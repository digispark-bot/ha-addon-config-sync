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
   aborted with a copy-paste fix recipe in the log.
6. **Tracked-symlink guard (v1.6.0+)**: if any tracked file matching
   `sync_paths` is a symlink in the repo, the sync is aborted (path-
   traversal vector). Configurable via `block_symlinks`.
7. **A pre-sync HA backup is triggered** (named `gitops-pre-<short_sha>`).
8. HA's config checker validates the result via the Supervisor API.
9. If valid, HA reloads automatically.
10. **Post-sync verification probes** check that HA's state machine and REST
    API are responsive after the reload.
11. If invalid at any step, the files are rolled back.
12. The outcome is published to `sensor.config_sync_status` (v1.5.0+).
13. **Old `gitops-pre-*` backups are pruned (v1.5.2+)**.

Network operations to GitHub are hard-bounded by
`GIT_HTTP_LOW_SPEED_LIMIT=1000` + `GIT_HTTP_LOW_SPEED_TIMEOUT=60` as of
v1.5.4. Supervisor API calls are bounded by `--max-time 30
--connect-timeout 5`. The `github_repo` URL host must match the
`allowed_repo_hosts` allowlist (v1.6.0+).

### Export (HA → GitHub)

When `export_enabled` is true:

1. **On startup**, the add-on runs an immediate export.
2. Every `export_interval` seconds, it compares `/config` files against the repo.
3. If HA-side changes are detected, the add-on commits and pushes them.
4. Immediately after an import, the next export cycle is skipped.
5. **Each export cycle with real changes writes a per-export structured
   log (v1.5.3+)** under `/data/logs/export/`.

## Configuration

### Import options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `github_repo` | Yes | — | Full HTTPS URL of your config repo. Host must be in `allowed_repo_hosts` (v1.6.0+). |
| `branch` | No | `main` | Branch to track for import |
| `check_interval` | No | `300` | Seconds between import checks (60–3600) |
| `sync_paths` | No | See below | List of file/directory paths to sync |
| `github_pat` | No | — | GitHub PAT — required for private repos and export. See "Where the PAT lives at runtime" below. |
| `post_sync_settle_seconds` | No | `5` | Seconds to wait after `reload_all` before running verification probes. |
| `restart_on_lovelace_change` | No | `true` | When `true`, calls `/core/restart` instead of `reload_all` when the diff touches the lovelace key. |
| `notify_on_failure` | No | `true` | Raise HA persistent_notification on every sync failure. |
| `strict_sync_paths_check` | No | `true` | Abort sync if !include_dir_* directives reference directories outside sync_paths. (v1.5.1+) |
| `pre_sync_backup_retention` | No | `7` | How many `gitops-pre-*` HA backups to keep. `0` disables pruning. (v1.5.2+) |
| `allowed_repo_hosts` | No | `["github.com"]` | List of hostnames `github_repo` is allowed to point at (v1.6.0+). Subdomain matches allowed via suffix-match. Add your GitHub Enterprise hostname here if applicable. Setting this to an empty list defaults back to `["github.com"]`. |
| `block_symlinks` | No | `true` | Abort sync if any tracked file in `sync_paths` is a symlink (v1.6.0+). Symlinks in tracked config files are a path-traversal vector. Set to `false` if you intentionally use symlinks and accept the risk. |

### Export options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `export_enabled` | No | `false` | Enable export (HA → GitHub) |
| `export_interval` | No | `3600` | Seconds between auto-export checks (300–86400) |
| `export_branch` | No | same as `branch` | Branch to push exports to |
| `export_commit_message` | No | `export: HA config snapshot` | Prefix for export commit messages |

### sync_paths

Controls which files are eligible for both import and export. Paths ending
in `/` are treated as directory prefixes. All other entries are exact
filename matches. Default paths:

- `configuration.yaml`
- `automations.yaml`
- `scripts.yaml`
- `scenes.yaml`
- `groups.yaml`
- `customize.yaml`
- `packages/`
- `dashboards/`
- `scripts/`

