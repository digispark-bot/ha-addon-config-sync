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

Network operations to GitHub (`git fetch`, `git push`, `git clone`) are
hard-bounded by `GIT_HTTP_LOW_SPEED_LIMIT=1000` + `GIT_HTTP_LOW_SPEED_TIMEOUT=60`
as of v1.5.4 — they abort if throughput stays below 1 KB/s for 60 seconds.
Supervisor API calls are similarly bounded by `--max-time 30 --connect-timeout 5`
from v1.5.4. Without these, a stalled network or hung Supervisor would
wedge the single-threaded sync loop indefinitely.

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
5. **Each export cycle with real changes writes a per-export structured
   log (v1.5.3+)** under `/data/logs/export/` so operators can
   reconstruct any past push.

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

Fine-grained is **strongly preferred** because it limits the blast radius
if the token is ever exfiltrated — see the PAT-handling note in Security
below.

### Where the PAT lives at runtime

The PAT you paste into the add-on UI is stored encrypted at rest by the
Home Assistant Supervisor (HA's add-on options store).

**However, at runtime, the add-on writes the PAT to `/data/repo/.git/config`
on disk inside the add-on container**, as part of the HTTPS remote URL
(`https://<PAT>@github.com/<owner>/<repo>.git`). This is how git
authenticates fetch/push without a credential helper. The `/data/` path is
on the persistent add-on volume — the PAT survives container restart.

Anyone with `docker exec` access to the add-on container (i.e. anyone
with HAOS admin + host-level access) can read the PAT in plaintext from
that file. The PAT is **also** scrubbed from log output by
`sanitize_output()` (v1.1.6+, hardened against glob-char fragility in
v1.5.4) so it doesn't leak into the add-on log even on git error output.

**Recommendation**: use a fine-grained PAT scoped to the single GitHub
repo you sync, with Contents: read+write only. That way if the PAT is
ever exfiltrated, the attacker gets push access to one repo and nothing
else — not your whole GitHub account. Rotate the PAT periodically by
pasting a new one into the add-on options (the old one is overwritten in
`.git/config` on the next add-on restart).

A future release may add an optional git credential helper to keep the
PAT out of `.git/config` entirely. Not yet implemented.

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
- **No inbound ports.** Only outbound HTTPS to GitHub and outbound HTTP
  to the Supervisor unix-socket-style endpoint.
- **Rollback on failure.** Invalid imports are automatically reverted. Storage-level
  rollback available via the `gitops-pre-<sha>` HA backup taken before each sync.
- **GitHub PAT** is encrypted at rest by HA's options store, then written
  to `.git/config` in plaintext inside the add-on container at runtime.
  See the "Where the PAT lives at runtime" section above for the full
  picture and the strong recommendation to use a fine-grained PAT scoped
  to a single repo.
- **PAT scrubbing in logs** via `sanitize_output()` (v1.1.6+, hardened
  in v1.5.4 against glob-char fragility).
- **Network timeouts on every outbound call** (v1.5.4+): Supervisor API
  calls bounded by `--max-time 30 --connect-timeout 5`, git network ops
  bounded by `GIT_HTTP_LOW_SPEED_LIMIT=1000` + `GIT_HTTP_LOW_SPEED_TIMEOUT=60`.
  A hung remote can no longer wedge the sync loop.
- **Export commits** are attributed to `HA Config Sync <config-sync@homeassistant.local>`
  for clear audit trail in git history.

(The Observability section, log examples, and Agent integration sections
are unchanged from v1.5.3; see the file history if needed. Truncated
here to keep the v1.5.4 diff focused on the changes.)
