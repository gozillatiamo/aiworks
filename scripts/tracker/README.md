# Tracker adapter

Provider-agnostic shell scripts that read and update a **ticket** in the team's issue
tracker. The four entry scripts share one CLI surface; `lib.sh` dispatches to a
provider implementation chosen by `TRACKER_PROVIDER` (`notion` | `jira`). Readers print
**plain text** to stdout. A ticket key is `FM-9` / `OFB-123` / a bare number / a page id
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
└── jira/{impl.sh,jira.jq}     # Jira Cloud REST v3 implementation (ADF)
```

A provider `impl.sh` defines the interface `lib.sh` calls: `tracker_require_config`,
`tracker_get_details`, `tracker_get_comments`, `tracker_upsert` (4th arg = optional
Markdown body), `tracker_find`, `tracker_add_comment`, `tracker_comments_for_block`.
**To add a tracker** (e.g. Linear, GitHub Issues), drop a new `<provider>/impl.sh`
implementing those functions — nothing else changes.

## Setup

```sh
cp .env.example .env      # then pick TRACKER_PROVIDER and fill that provider's block
```

Requires `bash`, `curl`, and `jq`.

## Usage

```sh
# read
./get-ticket-details.sh  FM-9
./get-ticket-comments.sh OFB-123
./get-ticket-comments.sh --deep FM-9        # Notion inline comments (no-op on Jira)

# search (dedup) — provider-neutral flags
./find-tickets.sh --query "encryption" --open
./find-tickets.sh --type Bug --open --json

# update — provider-neutral flags
./upsert-ticket-details.sh FM-9    --status Testing
./upsert-ticket-details.sh OFB-123 --status "In Review" --priority High
./upsert-ticket-details.sh new     --title "Encrypt DB at rest" --description "one-liner" --body-file spec.md
./add-ticket-comment.sh    FM-9    "Moving to Testing — plan attached."
./add-ticket-comment.sh    OFB-123 < plan.md
./upsert-ticket-details.sh OFB-123 --status Done --dry-run   # preview, don't send
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
  as ADF (common node types rendered to text). `--effort` is ignored unless
  `JIRA_EFFORT_FIELD` is set. A bare number needs `JIRA_PROJECT_KEY` to form the key.
  `--body` renders Markdown → ADF as the issue description. `find-tickets.sh` uses the
  classic `POST /rest/api/3/search`; newer Cloud sites may need `/rest/api/3/search/jql`.
