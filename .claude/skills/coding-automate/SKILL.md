---
name: coding-automate
description: Implement an approved automation plan in THIS project's Page Object Model and verify it. Reads agent_logs/<FM>-automation-plan.md (the plan to follow) with agent_logs/<FM>-testcases.md as the reference for expected behaviour/assertions, writes/extends Page Objects (pages/) and specs (tests/) strictly POM, wires the runner, then verifies with `npm test`. On a red run, investigate with `npm run why`, fix automation issues and re-run; log genuine app bugs to agent_logs/<FM>-bugs.md. This is the implement+execute step after plan-automate — it writes test code and runs the suite.
argument-hint: "[FM-ticket]"
arguments: [ticket]
---

# Coding — automate the plan

Turn the approved automation implementation plan into **working test code** the way **this** project does automation, then **prove it with `npm test`**. Unlike the planning skills, this one **writes Page Objects/specs and runs the suite.** Stay surgical — implement exactly what the plan calls for, no speculative scope.

## 1. Resolve the ticket and read the two inputs

- Resolve the ticket: `$ticket` (an `FM-<n>` key) given → use it; already in context → reuse it; neither → ask for the `FM-<n>` key.
- **Implementation plan — what you build:** read **`agent_logs/<FM>-automation-plan.md`** (the `plan-automate` output). It is the contract: which Page Objects/specs to add or reuse, selectors to confirm, runner wiring, and which scenarios are Automatable. **Missing? Stop** and tell the user to run `/plan-automate <FM>` first — don't improvise a plan.
- **Test plan — your reference for *expected behaviour*:** read **`agent_logs/<FM>-testcases.md`** (the `plan-testcases` output). The BDD `Given/When/Then` are the source of each spec's flow and **assertions** — what the app must do. If it says **"Nothing to test"**, there's nothing to automate — say so and stop.
- Build only what the plan marks **Automatable**. Skip **Manual-only**; for **Partial**, automate the automatable part and note the gap in your final report.

## 2. Survey the code so what you write matches the project

**Codegraph FIRST.** Find the existing Page Objects/specs to reuse and the idiom to copy by querying the repo's codegraph index — `codegraph explore` ("where are the Page Objects / how does a spec wire the runner"), `codegraph search` (a named Page Object/method), `codegraph callers` (who already uses a Page Object). It is the pre-built index for this repo, so use it instead of globbing+reading; reserve `Grep`/`Glob`/`Read` as a last resort to confirm a detail it didn't cover. The artifacts to look for:

- `pages/*.js` — Page Objects to **reuse**, and the idiom to copy (`pages/WelcomePage.js`): a `class` with `constructor(driver)`, selector **getters** returning `this.driver.$('~accessibility-id')`, a bounded-wait `isLoaded()`, and intent-named action methods.
- `config/capabilities.js` — platform caps + the app-under-test id. That id is declared in the workspace `workspace.config.yaml` (the mobile app repo's `app_id` under `products[].repos[]`); `config/capabilities.js` must match it — don't hardcode a different one. The cross-platform accessibility-id (`~`) is the default strategy — branch android/ios only when labels actually differ.
- `test.js` + `scripts/run-tests.js` — how a spec runs today: `run-tests.js` runs the **single hardcoded `test.js`** per platform and there is **no `tests/` discovery yet**, so making `npm test` actually execute your new spec is part of the job (§3, step 4).

## 3. Implement — strictly POM

Follow `CLAUDE.md`'s POM rules without exception. Hold to the workspace **coding style** too — **storytelling** code (no body comments), files ≤500 lines, and the **flow → side-effect → pure** split, which maps straight onto POM: a spec is **flow** (the scenario story), a Page Object action method is **side-effect** (it drives the driver), and any non-trivial logic (data builders, computed expectations) goes in a **pure** helper. Rules + example: the shared `../coding-style.md` beside this skill (read before your first edit).

1. **Screens → Page Objects.** Reuse an existing `pages/*.js` or add `pages/<Screen>Page.js`, named after the screen the user sees. Selectors live **only** here, as getters. No assertions, no test logic in a Page Object.
2. **Interactions → action methods** on the Page Object — intent, not mechanics (`tapLetsGo()`, `enterWeight(kg)`), returning elements/values or another Page Object. Handle android/ios differences **inside** the Page Object so specs stay platform-agnostic.
3. **Specs → `tests/<name>.spec.js`** holding the flow + assertions only. A spec imports Page Objects and calls their methods — it **never** writes a raw selector (`driver.$('//…')`) or a bare `click()`. Each BDD scenario from the test plan becomes a clear step-by-step flow whose `Then` is the assertion.
4. **Wire the runner so `npm test` runs the new spec.** Per the plan's wiring item: have the runner/entry discover or import `tests/*.spec.js` (mirror `test.js`'s session setup from `config/capabilities.js` — `remote(wdOpts(platform))`, `deleteSession()` in `finally`). If unsure how invasive to be, keep the existing `test.js` path working and add discovery alongside it.
5. **Use the plan's selectors; don't invent locators.** Take accessibility-ids from the plan's "Selectors to confirm". An unconfirmed selector is *confirmed by the run* (§4) — if it can't be found, that's an automation fix first, not an app bug.

