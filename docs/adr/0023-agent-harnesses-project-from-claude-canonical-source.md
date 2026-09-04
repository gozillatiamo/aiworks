# Agent harnesses project from the Claude canonical source

**Status:** Accepted

The authored agent configuration remains under `.claude/`, with the shared MCP registry in
`.mcp.json`. An organization declares its supported Harness set in `workspace.config.yaml`;
`aiworks sync` then projects those Harnesses at the workspace root and in every repo. Compatible artifacts
use symlinks, while incompatible formats are generated and guarded by Harness-specific `--check`
commands. A missing safety mapping fails closed rather than silently widening an agent.

Codex's current native custom-agent hook path does not expose reliable role identity to project
tool hooks. The conservative mapping therefore makes every native role without canonical
`Write`/`Edit` read-only, while the shared Workflow runtime supplies the role identity needed for
the finer default-deny tool guard. Codex also re-applies the parent turn's live permission override
to spawned agents, so native role TOML is not treated as an enforcement receipt; permission-sensitive
role work runs through the Workflow runtime. A safe false denial is preferable to an invisible
permission widening.

Cursor and Codex execute the same canonical `.claude/workflows/src/*.js` through a shared local
Workflow runtime instead of carrying rewritten workflow copies. Cursor routes workflow agents
through `auto`; Codex maps `opus`, `sonnet`, and `haiku` to GPT-5.6 Sol, Terra, and Luna while
preserving supported explicit effort names. Exact status-line appearance is a presentation
exception: each Harness receives its richest native form, but functional parity does not require
forking a Harness UI.

## Considered options

- A new provider-neutral source tree was rejected because it would migrate every existing Claude
  artifact and make the first parity change unnecessarily disruptive.
- Per-Harness copies were rejected because they create multiple authored sources and inevitable
  drift.
- Best-effort projection was rejected because silently dropped tool restrictions, hooks, or
  workflow validation would make an apparently available agent less safe than its source role.

## Consequences

First-run `aiworks setup` selects and bootstraps the organization-wide supported Harness set; later
setup runs are idempotent. A git-ignored local config may activate a non-empty subset for that
machine's CLI, plugin, status-line, and local MCP lifecycle, but never changes projections. Sync
reconciles projections in both directions, removing only generator-owned artifacts for a deselected
shared Harness. Skills remain canonical under `.claude/skills`, with
`.agents/skills` as a directory symlink for Codex discovery. Generated adapters cover agents,
rules, hooks, workflows, MCP servers, plugins, and native status lines, and completion requires the
non-destructive cross-Harness verification matrix.
