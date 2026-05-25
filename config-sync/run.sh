#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Source the bashio library (HA add-on option parsing + logging)
source /usr/lib/bashio/bashio.sh
# ---------------------------------------------------------------
# Config Sync (GitOps) — HA Supervisor Add-on  v1.6.0
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

# Git network timeouts (v1.5.4, H2). Abort git fetch/push/clone if the
# connection stalls (<1KB/s for 60s). Without these, a flaky GitHub
# connection can hang the entire single-threaded sync loop forever.
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIMEOUT=60

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

# Whether to ABORT syncs that would silently drop files referenced by
# !include_dir_* directives in configuration.yaml. Default: true
# (Sprint 4 P1, v1.5.1). When false, the gap is logged loudly at ERROR
# but the sync proceeds with the files dropped (the v1.5.0 behavior).
# Operators with intentional layout choices that need this off can
# flip it to false; default protects against the 2026-05-25 class.
STRICT_SYNC_PATHS_CHECK=$(bashio::config 'strict_sync_paths_check')
if [ -z "${STRICT_SYNC_PATHS_CHECK}" ]; then
    STRICT_SYNC_PATHS_CHECK="true"
fi

# How many gitops-pre-* HA backups to retain (v1.5.2, Sprint 4 P2).
# After every sync cycle that took a backup, the add-on enumerates all
# HA backups whose name starts with "gitops-pre-", sorts by date desc,
# and deletes everything past the Nth most recent. Default 7 — covers
# roughly a week of one-sync-per-day deploys.
#   0  = never prune (v1.5.1 behavior: backups accumulate forever)
#   N  = keep the N most recent gitops-pre-* backups
PRE_SYNC_BACKUP_RETENTION=$(bashio::config 'pre_sync_backup_retention')
if [ -z "${PRE_SYNC_BACKUP_RETENTION}" ]; then
    PRE_SYNC_BACKUP_RETENTION=7
fi

# Allowlist of hostnames the github_repo URL is permitted to point at
# (v1.6.0, Sprint 5 P1, M7). Default ["github.com"] catches the M7
# review finding: without this, a misconfigured/social-engineered
# github_repo URL would happily send the PAT to attacker.com.
# Operators using GitHub Enterprise add their GHE hostname here
# (e.g. ["github.com", "github.mycorp.io"]). Subdomain matches are
# allowed via suffix-match (e.g. "github.com" allows api.github.com,
# raw.githubusercontent.com, etc.). Build the array via the same
# loop pattern as sync_paths.
ALLOWED_REPO_HOSTS=()
_i=0
while bashio::config.exists "allowed_repo_hosts[${_i}]"; do
    ALLOWED_REPO_HOSTS+=("$(bashio::config "allowed_repo_hosts[${_i}]")")
    _i=$((_i + 1))
done
if [ "${#ALLOWED_REPO_HOSTS[@]}" -eq 0 ]; then
    ALLOWED_REPO_HOSTS=("github.com")
fi

# Whether to abort the sync if the tracked repo contains symlinks
# matching sync_paths (v1.6.0, Sprint 5 P1, M6). Default: true.
# Symlinks in a tracked file are a path-traversal vector — a commit
# could turn automations.yaml into a symlink targeting /etc/passwd
# (read on cp) or another sensitive path (overwrite on cp). HA itself
# also has trouble with symlinks in /config. Operators who legitimately
# need symlinks (rare) can disable to revert to the v1.5.x behavior.
BLOCK_SYMLINKS=$(bashio::config 'block_symlinks')
if [ -z "${BLOCK_SYMLINKS}" ]; then
    BLOCK_SYMLINKS="true"
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

# Supervisor API timeouts (v1.5.4, H1). Without these, a hung
# Supervisor would wedge the single-threaded sync loop forever.
# 30s max per call is comfortable for /backups/new/partial (which
# returns when HA accepts the job, not when the backup completes)
# and tight enough for the per-cycle health probes.
SUPERVISOR_API_TIMEOUT=30
SUPERVISOR_API_CONNECT_TIMEOUT=5

# Persistent-notification ID used by notify_sync_failure / _recovered.
# Singleton — every failure updates the same notification, every recovery
# dismisses it. Operators see one notification reflecting the LATEST sync
# state, not a backlog.
NOTIFICATION_ID="config_sync_failure"

# Per-sync structured-log location + retention. v1.4.1.
# Writes go to /data/ which is the add-on's persistent storage —
# survives restart AND add-on upgrade. NOT /config (would pollute HA's
# tree) and NOT /share (would require widening filesystem permissions).
# Operator access: `docker exec addon_config-sync ls /data/logs/sync/`.
SYNC_LOG_DIR="/data/logs/sync"
SYNC_LOG_MAX_FILES=20
# Set per-cycle by sync_log_open(); cleared by sync_log_close(). When
# empty, sync_log() is a no-op. This lets us drop sync_log calls into
# helpers (e.g. post_sync_verify) without needing to plumb the file
# path through arguments.
SYNC_LOG_FILE=""

# Per-export structured-log location (v1.5.3, Sprint 4 P3 — export-side
# parity with the v1.4.1 import-side log). Same parent /data/ tier;
# same retention (SYNC_LOG_MAX_FILES = 20); separate subdir so import
# and export logs don't intermix. Filename pattern:
# <UTC-timestamp>-export-<mode>.log where <mode> is "initial" or "auto".
EXPORT_LOG_DIR="/data/logs/export"
# Set per-cycle by export_log_open(); cleared by export_log_close().
# When empty, export_log() is a no-op. Parallel to SYNC_LOG_FILE.
EXPORT_LOG_FILE=""

# Sync status JSON + HA sensor entity (v1.5.0).
# After every cycle, sync state is published to:
#   1. /data/sync_status.json — persistent JSON snapshot, survives
#      restart + upgrade. Holds the lifetime counters that get restored
#      on next boot. Operator access via `docker exec ... cat`.
#   2. sensor.config_sync_status — HA entity, first-class state with
#      attributes. Can be put on a dashboard, triggered on by
#      automations (e.g. ping Telegram on failure), polled by
#      agent-homeops over the standard /core/api/states API.
STATUS_FILE="/data/sync_status.json"
STATUS_SENSOR_ENTITY="sensor.config_sync_status"

