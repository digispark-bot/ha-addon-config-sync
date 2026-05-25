#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Source the bashio library (HA add-on option parsing + logging)
source /usr/lib/bashio/bashio.sh
# ---------------------------------------------------------------
# Config Sync (GitOps) — HA Supervisor Add-on  v1.4.0
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

# Whether to surface sync failures as HA persistent_notifications.
# Default: true. Operator can disable for headless deployments where
# UI clutter is unwanted.
NOTIFY_ON_FAILURE=$(bashio::config 'notify_on_failure')
if [ -z "${NOTIFY_ON_FAILURE}" ]; then
    NOTIFY_ON_FAILURE="true"
fi

# Whether to call /core/restart instead of reload_all when the sync
# touches the lovelace key in configuration.yaml. Default: true.
# reload_all does NOT re-register lovelace.dashboards entries — the
# 2026-05-25 incident class needed manual restart after sync. Disabling
# this option reverts to reload_all and re-introduces that failure mode.
RESTART_ON_LOVELACE_CHANGE=$(bashio::config 'restart_on_lovelace_change')
if [ -z "${RESTART_ON_LOVELACE_CHANGE}" ]; then
    RESTART_ON_LOVELACE_CHANGE="true"
fi

# Extra settle seconds added to POST_SYNC_SETTLE when we used /core/restart
# instead of reload_all — HA needs longer to come back from a full restart.
RESTART_EXTRA_SETTLE=25

# ── Constants ──────────────────────────────────────────────────────
REPO_DIR="/data/repo"
CONFIG_DIR="/config"
ROLLBACK_DIR="/data/.rollback"
LAST_IMPORT_MARKER="/data/.last-import"
LAST_EXPORT_TS="/data/.last-export-ts"

# Diagnostic-capture temp files for supervisor_api().
# These survive the subshell boundary used by `var=$(supervisor_api ...)`,
# so the parent shell can read them after the call returns. The add-on
# runs as a single-threaded bash loop so there's no concurrent-write risk.
SUPERVISOR_RESP_BODY_FILE="/tmp/.sup_resp_body"
SUPERVISOR_RESP_CODE_FILE="/tmp/.sup_resp_code"

# Persistent-notification ID used by notify_sync_failure / _recovered.
# Singleton — every failure updates the same notification, every recovery
# dismisses it. Operators see one notification reflecting the LATEST sync
# state, not a backlog.
NOTIFICATION_ID="config_sync_failure"

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

# Call the Supervisor API and capture both the response body AND the
# HTTP status code for diagnostic-quality error reporting.
#
#   $1 = method (GET, POST, etc)
#   $2 = endpoint (e.g. "/core/api/states/sun.sun")
#   $3 = optional JSON body (string)
#
# Behavior:
#   - Writes the response body to stdout (so existing $(supervisor_api ...)
#     callers continue to work)
#   - Also writes the response body to ${SUPERVISOR_RESP_BODY_FILE} and
#     the HTTP status code to ${SUPERVISOR_RESP_CODE_FILE}. These survive
#     the subshell used by command substitution — the parent shell can
#     read them after the call returns.
#   - Returns 0 on HTTP 2xx, 1 on non-2xx HTTP response (e.g. 401/403/404/500),
#     2 on transport error (curl couldn't connect).
#
# Callers that want a diagnostic log line on failure should call
# log_supervisor_error after a non-zero return.
supervisor_api() {
    local method="$1" endpoint="$2" body="${3:-}"
    local -a args=(-s -o "${SUPERVISOR_RESP_BODY_FILE}" -X "${method}"
                   "http://supervisor${endpoint}"
                   -H "Authorization: Bearer ${SUPERVISOR_TOKEN}"
                   -H "Content-Type: application/json"
                   -w "%{http_code}")
    if [ -n "${body}" ]; then
        args+=(-d "${body}")
    fi

    # Ensure files exist + are empty even on transport error — readers
    # never see stale content from a prior call.
    : > "${SUPERVISOR_RESP_BODY_FILE}"
    : > "${SUPERVISOR_RESP_CODE_FILE}"

    local code
    if ! code=$(curl "${args[@]}" 2>/dev/null); then
        # Transport failure — couldn't reach Supervisor at all.
        echo "000" > "${SUPERVISOR_RESP_CODE_FILE}"
        return 2
    fi
    echo "${code}" > "${SUPERVISOR_RESP_CODE_FILE}"

    # Body echo for backwards compat with `var=$(supervisor_api ...)`.
    cat "${SUPERVISOR_RESP_BODY_FILE}"

    if [ "${code:0:1}" = "2" ]; then
        return 0
    fi
    return 1
}

