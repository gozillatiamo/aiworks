# The run ticks its own approval; the merge stays human

**Status:** Accepted

A review that passed used to end in a structured field and a chat line. The forge's own
**approve** — the GitLab MR approve, the GitHub `APPROVE` review — stayed untouched, on purpose.
`dev-cycle` says so in as many words, in the brief every gate receives:

> Never call `scripts/vcs/pr-approve.sh` … The host approval belongs to a human who is not part
> of this run.

The reasoning was sound and is not being discarded here: the developer agent and the reviewing
agent are two agents of the **same** automated run, so anything from the reviewer that reads as
an approval clears a two-party review requirement with one party. A gate that reports is an
instrument; a gate that approves is an authority.

What that left behind, though, was a forge with no record of the outcome. Every MR looked
identical — reviewed and clean, or never looked at — and the only way to tell was to read the
run summary or the ticket. Two costs followed. A human deciding what to merge had to reconstruct
a verdict that already existed. And nothing on the MR said "this review is finished", so the
next invocation had no cheap way to know either, and re-derived a review that had already
concluded (the failure [ADR 0021](0021-a-passed-gate-is-recorded-not-re-derived.md) attacked
from the ledger side).

The decision, in three parts:

1. **The tick is posted, and the ORCHESTRATOR posts it.** The gates keep `NO_SELF_APPROVE`
   verbatim — no gate calls `pr-approve.sh`, no gate phrases a comment as an approval. The
   workflow ticks, at a bar the workflow computed. That preserves the instrument/authority split
   the ban was protecting, and buys determinism the ban did not have: a gate that runs out of
   turns or talks itself into "no Bash" would silently leave the MR unapproved while returning a
   pass. `/ultra-review` §3.5 already worked this way; `dev-cycle` now matches it.
2. **The bar is ticket-wide, and the tick names its evidence.** Zero unresolved must-fix at
   every gate on every repo, plus a green test receipt per repo. Anything less ticks nothing
   anywhere — not even a repo that came back clean, because a ticket's repos are usually
   ship-order-coupled and approving one alone reads as "mergeable on its own". The verdict line
   quotes the suite that proved it; an approval that cannot point at a test result is exactly the
   failure the green gate exists to prevent.
3. **The merge stays a human decision.** With `vcs.auto_merge` off — this workspace's setting —
   the run leaves the PR/MR open and approved and stops. Nothing merges: not the gates, not the
   orchestrator, not with auto-merge on.

## What this costs

**The approval no longer means "a human cleared this."** That is the real price, and it is not
mitigated away by wording. A reader who sees a tick on an MR must know it may have been posted by
the same run that wrote the branch. Three things keep that honest rather than misleading:

- the verdict line on the tick says what was measured and which suite proved it, so the tick is a
  claim with evidence attached rather than a rubber stamp;
- the tick is decoupled from the merge, and the merge is the decision that actually ships — so a
  human still stands between an approved MR and the base branch;
- an approval also **freezes** the review (`docs/agents/review-ledger.md` §5), and a freeze
  inherited from the forge is recorded with `"source":"forge-approval"` rather than as a gate
  pass, so no later reader is told a review happened that did not.

A workspace that needs the forge approval to mean *human* specifically should not adopt part 1 —
it should leave `NO_SELF_APPROVE` covering the orchestrator too and accept the reconstruction
cost. That is a config-shaped decision we have not needed to make; if it is ever needed, the
single call site (`approvalTick` in `.claude/workflows/dev-cycle.js`) is where it goes.

## What it buys

An MR whose state is readable — by a person scanning the board, and by the next invocation.
`scripts/vcs/pr-view.sh <num> --approved` answers `yes` / `no` / `unknown`, so an already-passed
review is skipped instead of re-derived, and `pr-approve.sh` is idempotent so re-entering a
frozen gate cannot stack a second verdict. `unknown` — a forge that will not answer — counts as
unapproved and reviews: a review that ran needlessly costs tokens, a review skipped on a fiction
ships the bug it would have caught.