# Default export branch to the sync branch if not set
if [ -z "${EXPORT_BRANCH}" ]; then
    EXPORT_BRANCH="${BRANCH}"
fi

# ── Helpers ────────────────────────────────────────────────────────

# Sanitize PAT from log output to avoid leaking credentials.
# v1.5.4 (M5): quote the search side of the pattern substitution so
# glob characters in the PAT (* ? [ ]) are matched literally rather
# than as patterns. Current GitHub PAT format doesn't use glob chars,
# but if it ever does, a non-quoted form would silently fail to scrub
# the PAT and leak it into the log.
sanitize_output() {
    local text="$1"
    if [ -n "${PAT}" ]; then
        echo "${text//"${PAT}"/***}"
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

# ────────────────────────────────────────────────────────────────────
#  Per-sync structured log (v1.4.1)
# ────────────────────────────────────────────────────────────────────
# Each sync cycle that actually does work opens a dedicated file under
# /data/logs/sync/ and records structured key=value events at every
# major waypoint. Lets operators answer "what happened during that
# failed sync at 03:47?" without tailing the live add-on log or hoping
# the relevant lines haven't rotated out.
#
# Format (one event per line):
#   <ISO-timestamp> [<level>] event=<name> key=value key=value ...
#
# Hardcoded retention: SYNC_LOG_MAX_FILES = 20 (matches sprint plan).
# Pruning runs at close time, keeping the last 20 by mtime.
# ────────────────────────────────────────────────────────────────────

# Open a new per-sync log file. Called once per do_import cycle that
# has syncable changes (before any backup/copy/reload work).
#   $1 = LOCAL  sha (current /config state before the sync)
#   $2 = REMOTE sha (target state being synced in)
sync_log_open() {
    local local_sha="$1" remote_sha="$2"
    local fname_ts
    # Filename-safe ISO format (no colons — some operator workflows
    # mangle paths with colons; the in-line timestamp inside the log
    # uses standard ISO).
    fname_ts=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
    if ! mkdir -p "${SYNC_LOG_DIR}" 2>/dev/null; then
        bashio::log.warning "sync_log: failed to create ${SYNC_LOG_DIR} — per-sync log disabled this cycle"
        SYNC_LOG_FILE=""
        return 0
    fi
    SYNC_LOG_FILE="${SYNC_LOG_DIR}/${fname_ts}-${remote_sha:0:8}.log"
    sync_log INFO "event=sync_start local=${local_sha:0:8} remote=${remote_sha:0:8}"
}

# Append a structured event line to the current per-sync log file.
# No-op if no log is open (i.e. called outside an active sync cycle,
# or sync_log_open failed earlier).
#   $1 = level (INFO / WARN / ERROR)
#   $2+ = key=value tokens (caller responsible for formatting)
sync_log() {
    [ -z "${SYNC_LOG_FILE}" ] && return 0
    local level="$1"
    shift
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Append with fail-tolerant redirect — losing the log line shouldn't
    # break the sync.
    echo "${ts} [${level}] $*" >> "${SYNC_LOG_FILE}" 2>/dev/null || true
}

# Close the current per-sync log with a summary line and prune old
# files to retention limit. Idempotent — safe to call from multiple
# return paths.
#   $1 = result (success / failure)
sync_log_close() {
    [ -z "${SYNC_LOG_FILE}" ] && return 0
    local result="${1:-unknown}"
    sync_log INFO "event=sync_end result=${result}"
    SYNC_LOG_FILE=""
    # Prune oldest beyond SYNC_LOG_MAX_FILES. Pure mtime sort; no parsing
    # of filenames so it survives clock changes.
    if [ -d "${SYNC_LOG_DIR}" ]; then
        # shellcheck disable=SC2012  # ls -t is the right tool here
        ls -1t "${SYNC_LOG_DIR}" 2>/dev/null \
            | tail -n +$((SYNC_LOG_MAX_FILES + 1)) \
            | while IFS= read -r old; do
                rm -f "${SYNC_LOG_DIR}/${old}" 2>/dev/null || true
            done
    fi
}

# ────────────────────────────────────────────────────────────────────
#  Per-export structured log (v1.5.3, Sprint 4 P3)
# ────────────────────────────────────────────────────────────────────
# Mirror of the v1.4.1 import-side log, applied to do_export(). Each
# export cycle that has actual changes to push writes a dedicated file
# under /data/logs/export/ capturing the export waypoints as structured
# event=key=value lines. Cycles where nothing changed (the common case)
# produce no log file — matches the import-side discipline of staying
# quiet on no-ops.
#
# Format (one event per line): same as the import-side log.
# Retention: hardcoded SYNC_LOG_MAX_FILES (20), shared constant.
# Pruning runs at close time on a separate mtime sort over /data/logs/export.
# ────────────────────────────────────────────────────────────────────

# Open a new per-export log file. Called from do_export() AFTER the
# git diff --cached --quiet check proves there are real changes to push
# (no log noise on no-op cycles).
#   $1 = mode  ("initial" or "auto")
export_log_open() {
    local mode="$1"
    local fname_ts
    fname_ts=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
    if ! mkdir -p "${EXPORT_LOG_DIR}" 2>/dev/null; then
        bashio::log.warning "export_log: failed to create ${EXPORT_LOG_DIR} — per-export log disabled this cycle"
        EXPORT_LOG_FILE=""
        return 0
    fi
    EXPORT_LOG_FILE="${EXPORT_LOG_DIR}/${fname_ts}-export-${mode}.log"
    export_log INFO "event=export_start mode=${mode} branch=${EXPORT_BRANCH}"
}

# Append a structured event line to the current per-export log file.
# No-op if no log is open. Parallel to sync_log().
#   $1 = level (INFO / WARN / ERROR)
#   $2+ = key=value tokens
export_log() {
    [ -z "${EXPORT_LOG_FILE}" ] && return 0
    local level="$1"
    shift
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "${ts} [${level}] $*" >> "${EXPORT_LOG_FILE}" 2>/dev/null || true
}

# Close the current per-export log with a summary line and prune old
# files. Idempotent. Parallel to sync_log_close().
#   $1 = result (success / push_failed / no_pat / unknown)
export_log_close() {
    [ -z "${EXPORT_LOG_FILE}" ] && return 0
    local result="${1:-unknown}"
    export_log INFO "event=export_end result=${result}"
    EXPORT_LOG_FILE=""
    if [ -d "${EXPORT_LOG_DIR}" ]; then
        # shellcheck disable=SC2012  # ls -t is the right tool here
        ls -1t "${EXPORT_LOG_DIR}" 2>/dev/null \
            | tail -n +$((SYNC_LOG_MAX_FILES + 1)) \
            | while IFS= read -r old; do
                rm -f "${EXPORT_LOG_DIR}/${old}" 2>/dev/null || true
            done
    fi
}

# ────────────────────────────────────────────────────────────────────
#  Sync status emitter (v1.5.0)
# ────────────────────────────────────────────────────────────────────
# Publishes the most recent sync outcome to two places:
#   1. /data/sync_status.json — persistent JSON snapshot. Survives add-on
#      restart + upgrade. Holds lifetime counters (sync_count, failure_count).
#      Operator access: `docker exec ... cat /data/sync_status.json`.
#   2. sensor.config_sync_status — first-class HA state with attributes.
#      Can be put on a dashboard, triggered on, polled by agent-homeops
#      via the standard /core/api/states API.
#
# Single emitter (status_record) for both. Lifecycle helpers
# (status_mark_idle / _syncing / _success / _failure) wrap it for the
# canonical states. Both writes are best-effort — IO/API failures log
# WARN/DEBUG but NEVER block or break a sync.
# ────────────────────────────────────────────────────────────────────

# Read the persisted counters from STATUS_FILE. Echoes two space-
# separated numbers: "<sync_count> <failure_count>". Defaults to "0 0"
# if the file is missing, unparseable, or jq is unhappy.
status_load_counters() {
    if [ ! -f "${STATUS_FILE}" ]; then
        echo "0 0"
        return 0
    fi
    local sc fc
    sc=$(jq -r '.attributes.sync_count // 0' "${STATUS_FILE}" 2>/dev/null)
    fc=$(jq -r '.attributes.failure_count // 0' "${STATUS_FILE}" 2>/dev/null)
    [ -z "${sc}" ] && sc=0
    [ -z "${fc}" ] && fc=0
    echo "${sc} ${fc}"
}

# Record a sync status event. Writes /data/sync_status.json with the
# full payload, then POSTs to the HA sensor entity. Both writes are
# best-effort — failures log warnings but do not propagate.
#
#   $1 = state              ("idle" / "syncing" / "success" / "failed")
#   $2 = last_sha_short     (8 chars, or "" for idle)
#   $3 = last_strategy      ("reload_all" / "reload_all_plus_themes" /
#                            "core_restart" / "" for idle/syncing)
#   $4 = last_error         (string, or "" if not applicable)
#   $5 = last_backup_name   (string, or "" if not applicable)
#   $6 = last_log_file      (path, or "" if not applicable)
#   $7 = increment_sync     ("true" to bump sync_count, else "")
#   $8 = increment_failure  ("true" to bump failure_count, else "")
status_record() {
    local state="${1:-idle}"
    local last_sha="${2:-}"
    local last_strategy="${3:-}"
    local last_error="${4:-}"
    local last_backup="${5:-}"
    local last_log_file="${6:-}"
    local incr_sync="${7:-}"
    local incr_failure="${8:-}"

    local counters sc fc
    counters=$(status_load_counters)
    sc=$(echo "${counters}" | awk '{print $1}')
    fc=$(echo "${counters}" | awk '{print $2}')

    if [ "${incr_sync}" = "true" ]; then
        sc=$((sc + 1))
    fi
    if [ "${incr_failure}" = "true" ]; then
        fc=$((fc + 1))
    fi

    local ts icon
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    case "${state}" in
        success) icon="mdi:cloud-check" ;;
        failed)  icon="mdi:cloud-alert" ;;
        syncing) icon="mdi:cloud-sync" ;;
        *)       icon="mdi:cloud-sync" ;;
    esac

    # Build the JSON payload once; reuse for both disk + HA write.
    # jq -n is the only safe way — strings can contain quotes, newlines,
    # backslashes (error messages from check_config, especially).
    local payload
    payload=$(jq -nc \
        --arg state "${state}" \
        --arg last_sync_at "${ts}" \
        --arg last_sha_short "${last_sha}" \
        --arg last_strategy "${last_strategy}" \
        --arg last_error "${last_error}" \
        --arg last_backup_name "${last_backup}" \
        --arg last_log_file "${last_log_file}" \
        --argjson sync_count "${sc}" \
        --argjson failure_count "${fc}" \
        --arg friendly_name "Config Sync Status" \
        --arg icon "${icon}" \
        '{
            state: $state,
            attributes: {
                friendly_name: $friendly_name,
                icon: $icon,
                last_sync_at: $last_sync_at,
                last_sha_short: $last_sha_short,
                last_strategy: $last_strategy,
                last_error: $last_error,
                last_backup_name: $last_backup_name,
                last_log_file: $last_log_file,
                sync_count: $sync_count,
                failure_count: $failure_count
            }
        }' 2>/dev/null)

    if [ -z "${payload}" ]; then
        bashio::log.warning "status_record: failed to build JSON payload (jq error)"
        return 0
    fi

    # Write JSON snapshot to disk atomically (.tmp + rename) so a
    # partial-write doesn't poison the counter file.
    if ! echo "${payload}" > "${STATUS_FILE}.tmp" 2>/dev/null; then
        bashio::log.warning "status_record: failed to write ${STATUS_FILE}.tmp"
    else
        mv "${STATUS_FILE}.tmp" "${STATUS_FILE}" 2>/dev/null || true
    fi

    # Publish to HA sensor entity. Best-effort — sensor write failure
    # is a known harmless condition during HA restart (Sprint 3
    # /core/restart strategy), so log at DEBUG not WARN.
    if ! supervisor_api POST "/core/api/states/${STATUS_SENSOR_ENTITY}" "${payload}" > /dev/null; then
        bashio::log.debug "status_record: failed to publish to ${STATUS_SENSOR_ENTITY} (HA may be restarting)"
    fi
    return 0
}

