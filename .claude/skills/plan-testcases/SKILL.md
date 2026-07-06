---
name: plan-testcases
description: Read a ticket and author a user-perspective manual/E2E test plan — 3–6 BDD (Given/When/Then) cases plus any required regression checks — written to agent_logs/ by filling the shared `test-plan-template.md`. Use when designing test cases for a <KEY> ticket, or as the test-design step of QA. Plan only; never runs the app.
argument-hint: "[ticket]"
arguments: [ticket]
---

# Plan test cases

Turn a ticket into a test plan a real end user could follow. **Plan only — never run the app.** The output is a Markdown file in `agent_logs/`, produced by filling the shared `test-plan-template.md`.

## 1. Read the ticket, then the Figma (if it exists)

**a. Read the ticket — the single source of truth.**

- Resolve it: `$ticket` (a key, e.g. `FM-9` / `APP-123`) given → use it. Already in context (e.g. an agent passed the ticket) → reuse it, don't re-fetch. Neither → ask the user for the key.
- Read the ticket with the tracker adapter (run from the workspace root — they print plain text to stdout and accept a full key, a bare number, a page id, or a tracker URL):
  - `scripts/tracker/get-ticket-details.sh <KEY>` — title, properties (Status, Priority, …), and the body / **acceptance criteria**.
  - `scripts/tracker/get-ticket-comments.sh <KEY>` — the ticket's comments (where the regression request lives). Add `--deep` to also pull inline/block-anchored comments (Notion) if you suspect one's hiding there.
  - They need `scripts/tracker/.env` configured for the active `TRACKER_PROVIDER`, plus `curl` + `jq`. If a script errors (missing creds, ticket not found), surface that and stop — don't plan from a half-read ticket.
- Requirements come from the **ticket only** — do not read `docs/` or product-plan files. If the ticket is ambiguous or wrong, that is itself a finding — note it in the plan.
- Find the developer's **"⚠️ Regression request"** comment. It is the **sole** source of regression scope — never invent regressions. If the dev changed behavior but left no request, note that gap; don't guess at it. (Heads-up: by default the reader pulls the main comment stream where the regression request normally lives; `--deep` also pulls inline/block-anchored comments on providers that have them. Some trackers don't expose **resolved** threads, so a request buried in one may not show up.)

**b. Read the Figma design — only if the ticket links one.**

- If (and only if) the ticket links a `figma.com` screen, open it to confirm intent before writing cases — `get_screenshot` for the visual, `get_metadata`/`get_design_context` for the labels, copy, and states. Name buttons/messages in your cases the way the design labels them to the user.
- No Figma link → skip this; plan from the ticket alone. Never block on a missing design.
- If the design and the ticket disagree, that mismatch is a finding — note it in the plan.

## 2. Decide: is there anything to test?

If the ticket introduces **no user-observable behavior worth verifying** — a cosmetic-only tweak, a copy change, or an internal refactor that changes nothing a user does or sees — author **no** cases: write the "nothing to test" output (see step 5) and stop. Do **not** fabricate cases to hit a count. (This is the common outcome for pure-UI cosmetic tickets.)

## 3. Author the BDD cases (3–6)

`Given / When / Then`, **at least 3, never more than 6**. Cover the happy path, the key edge case(s), and error/offline where the ticket implies them — and every acceptance criterion. Each scenario has a distinct, self-contained purpose and a clear title.

**Write in the user's voice, not an engineer's.** Describe what the user *does* and *sees* on screen — name buttons, screens, and messages the way the app labels them to the user ("the **Save** button", "a *Saved* confirmation").

**Forbidden** — never appears in a case: source identifiers, class or page-object names, selectors (`//…`, `$(…)`), file paths, API endpoints, database/field names, or any technical jargon. If you can't name something without code, name it the way the user sees it.

## 4. Regression checks (only if requested)

Pull regression scope **only** from the developer's "⚠️ Regression request". For each existing feature listed, add **one concise bullet at the very bottom**: the feature + the expectation that it still works. Keep them a tight conclusion list, not full scenarios.

- No regression request → omit the section.
- Dev clearly touched shared behavior but filed no request → add a single bullet flagging the gap, rather than inventing scope.

## 5. Fill the template and write to agent_logs/

The plan's layout lives in a separate file: **`test-plan-template.md`** (next to this skill). Read it, fill every `{{ … }}` placeholder, and write the result to `agent_logs/<FM>-testcases.md` (create `agent_logs/` if missing). Delete the `<!-- … -->` guidance comments and any leftover placeholder blocks.

- **Title line** — fill the ticket number and the QA engineer's name (you — e.g. `Peter` when run by qa-planner). Keep `· Status → Testing`.
- **Scenarios** — one `### Scenario N — …` block per case (3–6 total); remove the unused `### Scenario` placeholders.
- **Regressions** — keep this block **only** if the dev filed a "⚠️ Regression request" (one bullet per feature). No request → delete the whole `**Regressions**` block.
- **Nothing to test** — keep only the title line and replace the body with a single `**Nothing to test** — <one-line reason>.` (drop the scenarios and regressions).

Finish by reporting the file path back to whoever invoked the skill.
