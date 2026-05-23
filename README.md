# Home Assistant Add-on: Config Sync (GitOps)

Bidirectional GitOps for Home Assistant — sync your configuration from a
GitHub repo with automatic validation and rollback. Export HA-side changes
back to GitHub automatically.

## Installation

1. In Home Assistant, go to **Settings > Add-ons > Add-on Store**.
2. Click the three-dot menu (top right) and select **Repositories**.
3. Paste this URL and click **Add**:

   ```
   https://github.com/JLay2026/ha-addon-config-sync
   ```

4. Find **Config Sync (GitOps)** in the add-on list and click **Install**.
5. Go to the **Configuration** tab and set your `github_repo` URL.
6. (Optional) Add a GitHub PAT for private repos or export — see below.
7. Click **Start**.

## What it does

Every few minutes the add-on checks your GitHub repo for new commits.
When it finds changes, it copies the updated config files into HA’s
`/config` directory, runs HA’s built-in config validator, and reloads
if everything checks out. If validation fails, the files are automatically
rolled back to the previous version.

With `export_enabled`, the add-on also detects changes made in the HA UI
(automations, scripts, scenes) and pushes them back to GitHub.

No SSH. No Samba. No manual HA tokens. Fully managed through the HA UI.

## GitHub PAT

A Personal Access Token is needed for private repos and for export (push).

**Fine-grained PAT (recommended):** scope to your config repo only, with
**Contents: Read and write** permission. This is the minimum the add-on
needs (`git clone` + `git push`).

**Classic PAT:** use the `repo` scope. Simpler to create but grants access
to all your repositories.

See [config-sync/DOCS.md](config-sync/DOCS.md) for step-by-step setup
instructions.

## Documentation

See [config-sync/DOCS.md](config-sync/DOCS.md) for full configuration
options, security details, and agent integration.

## License

MIT
