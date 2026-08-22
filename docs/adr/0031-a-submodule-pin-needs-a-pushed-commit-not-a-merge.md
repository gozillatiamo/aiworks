# A submodule pin needs a pushed commit, not a merge

**Status:** Accepted

Build-order is decoupled from merge-order: a repo's build needs the agreed contract, not a merged
upstream, so every scoped repo builds in parallel. That holds for every kind of cross-repo
dependency except one.

A repo whose test harness rebuilds its schema, migrations or fixtures from a **vendored submodule
checkout** can only see commits its pin can reach. Built beside its upstream, the upstream's commits
do not exist yet, so the pin can only point at the merged base — and the downstream cannot write a
single test against the change it exists to prove. On a measured run that cost the whole repo: all
fourteen acceptance criteria untouched, because the columns they read were in no commit the pin was
allowed to reach.

## Reordering was already tried, and it was not enough

The obvious fix — build the upstream first — had already happened. The upstream's migration was
committed three commits deep before the downstream's build agent ran. It still could not start,
because the run capped the pin at the upstream's **merged** base, and nothing merges mid-run:
`vcs.auto_merge` is off by default and the squash-merge is a human step by design
([ADR 0022](0022-the-run-ticks-its-own-approval-the-merge-stays-human.md)). Read that way, a
submodule-coupled pair costs one extra invocation by construction, and the only apparent escape is
to start merging inside the run.

That reading has a false premise in it. **A submodule pointer does not need a merged commit — it
needs a commit that exists on the remote.** Git will happily pin to a branch commit; Liquibase does
not know or care which branch a changelog came from. The cap was never git's, it was ours.

So: the upstream builds and **pushes** in an earlier wave, the downstream pins to that branch tip,
and the run's merge boundary is untouched. Nothing merges. The extra round disappears anyway.

## What actually changed

- **Kickoff reports the pin.** One `git config -f .gitmodules --get-regexp path`, matched against
  the other scoped repos **by remote URL, never by directory name**. `submodule_pins: []` is the
  normal answer. Detection lives here because the planner already has the checkout open, and because
  the answer must be a fact rather than the scoping agent's judgement.
- **A pin is a dependency edge.** It folds into the same graph `depends_on` feeds, so the existing
  waves order it and there is no second graph to keep in step. `depends_on` remains a contract
  between repos and still serializes nothing; a pin is a fact about the downstream's own harness and
  binds harder.
- **The build runs in waves only when a pin exists.** No pin, one wave, byte-identical to full
  parallelism — the tickets that do not need this pay nothing for it.
- **The pinned upstream must push.** Its build brief ends with `git push -u origin <branch>`, and
  says why: a repo is waiting on that commit reaching the remote. An unpushed commit makes the wave
  a wait for nothing.
- **The reviewer is told the unmerged pointer is intended.** Otherwise every reviewer raises it, and
  the honest-sounding fix — "merge the upstream first" — is precisely the round this removes.

## The pointer is re-aimed before anything lands

The hazard this creates is real and specific: the upstream squash-merges to a **new** sha and its
branch is deleted, which would strand a pointer aimed at the branch commit.

The Merge phase already emitted a `submodule-bump` ship step for exactly this — per downstream, run
after the upstream's merge lands, guarded on `.gitmodules` actually declaring the path. It was
written for the merged-base world and needs no change to cover this one; it is now load-bearing
rather than precautionary, which is worth stating so nobody tidies it away as speculative.

## The cost, stated plainly

**A pinned pair no longer builds concurrently.** That is the trade, taken deliberately: the
alternative was concurrency that produced nothing, followed by a second invocation to do the work
serially anyway. The cost is bounded by the pin graph's depth, which is the same depth the merge
order already has, and it is paid only by tickets that touch a submodule-coupled pair.

There is no knob to turn it off. A pin either exists in `.gitmodules` or it does not, and if it does,
building through it is not an optimization to opt into.

## Related

- [ADR 0022](0022-the-run-ticks-its-own-approval-the-merge-stays-human.md) — the merge stays human,
  which is what ruled out the obvious fix and forced the better one.
- [ADR 0025](0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md) — the run's base is
  settled once. A pin target is the same discipline for a different ref.
- `docs/agents/submodules.md` — never develop inside a submodule checkout; the pointer move is the
  only write, and it is committed in the parent.
