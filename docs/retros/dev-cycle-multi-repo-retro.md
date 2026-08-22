# Retro — a four-repo ticket that took seven `dev-cycle` invocations

**What it was.** One ticket across four repos: a guard in a backend service, a toggle in an admin
web app, and two E2E suites (admin-facing and user-facing). The opening request named a release
branch as the target — in prose, in the first sentence.

**Names here are generic** (`svc`, `web`, `e2e-suite`, `admin-suite`, `<PREFIX>-<n>`). Every number
is real and was measured on the run; the code paths cited are this framework's, and the fixes are in
[ADR 0025](../adr/0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md) and
[ADR 0026](../adr/0026-a-ticket-is-a-record-not-a-transcript.md).

Kept as a worked example: the individual bugs are fixed, but the *shapes* recur, and several of
them read as diligence while costing a round.

---

## 1. By the numbers

| Metric | Value |
|---|---|
| Full `dev-cycle` invocations | **7** |
| Additional targeted agent rounds (QA planner + runner) | 2 |
| Wall clock | ~2 days |
| Final invocation alone | 29 agent spawns · 907 turns · **6,714,974** run tokens |
| Invocations producing no progress | at least **2** |
| Human interventions on the critical path | **5** |
| Target | 1 |

**The one-line lesson: the run never held the user's actual intent as state, so every resume
re-litigated it — and no gate ever checked the result against it.**

The requested base was dropped on invocation 1 (free text, and `flag()` matches `--<name>` only),
never recorded anywhere durable, and therefore re-supplied by hand, per repo, every round. It never
once got fully re-supplied. And because no gate compared an MR's target branch to anything at all,
the run reported its designed clean finish — `merge-skipped`, "reviewed + validated, left OPEN for a
human" — with **all four MRs targeting the wrong branch**. A human caught that after the pipeline
had declared itself done.

---

## 2. Root causes, and which are fixed

### 2.1 The base was an argument, not state — *fixed (ADR 0025)*

Two independent gaps: no complaint about unconsumed free text, and base overrides that were never
persisted, so a resume without the flag silently reverted to the repo default. Worse, the code was
written to be authoritative about that reversion — the run's resolved base overwrote whatever a
planner returned.

Structurally responsible for the majority of the seven rounds.

### 2.2 A wrong constant, validated by nothing — *fixed (ADR 0025)*

Every `test-suite` repo was projected with `base.feature = fix_base`. Measured:

| repo | `origin/HEAD` | feature base ahead of fix base | last commit on fix base | files |
|---|---|---|---|---|
| `e2e-suite` | feature base | 99 | 8 months prior | — |
| `admin-suite` | feature base | 157 | **14 months prior** | **16 / 218** |

So a ticket's suite branch was cut off a 16-file scaffold, or off a trunk missing the shared login
helper every spec imports. A full round per repo to discover.

**The pipeline diagnosed this itself, in round 1, and nothing consumed the diagnosis.** A planner
wrote a `§0 — BLOCKING` section naming the exact root cause, quoting the config key it contradicted.
Nothing in the pipeline reads a plan's blocking section as a signal, so it was re-discovered in
round 4. *Still open* — see §4.

### 2.3 An invented flag shape, warned about and not stopped — *fixed (ADR 0025)*

Round 2 was resumed with `--feature-base-repos a=x,b=y`. That mapping form exists in no parser;
`--feature-base` was never passed, so the override was inert and both repos used their unchanged
defaults. **~20 agents, ~1.9M subagent tokens, zero progress.**

The operator half is the larger one — a CLI contract guessed rather than read. But the tool had
*two* checks that would have caught it (a `repo=value` token is not a registered repo id; and
`--feature-base-repos` without `--feature-base` scopes nothing) and both were `log()` calls firing
at line 2320 of a 2807-line run, after Scope, the tracker status move and every Kickoff planner had
been paid for. A warning that arrives after the expensive part and does not halt is a warning nobody
acts on.

### 2.4 The resume deadlock: a re-plan could not invalidate a build — *fixed (ADR 0025)*

Twice, a planning pass correctly re-diagnosed a problem and wrote a **new** plan describing a change
that had never been applied — and Build was skipped as "already built". `built`'s only proof was the
branch head, and a re-plan does not move the head, because nobody has built it yet.

