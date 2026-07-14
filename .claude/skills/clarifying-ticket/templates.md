# Clarified ticket templates

Pick the template matching the ticket type. Output the filled template as a code block so the user can copy easily. Use `Open question: <text>` for any field the user couldn't answer.

**Stay at the business-requirement level.** Use the optional *Technical pointers (rough)* section for general area/integration hints from the code exploration — area names, service names, "needs a new endpoint" — never concrete paths, function names, or step-by-step implementation. If you have nothing rough to add, omit the section entirely.

**The template is a skeleton, not a reset.** Fold existing ticket content into the matching fields — original acceptance criteria, repro steps, edge cases, links all carry through. If the source had material that doesn't fit any field, add an `Existing details:` section at the bottom rather than dropping it. **Embedded images/attachments are carried over by the adapter itself** — a `--body` rewrite re-appends the description's media under an *"Attachments (carried over)"* divider, so don't hand-copy image markup; just keep the surrounding prose that refers to them (`"see screenshot"`, callouts) so the text still reads sensibly beside the picture.

## Task / Story / Improvement

```
Title: <concise title>

User story:
As a <role>, I want <capability>, so that <value>.

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
