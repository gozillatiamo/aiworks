# A repo whose criteria already hold is finished, not stalled

**Status:** Accepted

A build agent found every ticket-visible requirement in its repo already implemented — shipped
under an earlier ticket, in generic flag-driven code, with a file:line citation per criterion. It
ran the repo's lint and build green on the unmodified `HEAD`, declined to manufacture a no-op
commit for the sake of having a diff, and handed back the only status that fit: `deferred`.

The verifier confirmed every specific citation it had been given, and then rejected the whole claim
on a single unconditional rule — *the branch has zero commits ahead of its base* — which downgraded
the repo to `partial` and stopped it. One repo of six, and the run ended `repo-unresolved`.

So a run can now say **`already-satisfied`**: this repo needs no change, and here is the shipped
code that proves it.

## Why the empty-branch rule could not tell the difference

The rule exists for a real failure: an agent claiming "everything except X is already done" to
avoid doing the parts that are *not* done. That claim and a true one produce the identical
fingerprint — zero commits on the branch — so a test on commit count cannot separate them. It is a
proxy for *was work done*, and the question is *is the criterion true*. Those two diverge in exactly
the case that matters.

They also diverge by design here. A registry/flag architecture exists so a new case can be added
without touching every consumer; a new provider needing no UI change is the goal of that design, not
an edge of it. The framework was forcing its own intended outcome to look like a failure.

## The bar goes up, not down

"It's all already done" is the cheapest sentence an agent can write, so removing the commit-count
test without replacing it would be a straight downgrade. Three things replace it, and a claim
failing any one of them lands back on `partial`, which stops the repo exactly as before:

1. **Structural.** `satisfied_by[]` carries one entry per criterion: the criterion quoted, the
   `commit` that shipped it, the `path_line` where the behaviour lives now, and the source `quote`
   itself. A sha that is not a sha, a `path_line` with no line, a quote too short to match — the
   claim is refused before a verifier is spawned, so a junk claim costs one agent, not two.
2. **Coverage.** The verifier reads the ticket and the plan and lists every acceptance criterion
   assigned to this repo. A criterion with no citation is work nobody looked at, and it sinks the
   claim. This is the check that separates "the design already covers it" from "I would rather not
   do this", and it is the one the old rule was reaching for and missing.
3. **The code, not the words.** Each citation is re-opened: the commit is an ancestor of the base,
   the quoted source is at the cited line today, and reading *around* the line shows the behaviour
   the criterion describes rather than the right words in the wrong place. Then a grep for the
   ticket's own new identifiers — if the generic path has a gap the new case falls through, the
   claim is false and the verifier must name the file where the work belongs.

The verifier is told one thing it may not do: **reject on commit count**. An empty branch is the
expected shape of a true claim here, and re-applying that test would rebuild the bug. A DIRTY tree
is still fatal, though — uncommitted work contradicts "nothing was needed".

## What it does to the run

An upheld repo leaves the run's live set the moment its build returns. It has no branch, no PR/MR
and nothing to merge, so rather than teach the approval tick, the gate's candidate list, the merge
order and the summary a status meaning "not applicable", one filter drops it and every downstream
phase is unchanged. Its criteria still count toward the ADR-0011 floor — they were met, just not by
this run — so a ticket with one satisfied repo and one deferring repo is not "nothing delivered".

**Every repo satisfied is its own ending**, `already-satisfied`, and deliberately not
[ADR 0011](0011-a-run-that-delivers-nothing-stops-for-a-human.md)'s `nothing-delivered`. Those are
opposite findings: one says nobody met anything, this one says everything was already met. The
answer a person needs is "close the ticket", and a run that reported the opposite would send them
looking for work that does not exist.

Nothing is checkpointed to run state. The citations do not fit in a state row, and a claim this
cheap to make should be re-audited by any invocation that acts on it — so a resume re-derives it,
the same way a `deferred` build does.

## Three places that read "finished" as "broken"

An adversarial review of the first version found the same mistake in three separate consumers, all
of them testing `status !== 'ready'` and meaning "something went wrong":

- **A reviewer finding naming a satisfied upstream** recorded a `blocked-on` blocking item, which
  kept the DOWNSTREAM out of `ready`. The new terminal state had become a way to fail a run.
- **A cross-repo escalation aimed at one** was routed with no guard: a fix pass, commits and a fresh
  PR/MR, all in a repo every ship phase had already filtered out — a merge that tells nobody. It is
  refused now, and RECORDED, because a defect in shipped code is a real gap and a person's call.
- **With every CODE repo satisfied**, the run walked on to the cross-repo gate with an EMPTY
  candidate list and returned a green pass over nothing. A gate that validated nothing must never
  read as a gate that passed, so the run ends at the satisfied ending and says which it was.

The lesson is narrower than "add a status carefully": **a status enum where one value means finished
and the rest mean broken has no room for a second kind of finished.** Every `!== 'ready'` is a place
that assumption is written down.

## What is deliberately NOT changed

`deferred` keeps its empty-branch rule. An empty branch plus "the rest belongs to another owner" is
still a suspicious pair, and the honest version of that claim now has its own status to go to. The
rule was never wrong; it was only ever load-bearing for the case it could not name.

## Related

- [ADR 0011](0011-a-run-that-delivers-nothing-stops-for-a-human.md) — the floor this ending is
  carefully not, and whose count now includes criteria met by earlier work.
- [ADR 0027](0027-the-review-loop-does-not-halt-on-a-finding.md) — the same argument for a repo that
  cannot finish. This one is for a repo that has nothing to finish.
- `docs/agents/issue-tracker.md` — the repo's durable `dev-status` record, which on a satisfied repo
  names the commit and file:line instead of a branch and a PR/MR.
