# The review loop does not halt on a finding

**Status:** Accepted

Every condition that used to stop a repo mid-review is now a **must-fix with its own attempt
budget**. When a budget runs out the condition is **recorded** and the loop carries on with
everything else. The round cap is the one terminal bound left.

What this must never become is a pass. A recorded blocking item keeps its repo out of `ready`, so
nothing is approved and nothing merges. *Does not halt* means the loop keeps working; it does not
mean an un-run gate reads as green.

## The distinction the old code did not make

A halt conflated two separate things:

1. **stop working this repo** — an early `return` out of the round loop
2. **block the merge** — `status !== 'ready'`, so the run returns before the merge gate

Only (2) is load-bearing. (1) was the expensive half: a repo that met one immovable finding on round
two abandoned the eight other findings it could have closed, and the next invocation paid for the
whole review phase again to get back to the same place. Measured on a four-repo ticket: seven
invocations, and at least two of them existed only to re-reach a state a previous one had already
computed.

So the two are separated. `blocking[]` carries (2). Nothing carries (1) any more except the round
cap.

## What each former halt became

**A fix-caused regression** was the clearest case: it halted for *loudness*, not because it was
unfixable — the developer who broke it is right there, holding the context. It is now handed
straight back with the regression detail, the specific instruction to start from the diff of the
push that caused it, and the rule that undoing the fix to clear the regression puts the original
must-fix back and does not count. Its own counter, because fix → regression → fix can oscillate and
would otherwise consume rounds other findings need.

**A stall** — the same unresolved finding set surviving a fix round with no new commit — was the
one halt with a genuinely good reason behind it: repeating an identical attempt is not progress, and
five no-commit rounds were measured ending in the same human call. So it does not halt, and it does
not simply repeat either: it **escalates the attempt**. The next brief names what did not move,
requires the previous reading to be treated as a hypothesis to disprove, insists the agent re-read
the actual threads rather than its memory of them, and says plainly that "I believe there is nothing
to change" is a claim about the *finding* and belongs on the finding's thread. Silence reads as a
stall and always will.

**A suite that could not run** is not a red suite — there is no verdict at all, so nothing in the
run can say the change does not break the tests. Most of the time it is genuinely fixable, so it
goes to the developer with the evidence the gate actually got, the repo's declared
`known_false_reds`, and the failure classes in the order they are cheapest to rule out: the harness
itself · the candidate stack not being up · a missing data precondition · genuinely absent from this
environment. Only the last cannot be fixed. The brief also carries the demand that made this worth
doing at all: **end with a receipt** — command, exit code, the runner's own summary line — because
no receipt means the gate still did not run, whatever changed.

**A load-test regression that stands** gets the same treatment in the other direction. The brief now
hands over the numbers *with their context* — candidate vs base sha, and the effective threshold as
`max(tolerance, the measured noise floor)` — because just over the line is one avoidable unit of
work per request while a multiple of it is structural, and those want different fixes. Then where
request-path time actually goes, cheapest to rule out first. Then the forbidden escapes, every one
of them tempting: do not relax a threshold, do not re-baseline, do not re-run hoping for a friendlier
sample, do not hide the work behind a flag the scenario does not exercise, do not cache in a way that
changes what a caller observes. Each of those makes the number go green without making the system
faster, which is the single outcome the gate exists to prevent.

**A cross-repo escalation** that did not land no longer ends the repo. One attempt per
(repo, finding) became a budget; a failed fix pass or a failed scoped re-gate retries within it.
A re-gate that does not approve still refuses to sync the fix forward — un-reviewed upstream code
must never ride the merge train, which is the whole reason that re-gate exists.

**A finding naming a finished, non-ready upstream** goes to the fix pass as a must-fix that may
escalate into that upstream through the route built for exactly this, with the two honest options
spelled out: route the root fix there with evidence, or resolve it inside this repo on its own terms
and say why that is a real fix rather than paper over the gap.

**More than one open PR/MR for one repo** is a must-fix plus a recorded item. Closing one stays a
human call, but this run's own MR has a computable diff, so the review is still real work.

## The sanctioned "cannot"

Two of those briefs end with a way to conclude that nothing can be done — a class-(d) environment,
or a cost inherent to the behaviour the ticket requires. Without it, an immovable condition grinds
its whole budget to reach the answer it had on attempt one.

`cannot_fix[]` is that channel, and it is deliberately expensive to use: refused without both
`evidence` (a command and its exit code, or the number) and `tried` (the cheaper classes ruled out
first). An unevidenced claim is dropped and the attempts continue. Accepted, it closes *that
condition's* attempts only — every other finding in the repo keeps being worked — and records the
condition, so the repo still cannot reach `ready`.

This is the same discipline
[ADR 0025](0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md) put on "the fix is out
of this gate's bounds", and for the same measured reason: that exact escape hatch, asserted once
without a second read, held a wrong diagnosis in place for two rounds.

## What is NOT converted, and why

Four states still stop a repo, because there is no loop to continue into:

- **the build returned no structured handoff** — nothing is known about what landed, so there is no
  diff, no PR and nothing to review
- **open-PR did not converge** — there is no PR/MR number, and every reviewer prompt needs one
- **a target branch that cannot be made right** — `git diff <base>...<head>` cannot be computed
  without that ref on the remote, so reviewers would produce findings about the wrong comparison.
  Expensive garbage is still garbage
- **`budget-stopped`** — nothing failed; the run ran out of the ceiling it was given

Converting these would not be robustness, it would be spending agents on questions that have no
answer yet. They are named here so the gap is deliberate rather than forgotten.

## The cost, stated plainly

**`budget-stopped` becomes a more common ending.** A repo that used to stop at round two now works
to the cap. That is the trade being made on purpose — the work is useful and it happens in one
invocation instead of three — but the ceiling has to be sized for it, and it counts **output** tokens
only, roughly 1/29th of a run's total.

**Loudness had to be rebuilt.** A halt was a banner mid-run; a recorded item is a line in a data
structure. So blocking items are bannered at the aggregation, given their own top-of-summary section
that the summary agent is told not to soften into "minor issues", and named in the incomplete-run DM.
Without that, this change would have traded a visible stop for a silent degradation.

## Configuration

`review.max_rounds` (14) is the terminal bound and is clamped to at least 1 — a `0` would mean the
loop never runs and every repo returned unresolved having done nothing. The per-condition budgets
default to 3: `review.max_regression_fixes`, `review.max_stall_reattempts`,
`review.max_escalation_attempts`, `test_suite.max_suite_repair_attempts`. `loadtest.max_fix_rounds`
moved 2 → 3, since its brief now carries enough for an extra round to be a different attempt rather
than a repeat.

## Related

- [ADR 0021](0021-a-passed-gate-is-recorded-not-re-derived.md) — a passed gate is frozen. Unchanged:
  this is about a gate that has *not* passed.
- [ADR 0022](0022-the-run-ticks-its-own-approval-the-merge-stays-human.md) — the approval tick is
  ticket-wide, which is what makes a recorded blocking item bite: one repo carrying one keeps the
  whole ticket from being approved.
- [ADR 0024](0024-a-qa-attributed-fix-is-quality-checked-not-re-reviewed.md) — the scoped quality
  check on an attributed fix, whose per-attempt bound is the pattern the budgets here follow.
- [ADR 0028](0028-the-test-suite-gate-does-not-halt-on-a-red.md) — the same conversion for the
  cross-repo test-suite gate, which this ADR deliberately left alone. The two together mean no phase
  in the workflow ends on a finding.
- `docs/agents/review-ledger.md` — a finding is raised once; this document is about what happens
  when it cannot be closed.
