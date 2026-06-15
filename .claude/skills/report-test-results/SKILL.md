---
name: report-test-results
description: Gather the automation run results for a ticket and report them on the ticket as a concise, human-readable summary. Reads the run logs (logs/test-<platform>.log via `npm run why`), the logged bugs (agent_logs/<KEY>-bugs.md), and the test plan (agent_logs/<KEY>-testcases.md), then writes a per-scenario results table tied to the plan to agent_logs/<KEY>-report.md and posts it with scripts/tracker/add-ticket-comment.sh. Reports the same way whether the suite passed or failed. Reports only — does not run the suite or write test code.
argument-hint: "[ticket]"
arguments: [ticket]
---

# Report test results

Turn a finished automation run into a short, readable verdict on the ticket — a results table a non-engineer can read, tied scenario-by-scenario to the test plan. **Report only — never run `npm test` or write test code.** Build the report from artifacts that already exist (the run already happened in `coding-automate`), then post it with `add-ticket-comment.sh`. If the suite passed or failed, report **the same way** — same table, same structure; a failure just fills in the failure rows.

## 1. Resolve the ticket and gather the inputs

- Resolve the ticket: `$ticket` (a key, e.g. `FM-9`/`OFB-123`) given → use it; already in context → reuse it; neither → ask for the key.
- **Test plan — the row source / reference:** read **`agent_logs/<FM>-testcases.md`**. Its BDD scenarios are the rows of the results table and define what each scenario *should* do (its `Then`). If it says **"Nothing to test"**, there are no results to report — say so and stop. Keep any **Regressions** list for the coverage note.
- **Coverage context:** read **`agent_logs/<FM>-automation-plan.md`** if present, to know which scenarios were **Automatable / Partial / Manual-only** — so an un-run scenario is reported as *not automated*, not silently dropped or counted as a pass.
- **Bug details:** read **`agent_logs/<FM>-bugs.md`** if present — the reproducible app bugs `coding-automate` logged. These populate the failure rows and the Failures section.

## 2. Determine the results — `npm run why`

The freshest verdict lives in the run logs, and `why` reads them without a device or a re-run:

- Run **`npm run why`** (both platforms; or `npm run why <platform>` for one). It prints, per platform, either `✓ no errors in logs/test-<platform>.log` (**pass**) or `✖ …` with the thrown error + its `test.js`/`pages/`/`config/` frame and any failed selector lookups (**fail**).
- **No logs** (`no log at … (run npm test first)`) → there are no results to report. Stop and tell the user to run `/coding-automate <FM>` (or `npm test`) first — don't fabricate a result.
- Map each test-plan scenario to its outcome per platform: ✅ pass, ❌ fail, or — not automated (Manual-only/Partial from the plan). Be faithful to what the logs actually show — if the run is one combined flow rather than per-scenario specs, report at that granularity and note it rather than inventing per-scenario detail.

## 3. Build the human-readable report

Read **`report-template.md`** (next to this skill), fill every `{{ … }}` placeholder, delete the `<!-- … -->` guidance comments and unused rows/blocks, and write the result to **`agent_logs/<FM>-report.md`** (create `agent_logs/` if missing).

- **Title line** — ticket number, overall verdict (`PASS`/`FAIL`), and a per-platform mark (`Android ✓ · iOS ✗`).
- **One-line summary** — e.g. *"5 of 6 planned scenarios automated; all pass on Android, 1 fails on iOS."*
- **Results table** — one row per test-plan scenario: `# · Scenario · Android · iOS · Notes`. Keep cells terse (✅/❌/—, a few words of note, a bug reference). Concise and skimmable beats exhaustive.
- **Failures** — include this section **only if any ❌**. One short block per failing scenario: expected (the plan's `Then`) vs actual, and the `npm run why` signal (error + `file:frame`, log path). Pull specifics from `agent_logs/<FM>-bugs.md`. Same concise style as the rest — don't paste raw logs.
- **Coverage** — automated count vs total planned, which scenarios were not automated (Manual-only/Partial) with a one-line reason, and the regression checks' status if the plan listed any.

## 4. Post it to the ticket — `add-ticket-comment.sh`

Post the report file **verbatim** via stdin (preserves multi-line Markdown, dodges shell-quoting hazards):

```sh
scripts/tracker/add-ticket-comment.sh <KEY> < agent_logs/<KEY>-report.md
```

- Preview first if unsure of the resolved ticket: append `--dry-run` to print the request body instead of sending.
- **Markdown-literal caveat:** some trackers store comments as plain/rich text, so `#`, `**bold**`, and `|table|` pipes may show up **literally**, not rendered. The content is faithful; only live styling may not be — so keep the layout readable as plain monospace text (the template's table already is).
- Moving the ticket's **Status** (e.g. → `Done` on a clean pass) is **not** this skill's job — that's `/update-ticket`. Mention it if the run warrants it, but don't change status here.

## 5. Requirements & report back

- Needs `scripts/tracker/.env` configured for the active `TRACKER_PROVIDER` (plus `curl` + `jq`) — see `scripts/tracker/README.md`. If `add-ticket-comment.sh` errors (no creds, ticket not found, empty body), **surface the exact error and stop** — don't retry blindly.
- Finish by reporting back: the overall verdict and per-platform result, the path to `agent_logs/<KEY>-report.md`, and the posted comment id (or the dry-run preview).
