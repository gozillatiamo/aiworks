# The framework follows the Superset-to-Paradev rename, and keeps the names the platform owns

**Status:** Accepted. Amends [ADR 0041](0041-a-fresh-worktree-knows-its-repos-before-sync.md) and [ADR 0042](0042-a-linked-worktree-inherits-the-main-checkouts-plugins.md); the names in ADR 0003, 0028, 0035, 0041 and 0042 predate this rename and are not rewritten.

## Context

The desktop tool the framework runs its worktrees in was renamed from Superset to Paradev. The tool's home moved from `~/.superset` to `~/.paradev`, its project directory from `.superset/` (with `config.json`) to `.paradev/` (with `config.toml`), and its CLI is now `paradev`. The app still injects `SUPERSET_*` variables (`SUPERSET_ROOT_PATH`, `SUPERSET_ENV=local|cloud`, `SUPERSET_HOME_DIR`, `SUPERSET_WORKSPACE_NAME`, and more), and its CLI reads `SUPERSET_API_KEY`. No `PARADEV_*` variable exists.

Two things broke:

- Our setup used `SUPERSET_ENV` as its own env-file switch (`symlink|copy|skip`) and treated any other value as `copy`. The platform sets `SUPERSET_ENV=local|cloud` on every step, so under the app every adapter `.env`, every repo `.env` and the Terraform init were copied instead of symlinked, with no warning.
- `aiworks gc` read `~/.superset` and called `superset`. A weekly launchd job with the default `PATH` can find a stale `superset` binary and never reach `~/.paradev/bin`, so a wrong live list would make live worktrees look orphaned.

## Decision

Rename what the framework owns; keep what belongs to the platform or to an operator's existing `.env`.

- **Rename:** the `.superset/` directory to `.paradev/`, `config.json` to `config.toml`, the lifecycle guard (`scripts/aiworks-paradev.sh`, run by `aiworks add` and `aiworks sync`), the doc and selftest file names, the Python classes and attributes of slack-dispatch, `~/.paradev`, and the prose. The CLI is called as `paradev`; gc has no fallback to `superset`.
- **Keep:** every variable the platform injects or reads (`SUPERSET_ROOT_PATH`, `SUPERSET_ENV`, `SUPERSET_HOME_DIR`, `SUPERSET_API_KEY`, the rest), the external package `@superset_sh/sdk`, and the slack-dispatch `.env` key names (`SUPERSET_PROJECT_ID`, `SUPERSET_HOST_ID`, `SUPERSET_AGENT_PRESET`, `SUPERSET_BASE_BRANCH`), per [ADR 0005](0005-deployed-env-triage-and-the-prod-gate.md): a renamed key reads as silently unconfigured on every machine.
- **Never reuse a name the platform could inject.** The framework's own switches are `PARADEV_LOCAL`, `PARADEV_ENV_FILES`, `PARADEV_DB_DATA`, `PARADEV_SIGNING` and `PARADEV_PRODUCTS`. The env-file switch is not `PARADEV_ENV`, because the platform may inject that name later and repeat the collision.
- gc takes its home from the platform's `SUPERSET_HOME_DIR`, default `~/.paradev`; the framework's own `SUPERSET_HOME` is dropped.
- The lifecycle is declared in `.paradev/config.toml` (`[setup]`, `[terminals.dev]`, `[archive]`). The guard writes it when missing and only warns when an existing file lacks a hook.

## Consequences

- The old switch names are still honoured, with a warning: `SUPERSET_LOCAL`, `SUPERSET_DB_DATA`, `SUPERSET_SIGNING`, `SUPERSET_PRODUCTS`, and `SUPERSET_ENV` only when it carries `symlink`, `copy` or `skip`. Ignoring `SUPERSET_DB_DATA=copy` would turn into symlink mode, which deletes the per-worktree DB copy. An unknown mode value warns and is treated as `skip`, never as `symlink`: symlink mode deletes a real per-worktree copy, so a typo must not select it. Mode case and surrounding space are ignored.
- A one-time migration: `aiworks sync` in the root workspace moves untracked state from `.superset/` to `.paradev/` without overwriting anything and without touching `~/.superset`. One `/.superset/` line stays in `.gitignore` for workspaces not yet migrated.
- Worktrees created before the rename keep dangling symlinks into the old directory until `aiworks setup` is re-run there. An installed gc schedule keeps its old plist until `aiworks gc --install-schedule` is re-run.
- The slack-dispatch daemon's `PATH` must contain `~/.paradev/bin`.
- gc passes `--local` to `paradev ws list` and `paradev ws archive`: without it the CLI answers for cloud workspaces on an account that has them, which would make every local worktree look like an orphan. `ws delete` no longer exists.
- Verified against a real local workspace created from this change: `config.toml` is accepted and `[setup]` runs `./.paradev/setup.sh`; env files are symlinked while the platform's `SUPERSET_ENV` is set; `[terminals.dev]` does not start on creation; `[archive]` runs `teardown.sh` and a failing teardown does not block the archive; Paradev writes nothing into `.paradev/run/` or `.paradev/logs/`; `paradev ws list --local --json` is an array carrying `worktreePath` and `id`.
- A legacy `.superset/config.json` left in the root checkout is not used: the same test workspace was created while its project's root checkout still carried one and no `.paradev/`, and Paradev ran the workspace's own `.paradev/config.toml`. Both files in the SAME tree was not tested; this change removes the tracked `config.json` and ignores `/.superset/`, so a worktree cannot carry one.
