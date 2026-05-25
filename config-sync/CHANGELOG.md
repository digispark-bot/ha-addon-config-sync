# Changelog

## 1.5.0

Sprint 4 P0 from the hardening plan (see issue #9): expose sync state as
a first-class HA sensor entity so operators, automations, and agents can
subscribe to sync outcomes without scraping the rolling add-on log.

- **Feature (Sprint 4 P0)**: After every sync cycle (success or failure),
  the add-on publishes the outcome to TWO places:
  - `sensor.config_sync_status` — first-class HA entity via
    `POST /core/api/states/sensor.config_sync_status`. Appears in HA
    natively (Developer Tools → States) and can be added to any dashboard
    (recommended: tile card). Subscribable by automations — e.g. trigger
    a Telegram notification when state goes to `failed`. Polled by
    `agent-homeops` via the standard `/core/api/states/<entity>` endpoint.
  - `/data/sync_status.json` — persistent JSON snapshot inside the add-on
    container. Survives add-on restart + upgrade. Used to restore
    lifetime counters on next boot, and for headless / non-HA-accessible
    tooling that needs the same data via `docker exec`.
- **State machine**: `idle` (boot, seeded once on add-on start) →
  `syncing` (set at start of every do_import cycle that has changes) →
  `success` | `failed` (set at the end of that cycle). The `syncing`
  state gives dashboards a real-time view of work-in-progress; the
  terminal states persist between cycles so the sensor always reflects
  the most recent outcome.
- **Attributes published with every state change**:
  - `friendly_name`: "Config Sync Status"
  - `icon`: `mdi:cloud-check` (success), `mdi:cloud-alert` (failed),
    `mdi:cloud-sync` (idle / syncing). Operator sees obvious red/green
    at-a-glance.
  - `last_sync_at`: UTC ISO-8601 timestamp.
  - `last_sha_short`: 8-char target commit SHA.
  - `last_strategy`: `reload_all` | `reload_all_plus_themes` |
    `core_restart` (matches the Sprint 3 reload-strategy keys).
  - `last_error`: human-readable error text on failure, with a
    `[stage]` prefix identifying where in the pipeline the failure
    occurred (`pre_sync_backup`, `check_config_api`,
    `check_config_invalid`, `post_sync_verify`).
  - `last_backup_name`: name of the most recent pre-sync HA backup
    (e.g. `gitops-pre-abc12345`), so the operator can copy-paste it
    straight from the sensor attribute into Settings → System →
    Backups for a one-click restore on catastrophic failure.
  - `last_log_file`: path to the v1.4.1 per-sync structured log file
    for the most recent run (e.g.
    `/data/logs/sync/2026-05-25T19-30-00Z-abc12345.log`). Direct
    pointer to the full event trace for the surfaced state.
  - `sync_count`: lifetime counter; bumps on every cycle that did
    real work (success OR failure), preserved across add-on restart
    via the JSON snapshot.
  - `failure_count`: lifetime counter; bumps only on failure.
    Operators can compute the failure rate from these two numbers.
- **New helpers**: `status_record()` is the single emitter; lifecycle
  wrappers (`status_mark_idle`, `status_mark_syncing`,
  `status_mark_success`, `status_mark_failure`) call it with the
  right state and bump flags. `status_load_counters()` reads
  persisted counters from the JSON snapshot at every cycle so the
  count is durable across add-on restart.
- **Resilience**: Both the disk write (`echo > .tmp && mv`) and the
  sensor publish (`supervisor_api POST`) are best-effort. Failures
  log a `WARN` (disk) or `DEBUG` (sensor — expected during HA
  restart in the Sprint 3 strategy) and never propagate. Status
  reporting must never block or break a sync.
- **No new config options**; no schema changes. No new permissions —
  `homeassistant_api: true` already grants
  `POST /core/api/states/sensor.*`. Comment in `config.yaml` updated
  to document the new endpoint use.
- **Recommended dashboard card**:
  ```yaml
  type: tile
  entity: sensor.config_sync_status
  show_entity_picture: false
  ```

## 1.4.1

Sprint 3 P1 from the hardening plan (see issue #9): per-sync structured log
file so operators can reconstruct exactly what happened during any past
sync without scraping the rolling add-on log.

- **Feature (Sprint 3 P1)**: Each sync cycle that has changes writes a
  dedicated log file under `/data/logs/sync/` named
  `<UTC-timestamp>-<remote-short-sha>.log`. Captures every major
  waypoint with structured `event=` keys: `sync_start`, `files_changed`,
  `backup`, `reconcile`, `check_config`, `reload`, `verify`, `sync_end`.
  Lines are timestamped UTC ISO-8601 and prefixed with a level tag
  (INFO / WARN / ERROR).
- **New helpers**: `sync_log_open()` creates the file and writes the
  `sync_start` line. `sync_log LEVEL msg` appends one line. `sync_log_close
  RESULT` writes the `sync_end` line and rotates the directory down to the
  most-recent 20 files. All three are no-ops if the log file path is unset,
  so cycles with no changes produce no log noise.
- **Storage**: `/data/` is the add-on's persistent storage (survives
  restart + upgrade). Logs are container-internal — operator access is via
  `docker exec -it addon_<slug>_config-sync ls -lt /data/logs/sync/`.
  Hardcoded retention of 20 files (oldest auto-deleted) keeps the
  footprint bounded; typical file size is ~2 KB so worst-case retained
  log volume is ~40 KB.
- **Resilience**: If `mkdir` on the log directory fails, the cycle logs a
  WARNING and continues — per-sync logging is best-effort and never blocks
  a sync. Per-line writes use `>> file 2>/dev/null || true` so a transient
  IO error doesn't crash the loop.
- **No new config options**; no schema changes. Operators who don't want
  per-sync logs can simply ignore the directory (it's tiny).

## 1.4.0

Sprint 3 P0 from the hardening plan (see issue #9): pick the right
reload strategy automatically so the 2026-05-25 incident class (lovelace
dashboards needed manual restart after sync) never recurs.

- **Feature (Sprint 3 P0)**: Three-way reload-strategy selection in
  `do_import()` after check_config validates:
  - `/core/restart` (heavy, ~30s downtime) when the diff touches the
    lovelace key in `configuration.yaml`. `reload_all` does NOT
    re-register `lovelace.dashboards` entries — this was the bug from
    the 2026-05-25 incident.
  - `reload_all` + `frontend.reload_themes` when any `themes/` file
    changed but lovelace didn't. Reloads YAML domains and refreshes
    the theme registry.
  - `reload_all` (lightest, default) for everything else. Unchanged
    behavior for the typical case.
- **New helpers**: `sync_touches_lovelace()` uses `git diff LOCAL..REMOTE
  -- configuration.yaml` to detect any `+/-` line matching `/lovelace/i`.
  `sync_touches_themes()` checks if `^themes/` appears in `CHANGED`.
  Both are cheap (one git diff, one grep) and emit no log noise on
  the common case.
- **New option**: `restart_on_lovelace_change: bool` (default `true`).
  Operators on latency-sensitive setups can disable to revert to
  `reload_all` for lovelace changes (with the known caveat that
  dashboards won't re-register until manual restart).
- **Adaptive post-sync settle**: when the chosen strategy is restart,
  the post-sync settle window grows by 25s (default total: 30s) so
  HA has time to come back from the full restart before the health
  probes run.
- **Failure-notification message** updated to include the actual
  strategy ("Applied /core/restart for…" vs "Applied reload_all for…")
  so the operator immediately knows what was attempted.
- No breaking changes; new option defaults to true so existing
  deployments get the heuristic automatically on update.

## 1.3.1

Sprint 2 P1 follow-up to v1.3.0 — surface sync failures in the HA UI so
operators don't have to tail the add-on log to notice problems.

- **Feature**: Persistent notification in the HA UI when a sync fails.
  Single notification (id: `config_sync_failure`) updates on each new
  failure and auto-dismisses on the next successful sync. Operators see
  exactly one notification reflecting the LATEST sync state.
- **New option**: `notify_on_failure: bool` (default `true`). Set to
  `false` for headless deployments where UI clutter is unwanted.
- **Wired into all failure paths**:
  - Pre-sync backup API failure → "Config Sync: pre-sync backup failed"
  - `check_config` API unreachable → "Config Sync: check_config API unreachable"
  - `check_config` returned invalid → "Config Sync: check_config rejected the new config"
  - Post-sync verification failure → "Config Sync: post-sync verification failed" (includes the named backup to restore)
- **New helpers**: `notify_sync_failure()` + `notify_sync_recovered()`
  use `jq` to safely build the JSON body (handles quotes, newlines,
  backslashes in error messages without breakage). Notification API
  failures are logged WARN but don't cascade.
- No schema-breaking change; `notify_on_failure` defaults to true so
  existing deployments get the feature automatically on update.

## 1.3.0

Sprint 2 of the hardening plan (see issue #9): eliminate silent and
opaque failures across `do_import()` and `do_export()`. Closes #2.

- **Fix (closes #2)**: New `reconcile_tracked_files()` pass runs after the
  diff-based file copy in every sync that has changes. Walks every
  tracked file matching `sync_paths` and copies any that are missing
  from `/config`. Catches the bug class where a tracked-but-never-
  modified file fails to materialize because it wasn't in any diff —
  configuration.yaml's `!include` against it then fails check_config,
  rolling back the sync forever. Eliminates the workaround chain from
  the M5.6 deploy ([JLay2026/home-assistant-config#2/#3/#4](https://github.com/JLay2026/home-assistant-config)).
- **Fix (Sprint 2 P0)**: Race condition in `stage_config_to_repo()`
  where `find | while read; do changed=1; done` ran the while loop
  in a subshell, so `changed=1` never propagated. Function always
  returned 0 regardless of what changed. Replaced pipe with process
  substitution `< <(find ...)`. Also fixed a `find` argument-precedence
  bug that matched any `*.yml` regardless of file type.
- **Fix (Sprint 2 P1 audit)**: Both `reload_all` API calls in
  `do_import()` previously used `> /dev/null 2>&1 || true`, silently
  swallowing failures. Now they check the return value and call
  `log_supervisor_error()` (with HTTP code + Supervisor response body)
  on failure. Doesn't abort — post-sync probes catch real breakage
  downstream — but operators now see WHEN and WHY reload_all failed.
- **Fix (Sprint 2 P1 audit)**: Three `git checkout "${BRANCH}" --quiet
  2>/dev/null || true` calls in `do_export()` extracted into a single
  `checkout_back_to_sync_branch()` helper. Captures `git checkout`
  stderr via `2>&1`, logs WARNING on failure with PAT scrubbed via
  `sanitize_output()`. Failure leaves the next import cycle on the
  wrong branch — now visible in the log instead of silently desyncing.
- **Improvement**: Branch-switch logic in `do_export()` startup now
  properly chains: try direct checkout → fall back to `-b` create →
  log ERROR on both-failed (was silent fall-through to commit-on-wrong-branch).
- **No new config options**; no schema changes; reverse-compat with v1.2.x.

## 1.2.1

- **Fix (P0)**: Grant `hassio_api: true` + `hassio_role: backup` so the
  v1.2.0 pre-sync HA backup call to `POST /backups/new/partial` actually
  succeeds. Without these permissions, the Supervisor rejected every
  backup attempt and the add-on entered a rollback loop on every sync
  cycle (production sync fully blocked). See issue #8 for the
  incident timeline + Sprint 1 from issue #9.
- **Fix (P0)**: `supervisor_api()` now captures HTTP status code + response
  body via temp files (`/tmp/.sup_resp_body`, `/tmp/.sup_resp_code`).
  Replaces `curl -sf` (silently discards body on non-2xx) with `curl -s
  -o file -w "%{http_code}"`. Temp-file approach is subshell-safe —
  the parent shell can read the diagnostic info even after
  `var=$(supervisor_api ...)` runs the function in a subshell.
- **New helper**: `log_supervisor_error()` prints HTTP code + truncated
  (500 char) response body in a single log line. Used by every
  diagnostic-needing failure path so operators see WHY a Supervisor
  call failed, not just THAT it did.
- **Applied diagnostic capture to**:
  - `ha_backup_pre_sync()` error path — includes HTTP-code → likely-cause
    cheat sheet (401/403 → permissions; 4xx → schema; 5xx → Supervisor)
  - `post_sync_verify()` both probes (sun.sun + /core/api/)
  - `do_import()` `check_config` API call
- **Backwards compat**: `supervisor_api()` still echoes the body to stdout
  (existing `$(supervisor_api ...)` callers work unchanged). Return code
  semantics preserved: 0 on 2xx, non-zero on non-2xx; transport errors
  now distinguishable via HTTP code "000".

## 1.2.0

- **Feature (safety)**: Before any `/config/` write, take a partial HA
  backup via the Supervisor API named `gitops-pre-<short_sha>` covering
  the `homeassistant` folder. If the backup API returns non-2xx, abort
  the sync and roll the local git state back to the pre-merge SHA so
  the next cycle retries. Storage-level safety net for the class of
  failure where file-level rollback can't recover (e.g. .storage/
  corruption). See issue #4.
- **Feature (safety)**: After `reload_all`, sleep `post_sync_settle_seconds`
  (new config option, default 5s) and then run two health probes against
  the Supervisor Core API:
  - `GET /core/api/states/sun.sun` — state machine alive
  - `GET /core/api/` — auth + REST responsive
  Either probe failing triggers file-level rollback, a best-effort
  re-reload, and a prominent ERROR block pointing the operator at
  the pre-sync HA backup for storage-level restore. Catches the
  bug class where check_config passes but reload breaks HA (e.g.
  the [JLay2026/nanoclaw-zimaos#50](https://github.com/JLay2026/nanoclaw-zimaos/issues/50)
  2026-05-25 incident — frontend rendering failure with valid YAML).
  See issue #5.
- **New option**: `post_sync_settle_seconds: int(0,60)` (default 5).
  Bump for slow HA setups; 0 disables the settle delay (probes run
  immediately after reload_all returns).
- **Helper extension**: `supervisor_api()` now accepts an optional third
  argument (JSON body) so the backup API call can POST a request body.
  Existing callers (check_config, reload_all, states) are unchanged.

## 1.1.7

- **Feature**: At startup, scan `configuration.yaml` for `!include_dir_*`
  directives targeting directories not in `sync_paths`, and emit a WARNING
  for each gap. Catches the class of incident where a PR adds files under
  a directory not in the allowlist — the add-on silently skips them, HA
  references them, frontend assets break. See issue #3 (and the
  [JLay2026/nanoclaw-zimaos#50](https://github.com/JLay2026/nanoclaw-zimaos/issues/50)
  incident from 2026-05-25 for the motivating case).
- New `audit_include_dir_directives()` helper using `grep` + `sed` +
  the existing `path_allowed()` allowlist function. No new runtime
  dependencies.

## 1.1.6

- **Fix**: Log actual git push/fetch error messages instead of swallowing
  stderr with `2>/dev/null` — PAT is sanitized from output
- Added `sanitize_output()` helper to strip credentials from log messages

## 1.1.5

- **Feature**: Add `scripts/` directory to default `sync_paths` so
  script files split into a directory are synced alongside `scripts.yaml`

## 1.1.4

- **Fix**: Add `homeassistant_api: true` to config.yaml so the add-on
  can call HA Core's `check_config` and `reload_all` endpoints
  (fixes "check-config API unreachable" errors)

## 1.1.3

- **Fix**: Use `#!/usr/bin/with-contenv bash` shebang to get Supervisor
  token and container environment (fixes "Unable to access the API,
  forbidden" errors from bashio)
- **Fix**: Set `$HOME` before `git config --global` to prevent
  "fatal: $HOME not set" error

## 1.1.2

- **Fix**: Replace `#!/usr/bin/with-bashio` shebang with `#!/usr/bin/env bash`
  plus explicit `source /usr/lib/bashio/bashio.sh` to resolve
  `/run.sh: not found` when the `with-bashio` wrapper is missing

## 1.1.1

- **Fix**: Update base images from Alpine 3.20 to 3.21
  (3.20 tags were removed from ghcr.io/home-assistant in Dec 2025)

## 1.1.0

- **Bidirectional sync**: export HA-side config changes back to GitHub
- New options: `export_enabled`, `export_interval`, `export_branch`, `export_commit_message`
- One-time export on startup (seeds repo or captures offline changes)
- Auto-export loop detects /config drift and commits/pushes on schedule
- Import-aware: skips export after import to prevent feedback loops
- Refactored into `do_import()` and `do_export()` functions
- Log messages now prefixed with Import/Export for clarity

## 1.0.0

- Initial release
- GitOps sync from GitHub to HA `/config`
- Supervisor API validation (check-config) before reload
- Automatic rollback on invalid config
- Configurable `sync_paths` allowlist
- Private repo support via GitHub PAT
- Multi-arch: amd64, aarch64, armv7, i386