# Emit a structured ERROR log line for a failed supervisor_api() call.
# Reads ${SUPERVISOR_RESP_CODE_FILE} + ${SUPERVISOR_RESP_BODY_FILE} (written
# by the most recent supervisor_api invocation, survives subshells).
#
#   $1 = prefix string (e.g. "Pre-sync HA backup API failed")
#
# Body output is truncated to 500 chars to avoid spamming the add-on log
# with multi-page error pages, and newlines are collapsed so the line
# stays grep-friendly.
log_supervisor_error() {
    local prefix="$1"
    local code body
    code=$(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo "???")
    body=$(head -c 500 "${SUPERVISOR_RESP_BODY_FILE}" 2>/dev/null | tr -d '\n' | tr -d '\r')

    if [ "${code}" = "000" ]; then
        bashio::log.error "${prefix} (no response — Supervisor unreachable)"
        bashio::log.error "  Probable cause: add-on networking down, or 'http://supervisor' DNS failure"
    elif [ -n "${body}" ]; then
        bashio::log.error "${prefix} (HTTP ${code})"
        bashio::log.error "  Supervisor response: ${body}"
    else
        bashio::log.error "${prefix} (HTTP ${code}, empty body)"
    fi
}

# Create or update an HA persistent_notification announcing a sync failure.
# Singleton (NOTIFICATION_ID) — every failure overwrites the previous one
# so the UI shows the LATEST state. Operators dismiss it implicitly via
# notify_sync_recovered() on the next healthy sync.
#
#   $1 = title (short — shown in the UI header)
#   $2 = message (longer — shown in the body; markdown supported by HA)
#
# Failures of the notification API itself are logged at WARNING and do
# not cascade — the sync's existing failure-handling has already done
# its job before this is called.
#
# No-op if notify_on_failure config option is false.
notify_sync_failure() {
    if [ "${NOTIFY_ON_FAILURE}" != "true" ]; then
        return 0
    fi
    local title="$1" message="$2"
    # Use jq to safely build the JSON — handles any quoting, newlines,
    # backslashes, etc. that might appear in error messages.
    local body
    body=$(jq -nc \
        --arg id "${NOTIFICATION_ID}" \
        --arg title "${title}" \
        --arg msg "${message}" \
        '{notification_id: $id, title: $title, message: $msg}' 2>/dev/null)
    if [ -z "${body}" ]; then
        bashio::log.warning "notify_sync_failure: failed to build JSON body (jq error)"
        return 0
    fi
    if ! supervisor_api POST "/core/api/services/persistent_notification/create" "${body}" > /dev/null; then
        bashio::log.warning "notify_sync_failure: HA notification API call failed (sync error already logged above)"
    fi
    return 0
}

