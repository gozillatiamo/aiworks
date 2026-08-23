# The review ledger — a finding is raised once, and resolved visibly

A review gate gets **one** complete pass over a change. Everything after it is a *re-visit*: the
same gate confirming its **own** findings are addressed, raising nothing new. This holds per
round **and across runs** — a workflow re-run is not a second first review.

Three mechanisms carry that across a process boundary, because prompt text alone cannot — and
the third, the approval tick (§5), is the only one a human can write.

## 1. The threads are the finding set

A gate's findings live on the PR/MR as review threads: file, line, body, resolved-state, durable,
editable by a human. Read them with `scripts/vcs/pr-threads.sh <number>` (run from inside the
repo — the adapter resolves the project from cwd, not from the number). No JSON copy of the
finding text exists, and none should: it would go stale the first time someone edits a comment.

**Every posted comment is prefixed with its gate:** `[gate:review]`, `[gate:guard]`,
`[gate:perf]` — before any other prefix, so a fold-in reads `[gate:guard] [minor / fold-in] …`.
All gates post through the same adapter token, so the forge shows a single author for all of
them. The tag is the only thing that still says whose finding a thread was, once the process that
wrote it is gone. An untagged comment is an orphan no re-visit will pick up.

## 2. The ledger rows record what a thread cannot

`dev-cycle` writes one row per repo per gate into its run-state dir
(`agent_logs/<KEY>-dev-cycle-state/<repo>-gate_<key>.json`):

```json
{"repo":"<repo>","milestone":"gate_review","status":"done","first_pass":true,
 "head_sha":"<full sha>","recorded_at":"<UTC>"}
```

- **`first_pass: true`** — this gate has done its one complete review. Written on **every**
  outcome, pass or not. A gate that skips the row on an open verdict is what makes the next
  invocation re-derive a whole new finding set instead of re-visiting the existing one.
- **`status: "done"`** — the gate genuinely passed, with every thread it owns resolved. That gate
  is then **frozen**: not re-reviewed, not even re-visited. Never written for a gate that could
  not run (`gate_unavailable`) — an un-run gate must not read as proven.
- **`head_sha`** — an audit trail, not a claim about the branch now. The run-state loader is
  explicitly told **not** to degrade these rows against the live head, unlike every other
  milestone. A passed gate stays passed; see
  [ADR 0021](../adr/0021-a-passed-gate-is-recorded-not-re-derived.md) for what that buys and
  costs.

The `guard-backstop` — the neutral checklist that stands in for a gate that died — writes **no**
row. Freezing the real gate for every future invocation on the strength of a substitute pass
would claim more than it earned.

`/ultra-review` reads the same sources and derives each gate's mode **per repo** from them, not
from how the request was phrased — and it checks §5's approval first, because an approved MR/PR
means there is no mode to derive at all. `--fresh` is the explicit override.

## 3. Resolving is part of the fix

The forge's **Resolve thread** (GitLab) / **Resolve conversation** (GitHub) marker is the record
of whether a finding is settled. `scripts/vcs/pr-resolve-thread.sh <number> <thread-id>` ticks
it; `--unresolve` reopens it.

- **The fixer resolves what it fixed**, in the same pass as the fix, matching each thread by
  `file:line` **and** gate tag. Not paperwork afterwards: the gates re-check exactly that list,
  and a fix whose thread was never resolved reads to every later reader — and to the next run —
  as never done. If the count of threads resolved differs from the count of comments fixed, the
  batch is not complete.
- **The owning gate makes the final call.** Before reporting a pass it settles every thread it
  opened: tick Resolve where the fix genuinely holds, leave it unresolved — or `--unresolve` it
  with a comment saying why — where it does not. **A gate may not pass while a thread it owns is
  unresolved.** A pass above an unresolved thread contradicts itself. Resolving one merely to end
  a loop is the abuse this rule exists to prevent.
- **A thread a human resolved is never reopened by an agent.** Note the gap once in the verdict
  and move on (`human-review.md` covers the `Human:` disposition case).

## 4. Consequences for the first pass

