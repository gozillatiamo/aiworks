---
name: dev-cycle
description: Run the canonical multi-repo dev-cycle Workflow for one ticket through planning, build, PR, review, test gates, and the human ship boundary. Use when the user invokes dev-cycle or asks to process a ticket end to end.
---

Run the canonical `.claude/workflows/src/dev-cycle.js`; never improvise or restate its phases.

- Under Claude Code, run `node scripts/workflows/build.mjs dev-cycle` first, then invoke the
  Workflow tool with `scriptPath` set to the path that command prints, passing the user's
  original arguments **plus `--invocation <stamp>`**, where `<stamp>` is
  `date -u +%Y%m%dT%H%M%SZ` read at that moment. To resume, add `resumeFromRunId` to that same
  `scriptPath` call — with a **fresh** stamp.
- Under Codex, run `./aiworks workflow dev-cycle --harness codex <original arguments>`.
- Under Cursor, run `./aiworks workflow dev-cycle --harness cursor <original arguments>`.

Mint the stamp every single call, and never copy the one a previous call used. The runtime
memoises a completed `agent()` on its prompt, and the workflow may not mint an id of its own —
Claude Code refuses to compile a script containing `Date.now()` or `Math.random()`. The stamp is
what a live-state probe (the run-state loader, the base reconciler, an approval or human-review
read) carries so it is asked again against the world as it is now; a producing step never carries
it, so a resume still replays the build it already paid for. A reused stamp silently returns
yesterday's reading of a branch, an approval, or a review thread. Neither harness CLI stamps for
you — `run.mjs` runs every agent unmemoised, so a stamp there changes nothing.

**Never hand the Workflow tool `.claude/workflows/src/dev-cycle.js` itself**, and do not reach for
`name: "dev-cycle"` instead. The tool weighs the script FILE before it parses it — 524,288 bytes
launches, one more is refused, and no delivery parameter is exempt — while the authored script
carries about 176 KB of comments that only a human ever reads. The build strips whole-line
comments and nothing else, verifies that is all it removed, and refuses to write a file that
would not parse. If it reports a workflow over budget, that is a stop: say so and stop, because
the raw file is not a fallback, it is the thing that does not fit.

Stream phase output, respect every stop/gate, and return the runtime's final summary. A failed runtime command is a failed Workflow, never permission to reproduce the workflow manually.
