# The test-suite gate does not halt on a red

**Status:** Accepted

[ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md) made the same distinction for the
review loop, and left the cross-repo test-suite gate untouched. This is that gate: every condition
that used to stop it mid-run is now a **must-fix with a budget**, and what a budget cannot close is
**recorded**. The record is what keeps the merge shut. Nothing else does any more.

Same warning as 0027, and it matters more here, because this gate is the only thing in a run that
can say the change set does not break the suite: *does not halt* means the loop keeps working. It
never means an un-run gate reads as green.

## The distinction, again

A halt did two things: **stop working this suite** and **block the merge**. Only the second is
load-bearing. The first was expensive in a way that showed up in one place above all:

> a fix whose scoped quality check never cleared abandoned **every red after it in the same round**

Measured on a two-repo red set: one repo's un-cleared fix threw away a sibling red that the very
next round closed on its first attempt. The run ended, a person re-ran it, and the second invocation
paid for the whole gate again to reach a state the first one had already computed.

So `blocking[]` carries the merge block, per suite repo, and the gate's `for` loop keeps going.

## What each former halt became

**A fix whose scoped quality check never cleared** is the case above. It is recorded per failing
case and the loop moves to the next red. The un-cleared diff is still on the branch — that has not
changed and is not something a run should decide — but it can no longer be laundered by a later
green: a suite carrying a record cannot read as passed, whatever its own verdict says.

**A gate that could not run** got the treatment 0027 gave the review loop, and it needed it more.
Re-briefing the qa-runner was the only repair available, and re-briefing a runner does not make a
stack listen or a migration exist. So every repair attempt after the first sends a **developer** at
it first, on the four-class ladder — the harness · the candidate stack not up · a data precondition ·
genuinely absent from this environment — with the reminder that the candidate is UNMERGED, so it is
the ticket's own work branches that have to be answering. And the same demand: **end with a receipt**,
because no receipt means the gate still did not run, whatever changed.

**The round budget running out** is recorded with the reds it could not close, named, rather than a
`why` string that said "did not converge" and nothing about what was still red.

**A load regression that stands** is recorded with its numbers. The brief already carried everything
0027 gave it — candidate vs base, the threshold as `max(tolerance, the measured noise floor)`, where
request-path time goes, the five forbidden escapes — and ended by offering `cannot_fix` for a cost
inherent to the behaviour the ticket requires. **Nothing read that field.** An honest, evidenced
answer bought another round of the same work. It is read now.

**Every red already red on the base branch** used to break out silently and surface as "did not
converge", which reads as *this ticket broke something*. It gets its own record saying the opposite:
the change set is not what broke them, and a candidate cannot be validated against a red base. The
human action is about the base branch, not about the ticket.

**Reds the gate could not classify**, and **a gate agent that returned no verdict at all**, are each
recorded as themselves. Both used to arrive as the same generic red as a genuine functional failure.

## The hole converting these exposed

Only `kind: 'app'` reds were ever routed to an agent. A `prereq` red — the suite could not reach an
assertion — and an `automation` red — the spec itself is wrong — were classified, counted, and then
handed to nobody: the round counter ticked, the suite re-ran byte-identically, and the gate "did not
converge" having never once been asked to fix what it found.

Converting the halt without fixing that would have produced the worst of both: a loop that does not
halt and does not work either. So all three kinds route now — `app` to the repo the gate attributed
it to, `automation` to the suite repo whose spec it is, `prereq` to a code repo, since a precondition
failure usually names none.

Two guards came out of building it. An `app` red naming a repo this run does not carry is a finding
about **scope**, so it is recorded rather than sent to an unrelated repo: the prereq fallback would
otherwise have produced a confident wrong answer, which is worse than a record. And a round that
routed **nothing** — every red unowned or declined — does not re-run the gate at all: no branch
moved, so the verdict would be byte-identical.

## The sanctioned "cannot", per red

