# Changelog

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
