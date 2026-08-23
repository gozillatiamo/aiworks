# A passed gate is recorded, not re-derived

**Status:** Accepted

A `dev-cycle` review is a loop over three gates — code review, the static-analysis gate, the
performance gate — each of which does **one** complete pass and then only *re-visits* its own
findings. That contract was already written into the prompts. It was enforced by two local
variables, `didFirstReview` and `done`, which live exactly as long as the process does.

[ADR 0018](0018-dev-cycle-keeps-its-own-run-state.md) gave the workflow per-repo milestones so a
resumed invocation would not re-pay for work already proven — but the review stage never wrote
one. The `reviewed` row is written by the **merge** phase. So a run that ended anywhere between
"all three gates passed" and "the merge agent ran" left no record that the review had happened
at all, and the next invocation opened the loop in first-review mode. Three fresh gates then
re-derived a whole new finding set on a branch that had already been reviewed, and posted must-fixes
that were not regressions from any fix — findings the developer had never been given the chance
to address. Observed on a real 8-repo ticket: five repos reached `pr_open`, only the three that
merged carried a `reviewed` row.

The decision, in two parts:

1. **Each gate checkpoints its own outcome**, one row per repo per gate
   (`<repo>-gate_review.json`, `-gate_guard.json`, `-gate_perf.json`). The row carries
   `first_pass: true` — meaning *this gate has done its one complete review* — and a status of
   `done` only when the gate genuinely passed. A later invocation rehydrates both facts before
   the loop opens: a gate with `first_pass` resumes in **re-visit** mode, and a gate with `done`
   is not re-run at all.
2. **A gate's finding set lives on the PR/MR, not in a file.** The threads a gate opened *are*
   its closed finding set — durable, human-editable, already readable through
   `scripts/vcs/pr-threads.sh`. The ledger records only what the threads cannot: that a gate
   which found *nothing* nevertheless completed a pass. Because all gates post through one
   adapter token and therefore appear as one author, each comment is prefixed
   `[gate:review|guard|perf]`; the tag is what makes a thread attributable after the process
   that wrote it is gone.

The corollary the loop now enforces: a gate may not report a pass while a thread it owns is
unresolved. The forge's own "Resolve thread" marker is the record of whether a finding is
settled, so a pass sitting above an unresolved thread contradicts itself. The fixer ticks the
threads it fixed; the owning gate makes the final call — resolving what genuinely holds,
reopening what does not.

## Why it qualifies on all three counts

- **Hard to reverse.** The rows are a persisted format that agents write and later invocations
  read, exactly like ADR 0018's. Withdrawing it re-introduces the failure it was built for, on
  every resumed run.
- **Surprising without context.** "A passed gate is never re-run, even after later commits land
  on the branch" reads like a bug. The run-state loader is told, in as many words, **not** to
  degrade these rows against the live branch head — the opposite of the rule every other
  milestone obeys. Nobody would guess that from the code.
- **A real trade-off.** The alternative is to key the freeze to `head_sha` and re-run any gate
  whose branch has moved. That is more conservative, and it re-opens precisely the loop this ADR
  closes: every fix commit would revive all three gates in a mode where they may raise new
  findings. We chose the other side.

## What we accept in exchange

A gate that passed does not see the commits that land afterwards. A fix applied for the code
reviewer is never re-scanned by the static-analysis gate if that gate had already passed. This
is bounded rather than open-ended: the code reviewer's **test-green receipt** is deliberately
exempt — its *findings* stay closed, but it re-runs the suite on every round, because a fix that
resolves a thread while breaking a test is exactly what the round after a fix exists to catch.
Where a genuinely fresh sweep is wanted, that is a human call: delete the repo's `gate_*` rows,
or run `/ultra-review --fresh`.

### The one carve-out: a declared upstream that moved

"A passed gate stays passed" is about commits this repo's own loop produced. It is not a claim
about code the repo was *built against*. When a declared upstream's `built`/`reviewed` proof no
longer holds, the downstream's `gate_*` rows degrade with its `built` and `reviewed` rows
(`degradeRows`' default list). Without that, degrading `built`+`reviewed` alone bought nothing:
the review skip is an `OR` — `doneAt(R,'reviewed') || reviewers.every(done)` — so the repo
re-built against the new upstream head, then took the second arm and logged "every gate is
ledgered PASSED" over a re-pin / re-vendor diff no reviewer had read, with the previous
invocation's approve tick still standing on the PR/MR.

This does not re-derive a finding set, so the decision above is intact. The degraded row keeps
`first_pass: true` on disk and the ledger check reads that field alone, so the gate returns as a
**re-visit** scoped to the new commits — never a second first review. Proven by `G1b` in
`scripts/dev-cycle-gate-selftest.sh`.

`pr_open` is deliberately excluded: a moved upstream head does not change the base, the work
branch is unchanged, and the PR/MR is still open. Only a base change (`0025`) mis-targets it.