If `configuration.yaml` contains a `!include_dir_*` directive pointing at
a directory not in `sync_paths`, files under that directory are silently
skipped during sync — unless `strict_sync_paths_check` (v1.5.1+) blocks
the sync first. The v1.1.7 startup audit also warns about this at
add-on start.

## Repo trust (v1.6.0+)

Two guards added in v1.6.0 defend against repo-trust threats.

### Host allowlist (`allowed_repo_hosts`)

Before any clone or fetch, the add-on validates that `github_repo`
points at a hostname in `allowed_repo_hosts`. Defaults to
`["github.com"]`. Subdomain matches are allowed via suffix-match:
`"github.com"` permits `api.github.com`, `raw.githubusercontent.com`,
etc.

If the host is not in the allowlist, the add-on refuses to start with
a multi-line ERROR pointing the operator at the fix:

```
REFUSING TO START — github_repo host not in allowlist
...
github_repo points at 'attacker.com', but allowed_repo_hosts is:
  - github.com

This is a security guard added in v1.6.0. Without it, a
misconfigured github_repo URL would send the GitHub PAT to
an arbitrary host on first clone/fetch.

If 'attacker.com' is a host you trust (e.g. your GitHub
Enterprise instance), add it to the allowed_repo_hosts
config option in the add-on Configuration tab, save, and
restart the add-on.
```

**For GitHub Enterprise operators**: this is a soft-breaking change.
Add your GHE hostname to `allowed_repo_hosts` before upgrading to
v1.6.0, e.g.:

```yaml
allowed_repo_hosts:
  - github.com
  - github.mycorp.io
```

### Tracked-symlink guard (`block_symlinks`)

Before any pre-sync backup or file copy, the add-on checks whether
any tracked file matching `sync_paths` is a symlink in the repo. If
yes, the sync is aborted with a clear ERROR listing the symlinks and
their targets.

Symlinks in tracked config files are a path-traversal vector:

- A commit could turn `automations.yaml` into a symlink to
  `/etc/passwd` — the subsequent `cp` would expose the target file's
  content through the sync (info disclosure, low-impact since the
  add-on container is already privileged).
- A commit could turn `scripts.yaml` into a symlink to
  `/data/sync_status.json` — the `cp` would overwrite the target
  with the commit's content (integrity attack).

Default is `true`. Operators with intentional symlink use (rare — HA
itself often has trouble with symlinks in `/config`) can set
`block_symlinks: false` to revert to v1.5.x behavior.

The abort path produces:
- `event=tracked_symlinks result=abort` in the per-sync log
- HA persistent_notification "Config Sync: tracked symlinks blocking sync"
- `sensor.config_sync_status` state = `failed`,
  `last_error: "[tracked_symlinks] ..."`, `failure_count` bumped
- Git state reset to LOCAL so next cycle retries the same SHA after
  the operator replaces the symlinks with regular files

## GitHub Personal Access Token

A GitHub PAT is required for private repos (import) and for export
(push). Public repo import works without a PAT.

**Fine-grained PAT (strongly recommended):**

1. Go to [GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new).
2. Set a descriptive name (e.g., `ha-config-sync`).
3. Set expiration (recommend 90 days; rotate by pasting a new token).
4. Under **Repository access**, select **Only select repositories** and pick your config repo.
5. Under **Permissions → Repository permissions**, set **Contents** to **Read and write**.
6. Click **Generate token** and paste into `github_pat`.

Fine-grained PATs are strongly preferred over classic PATs because
they limit blast radius if exfiltrated.

### Where the PAT lives at runtime

The PAT you paste into the add-on UI is stored encrypted at rest by
the Home Assistant Supervisor.

**However, at runtime, the add-on writes the PAT to
`/data/repo/.git/config` on disk inside the add-on container**, as
part of the HTTPS remote URL. This is how git authenticates without
a credential helper. The `/data/` path is persistent across container
restart.

