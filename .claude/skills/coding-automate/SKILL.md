---
name: coding-automate
description: >-
  Implement an approved automation plan in THIS repo's Page Object Model and verify it. Follows
  agent_logs/<KEY>-automation-plan.md against <KEY>-testcases.md, writes Page Objects and specs
  strictly POM - each test titled with its TC id, ending in a screenshot - then verifies with
  `scripts/dev.sh test`. On red, drill with `why test`, fix automation issues and re-run; log
  genuine app bugs to agent_logs/<KEY>-bugs.md. The implement+execute step after plan-automate.
argument-hint: "[FM-ticket]"
arguments: [ticket]
---

# Coding — automate the plan

Turn the approved automation implementation plan into **working test code** the way **this** project does automation, then **prove it by running the suite**. Unlike the planning skills, this one **writes Page Objects/specs and runs the suite.** Stay surgical — implement exactly what the plan calls for, no speculative scope.

**The repo owns its stack; this skill knows none of it.** A test-suite repo here may be Cypress, Newman, k6, Playwright, Appium, or whatever the team adopts next. Read the repo's own `CLAUDE.md` and `.claude/rules/` first, and drive everything through **`scripts/dev.sh`** — the per-repo harness every repo in this workspace has (`test`, `analyze`, `why <name>`, `artifacts`). **Never reach for `npm test`:** in this workspace's Cypress repos it is a stub that exits 1, and each repo's real invocation differs.

## 1. Resolve the ticket and read the two inputs

- Resolve the ticket: `$ticket` (a `<KEY>` like `APP-2245`) given → use it; already in context → reuse it; neither → ask for the key.
- **Implementation plan — what you build:** read **`agent_logs/<KEY>-automation-plan.md`** (the `plan-automate` output). It is the contract: which Page Objects/specs to add or reuse, selectors to confirm, runner wiring, and which scenarios are Automatable. **Missing? Stop** and tell the user to run `/plan-automate <KEY>` first — don't improvise a plan.
- **Test plan — your reference for *expected behaviour*:** read **`agent_logs/<KEY>-testcases.md`** (the `plan-testcases` output). The BDD `Given/When/Then` are the source of each spec's flow and **assertions** — what the app must do, and its `TC<nnn>` ids are the ids your test titles must carry (§3). If it says **"Nothing to test"**, there's nothing to automate — say so and stop.
- Build only what the plan marks **Automatable**. Skip **Manual-only**; for **Partial**, automate the automatable part and note the gap in your final report.

## 2. Survey the code so what you write matches the project

**Codegraph FIRST.** Find the existing Page Objects/specs to reuse and the idiom to copy by querying the repo's codegraph index — `codegraph explore` ("where are the Page Objects / how does a spec wire the runner"), `codegraph query` (a named Page Object/method), `codegraph callers` (who already uses a Page Object). It is the pre-built index for this repo, so use it instead of globbing+reading; reserve `Grep`/`Glob`/`Read` as a last resort to confirm a detail it didn't cover. The artifacts to look for:

- **An existing Page Object** — to reuse, and as the idiom to copy exactly (its directory, base class, how selectors are declared, how a bounded wait is expressed).
- **An existing spec** — how a test is titled, how it authenticates, how it seeds and asserts, and how it captures a screenshot.
- **How the suite runs** — what `scripts/dev.sh test` actually invokes and whether it has sub-modes (`test api`, `test all`). If your new spec would not be picked up, wiring that is part of the job.
- **Which target it points at** and how that is selected. Automated runs default to **local**; staging is an explicit, QA-reserved opt-in. Never hardcode one.

## 3. Implement — strictly POM

Follow `CLAUDE.md`'s POM rules without exception. Hold to the workspace **coding style** too — **storytelling** code (no body comments), files ≤500 lines, and the **flow → side-effect → pure** split, which maps straight onto POM: a spec is **flow** (the scenario story), a Page Object action method is **side-effect** (it drives the driver), and any non-trivial logic (data builders, computed expectations) goes in a **pure** helper. Rules + example: the shared `../coding-style.md` beside this skill (read before your first edit).

