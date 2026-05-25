#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Source the bashio library (HA add-on option parsing + logging)
source /usr/lib/bashio/bashio.sh
# ---------------------------------------------------------------
# Config Sync (GitOps) — HA Supervisor Add-on  v1.2.0
#
# Bidirectional sync:
#   IMPORT — pull config from GitHub → backup HA → validate → reload → verify
#   EXPORT — detect HA-side changes → commit + push to GitHub
#
# All configuration is read from the HA add-on options GUI
# via bashio.  The Supervisor token is auto-injected by HA.
# ---------------------------------------------------------------
set -euo pipefail

# Ensure HOME is set (needed by git config --global)
export HOME="${HOME:-/root}"

# ── Read add-on options ──────────────────────────────────────────────────
REPO=$(bashio::config 'github_repo')
BRANCH=$(bashio::config 'branch')
INTERVAL=$(bashio::config 'check_interval')
PAT=$(bashio::config 'github_pat')

# Export options
EXPORT_ENABLED=$(bashio::config 'export_enabled')
EXPORT_INTERVAL=$(bashio::config 'export_interval')
EXPORT_BRANCH=$(bashio::config 'export_branch')
EXPORT_MSG=$(bashio::config 'export_commit_message')

# Post-sync verify settle window — how many seconds to wait after reload_all
# before running the verification probes. Defaults to 5 if unset.
POST_SYNC_SETTLE=$(bashio::config 'post_sync_settle_seconds')
if [ -z "${POST_SYNC_SETTLE}" ]; then
    POST_SYNC_SETTLE=5
fi

# ── Constants ──────────────────────────────────────────────────────
REPO_DIR="/data/repo"
CONFIG_DIR="/config"
ROLLBACK_DIR="/data/.rollback"
LAST_IMPORT_MARKER="/data/.last-import"
LAST_EXPORT_TS="/data/.last-export-ts"

# Default export branch to the sync branch if not set
if [ -z "${EXPORT_BRANCH}" ]; then
    EXPORT_BRANCH="${BRANCH}"
fi

# ── Helpers ────────────────────────────────────────────────────────

# Sanitize PAT from log output to avoid leaking credentials.
sanitize_output() {
    local text="$1"
    if [ -n "${PAT}" ]; then
        echo "${text//${PAT}/***}"
    else
        echo "${text}"
    fi
}

# Build the sync_paths allowlist from config.
build_sync_filter() {
    local i=0
    SYNC_PATHS=()
    while bashio::config.exists "sync_paths[${i}]"; do
        SYNC_PATHS+=("$(bashio::config "sync_paths[${i}]")")
        i=$((i + 1))
    done
}

# Returns 0 if $1 matches any entry in SYNC_PATHS.
path_allowed() {
    local file="$1"
    for pattern in "${SYNC_PATHS[@]}"; do
        if [[ "${pattern}" == */ ]] && [[ "${file}" == "${pattern}"* ]]; then
            return 0
        fi
        if [[ "${file}" == "${pattern}" ]]; then
            return 0
        fi
    done
    return 1
}

# Call the Supervisor API.
#   $1 = method (GET, POST, etc)
#   $2 = endpoint (e.g. "/core/api/states/sun.sun")
#   $3 = optional JSON body (string)
# Returns curl's exit code (0 on 2xx, non-zero on transport/HTTP error).
# Writes the response body to stdout.
supervisor_api() {
    local method="$1" endpoint="$2" body="${3:-}"
    local -a args=(-sf -X "${method}"
                   "http://supervisor${endpoint}"
                   -H "Authorization: Bearer ${SUPERVISOR_TOKEN}"
                   -H "Content-Type: application/json")
    if [ -n "${body}" ]; then
        args+=(-d "${body}")
    fi
    curl "${args[@]}" 2>/dev/null
}

