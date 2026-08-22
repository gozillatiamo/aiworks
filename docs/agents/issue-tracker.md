# Issue tracker conventions

The single reference for how agents and skills read and write tickets in **this**
workspace. Skills (`ticket-kickoff`, `update-ticket`, `clarifying-ticket`,
`plan-testcases`, `report-test-results`, `open-pr`, `review`) consult this file instead
of hardcoding a provider — fill it in when you instantiate the workspace, alongside
`workspace.config.yaml`.

## The adapter is the only entry point

**Never** call a tracker's API/MCP directly. All ticket I/O goes through the shell
adapter in `scripts/tracker/`, which dispatches by `TRACKER_PROVIDER`
(`notion` | `jira` | `linear`) from `scripts/tracker/.env`:

| Need | Command |
|---|---|
| Read a ticket | `scripts/tracker/get-ticket-details.sh <KEY>` |
| Read comments | `scripts/tracker/get-ticket-comments.sh [--deep] <KEY>` |
| Set status/fields | `scripts/tracker/upsert-ticket-details.sh <KEY> --status … --priority … --title … --description …` |
| Set project + label | `scripts/tracker/upsert-ticket-details.sh <KEY> --project "<name>" --label <name>` (Jira ignores `--project` and says so — the project is `JIRA_PROJECT_KEY` at create) |
| Set estimate points | `scripts/tracker/upsert-ticket-details.sh <KEY> --dev-points <n> --qa-points <n> --estimate-reason-file <r.md>` |
| Create a child / sub-task | `scripts/tracker/upsert-ticket-details.sh new --parent <KEY> --subtask --title … --component <name> --link Implements:<KEY> --body-file …` |
| Add a **one-off** comment | `scripts/tracker/add-ticket-comment.sh <KEY> "text"` (or pipe a file via stdin) |
| Write a **durable record** | `scripts/tracker/upsert-ticket-comment.sh <KEY> --marker '[<kind> · <scope>]' < body.md` — one record per context, rewritten each run; read it back with `find-ticket-comment.sh` |

## A ticket is a record, not a transcript

Anything a run would write **again on a later invocation** is a durable record: one per
(kind, scope), identified by a visible marker line, upserted. Anything a run writes **once, ever**
is an ordinary comment. That is the whole test. Full reasoning:
[ADR 0026](../adr/0026-a-ticket-is-a-record-not-a-transcript.md).

| Marker | Written by | Contents |
|---|---|---|
| `[dev-status · <repo>]` | the build role | work branch, PR/MR, one line per deferred criterion + owner |
| `[regression · <repo>]` | the build role | the regression scope QA must cover — QA never guesses this |
| `[qa-plan · <repo>]` | the QA planner | the BDD plan (current revision) + a revision ledger |
| `[test-report · <repo>]` | `/report-test-results` | the run's verdict, screenshots and video |
| `[plans · <KEY>]` | the main session | plan Artifact links, one line per repo — omitted entirely when artifacts are off |

Rules that make a record work:

- **The marker is the body's first line**, verbatim: `**[<kind> · <scope>]**`. Never translated
  under a non-English `language` policy, never reworded, never merged across scopes. A comment is
  posted as Markdown, stored in the tracker's own format and read back as text, so an HTML comment
  would not survive; the marker has to be visible.
- The upsert **refuses** a body that omits its own marker. An unmarked record is invisible to the
  next run, which then posts a second one — the exact failure the marker prevents.
- **Never a "done" or "build finished" note.** The PR/MR is the code story; a comment restating it
  is noise on a ticket a person is trying to read.
- **History comes from a ledger, not from the previous record.** Append one line to
  `agent_logs/<KEY>-<kind>-history.tsv` and render the whole file. Asking an agent to carry old
  lines forward into a rewritten body is what produced three test reports that contradicted their
  own runs.
- Every provider updates in place, by whichever route its API offers — Jira and Linear rewrite the
  comment; Notion keeps the record as one callout **block** on the page, since its comment API
  cannot update. This is load-bearing: `dev-cycle` verifies its test-suite gate by *finding* the
  report through `find-ticket-comment.sh`, so a provider that cannot find one is a provider whose
  gate can never pass.

Both write scripts accept `--dry-run`. The flags are **abstract**; the adapter maps them
to the provider (Notion properties; Jira fields + a status transition; Linear GraphQL fields
+ a workflow-state id).

**Every ticket carries a project + a type label — the product-owner owns this.** When the
product-owner creates or completes a ticket it MUST end up with a **project** and a **type
label** (`Feature` | `Improvement` | `Bug`). *Checkable:* `get-ticket-details.sh <KEY>`
prints a `Project:` line and a `Labels:` line. On **create** (`new`) the adapter auto-applies
the configured default project (`LINEAR_PROJECT` in `.env`), so only the `--label` need be
passed; on an **existing** ticket, pass both `--project "<name>"` and `--label <name>` to
back-fill. Provider mapping of the two flags: **Linear** — `--project` resolves by name/id
and sets it on create *and* update, `--label` is a workspace label (must already exist);
**Jira** — `--label` → issue labels, `--project` is not per-issue (warned); **Notion** —
`--label` → the Component multi_select, `--project` not applicable (warned).