The asymmetry was visible in the checkpoint files: the `planned` row carried a plan pointer and
fingerprint; the `built` row carried neither. The only recovery found was deleting checkpoint JSONs
by hand — undocumented, reverse-engineered from the loader's own inline comments, and not covered by
the orchestrator guard, which denies `Write`/`Edit` there but not `rm`.

### 2.5 The dotenv ban is correct, and had no fast path — *open*

Round 4's root cause was one local env var pointing at a record with no rows, so any request
resolving one particular host header crashed with a 500. The agent found it, proved it black-box
with two `curl`s, and was structurally unable to fix it — correctly: the `.env` ban is enforced and
motivated by a real leak. (It fired on a `grep` issued while writing the postmortem this retro is
derived from.)

The gap is not the ban. It is that there is **no structured channel for "a human must change one env
var"**. The agent invented one in prose, in a bug log — and a prose line in a bug log is not a
pipeline state. Cost: one full human round-trip, at human latency.

### 2.6 "Re-confirm" substituted for "re-investigate" — *fixed at the prompt level (see §3)*

A spec-aborting `TypeError` was diagnosed as a defect in the test runner + reporter combination,
fixable only by a repo-wide version bump. Round 6 re-ran the same spec, got the identical failure,
and recorded it as **confirmation** — verbatim, *"No new fix attempted"*.

The real cause was **one line in a fixture**: a hostname that sent the post-login redirect
cross-origin, whereupon the runner's own error-*reporting* code crashed trying to describe it. The
`TypeError` was the mask, not the fault. The correction came only from a round explicitly told to
verify rather than trust — and it was derivable from screenshots round 5 had already captured. The
evidence to overturn the diagnosis was in hand for two rounds.

Three compounding gaps, all cheap to fix in prompts:

1. **A red-triage round's default posture is reproduce-and-confirm, not re-derive.** The bounded-loop
   counters bound *attempts*, not *hypotheses*: a second attempt under a wrong hypothesis burns a
   round and reads as diligence.
2. **"Pre-existing on base" was treated as terminal.** A control spec failed identically and that
   was read as "not our diff, therefore not our fix" — when in fact both specs shared one
   fixture-driven cause. **A control that fails identically confirms a shared cause, not
   out-of-scope-ness.**
3. **"Needs a dependency bump" is a self-sealing escape hatch.** Once a diagnosis names an
   out-of-scope fix, no later round has a reason to reopen it.

Two near-misses worth noting: acting on the tooling diagnosis would have meant a repo-wide runner
bump that **would not have fixed the bug** (the newer versions enforce the same cross-origin
restriction). And once the third round was told to re-verify, it found two further genuine bugs the
first two had never reached, because the crash masked them.

### 2.7 No gate validated an MR's target branch — *fixed (ADR 0025)*