# Audit configuration.yaml for !include_dir_* directives whose target
# directory is NOT in sync_paths. Such directives produce silent sync
# skips on the referenced files (the add-on logs "Import: skipped (not
# in sync_paths)" but HA can't find the files; frontend assets break).
#
# Runs once at startup. Emits a bashio::log.warning per gap with the
# file:line and a one-line remediation. No-op if configuration.yaml
# is unreadable.
#
# See: GitHub issue #3, and the JLay2026/nanoclaw-zimaos#50 incident.
audit_include_dir_directives() {
    local cfg="${CONFIG_DIR}/configuration.yaml"
    if [ ! -r "${cfg}" ]; then
        bashio::log.debug "audit: ${cfg} unreadable — skipping include_dir_* audit"
        return 0
    fi

    local found_gaps=0
    # grep -nE matches the four canonical include_dir_* directives followed
    # by at least one path char. The path argument is the last whitespace-
    # separated token before any inline comment.
    while IFS= read -r line; do
        local lineno content arg norm
        lineno="${line%%:*}"
        content="${line#*:}"
        # Extract path arg via sed; strip optional quotes.
        arg=$(echo "${content}" | sed -E 's/.*!include_dir_(named|list|merge_named|merge_list)[[:space:]]+"?([^"[:space:]#]+)"?.*/\2/')
        # Normalize: ensure trailing slash for the allowlist check.
        norm="${arg%/}/"
        # Probe with a synthetic file inside the directory.
        if ! path_allowed "${norm}_audit_probe.yaml"; then
            bashio::log.warning "sync_paths gap: configuration.yaml line ${lineno} uses !include_dir_* on '${arg}', but '${norm}' is NOT in sync_paths. Files added there will be silently skipped on sync. Add '${norm}' to sync_paths to fix."
            found_gaps=$((found_gaps + 1))
        fi
    done < <(grep -nE '!include_dir_(named|list|merge_named|merge_list)[[:space:]]+\S+' "${cfg}" 2>/dev/null || true)

    if [ "${found_gaps}" -eq 0 ]; then
        bashio::log.debug "audit: no sync_paths gaps detected in configuration.yaml"
    else
        bashio::log.warning "audit: ${found_gaps} sync_paths gap(s) detected — see WARNINGs above"
    fi
}

# Trigger a partial HA backup via the Supervisor API before applying
# a sync. The backup is async on HA's side (we don't wait for the
# file write to complete); we only block on the API accepting the
# request.
#
# Scope: only the `homeassistant` folder (covers /config and .storage).
# Add-on data, ssl, share, media are excluded — they're not in the
# sync's mutation surface and keeping them out keeps the per-sync
# backup small + fast.
#
# Returns 0 if the backup request was accepted (HTTP 2xx), non-zero
# otherwise. On non-zero, the caller MUST abort the sync — we never
# write to /config without a backup in place.
#
# See: GitHub issue #4, and the JLay2026/nanoclaw-zimaos#50 incident.
ha_backup_pre_sync() {
    local target_sha="$1"
    local name="gitops-pre-${target_sha:0:8}"
    local body
    # JSON body. addons=[] folders=["homeassistant"] compressed=true
    body=$(printf '{"name":"%s","addons":[],"folders":["homeassistant"],"compressed":true}' "${name}")
    if ! supervisor_api POST "/backups/new/partial" "${body}" > /dev/null; then
        bashio::log.error "Pre-sync HA backup API failed — REFUSING to sync"
        bashio::log.error "  Probable causes: backup integration not loaded, Supervisor unreachable,"
        bashio::log.error "  insufficient disk space, or the partial-backup endpoint moved in HA."
        bashio::log.error "  Diagnostic: 'ha core info' on the host, or check Supervisor logs."
        return 1
    fi
    bashio::log.info "Pre-sync HA backup '${name}' triggered — Settings → System → Backups"
    return 0
}