## 4. Verify with `npm test`

- Run **`npm test`** — it manages the automation server (`pretest`/`posttest`), runs **android and ios** in parallel, prints one summary line per platform, and writes verbose output to `logs/test-<platform>.log`. Just run it; don't start the server yourself.
- All green on both platforms → done. Go to §6.
- **A failure leaves the automation server up on purpose** (npm skips `posttest` on non-zero exit) — that's expected; the next run reuses then cleans it. Don't try to kill it.

## 5. On a red run — investigate with `why`, then triage

Run **`npm run why [platform]`** (omit platform for both). It extracts just the signal from the logs — the error the spec threw (with its `test.js` / `pages/` / `config/` frame) and any element-lookup failures tied to the selector that triggered them — so you don't re-read the whole log. Then triage every failure into exactly one of:

- **Automation issue** — wrong/unconfirmed selector, a missing `await`, a too-short wait, a flow bug in your spec/Page Object, or a runner-wiring mistake. `why` typically shows a `no such element` lookup on a selector you haven't confirmed, or a thrown error framed in `pages/`/`test.js`. **Fix it in the code and re-run `npm test`.** Loop §4–§5 until the suite is green or only app bugs remain. Never log an automation issue as a bug.
- **App bug** — the automation is correct (selector matches what the app actually exposes, flow follows the test plan) yet the app's **observable behaviour contradicts the test plan's `Then`**: an expected element/screen never appears, a confirmation is missing, the wrong message shows, or it crashes. This is a real finding → **log it (§5a).**

Don't cry "app bug" on the first red. Make the automation correct first — and confirm **ground truth** held: the seed mirrored a **real** entity (not a stub) and every step was a **reachable** transition ([`../ground-truth-first.md`](../ground-truth-first.md)). A stub seed or an impossible flow fails for a reason that isn't the feature. Only a failure that reproduces against correct automation *and* faithful ground truth, where the app contradicts the expected behaviour, is a bug — confirm it with the developer before logging.

### 5a. Log app bugs into agent_logs/

For each reproducible **app** bug, append an entry to **`agent_logs/<FM>-bugs.md`** (create it from `bug-log-template.md` next to this skill if absent; create `agent_logs/` if missing). Fill scenario, platform(s), steps (the user actions / page-object calls), expected (from the test plan) vs actual, and evidence (the `npm run why` line — error + frame — and the `logs/test-<platform>.log` path). Be specific and reproducible — a vague bug wastes the developer's loop. Keep the spec that exposes it in place so the bug stays reproducible.

## 6. Report back

Report concisely: pass/fail per platform from the last `npm test`, the Page Objects/specs added or changed and the runner wiring touched, the path to `agent_logs/<FM>-bugs.md` if any bugs were logged (with a one-line list), and any Partial/Manual-only scenarios left unautomated.
