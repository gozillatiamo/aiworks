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

One request, one ticket (docs/adr/0044): a ticket key or URL, a path under `agent_logs/`, or
free text is a SINGLE request and always produces exactly ONE ticket, however large; only a BRD
(`phase-N`, `docs/brd/<key>.md`, a doc-space URL, a one-word work-key) yields one ticket per
feature. Pass `args: { brd: <ref>, single: true|false }` to override the classifier. Before
invoking, collect every image the user pasted into the conversation — the harness shows each as
`[Image: source: <path>]`, stored under the session `images/` dir — and pass the absolute paths
(optionally `{ path, caption }`) as `args.images`; the Product Owner attaches each one and embeds
it in the description core under `## Evidence`. A missing path is a warning, never a failure.

Stream phase output and return the runtime's final summary. Use the existing `prd-design` skill when its documented authenticated Figma split is required.
