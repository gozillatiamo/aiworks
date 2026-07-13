# Human-review comments — the `Human:` convention

The single reference for how a **human reviewer** hands required changes to the agents.
A human's review comment is an ordinary PR/MR review-thread comment whose body's first
line starts with the marker **`Human:`** — that prefix is the only thing that turns it
from discussion into a **directive** the agents must act on. The role agents (developer,
code-reviewer, development-planner, qa-runner, qa-planner) and the `apply-human-review`
skill consult this file; the marker is read and resolved through the VCS adapter
(`scripts/vcs/`), never a git host API directly.

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
- The merge/Done gate **cannot pass while any `Human:` thread is unresolved** — the Code
  Reviewer never approves or squash-merges through one (`code-reviewer.md` §5–6).

## Routing — classify each directive by what it asks for

The `apply-human-review` skill **auto-routes** each `Human:` directive to one role:

| The directive asks to… | Route to |
|---|---|
| change/fix implementation — logic, refactor, naming, error handling, "this is wrong/broken" | **developer** (Noah) — the default / tie-break bucket |
| add/change a test — coverage, an assertion, a regression or E2E scenario | **qa** (qa-runner; via qa-planner when it needs a plan first) |
| change the approach/scope — a different design, add/drop scope, an ADR conflict → needs re-planning before code | **development-planner** (George) → then developer implements the revised plan |

Ambiguous → **developer** (the branch owner, who pulls in planner/QA if the fix needs them).

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
