# A linked worktree inherits the main checkout's plugins

**Status:** Accepted. Amends [ADR 0035](0035-declared-plugins-install-at-project-scope.md).

## Context

ADR 0035 installs every declared Claude plugin at **project** scope, and buys reach by walking:
`ensure_claude_plugins` (`.superset/lib.sh`) reconciles the workspace root and every clone beside
it. `.superset/setup.sh` runs it unconditionally, so it also ran in every Superset worktree — and a
worktree path never has a registry entry, so every fresh worktree re-installed every plugin.

Measured 2026-10-04 (claude 2.1.289) on one real Superset session: setup registered 6 new project
entries for the worktree path (skill-creator, frontend-design, caveman, ponytail, debugging-code,
headroom-usage-indicator) that the main checkout already had, and the install re-serialised the
tracked `.claude/settings.json` — 26+/25− lines, all key moves, no change in meaning. Every fresh
worktree therefore started with a dirty tracked file that could end up in a ticket's PR, and
teardown never removed the registry rows, so the registry accumulated one stale set per worktree
ever created.

The decisive probe: with an isolated `CLAUDE_CONFIG_DIR` whose registry held ONLY the project
entries for the main checkout, `claude -p … --debug-file` in a linked worktree reported
`Found 9 plugins (9 enabled)` — the 6 workspace plugins plus 3 builtins — with their skills and
hooks loaded, and the trust prompt keyed `projects["<main checkout path>"]`. **Claude Code keys a
linked worktree's project by its main checkout.** The control, a plain `git init` directory with
the same `settings.json` and no registry entry, reported `Found 3 plugins` (builtins only): **an
independent clone does need its own install.** `claude plugin list --json` is not a valid probe
for this; it lists every registry row and its `enabled` flag reflects only the cwd's settings.

## Decision

1. **The unit ADR 0035 installs per is the Claude Code project key, not the directory.** A linked
   worktree shares its main checkout's key, so the install that serves it is the main checkout's.
   `git_main_checkout <dir>` resolves that key the way Claude Code does — through git
   (`rev-parse --git-common-dir`, physical paths), never through `SUPERSET_ROOT_PATH`.

2. **Delegate, do not drop.** In a worktree, `ensure_claude_plugins` reconciles the **main
   checkout's** registry entry against the **worktree's** declarations
   (`ensure_claude_plugins_in <main> <worktree>/.claude/settings.json`). When the main checkout is
   already installed — the normal case — that is a registry read and nothing more. A plugin the
   worktree's branch declares and the main checkout lacks is installed **in the main checkout**,
   so the doctor's rule that an owner command clears its finding still holds.

3. **Independent clones are unchanged.** A product repo cloned inside a worktree is its own
   project (the control above) and installs for itself, exactly as ADR 0035 decides. The rule is
   per directory, so a product repo that is itself a linked worktree inherits like the root.

4. **The doctor reads the main checkout's entry in a worktree.** The plugin-scope check resolves
   its project path through `MAIN_CLONE` when in a worktree, otherwise `declared plugin(s) not
   installed in this project` would fire in every worktree and no command could clear it.

## Consequences

- A fresh worktree's `.claude/settings.json` stays clean after setup, and the registry gains no
  entry for the worktree path. Stale entries from worktrees created before this change stay until
  removed by hand; an automatic cleanup would need `claude plugin uninstall -s project`, which
  edits the uninstalling project's `settings.json` (the trap ADR 0035 documents).
- **Trade-off accepted:** when the main checkout was never installed, or a worktree's branch
  declares a plugin the main checkout lacks, the install runs in the main checkout and may reorder
  the **main** checkout's tracked `.claude/settings.json` — the same cost the root's own first
  setup pays today.
- A bare main repo (common dir with no checkout) is outside this workspace's model;
  `git_main_checkout` falls back to the directory itself, which is the pre-0042 behaviour.
- `ensure_codex_plugins` and `ensure_harness_statuslines` are untouched: both are machine-global
  and idempotent and write neither a per-path registry row nor a tracked file.
- `aiworks update` still refreshes the copy of the project it runs in; run in a worktree root it
  finds no entry for the worktree path and skips, so refresh plugins from the main checkout. Mapping
  that loop through `git_main_checkout` is a follow-up.
