# Clarified ticket templates

Pick the template matching the ticket type. Output the filled template as a code block so the user can copy easily. Use `Open question: <text>` for any field the user couldn't answer.

**Language of the FILLED-IN prose (read before composing).** If your OUTPUT LANGUAGE is `th` (per the `LANGUAGE_DIRECTIVE` in your prompt, else resolved from `workspace.config.local.yaml`/`workspace.config.yaml`), then EVERY value you write into a `<placeholder>` — role, capability, value, scope & out-of-scope items, each acceptance criterion, edge cases, pointers, repro steps, expected/actual — is **Thai prose**. Do NOT copy the English placeholder wording; the placeholders below only mark the shape. Keep English ONLY for: the field **labels** (`Title:`, `User story:`, `Scope:`, `Acceptance criteria:` …), the `Title:` value itself, the `- [ ]` checkbox syntax, and all code / identifiers / API names / domain & proper-noun terms (Arabic numerals always). The English `As a … I want … so that …` skeleton becomes its Thai form `ในฐานะ <role> ฉันต้องการ <capability> เพื่อ <value>`. A ticket whose description comes back in English under `th` is a defect, not a stylistic choice. Default `en` ⇒ write everything in English exactly as the skeleton shows.

**Stay at the business-requirement level.** Use the optional *Technical pointers (rough)* section for general area/integration hints from the code exploration — area names, service names, "needs a new endpoint" — never concrete paths, function names, or step-by-step implementation. If you have nothing rough to add, omit the section entirely.

**The template is a skeleton, not a reset.** Fold existing ticket content into the matching fields — original acceptance criteria, repro steps, edge cases, links, embedded images, and attachment references all carry through. If the source had material that doesn't fit any field, add an `Existing details:` section at the bottom rather than dropping it. Preserve Jira image markup (`!filename.png!`) and Notion block references verbatim so attachments stay rendered.

## Task / Story / Improvement

```
Title: <concise title>

User story:
As a <role>, I want <capability>, so that <value>.
# ^ under language=th write the Thai form instead: ในฐานะ <role> ฉันต้องการ <capability> เพื่อ <value>
# under language=th EVERY item below (Scope, Out of scope, Acceptance criteria, Edge cases,
# Technical pointers) is also written in Thai — the labels + `- [ ]` + code/terms stay English.

Scope:
- <in-scope item>

Out of scope:
- <out-of-scope item>

Acceptance criteria:
- [ ] <criterion>

Edge cases:
- <case> → <expected behavior>

Technical pointers (rough, optional):
- <area/service/integration hint — high level only>
```

## Bug

```
Title: <concise title>

Reproduce steps:
1. <step>

Expected: <expected behavior>
Actual: <actual behavior>

Assumptions:
- <assumption>

Acceptance criteria:
- [ ] <criterion>

Edge cases / related scenarios:
- <case>

Technical pointers (rough, optional):
- <suspected area/component — high level only, not a fix prescription>
```
