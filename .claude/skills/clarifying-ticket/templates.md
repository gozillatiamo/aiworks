# Clarified ticket templates

Pick the template matching the ticket type. Output the filled template as a code block so the user can copy easily. Use `Open question: <text>` for any field the user couldn't answer.

**A description is a short page (docs/adr/0044).** The part a reader sees first — everything above `## Details` — is the **core**: what is wrong or what we want, who is affected, how to see it in **5 steps or fewer**, **at most 6** acceptance checks, and links. Plain sentences a stranger reads in one minute. Everything else (edge cases, assumptions, technical pointers, background, the long runbook, the CTO's notes, a bug's investigation) goes **under `## Details`** — a reader opens it when they need it. The tracker adapter caps the description at `tracker.max_description_chars` (default 5000) and, when a body is over it, keeps the core and moves the full body to ONE `<KEY>-details.md` attachment; writing the core first is what keeps that cut clean. Say the simple thing; do not pad a field to fill it.

**Images the user supplied (screenshots, mockups, related pictures).** Attach each one (`scripts/tracker/add-ticket-attachment.sh <KEY> <file> --embed-id`) and embed it **in the core** under a short `## Evidence` line with a one-line caption — never only under `## Details`, because an `![](attachment:…)` token does not render inside a `.md` attachment. Images do not count toward the cap. Keep the number small (the ones that show the problem or the wanted result) and caption every one.

**Language of the FILLED-IN prose (read before composing).** If your OUTPUT LANGUAGE is `th` (per the `LANGUAGE_DIRECTIVE` in your prompt, else resolved from `workspace.config.local.yaml`/`workspace.config.yaml`), then EVERY value you write into a `<placeholder>` — role, capability, value, scope & out-of-scope items, each acceptance criterion, edge cases, pointers, repro steps, expected/actual — is **Thai prose**. Do NOT copy the English placeholder wording; the placeholders below only mark the shape. Keep English ONLY for: the field **labels** (`Title:`, `User story:`, `Scope:`, `Acceptance criteria:` …), the `Title:` value itself, the `- [ ]` checkbox syntax, and all code / identifiers / API names / domain & proper-noun terms (Arabic numerals always). The English `As a … I want … so that …` skeleton becomes its Thai form `ในฐานะ <role> ฉันต้องการ <capability> เพื่อ <value>`. A ticket whose description comes back in English under `th` is a defect, not a stylistic choice. Default `en` ⇒ write everything in English exactly as the skeleton shows.

**Stay at the business-requirement level.** Use the optional *Technical pointers (rough)* section for general area/integration hints from the code exploration — area names, service names, "needs a new endpoint" — never concrete paths, function names, or step-by-step implementation. If you have nothing rough to add, omit the section entirely.

**The template is a skeleton, not a reset.** Fold existing ticket content into the matching fields — original acceptance criteria, repro steps, edge cases, links, embedded images, and attachment references all carry through. If the source had material that doesn't fit any field, add an `Existing details:` section under `## Details` rather than dropping it. Preserve Jira image markup (`!filename.png!`) and Notion block references verbatim so attachments stay rendered.

## Task / Story / Improvement

```
Title: <concise title>

User story:
As a <role>, I want <capability>, so that <value>.
# ^ under language=th write the Thai form instead: ในฐานะ <role> ฉันต้องการ <capability> เพื่อ <value>
# under language=th EVERY item below (Scope, Out of scope, Acceptance criteria, Edge cases,
# Technical pointers) is also written in Thai — the labels + `- [ ]` + code/terms stay English.

Who is affected: <one line — which users / roles / sites>

How to see it (5 steps or fewer):
1. <where to look today, and what is missing or wrong>

Acceptance criteria (at most 6):
- [ ] <criterion>

## Evidence (only when the user supplied images — omit otherwise)
![<file>](attachment:<id>)
<one-line caption>

Links:
- <BRD / design / related ticket>

## Details

Scope:
- <in-scope item>

Out of scope:
- <out-of-scope item>

Diagram (optional, via /diagram-ticket — omit this section entirely if none was generated):
<reference line + live-editor link>

Edge cases:
- <case> → <expected behavior>

Technical pointers (rough, optional):
- <area/service/integration hint — high level only>
```

## Bug

Write **Reproduce steps** as a **runbook a stranger can follow blind** — never a past-tense
narration of what happened. Each numbered step is ONE concrete action the reader *performs*:
the exact command, the click path, or the field + value, phrased as an imperative (`Run …`,
`Open …`, `Click …`, `Enter …`) and kept to one short line. Lead with a `Precondition:` line
that states the clean starting state (env/URL, logged-in-as which role, seeded data) so the
reader can set it up themselves; the last step is the observation where the bug surfaces. Test:
a teammate who has never seen the bug can reproduce it from these lines alone. The core keeps
the short runbook (5 steps or fewer); a longer one, the investigation and the fix guideline go
under `## Details`.

```
Title: <concise title>

What is wrong: <one or two plain sentences>
Who is affected: <one line — which users / roles / sites>

Reproduce steps (5 or fewer):
Precondition: <clean starting state — env/URL, logged in as which role, data seeded before step 1>
1. <action — the exact command / click path / field+value, imperative, one short line>
2. <action>
3. <observe — the screen or output where the bug shows>

Expected: <what should happen at the last step>
Actual: <what actually happens — the bug>

Acceptance criteria (at most 6):
- [ ] <criterion>

## Evidence (only when the user supplied images — omit otherwise)
![<file>](attachment:<id>)
<one-line caption>

Links:
- <trace / related ticket>

## Details

Assumptions:
- <assumption>

Edge cases / related scenarios:
- <case>

Technical pointers (rough, optional):
- <suspected area/component — high level only, not a fix prescription>
```

Example — every step reads as an action you can DO, not a description of what broke:

```
Reproduce steps:
Precondition: staging, logged in as an Admin with one pending payout in the queue.
1. Open Payouts → Pending.
2. Select the pending row and click Approve.
3. Reload the page, re-open Payouts → Pending.

Expected: the payout has left Pending and shows under Approved.
Actual: the payout still shows as Pending (duplicated after reload).
```
