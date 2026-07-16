---
name: clarifying-ticket
description: Turn a rough request OR a non-blocking gate finding into a well-formed ticket in the issue tracker — clarified title, type, priority, effort, and a templated spec. Dedups against the existing board first (find-tickets.sh) so the same finding is never filed twice. Goes through the tracker adapter (scripts/tracker/), provider-agnostic. Use when a guardian/perf gate files an Improvement ticket (dev-cycle), or when a product-owner/user wants a raw idea groomed into a proper ticket. Returns the <KEY> (new, or the existing one a duplicate matched) + URL for improvements_filed.
argument-hint: "[request-or-finding] [source <KEY>]"
allowed-tools:
  - Bash(scripts/tracker/*)
  - Read
  - Grep
  - Glob
  # Codegraph (per-repo index): the FIRST lookup for the Mode-B code skim —
  # codegraph explore/search before Grep/Glob/Read (which stay the last resort).
  - Bash(codegraph *)
  - AskUserQuestion
---

# Clarifying a ticket

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write every ticket description, spec, acceptance criterion, and comment you post (the ticket Summary/title itself stays on the English spine) in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code and checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files) are **never** Thai. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

Clarify a vague request or a gate finding into a ready-to-implement ticket. The ticket
**templates** live in the companion **`templates.md`** next to this file. All tracker
reads/writes go through the **tracker adapter** (provider-agnostic — `notion`|`jira`);
**never** use a tracker MCP/plugin directly:

```
$CLAUDE_PROJECT_DIR/scripts/tracker/
  find-tickets.sh         [--query <text>] [--type <name>] [--open] [--limit n] [--json]   # SEARCH the board (dedup)
  get-ticket-details.sh   <ref>            # read title + props + body  (plain text)
  get-ticket-comments.sh  <ref> [--deep]   # read comments
  upsert-ticket-details.sh <ref> [--title --status --priority --effort --description --body|--body-file] [--dry-run]
  add-ticket-comment.sh   <ref> "text"     # add a comment (chunks long text)
```

`<ref>` = a full key (`FM-9`/`APP-123`), a bare number, a page id, a URL, or the literal
**`new`** to create. Provider + auth + the project/db come from `scripts/tracker/.env` —
you don't pass them. See `scripts/tracker/README.md` and `docs/agents/issue-tracker.md`
for this org's ticket-id format, status names, and any read-only fields.

> **How `upsert` writes the spec:** `--description` sets the one-line **summary**
> (the description property / Jira short field); `--body` / `--body-file` writes the
> **full clarified spec into the ticket BODY** — Notion page blocks, Jira issue
> description — exactly like a feature ticket, NOT a comment. Pass the rendered
> template Markdown to `--body` (or `--body-file -` to pipe it); it supports headings,
> bullet/numbered/to-do lists, quotes, dividers and fenced code blocks. **Do NOT put
> the spec in a comment** — `add-ticket-comment.sh` is only for the source-ticket
> cross-link note. Create with the ref **`new`** + `--title` (the key is auto-assigned
> — read it from the `Created <KEY> — …` stdout); a `--body` written on create goes in
> with the new ticket. Dedup is the caller's responsibility and is now a **required
> step** — `find-tickets.sh` is the search (see Flow step 3): never file a second
> ticket for a finding the board already tracks. Always `--dry-run` a write first when
> unsure.

## Modes (detect from how you were called)

- **A — File an Improvement from a gate finding** (autonomous; the dev-cycle
  guardian/perf gates call this). You already have the facts — **do NOT ask questions**.
  Default the type to a hardening/polish classification unless it's a clear bug or a new
  feature. **Only MAJOR, nice-to-have findings reach this skill** — minor, mechanical
  fixes are folded into the originating PR by the gates, not filed. So if the finding
  handed to you is clearly trivial (a few-line, local, mechanical change with no design /
  contract / QA scope), don't file it — return `skipped: minor — fold into source PR`
  instead of creating a ticket. Otherwise go straight to compose.
- **B — Clarify a request** (interactive; product-owner / user). After Classify (step 2) and
  Dedup (step 3) find no existing ticket, batch focused `AskUserQuestion`s (skip anything
  already known; use a shallow code skim for sharper questions) → summarize with
  `templates.md`. Don't invent — mark gaps `Open question:`.

## Flow

1. **Gather source — clarifying an existing ticket FOLDS IN, never resets.** Mode A: use
   the finding passed in (title, scope/`file:line`, severity, evidence, originating
   `<KEY>`). Mode B: use the request text, or read an existing ticket with
   `get-ticket-details.sh <KEY>` (+ `get-ticket-comments.sh` for prior context). Capture
   every bit of existing content — repro steps, acceptance criteria, edge cases, links —
   verbatim; the clarified spec **carries it forward and may sharpen it, but drops
   nothing**. **Attachments/images:** when the read output ends in a `⚠ N embedded
   image/attachment(s)` line, the description holds editor-pasted images. The adapter
   carries those media across automatically on a `--body` rewrite (they re-appear under an
   *"Attachments (carried over)"* divider), so you never manually re-embed them — but keep
   any surrounding prose that references them (`"see screenshot"`, callouts) so the text
   still makes sense next to the picture.
2. **Classify.** Type (bug / feature / polish), Priority (map a finding's severity),
   Effort (hardening tweaks are usually small) — use the org's real values from
   `issue-tracker.md` / `workspace.config.yaml`. Classify **before** dedup below — a
   duplicate match still needs a fresh Priority to sync onto the existing ticket.
3. **Dedup — search the board FIRST (REQUIRED; do not skip).** Before composing
   anything, confirm the board isn't already tracking this finding. Search by
   **distinctive keyword**, not by type — improvement tickets are often filed with no
   type set, so `--type` would miss them:
   ```sh
   "$CLAUDE_PROJECT_DIR"/scripts/tracker/find-tickets.sh --query "<distinctive token>" --open
   ```
   Pick 1–2 distinctive tokens from the finding — a symbol / file / widget / metric name.
   Run a couple of searches (and a broader noun if the first returns nothing), then skim
   the `<KEY> | Status | type | title :: description` lines. A hit is a **duplicate** only
   when it targets the **same scope (file/symbol/flow) AND the same root cause** — not
   merely the same screen or area. **If a duplicate exists, STOP — do not create a second
   ticket**, but first sync the just-computed Priority onto it (always overwrite to the
   latest classification, even if that lowers it — the existing ticket's Priority may be
   stale):
   ```sh
   "$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <KEY-existing> --priority <P>
   ```
   Then return that existing `<KEY>` as the result (with `duplicate: true`), and if it
   came from a *different* source ticket leave a one-line recurrence note:
   `add-ticket-comment.sh <KEY-existing> "Re-observed via <source KEY> (<scope>) — same finding, not re-filed."`
   Only when nothing on the board covers it do you continue. When overlap is
   partial/ambiguous, prefer linking to the existing ticket (note the overlap in the new
   ticket's **Source** block) over filing a near-duplicate.
4. **(Mode B only) Clarify — when it isn't clear, ASK; never invent.** Shallow code skim
   — **codegraph FIRST** (`codegraph explore`/`codegraph search` to find the area the
   request touches), with `Grep`/`Glob`/`Read` slices only as a last resort — →
   `AskUserQuestion` (≤4 related per call; skip anything the request, existing ticket, or
   step-2 classification already answers). Any gap that would change scope, behaviour, or
   an acceptance criterion is a **must-ask** — batch it into an `AskUserQuestion`, don't
   guess a default. Only mark a gap `Open question:` in the spec when it genuinely can't be
   answered now (out of the user's hands, needs another role); a reachable answer left
   unasked is a bug. **Completion criterion:** no material ambiguity survives unasked, and
   nothing in the spec is fabricated. Business-requirement first; no file paths / function
   names / schemas in the ticket — leave design to the implementer.
5. **Compose the spec.** Read the companion **`templates.md`** and render the matching
   template into Markdown: **Context/Problem**, **Proposed change**, **Acceptance
   criteria** (verifiable checklist), **Source** (originating `<KEY>` + `file:line`/scope
   + evidence verbatim), plus a `Triage: ready-for-agent` line. (Mode B: an
   **Assumptions** block for anything inferred.) When refining an existing ticket, the
   template is a **skeleton, not a reset** — fold the step-1 content into its matching
   fields per `templates.md` (nothing dropped); the rewrite then goes through `--body`,
   which preserves the ticket's images.
6. **Create the ticket with its spec in the body** (only if step 3 found no duplicate).
   One call — `--description` is the one-line summary, `--body` is the full rendered spec,
   `--issuetype` carries the step-2 Type classification onto the actual field (mapped to the
   org's real issue-type values, e.g. Bug/Story/Task — see `issue-tracker.md`):
   ```sh
   "$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
     --title "<clear, imperative title>" --issuetype "<Type>" --status "<not-started status>" \
     --priority <P> --effort <E> --description "<one-line summary>" \
     --body "<rendered template Markdown>"
   ```
   Read the new `<KEY>` from the `Created <KEY> — …` line. The spec lands in the ticket
   **body** — like a feature ticket, **never** a comment. (`--dry-run` first if unsure;
   for a long/multiline spec, `--body-file -` lets you pipe the Markdown in.)
7. **Cross-link.** If there's a source ticket:
   `add-ticket-comment.sh <KEY-source> "Filed improvement <KEY-new>: <title>"`.
   (This is the *only* use of `add-ticket-comment.sh` here — the spec is the body, not a
   comment.)

## Output

Return a compact summary the caller drops into `improvements_filed`:

```
ticket:    <KEY>             # the created ticket, OR the existing one a duplicate matched
duplicate: true | false      # true → matched an existing ticket; nothing new was filed
ticket_url:<url>             # from get-ticket-details.sh <KEY>
type:      bug | feature | polish
priority:  High | Medium | Low
title:     <title>
```

This skill **only files** the ticket — it does not start work on it. Improvement tickets
are non-blocking by design: filing one must never hold up the current ticket's merge. And
it never files a **duplicate**: if the board already tracks the finding (step 3), it
syncs Priority onto it and returns that ticket with `duplicate: true` instead of creating one.
