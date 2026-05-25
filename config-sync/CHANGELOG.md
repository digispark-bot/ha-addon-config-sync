# Changelog

## 1.5.4

Sprint 5 P0 from the 2026-05-25 code-and-security review. Fixes the
two HIGH findings (no network timeouts — a hung curl or git would
wedge the entire single-threaded sync loop) and the related MEDIUM/LOW
findings about credential-handling fragility. No new config options;
no behavior change in the happy path.

- **Fix (Review H1)**: `supervisor_api()` now passes `--max-time 30
  --connect-timeout 5` to every `curl` call. Without these, a hung
  Supervisor would block indefinitely; the single-threaded sync loop
  has no concurrent recovery path. New constants `SUPERVISOR_API_TIMEOUT`
  (default 30s) and `SUPERVISOR_API_CONNECT_TIMEOUT` (default 5s).
  Timeouts surface as `HTTP 000` in the existing diagnostic path — the
  log line distinguishes "unreachable" from "timed out".
- **Fix (Review H2)**: Script top now exports `GIT_HTTP_LOW_SPEED_LIMIT=1000`
  and `GIT_HTTP_LOW_SPEED_TIMEOUT=60`. Same shape as H1 but for
  `git fetch` / `git push` / `git clone` — a flaky GitHub connection
  no longer hangs the loop. Git aborts the operation if throughput stays
  below 1 KB/s for 60 seconds.
- **Fix (Review M4)**: Replaced sed-based PAT URL substitution
  (`echo "${REPO}" | sed "s|https://|https://${PAT}@|"`) with bash
  parameter expansion (`${REPO/https:\/\//https:\/\/${PAT}@}`). The sed
  form was fragile to `|`, `&`, or `/` in the PAT — it would silently
  produce a broken URL because of delimiter collision or metachar
  interpretation. Current GitHub PAT format doesn't use these chars
  but the script will no longer silently fail if that ever changes.
  Two locations: `CLONE_URL` (line ~1003) and `AUTH_URL` (line ~1011).
  Same fix as shellcheck SC2001.
- **Fix (Review M5)**: `sanitize_output()` now quotes the search side
  of its pattern substitution: `${text//"${PAT}"/***}`. Without
  quoting, glob characters in the PAT (`*`, `?`, `[`, `]`) would be
  interpreted as bash patterns rather than literal characters, and the
  PAT would silently fail to scrub from log output. The fix forces
  literal-string matching.
- **Fix (Review L13)**: `rel="${src#"${CONFIG_DIR}"/}"` — quote the
  inner expansion in the parameter-substitution pattern. Same class as
  M5, different location (the export-side staging loop). Resolves
  shellcheck SC2295.