Because the first pass is the only pass, it is also the only chance. A gate sweeps the whole
change set and reports every must-fix in one batch — not the obvious ones first with the rest
deferred to a later round that will never accept them. Something noticed later, outside the
closed set, is named in the verdict as **out-of-scope for this PR** so a human can decide; under
`review.level: strict` that is the only place it belongs.

## 5. The approval tick is the review's last act — and its third record

A review that passes ends with the forge's own **approve** ticked. Not a comment saying it
passed: the host-level marker (GitLab MR approve / GitHub review `APPROVE`), posted through
`scripts/vcs/pr-approve.sh <num> --body "<the verdict>"`, with the verdict line naming the suite
that proved it. An approval that cannot point at a test result is the failure the green gate
exists to prevent.

**The gate never ticks it; the orchestrator does.** A gate that reports is an instrument, a gate
that approves is an authority — and in `dev-cycle` the gate reviewing a branch belongs to the
same run that wrote it (`NO_SELF_APPROVE`). So the tick is posted by the workflow, at a bar the
workflow computed, which is also the only way it is deterministic: a gate that ran out of turns
or lost its shell would leave the MR unapproved while reporting a pass. `/ultra-review` §3.5 and
`dev-cycle`'s Review phase do the same thing from the two different sides.

**The bar is TICKET-WIDE.** Zero unresolved must-fix at every gate on every repo, plus a green
receipt per repo. Anything less ticks **nothing anywhere** — not even a repo that came back
clean, because a ticket's repos are usually ship-order-coupled and approving one alone reads as
"mergeable on its own". The absence of a tick *is* the changes-requested signal.

Which gate's bar a repo cleared decides *when* it is ticked. A code repo is ticked at the end of
Review. A **test-suite repo has no reviewer at all** (`review: null` by kind), so its verdict is
the cross-repo test-suite gate, and it is ticked when that gate passes — leaving it permanently
unapproved beside its ticked siblings would read as "this one was rejected".

**An approved PR/MR is a frozen gate.** `scripts/vcs/pr-view.sh <num> --approved` prints
`yes` / `no` / `unknown`, and a `yes` freezes every gate on that repo: not re-reviewed, not
re-visited. This is the third record of the same fact the threads (§1) and the ledger rows (§2)
carry — and the only one a **human** can write, which is the point: a person who ticks approve
has ended the review, and the next invocation must agree instead of re-deriving one. A row
written from that inheritance carries `"source":"forge-approval"`, so no later reader is told a
gate ran that did not.

Two rules that keep this from lying:

- **`unknown` is not `no`, and certainly not `yes`.** It means the forge would not answer
  (approvals disabled on the instance, an API refusal). A review that ran needlessly costs
  tokens; a review skipped on a fiction ships the bug it would have caught — so `unknown`
  reviews.
- **The tick is idempotent, deliberately.** `pr-approve.sh` reads the state first and returns
  early on `yes`, posting nothing. Re-approving is harmless; a second identical `✅ APPROVED`
  verdict on the same MR is not, and a frozen gate must be safe to re-enter without consequence.

**Approve is still not merge.** It says "cleared the bar". With `vcs.auto_merge` off the PR/MR is
left open, approved, and the merge is a human's separate, later decision — which is also what
makes the run ticking its own work acceptable rather than a rubber stamp
([ADR 0022](../adr/0022-the-run-ticks-its-own-approval-the-merge-stays-human.md)).

### The one thing a frozen gate does not outrank: a `Human:` directive

Everything above freezes on a proof about a **commit** — a thread's state, a ledger row's
`head_sha`, a tick on the forge. A person's `Human:` directive is none of those: it moves no head,
so a frozen repo used to be re-entered by nothing and the directive was returned `ready` unread
(the measured case is in [ADR 0018's](../adr/0018-dev-cycle-keeps-its-own-run-state.md) last
addendum). An unresolved `Human:` thread is the **one** signal that re-opens a settled review, and
only in this exact shape:

- **It never thaws a gate into a re-review.** The frozen gates are demoted to **re-visit**, the
  same demotion a carried blocking item performs — §1 and §4 hold, the closed finding set stays
  closed, and the directive is the fix pass's FIRST must-fix (it outranks every agent finding —
  [`human-review.md`](human-review.md) §Authority).
