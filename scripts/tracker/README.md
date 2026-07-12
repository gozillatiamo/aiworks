# Tracker adapter

Provider-agnostic shell scripts that read and update a **ticket** in the team's issue
tracker. The four entry scripts share one CLI surface; `lib.sh` dispatches to a
provider implementation chosen by `TRACKER_PROVIDER` (`notion` | `jira` | `linear`). Readers
print **plain text** to stdout. A ticket key is `FM-9` / `APP-123` / a bare number / a page id
/ a tracker URL.

| Script | Does |
|---|---|
| `get-ticket-details.sh`   | Read title, properties/fields (Status, Priority, Assignee, …) and the body |
| `get-ticket-comments.sh`  | Read open comments (`--deep` also gathers inline/block-anchored — Notion only) |
| `find-tickets.sh`         | **Search** the tracker (`--query`/`--type`/`--open`) — the dedup lookup |
| `upsert-ticket-details.sh`| Set Status/Priority/Effort/Title/Description, and write the full spec to the **body** (`--body`/`--body-file`) — updates or creates the ticket |
| `add-ticket-comment.sh`   | Add a comment (text from an argument or stdin) — Markdown is rendered to the tracker's native style, not posted raw |

The two write scripts accept `--dry-run` to print the request instead of sending it.

**Create a ticket:** pass the ref `new` with `--title` to `upsert-ticket-details.sh`
(Notion: a fresh page with an auto-assigned id; Jira: a new issue in `JIRA_PROJECT_KEY`
of type `JIRA_DEFAULT_ISSUETYPE`). The created key is printed as `Created <KEY> — …`.

**Child issues / sub-tasks (create-only):** the same `new` create accepts a set of
relation flags so a caller (e.g. `/qa-subtasks`) can build a child issue without touching
a provider API directly:

| Flag | Meaning | Jira | Notion |
|---|---|---|---|
| `--parent <KEY>` | make it a child of `<KEY>` | `fields.parent` | the parent-item relation (`NOTION_PROP_PARENT`) |
| `--subtask` | use the project's sub-task type (needs `--parent`) | resolved sub-task issue type (or `JIRA_SUBTASK_ISSUETYPE`) | no-op (the parent relation is the sub-item) |
| `--issuetype <name>` | create with this type | `fields.issuetype` | the Type property (`NOTION_PROP_TYPE`) |
| `--component <name>` (repeatable) | tag/component | project component, **validated** | a multi_select option (`NOTION_PROP_COMPONENT`) |
| `--link <TYPE>:<KEY>` (repeatable) | link the new issue to `<KEY>` | an issue link, new issue = outward subject | a relation (`NOTION_PROP_LINKS`) |

