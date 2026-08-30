# How a dev-cycle run ends

The design goal is that **budget exhaustion should be close to the only thing that stops a run**.
Everything else either finishes, or works to a bound and RECORDS what it could not close. This page
is the complete list, so "why did it stop?" is a lookup rather than a source read.

The rule underneath it (ADRs 0027, 0028, 0029, 0030, 0032): *a phase does not end on its first bad
answer.* Every former halt is a condition with an attempt budget; what a budget cannot close becomes
a **blocking item**, which keeps its repo out of `ready` and the ticket out of a merge — but never
stops the loop from working everything else in the same invocation.

## It finished

| Ending | What it means |
|---|---|
| `awaiting-human-ship` | The normal one. Reviewed, gated, validated; the `!` merge and distribute commands are handed to a person, because the squash-merge is outward and irreversible (ADR 0022). |
| `merge-skipped` | Same, with `vcs.auto_merge` off: the validated PR/MR is left open and the team is notified. |
| `already-satisfied` | Every scoped repo's criteria were already met by shipped code, each citation verified (ADR 0030). Nothing was branched. The answer is "close the ticket". |
| `dry-run` | `--dry-run`. Nothing outward happened, by request. |

## A person has to decide (not a failure, and no bound would help)

| Ending | Why no budget fixes it |
|---|---|
| `awaiting-plan-approval` | `planning.auto_approve: false` asked the run to stop here. Re-run with `--approve-plan`. |
| `nothing-deliverable` | Scope found no acceptance criterion this workspace can reach. There is nothing to build. |
| `nothing-delivered` | Every repo deferred and none met a criterion (ADR 0011). Reviewed, green and pointless is still pointless. |
| `scope-unresolved` | Two scoping attempts returned nothing structured, or the scope named only repos this workspace does not register. Nothing is known about which repos the ticket touches, so no branch, plan or build exists to continue. It used to `throw` — a stack trace with no summary, no state and no record; it now reports. |

## It ran out of budget

`budget-stopped` — `dev_cycle.token_budget` was reached at a phase boundary or between build waves.
Fully resumable: run state replays every milestone already proven. **This is the ending the design
funnels everything else toward**, and sizing guidance lives beside the key in
`workspace.config.example.yaml`. Two measurements to calibrate against: a four-repo run spent 232k
output tokens, and an audited six-repo run spent ~158k — both under a tenth of the 2M default.

## It worked to a bound and recorded what it could not close

These are the endings the "does not halt" ADRs produce. The run did the work; the record says what a
person still owes. **Raising the token budget does not change any of them** — read the summary's
"Blocking — needs a person" section instead.

| Ending | The bound that was reached |
|---|---|
| `repo-unresolved` / `review-unresolved` | `review.max_rounds` (14), the one terminal bound on the review loop, or a per-condition budget inside it (ADR 0027). Also: a `Human:` directive on the PR/MR that this run fixed, replied to, but could not get **resolved on the forge** — a blocking `human-review` item, because no gate passes above a person's open instruction ([`human-review.md`](human-review.md)). Answer or resolve the thread and re-run. |
| `review-blocked-on` | A finding names an upstream whose own pipeline finished without reaching ready. Recorded, and the loop kept working everything else. |
| `test-suite-failed` / `-unverified` / `-unresolved` | `test_suite.max_fix_rounds` / `max_suite_repair_attempts`, or a green suite that a blocking item keeps from counting as a pass (ADR 0028). |

## The stops that remain, and why each is genuinely terminal

Every one of these has already spent its retry. They are listed so the gap is deliberate rather than
forgotten — and so the next person to widen this net starts here.

| Stop | Attempts spent | Why continuing is not possible |
|---|---|---|
| `build-unresolved`, no handoff | 2 (build, then a bounded "hand off now") | Nothing is known about what landed — no diff, no summary, no cause. There is no continuation point, only a branch to inspect by hand. |
| `build-unresolved`, `partial`/`blocked` | 1 + `build.max_continuation_passes` (3) | Everything IS known, which is why it is continued (ADR 0032). What the bound cannot close is recorded; the repo still owes code. |
| `pr-unresolved` | 2 (open-PR, then a bounded retry) | No PR/MR number exists, and every reviewer prompt is addressed to one. The branch is built and pushed; opening it by hand is one command, given in the handoff. |
| `plan-missing` | 2 (Kickoff, then a bounded re-plan) | The build reads the plan file. A re-plan that also failed to write it is not a question a third ask answers. |
| `target-branch-halt` | 0, deliberately | `git diff <base>...<head>` cannot be computed without the base on the remote, so reviewers would produce findings about the wrong comparison. Expensive garbage is still garbage (ADR 0025). |
| `build-unresolved`, `known-false-red` recorded | 1 (the screen itself, which re-runs the check on the base) | The check that failed is one this repo DECLARES under `known_false_reds`, and it fails on the base branch too — a tree carrying none of this ticket's change. Continuing spends a fresh agent, a full rebuild and a pass of the budget to be told again what the repo already wrote down. The record is what a person reads: the ticket's code is not what is broken, and no run can call this repo's suite green until that check is stable. |
| `target-branch-halt`, from the base reconcile | 1 (the reconcile itself, which repairs what it can) | The work branch stands on the wrong base AND already carries this ticket's own commits, so re-pointing it at the run's base would delete work this run cannot re-derive. Where the branch carries no work of its own the reconcile re-points it and the run continues; where it carries both, only a person can say which commits survive the rebase. |

## The shape to keep

Two failures of this design have been found by review rather than by a run, and both had the same
shape: **an early `return` decides which of the code below it exists.** ADR 0029 found it by deleting
one; ADR 0031 found it by trusting one. When converting the next stop on this page, the question to
ask is not only "can this continue?" but "what became reachable that was written assuming it could
not?".
