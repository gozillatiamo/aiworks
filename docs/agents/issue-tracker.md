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
| Set estimate points | `scripts/tracker/upsert-ticket-details.sh <KEY> --dev-points <n> --qa-points <n> --effort …` |
| Create a child / sub-task | `scripts/tracker/upsert-ticket-details.sh new --parent <KEY> --subtask --title … --component <name> --link Implements:<KEY> --body-file …` |
| Add a comment | `scripts/tracker/add-ticket-comment.sh <KEY> "text"` (or pipe a file via stdin) |

Both write scripts accept `--dry-run`. The flags are **abstract**; the adapter maps them
to the provider (Notion properties; Jira fields + a status transition; Linear GraphQL fields
+ a workflow-state id).

**Estimate points are FIELDS, not a comment.** `--dev-points` / `--qa-points` write the
estimation split into dedicated number fields (Notion "Developer Points" / "QA Points";
Jira `JIRA_DEV_POINTS_FIELD` / `JIRA_QA_POINTS_FIELD`), and `--effort` the overall size
(Notion "Effort level"; Jira `JIRA_EFFORT_FIELD`). `/estimate-ticket` owns these — see
that skill. A provider with no point fields configured now **warns** and lists the flag
under a `Skipped:` line (it no longer drops the value silently) — check `Changed:` /
`Skipped:`. **Linear** has a single numeric `estimate` (no Dev/QA split), so this workspace
**sums** `--effort` + `--dev-points` + `--qa-points` into it — the split isn't stored
separately there.

**Child issues are create-only flags through the same adapter.** `--parent`, `--subtask`
(or `--issuetype`), `--component`, and `--link <TYPE>:<KEY>` on the ref `new` build a child
issue — provider-agnostic, no Atlassian MCP/OAuth, so it runs headless. `/qa-subtasks` uses
this to file per-tool QA sub-tasks (E2E→Cypress / API→Newman / Load→K6) under a parent with
an Implements link. On Jira an unknown component fails loud and a missing link type falls
back to the closest; see `scripts/tracker/README.md`.

## This workspace's settings

> Fill these in from `workspace.config.yaml`.

- **Provider:** `<notion | jira | linear>`
- **Ticket id format:** `<PREFIX>-<n>` (e.g. `FM-9`, `APP-123`). The id regex is
  `<PREFIX>-\d+`. A bare number is accepted (Notion: looked up by the unique-id
  property; Jira: expanded with `JIRA_PROJECT_KEY`; Linear: expanded with `LINEAR_TEAM_KEY`).
- **Notion only:** tasks database id = `<NOTION_DB_ID>`; unique-id property =
  `<NOTION_ID_PROP, default "Task ID">`. Never write `Task ID` or `Updated at`
  (read-only / auto).
- **Jira only:** project key = `<JIRA_PROJECT_KEY>`; status changes happen via
  **workflow transitions** (the adapter resolves a transition whose target matches the
  status name you pass).
- **Linear only:** team key = `<LINEAR_TEAM_KEY>` (the identifier prefix, e.g. `FM`);
  the id regex prefix is that team key. `--status` names a **workflow state** resolved to
  its id within the team, so `tracker.statuses` must map to your Linear state names.
  Descriptions and comments are Markdown-native. `--issuetype`/`--component` → **labels**;
  there is no separate issue-type field.

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
