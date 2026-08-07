---
name: update-ticket
description: Write to a ticket in the issue tracker — move its Status, set properties (Priority/Effort/Title/Description), create a ticket when missing, post a comment (inline text or a Markdown file like agent_logs/<KEY>-testcases.md), and attach a file so it shows INSIDE the comment (a screenshot, a rendered report). Wraps scripts/tracker/upsert-ticket-details.sh + add-ticket-comment.sh + add-ticket-attachment.sh. Use whenever an agent or person needs to change a ticket, publish a note/plan/verdict onto a ticket, or put visual evidence on one.
argument-hint: "[ticket] [what to change — e.g. status Testing, comment plan.md]"
arguments: [ticket, request]
model: haiku
allowed-tools:
  - Bash(scripts/tracker/*)
---

# Update a ticket

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write every ticket description, spec, acceptance criterion, and comment you post (the ticket Summary/title itself stays on the English spine) in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code, checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files), **and ANY file you author with a `.md` extension** (plans, testcases, PRD/summary Markdown in `agent_logs/`) are **never** Thai — the `th` prose rule applies to chat, tickets, PR/MR discussion, Slack, and `.html` docs only. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

One skill for **writing** to a ticket — moving status, upserting properties, creating a
ticket, and commenting. It composes the two tracker **writer** scripts; run them **from
the workspace root**. (For reading a ticket, use `scripts/tracker/get-ticket-details.sh`
/ `get-ticket-comments.sh` — those are read-only.) The tracker provider, status names,
and id format are defined in `docs/agents/issue-tracker.md` / `workspace.config.yaml`.

| Want to… | Use |
|---|---|
| Move Status / set a property / rename / create | `scripts/tracker/upsert-ticket-details.sh` |
| Post a comment (note, plan, verdict) | `scripts/tracker/add-ticket-comment.sh` |
| Show a file (screenshot, report) **in** a comment | `scripts/tracker/add-ticket-attachment.sh` → §4 |

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

## 4. Attachments — show the file, don't just upload it

An uploaded file lands in the ticket's **Attachments panel**, away from the words that
explain it and under whatever name the tool that produced it chose. Evidence read that
way is evidence nobody reads. Put it **in** the comment instead. Three moves, in order:

**Rename first.** Copy the artifact to a name that says what it is —
`<KEY>-TC001-fail.png`, `<KEY>-loadtest.png` — under `agent_logs/<KEY>-artifacts/`.
The tracker never renames an attachment, so the upload name is permanent, and the
original (`… -- TC001 [regression] - Success … (failed).png`) is unreadable in a panel.
Copy, never move: the original stays put for anyone re-reading the run. Re-running the
same ticket? Suffix the round — `-r2` — because Jira does **not** dedupe filenames and
two same-named attachments leave nobody able to tell which is current.

**Upload and keep the EMBED id.** An upload yields two handles and they are not
interchangeable: the numeric attachment id (`--id-only`) is the tracker's own, used to
remove or download the file later, while the **media uuid** (`--embed-id`) is the only
thing an inline image accepts. Feeding the numeric one to a comment is rejected with a
bare `ATTACHMENT_VALIDATION_ERROR` that names nothing.
```sh
id=$(scripts/tracker/add-ticket-attachment.sh <KEY> agent_logs/<KEY>-artifacts/<KEY>-TC001-fail.png --embed-id)
```

**Embed it by that id.** In the Markdown you pipe to `add-ticket-comment.sh`, put the
image **alone on its own line** — that is what makes it a block-level image rather than
literal text:
```markdown
### TC001 — Sign in with a wrong password
![TC001 fail](attachment:12345)
```
One image on a line renders full-width; several on **one** line render as a thumbnail
strip. Use full-width for a failure a human must actually look at, and a strip for
pass evidence that is proof-of-record.

Two limits, both loud rather than silent: this is **Jira-only** (Notion's uploader dies
with a message saying so), and an `![…](attachment:…)` **not** alone on its line stays
literal text — ADF has nowhere to put an image inside a paragraph.

## 5. Preview, then write

Both writers take `--dry-run` — it prints the request instead of sending. Use it when
unsure about the resolved ticket, status name, or comment body, then run for real.

```sh
scripts/tracker/upsert-ticket-details.sh FM-9 --status Done --dry-run
scripts/tracker/add-ticket-comment.sh    FM-9 < plan.md --dry-run
```

## 6. Requirements & failures

- Needs `scripts/tracker/.env` configured for the active `TRACKER_PROVIDER` (plus `curl`
  + `jq`) — see `scripts/tracker/README.md`.
- If a script errors (no creds, ticket not found, unknown status/transition, empty
  comment, nothing to update), **surface the exact error and stop** — don't retry
  blindly, invent a ticket, or fall back to a different status.

Finish by reporting what changed — the ticket plus the new status/properties and/or the
comment id (or the dry-run preview) — to whoever invoked the skill.
