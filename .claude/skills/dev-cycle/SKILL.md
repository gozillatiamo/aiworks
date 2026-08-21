---
name: dev-cycle
description: Run the canonical multi-repo dev-cycle Workflow for one ticket through planning, build, PR, review, test gates, and the human ship boundary. Use when the user invokes dev-cycle or asks to process a ticket end to end.
---

Run the canonical `.claude/workflows/dev-cycle.js`; never improvise or restate its phases.

- Under Claude Code, invoke the native `dev-cycle` Workflow with the user's original arguments.
- Under Codex, run `./aiworks workflow dev-cycle --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow dev-cycle --harness cursor <original arguments>`.

Stream phase output, respect every stop/gate, and return the runtime's final summary. A failed runtime command is a failed Workflow, never permission to reproduce the workflow manually.
