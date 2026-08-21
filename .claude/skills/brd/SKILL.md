---
name: brd
description: Run the canonical BRD Workflow for a roadmap phase or strategy directive through research, strategy, product definition, feasibility, writing, and summary.
---

Run the canonical `.claude/workflows/brd.js`; never improvise or restate its phases.

- Under Claude Code, invoke the native `brd` Workflow with the user's original arguments.
- Under Codex, run `./aiworks workflow brd --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow brd --harness cursor <original arguments>`.

Stream phase output and return the runtime's final summary. A failed runtime command is a failed Workflow, never permission to reproduce the workflow manually.
