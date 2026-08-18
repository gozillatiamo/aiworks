# The review ledger — a finding is raised once, and resolved visibly

A review gate gets **one** complete pass over a change. Everything after it is a *re-visit*: the
same gate confirming its **own** findings are addressed, raising nothing new. This holds per
round **and across runs** — a workflow re-run is not a second first review.

Two mechanisms carry that across a process boundary, because prompt text alone cannot.

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

`/ultra-review` reads the same two sources and derives each gate's mode **per repo** from them,
not from how the request was phrased. `--fresh` is the explicit override.

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