# Dismiss the sync-failure persistent_notification (called on healthy sync
# completion). Idempotent — succeeds whether or not a notification exists.
# No-op if notify_on_failure config option is false.
notify_sync_recovered() {
    if [ "${NOTIFY_ON_FAILURE}" != "true" ]; then
        return 0
    fi
    local body
    body=$(jq -nc --arg id "${NOTIFICATION_ID}" '{notification_id: $id}' 2>/dev/null)
    if [ -z "${body}" ]; then
        return 0
    fi
    # Dismiss failure silently — we don't care if it didn't exist.
    supervisor_api POST "/core/api/services/persistent_notification/dismiss" "${body}" > /dev/null 2>&1 || true
    return 0
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
        log_supervisor_error "Pre-sync HA backup API failed — REFUSING to sync"
        bashio::log.error "  Common causes for this endpoint:"
        bashio::log.error "    HTTP 401/403 — add-on missing 'hassio_api: true' or 'hassio_role: backup' in config.yaml"
        bashio::log.error "    HTTP 4xx     — backup integration not loaded, or request body schema changed"
        bashio::log.error "    HTTP 5xx     — Supervisor internal error, or disk full"
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
        log_supervisor_error "Post-sync probe 1 FAILED: sun.sun unreachable"
        bashio::log.error "  HA may be down, restarting, or its state machine isn't serving."
        return 1
    fi

    bashio::log.debug "Post-sync verify: probe 2/2 — /core/api/ auth + responsiveness"
    if ! supervisor_api GET "/core/api/" > /dev/null; then
        log_supervisor_error "Post-sync probe 2 FAILED: /core/api/ unresponsive or auth rejected"
        bashio::log.error "  Possible causes: auth provider broken, frontend assets missing,"
        bashio::log.error "  integration crashed during reload. THIS IS THE 2026-05-25 BUG CLASS."
        return 1
    fi

    bashio::log.info "Post-sync verify: both probes passed — sync verified healthy"
    return 0
}

# Reconcile pass: ensure every tracked file matching sync_paths exists
# on /config. Catches the bug class where a file is tracked in the repo
# but was never modified in any commit reaching /config — the diff-based
# sync never copies it, and a !include directive against it then fails
# check_config (the M5.6 deploy saga that needed 3 PRs to work around).
#
# Runs as the LAST step before check_config in do_import(), but ONLY on
# import cycles that have syncable changes (no overhead on no-op cycles).
#
# Cost: one stat per tracked file + cp for any missing. On a clean repo
# this is sub-50ms even for hundreds of tracked files. On a repo with
# gaps, it logs each reconciliation so the operator sees the catch.
#
# Returns 0 always; reconciliation failures (rare — cp to /config) are
# logged but don't abort the sync because check_config will catch any
# real damage.
#
# See: GitHub issue #2, M5.6 deploy saga in JLay2026/nanoclaw-zimaos.
reconcile_tracked_files() {
    local reconcile_count=0
    local cp_failure_count=0

    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        # Only reconcile files in sync_paths — anything outside the
        # allowlist would also be silently skipped on normal sync, so
        # it's not our job to copy it.
        if ! path_allowed "${f}"; then
            continue
        fi
        # Already there → no-op.
        if [ -f "${CONFIG_DIR}/${f}" ]; then
            continue
        fi
        # Missing from /config → copy it.
        local dst_dir
        dst_dir="${CONFIG_DIR}/$(dirname "${f}")"
        if ! mkdir -p "${dst_dir}" 2>/dev/null; then
            bashio::log.warning "Reconcile: failed to mkdir '${dst_dir}' for tracked-but-missing file '${f}'"
            cp_failure_count=$((cp_failure_count + 1))
            continue
        fi
        if cp "${REPO_DIR}/${f}" "${CONFIG_DIR}/${f}" 2>/dev/null; then
            bashio::log.info "Reconcile: copied tracked-but-missing file '${f}' to /config (issue #2 prevention)"
            reconcile_count=$((reconcile_count + 1))
        else
            bashio::log.warning "Reconcile: cp failed for '${f}' — check_config may fail next"
            cp_failure_count=$((cp_failure_count + 1))
        fi
    done < <(cd "${REPO_DIR}" && git ls-files 2>/dev/null)

    if [ "${reconcile_count}" -gt 0 ] || [ "${cp_failure_count}" -gt 0 ]; then
        bashio::log.info "Reconcile: ${reconcile_count} missing file(s) copied, ${cp_failure_count} failure(s)"
    fi
    return 0
}

