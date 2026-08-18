---
name: report-test-results
description: Gather the automation run results for a ticket and report them on the ticket as a concise, human-readable summary WITH the run's own screenshots embedded in the comment. Reads the run summary (`scripts/dev.sh why test`), the run's artifacts (`scripts/dev.sh artifacts`), the logged bugs (agent_logs/<KEY>-bugs.md), and the test plan (agent_logs/<KEY>-testcases.md), then writes a per-TC results table to agent_logs/<KEY>-report.md and posts it with the evidence attached. Reports the same way whether the suite passed or failed. Reports only — does not run the suite or write test code.
argument-hint: "[ticket]"
arguments: [ticket]
---

# Report test results

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write every ticket description, spec, acceptance criterion, and comment you post (the ticket Summary/title itself stays on the English spine) in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code, checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files), **and ANY file you author with a `.md` extension** (plans, testcases, PRD/summary Markdown in `agent_logs/`) are **never** Thai — the `th` prose rule applies to chat, tickets, PR/MR discussion, Slack, and `.html` docs only. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

Turn a finished automation run into a short, readable verdict on the ticket — a results table a non-engineer can read, tied row-by-row to the test plan, **with the run's own screenshots in the comment beside the rows they belong to**. **Report only — never run the suite or write test code.** Build the report from artifacts that already exist (the run happened in `coding-automate`). If the suite passed or failed, report **the same way** — same table, same structure; a failure just fills in the failure rows.

**The repo owns its stack; this skill knows none of it.** Cypress, Newman, k6, Playwright, Appium — it does not matter here. Everything you need comes from the repo's own harness, **`scripts/dev.sh`**, which every repo in this workspace has. Never reach for `npm test` / `npm run why`: in this workspace's Cypress repos `npm test` is a stub that exits 1.

## 1. Resolve the ticket and gather the inputs

- Resolve the ticket: `$ticket` (a key, e.g. `APP-2245`) given → use it; already in context → reuse it; neither → ask for the key.
- **Test plan — the row source:** read **`agent_logs/<KEY>-testcases.md`**. Its `TC<nnn>` scenarios are the rows of the results table and define what each should do (its `Then`). If it says **"Nothing to test"**, there are no results to report — say so and stop. Keep any **Regressions** list for the coverage note.
- **Coverage context:** read **`agent_logs/<KEY>-automation-plan.md`** if present, to know which scenarios were **Automatable / Partial / Manual-only** — so an un-run scenario is reported as *not automated*, never silently dropped or counted as a pass.
- **Bug details:** read **`agent_logs/<KEY>-bugs.md`** if present — the reproducible app bugs `coding-automate` logged. These populate the failure rows.

## 2. Determine the results — `scripts/dev.sh why test`

The freshest verdict lives in the run log, and `why` reads it without a re-run:

- Run **`scripts/dev.sh why test`** from the suite repo. It prints the run's `SUMMARY:` line(s) and exit code, then the failure detail.
- **No log** (`no test run yet` / `no logs for 'test'`) → there are no results to report. Stop and tell the user to run `/coding-automate <KEY>` first — **don't fabricate a result.**
- The `SUMMARY:` lines are the harness's own account of what ran, and their shape **is** the report's shape. One tool that ran → one result column. Several (`cypress … newman …`) → one column each. Be faithful to what the summary actually says: if the run is one combined flow rather than per-test results, report at that granularity and note it rather than inventing per-scenario detail.
- Map each test-plan `TC<nnn>` to its outcome: ✅ pass, ❌ fail, or — not automated (Manual-only/Partial from the plan).
- If a repo's `why` output is still long, put it in a file and pull the rows you report
  (`scripts/dev.sh why test > /tmp/why.log 2>&1` then `grep -n -E 'SUMMARY|✗|failed' /tmp/why.log`).
  The report needs per-TC outcomes, not the transcript.

## 3. Collect the evidence — `scripts/dev.sh artifacts`

