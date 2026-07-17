---
name: plan-automate
description: Read a test plan (agent_logs/<KEY>-testcases.md) and plan how to automate it in THIS project's Page Object Model — which Page Objects and specs to add or reuse, the selectors to confirm, the runner/wiring changes needed, and which scenarios are automatable vs manual-only. Plan only; writes the plan to agent_logs/ and never writes test code or runs the app.
argument-hint: "[ticket]"
arguments: [ticket]
---

# Plan automation

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write the prose you author in **Thai prose with an English spine** — but note the `.md` deliverable itself (the plan/testcases Markdown in `agent_logs/`) stays **English regardless**; only an `.html` render (via `/write-interactive-docs`) is localized to Thai — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code, checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files), **and ANY file you author with a `.md` extension** (plans, testcases, PRD/summary Markdown in `agent_logs/`) are **never** Thai — the `th` prose rule applies to chat, tickets, PR/MR discussion, Slack, and `.html` docs only. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

Turn an approved test plan into an implementation plan for automating it the way **this** project does automation. **Plan only — never write Page Objects/specs and never run the app or `npm test`.** The output is a Markdown file in `agent_logs/`, produced by filling the shared `automation-plan-template.md`.

## 1. Read the test plan — the input

- Resolve the ticket: `$ticket` (a key, e.g. `FM-9`/`APP-123`) given → use it; already in context → reuse it; neither → ask for the key.
- Read **`agent_logs/<KEY>-testcases.md`** (the `plan-testcases` output) — it is the source of scenarios. If it's missing, stop and tell the user to run `/plan-testcases <KEY>` first; **don't invent scenarios.**
- If the test plan says **"Nothing to test"**, there's nothing to automate — write that one line to the plan file and stop.
- Need ticket context (preconditions, data, app area)? Read it via `scripts/tracker/get-ticket-details.sh <KEY>` — but the scenarios come from the test plan, not re-derived from the ticket.

## 2. Survey the project — so the plan fits real conventions

Map what already exists so the plan reflects it, not a generic template — **codegraph FIRST.** Query the repo's codegraph index (`codegraph explore` for "where are the Page Objects / how is the runner wired", `codegraph search` for a named Page Object/method, `codegraph callers` for reuse) instead of a grep+read sweep; it is the pre-built index for this repo. Reserve `Grep`/`Glob`/`Read` for a last-resort detail codegraph didn't surface. The artifacts to map:

- `pages/*.js` — existing Page Objects to **reuse**, and the idiom to follow (see `pages/WelcomePage.js`): a `class` with `constructor(driver)`, selector **getters** returning `this.driver.$('~accessibility-id')`, an `isLoaded()` bounded-wait check, and intent-named action methods. **No assertions, no test logic in a Page Object.**
- `config/capabilities.js` — platform caps + the app-under-test id. That id is declared in the workspace `workspace.config.yaml` (the mobile app repo's `app_id` under `products[].repos[]`); `config/capabilities.js` must match it. Selectors prefer the cross-platform accessibility-id (`~`) — branch android/ios only when the labels actually differ.
- `test.js` + `scripts/run-tests.js` — how a spec is run today. **Note the current reality:** there is no `tests/` directory yet and the runner executes only the hardcoded root `test.js`, so "where the new spec lives and how it gets run" is a real planning item, not a given.

## 3. Map each scenario to POM artifacts

For every BDD scenario in the test plan, work out:

- **Screens → Page Objects.** Reuse an existing `pages/*.js`, or add a new `pages/<Screen>Page.js`. Name it after the screen as the user sees it.
- **Interactions → action methods** on the relevant Page Object (intent, not mechanics — `openHealthStep()`, `enterWeight(kg)`), returning elements/values or another Page Object. Specs must **never** carry a raw selector.
- **Assertions → the spec**, never the Page Object.
- **Don't invent selectors.** List the elements whose accessibility-id / locator must be **confirmed against the app**, with the proposed strategy (`~` first; android/ios fallback only if needed).

## 4. Decide what's automatable

Mark each scenario **Automatable / Partial / Manual-only** with a one-line reason. Be honest about the automation's reach — e.g. forcing offline/save-failure states, exhaustive "no internal wording leaks" content sweeps, OS-level permission dialogs, or visual/layout checks are often Partial or Manual-only. A plan that over-promises wastes the implementer's time.

## 5. Plan the spec + runner wiring and prerequisites

- Where the spec(s) live (`tests/` per `CLAUDE.md`) and **how they get executed** — call out the change needed since `run-tests.js` runs only `test.js` today (e.g. discover `tests/*.spec.js`, or have an entry import them). Describe it as a plan item; don't make the change here.
- App-under-test prerequisites: build/install the app, any **test-data reset** the plan needs (e.g. a clean reinstall precondition), and that platform caps already exist in `config/capabilities.js`.
- **Ground truth first** — any prerequisite/seed data the plan calls for must mirror a **real** entity's full row-set (check the schema + `docs/adr/` + `CONTEXT*.md`), not a minimal stub: a stub missing a row the app's own queries require makes the test fail for a non-feature reason. See [`../ground-truth-first.md`](../ground-truth-first.md).

## 6. Fill the template and write to agent_logs/

Read **`automation-plan-template.md`** (next to this skill), fill every `{{ … }}` placeholder, delete the `<!-- … -->` guidance comments and unused placeholder rows, and write the result to `agent_logs/<FM>-automation-plan.md` (create `agent_logs/` if missing). Finish by reporting the file path.