# Returns 0 if this sync's diff on configuration.yaml between LOCAL and
# REMOTE touches the lovelace key. Used to pick the reload strategy:
# reload_all does NOT re-register lovelace.dashboards entries, so any
# change to the lovelace block requires /core/restart.
#
# Cheap pre-check: configuration.yaml must be in CHANGED. If not, no
# lovelace concern regardless of what changed elsewhere.
#
# Then: `git diff LOCAL REMOTE -- configuration.yaml | grep '^[+-].*lovelace'`
# False positives (a YAML comment mentioning "lovelace") cause an extra
# restart — acceptable cost vs missing the real case. False negatives
# are not possible for the canonical case (any meaningful change to
# the lovelace block contains the word "lovelace" somewhere in its
# direct path).
sync_touches_lovelace() {
    if ! echo "${CHANGED}" | grep -qx 'configuration.yaml'; then
        return 1
    fi
    git -C "${REPO_DIR}" diff "${LOCAL}" "${REMOTE}" -- configuration.yaml 2>/dev/null \
        | grep -qiE '^[+-].*lovelace'
}

# Returns 0 if any file under themes/ is in CHANGED. New theme files
# don't always get picked up by reload_all — frontend.reload_themes
# refreshes the theme registry but doesn't reload the rest of HA.
sync_touches_themes() {
    echo "${CHANGED}" | grep -qE '^themes/'
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
#
# Returns 0 if no files changed, 1 if any file was updated. The
# return semantics let do_export() short-circuit when there's nothing
# to commit.
stage_config_to_repo() {
    local changed=0

    for pattern in "${SYNC_PATHS[@]}"; do
        if [[ "${pattern}" == */ ]]; then
            # Directory prefix — copy matching files.
            if [ -d "${CONFIG_DIR}/${pattern}" ]; then
                mkdir -p "${REPO_DIR}/${pattern}"
                # Process substitution (not a pipe) — the while loop runs
                # in THIS shell so `changed=1` propagates. The old `find
                # | while` form ran the while in a subshell and silently
                # always returned 0 from the function. Also: explicit
                # parens around the -name OR so `-type f` applies to both
                # extensions (the old form matched any *.yml regardless
                # of type due to operator precedence).
                while IFS= read -r src; do
                    [ -z "${src}" ] && continue
                    rel="${src#${CONFIG_DIR}/}"
                    mkdir -p "${REPO_DIR}/$(dirname "${rel}")"
                    if ! cmp -s "${src}" "${REPO_DIR}/${rel}" 2>/dev/null; then
                        cp "${src}" "${REPO_DIR}/${rel}"
                        changed=1
                    fi
                done < <(find "${CONFIG_DIR}/${pattern}" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)
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

# Switch back to the sync branch after an export operation, logging a
# WARNING (not silent fallthrough) on failure. Used by do_export() in
# multiple early-exit paths.
checkout_back_to_sync_branch() {
    if [ "${EXPORT_BRANCH}" = "${BRANCH}" ]; then
        return 0  # already on the sync branch, no switch needed
    fi
    local co_err
    if ! co_err=$(git checkout "${BRANCH}" --quiet 2>&1); then
        bashio::log.warning "Export: failed to switch back to ${BRANCH} after export: $(sanitize_output "${co_err}")"
        bashio::log.warning "  Next import cycle will operate on '${EXPORT_BRANCH}' until manually corrected."
        return 1
    fi
    return 0
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
        # Fetch the export branch if it exists remotely. Failure here is
        # expected when the branch doesn't exist yet (first export); the
        # checkout fallback handles creation. We log DEBUG instead of
        # silent-fall-through so a genuine fetch failure isn't masked.
        local fetch_err
        if ! fetch_err=$(git fetch origin "${EXPORT_BRANCH}" 2>&1); then
            bashio::log.debug "Export: fetch of ${EXPORT_BRANCH} failed (expected on first export): $(sanitize_output "${fetch_err}")"
        fi
        if git show-ref --verify --quiet "refs/remotes/origin/${EXPORT_BRANCH}"; then
            local co_err
            if ! co_err=$(git checkout "${EXPORT_BRANCH}" --quiet 2>&1); then
                if ! git checkout -b "${EXPORT_BRANCH}" "origin/${EXPORT_BRANCH}" --quiet 2>/dev/null; then
                    bashio::log.error "Export: failed to switch to ${EXPORT_BRANCH}: $(sanitize_output "${co_err}")"
                    return 1
                fi
            fi
        else
            if ! git checkout -b "${EXPORT_BRANCH}" --quiet 2>/dev/null; then
                local co_err
                if ! co_err=$(git checkout "${EXPORT_BRANCH}" --quiet 2>&1); then
                    bashio::log.error "Export: failed to switch to or create ${EXPORT_BRANCH}: $(sanitize_output "${co_err}")"
                    return 1
                fi
            fi
        fi
    fi

    # Stage /config files into the repo. stage_config_to_repo returns
    # 1 if any file changed, 0 otherwise — but we don't act on the
    # return here because `git diff --cached --quiet` below is the
    # authoritative check (it sees the git index, which is what we'd
    # be committing). The return code semantics are still preserved
    # by the Sprint 2 race fix for future callers.
    stage_config_to_repo || true

    # Check for actual changes
    git add -A
    if git diff --cached --quiet; then
        bashio::log.debug "Export (${label}): no changes to export"
        checkout_back_to_sync_branch || true
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
        checkout_back_to_sync_branch || true
        return 1
    fi

    local push_output
    if push_output=$(git push origin "${EXPORT_BRANCH}" 2>&1); then
        bashio::log.info "Export (${label}): pushed to origin/${EXPORT_BRANCH}"
        date -u '+%s' > "${LAST_EXPORT_TS}"
    else
        bashio::log.error "Export (${label}): push failed — $(sanitize_output "${push_output}")"
    fi

    checkout_back_to_sync_branch || true
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
        notify_sync_failure \
            "Config Sync: pre-sync backup failed" \
            "The add-on could not take an HA backup before syncing ${REMOTE:0:8}. Sync aborted and will retry next cycle. Check the add-on log for the Supervisor error response."
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

    # ── Reconcile tracked-but-missing files (issue #2 fix, Sprint 2) ──
    # Walk every tracked file matching sync_paths and copy any that are
    # missing from /config. Catches the M5.6 bug class where a tracked-
    # never-modified file fails to materialize on first sync, causing
    # check_config to fail later because of an !include reference.
    reconcile_tracked_files

    sleep 2  # let HA notice file changes

    # Validate config via Supervisor API
    CHECK_RESULT=$(supervisor_api POST "/core/api/config/core/check_config") || {
        # supervisor_api wrote the HTTP code + body to temp files BEFORE
        # the subshell exited — those survive into this branch, so the
        # log_supervisor_error helper can read them here.
        log_supervisor_error "Import: check-config API failed — rolling back"
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            [ -f "${BACKUP}/${f}" ] && cp "${BACKUP}/${f}" "${CONFIG_DIR}/${f}"
        done <<< "${CHANGED}"
        git reset --hard "${LOCAL}"
        rm -rf "${BACKUP}"
        notify_sync_failure \
            "Config Sync: check_config API unreachable" \
            "Tried to validate ${REMOTE:0:8} but the Supervisor check_config endpoint did not respond. Sync rolled back to ${LOCAL:0:8}. Check the add-on log for the Supervisor error response."
        return 1
    }

    VALID=$(echo "${CHECK_RESULT}" | jq -r '.result // empty' 2>/dev/null)

    if [ "${VALID}" = "valid" ]; then
        # ── Reload-strategy selection (Sprint 3) ─────────────────────
        # Pick the right way to apply the new config based on what changed:
        #   - lovelace touched  → /core/restart (re-registers dashboards)
        #   - themes touched    → reload_all + frontend.reload_themes
        #   - everything else   → reload_all (lightest, current default)
        #
        # See sync_touches_lovelace() / sync_touches_themes() for the
        # detection heuristics. Logged so the operator can see WHY a
        # given strategy was used.
        local reload_strategy reload_settle
        if [ "${RESTART_ON_LOVELACE_CHANGE}" = "true" ] && sync_touches_lovelace; then
            reload_strategy="/core/restart"
            reload_settle=$((POST_SYNC_SETTLE + RESTART_EXTRA_SETTLE))
            bashio::log.info "Import: configuration.yaml lovelace block changed — calling /core/restart (reload_all does NOT re-register dashboards)"
            if ! supervisor_api POST "/core/api/services/homeassistant/restart" > /dev/null; then
                log_supervisor_error "/core/restart API call failed"
                bashio::log.warning "  Manual HA restart may be needed for lovelace dashboards to register."
            fi
        elif sync_touches_themes; then
            reload_strategy="reload_all + frontend.reload_themes"
            reload_settle="${POST_SYNC_SETTLE}"
            bashio::log.info "Import: themes/ files changed — calling reload_all + frontend.reload_themes"
            if ! supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null; then
                log_supervisor_error "reload_all API call failed — HA may not have picked up the changes"
                bashio::log.warning "  Continuing to post-sync probes; they will catch any actual breakage."
            fi
            if ! supervisor_api POST "/core/api/services/frontend/reload_themes" > /dev/null; then
                log_supervisor_error "frontend.reload_themes API call failed — new themes may not activate until next HA restart"
            fi
        else
            reload_strategy="reload_all"
            reload_settle="${POST_SYNC_SETTLE}"
            bashio::log.info "Import: config valid — reloading Home Assistant"
            if ! supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null; then
                log_supervisor_error "reload_all API call failed — HA may not have picked up the changes"
                bashio::log.warning "  Continuing to post-sync probes; they will catch any actual breakage."
            fi
        fi
        bashio::log.info "Import: ${reload_strategy} complete (${LOCAL:0:8} -> ${REMOTE:0:8})"

        # ── Post-sync verification probes ────────────────────────────
        # Let HA settle after reload/restart before probing. Wait time
        # scales with the strategy: restart needs longer because HA
        # core is fully reinitializing.
        sleep "${reload_settle}"
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
            # the pre-sync HA backup below. Sprint 2: capture failure to
            # log (was silently swallowed in v1.2.x).
            bashio::log.warning "Attempting re-reload of rolled-back files..."
            if ! supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null; then
                log_supervisor_error "Re-reload of rolled-back files also failed"
                bashio::log.warning "  HA is in an inconsistent state; restore from the pre-sync backup."
            fi

            bashio::log.error ""
            bashio::log.error "If HA is still broken, restore the pre-sync backup:"
            bashio::log.error "  Settings → System → Backups → 'gitops-pre-${REMOTE:0:8}'"
            bashio::log.error "============================================================"

            rm -rf "${BACKUP}"
            notify_sync_failure \
                "Config Sync: post-sync verification failed" \
                "Applied ${reload_strategy} for ${REMOTE:0:8} but HA failed health probes afterward. Files rolled back to ${LOCAL:0:8}. **If HA is still broken, restore backup \`gitops-pre-${REMOTE:0:8}\`** via Settings → System → Backups. Check the add-on log for the failed probe details."
            return 1
        fi

        rm -rf "${BACKUP}"
        # Mark that we just imported — export should skip next cycle
        git rev-parse HEAD > "${LAST_IMPORT_MARKER}"
        # Healthy sync completed — dismiss any prior failure notification
        # so the operator's UI is clean.
        notify_sync_recovered
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
        notify_sync_failure \
            "Config Sync: check_config rejected the new config" \
            "HA's check_config returned invalid for ${REMOTE:0:8}: ${ERROR_MSG}. Files rolled back to ${LOCAL:0:8}; sync will keep retrying. Fix the config in the repo and push again."
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
