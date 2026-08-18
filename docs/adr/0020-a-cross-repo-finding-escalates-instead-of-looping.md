# A cross-repo finding escalates instead of looping

**Status:** Accepted

## Context

A dev-cycle review round surfaced a performance must-fix in one repo (a hot-path query with no
supporting index) whose only real fix was a migration in a DIFFERENT repo of the same run — the
migration repo, vendored into the first as a read-only submodule that a guard rightly blocks the
fix agent from editing. The run had exactly one cross-repo route: the "UPSTREAM SYNC" clause,
which assumes the fix already EXISTS upstream and only instructs bringing a pin forward. Its
third branch — "the fix exists nowhere" — ended in free text (`remaining`) the workflow never
acts on.

Measured result: **five consecutive review rounds with zero code change.** Each round the
reviewer re-confirmed the same gap, the fix agent re-fetched the upstream, re-proved the fix was
absent there, re-proved it could not edit the submodule, and re-stated all of it in prose. The
stall detector existed and never tripped: its fingerprint keyed on the reviewers' free-text
`issue`/`title` fields, and every re-visit re-worded the same finding ("Round-3 re-visit …"), so
two fingerprints never matched. At `review.level: strict` the Improvement-ticket escape hatch is
deliberately disabled, so the loop had no exit at all short of the round cap — burning the
remaining rounds to arrive at the same human call the second round had already established.

Both agents were behaving correctly. The reviewer must keep flagging an unmet must-fix; the fix
agent genuinely cannot land a migration from a guard-blocked submodule checkout. The missing
piece was orchestration: nobody could ROUTE the fix to the repo that owns it.

## Decision

Four mechanisms, together, in `dev-cycle.js`:

1. **A structured declaration, on the dev side.** The review-fix handoff (`DEV_SCHEMA`) gains
   `upstream_fix_needed[]: {repo, finding, evidence}`. The fix agent — the one already doing the
   proving — declares "this finding's root fix lives in repo B", on the same evidence standard as
   a deferral: entries without observed evidence are ignored. The reviewer stays measurement-only;
   the orchestrator parses no prose.

2. **Tiered routing, in the loop.** A target repo that is part of the run gets a **scoped fix
   pass** there (the ticket's existing branch; the finding as the entire brief; the run's open
   PR/MR when still open, a follow-up PR/MR when already merged) followed by a **scoped re-gate**:
   the code-review gate over only the escalated commits, suite green required, refreshing that
   repo's `reviewed` checkpoint on approval. Never-fail-open holds — an escalated fix that cannot
   be re-gated does not ride the merge train. A target OUTSIDE the run halts `review-blocked-on`
   for a human: that is scope the ticket never authorized, and at `strict` there is deliberately
   no ticket-filing path to hide it in.

3. **Bounded, one level deep.** One attempt per (repo, finding) per run — a repeat halts. The
   escalated fix agent may not itself escalate — a chained cross-repo fix is a human call. All
   escalation work spends the same `MAX_REVIEW_ROUNDS` budget. The sync-forward (pin bump in the
   escalating repo) is carried explicitly to the next fix pass (`pendingSync`), not left to a
   reviewer happening to re-name the upstream.

4. **A phrasing-immune stall fingerprint.** `stallFp` now keys on WHERE findings sit
   (`comments[].file_line`, `blocking[].scope`) and never on the reviewer's wording of them, so
   the existing two-rounds-no-commit stall halt actually trips on the loops this route does not
   cover.

## Consequences

- The measured failure mode — N rounds of re-confirmation ending in a round-cap halt — becomes:
  one round to prove and declare, one escalation (fix + re-gate in the owning repo), one round to
  sync forward and resolve, one round to verify. Anything that cannot follow that path halts
  loudly with the decision a human actually has to make.
- An escalated fix is reviewed code: the scoped re-gate is smaller than a full re-review but is a
  real gate — approved + tests green — and it refreshes run state so a resume neither re-pays nor
  degrades the target repo.
- The declaration is falsifiable and auditable: evidence rides the schema, and a lazy or wrong
  declaration either gets filtered (no evidence), halts on repeat (fix did not settle it), or
  fails the re-gate.
- The stall detector now guards the routes this ADR does not: a genuinely unactionable finding
  stops after two no-commit rounds instead of running to the cap.
- What this does NOT do: widen ticket scope silently (out-of-run targets halt), recurse across
  three repos (one level, then a human), or replace the ticket-wide test-suite gate — the merged
  candidate still validates end-to-end afterwards.
