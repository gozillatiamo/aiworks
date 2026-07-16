# Headless workflows read config from a generated mirror, not the file

**Status:** Accepted

`workspace.config.yaml` is the source of truth for this workspace, and agents/skills
running in the main session read it directly. The headless Workflow scripts
(`.claude/workflows/dev-cycle.js`, `prd.js`) **cannot** — a workflow runs detached with no
filesystem access at runtime, so it can only see values that were already baked into the
script. We therefore *mirror* the config: `scripts/aiworks-config.sh` (run via
`scripts/aiworks config`/`sync`/`add`/`remove`) extracts the relevant fields and rewrites them
as `const` declarations inside the `AIWORKS:CONFIG` block of each workflow —
`const LANGUAGE`, `const REVIEW_LEVEL`, the repo table, and so on.

The block is delimited by
`>>> AIWORKS:CONFIG START … <<< AIWORKS:CONFIG END` markers and is **generated** — everything
between the markers is overwritten on the next regenerate.

## Consequences

- Editing `workspace.config.yaml` has **no effect on a workflow run until** you run
  `aiworks config` (or any command that regenerates) to refresh the mirror. This is the one
  non-obvious footgun; the workflow files and README both warn against hand-editing the block.
- Runtime-only values that must *not* be committed cannot live in the mirror — this is the
  constraint that shapes [0003](0003-personal-runtime-config-overrides.md).
- Values a workflow needs but that are personal/runtime must instead reach it through a channel
  that *is* read at runtime — the per-agent pointer the spawned agents carry.

## Rejected alternatives

- **Read the config at runtime** — impossible for a headless workflow; the whole reason the
  mirror exists.
- **Hand-maintain the constants in each workflow** — guaranteed drift from the source of truth;
  generating them keeps one authority.