- **No gate passes above one, even though no gate owns one.** A `Human:` thread belongs to the
  person who opened it: the reviewers name it in `still_open` and withhold their pass; the
  developer fixes, replies and resolves it. A `Human:` **reply inside a gate's own thread** is the
  mirror image — a *disposition*, which **clears** that must-fix and never blocks.
- **Unreadable is not resolved.** A run that cannot read the threads does not skip on the
  assumption they are clean — the same rule as `unknown` above. And before the repo may return
  `ready`, the threads are read back once: anything still unresolved is RECORDED (§6), which is
  what keeps "the loop does not halt" from quietly meaning "a person's instruction was optional".

## 6. The loop does not halt on a finding — it records what it cannot close

A finding never ends a repo's review. Every condition that used to stop one mid-loop — a
fix-caused regression, a stall, a cross-repo escalation that did not settle, a suite that could not
run, a second open PR/MR — is a **must-fix with its own attempt budget**, and when a budget runs out
the condition is **recorded** while the loop carries on with everything else. `review.max_rounds`
is the only terminal bound. Full reasoning:
[ADR 0027](../adr/0027-the-review-loop-does-not-halt-on-a-finding.md).

Two things follow that matter when reading a run:

**A recorded item is not a pass.** A repo carrying one cannot return `ready`, so — because the
approval tick is ticket-wide (§5) — nothing is approved anywhere and nothing merges. If you see a
run end `review-unresolved` with a blocking list, the loop did the work and could not close those
specific items; it did not give up on the rest.

**A stall changes the attempt, not just the count.** The same finding set surviving a fix round with
no new commit escalates the next brief rather than repeating it: name what did not move, treat the
previous reading as a hypothesis to disprove, re-read the actual threads. And "I believe there is
nothing to change" is a claim about the **finding**, so it belongs on the finding's thread — an
answered thread is a real outcome, silence reads as a stall.

There is one sanctioned way to end a condition's attempts early: `cannot_fix[]`, refused unless it
carries both the evidence (a command and its exit code, or the number) and what was ruled out first.
It closes that one condition, records it, and leaves every other finding still being worked.

**The cross-repo test-suite gate works the same way** since
[ADR 0028](../adr/0028-the-test-suite-gate-does-not-halt-on-a-red.md), which is the other half of the
rule: a red whose fix its scoped check never cleared, a gate that could not run, the round budget, a
standing load regression, reds that are already red on base — each is worked to a budget, then
recorded, and the gate keeps going on its other reds. Two things to know when reading such a run:

- Blocking items from the gate land in the **same** list as the review loop's, so a run has one
  "Blocking — needs a person" section, not two.
- `test-suite-unresolved` is a real ending: the suite is **green** and the run is still blocked by
  what the gate recorded. Together with `test-suite-failed` (red) and `test-suite-unverified` (no
  verifiable result), that is three statuses meaning *the gate did not pass* — a reader checking only
  for `failed` will mis-read two of them.

One retraction exists, and only one: a per-case "the fix was never cleared" record is dropped if a
later round's fix for that same case clears the same check. Every other record is a budget that ran
out, and a budget does not un-run.

**A recorded item survives the resume**, and this is the one place the ledger's freeze yields. A
`blocked` row per repo carries the items forward; on the next invocation that row demotes the repo's
ledgered-PASSED gates from **frozen to re-visit** so the loop runs at all, and hands each item to the
first fix pass as a must-fix. Re-visit is still a re-check, never a second first review — §1 holds.
What the run must NOT do is re-assert the item on sight: a person may have fixed it between runs, so
the developer is told to check whether it still stands, with evidence, before working it. Closed ⇒
the repo proceeds; still open ⇒ recorded again on this run's own evidence. A run that ends clean
rewrites the row empty, which is how one gets cleared (a workflow script cannot delete a file).
Without this the guarantee held for exactly one invocation: the gates a blocking item coexists with
are all PASSED, so the next run skipped review and merged what the last one recorded.