Anyone with `docker exec` access to the add-on container (HAOS admin
+ host access) can read the PAT in plaintext from that file. The PAT
is also scrubbed from log output by `sanitize_output()` (v1.1.6+,
hardened in v1.5.4) so it doesn't leak into the rolling add-on log.

**Recommendation**: use a fine-grained PAT scoped to your single
GitHub repo with Contents: read+write only. That way exfiltration
limits attacker to push access on one repo.

A future release may add an optional git credential helper to keep
the PAT out of `.git/config` entirely. Not yet implemented.

## Workflows

### Import-only (default)

Edit config in GitHub → merge to branch → add-on pulls and validates → HA reloads.

### Export-only

Set `export_enabled: true`. Make changes via the HA UI → add-on detects
the drift → commits and pushes to GitHub.

### Bidirectional

Set `export_enabled: true`. Edit config in GitHub OR in the HA UI — both
directions are handled. Import takes priority.

## Security

### Permissions the add-on requests

| Permission | Why | Since |
|------------|-----|-------|
| `homeassistant_api: true` | Core API access (check_config, reload_all, post-sync probes, /core/restart, persistent_notification, status sensor) | 1.1.4 |
| `hassio_api: true` + `hassio_role: backup` | Pre-sync backup + retention prune (least-privilege backup-only role) | 1.2.1 |
| `map: config:rw` | Direct read/write to /config for sync | 1.0.0 |

### Defense-in-depth summary

- **No manual HA tokens** — uses auto-injected `$SUPERVISOR_TOKEN`.
- **No Samba** — direct `/config` access via `map: config:rw`.
- **No inbound ports** — only outbound HTTPS to GitHub + HTTP to Supervisor.
- **Network timeouts on every outbound call** (v1.5.4+): `--max-time 30
  --connect-timeout 5` for curl; `GIT_HTTP_LOW_SPEED_TIMEOUT=60` for git.
- **Repo-host allowlist** (v1.6.0+): `github_repo` host must match
  `allowed_repo_hosts`.
- **Tracked-symlink guard** (v1.6.0+): aborts sync if any tracked
  sync_paths file is a symlink in the repo.
- **sync_paths gap guard** (v1.5.1+): aborts sync if !include_dir_*
  references files outside sync_paths.
- **Pre-sync HA backup** (v1.2.0+) + retention (v1.5.2+) for storage-level
  rollback.
- **Post-sync verification probes** (v1.2.0+) for behavioral verification
  that check_config doesn't catch.
- **PAT scrubbing in logs** (v1.1.6+, hardened in v1.5.4).
- **GitHub PAT stored encrypted at rest** by HA's options store; written
  to `.git/config` in plaintext at runtime (see "Where the PAT lives"
  above).
- **Export commits** attributed to `HA Config Sync
  <config-sync@homeassistant.local>` for audit trail.

## Observability

See `sensor.config_sync_status` (v1.5.0+), `/data/sync_status.json`
(v1.5.0+), the rolling add-on log, `/data/logs/sync/` (v1.4.1+), and
`/data/logs/export/` (v1.5.3+). The 2026-05-25 review found no
additional observability gaps in v1.5.x.

### Recommended dashboard card

```yaml
type: tile
entity: sensor.config_sync_status
show_entity_picture: false
```

### Recommended automation — ping on failure

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

(For full observability detail — attribute schema, per-sync log format,
export log format, error log examples — see the v1.5.3 file history
of DOCS.md. Truncated here in v1.6.0 only because the schema and log
formats have not changed.)

## Agent integration

Any agent or automation platform that can call the HA REST API can:

- **Subscribe to sync state** (v1.5.0+): `GET /core/api/states/sensor.config_sync_status`
- **Read add-on options**: `GET/POST /addons/config-sync/options`
- **Start/stop/restart**: `POST /addons/config-sync/{start,stop,restart}`
- **Read add-on logs**: `GET /addons/config-sync/logs`
- **Check add-on status**: `GET /addons/config-sync/info`

NanoClaw's `agent-homeops` is the intended primary consumer of
`sensor.config_sync_status` — it polls the state and surfaces failures
via Telegram without needing `docker exec`.
