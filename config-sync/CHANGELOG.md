# Changelog

## 1.6.3

Field-discovered regression fix: diff-sync was silently dropping file
deletions. PRs that delete a file (or rename one, which git represents
as add+delete) propagated the add to `/config` but left the deleted
file on disk. The orphaned file kept failing config validation at
every reload, producing repeating ERROR log entries even though the
upstream repo was clean.

- **Fix**: The copy loop in `do_import()` now handles three cases:
  added/modified files are copied from `${REPO_DIR}` (existing
  behavior), and deleted files are removed from `${CONFIG_DIR}` via
  `rm -f` (new). The existing backup loop already snapshots the
  about-to-be-deleted file from `${CONFIG_DIR}` (it copies whenever
  the file exists locally, regardless of operation type), so the
  existing rollback path restores it correctly if validation fails.

- **Reproduction**: PR that adds `packages/foo.yaml` and deletes
  `packages/_foo.yaml` in a single commit. Pre-fix: `_foo.yaml`
  remained on disk and continued failing the package slug validator.
  Post-fix: both operations propagate; `_foo.yaml` is removed on the
  next sync.

- **Field incident**: 2026-05-30, observed in
  `JLay2026/home-assistant-config#43` (rename of `_shared_alert_macros.yaml`
  to `shared_alert_macros.yaml`). The rename PR merged cleanly upstream
  and the new file synced to `/config/packages/` at 18:23:05 UTC, but
  the old underscored file remained — producing
  `Setup of package '_shared_alert_macros' ... invalid slug` errors at
  every subsequent reload (~20s cadence via the addon's sync loop).
  Manually deleting the orphaned file from `/config/packages/` cleared
  the error.

- **No new options**; no schema changes; no permission changes; no
  behavior change for adds or modifies. Backup and rollback paths
  unchanged.

## 1.6.2

Sprint 6 housekeeping release from the 2026-05-25 code-and-security
review — closes the remaining LOW-severity items that warrant action
(L12, L16, L18, L19). No new MEDIUMs in this sprint; **M8** (commit
signature verification) remains deferred per the review's "Backlog
(when warranted)" classification. **L17** (git release tags) is an
out-of-tree operator action documented separately.

- **Fix (Review L12)**: every `cp` call that moves config content now
  passes `-p` to preserve timestamps. Lets operators correlate
  `ls -l /config` mtimes against GitHub commit authorship times.
  Cosmetic but useful for forensics.

- **Fix (Review L16)**: `/tmp/.sup_resp_body` and `/tmp/.sup_resp_code`
  are now created via `mktemp` with unique per-PID suffixes; a `trap
  ... EXIT` cleans them up on add-on stop. Today's single-threaded
  loop wouldn't have raced, but a future feature (background export,
  parallel agent calls) would have collided on the shared paths.
  Future-proofing with no behavior change for current code.

- **Feature (Review L18)**: New optional config `pre_sync_backup_name_prefix`
  (default `"gitops-pre-"`, backward compatible). Operators who keep
  their own manual `gitops-pre-*` HA backups can pick a different
  prefix to avoid collision with the add-on's retention prune. WARNING
  in DOCS: changing the prefix abandons any backups taken under the
  prior prefix — they look like operator backups and are never pruned.

- **Fix (Review L19)**: Defensive INFO log in `prune_pre_sync_backups()`
  when Supervisor returns an empty backup list AND lifetime sync_count
  is ≥ 5. Surfaces the case where a future HA major-version renames
  `.data.backups` and the jq filter silently no-ops. Threshold filters
  out false positives from brand-new installs.

- **New options**: `pre_sync_backup_name_prefix: "str?"` (default
  `"gitops-pre-"`).

- **No permission changes**; no behavior change for operators using
  default settings; no new dependencies.

## 1.6.1

Sprint 5 P2 from the 2026-05-25 code-and-security review — closes the
M3 finding (PAT written to `.git/config` on disk inside the persistent
`/data/` volume). PAT is now passed to git via an inline credential
helper that reads from a process env var at git-command time, so the
PAT never lands on disk.

- **Fix (Review M3)**: PAT no longer written to `.git/config`. New
  pattern:
  1. Top of `run.sh` exports `GH_CONFIG_SYNC_PAT="${PAT}"` into the
     process environment along with `GIT_TERMINAL_PROMPT=0`.
  2. A credential helper is configured as an inline shell function:
     `!f() { echo username=x-access-token; echo "password=${GH_CONFIG_SYNC_PAT}"; }; f`
     The literal string `${GH_CONFIG_SYNC_PAT}` is what `git config`
     stores in `.git/config` — bash expands it at git-command time,
     not at config-write time. The PAT itself is never written to
     disk.
  3. The initial clone uses `git -c credential.helper=...` inline so
     the very first authentication needs no on-disk credential.
  4. After clone (or on every startup for existing repos),
     `git remote set-url origin "${REPO}"` is run to ensure the
     remote URL is the plain HTTPS form with NO PAT embedded. This
     idempotently cleans any PAT-in-URL config left from v1.5.x or
     v1.6.0 on first v1.6.1 startup.

- **Upgrade behavior**: existing v1.5.x / v1.6.0 deployments with
  PATs already in `.git/config` get cleaned on first start of v1.6.1
  — the `remote set-url origin "${REPO}"` and `git config
  credential.helper ...` calls overwrite the prior PAT-embedded URL
  and (for set-url) write a clean URL back. No operator action
  required.

- **Threat model improvement**: prior versions left the PAT in
  `/data/repo/.git/config` (persistent across container restart) and
  in `git remote -v` output (live, only when add-on is running, but
  still visible to anyone with `docker exec`). v1.6.1 leaves the PAT
  only in `/proc/<pid>/environ` of the running `run.sh` process and
  its `git` subprocesses — ephemeral, gone on add-on stop.

- **No new options**; no schema changes; no permission changes; no
  behavior change in the happy path. The credential helper pattern
  is functionally equivalent to URL-embedded credentials from git's
  authentication-protocol perspective.

- **No new config option for `GH_CONFIG_SYNC_PAT`** — the env-var
  name is an internal implementation detail, not an operator-tunable.
  Operators continue to set `github_pat` in the add-on UI exactly as
  before.

## 1.6.0

(Older entries unchanged — see git history for the full file at the
parent of this commit.)