# Lifecycle wrappers. Each takes the minimum args needed; the rest
# default to "" inside status_record.

status_mark_idle() {
    status_record "idle" "" "" "" "" "" "" ""
}

status_mark_syncing() {
    local target_sha="$1"
    status_record "syncing" "${target_sha:0:8}" "" "" "" "${SYNC_LOG_FILE}" "" ""
}

status_mark_success() {
    local target_sha="$1" strategy="$2" backup_name="$3"
    status_record "success" "${target_sha:0:8}" "${strategy}" "" "${backup_name}" "${SYNC_LOG_FILE}" "true" ""
}

# Failure path — bumps both sync_count and failure_count.
#   $1 = target_sha
#   $2 = stage  (e.g. "pre_sync_backup", "check_config", "post_sync_verify")
#   $3 = error_text (human-readable, shown in last_error attribute)
#   $4 = backup_name (or "" if not applicable / pre-backup failure)
status_mark_failure() {
    local target_sha="$1" stage="$2" error_text="$3" backup_name="$4"
    local err
    err="[${stage}] ${error_text}"
    status_record "failed" "${target_sha:0:8}" "" "${err}" "${backup_name}" "${SYNC_LOG_FILE}" "true" "true"
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
    local -a args=(-s
                   --max-time "${SUPERVISOR_API_TIMEOUT}"
                   --connect-timeout "${SUPERVISOR_API_CONNECT_TIMEOUT}"
                   -o "${SUPERVISOR_RESP_BODY_FILE}" -X "${method}"
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
# Complemented by check_sync_paths_gap() (v1.5.1) which runs the same
# style of check at EVERY sync and ABORTS the sync (vs warning-only).
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

# ────────────────────────────────────────────────────────────────────
#  sync_paths gap guard at sync time (v1.5.1, Sprint 4 P1)
# ────────────────────────────────────────────────────────────────────
# Checks whether THIS sync would silently drop files referenced by
# !include_dir_* directives in configuration.yaml. Catches the
# 2026-05-25 incident class structurally:
#
#   - configuration.yaml has `themes: !include_dir_merge_named themes/`
#   - themes/ is NOT in sync_paths (the gap)
#   - PR adds themes/*.yaml files
#   - Without this guard, the sync silently drops the themes/ files
#     (allowlist-correct), configuration.yaml references files HA
#     can't find on disk, frontend breaks
#
# Complementary to v1.1.7's audit_include_dir_directives() which only
# runs at add-on startup. A PR can land between add-on restarts and
# slip through that audit — this guard enforces at every sync.
#
# Returns 0 if no blocking gap, 1 if a gap should abort this sync.
# When strict_sync_paths_check=false (operator override), emits the
# same diagnostic ERROR but returns 0 (warning-only, v1.5.0 behavior).
check_sync_paths_gap() {
    # Pick the configuration.yaml to audit:
    #   - if it's in this sync's CHANGED list, use the incoming repo version
    #   - else use the currently-active /config version
    # Either way, the !include_dir_* directives in that file determine
    # which files HA expects to find on disk after the sync lands.
    local cfg
    if echo "${CHANGED}" | grep -qx 'configuration.yaml'; then
        cfg="${REPO_DIR}/configuration.yaml"
    elif [ -r "${CONFIG_DIR}/configuration.yaml" ]; then
        cfg="${CONFIG_DIR}/configuration.yaml"
    else
        # No configuration.yaml to audit, and no include_dir_* directives
        # to satisfy without one. Nothing to guard.
        return 0
    fi

    # Build the list of !include_dir_* target directories (normalized
    # with trailing slash for path_allowed probing).
    local include_dirs=()
    while IFS= read -r line; do
        local arg norm
        arg=$(echo "${line}" | sed -E 's/.*!include_dir_(named|list|merge_named|merge_list)[[:space:]]+"?([^"[:space:]#]+)"?.*/\2/')
        norm="${arg%/}/"
        include_dirs+=("${norm}")
    done < <(grep -E '!include_dir_(named|list|merge_named|merge_list)[[:space:]]+\S+' "${cfg}" 2>/dev/null || true)

    if [ "${#include_dirs[@]}" -eq 0 ]; then
        return 0
    fi

    # For each include_dir NOT in sync_paths, check if any file in this
    # sync's diff (CHANGED_ALL — broader set, includes already-skipped
    # files) lies under it. Collect (dir, file) pairs for the report.
    local gap_dirs=()
    local gap_files=()
    for d in "${include_dirs[@]}"; do
        # Probe path_allowed with a synthetic file inside d. The synthetic
        # suffix keeps us from accidentally matching a sync_paths entry
        # whose name happens to share a prefix with d.
        if path_allowed "${d}_audit_probe.yaml"; then
            continue
        fi
        while IFS= read -r f; do
            [ -z "${f}" ] && continue
            if [[ "${f}" == "${d}"* ]]; then
                gap_dirs+=("${d}")
                gap_files+=("${f}")
            fi
        done <<< "${CHANGED_ALL}"
    done

    if [ "${#gap_dirs[@]}" -eq 0 ]; then
        return 0
    fi

    # Dedupe directories for the report.
    local unique_dirs_str
    unique_dirs_str=$(printf '%s\n' "${gap_dirs[@]}" | sort -u | tr '\n' ' ')

    bashio::log.error "============================================================"
    if [ "${STRICT_SYNC_PATHS_CHECK}" = "true" ]; then
        bashio::log.error "SYNC ABORTED — sync_paths gap detected"
    else
        bashio::log.error "SYNC_PATHS GAP DETECTED (strict_sync_paths_check=false — continuing)"
    fi
    bashio::log.error "============================================================"
    bashio::log.error "configuration.yaml (${cfg}) has !include_dir_* directives"
    bashio::log.error "targeting directories NOT in sync_paths:"
    bashio::log.error "  ${unique_dirs_str}"
    bashio::log.error ""
    bashio::log.error "This sync would update configuration.yaml's references but"
    bashio::log.error "the sync_paths filter blocks ${#gap_files[@]} referenced file(s)"
    bashio::log.error "from reaching /config. HA will see configuration.yaml pointing"
    bashio::log.error "at files that don't exist on disk — frontend assets, themes,"
    bashio::log.error "or lovelace dashboards may break."
    bashio::log.error ""
    bashio::log.error "Affected files (first 10):"
    local i=0
    for f in "${gap_files[@]}"; do
        bashio::log.error "  - ${f}"
        i=$((i + 1))
        if [ "${i}" -ge 10 ]; then
            if [ "${#gap_files[@]}" -gt 10 ]; then
                bashio::log.error "  ... (${#gap_files[@]} total, list truncated)"
            fi
            break
        fi
    done
    bashio::log.error ""
    bashio::log.error "Fix: open the add-on Configuration tab, add these to sync_paths:"
    while IFS= read -r d; do
        bashio::log.error "    - \"${d}\""
    done < <(printf '%s\n' "${gap_dirs[@]}" | sort -u)
    bashio::log.error "Save the config and restart the add-on. The next sync will retry."
    bashio::log.error "============================================================"

    if [ "${STRICT_SYNC_PATHS_CHECK}" = "true" ]; then
        return 1
    fi
    return 0
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
        sync_log ERROR "event=backup name=${name} result=failed http_code=$(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)"
        return 1
    fi
    bashio::log.info "Pre-sync HA backup '${name}' triggered — Settings → System → Backups"
    sync_log INFO "event=backup name=${name} result=triggered"
    return 0
}

# Prune old gitops-pre-* HA backups, keeping only the most-recent
# PRE_SYNC_BACKUP_RETENTION (v1.5.2, Sprint 4 P2). Called after every
# sync cycle that took a backup, regardless of success or failure.
#
# The just-created backup is always in the "keep" set (it's the most
# recent by date), so a freshly-failed sync's restore point is never
# deleted in the same cycle that failed.
#
# Best-effort: list / delete failures log WARN but never propagate.
# If PRE_SYNC_BACKUP_RETENTION is 0, this is a no-op (v1.5.1 behavior).
prune_pre_sync_backups() {
    if [ "${PRE_SYNC_BACKUP_RETENTION}" -le 0 ]; then
        return 0
    fi

    local list_json
    if ! list_json=$(supervisor_api GET "/backups"); then
        bashio::log.debug "prune_pre_sync_backups: failed to list backups (HTTP $(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)) — will retry next cycle"
        return 0
    fi

    # Filter to gitops-pre-* by name, sort by date descending, drop the
    # first N (the keep set), emit slugs of the rest. jq's .[$keep:]
    # slice on an empty / nil list yields empty output safely.
    local doomed_slugs
    doomed_slugs=$(echo "${list_json}" | jq -r \
        --argjson keep "${PRE_SYNC_BACKUP_RETENTION}" \
        '(.data.backups // []) | map(select(.name | startswith("gitops-pre-"))) | sort_by(.date) | reverse | .[$keep:] | .[] | .slug' \
        2>/dev/null)

    if [ -z "${doomed_slugs}" ]; then
        # No prune candidates this cycle.
        return 0
    fi

    local deleted=0 failed=0
    while IFS= read -r slug; do
        [ -z "${slug}" ] && continue
        if supervisor_api DELETE "/backups/${slug}" > /dev/null; then
            deleted=$((deleted + 1))
            bashio::log.debug "prune_pre_sync_backups: deleted ${slug}"
        else
            failed=$((failed + 1))
            bashio::log.warning "prune_pre_sync_backups: failed to delete ${slug} (HTTP $(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???))"
        fi
    done <<< "${doomed_slugs}"

    if [ "${deleted}" -gt 0 ] || [ "${failed}" -gt 0 ]; then
        bashio::log.info "Pre-sync backup retention: pruned ${deleted}, failed ${failed} (keeping last ${PRE_SYNC_BACKUP_RETENTION})"
        sync_log INFO "event=backup_prune retention=${PRE_SYNC_BACKUP_RETENTION} deleted=${deleted} failed=${failed}"
    fi
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
        sync_log ERROR "event=verify probe=sun.sun result=fail http_code=$(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)"
        return 1
    fi
    sync_log INFO "event=verify probe=sun.sun result=pass"

    bashio::log.debug "Post-sync verify: probe 2/2 — /core/api/ auth + responsiveness"
    if ! supervisor_api GET "/core/api/" > /dev/null; then
        log_supervisor_error "Post-sync probe 2 FAILED: /core/api/ unresponsive or auth rejected"
        bashio::log.error "  Possible causes: auth provider broken, frontend assets missing,"
        bashio::log.error "  integration crashed during reload. THIS IS THE 2026-05-25 BUG CLASS."
        sync_log ERROR "event=verify probe=core_api result=fail http_code=$(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)"
        return 1
    fi
    sync_log INFO "event=verify probe=core_api result=pass"

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
    sync_log INFO "event=reconcile copied=${reconcile_count} failed=${cp_failure_count}"
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

# ────────────────────────────────────────────────────────────────────
#  Repo-host allowlist guard (v1.6.0, Sprint 5 P1, M7)
# ────────────────────────────────────────────────────────────────────
# Validates that github_repo points at a hostname in ALLOWED_REPO_HOSTS.
# Defends against the case where the operator misconfigures (or is
# socially engineered to set) github_repo to a non-GitHub URL — without
# this guard, the add-on would happily embed the PAT in that URL and
# send it on first clone or fetch.
#
# Subdomain matches are allowed via suffix-match: "github.com" in the
# allowlist permits api.github.com, raw.githubusercontent.com, etc.
# Operators on GitHub Enterprise add their GHE hostname to the list.
#
# Called once at startup. Exits the add-on with an error if the host
# is not in the allowlist (a config error should be loud).
check_repo_host_allowed() {
    # Strip scheme and path with bash parameter expansion (no sed fork).
    local repo_host="${REPO#*://}"
    repo_host="${repo_host%%/*}"
    # Also strip any embedded user@ in case PAT got included by mistake.
    repo_host="${repo_host##*@}"

    if [ -z "${repo_host}" ]; then
        bashio::log.error "Unable to extract host from github_repo='${REPO}' — refusing to start"
        exit 1
    fi

    local h
    for h in "${ALLOWED_REPO_HOSTS[@]}"; do
        if [[ "${repo_host}" == "${h}" ]] || [[ "${repo_host}" == *".${h}" ]]; then
            bashio::log.info "github_repo host '${repo_host}' allowed (matches '${h}' in allowed_repo_hosts)"
            return 0
        fi
    done

    bashio::log.error "============================================================"
    bashio::log.error "REFUSING TO START — github_repo host not in allowlist"
    bashio::log.error "============================================================"
    bashio::log.error "github_repo points at '${repo_host}', but allowed_repo_hosts is:"
    local h_show
    for h_show in "${ALLOWED_REPO_HOSTS[@]}"; do
        bashio::log.error "  - ${h_show}"
    done
    bashio::log.error ""
    bashio::log.error "This is a security guard added in v1.6.0. Without it, a"
    bashio::log.error "misconfigured github_repo URL would send the GitHub PAT to"
    bashio::log.error "an arbitrary host on first clone/fetch."
    bashio::log.error ""
    bashio::log.error "If '${repo_host}' is a host you trust (e.g. your GitHub"
    bashio::log.error "Enterprise instance), add it to the allowed_repo_hosts"
    bashio::log.error "config option in the add-on Configuration tab, save, and"
    bashio::log.error "restart the add-on."
    bashio::log.error "============================================================"
    exit 1
}

# ────────────────────────────────────────────────────────────────────
#  Tracked-symlink guard at sync time (v1.6.0, Sprint 5 P1, M6)
# ────────────────────────────────────────────────────────────────────
# Aborts the sync if any file tracked in the repo AND matching
# sync_paths is a symlink (relative to REPO_DIR). Defends against the
# case where a commit replaces automations.yaml with a symlink to
# /etc/passwd or /data/sync_status.json — without this guard, the
# subsequent cp would either read sensitive files (low impact since
# the add-on is already container-elevated) or overwrite them with
# arbitrary content from the commit.
#
# Only checks files inside sync_paths; non-synced tracked files can be
# anything (we're not going to copy them).
#
# Returns 0 if no blocking symlinks, 1 if any should abort this sync.
# Honors BLOCK_SYMLINKS config: when "false", same diagnostic ERROR
# but returns 0 (warning-only, v1.5.x behavior).
check_no_tracked_symlinks() {
    local symlinks=()
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        if ! path_allowed "${f}"; then
            continue
        fi
        if [ -L "${REPO_DIR}/${f}" ]; then
            symlinks+=("${f}")
        fi
    done < <(cd "${REPO_DIR}" && git ls-files 2>/dev/null)

    if [ "${#symlinks[@]}" -eq 0 ]; then
        return 0
    fi

    bashio::log.error "============================================================"
    if [ "${BLOCK_SYMLINKS}" = "true" ]; then
        bashio::log.error "SYNC ABORTED — tracked symlinks detected in sync_paths"
    else
        bashio::log.error "TRACKED SYMLINKS DETECTED (block_symlinks=false — continuing)"
    fi
    bashio::log.error "============================================================"
    bashio::log.error "The following tracked files are symlinks in ${REPO_DIR}:"
    local s
    local count=0
    for s in "${symlinks[@]}"; do
        local target
        target=$(readlink "${REPO_DIR}/${s}" 2>/dev/null || echo "(unreadable)")
        bashio::log.error "  - ${s} -> ${target}"
        count=$((count + 1))
        if [ "${count}" -ge 10 ]; then
            if [ "${#symlinks[@]}" -gt 10 ]; then
                bashio::log.error "  ... (${#symlinks[@]} total, list truncated)"
            fi
            break
        fi
    done
    bashio::log.error ""
    bashio::log.error "Symlinks in tracked config files are a path-traversal vector."
    bashio::log.error "On sync, cp would follow the symlink and either read the"
    bashio::log.error "target (information disclosure) or overwrite it with commit"
    bashio::log.error "content (integrity attack). HA itself also has trouble with"
    bashio::log.error "symlinks in /config — they're usually accidents, not intent."
    bashio::log.error ""
    bashio::log.error "Fix: replace the symlinks with regular files in your repo,"
    bashio::log.error "or set block_symlinks=false in the add-on config if you"
    bashio::log.error "intentionally use symlinks and accept the risk."
    bashio::log.error "============================================================"

    if [ "${BLOCK_SYMLINKS}" = "true" ]; then
        return 1
    fi
    return 0
}

# ── Git setup ─────────────────────────────────────────────────────

# Validate github_repo host before any clone/fetch (v1.6.0, M7).
# Exits the add-on on failure — a misconfigured repo URL is a fatal
# startup error, not a recoverable runtime issue.
check_repo_host_allowed

# Configure git identity for export commits
git config --global user.name "HA Config Sync"
git config --global user.email "config-sync@homeassistant.local"

# ── Initial clone ──────────────────────────────────────────────────
if [ ! -d "${REPO_DIR}/.git" ]; then
    bashio::log.info "First run — cloning ${REPO} (branch: ${BRANCH})"
    CLONE_URL="${REPO}"
    if [ -n "${PAT}" ]; then
        # v1.5.4 (M4): bash parameter expansion replaces sed.
        # sed delimiter "|" would break if PAT ever contained |, &, or /;
        # bash ${var/pattern/repl} substitutes literally, no fork to sed.
        CLONE_URL="${REPO/https:\/\//https:\/\/${PAT}@}"
    fi
    git clone --branch "${BRANCH}" --single-branch "${CLONE_URL}" "${REPO_DIR}"
    bashio::log.info "Clone complete"
fi

# Ensure remote URL has current PAT
if [ -n "${PAT}" ]; then
    # v1.5.4 (M4): bash parameter expansion replaces sed. See CLONE_URL above.
    AUTH_URL="${REPO/https:\/\//https:\/\/${PAT}@}"
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

# Seed the sync status sensor + JSON snapshot on startup (v1.5.0).
# State = idle; counters preserved from prior runs if the file exists.
# This makes sensor.config_sync_status available in HA immediately,
# even before the first real sync cycle runs.
status_mark_idle

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
                    rel="${src#"${CONFIG_DIR}"/}"
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

    # Real changes to push — open per-export structured log (v1.5.3).
    # No log file for no-op cycles, matching the import-side discipline.
    export_log_open "${label}"

    # Commit with timestamp
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local files_changed files_count files_csv
    files_changed=$(git diff --cached --name-only | tr '\n' ' ')
    files_count=$(git diff --cached --name-only | wc -l | tr -d ' ')
    files_csv=$(git diff --cached --name-only | tr '\n' ',' | sed 's/,$//')
    export_log INFO "event=files_staged count=${files_count} paths=${files_csv}"

    git commit -m "${EXPORT_MSG} (${ts})" -m "Files: ${files_changed}" --quiet
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    export_log INFO "event=commit sha=${commit_sha:0:8} files=${files_count}"

    bashio::log.info "Export (${label}): committed ${files_changed}"

    # Push
    if [ -z "${PAT}" ]; then
        bashio::log.warning "Export: no github_pat configured — cannot push (read-only)"
        export_log WARN "event=push branch=${EXPORT_BRANCH} result=skipped reason=no_pat"
        export_log_close no_pat
        checkout_back_to_sync_branch || true
        return 1
    fi

    local push_output
    if push_output=$(git push origin "${EXPORT_BRANCH}" 2>&1); then
        bashio::log.info "Export (${label}): pushed to origin/${EXPORT_BRANCH}"
        date -u '+%s' > "${LAST_EXPORT_TS}"
        export_log INFO "event=push branch=${EXPORT_BRANCH} result=success"
        export_log_close success
    else
        bashio::log.error "Export (${label}): push failed — $(sanitize_output "${push_output}")"
        # Truncate push error to keep the log line bounded; sanitize_output
        # strips the PAT from credential URLs.
        local push_err_short
        push_err_short=$(sanitize_output "${push_output}" | tr '\n' ' ' | head -c 200)
        export_log ERROR "event=push branch=${EXPORT_BRANCH} result=failed error=\"${push_err_short}\""
        export_log_close push_failed
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

    # Open the per-sync structured log file for this cycle. All
    # subsequent sync_log calls land in this file. Closed at every
    # return point below.
    sync_log_open "${LOCAL}" "${REMOTE}"

    # Mark sensor.config_sync_status = "syncing" before any work begins,
    # so HA dashboards / automations see the in-progress state. Done
    # AFTER sync_log_open so the last_log_file attribute is populated.
    status_mark_syncing "${REMOTE}"

    # ── sync_paths gap guard (v1.5.1, Sprint 4 P1) ────────────────────
    # Abort BEFORE any backup or filesystem write if this sync would
    # silently drop files referenced by configuration.yaml's
    # !include_dir_* directives. Catches the 2026-05-25 incident class
    # at sync time (vs the v1.1.7 startup-only warning). Honors the
    # strict_sync_paths_check config option; when false, the check
    # emits the same ERROR but returns 0 and the sync continues.
    if ! check_sync_paths_gap; then
        sync_log ERROR "event=sync_paths_gap result=abort"
        notify_sync_failure \
            "Config Sync: sync_paths gap blocking sync" \
            "configuration.yaml references files under directories not in sync_paths, and this sync would silently drop them. See add-on log for the missing directories and a copy-paste fix (add them to sync_paths and restart the add-on). Sync aborted; will keep retrying."
        status_mark_failure "${REMOTE}" "sync_paths_gap" \
            "configuration.yaml references files under directories not in sync_paths; sync aborted to prevent silent file drop. See add-on log for the fix recipe." \
            ""
        sync_log_close failure
        # Roll back git state so the next cycle retries the same SHA
        # once the operator has added the missing directories to sync_paths.
        git reset --hard "${LOCAL}"
        return 1
    fi

    # ── tracked-symlink guard (v1.6.0, Sprint 5 P1, M6) ──────────────
    # Abort BEFORE backup/copy if the incoming repo state contains
    # symlinks in any sync_paths file. cp would otherwise follow them
    # and potentially read or overwrite sensitive paths via the synced
    # /config location. Honors block_symlinks config option; when false,
    # logs the ERROR but allows the sync to continue (v1.5.x behavior).
    if ! check_no_tracked_symlinks; then
        sync_log ERROR "event=tracked_symlinks result=abort"
        notify_sync_failure \
            "Config Sync: tracked symlinks blocking sync" \
            "The repo contains symlinks in tracked sync_paths files (path-traversal vector). Sync aborted to prevent cp from following them. See add-on log for the list of symlinks. Fix by replacing with regular files in the repo, or set block_symlinks=false in the add-on config if intentional."
        status_mark_failure "${REMOTE}" "tracked_symlinks" \
            "Tracked files in sync_paths are symlinks; aborted to prevent path traversal via cp. See add-on log for the list and fix recipe." \
            ""
        sync_log_close failure
        git reset --hard "${LOCAL}"
        return 1
    fi

    # Deterministic backup name — also referenced by failure paths
    # in the status_mark_failure attribute payload.
    local backup_name="gitops-pre-${REMOTE:0:8}"

    bashio::log.info "Import: syncing $(echo "${CHANGED}" | tr '\n' ' ')"
    sync_log INFO "event=files_changed count=$(echo "${CHANGED}" | wc -l | tr -d ' ') paths=$(echo "${CHANGED}" | tr '\n' ',' | sed 's/,$//')"

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
        status_mark_failure "${REMOTE}" "pre_sync_backup" \
            "Supervisor backups/new/partial API rejected the request (HTTP $(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)); sync aborted" \
            ""
        sync_log_close failure
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
        sync_log ERROR "event=check_config result=api_failed http_code=$(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)"
        status_mark_failure "${REMOTE}" "check_config_api" \
            "Supervisor check_config endpoint did not respond (HTTP $(cat "${SUPERVISOR_RESP_CODE_FILE}" 2>/dev/null || echo ???)); rolled back to ${LOCAL:0:8}" \
            "${backup_name}"
        prune_pre_sync_backups
        sync_log_close failure
        return 1
    }

    VALID=$(echo "${CHECK_RESULT}" | jq -r '.result // empty' 2>/dev/null)

    if [ "${VALID}" = "valid" ]; then
        sync_log INFO "event=check_config result=valid"
        # ── Reload-strategy selection (Sprint 3) ─────────────────────
        # Pick the right way to apply the new config based on what changed:
        #   - lovelace touched  → /core/restart (re-registers dashboards)
        #   - themes touched    → reload_all + frontend.reload_themes
        #   - everything else   → reload_all (lightest, current default)
        #
        # See sync_touches_lovelace() / sync_touches_themes() for the
        # detection heuristics. Logged so the operator can see WHY a
        # given strategy was used. reload_strategy_key is the canonical
        # short form used by the status sensor + per-sync log; the
        # human-readable reload_strategy is for log messages only.
        local reload_strategy reload_strategy_key reload_settle
        if [ "${RESTART_ON_LOVELACE_CHANGE}" = "true" ] && sync_touches_lovelace; then
            reload_strategy="/core/restart"
            reload_strategy_key="core_restart"
            reload_settle=$((POST_SYNC_SETTLE + RESTART_EXTRA_SETTLE))
            bashio::log.info "Import: configuration.yaml lovelace block changed — calling /core/restart (reload_all does NOT re-register dashboards)"
            sync_log INFO "event=reload strategy=core_restart reason=lovelace_changed"
            if ! supervisor_api POST "/core/api/services/homeassistant/restart" > /dev/null; then
                log_supervisor_error "/core/restart API call failed"
                bashio::log.warning "  Manual HA restart may be needed for lovelace dashboards to register."
                sync_log WARN "event=reload_call result=failed strategy=core_restart"
            fi
        elif sync_touches_themes; then
            reload_strategy="reload_all + frontend.reload_themes"
            reload_strategy_key="reload_all_plus_themes"
            reload_settle="${POST_SYNC_SETTLE}"
            bashio::log.info "Import: themes/ files changed — calling reload_all + frontend.reload_themes"
            sync_log INFO "event=reload strategy=reload_all_plus_themes reason=themes_changed"
            if ! supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null; then
                log_supervisor_error "reload_all API call failed — HA may not have picked up the changes"
                bashio::log.warning "  Continuing to post-sync probes; they will catch any actual breakage."
                sync_log WARN "event=reload_call result=failed strategy=reload_all"
            fi
            if ! supervisor_api POST "/core/api/services/frontend/reload_themes" > /dev/null; then
                log_supervisor_error "frontend.reload_themes API call failed — new themes may not activate until next HA restart"
                sync_log WARN "event=reload_call result=failed strategy=reload_themes"
            fi
        else
            reload_strategy="reload_all"
            reload_strategy_key="reload_all"
            reload_settle="${POST_SYNC_SETTLE}"
            bashio::log.info "Import: config valid — reloading Home Assistant"
            sync_log INFO "event=reload strategy=reload_all reason=default"
            if ! supervisor_api POST "/core/api/services/homeassistant/reload_all" > /dev/null; then
                log_supervisor_error "reload_all API call failed — HA may not have picked up the changes"
                bashio::log.warning "  Continuing to post-sync probes; they will catch any actual breakage."
                sync_log WARN "event=reload_call result=failed strategy=reload_all"
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
            status_mark_failure "${REMOTE}" "post_sync_verify" \
                "Post-${reload_strategy_key} health probes failed; rolled back to ${LOCAL:0:8}. Restore backup ${backup_name} if HA is still broken." \
                "${backup_name}"
            prune_pre_sync_backups
            sync_log_close failure
            return 1
        fi

        rm -rf "${BACKUP}"
        # Mark that we just imported — export should skip next cycle
        git rev-parse HEAD > "${LAST_IMPORT_MARKER}"
        # Healthy sync completed — dismiss any prior failure notification
        # so the operator's UI is clean.
        notify_sync_recovered
        # Publish success to sensor.config_sync_status BEFORE close so
        # the sensor's last_log_file attribute still references the
        # active log file path. sync_log_close clears SYNC_LOG_FILE.
        status_mark_success "${REMOTE}" "${reload_strategy_key}" "${backup_name}"
        sync_log_close success
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
        # check_config-invalid path falls through to the cleanup below
        # then returns 0 from do_import (we recovered cleanly). Per-sync
        # log records the failure outcome.
        sync_log ERROR "event=check_config result=invalid"
        status_mark_failure "${REMOTE}" "check_config_invalid" \
            "HA's check_config rejected ${REMOTE:0:8}: ${ERROR_MSG}" \
            "${backup_name}"
        sync_log_close failure
    fi

    # Clean old rollback dirs (keep last 5)
    if [ -d "${ROLLBACK_DIR}" ]; then
        ls -1t "${ROLLBACK_DIR}" 2>/dev/null | tail -n +6 | while read -r old; do
            rm -rf "${ROLLBACK_DIR:?}/${old}"
        done
    fi

    # Prune old gitops-pre-* HA backups (v1.5.2, Sprint 4 P2). Runs on
    # both success and check_config-invalid fall-through paths. The
    # early-return failure paths (post_sync_verify, check_config_api)
    # have their own prune calls inline. Sync_paths_gap + pre_sync_backup
    # early aborts never created a backup so nothing to prune.
    prune_pre_sync_backups

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
