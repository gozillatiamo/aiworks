# The run's base is state, and the PR/MR is asserted against it

**Status:** Accepted

A `dev-cycle` run decides, once, which branch each repo's work targets. That decision was an
**argument**, not a fact of the run: it was read from this invocation's flags, used, and forgotten.
Nothing recorded it, and nothing ever checked the result against it.

Measured, on one four-repo ticket: **seven invocations, about two days, five human interventions on
the critical path.** The requested base was stated in the first sentence of the first invocation, as
free text. `flag()` matches `--<name>` only, so it was discarded in silence — and the comment three
lines above that regex says the string-argument form exists precisely so a fast-track base has a way
in without hand-editing the file. The feature was built for that case and the phrasing missed it.

From there the base had to be re-supplied by hand, per repo, every round. It never once got fully
re-supplied: each invocation fixed one or two repos while the rest silently reverted to their
defaults. One whole invocation — roughly twenty agents — was spent on an invented flag shape
(`--feature-base-repos repo=value,repo=value`) that exists in no parser; the workflow even logged a
warning for exactly that shape, at line 2320 of a 2807-line run, after Scope, the tracker status
move and every Kickoff planner had already been paid for. A warning that arrives after the expensive
part and does not halt is a warning nobody acts on.

The run then reported its designed clean finish — `merge-skipped`, "reviewed + validated PR/MR left
OPEN for human merge", review-request posted — with **all four MRs targeting the wrong branch**, one
of them at a branch that repo's own documented `develop → staging → main` policy forbids. A human
caught it after the pipeline had declared itself done.

That last part is the important one. The pipeline is *thorough* about the base right up to the
moment the PR/MR is created: three separate prompts tell an agent not to re-derive it, and two of
them name the exact failure mode. After creation, **nothing ever asked the forge what the thing
actually targets.** Review judged the diff, the quality gate judged the smells, the performance gate
judged the latency, the test-suite gate judged the suite. No gate compared an MR's target to
anything at all. The failure was predicted in comments and never checked in code — and three
warnings for one rule is evidence that prose is not holding.

The decision, in five parts.

**1. Every repo kind takes its bases from `branch_model`.** A `test-suite` repo used to be the one
exception, projected with `base.feature = fix_base` on the reasoning that a QA suite has no
feature-branch flow. Measured, that reasoning was simply false: both suite repos on that ticket had
`origin/HEAD` on the feature base, with the fix base 99 and 157 commits behind, and one of those
trunks was a 16-file scaffold last touched a year earlier. A ticket's suite branch was cut off a
dead branch, missing a shared login helper the specs import — a full round to discover, per repo.
The exception is gone. A repo whose policy genuinely differs declares it with `feature_base:` /
`fix_base:` on its own `products[].repos[]` entry, which is also the first time the *config* has
been able to say anything about a base at all: it previously held zero base keys, so the hardcoded
map inside the generated workflow was the real authority, in direct violation of the workspace's own
"config is the source of truth" invariant.

**2. An argument the run cannot honour stops it, before it costs an agent.** Every argument-level
check now throws immediately after parsing, and the parsing itself was moved above the runtime-config
resolver — because that resolver is an agent, and "zero agents" has to mean zero. The checks:
unconsumed free text in the argument string (naming the residue, and the flag it should have been
when it looks like a branch); `--feature-base-repos` without `--feature-base`; `--feature-base-repos`
naming an unregistered repo id, which a `repo=value` token is not; `--base` and `--feature-base`
together. The error names the flag but **never adopts it** — a run that infers its own base is the
failure being fixed, so the suggestion is text, not behaviour.

**3. The resolved base is written to run state and is authoritative on resume.** `base_branch` goes
on the `planned` row, beside the per-run context already there (`ticket_fp`, `plan_path`,
`acceptance`). On a resume with no override flag, the recorded base wins and says so — this is the
line that kills "silently reverted to defaults". An explicit override that *disagrees* halts the run
and names both branches; `--accept-base-change` re-bases in place and degrades every row that was
proven against the old base (`planned`, `built`, `pr_open`, `reviewed`, the gate rows), because a
plan and a build made against a different branch are not proof of anything. And the resolved-base
table now prints right after Scope, before the first planner spawns, attributing each base to its
source — flag, run state, or repo default. It is the one line that would have caught every
wrong-base round on that ticket, and it used to print at the far end of Kickoff.

