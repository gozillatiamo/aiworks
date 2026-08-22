# A reviewed-but-unresolved repo still gets the gate

**Status:** Accepted

The cross-repo test-suite gate ran only when **every** scoped repo reached `ready`. So a run with two
ready repos and one carrying a recorded blocking item never learned whether the change set breaks the
suite. That answer arrived a whole invocation later — after a person settled the blocking item, and
after the run paid for the gate it could have run the first time.

That is the round-trip [ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md) exists to
remove, surviving one level up: the loop stopped abandoning work inside a repo, and the run went on
abandoning work across them.

So the gate now runs anyway — **advisory**, and only when the candidate is fit to measure.

## When, exactly

`review-unresolved` is the one status where this is honest work. That repo is built, its PR/MR is
open, its review ran, and its fixes landed to their budgets: the branch is in the final state THIS
run can put it in. Measuring it tells you something true.

Every other status leaves the candidate unfit, and running the gate would buy an expensive answer
about a change set that does not exist yet:

- **`build-unresolved`** — no complete handoff, so the branch may be half-implemented or unpushed
- **`pr-unresolved`** — no PR/MR number, and the gate posts its result on one
- **`review-blocked-on`** — never reached review at all; its upstream did not land
- **`target-branch-halt`** — cannot compute its own diff (ADR-0025), never mind a candidate
- **no result at all** — a crashed pipeline. This is also what keeps the gate from reading a plan off
  `undefined`, which is why the condition is "every unresolved repo is `review-unresolved`" rather
  than "no repo is build-unresolved"

One unresolved repo in that second group and the run returns exactly as it always did.

## Advisory means full work, no authority

The gate runs its whole course: it triages, routes fixes to the repos that own them, re-runs, and
records what it cannot close. That is the point — the work happens now instead of an invocation
later, and reds attributable to a **ready** repo get fixed in this run.

What it must not do is act like a gate that passed on a finished change set:

- **no approval tick.** The tick is ticket-wide (ADR-0022), so ticking it would announce the whole
  ticket approved while a repo carries a recorded blocking item — precisely what that scope exists to
  prevent. All or nothing, so: nothing.
- **no ticket move.** Not to `Testing` (the change set is not ready to test) and not to
  `ready_to_merge`.
- **no run-state row.** The candidate is about to change when the blocking item is settled, so a row
  saying this gate is proven would let the next invocation skip a gate that never saw the final
  candidate. The gate brief says so explicitly, and `tsSkippable` refuses to skip on an advisory run
  regardless.
- **no relabelling of the run.** The repos were unresolved *before* the gate ran, so the ending stays
  `repo-unresolved`. A green advisory gate does not turn a blocked run into a passing one, and a red
  one does not turn it into `test-suite-failed` — that would bury the actual reason.

Both producers' records go out in **one** list, so the reader still gets a single "Blocking — needs a
person" section covering the review loop and the gate, and every item is carried to the next
invocation (ADR 0027 §Across invocations).

## The bug this nearly shipped

Two steps sat between the old early return and the gate, unreachable while any repo was unresolved:
the Review phase's **approval tick** and the **ticket move to `ready_to_merge`** — the latter also
writing a `reviewed` state row for every repo. Removing the return made both reachable, so the first
version of this change approved a ticket whose repo was carrying a blocking item and wrote a
`reviewed` row that the next invocation would have read as "review already done".

The suite's existing `nothing_approved` assertions caught it on the first run. They were written for
ADR 0027 and were not about this change at all, which is the argument for asserting the *invariant*
rather than the path: five scenarios that had nothing to do with advisory gating are what stopped a
false approval reaching a ticket.

The ready repos lose nothing they need from the skipped move. Their reviewers wrote their own
`gate_*` ledger rows, so a resumed run still skips their review on "every gate is ledgered PASSED".

## The cost, stated plainly

**A blocked run now costs a gate it used to skip.** That is the trade being made deliberately: the
alternative was paying for the same gate one invocation later, plus a second Scope, Kickoff and
resume to get back to it. It is a worse trade on a run that a person will abandon rather than fix —
and there is no knob to turn it off, because the condition already narrows it to candidates worth
measuring. If it proves wrong for some team's shape of work, that is the moment to add one, not now.

## Related

- [ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md) — the loop does not abandon work
  inside a repo. This is the same argument one level up, across them.
- [ADR 0028](0028-the-test-suite-gate-does-not-halt-on-a-red.md) — what the gate does with what it
  finds, which is what makes running it early worth anything.
- [ADR 0022](0022-the-run-ticks-its-own-approval-the-merge-stays-human.md) — the ticket-wide tick,
  and why an advisory run posts none.
- [ADR 0021](0021-a-passed-gate-is-recorded-not-re-derived.md) — a passed gate is frozen. An advisory
  gate is deliberately not recorded as passed: it did not judge the final candidate.
