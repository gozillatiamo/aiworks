---
name: prd
description: Run the canonical PRD Workflow from a BRD reference, phase, path, URL, or ticket through recon, briefs, consultation, optional investigation/design, ticketing, and summary.
---

Run the canonical `.claude/workflows/src/prd.js`; never improvise or restate its phases.

- Under Claude Code, run `node scripts/workflows/build.mjs prd` first, then invoke the Workflow
  tool with `scriptPath` set to the path that command prints, passing the user's original
  arguments. To resume, add `resumeFromRunId` to that same `scriptPath` call. There is no
  `name: "prd"` to reach for: the authored script lives under `src/`, where Claude Code's
  workflow loader does not look, so that this skill is the one and only `/prd`.
- Under Codex, run `./aiworks workflow prd --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow prd --harness cursor <original arguments>`.

Stream phase output and return the runtime's final summary. Use the existing `prd-design` skill when its documented authenticated Figma split is required.
