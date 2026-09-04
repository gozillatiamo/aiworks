---
name: brd
description: Run the canonical BRD Workflow for a roadmap phase or strategy directive through research, strategy, product definition, feasibility, writing, and summary.
---

Run the canonical `.claude/workflows/src/brd.js`; never improvise or restate its phases.

- Under Claude Code, run `node scripts/workflows/build.mjs brd` first, then invoke the Workflow
  tool with `scriptPath` set to the path that command prints, passing the user's original
  arguments. To resume, add `resumeFromRunId` to that same `scriptPath` call. There is no
  `name: "brd"` to reach for: the authored script lives under `src/`, where Claude Code's
  workflow loader does not look, so that this skill is the one and only `/brd`.
- Under Codex, run `./aiworks workflow brd --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow brd --harness cursor <original arguments>`.

Stream phase output and return the runtime's final summary. A failed runtime command is a failed Workflow, never permission to reproduce the workflow manually.