# Run health probes after reload_all to catch breakage that
# check_config missed. Returns 0 if both probes pass, non-zero
# otherwise.
#
# Probe 1: GET /core/api/states/sun.sun
#   sun.sun is always present on HAOS. Failure here means HA's state
#   machine is not serving — core is down, restart wedged, or reload
#   deadlocked.
#
# Probe 2: GET /core/api/
#   Returns {"message":"API running."} on healthy + authenticated.
#   This is the probe that catches the 2026-05-25 bug class — a config
#   that passes check_config but breaks frontend rendering / auth UI.
#
# See: GitHub issue #5.
post_sync_verify() {
    bashio::log.debug "Post-sync verify: probe 1/2 — sun.sun state lookup"
    if ! supervisor_api GET "/core/api/states/sun.sun" > /dev/null; then
        bashio::log.error "Post-sync probe 1 FAILED: sun.sun unreachable"
        bashio::log.error "  HA may be down, restarting, or its state machine isn't serving."
        return 1
    fi

    bashio::log.debug "Post-sync verify: probe 2/2 — /core/api/ auth + responsiveness"
    if ! supervisor_api GET "/core/api/" > /dev/null; then
        bashio::log.error "Post-sync probe 2 FAILED: /core/api/ unresponsive or auth rejected"
        bashio::log.error "  Possible causes: auth provider broken, frontend assets missing,"
        bashio::log.error "  integration crashed during reload. THIS IS THE 2026-05-25 BUG CLASS."
        return 1
    fi

    bashio::log.info "Post-sync verify: both probes passed — sync verified healthy"
    return 0
}

# ── Git setup ─────────────────────────────────────────────────────

# Configure git identity for export commits
git config --global user.name "HA Config Sync"
git config --global user.email "config-sync@homeassistant.local"

# ── Initial clone ──────────────────────────────────────────────────
if [ ! -d "${REPO_DIR}/.git" ]; then
    bashio::log.info "First run — cloning ${REPO} (branch: ${BRANCH})"
    CLONE_URL="${REPO}"
    if [ -n "${PAT}" ]; then
        CLONE_URL=$(echo "${REPO}" | sed "s|https://|https://${PAT}@|")
    fi
    git clone --branch "${BRANCH}" --single-branch "${CLONE_URL}" "${REPO_DIR}"
    bashio::log.info "Clone complete"
fi

# Ensure remote URL has current PAT
if [ -n "${PAT}" ]; then
    AUTH_URL=$(echo "${REPO}" | sed "s|https://|https://${PAT}@|")
    git -C "${REPO_DIR}" remote set-url origin "${AUTH_URL}"
else
    git -C "${REPO_DIR}" remote set-url origin "${REPO}"
fi

# Build the path allowlist once at startup.
build_sync_filter
bashio::log.info "Sync paths: ${SYNC_PATHS[*]}"

# Audit configuration.yaml against the freshly-built sync_paths
# allowlist. Catches the 2026-05-25 incident class at add-on startup
# instead of via post-hoc operator discovery. See function comment.
audit_include_dir_directives

# ================================================================
#  EXPORT FUNCTIONS
# ================================================================

# Copy sync_paths files from /config into the repo working tree.
# Only touches files that match the sync_paths allowlist.
stage_config_to_repo() {
    local changed=0

    for pattern in "${SYNC_PATHS[@]}"; do
        if [[ "${pattern}" == */ ]]; then
            # Directory prefix — copy matching files
            if [ -d "${CONFIG_DIR}/${pattern}" ]; then
                mkdir -p "${REPO_DIR}/${pattern}"
                find "${CONFIG_DIR}/${pattern}" -type f -name '*.yaml' -o -name '*.yml' | while read -r src; do
                    rel="${src#${CONFIG_DIR}/}"
                    mkdir -p "${REPO_DIR}/$(dirname "${rel}")"
                    if ! cmp -s "${src}" "${REPO_DIR}/${rel}" 2>/dev/null; then
                        cp "${src}" "${REPO_DIR}/${rel}"
                        changed=1
                    fi
                done
            fi
        else
            # Exact file match
            if [ -f "${CONFIG_DIR}/${pattern}" ]; then
                if ! cmp -s "${CONFIG_DIR}/${pattern}" "${REPO_DIR}/${pattern}" 2>/dev/null; then
                    mkdir -p "${REPO_DIR}/$(dirname "${pattern}")"
                    cp "${CONFIG_DIR}/${pattern}" "${REPO_DIR}/${pattern}"
                    changed=1
                fi
            fi
        fi
    done

    return ${changed}
}

