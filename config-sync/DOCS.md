# Config Sync (GitOps)

Bidirectional GitOps for Home Assistant. Pulls config from GitHub, validates,
and reloads. Optionally exports HA-side changes (UI edits, manual tweaks)
back to GitHub automatically.

## How it works

### Import (GitHub → HA)

1. The add-on clones your GitHub config repo on first start.
2. Every `check_interval` seconds it runs `git fetch` to check for new commits.
3. When new commits are found, it identifies which files changed.
4. Only files matching your `sync_paths` allowlist are copied to `/config`.
5. **sync_paths gap guard (v1.5.1+)**: if `configuration.yaml` has
   `!include_dir_*` directives targeting directories not in `sync_paths`
   AND this sync's diff has files under those directories, the sync is
   aborted with a copy-paste fix recipe in the log. Configurable via
   `strict_sync_paths_check`.
6. **A pre-sync HA backup is triggered** (named `gitops-pre-<short_sha>`)
   covering the `homeassistant` folder. If the backup API fails, the sync
   aborts and rolls back the local git state so the next cycle retries.
7. HA's config checker validates the result via the Supervisor API.
8. If valid, HA reloads automatically.
9. **Post-sync verification probes** check that HA's state machine and REST
   API are responsive after the reload. Either probe failing triggers
   file-level rollback + best-effort re-reload, and the operator is pointed
   at the named pre-sync backup for storage-level restore.
10. If invalid at any step, the files are rolled back and the error is logged.
11. The outcome is published to `sensor.config_sync_status` (v1.5.0+) so
    the operator sees the result on dashboards and automations can react.
12. **Old `gitops-pre-*` backups are pruned (v1.5.2+)**: the add-on keeps
    the most-recent `pre_sync_backup_retention` (default 7) and deletes the
    rest. The just-created backup is always in the keep set.

### Export (HA → GitHub)

When `export_enabled` is true:

1. **On startup**, the add-on runs an immediate export — this captures any
   changes made while the add-on was stopped, and seeds the repo on
   first install.
2. Every `export_interval` seconds, it compares `/config` files (filtered
   by `sync_paths`) against the repo.
3. If HA-side changes are detected (e.g., automations edited via the UI),
   the add-on commits and pushes them to `export_branch`.
4. Immediately after an import, the next export cycle is skipped to
   avoid re-committing what was just pulled.

## Configuration

