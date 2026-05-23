# Changelog

## 1.1.2

- **Fix**: Replace `#!/usr/bin/with-bashio` shebang with `#!/usr/bin/env bash`
  plus explicit `source /usr/lib/bashio/bashio.sh` to resolve
  `/run.sh: not found` when the `with-bashio` wrapper is missing
  from the base image

## 1.1.1

- **Fix**: Update base images from Alpine 3.20 to 3.21
  (3.20 tags were removed from ghcr.io/home-assistant in Dec 2025,
  causing Docker build failures)

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
