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
5. HA’s config checker validates the result via the Supervisor API.
6. If valid, HA reloads automatically. If invalid, the files are rolled
   back to their previous state and the error is logged.

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

The token is stored in HA’s encrypted add-on option store and is never
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

## Security

- **No manual HA tokens.** The add-on uses the auto-injected `$SUPERVISOR_TOKEN`
  for HA API calls.
- **No Samba.** Direct `/config` access via the Supervisor’s `map: config:rw`.
- **No inbound ports.** Only outbound HTTPS to GitHub.
- **Rollback on failure.** Invalid imports are automatically reverted.
- **GitHub PAT** is stored in HA’s encrypted add-on option store.
  Fine-grained tokens scoped to a single repo with Contents read/write
  are recommended over classic tokens with broad `repo` scope.
- **Export commits** are attributed to `HA Config Sync <config-sync@homeassistant.local>`
  for clear audit trail in git history.

## Logs

Check the **Log** tab in the add-on panel.

### Import logs

```
[config-sync] Import: change detected (abc12345 -> def67890)
[config-sync] Import: syncing configuration.yaml automations.yaml
[config-sync] Import: config valid — reloading Home Assistant
[config-sync] Import: reload complete (abc12345 -> def67890)
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

```
[config-sync] Import: config invalid: Integration 'nonexistent' not found
[config-sync] Import: rolling back to abc12345
[config-sync] Export: no github_pat configured — cannot push (read-only)
```

## Agent integration

The add-on can be managed programmatically via the HA Supervisor API.
Any agent or automation platform that can call the HA REST API can:

- Read/change add-on options: `GET/POST /addons/config-sync/options`
- Start/stop/restart: `POST /addons/config-sync/{start,stop,restart}`
- Read logs: `GET /addons/config-sync/logs`
- Check status: `GET /addons/config-sync/info`

To trigger an on-demand export, an agent can restart the add-on — the
initial export runs on every startup when `export_enabled` is true.

This makes it compatible with NanoClaw’s `agent-homeops`, Home Assistant
automations, or any future agent platform.