`cannot_fix` was already in the schema the gate-fix developer answers with, and already described in
the load-fix brief. It is now offered explicitly on every red and actually read, refused without both
`evidence` and `tried`, exactly as in 0027. Accepted, it ends **that red's** attempts — every other
red in the run keeps being worked — and records the condition, so the suite still cannot pass.

## The one retraction

A `gate-fix-unchecked` record for a case is **dropped** if a later round's fix for the same case
clears the same scoped check. That is a fresher statement by the same reviewer over a superset of the
same diff, and holding the earlier rejection would block a run that genuinely converged.

Nothing else is retractable. Every other record is a budget that ran out, and a budget does not
un-run.

## A fail-open this closed on the way past

A load suite whose specs pass but whose baseline comparison **loses** returns `passed: true`. The
gate agent's run-state clause said "write the checkpoint if and only if you are returning
passed:true" — so it wrote one. The run then halted on the regression, and the next invocation read
that row, skipped the gate as already proven, and merged a candidate nobody had measured.

The clause now says a load suite is green only when `loadtest.verdict` is `pass`, and every gate
brief issued after a blocking item exists tells the agent not to write a row at all. The workflow
cannot delete a row itself — run state is written by agents and read at Scope — so the instruction
has to be in the brief, and it is in every one that can still be reached.

## What is NOT converted

Nothing inside the gate halts any more. The **phase** still ends the run when any suite fails,
because that is the merge block doing its job: after the gate there is only Merge and Distribute, and
both are exactly what a recorded item exists to prevent. The suites themselves already fan out in
parallel, so a sibling suite's gate is never abandoned for another one's finding.

## Across invocations

A recorded item here survives a resume by the same mechanism 0027 describes: a `blocked` row per
repo, written by the closing agent, which vetoes `tsSkippable` — so a `test_suite` row that got
written anyway cannot let the gate be skipped over a standing record. The brief telling the agent not
to write that row is still there; it is now the belt, not the whole trousers.

## The cost, stated plainly

**A red run now spends more.** Three red kinds route where one did, an unrunnable gate buys developer
passes, and a round that used to end at the first un-cleared fix works every red. That is the trade,
and it is the right one — the work is useful and it happens in one invocation instead of three — but
the token ceiling has to be sized for it, and it counts **output** tokens only.

**A new status exists.** `test-suite-unresolved`: the suite is GREEN and the run is still blocked.
`test-suite-failed` (red) and `test-suite-unverified` (no verifiable result) keep their meanings.
Anything reading run status for "did the gate pass" must treat all three as no.

**Loudness is shared, not duplicated.** Blocking items from the gate use the same `blockingByRepo`
shape the review loop produces, so the summary's "Blocking — needs a person" section, the
incomplete-run DM and the banner all work unchanged, and a reader gets one list instead of two. The
banner itself moved into one helper for both producers: a banner improved for one and not the other
is exactly the drift these records exist to prevent.

## Configuration

**No new keys, deliberately.** Every condition here already had a bound: `test_suite.max_fix_rounds`
bounds the routed reds, `test_suite.max_suite_repair_attempts` bounds the unrunnable-gate repair (the
developer passes are interleaved inside it rather than given a budget of their own),
`loadtest.max_fix_rounds` bounds the load fixes, and the per-red quality-check retries keep their own
attempt bound. A fifth knob would have been a fifth thing to tune and nothing it could express.

## Related

- [ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md) — the same conversion for the review
  loop. This is its other half; the two together mean no phase in the workflow ends on a finding.
- [ADR 0024](0024-a-qa-attributed-fix-is-quality-checked-not-re-reviewed.md) — the scoped check whose
  non-clearing was the most expensive halt of the set. Unchanged: what it judges, and that an
  un-cleared fix never passes. Only the mechanism holding that line is different.
- [ADR 0021](0021-a-passed-gate-is-recorded-not-re-derived.md) — a passed gate is frozen. The
  run-state fix above is that rule being enforced honestly for load suites.
- `docs/agents/loadtest-gate.md` — the never-fail-open rule every test-suite gate obeys, and the home
  of the load suite's two-part verdict.