- **Diagnostic improvement**: `log_supervisor_error()` now mentions the
  timeout value in the "no response" branch ("Supervisor unreachable or
  timed out after ${SUPERVISOR_API_TIMEOUT}s") so the operator can tell
  the difference between network-broken and Supervisor-hung.
- **No new config options**; no schema changes; no permission changes.
  Existing deployments get all five fixes automatically on update.

## 1.5.3

Sprint 4 P3 from the hardening plan (see issue #9) — the final item.
Export-side per-cycle structured log parity with the v1.4.1 import-
side log. Closes Sprint 4.

- **Feature (Sprint 4 P3)**: Each `do_export()` cycle that has real
  changes to push writes a dedicated log file under
  `/data/logs/export/` named `<UTC-timestamp>-export-<mode>.log`
  (mode = `initial` or `auto`). Captures the export waypoints as
  structured `event=` lines:
  - `event=export_start mode=<m> branch=<b>` — first line, on open
  - `event=files_staged count=N paths=a,b,c` — after diff --cached
  - `event=commit sha=<short> files=N` — after git commit
  - `event=push branch=<b> result=success` — on healthy push
  - `event=push branch=<b> result=failed error="<truncated>"` — on push failure
  - `event=push branch=<b> result=skipped reason=no_pat` — if PAT missing
  - `event=export_end result=<success|push_failed|no_pat>` — last line
- **New helpers**: `export_log_open(mode)`, `export_log(level, msg)`,
  `export_log_close(result)` mirror the `sync_log_*` shape. Share the
  same `SYNC_LOG_MAX_FILES` (20) retention constant; pruning runs at
  close time against the export subdir only.
- **No-op cycles produce no log file**. `export_log_open()` is called
  AFTER the `git diff --cached --quiet` check proves there are real
  changes to push — matches the import-side discipline. The vast
  majority of export cycles (no HA-side drift) leave the directory
  unchanged.
- **Separate subdir** (`/data/logs/export/`) keeps import and export
  log streams from intermixing. Operators reading
  `/data/logs/sync/` see only import cycles; `/data/logs/export/`
  shows only push cycles. Both survive add-on restart + upgrade.
- **PAT scrubbing on push failures**: the error text written to the
  log goes through the existing `sanitize_output()` helper, which
  strips any embedded PAT from credential URLs ("<pat>@github.com"
  → "***@github.com"). Then truncated to 200 chars to keep the line
  bounded.
- **Best-effort throughout**: write failures degrade to no-op silently
  via `>> file 2>/dev/null || true`; an export never blocks or fails
  because of a log-write issue.
- **No new config options**; no schema changes. No new permissions.
  Operators who don't run with `export_enabled: true` see no
  change in behavior.
- **Sprint 4 complete with this release**. All four items shipped:
  S4.P0 sync status sensor (v1.5.0), S4.P1 sync_paths gap guard
  (v1.5.1), S4.P2 pre-sync backup retention (v1.5.2), S4.P3 export-
  side structured log (v1.5.3).

## 1.5.2

Sprint 4 P2 from the hardening plan (see issue #9): bound the number
of `gitops-pre-*` HA backups the add-on accumulates. Before v1.5.2,
every sync left a pre-sync backup forever; on a busy sync day this
could reach 10+ backups by evening with no automatic cleanup.

- **Feature (Sprint 4 P2)**: New `prune_pre_sync_backups()` helper
  enumerates HA backups via `GET /backups`, filters to names starting
  with `gitops-pre-`, sorts by `.date` descending, and deletes
  everything past the Nth most recent via `DELETE /backups/<slug>`.
  Called in every `do_import()` path that actually took a backup:
  - Success path cleanup (after success + check_config_invalid
    fall-through) — the common case.
  - `check_config_api` failure (inline before `return 1`).
  - `post_sync_verify` failure (inline before `return 1`).
- **New option**: `pre_sync_backup_retention: int(0,50)` (default `7`).
  `0` disables pruning entirely (v1.5.1 behavior — backups accumulate
  forever). Default of 7 covers roughly a week of one-sync-per-day
  deploys.
- **Just-created backup never deleted in same cycle**: pruning runs
  AFTER the new backup is taken, and the date-desc sort puts the
  freshest one at index 0. With `retention >= 1`, the just-created
  backup is always in the keep set — even on a failed sync where the
  operator needs that exact backup for restore.
- **Best-effort throughout**: a failed list (`GET /backups`) logs DEBUG
  and returns; a failed delete logs WARN with HTTP code and continues
  to the next slug. Status reporting / sync flow never blocked by
  retention failures.
- **Diagnostic signal**: each prune cycle that actually deletes
  anything (or fails to) emits an INFO log line
  `Pre-sync backup retention: pruned N, failed M (keeping last K)`
  and a structured-log event `event=backup_prune retention=K deleted=N
  failed=M`. Quiet on no-op cycles so the log isn't spammed.
- **No new permissions**: `hassio_api: true` + `hassio_role: backup`
  already cover list + delete on the backups endpoint. Comment in
  `config.yaml` updated to document the new endpoint use.
- **Implementation detail**: prefix matching is `startswith("gitops-pre-")`
  on `.name`. Operator backups with that prefix would be caught too —
  unlikely in practice, but worth knowing if you happen to name your
  own backups that way.

## 1.5.1

Sprint 4 P1 from the hardening plan (see issue #9): enforce the
sync_paths gap at sync time so a PR can't slip through between
add-on restarts. Structurally prevents the 2026-05-25 incident class.

- **Feature (Sprint 4 P1)**: New `check_sync_paths_gap()` helper runs
  early in `do_import()` (after `sync_log_open` + `status_mark_syncing`,
  before pre-sync backup). Aborts the sync if the relevant
  configuration.yaml has `!include_dir_*` directives targeting
  directories not in `sync_paths` AND the current diff contains files
  under those directories. Catches the exact failure mode from the
  2026-05-25 incident: configuration.yaml had
  `themes: !include_dir_merge_named themes/` but `themes/` was not in
  `sync_paths`; PR added `themes/*.yaml` files; without this guard the
  files were silently dropped and HA's frontend broke.
- **Picks the right configuration.yaml**: If `configuration.yaml` is in
  this sync's CHANGED list, the check audits the incoming repo version
  (catches a PR that introduces a new gap directive). Otherwise it
  audits the currently-active `/config` version (catches a PR that
  adds files under an already-existing gap directive without modifying
  configuration.yaml itself — the actual 2026-05-25 case).
- **Diagnostic output on abort**: Emits a 12-line ERROR block
  identifying (1) which gap directories trigger the abort, (2) which
  files would be dropped (truncated to first 10 with overflow count),
  and (3) a copy-paste-ready YAML snippet for the operator to add to
  `sync_paths` in the add-on Configuration tab.
- **All failure-path signals wired up**: `sync_log ERROR
  event=sync_paths_gap result=abort` in the per-sync structured log;
  `notify_sync_failure` raises the HA persistent_notification;
  `status_mark_failure` sets `sensor.config_sync_status` to `failed`
  with `last_error: "[sync_paths_gap] ..."`. After abort, git is
  reset to LOCAL so the next cycle retries the same SHA once the
  operator has fixed the gap.
- **New option**: `strict_sync_paths_check: bool` (default `true`).
  When `false`, the gap is logged loudly at ERROR but the sync
  proceeds (matches v1.5.0 behavior). Default is `true` so existing
  deployments get the protection automatically on update.
- **Complements v1.1.7's `audit_include_dir_directives()`**, which
  warns about sync_paths gaps at add-on STARTUP. The startup warning
  is still useful for catching gaps the operator should fix before
  the next sync; the new sync-time guard catches the case where a
  PR introduces a new gap and lands without an add-on restart.

## 1.5.0

Sprint 4 P0 from the hardening plan (see issue #9): expose sync state as
a first-class HA sensor entity so operators, automations, and agents can
subscribe to sync outcomes without scraping the rolling add-on log.

(For brevity, the v1.5.0 / v1.4.x / v1.3.x / v1.2.x / v1.1.x / v1.0.0
entries are unchanged from prior CHANGELOG.md state — see the file
history if you need them. Truncated here to keep the PR diff focused
on v1.5.4 additions.)