The most serious defect found. `svc` accumulated **two** open MRs (one per candidate base, the
second against that repo's own documented branch policy); `web` targeted the integration branch
instead of the release branch; both suites targeted the fix trunk instead of the feature trunk.

Before creation, three prompts insisted on the base and two named the failure mode. After creation,
nothing ever asked the forge what the MR actually targets. Compounding it, the adapter could neither
**read** a target branch (`vcs_pr_view` fetched the whole object and printed three fields) nor
**change** one — so the repair was, per repo: close the wrong MR with an explanation, open a
correctly-targeted one, and re-approve by hand, because the forge does not carry approvals across
close+reopen. Then delete the stale checkpoints again (§2.4).

### 2.8 The report comment contradicted its own run, three times — *fixed (ADR 0026)*

In three separate rounds the audit caught the per-repo test report disagreeing with the run it
claimed to describe: wrong pass/fail counts, a filter label for a filter nobody ran, mismatched
candidate shas, once the wrong spec name.

**The finding is not the detector — the detector worked every time.** It is that nothing
investigated *why the writer kept producing contradictory bodies*. Two visible causes: the report was
a rewrite-in-place upsert whose run history an agent had to hand-merge on every re-run (a lossy
operation performed by a language model, repeatedly), and its summary was re-read from the repo's
latest artifacts rather than from the receipt the gate had already captured — with the guard against
staleness being prose, not a mechanism.

### 2.9 Budget exhaustion — *downstream symptom, fixed by the above*

Round 6 stopped on the token budget *before Kickoff*. The stop itself is well-built: graceful,
resumable, clearly worded, and honest that nothing failed. The budget had been consumed by §2.3's
waste and §2.1/§2.4's rebuilds. Fixing those removes this event.

Two things it exposed, both now addressed: the ceiling counts **output** tokens only (232k output
against 6.7M total run tokens in one invocation — a ~29× ratio no reader would guess from
`token_budget: 2000000`), and nothing accumulated a **per-ticket** spend, which is the number the
person actually asked about.

---

## 3. What worked — do not "fix" these

Several are the only reason this ticket did not end in a false green.

1. **The test-suite audit never failed open — three for three.** Every self-contradicting report was
   recorded as NOT RUN, not as a pass. Nothing shipped on an unverifiable claim.
2. **`build-unresolved` refused to fake progress.** A repo that could not be built on a 16-file
   scaffold said so, rather than producing a plausible empty diff.
3. **The dotenv guard blocked every attempt, including the retro author's.** The policy is airtight
   and the cost it imposes (§2.5) is the right trade.
4. **The orchestrator guard kept hand-edits out of the pipeline's blind spot** — deliberately
   redundant toward *allow* so it can never break a run, with a narrow, reasoned deny set.
5. **No gate ever approved its own work.** The instrument/authority split survived seven rounds.
6. **The run stopped at its human-ship boundary and did not merge.** Given all four MRs were
   mis-targeted, *this is the control that prevented a wrong-branch merge.* A good backstop to have
   had, and a bad one to have been relying on.
7. **The planners did excellent measurement work** — measured-not-inferred evidence with the
   commands that produced it, explicit "still NOT measured" sections, and a `§0 BLOCKING` that
   root-caused the base bug in round 1. **The planning output was better than the pipeline's ability
   to consume it.**
8. **A round told to re-verify rather than trust did the job**, and found two more real bugs on the
   way. The capability was there; the default posture was what needed changing.
9. **The bug log distinguished app bugs from test artifacts under pressure**, and declined to file an
   app bug for a testing-tool artifact.

---

## 4. Still open

1. **A plan's `§0 BLOCKING` section is not a signal the pipeline reads.** A planner named the
   base-branch root cause in round 1, in writing, and the run carried on. `REPO_PLAN_SCHEMA` already
   has `unverified_claims`; a `blocking[]` array that halts the run when it names a precondition the
   run itself could fix is the obvious shape.
2. **An env-blocked repo has no first-class handoff.** Wanted: `{file, var, current_symptom,
   required_value_description, verify_command}` — never a value read from the file — surfaced as a
   top-of-summary blocking item and a DM, so the request exists as pipeline state the moment it is
   discovered.
3. **Why did a permission classifier deny the approval step once and allow it later**, with nothing
   changed by hand? Unmeasured. Until then, the workflow's "tick by hand" fallback line is the only
   safety net.
4. **Why did the budget stop trigger *before* Kickoff on a fresh invocation?** Either the engine's
   budget API accumulates across a resumed persisted script, or the exhaustion pre-dated the phase
   boundary some other way. This decides whether per-ticket accounting is a new feature or already
   half-implemented by accident.
5. **A dirty worktree at kickoff should be a hard stop, not a shrug.** In round 1 a planner's
   recovery commands were denied by the classifier mid-kickoff and it proceeded on the wrong base
   rather than stopping. The prompt path that allowed that decision was never located.
6. **Worktree dotenv files had drifted from symlinks to independent copies**, silently, with no drift
   detector anywhere — so a fix applied at the workspace root never reached the worktree. Not on this
   ticket's critical path, but it is exactly what makes an env-class bug look repo-specific and
   unreproducible.

---

## 5. The transferable lessons

- **Intent that is not state gets re-litigated every round.** If a run makes a decision, the run has
  to record it, and a later invocation has to be unable to lose it by omission.
- **A warning that does not halt, and arrives after the expensive part, is not a check.** Argument
  errors belong before the first agent spawns, where they cost nothing.
- **A gate cannot assert what the sanctioned tool refuses to print.** Missing adapter output is not
  a convenience gap; it decides which gates can exist at all.
- **A test that asserts the projection instead of the intent passes straight through the incident.**
  One selftest in this framework encoded the wrong base constant as its expected value, and was
  green throughout.
- **A second attempt under an unexamined hypothesis reads as diligence and costs a round.** When the
  failure signature is identical to last round's, the prior conclusion is the thing to attack.
- **A control that fails identically confirms a shared cause.** It is not evidence of
  out-of-scope-ness.
- **Never ask a language model to hand-merge history.** Keep the history in a file and render it.