**Estimate points are FIELDS, not a comment.** `--dev-points` / `--qa-points` write the
estimation split into dedicated number fields (Notion "Developer Points" / "QA Points";
Jira `JIRA_DEV_POINTS_FIELD` / `JIRA_QA_POINTS_FIELD`), and `--effort` the overall size
(Notion "Effort level"; Jira `JIRA_EFFORT_FIELD`). `/estimate-ticket` owns these — see
that skill. A provider with no point fields configured now **warns** and lists the flag
under a `Skipped:` line (it no longer drops the value silently) — check `Changed:` /
`Skipped:`. **Linear** has a single numeric `estimate` (no Dev/QA split), so this workspace
**sums** `--effort` + `--dev-points` + `--qa-points` into it — the split isn't stored
separately there.

**Points require their reasoning — coupled in one call.** Whenever `--dev-points`/
`--qa-points` is set, `--estimate-reason` (or `--estimate-reason-file`, `-` = stdin) is
**mandatory** — and it's only valid alongside points. The adapter posts the reason as a
comment, then writes the fields, so a calibrated number can never land with no recorded
basis. A bare points write with no reason is rejected. (A re-estimation that only *confirms*
existing points changes no field, so it takes a plain `add-ticket-comment.sh` note instead.)

**Child issues are create-only flags through the same adapter** — `--subtask` (or
`--issuetype`), `--component`, and `--link <TYPE>:<KEY>` on the ref `new` build a child
issue — provider-agnostic, no Atlassian MCP/OAuth, so it runs headless. `/qa-subtasks` uses
this to file per-tool QA sub-tasks (E2E→Cypress / API→Newman / Load→K6) under a parent with
an Implements link. On Jira an unknown component fails loud and a missing link type falls
back to the closest; see `scripts/tracker/README.md`.

**`--parent` is the exception — it also works on an existing ticket, re-parenting it**
(both providers). Use it to move an already-created issue under a freshly created epic
(e.g. `decompose-ticket`'s epic-shape split no longer has to supersede the original —
it can re-parent it under the new epic instead).

## This workspace's settings

> Fill these in from `workspace.config.yaml`.

- **Provider:** `<notion | jira | linear>`
- **Ticket id format:** `<PREFIX>-<n>` (e.g. `FM-9`, `APP-123`). The id regex is
  `<PREFIX>-\d+`. A bare number is accepted (Notion: looked up by the unique-id
  property; Jira/Linear: expanded with `JIRA_PROJECT_KEY` / `LINEAR_TEAM_KEY`).
- **Notion only:** tasks database id = `<NOTION_DB_ID>`; unique-id property =
  `<NOTION_ID_PROP, default "Task ID">`. Never write `Task ID` or `Updated at`
  (read-only / auto).
- **Jira only:** project key = `<JIRA_PROJECT_KEY>`; status changes happen via
  **workflow transitions** (the adapter resolves a transition whose target matches the
  status name you pass).
- **Linear only:** team key = `<LINEAR_TEAM_KEY>`; `--status` names a workflow state
  resolved within the team. Linear has a single numeric `estimate`, so `--effort` +
  `--dev-points` + `--qa-points` are summed into it. Optional default project:
  `LINEAR_PROJECT` / `LINEAR_PROJECT_ID` in `.env`.


## Status lifecycle

Canonical workflow phases → this org's real status names (from
`workspace.config.yaml: tracker.statuses`). Pass the **real name** to
`upsert-ticket-details.sh --status`.

**The dev-cycle workflow owns the ticket status.** Because one ticket is shared by every
repo it touches, the workflow — not the per-repo agents — moves it, **forward only**, once
per aggregate milestone (so a multi-repo ticket can't thrash its status). Declare whatever
statuses your board uses; at each milestone the workflow picks the best one you've declared
(the *preference* column below), and silently skips any you haven't. A human or product-owner
still owns the initial state and may use extra statuses the workflow doesn't drive.

| Milestone (what the workflow means) | Status preference (first you declare) | Set by |
|---|---|---|
| ticket created            | `not_started` / `to_do`          | product-owner on creation |
| Kickoff begins            | `in_progress`                    | the workflow (once) |
| all repos built + reviewed + approved | `ready_to_merge` → `ready_to_test` | the workflow (once) |
| cross-repo test-suite gate running (pre-merge) | `testing`       | the workflow (once) |
| merged + distributed      | `done`                           | the workflow (once, after merge → distribute) |

`code_review` (and other intermediate states) are carried through to the board for humans /
other tools even though the workflow doesn't drive them. If a provider rejects a status (e.g.
no Jira transition to it from the current state), the adapter prints the available targets —
pick the right real name and update `workspace.config.yaml` so it matches your board.

## Notes

- **Reachability:** if the adapter errors (bad/missing token, network), treat the
  tracker as *unreachable* — proceed from inline context but loudly flag that status
  moves / comments did **not** persist (the dev-cycle does this automatically).
- **Improvement tickets:** non-blocking gate findings are filed with `/clarifying-ticket`,
  which creates a new ticket via this same adapter and returns the real new id.
