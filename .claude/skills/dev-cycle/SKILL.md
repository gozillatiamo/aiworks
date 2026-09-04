---
name: dev-cycle
description: Run the canonical multi-repo dev-cycle Workflow for one ticket through planning, build, PR, review, test gates, and the human ship boundary. Use when the user invokes dev-cycle or asks to process a ticket end to end.
---

Run the canonical `.claude/workflows/src/dev-cycle.js`; never improvise or restate its phases.

- Under Claude Code, run `node scripts/workflows/build.mjs dev-cycle` first, then invoke the
  Workflow tool with `scriptPath` set to the path that command prints, passing the user's
  original arguments. To resume, add `resumeFromRunId` to that same `scriptPath` call.
- Under Codex, run `./aiworks workflow dev-cycle --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow dev-cycle --harness cursor <original arguments>`.

**Never hand the Workflow tool `.claude/workflows/src/dev-cycle.js` itself**, and do not reach for
`name: "dev-cycle"` instead. The tool weighs the script FILE before it parses it — 524,288 bytes
launches, one more is refused, and no delivery parameter is exempt — while the authored script
carries about 176 KB of comments that only a human ever reads. The build strips whole-line
comments and nothing else, verifies that is all it removed, and refuses to write a file that
would not parse. If it reports a workflow over budget, that is a stop: say so and stop, because
the raw file is not a fallback, it is the thing that does not fit.

Stream phase output, respect every stop/gate, and return the runtime's final summary. A failed runtime command is a failed Workflow, never permission to reproduce the workflow manually.
