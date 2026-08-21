# A QA-attributed fix is quality-checked, not re-reviewed

**Status:** Accepted

## Context

The cross-repo test-suite gate does not halt on its first red. It classifies each failure, and a
failure it attributes to an app repo (`kind: 'app'`) goes to that repo's developer as a scoped fix,
inside a bounded repair loop the gate runs itself. Until now the step after that fix was a full
code-review approval over the fix diff: the repo's own `code-reviewer`, `approved:true` plus
`tests_green:true`, or the whole gate stopped.

Three things were wrong with that shape, and they compound.

**It re-derived a verdict the run already held.** That repo's code review passed in the Review
phase — one complete pass, every must-fix resolved, a green suite receipt, and an approval tick on
the PR/MR posted by the orchestrator ([ADR 0022](0022-the-run-ticks-its-own-approval-the-merge-stays-human.md)).
The ledger's whole rule is that such a gate is frozen and not re-derived
([ADR 0021](0021-a-passed-gate-is-recorded-not-re-derived.md)). This loop then asked that same
frozen gate to run again, for a diff of a few lines, and — because it ran as a fresh approval
rather than a re-visit — to re-answer a question the run had already recorded as settled.

**One rejection consumed the whole gate.** `test_suite.max_fix_rounds` promised the loop a budget of
rounds. A single non-approving re-review returned a halted result immediately, with rounds still
unspent: the developer never got the second attempt the config had granted, and a suite that would
have gone green on the next pass was reported as a failed gate. The selftest locked that in by name
(`halts_when_fix_not_reviewed_green`, `no_second_round_spawned`), so the behaviour was tested, not
accidental.

**And it was the wrong check for the actual risk.** Whether this fix WORKS is measured, not judged:
the gate re-runs the failing case against the pushed candidate. What no re-run can see is what the
fix cost to get there — a smell, a debt shortcut, an added round-trip on the flow it touched. Those
are precisely the two gates the Review phase ran (guardian, performance) and this loop did not.

## Decision

Four parts, all in `runSuiteGate` in `.claude/workflows/dev-cycle.js`:

1. **No code reviewer in this loop.** Dropped here and only here. The Review phase keeps its code
   gate unchanged, and so does the **scoped re-gate** a cross-repo escalation runs
   ([ADR 0020](0020-a-cross-repo-finding-escalates-instead-of-looping.md)) — that one judges commits
   this run had never reviewed at all, on a repo whose reviewer may never have seen them, which is a
   different question from a fix landing on a branch that already cleared its review.

2. **A scoped quality check instead — only where the repo declares one.** A repo with `guard:true`
   gets a guardian-engineer check, `perf:true` gets a performance-engineer check, both run in
   parallel when both are declared, and each judges ONE thing: does this fix diff introduce a
   smell/debt or performance regression its gate would have held the merge for at first review? The
   idiom is the scoped re-gate's — read only the new commits, no collateral change, raise nothing
   new, a finding outside the diff goes in `conclusion` for a human and never in `blocking`. It is
   not the configured static-analysis scan and does not need one: it is a read of a small diff
   against the bar that gate already applied to this repo. `gate_unavailable` is not a pass — an
   un-run check sends the fix back, like every other gate in this file.

3. **Rejection retries the fix, on its own bound.** A rejected check hands the same red back to the
   developer with what was rejected, inside the current round, up to `MAX_GATE_FIX_ATTEMPTS` — an
   independent counter, not a slice of the round budget. That split is deliberate. A round stays
   coarse (classify → fix every red → re-run the suite once), and the ordering is the load-bearing
   part: the check must clear BEFORE the suite is re-run, because a case whose QA-visible symptom
   happens to go green would otherwise release an unchecked diff onto the merge train with the
   green run as its only evidence. Exhausting the attempt bound halts the suite in the same shape as
   rounds-exhausted, naming the case: `quality check for <case> did not clear within N attempt(s)`.

4. **`test_suite.max_fix_rounds` default 2 → 3**, in the workflow's mirror and in
   `workspace.config.example.yaml`. The number now buys both the rounds and the per-red attempts,
   and the round no longer burns on the first sloppy fix.

## Consequences

- The loop is cheaper and finishes more often. One or two diff-scoped agents replace a full code
  review per red, and nothing in the loop now demands a suite receipt from a gate that cannot
  produce one — the guardian and performance roles hold no `scripts/dev.sh test` grant in this
  workspace, only the code gate does. Green stays where it is actually measured: the fix agent keeps
  the repo green, and the gate re-runs the case.
- **What is given up:** the code reviewer's judgement on this narrow class of fix — spec fidelity,
  "does this change belong here", the read of the fix against the ticket's bar. That is a real loss,
  not a wording change. It is accepted because the bar for this repo was judged once already, at
  Review, and because the failing spec IS the criterion this fix answers to: the gate re-runs it.
- **Accepted gap:** a repo declaring NEITHER `guard` nor `perf` gets no independent agent check at
  all for a QA-attributed fix. Its bar is the suite re-run plus the fix agent's own green — exactly
  what it had before this ADR, and exactly what its Review phase applies. Inventing a check for a
  repo that never had one would hold this loop to a higher bar than the review it follows. A repo
  that wants one declares the gate.
- A skipped review-shaped step reads as risky at a glance, so the reasoning has to travel with the
  code: the check that was dropped had already run, and the check that replaced it covers the ground
  the re-run cannot. `CONTEXT.md` carries **Scoped quality check** as a term of its own, distinct
  from **Scoped re-gate**, so the two are never collapsed in a later change.
- The reversal is on record. The config comment said an app bug is "re-reviewed, then re-run", and a
  test asserted the halt-on-first-reject. Both were deliberate and both are now wrong; anyone
  reading either in an older checkout should read this file next.