# Run one export cycle: compare /config to repo, commit + push if different.
do_export() {
    local label="$1"  # "initial" or "auto"

    cd "${REPO_DIR}"

    # If we just did an import, skip this export cycle to avoid
    # re-committing what we just pulled.
    if [ -f "${LAST_IMPORT_MARKER}" ]; then
        local import_sha
        import_sha=$(cat "${LAST_IMPORT_MARKER}")
        local current_sha
        current_sha=$(git rev-parse HEAD)
        if [ "${import_sha}" = "${current_sha}" ]; then
            bashio::log.debug "Skipping export — last action was an import"
            return 0
        fi
    fi

    # Ensure we're on the export branch
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "${current_branch}" != "${EXPORT_BRANCH}" ]; then
        # Fetch the export branch if it exists remotely
        git fetch origin "${EXPORT_BRANCH}" --quiet 2>/dev/null || true
        if git show-ref --verify --quiet "refs/remotes/origin/${EXPORT_BRANCH}"; then
            git checkout "${EXPORT_BRANCH}" --quiet 2>/dev/null || \
                git checkout -b "${EXPORT_BRANCH}" "origin/${EXPORT_BRANCH}" --quiet
        else
            git checkout -b "${EXPORT_BRANCH}" --quiet 2>/dev/null || \
                git checkout "${EXPORT_BRANCH}" --quiet
        fi
    fi

    # Stage /config files into the repo
    stage_config_to_repo || true

    # Check for actual changes
    git add -A
    if git diff --cached --quiet; then
        bashio::log.debug "Export (${label}): no changes to export"
        # Switch back to sync branch if different
        if [ "${EXPORT_BRANCH}" != "${BRANCH}" ]; then
            git checkout "${BRANCH}" --quiet 2>/dev/null || true
        fi
        return 0
    fi

    # Commit with timestamp
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local files_changed
    files_changed=$(git diff --cached --name-only | tr '\n' ' ')
    git commit -m "${EXPORT_MSG} (${ts})" -m "Files: ${files_changed}" --quiet

    bashio::log.info "Export (${label}): committed ${files_changed}"

    # Push
    if [ -z "${PAT}" ]; then
        bashio::log.warning "Export: no github_pat configured — cannot push (read-only)"
        # Switch back
        if [ "${EXPORT_BRANCH}" != "${BRANCH}" ]; then
            git checkout "${BRANCH}" --quiet 2>/dev/null || true
        fi
        return 1
    fi

    local push_output
    if push_output=$(git push origin "${EXPORT_BRANCH}" 2>&1); then
        bashio::log.info "Export (${label}): pushed to origin/${EXPORT_BRANCH}"
        date -u '+%s' > "${LAST_EXPORT_TS}"
    else
        bashio::log.error "Export (${label}): push failed — $(sanitize_output "${push_output}")"
    fi

    # Switch back to sync branch if different
    if [ "${EXPORT_BRANCH}" != "${BRANCH}" ]; then
        git checkout "${BRANCH}" --quiet 2>/dev/null || true
    fi
}

# ================================================================
#  IMPORT FUNCTION
# ================================================================