The new issue is always the **outward (subject)** side of a link, so
`--link Implements:APP-123` reads "*\<new\> implements APP-123*". On Jira an unknown
**component** is a loud failure (it lists the project's components) and an exact link type
that's missing falls back to the **closest** name (e.g. `Implements` → `Implement`) with a
note — neither is invented or silently skipped. Passing these flags to an *update* (a real
key, not `new`) warns and ignores them on Jira; on Notion the relation/multi_select flags
also work on an update.

**Spec in the body:** `--body <md>` / `--body-file <path|->` writes the full clarified
spec (Markdown — headings, bullet/numbered/to-do lists, quotes, dividers, pipe tables,
fenced code, and inline **bold**/*italic*/`code`/[links]) into the ticket body, not a
comment. Notion appends page blocks (in 100-block batches); Jira renders the Markdown to
ADF as the issue **description** (its one rich field — so a bare `--description` is used
only when no `--body` is given).

**Comments render Markdown too:** `add-ticket-comment.sh` no longer posts raw Markdown —
it converts it to each tracker's native style so headers, bullets, tables and inline
marks read as intended, not as literal `##`/`-`/`|`. **Jira** comment bodies are full ADF
(same renderer as the description), so headings, lists, **tables** and code blocks are
native. **Notion**'s `/comments` endpoint accepts a `rich_text` array only — never block
children — so a Notion *comment* can't hold heading/list/table *blocks*; it's rendered as
one prettified rich-text run instead: **bold** headings, `•`/numbered/`☑` list lines,
inline marks and real links kept as annotations, and tables laid out as aligned monospace.
Native heading/list/table blocks in Notion only exist in the page **body** (`--body`).

**Dedup before filing:** `find-tickets.sh --query "<distinctive token>" --open` searches
the board so a caller never files a duplicate. Notion matches a case-insensitive title
**substring**; Jira's `summary ~` is a **word/text** match — pick a distinctive whole
token. `--json` returns the raw matches for scripting.

## Layout

```
tracker/
├── lib.sh                     # provider dispatch + .env loading + tool checks
├── get-ticket-details.sh      # entry points — thin; parse args, call the provider fn
├── get-ticket-comments.sh
├── upsert-ticket-details.sh
├── add-ticket-comment.sh
├── notion/{impl.sh,notion.jq} # Notion REST implementation
├── jira/{impl.sh,jira.jq}     # Jira Cloud REST v3 implementation (ADF)
└── linear/impl.sh             # Linear GraphQL implementation (Markdown-native)
```

A provider `impl.sh` defines the interface `lib.sh` calls: `tracker_require_config`,
`tracker_get_details`, `tracker_get_comments`, `tracker_upsert` (4th arg = optional
Markdown body), `tracker_find`, `tracker_add_comment`, `tracker_comments_for_block`.
**To add a tracker** (e.g. GitHub Issues), drop a new `<provider>/impl.sh`
implementing those functions — nothing else changes (Linear was added exactly this way).

## Setup

```sh
cp .env.example .env      # then pick TRACKER_PROVIDER and fill that provider's block
```

Requires `bash`, `curl`, and `jq`.

## Usage

```sh
# read
./get-ticket-details.sh  FM-9
./get-ticket-comments.sh APP-123
./get-ticket-comments.sh --deep FM-9        # Notion inline comments (no-op on Jira)

# search (dedup) — provider-neutral flags
./find-tickets.sh --query "encryption" --open
./find-tickets.sh --type Bug --open --json

# update — provider-neutral flags
./upsert-ticket-details.sh FM-9    --status Testing
./upsert-ticket-details.sh APP-123 --status "In Review" --priority High
./upsert-ticket-details.sh new     --title "Encrypt DB at rest" --description "one-liner" --body-file spec.md
./add-ticket-comment.sh    FM-9    "Moving to Testing — plan attached."
./add-ticket-comment.sh    APP-123 < plan.md
./upsert-ticket-details.sh APP-123 --status Done --dry-run   # preview, don't send

# create a QA sub-task under a parent (component validated, Implements link added)
./upsert-ticket-details.sh new --parent APP-123 --subtask \
    --title "[QA][E2E] Sign-in" --component Cypress --link Implements:APP-123 \
    --body-file scenarios.md
```

The **status name** you pass is the org's real status. On Jira, `--status` is resolved
to a workflow **transition** (Jira moves by transition, not by writing the field). The
canonical workflow-phase → real-status mapping for this org lives in
`docs/agents/issue-tracker.md`.

## Notes / limitations

- **Notion**: only *open* comments are exposed by the API; resolved threads aren't.
  `--deep` fans out one request per block (parallel, `NOTION_CONCURRENCY`, default 8).
  Creating a missing ticket needs `--title`; the ticket number is auto-assigned.
  Comments are a `rich_text`-only run (no block children), so a very long Markdown
  comment is coalesced and capped at 100 rich-text objects — beyond that it's truncated
  with a "see the ticket body" note; put large specs in the **body** (`--body`), not a comment.
- **Jira**: a single comment stream (no `--deep`); description/comments are read+written
  as ADF (common node types rendered to text). A bare number needs `JIRA_PROJECT_KEY` to
  form the key. `--body` renders Markdown → ADF as the issue description.
  - `--effort` / `--dev-points` / `--qa-points` write to the custom fields named by
    `JIRA_EFFORT_FIELD` / `JIRA_DEV_POINTS_FIELD` / `JIRA_QA_POINTS_FIELD`. When a flag is
    passed but its field id is **unset**, the adapter no longer drops the value silently —
    it prints a `WARN:` to stderr and lists the flag under a `Skipped:` line on stdout (so
    `/estimate-ticket` can report the point never persisted). Run
    `jira/discover-fields.sh` to find the ids.
  - `find-tickets.sh` searches via `POST /rest/api/3/search/jql` (the enhanced endpoint
    Atlassian migrated to; the classic `POST /rest/api/3/search` was removed and now 410s,
    changelog CHANGE-2046). Pagination is token-based and the result has no `total` (use
    `/rest/api/3/search/approximate-count` for a count).
  - **Sub-tasks**: `--subtask` resolves the project's sub-task issue type from
    `GET /rest/api/3/issue/createmeta/{key}/issuetypes` (falling back to the global
    issue-type catalog), unless `JIRA_SUBTASK_ISSUETYPE` pins a name. `--component` is
    validated against `GET /rest/api/3/project/{key}/components`; `--link` resolves against
    `GET /rest/api/3/issueLinkType` and is posted to `POST /rest/api/3/issueLink` after the
    issue is created.
- **Notion**: `--parent`/`--link` are **relation** properties (`NOTION_PROP_PARENT` /
  `NOTION_PROP_LINKS`) and `--component` a **multi_select** (`NOTION_PROP_COMPONENT`);
  `--link` is **off** unless `NOTION_PROP_LINKS` is set (Notion has no typed issue links, so
  the parent relation already carries the QA "Implements parent" case). `--dry-run` notes
  the parent/link relations rather than resolving their page ids, to stay offline.
- **Linear** (GraphQL, `LINEAR_API_KEY` + `LINEAR_TEAM_KEY`): descriptions **and** comments
  are Markdown-native, so there's no ADF/blocks renderer — the Markdown is sent verbatim.
  `--status` names a workflow **state** resolved to its id within the team (unknown name →
  loud failure listing the team's states). `--priority` maps to Linear's Int 0–4
  (Urgent=1/High=2/Medium=3/Low=4/None=0; a bare 0–4 works too; an unrecognised name WARNs and
  is skipped). There is a **single numeric `estimate`** (no Dev/QA split) — this workspace
  **sums** `--effort` + `--dev-points` + `--qa-points` into it (needs team estimation enabled).
  `--issuetype` and `--component` both map to **labels** (Linear has no issue-type field; a
  missing label WARNs and is skipped, never invented). `--parent` sets the sub-issue parent
  (`--subtask` is a no-op note). `--link <TYPE>:<KEY>` creates an issue **relation** — Linear
  supports `related|blocks|duplicate`, so any other type (e.g. `Implements`) maps to `related`.
  `find-tickets.sh` scopes to `LINEAR_TEAM_KEY` (when set), matches the title case-insensitively,
  and treats "done" as a **completed** workflow state. `--dry-run` stays offline (describes the
  change by name; ids resolve on a real run). New issues (ref `new`) can default into a
  **project** via `LINEAR_PROJECT` (a project name) or `LINEAR_PROJECT_ID` (a UUID) — Linear has
  no team-level default-project setting through the API, so this is where you set it; the
  identifier PREFIX still comes from the team, not the project.
