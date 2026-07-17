# Workspace output localization uses an English spine, not full translation

**Status:** Accepted

The workspace serves a Thai-speaking team, so the agents can communicate more naturally in
Thai. We added a top-level `language: en | th` switch (default `en`, unchanged). When it is
`th`, agents do **not** translate everything — they write an **English spine, Thai prose**:
human-readable prose (this CLI chat, ticket/PR descriptions & comments, the `.html` render of a
plan, code-review notes, Slack) is Thai, while an English spine is preserved for three buckets — **Structure**
(titles, headings, labels, enum/status values), **Code** (all code & comments, identifiers,
paths, commands, commit messages, branch names), and **Terms** (technical/transliterated words,
domain jargon, proper nouns). Numerals/dates/IDs stay Arabic.

This is a *language* decision only — it never changes which tools run, which phases fire, or
what the work is; an `en` run and a `th` run produce identical artifacts, only the prose
differs. It also governs how the **agent team** communicates, never the **product's** own UI
copy (that follows the product's design/localization).

The full operating convention — the per-surface table and how it's enforced (per-agent pointer +
`LANGUAGE_DIRECTIVE` in the workflows) — lives in
[`docs/agents/language.md`](../agents/language.md); this ADR records only *why* the model is
shaped this way.

## Refinement (2026-07-17): `.md` is English, `.html` localizes

The original model localized a *working deliverable* by destination — a plan/PRD/summary Markdown
in `agent_logs/` went Thai under `th`, while the same document committed beside code stayed English.
This split the same `.md` file two ways and made the machine-read artifact language-dependent.

Refined rule: **file type wins.** Any `.md` file an agent authors is **English — always**, whether
it is a working deliverable in `agent_logs/` or a checked-in repo doc. Localization (`th`) applies
only to the non-`.md` surfaces: CLI chat, ticket bodies & comments, PR/MR descriptions & review
discussion, Slack, and the **`.html`** interactive render of a plan.

Why: a plan `.md` is a **stable, machine-read hand-off** — the next-phase agent reads it via the
`data-plan-md` pointer, and downstream tooling greps fixed English headings/paths; keeping it
English removes a locale variable from the pipeline. The **`.html`** render is the human
presentation surface, so that is where Thai prose belongs. This also collapses the awkward
"same document, two languages by destination" case into one predictable invariant (`.md` ⇒ English)
that is trivial to check and hard to get wrong.

## Rejected alternatives

- **Full translation (everything Thai, including code/comments/commits).** Rejected: code and
  code-adjacent text (commit messages, branch names, checked-in repo docs) must stay English so
  the code remains readable to future and non-Thai developers, and transliterating technical
  terms into Thai makes a mixed sentence *harder* to read, not easier.
- **No localization (English only).** Rejected as the sole option — it is exactly the `en`
  default, kept as the default, but forcing it would deny the team its natural working language.