do_import() {
    cd "${REPO_DIR}"

    # Fetch
    local fetch_output
    if ! fetch_output=$(git fetch origin "${BRANCH}" 2>&1); then
        bashio::log.error "git fetch failed: $(sanitize_output "${fetch_output}") — will retry next cycle"
        return 1
    fi

    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/${BRANCH}")

    if [ "${LOCAL}" = "${REMOTE}" ]; then
        return 0  # no changes
    fi

    bashio::log.info "Import: change detected (${LOCAL:0:8} -> ${REMOTE:0:8})"

    # Fast-forward merge
    if ! git merge "origin/${BRANCH}" --ff-only --quiet 2>/dev/null; then
        bashio::log.error "Fast-forward merge failed — resetting to origin/${BRANCH}"
        git reset --hard "origin/${BRANCH}"
    fi

    # Identify changed files that pass the sync filter
    CHANGED_ALL=$(git diff --name-only "${LOCAL}" "${REMOTE}" || true)
    CHANGED=""
    SKIPPED=""

    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if path_allowed "${f}"; then
            CHANGED="${CHANGED}${CHANGED:+$'\n'}${f}"
        else
            SKIPPED="${SKIPPED}${SKIPPED:+, }${f}"
        fi
    done <<< "${CHANGED_ALL}"

    if [ -n "${SKIPPED}" ]; then
        bashio::log.info "Import: skipped (not in sync_paths): ${SKIPPED}"
    fi

    if [ -z "${CHANGED}" ]; then
        bashio::log.info "Import: no syncable config files changed"
        return 0
    fi

    bashio::log.info "Import: syncing $(echo "${CHANGED}" | tr '\n' ' ')"

    # ── Pre-sync HA backup (storage-level safety net) ────────────────
    # If this fails, we MUST roll back the git merge so the next cycle
    # re-attempts the same commit. Otherwise the next iteration sees
    # LOCAL==REMOTE and silently skips the pending changes.
    if ! ha_backup_pre_sync "${REMOTE}"; then
        bashio::log.error "Aborting sync — rolling back git state to ${LOCAL:0:8}; next cycle will retry"
        git reset --hard "${LOCAL}"
        return 1
    fi

    # Backup affected files (existing file-level rollback — belt + suspenders
    # with the storage-level HA backup above)
    BACKUP="${ROLLBACK_DIR}/${LOCAL:0:8}"
    rm -rf "${BACKUP}"
    mkdir -p "${BACKUP}"

    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if [ -f "${CONFIG_DIR}/${f}" ]; then
            mkdir -p "${BACKUP}/$(dirname "${f}")"
            cp "${CONFIG_DIR}/${f}" "${BACKUP}/${f}"
        fi
    done <<< "${CHANGED}"

    # Copy changed files to /config
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if [ -f "${REPO_DIR}/${f}" ]; then
            mkdir -p "${CONFIG_DIR}/$(dirname "${f}")"
            cp "${REPO_DIR}/${f}" "${CONFIG_DIR}/${f}"
            bashio::log.debug "Import: copied ${f}"
        fi
    done <<< "${CHANGED}"

    sleep 2  # let HA notice file changes

    # Validate config via Supervisor API
    CHECK_RESULT=$(supervisor_api POST "/core/api/config/core/check_config") || {
        bashio::log.error "Import: check-config API unreachable — rolling back"
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            [ -f "${BACKUP}/${f}" ] && cp "${BACKUP}/${f}" "${CONFIG_DIR}/${f}"
        done <<< "${CHANGED}"
        git reset --hard "${LOCAL}"
        rm -rf "${BACKUP}"
        return 1
    }

    VALID=$(echo "${CHECK_RESULT}" | jq -r '.result // empty' 2>/dev/null)

    if [ "${VALID}" = "valid" ]; then
        bashio::log.info "Import: config valid — reloading Home Assistant"
        supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null 2>&1 || true
        bashio::log.info "Import: reload complete (${LOCAL:0:8} -> ${REMOTE:0:8})"

        # ── Post-sync verification probes ────────────────────────────
        # Let HA settle after reload before probing. POST_SYNC_SETTLE
        # defaults to 5s; bump via the post_sync_settle_seconds option
        # if your HA setup is slow to recover from reload_all.
        sleep "${POST_SYNC_SETTLE}"
        if ! post_sync_verify; then
            bashio::log.error "============================================================"
            bashio::log.error "POST-SYNC VERIFICATION FAILED — rolling back"
            bashio::log.error "============================================================"

            # File-level rollback (existing pattern, mirrored from invalid-check path)
            while IFS= read -r f; do
                [ -z "${f}" ] && continue
                [ -f "${BACKUP}/${f}" ] && cp "${BACKUP}/${f}" "${CONFIG_DIR}/${f}"
            done <<< "${CHANGED}"
            git reset --hard "${LOCAL}"

            # Best-effort re-reload with the rolled-back files. If HA is
            # too broken for this to succeed, the operator restores from
            # the pre-sync HA backup below.
            bashio::log.warning "Attempting re-reload of rolled-back files..."
            supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null 2>&1 || true

            bashio::log.error ""
            bashio::log.error "If HA is still broken, restore the pre-sync backup:"
            bashio::log.error "  Settings → System → Backups → 'gitops-pre-${REMOTE:0:8}'"
            bashio::log.error "============================================================"

            rm -rf "${BACKUP}"
            return 1
        fi

        rm -rf "${BACKUP}"
        # Mark that we just imported — export should skip next cycle
        git rev-parse HEAD > "${LAST_IMPORT_MARKER}"
    else
        ERROR_MSG=$(echo "${CHECK_RESULT}" | jq -r '.errors // .message // "unknown error"' 2>/dev/null)
        bashio::log.error "Import: config invalid: ${ERROR_MSG}"
        bashio::log.warning "Import: rolling back to ${LOCAL:0:8}"
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            [ -f "${BACKUP}/${f}" ] && cp "${BACKUP}/${f}" "${CONFIG_DIR}/${f}"
        done <<< "${CHANGED}"
        git reset --hard "${LOCAL}"
        rm -rf "${BACKUP}"
    fi

    # Clean old rollback dirs (keep last 5)
    if [ -d "${ROLLBACK_DIR}" ]; then
        ls -1t "${ROLLBACK_DIR}" 2>/dev/null | tail -n +6 | while read -r old; do
            rm -rf "${ROLLBACK_DIR:?}/${old}"
        done
    fi

    return 0
}