Run **`scripts/dev.sh artifacts`**. Each row is `<TC-id>\t<kind>\t<path>`, and only files newer than the run are listed, so nothing left over from an earlier ticket can be reported as this run's evidence.

- **`<TC-id>`** joins the artifact to a table row. A row whose id is `-` belongs to no single scenario (the run video, the whole-suite report) — reference it under Coverage, not in a row.
- **`<kind>`** is `fail-screenshot`, `screenshot`, `video`, or `report` (a load suite adds `data`).
- **No rows on a green run** means the specs never captured anything. Say so plainly in the report — "no screenshots captured" — and do not present the run as evidenced. Do **not** go fix the specs; that is `coding-automate`'s job.
- An `.html` report can be turned into a picture worth attaching:
  ```sh
  scripts/pdf/render.sh <the report.html> agent_logs/<KEY>-artifacts/<KEY>-report.png --png
  ```

## 4. Build the human-readable report

Read **`report-template.md`** (next to this skill), fill every `{{ … }}` placeholder, delete the `<!-- … -->` guidance comments and unused rows/blocks, and write the result to **`agent_logs/<KEY>-report.md`** (create `agent_logs/` if missing).

- **Title line** — ticket, overall verdict (`PASS`/`FAIL`), and the harness's own per-tool marks (`cypress ✓ · newman ✗`).
- **One-line summary** — e.g. *"5 of 6 planned scenarios automated; all pass."*
- **Results table** — one row per test-plan `TC<nnn>`: `TC · Scenario · Result · Evidence · Notes`. Keep cells terse.
- **Failures** — **only if any ❌.** One short block per failing `TC`: expected (the plan's `Then`) vs actual, the `why` signal, and the failure screenshot. No raw logs.
- **Coverage** — automated count vs total planned, which scenarios were not automated (with a one-line reason), the regression checks' status if the plan listed any, and the run-wide artifacts (video, report).

## 5. Post it to the ticket — with the evidence in the comment

Attaching and embedding is **`/update-ticket`'s** job — read its §4 for the exact moves (rename → upload with `--embed-id` → `![alt](attachment:<id>)` alone on a line, the id used **whole** including the `@<W>x<H>` size the uploader prints, or the screenshot renders as a 250×200 stamp) rather than improvising them here. What this skill decides is **which** files go up and **how they lay out**:

- **A failing `TC`** → its `fail-screenshot`, **alone on its own line** inside that TC's Failures block, so it renders wide (~446px). A reviewer has to actually look at this one.
- **Passing `TC`s** → their `screenshot`s, **all on ONE line** under the Results table, so they render as a thumbnail strip. This is proof-of-record, not something anyone reads one by one.
- **The rendered run report** (§3) → one line under Coverage.
- **Video** → attach only when a failure is a sequence a still cannot show. It is large and rarely opened.

Rename every file before upload — `<KEY>-TC001-fail.png`, `<KEY>-report.png` — into `agent_logs/<KEY>-artifacts/`, suffixing the round (`-r2`) on a re-run. Then post the finished Markdown verbatim via stdin:

```sh
scripts/tracker/add-ticket-comment.sh <KEY> < agent_logs/<KEY>-report.md
```

- Preview with `--dry-run` if unsure of the resolved ticket.
- **Only Jira embeds images.** On another provider the upload dies loud and the comment still posts — the words are the deliverable, the pictures are the proof. Say which you got.
- Moving the ticket's **Status** is **not** this skill's job — that's `/update-ticket`. Mention it if the run warrants it; don't change it here.

## 6. Requirements & report back

- Needs `scripts/tracker/.env` configured for the active `TRACKER_PROVIDER` (plus `curl` + `jq`) — see `scripts/tracker/README.md`. If a tracker script errors (no creds, ticket not found, empty body), **surface the exact error and stop** — don't retry blindly.
- Finish by reporting back: the overall verdict, the path to `agent_logs/<KEY>-report.md`, the posted comment id (or the dry-run preview), and **how many artifacts were attached** — including "none" when the run captured nothing.