### Import options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `github_repo` | Yes | — | Full HTTPS URL of your config repo |
| `branch` | No | `main` | Branch to track for import |
| `check_interval` | No | `300` | Seconds between import checks (60–3600) |
| `sync_paths` | No | See below | List of file/directory paths to sync |
| `github_pat` | No | — | GitHub PAT — required for private repos and export (see below) |
| `post_sync_settle_seconds` | No | `5` | Seconds to wait after `reload_all` before running verification probes. Bump for slow HA setups; 0 disables the settle delay. Range: 0–60. |
| `restart_on_lovelace_change` | No | `true` | When `true`, calls `/core/restart` (instead of `reload_all`) when this sync touches the lovelace key in `configuration.yaml`. Required for new `lovelace.dashboards` entries to register — see Sprint 3 / v1.4.0. Disable only on latency-sensitive setups (with the known caveat that dashboard changes won't take effect without manual restart). |
| `notify_on_failure` | No | `true` | When `true`, raises an HA persistent_notification on every sync failure and auto-dismisses it on the next healthy sync. Disable for headless deployments. |
| `strict_sync_paths_check` | No | `true` | When `true` (v1.5.1+), aborts the sync if `configuration.yaml` has `!include_dir_*` directives targeting directories not in `sync_paths` AND the diff contains files under those directories. Prevents the 2026-05-25 incident class structurally. Set to `false` to log the gap loudly but continue the sync (v1.5.0 behavior). |
| `pre_sync_backup_retention` | No | `7` | How many `gitops-pre-*` HA backups to keep (v1.5.2+). After every sync that took a backup, the add-on prunes anything past the Nth most recent. The just-created backup is always in the keep set. Set to `0` to disable pruning (v1.5.1 behavior — backups accumulate forever). Range: 0–50. |

### Export options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `export_enabled` | No | `false` | Enable export (HA → GitHub) |
| `export_interval` | No | `3600` | Seconds between auto-export checks (300–86400) |
| `export_branch` | No | same as `branch` | Branch to push exports to |
| `export_commit_message` | No | `export: HA config snapshot` | Prefix for export commit messages |

### sync_paths

Controls which files are eligible for both import and export. Paths ending
in `/` are treated as directory prefixes (everything underneath is included).
All other entries are exact filename matches.

Default paths:

- `configuration.yaml`
- `automations.yaml`
- `scripts.yaml`
- `scenes.yaml`
- `groups.yaml`
- `customize.yaml`
- `packages/`
- `dashboards/`
- `scripts/`

**⚠️ sync_paths gotcha:** if `configuration.yaml` contains a `!include_dir_*`
directive pointing at a directory not in this list (e.g., `themes/`,
`lovelace/`, `blueprints/`), files under that directory are silently
skipped during sync — unless `strict_sync_paths_check` (v1.5.1+) blocks
the sync first. Add the directory to `sync_paths` and restart the add-on
before merging PRs that add files under it.

Three layers of protection against this class of mistake:

1. **v1.1.7 startup audit** — `audit_include_dir_directives()` scans
   `configuration.yaml` at add-on startup and emits a WARNING per gap,
   with line number and one-line remediation. Tells the operator about
   gaps before they cause incidents.
2. **v1.5.1 sync-time guard** — `check_sync_paths_gap()` runs at every
   sync and ABORTS (default) if the current diff would silently drop
   files referenced by an `!include_dir_*` directive. Prevents the
   incident class even when the operator forgets to restart the add-on
   after fixing the config.
3. **strict_sync_paths_check** option — the v1.5.1 guard's default is
   `true` (abort). Set to `false` to fall back to the v1.5.0 behavior
   (log loudly, continue, let downstream check_config/reload catch it).

### GitHub Personal Access Token

A GitHub PAT is required for private repos (import) and for export (push).
Public repo import works without a PAT.

**Fine-grained PAT (recommended):**

1. Go to [GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).
2. Set a descriptive name (e.g., `ha-config-sync`).
3. Set expiration (recommend 90 days; you can rotate by pasting a new token into the add-on config).
4. Under **Repository access**, select **Only select repositories** and pick your config repo.
5. Under **Permissions → Repository permissions**, set **Contents** to **Read and write**. No other permissions are needed.
6. Click **Generate token** and paste it into the `github_pat` field in the add-on config.

**Classic PAT (simpler, broader scope):**

1. Go to [GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)](https://github.com/settings/tokens/new).
2. Set a descriptive name and expiration.
3. Check the `repo` scope (grants read/write to all your repos).
4. Click **Generate token** and paste it into `github_pat`.

Fine-grained is preferred because it limits access to a single repository
with only the permissions the add-on actually uses (`git clone` and
`git push`). Classic PATs grant broader access across all repositories.

The token is stored in HA's encrypted add-on option store and is never
written to disk inside the container.

## Workflows

### Import-only (default)

Edit config in GitHub → merge to branch → add-on pulls and validates → HA reloads.

### Export-only

Set `export_enabled: true`. Make changes via the HA UI → add-on detects
the drift → commits and pushes to GitHub. Useful for backing up UI-driven
configurations.

### Bidirectional

Set `export_enabled: true`. Edit config in GitHub OR in the HA UI — both
directions are handled. Import takes priority: after a pull from GitHub,
the next export cycle is skipped to avoid a feedback loop.

For cleaner git history with bidirectional sync, set `export_branch` to a
separate branch (e.g., `ha-export`). HA-side changes land on that branch
and can be reviewed via PR before merging to `main`.

### Seeding the repo

To populate an empty repo with your current HA config:

1. Set `export_enabled: true`
2. Start the add-on
3. The initial export commits all `sync_paths` files to the repo
4. Optionally disable export afterward if you only want one-way import

## Pre-sync backup retention (v1.5.2+)

Every sync that proceeds past the gap-guard takes a partial HA backup named
`gitops-pre-<short_sha>` covering the `homeassistant` folder. By default the
add-on retains the most-recent 7 of these and deletes the rest, so backups
don't accumulate forever.

**How it works:**

- Pruning runs at the end of every `do_import()` cycle that took a backup
  (success path, `check_config_invalid` fall-through, `check_config_api`
  failure, `post_sync_verify` failure).
- Backups are listed via `GET /backups`, filtered to names starting with
  `gitops-pre-`, sorted by date descending, and anything past the Nth
  most recent is deleted via `DELETE /backups/<slug>`.
- The just-created backup is always the most recent by date, so it's never
  deleted in the same cycle that created it — even on a failed sync where
  the operator needs that exact backup for restore.
- Failures of the list/delete API are logged at DEBUG/WARN respectively
  and never propagate. The retention pass is strictly best-effort.

**Disabling retention:**

Set `pre_sync_backup_retention: 0` to revert to the v1.5.1 behavior
(backups accumulate forever). Useful if you want HA's own backup retention
policy to manage them, or if you keep a long compliance trail.

**Naming caveat:** the prefix match is `gitops-pre-` against the backup
`.name`. If you happen to create a backup of your own with that prefix
(unusual), it will be subject to the retention sweep too. Use a different
name for manual backups you want to keep.

## Security

### Permissions the add-on requests

| Permission | Why | Since |
|------------|-----|-------|
| `homeassistant_api: true` | Core API access for `check_config`, `reload_all`, the post-sync verification probes (`/core/api/states/*`, `/core/api/`), and the v1.5.0 sync status sensor (`POST /core/api/states/sensor.config_sync_status`) | 1.1.4 |
| `hassio_api: true` + `hassio_role: backup` | Supervisor API access for the pre-sync HA backup (`POST /backups/new/partial`) and the v1.5.2 backup retention sweep (`GET /backups` + `DELETE /backups/<slug>`). `backup` is the least-privilege role that grants the backups API — covers list + delete in addition to create. `manager` would also work but is broader than necessary. | 1.2.1 |
| `map: config:rw` | Direct read/write to `/config` for the sync. | 1.0.0 |

### General security posture

- **No manual HA tokens.** The add-on uses the auto-injected `$SUPERVISOR_TOKEN`
  for HA API calls.
- **No Samba.** Direct `/config` access via the Supervisor's `map: config:rw`.
- **No inbound ports.** Only outbound HTTPS to GitHub.
- **Rollback on failure.** Invalid imports are automatically reverted. Storage-level
  rollback available via the `gitops-pre-<sha>` HA backup taken before each sync.
- **GitHub PAT** is stored in HA's encrypted add-on option store.
  Fine-grained tokens scoped to a single repo with Contents read/write
  are recommended over classic tokens with broad `repo` scope.
- **Export commits** are attributed to `HA Config Sync <config-sync@homeassistant.local>`
  for clear audit trail in git history.

## Observability

The add-on surfaces sync state in four places, ordered from most operator-
friendly to most diagnostic-detailed.

### sensor.config_sync_status (v1.5.0+)

First-class HA entity that reflects the most recent sync outcome. Visible in
Developer Tools → States, addable to any dashboard, subscribable by
automations, and queryable by external tooling (NanoClaw `agent-homeops`,
Node-RED, etc) via the standard `/core/api/states/sensor.config_sync_status`
endpoint.

**States**: `idle` (boot, before any sync) → `syncing` (during do_import) →
`success` | `failed`. Stays on the terminal state between cycles so the
sensor always shows the latest outcome.

**Attributes:**

| Attribute | Description |
|---|---|
| `friendly_name` | Always `"Config Sync Status"` |
| `icon` | `mdi:cloud-check` (success), `mdi:cloud-alert` (failed), `mdi:cloud-sync` (idle/syncing) |
| `last_sync_at` | UTC ISO-8601 timestamp |
| `last_sha_short` | 8-char target commit SHA |
| `last_strategy` | `reload_all` / `reload_all_plus_themes` / `core_restart` (Sprint 3 reload key) |
| `last_error` | Human-readable error text on failure, prefixed with `[stage]` (`pre_sync_backup`, `check_config_api`, `check_config_invalid`, `post_sync_verify`, `sync_paths_gap`) |
| `last_backup_name` | Pre-sync HA backup name (e.g. `gitops-pre-abc12345`) for one-click restore |
| `last_log_file` | Path to the per-sync structured log file for the run |
| `sync_count` | Lifetime count of cycles that did real work |
| `failure_count` | Lifetime count of failed cycles |

**Recommended dashboard card:**

```yaml
type: tile
entity: sensor.config_sync_status
show_entity_picture: false
```

**Recommended automation — ping on failure:**

```yaml
alias: Notify on Config Sync failure
trigger:
  - platform: state
    entity_id: sensor.config_sync_status
    to: failed
action:
  - service: notify.telegram
    data:
      message: |
        Config Sync failed at {{ state_attr('sensor.config_sync_status', 'last_sync_at') }}
        SHA: {{ state_attr('sensor.config_sync_status', 'last_sha_short') }}
        Error: {{ state_attr('sensor.config_sync_status', 'last_error') }}
        Restore backup: {{ state_attr('sensor.config_sync_status', 'last_backup_name') }}
```

### /data/sync_status.json (v1.5.0+)

Mirror of the sensor's state + attributes, written to the add-on's persistent
storage. Survives add-on restart and upgrade. Used internally to restore
lifetime counters across reboots, and externally by headless tooling that
doesn't have HA API access.

Operator access:

```
docker exec -it addon_<slug>_config-sync cat /data/sync_status.json | jq
```

### Rolling add-on log

Check the **Log** tab in the add-on panel for the live log stream.

### Per-sync structured log (v1.4.1+)

In addition to the rolling add-on log, every sync cycle that has changes
writes a dedicated structured log file under `/data/logs/sync/` inside the
add-on container. Filename is `<UTC-timestamp>-<remote-short-sha>.log`.
Retention is hardcoded to the most-recent 20 files (oldest auto-deleted).

Each file captures every major waypoint with `event=` keys:

```
2026-05-26T03:14:07Z [INFO] event=sync_start local=abc12345 remote=def67890
2026-05-26T03:14:07Z [INFO] event=files_changed count=2 paths=automations.yaml,scripts.yaml
2026-05-26T03:14:09Z [INFO] event=backup result=triggered name=gitops-pre-def67890
2026-05-26T03:14:10Z [INFO] event=reconcile copied=0 failed=0
2026-05-26T03:14:11Z [INFO] event=check_config result=valid
2026-05-26T03:14:11Z [INFO] event=reload strategy=reload_all reason=default
2026-05-26T03:14:17Z [INFO] event=verify probe=sun.sun result=pass
2026-05-26T03:14:17Z [INFO] event=verify probe=core_api result=pass
2026-05-26T03:14:18Z [INFO] event=backup_prune retention=7 deleted=1 failed=0
2026-05-26T03:14:18Z [INFO] event=sync_end result=success
```

Operator access:

```
docker exec -it addon_<slug>_config-sync ls -lt /data/logs/sync/
docker exec -it addon_<slug>_config-sync cat /data/logs/sync/<filename>.log
```

Use this when investigating a past sync that the rolling log has scrolled
past, or when reconstructing the exact sequence around a known-bad commit.
The `/data/` mount is persistent across add-on restarts and upgrades, so
the log history survives a container rebuild. The path of the latest
file is also exposed as the `last_log_file` attribute on
`sensor.config_sync_status` for direct lookup.

If `mkdir` on the log directory fails (e.g. disk full), the cycle logs a
WARNING to the rolling add-on log and continues — per-sync logging is
best-effort and never blocks a sync.

### Import logs (happy path)

```
[config-sync] Import: change detected (abc12345 -> def67890)
[config-sync] Import: syncing configuration.yaml automations.yaml
[config-sync] Pre-sync HA backup 'gitops-pre-def67890' triggered — Settings → System → Backups
[config-sync] Import: config valid — reloading Home Assistant
[config-sync] Import: reload complete (abc12345 -> def67890)
[config-sync] Post-sync verify: both probes passed — sync verified healthy
[config-sync] Pre-sync backup retention: pruned 1, failed 0 (keeping last 7)
```

### Export logs

```
[config-sync] Export enabled — running initial export
[config-sync] Export (initial): committed automations.yaml scripts.yaml
[config-sync] Export (initial): pushed to origin/main
[config-sync] Export (auto): committed automations.yaml
[config-sync] Export (auto): pushed to origin/main
```

### Error logs

Failed Supervisor API calls log the actual HTTP status code and a
truncated response body so the root cause is visible without a separate
diagnostic step. Examples:

```
[config-sync] Pre-sync HA backup API failed — REFUSING to sync (HTTP 403)
[config-sync]   Supervisor response: {"result":"error","message":"You don't have the role to call this endpoint"}
[config-sync]   Common causes for this endpoint:
[config-sync]     HTTP 401/403 — add-on missing 'hassio_api: true' or 'hassio_role: backup' in config.yaml
[config-sync]     HTTP 4xx     — backup integration not loaded, or request body schema changed
[config-sync]     HTTP 5xx     — Supervisor internal error, or disk full
[config-sync] Aborting sync — rolling back git state to abc12345; next cycle will retry
```

A v1.5.1 sync_paths gap abort looks like:

```
[config-sync] ============================================================
[config-sync] SYNC ABORTED — sync_paths gap detected
[config-sync] ============================================================
[config-sync] configuration.yaml (/data/repo/configuration.yaml) has !include_dir_* directives
[config-sync] targeting directories NOT in sync_paths:
[config-sync]   themes/ 
[config-sync] 
[config-sync] This sync would update configuration.yaml's references but
[config-sync] the sync_paths filter blocks 3 referenced file(s) from reaching /config.
[config-sync] HA will see configuration.yaml pointing at files that don't exist on disk —
[config-sync] frontend assets, themes, or lovelace dashboards may break.
[config-sync] 
[config-sync] Affected files (first 10):
[config-sync]   - themes/dark.yaml
[config-sync]   - themes/light.yaml
[config-sync]   - themes/seasonal.yaml
[config-sync] 
[config-sync] Fix: open the add-on Configuration tab, add these to sync_paths:
[config-sync]     - "themes/"
[config-sync] Save the config and restart the add-on. The next sync will retry.
[config-sync] ============================================================
```

Other failure examples:

```
[config-sync] Import: config invalid: Integration 'nonexistent' not found
[config-sync] Import: rolling back to abc12345
```

```
[config-sync] Post-sync probe 2 FAILED: /core/api/ unresponsive or auth rejected (HTTP 500)
[config-sync]   Supervisor response: {"error":"Internal Server Error"}
[config-sync] POST-SYNC VERIFICATION FAILED — rolling back
[config-sync] If HA is still broken, restore the pre-sync backup:
[config-sync]   Settings → System → Backups → 'gitops-pre-def67890'
```

```
[config-sync] Export: no github_pat configured — cannot push (read-only)
```

If a sync fails with a Supervisor response you don't understand, the
HTTP code + response body in the log line are enough to file an issue
with full diagnostic context.

## Agent integration

The add-on can be managed and observed programmatically. Any agent or
automation platform that can call the HA REST API can:

- **Subscribe to sync state** (v1.5.0+): `GET /core/api/states/sensor.config_sync_status` returns the current state + attributes; use the standard HA state-change WebSocket for push.
- **Read add-on options**: `GET/POST /addons/config-sync/options`
- **Start/stop/restart**: `POST /addons/config-sync/{start,stop,restart}`
- **Read add-on logs**: `GET /addons/config-sync/logs`
- **Check add-on status**: `GET /addons/config-sync/info`

To trigger an on-demand export, an agent can restart the add-on — the
initial export runs on every startup when `export_enabled` is true.

This makes it compatible with NanoClaw's `agent-homeops`, Home Assistant
automations, or any future agent platform. NanoClaw `agent-homeops` is
the intended primary consumer of `sensor.config_sync_status` — it polls
the state and surfaces failures via the Telegram channel without needing
`docker exec` into the add-on container.