# ================================================================
#  STARTUP
# ================================================================

# One-time export on startup (seeds the repo if empty, or captures
# any HA-side changes made while the add-on was stopped).
if [ "${EXPORT_ENABLED}" = "true" ]; then
    bashio::log.info "Export enabled — running initial export"
    do_export "initial" || true
    bashio::log.info "Export interval: ${EXPORT_INTERVAL}s, branch: ${EXPORT_BRANCH}"
fi

bashio::log.info "Starting main loop — import every ${INTERVAL}s"

# ================================================================
#  MAIN LOOP
# ================================================================

IMPORT_COUNTER=0
EXPORT_CYCLES=$(( EXPORT_INTERVAL / INTERVAL ))  # how many import cycles per export
if [ "${EXPORT_CYCLES}" -lt 1 ]; then
    EXPORT_CYCLES=1
fi

while true; do
    # ── Import (every cycle) ─────────────────────────────────────
    do_import || true

    # ── Export (every EXPORT_CYCLES import cycles) ───────────
    IMPORT_COUNTER=$(( IMPORT_COUNTER + 1 ))
    if [ "${EXPORT_ENABLED}" = "true" ] && [ $(( IMPORT_COUNTER % EXPORT_CYCLES )) -eq 0 ]; then
        do_export "auto" || true
    fi

    sleep "${INTERVAL}"
done