1. **Screens → Page Objects.** Reuse an existing one or add a new one named after the screen the user sees, in the repo's own directory and idiom. Selectors live **only** here. No assertions, no test logic in a Page Object.
2. **Interactions → action methods** on the Page Object — intent, not mechanics (`openWithdrawForm()`, `enterAmount(n)`), returning elements/values or another Page Object. Any platform/variant branching lives **inside** the Page Object so specs stay clean.
3. **Specs hold the flow + assertions only.** A spec imports Page Objects and calls their methods — it **never** writes a raw selector or a bare click. Each `TC<nnn>` from the test plan becomes one clear step-by-step flow whose `Then` is the assertion.
4. **The test title MUST open with the plan's `TC<nnn>` id** — `TC001 - Success : Sign in with username + password`. This is not cosmetic: the runner names every screenshot and video after the test title, so the id is what carries through to the artifact filename and lets the results report attach the right evidence to the right row. Drop it and the evidence lands on the ticket attached to nothing.
5. **End every scenario by capturing a screenshot.** Use the capture call the repo's own framework provides (`cy.screenshot()`, `page.screenshot()`, `driver.saveScreenshot()`, …) as the scenario's last step. Runners screenshot automatically **on failure only**, so without this a passing run leaves a green tick and no proof — and "it passed" is exactly the claim a reviewer most wants to see evidence for. Name the capture so the `TC<nnn>` survives into the filename (the default — naming from the test title — already does).
6. **Wire the runner so `scripts/dev.sh test` runs the new spec.** Per the plan's wiring item. Keep the existing path working; add alongside rather than rewriting it.
7. **Use the plan's selectors; don't invent locators.** Take them from the plan's "Selectors to confirm". An unconfirmed selector is *confirmed by the run* (§4) — if it can't be found, that's an automation fix first, not an app bug.

## 4. Verify by running the suite

- Run **`scripts/dev.sh test`** (plus the repo's own sub-mode if the plan calls for one, e.g. `test api` / `test all`). It writes the verbose log and prints a one-line summary; just run it.
- Green → check **`scripts/dev.sh artifacts`** lists a capture for each scenario you automated. A green run with no rows means §3 step 5 didn't take effect — fix that before reporting, or the results report has nothing to attach.
- The harness already writes the verbose log and prints one summary line — keep it that way. For any
  command that does NOT (a raw runner, a container bring-up), redirect it (`> /tmp/run.log 2>&1`)
  and read it with `grep`/`tail`. Never paste a full run log into context.
- Then go to §6.

## 5. On a red run — investigate with `why`, then triage

Run **`scripts/dev.sh why test`**. It extracts just the signal from the run log — the `SUMMARY:`/exit line, then the failure detail — so you don't re-read the whole thing. Then triage every failure into exactly one of:

- **Automation issue** — wrong/unconfirmed selector, a missing wait, a flow bug in your spec/Page Object, or a runner-wiring mistake. **Fix it in the code and re-run `scripts/dev.sh test`.** Loop §4–§5 until the suite is green or only app bugs remain. Never log an automation issue as a bug.
- **App bug** — the automation is correct (selector matches what the app actually exposes, flow follows the test plan) yet the app's **observable behaviour contradicts the test plan's `Then`**: an expected element/screen never appears, a confirmation is missing, the wrong message shows, or it crashes. This is a real finding → **log it (§5a).**

Don't cry "app bug" on the first red. Make the automation correct first — and confirm **ground truth** held: the seed mirrored a **real** entity (not a stub) and every step was a **reachable** transition ([`../ground-truth-first.md`](../ground-truth-first.md)). A stub seed or an impossible flow fails for a reason that isn't the feature. Only a failure that reproduces against correct automation *and* faithful ground truth, where the app contradicts the expected behaviour, is a bug — confirm it with the developer before logging.

### 5a. Log app bugs into agent_logs/

For each reproducible **app** bug, append an entry to **`agent_logs/<KEY>-bugs.md`** (create it from `bug-log-template.md` next to this skill if absent; create `agent_logs/` if missing). Fill the `TC<nnn>` it broke, steps (the user actions / page-object calls), expected (from the test plan) vs actual, and evidence — the `scripts/dev.sh why test` line, the run-log path, and the **failure screenshot's path from `scripts/dev.sh artifacts`** (the row whose id is that `TC<nnn>`), so the report can attach the picture beside the words. Be specific and reproducible — a vague bug wastes the developer's loop. Keep the spec that exposes it in place so the bug stays reproducible.

## 6. Report back

Report concisely: the pass/fail summary from the last `scripts/dev.sh test`, the Page Objects/specs added or changed and the runner wiring touched, the number of rows `scripts/dev.sh artifacts` returns, the path to `agent_logs/<KEY>-bugs.md` if any bugs were logged (with a one-line list), and any Partial/Manual-only scenarios left unautomated.
