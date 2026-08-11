# Deferred scope does not stop a run

**Status:** Accepted

A `dev-cycle` build hands back one of four states. Three are old: `complete`, `partial` (work of
this repo's own remains), `blocked` (cannot proceed). The fourth is new — **`deferred`**: the repo's
own work is done and green, and what the ticket still wants belongs to another owner. A `deferred`
repo keeps going. It opens its PR/MR, gets reviewed, faces the test gate, and reaches the merge
handoff, carrying the criteria it does not meet on the MR, on the ticket, and in the run summary.

Before this, every handoff that was not `complete` returned `build-unresolved` and skipped the rest
of that repo's pipeline; because the run also requires the whole change set to be ready before any
merge, one such repo ended the run.

## What that cost

APP-1531 is the case that forced the question. The service repo's build fixed the read-path bug,
landed two commits, kept the tree clean, and left receipts: `dev.sh gen` exit 0, fourteen unit tests
green, one DAO integration test green. Two acceptance criteria it could not meet — one needs a route
change in a gateway repo this workspace does not hold, one needs a certificate nobody in the run can
issue. It reported `partial`, honestly, and the run recorded `repo-unresolved` and stopped.

Nothing was wrong with the code. What followed was done by hand in the main session: push, open the
MR, spawn both reviewers, apply their must-fixes, re-review, bring up the local stack, run the QA
gate, move the ticket twice, write the notification. A workflow whose purpose is to carry a ticket
end to end had carried it to the point of being green and then handed the whole remainder back.

The schema's own words show why. `partial` was documented as *"some slices landed, work remains"*,
which is true of both "I did not finish my work" and "my work is finished; the rest is not mine" —
and those two want opposite handling. One should stop. The other should not.

## Why not simply proceed on `partial`

Because `partial` also covers the case the old behaviour was right about. A build that ran out of
budget mid-feature, or left a slice unimplemented, must not open a PR and collect approvals; the
stop is the feature there. Widening `partial` to proceed would trade one wrong outcome for another.

A fourth state keeps both: `partial` stops, as it always did, and `deferred` proceeds.

## Why not stop at the PR, short of the gate

Considered, and rejected: open the MR, then hand over. But review and the test gate are exactly the
signal a green slice deserves — a reviewer reads the diff against the criteria it *does* claim, and
the suite proves the change works against the candidate build. Stopping before them discards that
work and puts a person back in the loop for the case this design exists to remove.

## The cost we accepted, and what pays for it

A ticket can now reach *ready to merge* with acceptance criteria openly unmet. That is a real
weakening of what the status means, and it is deliberate. Four things keep it honest:

- **The deferral is loud where the decision happens.** The unmet criteria appear in the PR/MR body,
  and again in the terminal beside the merge command a human must run — not only in a summary read
  afterwards. Merging is the irreversible step, so that is where the warning belongs.
- **The status never advances past *ready to merge*.** The workflow does not move a ticket to done;
  distribution and closure stay a human's.
- **`deferred` costs more to claim than `partial`.** It requires a per-criterion owner and
  `evidence` — something the agent actually observed, a file:line, a config value, a command and its
  refusal — plus `met_acceptance`, the criteria the diff does meet.
- **The claim is audited.** The scope stage declares up front which criteria are out of reach in this
  workspace by construction; a deferral matching that settled list needs nothing further, and any
  other deferral is read by a separate verifier that confirms the evidence is real, that no file in
  this repo could satisfy the criterion, and that the branch is genuinely clean and committed. It
  downgrades an unevidenced claim to `partial`, which stops the repo. A verifier that fails to
  converge is treated as a rejection: an unaudited deferral must not be able to buy a merge.

## The floor

Two stops remain, because "proceed" is not "proceed regardless".

**At scope.** If no acceptance criterion is reachable in this workspace at all, the run stops
immediately — before a branch is cut, a plan is written, or the ticket's status is touched. The
verdict is the same one it would reach forty minutes later; taking it early leaves no half-state to
clean up.

**After build.** If every repo deferred and not one criterion was met, the change set delivers
nothing the ticket asked for. Reviewed, green and pointless is still pointless: the run stops, the
PR/MR stay open, and a human decides whether to re-scope, route it to the owners, or merge the
groundwork deliberately.

## No ticket is filed

A deferred criterion does *not* become an automatic follow-up ticket, even though the pipeline files
Improvement tickets elsewhere. Deferred scope is a statement about ownership, and picking the owner,
the priority and whether it is worth doing at all is a product decision — so it lands in the run
summary under a heading that names the decision waiting, and a person makes it.

## Consequences

- A green slice ships on its own, and the run says plainly what it left behind.
- *Ready to merge* now means "everything this change set claims is reviewed and tested", not
  "the ticket is fully satisfied" — read the MR for the difference.
- A build agent that wants out of hard work cannot get there by calling it someone else's: the
  evidence requirement and the verifier are what stand in the way, and `partial` remains the
  honest, cost-free answer for unfinished work of its own.
