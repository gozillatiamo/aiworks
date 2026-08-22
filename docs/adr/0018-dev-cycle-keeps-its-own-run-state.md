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

## Addendum — the `planned` row now skips, guarded by a ticket fingerprint

> Two fields were added to these rows later, by
> [ADR 0025](0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md): `base_branch` on the
> `planned` row (the base this repo was planned against, authoritative on resume), and `plan_sha` —
> the live plan's fingerprint on a `planned` row, and on a `built` row the fingerprint of the plan
> that build was made FROM. The second closes a deadlock this document's own rules create: `built`
> is proven by a branch head, a re-plan does not move the head, so a corrected plan could be written
> and then never built. Read that ADR before changing any degrade rule below.

The original decision recorded that "a `planned` milestone is recorded but never used to skip anything",
resting on two premises. A real multi-repo run disproved both. The kickoff planners were NOT inside the
engine's cached prefix: the run was re-invoked with a fresh `Workflow()` call and no `resumeFromRunId`,
which is an ordinary way to re-invoke a ticket and leaves the engine's cache doing nothing — so the
run-state row is the only mechanism that can make a resumed Kickoff cheap, and 8-9 planner spawns at
300k-800k tokens each were paid again per invocation. And a plan row CAN carry the reviewers' bar: it now
records `title` and `acceptance` alongside `ticket_fp` and `plan_path`.

A `planned` row is therefore skippable, but only when the plan file it points at still exists and is
non-empty AND the ticket's fingerprint — title + acceptance criteria, normalized and hashed, since no
tracker provider's adapter exposes an `updated` timestamp (see the addendum below for why the comment
count that originally rode along with these was dropped) — matches the fingerprint recorded at plan time.
This ticket was hand-edited mid-run once already, so an unguarded skip would have built every repo against
superseded acceptance criteria. On a mismatch, EVERY `planned` row for the run is invalidated and all
repos re-plan: a partial re-plan is the worse failure, because it leaves sibling repos planned against two
different readings of one ticket.

Two consequences for the loader. First, `planned` is proven by its PLAN FILE, not by a branch head: the
loader measures `wc -c` on the recorded `plan_path` and stops comparing `head_sha` for that milestone —
under the head rule every `planned` row degraded the moment the build made its first commit (and the
test-suite repo's row degraded immediately, since its branch is created at build time, not plan time), so
the skip could never have fired. Every other milestone keeps the head rule unchanged. Second, a published
plan Artifact's URL is recorded as its OWN row (`<repo>-artifact_published.json`, written by the main
session — the only holder of the `Artifact` tool) rather than patched into the `planned` row, preserving
this ADR's unique-path-per-(repo, milestone) property: no read-modify-write, no row an agent can corrupt
by re-emitting one it did not own. Later runs pass that URL back so the page is updated in place; a repo
whose Kickoff was skipped renders no page and so is published not at all.

## Addendum — upstream degrade, per-suite gate rows, and a fingerprint without the comment count

**Upstream degrade.** A `built`/`reviewed` row only proves ITS OWN repo's head — it says nothing
about whether the upstream it was built or reviewed against is still the upstream that would be
built against today. A measured run hit exactly that gap: a DB repo's head moved after its own
`built` row was recorded, a downstream service repo's build (which carries the submodule-pin
clause that would have caught this) was skipped because its OWN row still looked fresh, and the
reviewer ended up reading a stale vendored schema. The fix walks every scoped repo's declared
`depends_on` edges to a fixpoint: whenever an upstream's `built`/`reviewed` row is itself degraded
or missing, every downstream row degrades too, in one pass, so a chain (`db` → `svc` → `e2e`)
propagates instead of stopping at the first hop. This runs in JS, in the Scope stage, right after
`out_of_reach` is settled — deliberately NOT inside the run-state loader prompt, because
`depends_on` does not exist until Scope has run, and the loader runs BEFORE Scope. Doing it in JS
also makes it free (no extra agent call) and directly testable offline. An upstream with no row at
all is not itself a degrade signal — nothing was proven for it, so there is nothing to invalidate,
and the downstream's own `built`-row skip for that upstream simply never fires.

**Per-suite gate rows.** The original single `all-test_suite.json` row assumed one test-suite repo
per run. A ticket can scope more than one (an E2E suite and an API suite, say), and each needs its
OWN resume proof — a `${repo}-test_suite.json` row, mirroring the `built`/`reviewed` naming already
used per repo. A pre-existing `all-test_suite.json` row from a run before this split matches no
suite repo's new row name, so the first resume after this change simply runs every gate once more.
That is the safe direction (never a false skip) and is expected to cost exactly one extra run, once.

**Fingerprint without the comment count.** The original design hashed title + acceptance criteria
+ comment count, on the reasoning that a comment can carry a real requirement change a title/body
edit would miss. In practice this was self-defeating: the run itself posts comments (status moves,
gate results, dev-status updates), so the comment count climbs on every single invocation, and the
very next resume read a changed fingerprint and re-planned every repo from scratch — the fingerprint
was invalidating the plan it had just written. Own-comment exclusion was considered and declined:
excluding comments authored by "the run itself" needs a stable identity to filter on, and none is
cheaply available — the Jira adapter renders each comment as `author.displayName` (falling back to
`accountId`), while the adapter's own identity lives only in `scripts/tracker/.env` (`JIRA_EMAIL`),
which is unreadable by policy and would not match a displayName even if it were read. No provider
adapter exposes a self-identity call (`myself`/`users/me`/`viewer` — grepped, none exist), and
adding one is new adapter surface bought for a single hash input. So the fingerprint now hashes
title + acceptance criteria only. The accepted trade: a requirement change that lives ONLY in a
comment, never folded into the ticket's body or acceptance criteria, no longer invalidates a plan —
that belongs in the body/acceptance in the first place, and the alternative (measured) invalidated
every plan on every resume.
