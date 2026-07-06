---
name: qa-subtasks
description: Create per-tool QA sub-tasks (Cypress / Newman / K6) under a parent ticket — BDD scenarios authored by a Senior QA Expert, each created as a child of the parent with the right Component and an Implements link. Goes through the tracker adapter (scripts/tracker/), provider-agnostic and headless-safe — never an Atlassian MCP/OAuth. Accepts an optional positional arg `parent-ticket-number` (e.g. `APP-123`). Use when the user wants QA sub-tasks for a ticket, or as the QA step of /clarifying-ticket.
argument-hint: "[parent-ticket-number] [tools: E2E API Load]"
model: opus[1m]
effort: high
allowed-tools:
  - Bash(scripts/tracker/*)
  - Read
  - Grep
  - Glob
  - Write
  - AskUserQuestion
---

# QA sub-task creation

Create one QA sub-task per selected tool **under a parent ticket**, each a true child
(sub-task) with the right Component set and an **Implements** link back to the parent.

All tracker reads/writes go through the **tracker adapter** (provider-agnostic —
`notion`|`jira`); **never** call an Atlassian MCP or any tracker API directly. This keeps
the skill **headless-safe** — it runs unchanged inside workflows/cron, with no interactive
OAuth (`/mcp`) handshake:

```
$CLAUDE_PROJECT_DIR/scripts/tracker/
  get-ticket-details.sh   <PARENT>           # read the parent: title + scope + AC (plain text)
  get-ticket-comments.sh  <PARENT> [--deep]  # extra context if the body is thin
  upsert-ticket-details.sh new --parent <PARENT> --subtask \
      --title "[QA][<TOOL>] <title>" --component <Cypress|Newman|K6> \
      --link Implements:<PARENT> --body-file <scenarios.md>   # CREATE the sub-task
```

Provider + auth + the project/db come from `scripts/tracker/.env` — you never pass them.
The adapter maps the abstract flags to each provider (Jira: a sub-task issue type +
`parent` + project `components` + an issue link; Notion: a parent-item relation + a
`Component` multi_select). See `scripts/tracker/README.md` and
`docs/agents/issue-tracker.md`.

## 0. Establish parent context

The parent ticket's **title**, **user story**, **scope**, and **acceptance criteria** are
the raw material for the scenarios. Get them before authoring:

- **Invoked from `/clarifying-ticket` (its QA step)** → the clarified ticket is already in
  context. Reuse it; don't re-fetch.
- **Invoked standalone with `$parent-ticket-number`** → read it with
  `get-ticket-details.sh <PARENT>` (and `get-ticket-comments.sh <PARENT>` if the spec is
  thin). Capture title + description + acceptance criteria.
- **No key and no context** → ask the user for the parent key (or to paste the ticket),
  then read it.

If you can't resolve a parent ticket through the adapter, stop and tell the user — there's
nothing to attach sub-tasks to. If the adapter errors (bad/missing token, network), treat
the tracker as **unreachable** and say the sub-tasks were **not** created (don't fabricate
keys) — same rule as `docs/agents/issue-tracker.md`.

Ground the scenarios in real context where you can — the parent's AC first, plus any
product docs the repo already has (`Grep`/`Glob` under `docs/`). Keep scenarios
**business-level**: no file paths, function names, schema fields, HTML tags, or ARIA roles
in the description.

## 1. Choose which tools

If the invocation already names the tools (e.g. "`/qa-subtasks APP-123 E2E API`", or the
calling step passed a selection), **use them directly — do not ask** (this is what keeps a
headless run unattended). Otherwise, when interactive, `AskUserQuestion` with
`multiSelect: true`:

- **E2E (Cypress)** — browser-level end-to-end tests
- **API (Newman / Postman)** — API contract & behavior tests
- **Load test (K6)** — performance / load testing

Zero selections → create nothing, stop.

## 2. For each selected tool, author and create a sub-task

One sub-task per tool. Never bundle.

### Title

`[QA][<TOOL>] <parent ticket title>` — `<TOOL>` ∈ `E2E`, `API`, `Load`.

### Authoring stance (instructions for you — DO NOT paste into the description)

Adopt this voice when writing the scenarios, then discard:

- **Role:** Senior QA Expert (10 yrs), with high-scale load-testing expertise.
- **Format:** BDD using `Given / When / And / Then`.
- **Scope:** 3–5 high-impact scenarios, tuned to the sub-task purpose (E2E, API, Load).
- **Focus-area spread:** across the set, cover **Correctness, Accessibility, Security,
  Performance** — tag each scenario with its focus area in parentheses.
- **Rules:** each scenario has a distinct, self-contained business purpose; business-level
  only (no HTML tags, ARIA, DB fields); if later asked for "another one," add exactly one
  more; copy-friendly output, no concluding text.

### Description content (what goes into the ticket body)

Before writing your first sub-task this session, **`Read` the companion `qa-examples.md`**
once — it shows the level of detail and focus-area spread to match. The example is E2E, but
the same pattern applies to API and Load: only the `Scope:` line and the flavor of the
`Then` assertions change.

Write the filled template to a file, then pass it with `--body-file` (multi-line specs go
into the **body**, not a comment). Template — copy and fill:

```
Feature: <feature name — same business concept as the parent ticket>
Scope: <End-to-End (E2E) | API | Load Test>
Parent: <PARENT> — <parent title>

User story / context:
<User story + Scope + Acceptance criteria from the parent ticket>

**Scenario 1**: <name> (<focus area>)
  Given <…>
  When <…>
  And <…>
  Then <…>
  And <…>

**Scenario 2**: <name> (<focus area>)
  Given <…>
  When <…>
  Then <…>

<…3–5 total scenarios, each a distinct focus area…>
```

### Create + link to parent (one adapter call)

Write the scenarios to a temp markdown file, then create the sub-task:

```sh
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --parent <PARENT> --subtask \
  --title "[QA][<TOOL>] <parent title>" \
  --component <Cypress|Newman|K6> \
  --link Implements:<PARENT> \
  --body-file <path-to-scenarios.md>
```

Read the new key from the adapter's `Created <KEY> — …` line; the `Components:` and
`Linked … —[…]→ <PARENT>` lines confirm the component + link landed. `--dry-run` first if
you want to preview the request.

- **`--subtask`** makes it a true child of `--parent` (Jira: the project's sub-task issue
  type; Notion: the parent-item relation). The adapter resolves the sub-task type itself.
- **`--component`** sets the per-tool component. This mapping is the **source of truth** —
  extend it here when a new QA tool is added:

  | Tool | Component |
  | --- | --- |
  | E2E | `Cypress` |
  | API | `Newman` |
  | Load test | `K6` |

  On **Jira** the adapter **validates** the component against the project and **fails loud**
  if it's missing (it prints the available components) — it never invents one. If that
  happens, tell the user which component is missing and ask whether to (a) re-run **without**
  `--component`, or (b) pause so they can add the component in Jira first. Do **not** quietly
  drop it.
- **`--link Implements:<PARENT>`** adds the *implements* link (new sub-task **implements**
  parent). If the exact `Implements` link type doesn't exist, the adapter automatically uses
  the closest one (e.g. `Implement`) and says so in its output — surface that note; never
  skip the link silently.

## 3. Report

Print each created sub-task's **key + title + component + link** (and URL when available via
`get-ticket-details.sh <KEY>`). If a tool's creation failed (e.g. missing component on a
real run), say which one and why, and what you did about it — don't report a partial run as
a clean success.
