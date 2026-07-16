---
name: update-ticket
description: Write to a ticket in the issue tracker — move its Status, set properties (Priority/Effort/Title/Description), create a ticket when missing, and/or post a comment (inline text or a Markdown file like agent_logs/<KEY>-testcases.md). Wraps scripts/tracker/upsert-ticket-details.sh + add-ticket-comment.sh. Use whenever an agent or person needs to change a ticket or publish a note/plan/verdict onto a ticket.
argument-hint: "[ticket] [what to change — e.g. status Testing, comment plan.md]"
arguments: [ticket, request]
model: haiku
allowed-tools:
  - Bash(scripts/tracker/*)
---

# Update a ticket

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write every ticket description, spec, acceptance criterion, and comment you post (the ticket Summary/title itself stays on the English spine) in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code and checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files) are **never** Thai. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

One skill for **writing** to a ticket — moving status, upserting properties, creating a
ticket, and commenting. It composes the two tracker **writer** scripts; run them **from
the workspace root**. (For reading a ticket, use `scripts/tracker/get-ticket-details.sh`
/ `get-ticket-comments.sh` — those are read-only.) The tracker provider, status names,
and id format are defined in `docs/agents/issue-tracker.md` / `workspace.config.yaml`.

| Want to… | Use |
|---|---|
| Move Status / set a property / rename / create | `scripts/tracker/upsert-ticket-details.sh` |
| Post a comment (note, plan, verdict) | `scripts/tracker/add-ticket-comment.sh` |

Do **both** when the task calls for it (e.g. comment the plan *and* move Status →
Testing) — just run the two scripts.

## 1. Resolve the ticket

`$ticket` accepts a full key (`FM-9` / `APP-123`), a bare number (`9`), a tracker page
id, or a tracker URL — all work as the first argument to either script. If nothing in
`$request` or context names a ticket, ask the user for the key. Don't guess.

## 2. Properties & status — `upsert-ticket-details.sh`

Pass at least one flag; combine as many as you need in one call.

```sh
scripts/tracker/upsert-ticket-details.sh FM-9 --status Testing
scripts/tracker/upsert-ticket-details.sh FM-9 --status "In progress" --priority High
scripts/tracker/upsert-ticket-details.sh FM-9 --title "New title" --description "Some context"
```

**Values are abstract; the adapter maps them to the provider.**
- `--status` — use the org's **real** status name from `issue-tracker.md`
  (`Not started` · `In progress` · `Ready to test` · `Testing` · `Done`, or your
  equivalents). On Jira this resolves to a workflow transition.
- `--priority`, `--effort` — provider values (e.g. `High`/`Medium`/`Low`); `--effort`
  may be a no-op unless mapped (see the tracker README).
- `--title <text>` · `--description <text>` — free text.

**Create (upsert):** where the provider supports it (Notion), passing `--title` for a
missing ticket creates it (the id is auto-assigned, so it won't reuse the key you
passed). Without `--title`, a missing ticket is an error.

## 3. Comments — `add-ticket-comment.sh`

- **Markdown file** (the common case — e.g. `agent_logs/<KEY>-testcases.md`): pipe it in
  via **stdin** and post it **verbatim**.
  ```sh
  scripts/tracker/add-ticket-comment.sh FM-9 < agent_logs/FM-9-testcases.md
  ```
- **Short inline text:** pass it quoted as the second argument.
  ```sh
  scripts/tracker/add-ticket-comment.sh FM-9 "All planned cases pass on Android + iOS."
  ```
- **Markdown in context but not on disk:** write a temp file first, then pipe it.

> Note: some trackers store comments as plain/rich text, so Markdown may show literally
> rather than rendered. The content is preserved faithfully; only live styling may not be.

## 4. Preview, then write

Both writers take `--dry-run` — it prints the request instead of sending. Use it when
unsure about the resolved ticket, status name, or comment body, then run for real.

```sh
scripts/tracker/upsert-ticket-details.sh FM-9 --status Done --dry-run
scripts/tracker/add-ticket-comment.sh    FM-9 < plan.md --dry-run
```

## 5. Requirements & failures

- Needs `scripts/tracker/.env` configured for the active `TRACKER_PROVIDER` (plus `curl`
  + `jq`) — see `scripts/tracker/README.md`.
- If a script errors (no creds, ticket not found, unknown status/transition, empty
  comment, nothing to update), **surface the exact error and stop** — don't retry
  blindly, invent a ticket, or fall back to a different status.

Finish by reporting what changed — the ticket plus the new status/properties and/or the
comment id (or the dry-run preview) — to whoever invoked the skill.
