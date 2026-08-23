# Human-review comments — the `Human:` convention

The single reference for how a **human reviewer** hands required changes to the agents.
A human's review comment is an ordinary PR/MR review-thread comment whose body's first
line starts with the marker **`Human:`** — that prefix is the only thing that turns it
from discussion into a **directive** the agents must act on. The role agents (developer,
code-reviewer, development-planner, qa-runner, qa-planner) and the `apply-human-review`
skill consult this file; the marker is read and resolved through the VCS adapter
(`scripts/vcs/`), never a git host API directly.

## Two kinds of `Human:` comment — directive vs disposition

The marker always means "a human is speaking, act on this". *What* to act on depends on
whose thread it sits in:

| | **Directive** | **Disposition** |
|---|---|---|
| Sits in | a thread the **human opened** | a **reply** on a thread an **agent** opened (an agent must-fix) |
| Says | "change this" | "accepted" · "not a fix — this belongs to \<role\>" · "deferred, tracked elsewhere" |
| The agent does | route + fix + reply + resolve (below) | **nothing to the code** — record it and count that must-fix as **cleared** |

A disposition **closes the finding for gate purposes.** Do not re-argue it, do not re-open
the thread, and do not keep the finding in the must-fix tally — **even when the work it hands
off has not landed yet** (a test-suite fix in another repo, a product decision, a follow-up
ticket). Carry that outstanding work forward as a **stated condition** on the approval, the
ticket, and the chat summary — a merge-order warning, a named owner — never as a blocker on
the MR/PR the human just cleared. Withholding approval until the handed-off work lands
re-opens the decision the human already made.

Worked example (APP-2242): the reviewer filed a wire-contract break — renamed error codes
with 9 stale Newman assertions living in a *different* repo that had no branch yet. The
developer replied `Human: this is a task for QA` and resolved the thread. Correct handling:
the finding is cleared, **both MRs are approved and the ticket advances**, and the un-landed
Newman fix survives as "⚠️ merge order — do not merge before the QA-suite MR" on the
approval line, the ticket, and the review thread.

### When a human resolves a thread and writes nothing

Silence is not a directive, and it is **not yours to overturn**. **Never re-open a thread a
human resolved.** Note the gap **once** — in your verdict, naming what is still unrecorded
and the single line that would settle it — then treat the finding as dispositioned and let
the gate pass. Re-opening resolved threads to force an answer reads as the agent overruling
the reviewer; it is the failure this section exists to prevent.

## Where they live

PR/MR **review threads only** — inline at `file:line`, listed by
`scripts/vcs/pr-threads.sh <number>` as
`● thread=<id>  [unresolved|resolved]  <path>:<line>  (<author>)` + body. A `Human:`
directive is any such thread, still `[unresolved]`, whose body's first line starts with
`Human:`. (Ticket comments and in-code text are **not** this channel.)

## Authority — blocking, top-priority

A `Human:` directive **outranks every agent-reviewer comment** (Daniel / Ethan / Liam):

- It **jumps the developer's FIFO queue** — drain `Human:` directives before agent comments.
- It is **always a must-fix**, regardless of `review.level`.
- The merge/Done gate **cannot pass while any `Human:` directive thread is unresolved** — the
  Code Reviewer never approves or squash-merges through one (`code-reviewer.md` §5–6). A
  **disposition** is the mirror image: it never blocks, it *clears*.

## Routing — classify each directive by what it asks for

The `apply-human-review` skill **auto-routes** each `Human:` directive to one role:

| The directive asks to… | Route to |
|---|---|
| change/fix implementation — logic, refactor, naming, error handling, "this is wrong/broken" | **developer** (Noah) — the default / tie-break bucket |
| add/change a test — coverage, an assertion, a regression or E2E scenario | **qa** (qa-runner; via qa-planner when it needs a plan first) |
| change the approach/scope — a different design, add/drop scope, an ADR conflict → needs re-planning before code | **development-planner** (George) → then developer implements the revised plan |

Ambiguous → **developer** (the branch owner, who pulls in planner/QA if the fix needs them).

A **disposition** routes nowhere — there is no work order in it. If it names an owner
("this is a task for QA"), that ownership is recorded in the ticket and the approval line,
not turned into a thread the agents keep open.

## Mechanics — fix, reply, resolve (the agent resolves)

1. Read the directive: `scripts/vcs/pr-threads.sh <number>` → its `file:line`, `thread=<id>`, body.
2. Fix it — code via `/tdd`; a genuine defect (wrong/broken/failing/slow) via `/diagnosing-bugs`
   first, the same defect-vs-style split as any review comment.
3. Reply anchored:
   `scripts/vcs/pr-comment.sh <number> --path <file> --line <n> --body "done in <sha> — <what changed>"`.
4. **Resolve the thread yourself** — `scripts/vcs/pr-resolve-thread.sh <number> <thread-id>` — after
   the fix is pushed (the agent resolves, not the human). Resolve **only** the directive you addressed.
5. Can't fix, or the directive is unclear → reply asking, and **leave it unresolved** (an open
   `Human:` thread keeps the gate closed).

No special tooling — the adapter commands above already read, reply to, and resolve these
threads; a `Human:` directive is found by grepping the thread body for the leading marker.

## Who picks a directive up — including on a PR/MR that is already approved

Three entry points, and the third is the one that used to be missing:

1. **`/apply-human-review`** — invoke it directly against an MR, a ticket key, or a URL. Always
   works, whatever any run's ledger says. Still the right tool when you want *only* the directives
   applied and nothing else re-checked.
2. **A `dev-cycle` repo still going through review this run** — the directive lands in the fix
   batch like any other must-fix, ahead of the agent findings.
3. **A `dev-cycle` re-run over a repo whose review is already SETTLED** — a `reviewed` row, three
   ledgered gates, or an approve tick on the forge. This one is new. Such a repo is skipped without
   re-paying for its review ([ADR 0018](../adr/0018-dev-cycle-keeps-its-own-run-state.md)), and
   that skip's proofs — an unmoved branch head, a title+acceptance fingerprint — are both blind to
   a comment. So a run now asks the forge one read-only question before skipping: *does this PR/MR
   carry an unresolved `Human:` directive?* If yes, the skip is vetoed, the frozen gates drop to
   **re-visit** (not a re-review — nothing is re-derived), and the directive goes to the fix pass
   first. If the run cannot read the threads, it also does not skip: an unanswered question is not
   a clean bill of health. Before the repo can be called ready the threads are read back, and any
   still open is recorded as blocking — the run ends unresolved rather than reporting a settled
   review above your open instruction.

**What you have to do differently: nothing.** Leave the directive on the MR and re-run
`dev-cycle`, or call `/apply-human-review` — either picks it up.

**The one residual gap.** A repo with no reviewers — a test-suite/QA repo — has no review path at
all, so nothing there probes for directives. A `Human:` directive on a QA MR needs
`/apply-human-review`.
