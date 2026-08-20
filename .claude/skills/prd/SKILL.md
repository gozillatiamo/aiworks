---
name: prd
description: Run the canonical PRD Workflow from a BRD reference, phase, path, URL, or ticket through recon, briefs, consultation, optional investigation/design, ticketing, and summary.
---

Run the canonical `.claude/workflows/prd.js`; never improvise or restate its phases.

- Under Claude Code, invoke the native `prd` Workflow with the user's original arguments.
- Under Codex, run `./aiworks workflow prd --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow prd --harness cursor <original arguments>`.

Stream phase output and return the runtime's final summary. Use the existing `prd-design` skill when its documented authenticated Figma split is required.