**4. The adapter can show and change a target branch.** `vcs_pr_view` always fetched the entire
PR/MR object — `target_branch` included — and printed three of its fields. So a gate could not
assert what the sanctioned tool refused to print, and the workspace correctly forbids reaching past
the adapter to `glab`/`gh`. That is *why* there was no gate: one `jq` line short. It now prints
`target_branch=` and `source_branch=`, `vcs_list_prs` carries a target column, and
`scripts/vcs/retarget-pr.sh` repoints an open PR/MR (`PUT /merge_requests/:iid` ·
`gh pr edit --base`). The repair matters as much as the read: both forges keep existing approvals
across a retarget, while the only route before — close the wrong MR, open a correctly-targeted one —
does not, so repairing four mis-targeted MRs also destroyed four approvals that had to be rebuilt by
hand.

**5. The target branch is asserted twice, and repaired once.** Immediately after the PR/MR is opened,
and again immediately before the approval tick. The first checkpoint is where the run still holds the
base as a live fact, and it comes before three reviewers spend anything on a diff against the wrong
base; on a mismatch the run retargets toward the base it recorded — after proving that branch exists
on the remote — then re-reads the forge and continues only if the re-read agrees. The second
checkpoint exists for the two cases the first cannot cover: an invocation that resumed straight past
open-PR on a `pr_open` row, and a human moving the target mid-run. It is read-only, because a
mismatch surviving to the tick is not something to fix silently underneath an approval.

Both checkpoints also assert **exactly one open PR/MR per repo per ticket**. `pr_open` proof is a
head sha, not an MR identity, so a resume can open another one without noticing — one repo on that
ticket really did end up carrying two, targeting different branches. Closing an MR stays a human
call, so that case halts rather than repairs.

And neither may fail open. An assert that did not converge is recorded as unverified and halts the
repo, never as a pass. This is the same rule the test-suite audit runs on, for the same reason:
"nobody checked" was the previous state, and it is what shipped.

**6. A `built` row is proof only while the plan it was built from still stands.** The same
"state has to be real proof" argument, one link further down the chain. `built`'s only proof was the
branch head, and that deadlocks: a fresh planning pass that correctly re-diagnoses the problem does
not move the head — nobody has built the new plan yet — so `built` stayed non-degraded, Build was
skipped as "already built", and the corrected plan was never built. It happened twice on that
ticket, and the only recovery found was deleting checkpoint files by hand, an idiom no document
mentions and which slips past the orchestrator guard because that guard denies `Write`/`Edit` under
the run-state directory but not `rm`.

The workflow had already invented exactly the right mechanism for this class of problem —
`TICKET_FP`, which invalidates every `planned` row when the ticket text changes — and never extended
it to the plan→build edge. It is extended now: the run-state loader stamps the live plan's
fingerprint onto the `planned` row, a planner returns the fingerprint of the plan it just wrote, a
build records the fingerprint of the plan it built **from**, and a `built` row whose fingerprint
disagrees with the current plan is ignored — that repo builds again, and its `pr_open`/`reviewed`/
gate rows are degraded with it. The asymmetry that made this possible is visible in the checkpoint
files themselves: a `planned` row carried a plan pointer and fingerprint, a `built` row carried
neither.

Do **not** close the `rm` gap in the orchestrator guard on the strength of this change alone: that
delete is still the only escape from any resume deadlock not yet accounted for, and denying it
without a replacement strands a run.

## What this costs

Two read-only adapter reads per repo per run, on a haiku agent. Against that: without them, four
wrongly-targeted MRs reached a human labelled "reviewed + validated", and one of them would have
merged a release fast-track into a branch its own repo policy forbids. The control that actually
prevented that merge was `vcs.auto_merge: false` — the run stopping at its human-ship boundary
(ADR 0022). That is a good backstop to have had, and a bad one to rely on.

## Related

- [ADR 0018](0018-dev-cycle-keeps-its-own-run-state.md) — run state. `base_branch` and `plan_sha`
  are new rows' fields; the `planned`-row skip it describes as "never used to skip anything" has
  since become C10's Kickoff skip, and this change adds the plan→build edge below.
- [ADR 0021](0021-a-passed-gate-is-recorded-not-re-derived.md) — a passed gate is recorded, not
  re-derived. The target assert is deliberately *not* one of those: it is cheap, read-only, and
  answers a question about the forge's current state rather than about work already done.
- [ADR 0022](0022-the-run-ticks-its-own-approval-the-merge-stays-human.md) — the run ticks its own
  approval. The target assert runs immediately before that tick, and refusing to tick is how it
  reports a mismatch.
- `docs/agents/workflow-resume.md` — the resume contract, including `--accept-base-change`.
