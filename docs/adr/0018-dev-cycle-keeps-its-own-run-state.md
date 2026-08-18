# dev-cycle keeps its own run state

**Status:** Accepted

`dev-cycle` is a single long `Workflow` script. The engine that runs it caches by call
sequence: the longest unchanged prefix of `agent()` calls in the persisted script returns
from cache, and the first call that is new or edited — and everything after it — runs live.
That cache has no idea what a repo's build actually produced; it only knows whether the
`agent()` call that produced it is byte-identical to last time.

The decision: `dev-cycle` records its own per-repo milestones — `planned`, `built`,
`pr_open`, `reviewed`, plus the run-level `test_suite` gate — as git-ignored files, and skips
a milestone whose recorded head still matches the live branch. The engine's cache stays
exactly what it is; this is a second, independent layer that survives a script edit the
engine's cache cannot.

## Why it qualifies on all three counts

- **Hard to reverse.** Once phase agents are writing checkpoint rows and later invocations
  read them, removing the mechanism does not just delete a feature — it either leaves rows
  being written that nothing reads, or breaks a resume behaviour a person has learned to
  expect (a rebuilt repo silently re-running from scratch again).
- **Surprising without context.** A workflow script that has no filesystem access
  (`agent()`/`parallel()`/`log()` are the only primitives; `Date.now()`, `Math.random()`, and
  an argless `new Date()` all throw) and yet persists state across invocations reads like a
  mistake until the reader knows that every read and write of that state has to travel through
  an agent's shell — there is no other I/O available to it.
- **A real trade-off, not a free win.** A stale checkpoint is worse than none: trusting a
  `built` row for a branch that has since moved would ship the wrong commit. The mitigation is
  that the loader — not a remembering human — compares the recorded head against
  `git rev-parse --verify` on the live branch and degrades the row the moment they disagree.
  The price of that safety: a `deferred` build is never checkpointed at all (the deferral
  itself — `deferred[]`/`met_acceptance[]` — does not fit in a flat row, so a resumed deferred
  repo always rebuilds), and a `planned` milestone is recorded but never used to skip anything
  (a plan row cannot carry the acceptance criteria the reviewers need as their bar, and the
  kickoff planners were already inside the engine's own cached prefix in the run that prompted
  this, so skipping them buys nothing).

## What that cost

One real run — one ticket, 8 scoped repos — was launched once and resumed 4 times. Measured
from its journal and 143 agent transcripts: 143 agent spawns, 141 distinct cache keys — only 2
repeats, so essentially nothing content-identical ever ran twice. The persisted script had to
be hand-edited immediately before every one of the 5 invocations, always at or after the Build
stage, because the base branch was not a real argument (see the sibling change that made it
one). So the cached prefix was the same tiny head every time — scope, the tracker status move,
the workspace-root probe, the 8 kickoff planners, the plan guard, the publish request — and the
cache broke at the first `Build` call on all four resumes: one repo's build ran 5 times, six
repos' builds ran 4 times each, one repo's first review round ran 4 times. One of those
hand-edits killed a resume outright with `Script parse error: Unexpected token (…)` on an
unescaped apostrophe in a phase description.

Separately, in the same run, several per-repo adapter calls resolved against the wrong repo
because the VCS adapter assumed the current working directory named the repo, and a
`parallel()` wave of per-repo agents shares one Bash cwd. That is a different fault (fixed by
scoping the adapter itself, `VCS_REPO`) — it is mentioned here only because it is part of why
the same run needed 4 resumes in the first place.

## What it is not

This is not a general workflow-state facility, and it is not a substitute for the engine's own
cache — that cache still does the cheap, common case (an invocation that changes nothing about
the script re-runs nothing). This mechanism only covers what the engine's cache structurally
cannot: milestones for one ticket's run, recorded as git-ignored files, verified against git
on every read rather than trusted blindly. A tracker-unreachable run still writes build/PR/open
rows but never a `reviewed` row (the only agent trusted to write it is the one already
confirmed to hold git — `moveTicket`'s `developer`, which short-circuits when the tracker is
unreachable), so that one row is a known, accepted gap in a best-effort run.

## Consequences

- A resumed invocation pays for a repo's build/PR/review exactly once, as long as the branch
  it produced has not moved since.
- The first invocation after this change ships pays a full, one-time cache invalidation: adding
  the run-state load call shifts every `agent()` call after it, so nothing in Build or later is
  cached on that first run. Every run after that is the one that benefits.
- The state lives as one file per checkpoint (`<repo>-<milestone>.json`), not one shared file —
  because no phase agent's tool grant includes a shell-append primitive: `developer.md`,
  `qa-runner.md` and `documentor.md` are each an explicit allowlist of specific Bash patterns,
  none matching `printf`/redirect, so a shared append-only file was silently unwritable by every
  agent asked to write it. Every one of them has the Write tool, which replaces a whole file —
  safe here only because the path is unique per (repo, milestone): up to eight parallel build
  agents never share a path, so there is no read-modify-write and no row an agent could corrupt
  by re-emitting one it didn't own. Its content is machine data, never prose, so it carries no
  localization surface.
