# A ticket is a record, not a transcript

**Status:** Accepted

Everything a run writes onto a ticket is **one durable record per (kind, scope), rewritten** — never
a new comment each time. A ticket carries the current state of the work, not the history of the
runs that produced it.

## What it was

Each phase posted a fresh comment on every invocation: a test plan at Kickoff, a scoped re-plan for
every bug in the QA loop, a regression request refreshed after every fix batch, a per-repo test
report, and a "dev status" the workflow asked for but no skill or agent file ever defined — so each
build agent invented its own, and what actually landed were free-form "dev done" and "dev build"
notes nobody had specified.

On a ticket run seven times, that is a stack of near-identical tables and requests with no way to
tell which is current. It also broke something else. The Kickoff skip-gate originally fingerprinted
the ticket as *title + acceptance criteria + comment count*, on the sound reasoning that a
requirement change can arrive in a comment. In practice it was self-defeating: **the run itself posts
comments**, so the count climbed on every invocation and the very next resume read a changed
fingerprint and re-planned every repo from scratch — the fingerprint invalidating the plan it had
just written. The fix at the time was to drop comments from the hash, accepting that a requirement
living only in a comment no longer invalidates a plan ([ADR 0018](0018-dev-cycle-keeps-its-own-run-state.md)).
That trade was forced by comment spam the run was generating itself.

And a rewrite-in-place report that carries its own history forward is a **lossy operation performed
by a language model, repeatedly.** Measured: the per-repo test report contradicted the run it claimed
to describe in three separate rounds — wrong pass/fail counts, a `grep=` label for a filter nobody
ran, mismatched candidate shas, once the wrong spec name entirely. The audit caught all three and
recorded the gate as NOT RUN, which is the system working; but each catch cost a fix round, and the
writer bug was still live.

## The decision

**One record per (kind, scope), keyed by a visible marker line, upserted.**

| Marker | Owner | Contents |
|---|---|---|
| `[dev-status · <repo>]` | build role | the work branch, the PR/MR, one line per deferred criterion and its owner |
| `[regression · <repo>]` | build role | the regression scope only the author of the change can know |
| `[qa-plan · <repo>]` | QA planner | the BDD plan, current revision, plus a revision ledger |
| `[test-report · <repo>]` | `/report-test-results` | the run's verdict, with its own evidence |
| `[plans · <KEY>]` | main session | plan Artifact links, ticket-wide |

Four consequences worth stating outright:

**No "dev done" or "dev build" note.** The PR/MR is the code story — its diff, its title, its body,
its review threads. A comment restating it is noise on a ticket a human is trying to read. Deleted,
not reworded.

**A plan travels as a link, never as a body.** A plan is a working artifact superseded by the next
planning pass, and `agent_logs/` is git-ignored for exactly that reason. When `planning.to_html` and
`artifacts.enabled` are both on, the ticket carries one `[plans · <KEY>]` record listing one URL per
repo, rendered from the `artifact_published` run-state rows so it never needs merging by hand. When
either gate is off, there is no record — not an empty one, not a path nobody else can open. The QA
**BDD plan** is the exception and stays a body: it is the artifact the team reads to know what will
be tested. The QA **automation** plan was already never published.

**History is rendered from a ledger, never re-typed.** Anything that must show what earlier rounds
did keeps a per-repo append-only file (`agent_logs/<KEY>-qa-plan-history.tsv`,
`<KEY>-test-report-history.tsv`): one `printf >>` per run, then the whole file rendered into the
record. This is the direct fix for the contradicting reports — carrying old lines forward is the
operation that broke, so no agent does it. Relatedly, the run's own invocation ordinal is now
computed once by the workflow and threaded to everything that used to guess it; the test report's
`run r<n>` stamp is the only thing separating this run's result from the last one's, and the audit
records a gate as NOT RUN when it does not match.

**Every provider updates in place, by whichever route its API offers.** Jira and Linear rewrite the
comment body — Linear's `commentUpdate` existed all along and simply was not wired up. Notion's
comment API has no update endpoint at all, so there a record is not a comment: it is one `callout`
**block** on the page, marker in the callout's own text, record in its children, and an update
archives that block and appends a fresh one. The comment feed is left to humans, which is the right
split — their conversation is a conversation, and these records are not.

That last point was not a nicety. `dev-cycle` proves its cross-repo test-suite gate really ran by
having a second agent *find* this run's result on the ticket, through `tracker_find_comment`. While
two providers answered "nothing" unconditionally, **that gate could never be verified on either** —
it was recorded as NOT RUN on every ticket, on the framework's own default provider. A find that
cannot find is not a missing convenience; it is a gate that cannot pass.

## Rules a writer must follow

- The marker is the record's **first line**, verbatim, brackets and all: `**[<kind> · <scope>]**`.
  Not translated under a non-English `language` policy, not reworded, never merged across scopes.
  A comment is posted as Markdown, stored as the tracker's own format and read back as text, so an
  HTML comment would not survive the trip — the marker has to be visible.
- `upsert-ticket-comment.sh`, never `add-ticket-comment.sh`. The upsert **refuses** a body that
  omits its own marker: such a record is invisible to the next run, which then posts a second one.
- It is a WRITER — run it bare. No pipe, no `&&`, no `$( )`, no heredoc, or the allow rules match
  nothing and the call is denied silently.
- `add-ticket-comment.sh` remains correct for a genuine **one-off**: an "already implemented"
  short-circuit, a note that this ticket duplicates another, a link to a filed improvement. The test
  is whether a later run would ever write it again.

## Related

- [ADR 0018](0018-dev-cycle-keeps-its-own-run-state.md) — run state, and the fingerprint that had to
  stop counting comments because the run kept adding them.
- [ADR 0025](0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md) — the sibling rule for
  the run's own decisions: state that is real proof, asserted rather than assumed.
- `docs/agents/issue-tracker.md` — the marker table, and which adapter script to reach for.
