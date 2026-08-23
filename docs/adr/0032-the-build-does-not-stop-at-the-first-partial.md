# The build does not stop at the first partial

**Status:** Accepted

A build handoff of `partial` means, in the schema's own words, *some slices landed, work OF MY OWN
remains*. It ended the repo on attempt one — and with it the whole change set, because nothing merges
until every repo is ready.

That is the most continuable condition in the run being treated as the least. The next invocation
then paid for Scope, Kickoff and a resume to stand exactly where this one was already standing, with
the same agent, the same branch and the same list of remaining slices.

So it is a budget now, like every other condition since
[ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md): continue from the branch as it
stands, up to `build.max_continuation_passes`, and RECORD what the budget cannot close.

## Why ADR 0027 missed it

ADR 0027 lists what it deliberately did not convert, and the first entry reads *"the build returned
no structured handoff — nothing is known about what landed"*. That is true, and it is a different
case: the `!dev` path, which already retried once with a bounded "hand off now" brief.

The line that actually stopped repos was the next one down — `status !== 'complete'` — and nobody
had written down why *that* was terminal, because it looked like the same thing. It is the opposite
thing. A missing handoff means nothing is known; a `partial` handoff means everything is known: what
landed, what remains, the measured cause, the commands run, and where work was parked. It is the
best-informed continuation point in the workflow.

A measured round-1 audit hit exactly this. One repo bumped its submodule pin, committed the
cross-cutting docs it could write, reported eleven remaining slices with a file:line cause, and
stopped. Its own handoff said *"Sequencing only, no human call needed"*.

## What the continuation is, and is not

**Not a restart.** The brief opens with what the previous pass said it did and what it said remained,
then requires the agent to re-read the ground rather than its own memory of it — `git log` for what
actually landed, `git status` for what is uncommitted, and the parked WIP commit or stash if one was
recorded, *before* writing anything new, so the same work is not implemented twice. What is already
committed is done and is not re-litigated.

**`blocked` gets the same ladder, a different brief.** Most "blocked" is a named obstacle worth one
honest attempt, so the brief names the cheap classes to rule out first — the harness or toolchain, a
service not standing up, a missing data precondition, a contract another repo owes that can be stubbed
behind an interface and declared. The repo's own `known_false_reds` comes before any environment
claim.

**A pass that moves nothing does not get spent again on the same words.** An unchanged `remaining`
escalates the brief the way a review stall does: the previous reading becomes a hypothesis to
disprove, not context to build on. Repeating an identical attempt is not progress.

**`cannot_fix` is the sanctioned exit**, on the same terms as everywhere else — refused without both
the evidence (a command and its exit code) and the cheaper classes ruled out first. Accepted, it ends
the passes immediately rather than burning the remaining budget to reach the answer it already has.

## What this does NOT make true

A recorded `partial` still keeps its repo out of `ready`, and still stops the merge. *Does not stop
at the first partial* means the passes happen; it does not mean an unfinished build ships. The record
now says which stopped it — the bound, or an evidenced refusal — instead of leaving a reader to
assume the run simply gave up early.

Three build-phase states stay terminal, and for the reason ADR 0027 gave: no handoff at all after its
own retry (nothing is known), a PR/MR that never opened (no number for any reviewer prompt), and a
target branch that cannot be made right (no computable diff). Those have no continuation point,
because there is nothing to continue from.

## The cost, stated plainly

**The build phase can now cost up to `1 + max_continuation_passes` agents per unfinished repo**, and
`budget-stopped` becomes more common again — the same trade ADR 0027 made, for the same reason: the
work is useful and it happens in one invocation instead of three. With budget exhaustion now the
dominant remaining stop, the ceiling is the number that decides whether a run finishes, and it counts
**output** tokens only — roughly 1/29th of a run's total.

## Configuration

`build.max_continuation_passes` (default 3). `0` restores the old behaviour exactly: a `partial`
handoff ends the repo on attempt one.

## Related

- [ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md) — the same conversion for the review
  loop, and the list this case should have been on.
- [ADR 0028](0028-the-test-suite-gate-does-not-halt-on-a-red.md) — and for the cross-repo gate. With
  the build included, no phase in the workflow now ends on its first bad answer.
- [ADR 0031](0031-a-submodule-pin-needs-a-pushed-commit-not-a-merge.md) — the other half of the
  audited stall this converts: that one removed the *reason* the repo could not build, this one
  removes the *stop* when a build is merely unfinished.
