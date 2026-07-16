# Language (output-localization convention)

The single reference for **what language every agent writes in**. Governed by the
top-level `language:` field in `workspace.config.yaml` (see `workspace.config.example.yaml`).
`scripts/aiworks config`/`sync` mirrors it into the headless-workflow CONFIG blocks
(`dev-cycle.js`, `prd.js`) as `const LANGUAGE`, because workflow scripts can't read the
filesystem at runtime.

This file is the operating convention (the *what/how*); the *why* behind the English-spine
model — and the config-mirror and personal-override decisions it leans on — is recorded in
[ADR-0002](../adr/0002-workspace-output-localization.md) (with
[ADR-0001](../adr/0001-headless-workflow-config-mirror.md) and
[ADR-0003](../adr/0003-personal-runtime-config-overrides.md)).

This governs **language only** — never *which* tools run, *which* phases fire, or *what* the
work is. An `en` run and a `th` run take the identical process and produce the identical
artifacts; only the prose differs.

**Out of scope:** this is the language the **agent team communicates in** — not the **product's**
own UI copy or content. A product screen's labels/strings follow the product's own design and
localization (the Figma spec / design system), never this switch. `language: th` does not translate
the product.

## 1. `language` — the workspace-wide output language (default **`en`**)

```yaml
language: en   # en (default) | th
```

- **`en` (default):** everything in English, exactly as today. No behavior change — no
  directive fires anywhere.
- **`th`:** **English spine, Thai prose** (§2).

An existing workspace stays English until it explicitly sets `language: th` — it does not
switch on by itself.

**The resolved value is authoritative, not the user's input language.** Agents must not mirror
whatever language the user happens to type their message in — `language: en` means respond in
English even if the user writes in Thai (or any other language), and `language: th` means English
spine / Thai prose even if the user writes in English. The `SessionStart` hook (§4) injects the
resolved value at the start of every session precisely so this doesn't depend on inferring intent
from the user's own message.

**Personal override.** Set `language` for yourself only — without touching the team default — in a
git-ignored **`workspace.config.local.yaml`** (see `workspace.config.local.example.yaml`). It
overrides `workspace.config.yaml` at RUNTIME (this chat, the agents, interactive skills). The
committed workflow mirror is regenerated from the shared file only, so your pref never lands in
git; a headless workflow still honors it because its agents read `language` at runtime through
their per-agent pointer (§4), not the baked `const LANGUAGE`.

## 2. The rule — English spine, Thai prose

When `language: th`, write human-readable **prose in Thai**, but keep an **English spine**.
Default every string to Thai; keep English for exactly the three spine buckets:

- **Structure** — titles, **every section heading / topic / subject**, field labels, table
  headers, and status/enum values. (A Thai plan reads `## Acceptance Criteria` with the criteria
  themselves in Thai.)
- **Code** — all code and code comments, identifiers, file paths, commands, **git commit
  messages, and branch names**. Code and code-adjacent text are **never** Thai.
- **Terms** — technical terms, transliterated words, product & domain jargon, and proper nouns
  (e.g. *API, webhook, staging, feature flag, rate limit,* and product / brand names). A Thai sentence
  carries these English inline rather than transliterating them — transliteration is what makes
  a mixed sentence hard to read, so it is disallowed.

Numerals, dates, IDs, and currency stay as-is (Arabic numerals / ISO) — never Thai digits.

The test the agent runs on each token: **is it on the English spine? → English; otherwise → Thai.**

## 3. Which surface gets which language

| Surface | `en` | `th` |
|---|---|---|
| CLI chat (agent ↔ you) | English | Thai prose (English spine) |
| Issue-tracker ticket | English | **Summary/title English**; description & comments Thai |
| PR/MR | English | **Title English** (conventional-commit); description & review discussion Thai |
| Code-review / guardian / perf comments | English | Thai prose; the code & identifiers they cite stay English |
| Plans, PRDs, BRDs, summaries **as working deliverables** — `agent_logs/`, ticket bodies, anything shown to you | English | Thai prose (English spine) |
| Slack / chat notifications | English | Thai prose (English spine) |
| **Code & code comments** | English | English — never Thai |
| **Git commit messages & branch names** | English | English — never Thai |
| **Checked-in repo docs committed beside code** — `docs/`, `README`, `docs/adr/` ADRs, `CONTEXT.md`, and PRD/BRD **files committed into a product repo** | English | English — they live beside code for future / non-Thai devs |

The dividing line for structured artifacts: a **file committed beside code** is English; a
**collaboration / working surface** (chat, tickets, Slack, PR discussion, plans shown to you) is
Thai. The *same* document type splits by destination — a PRD written into `agent_logs/` or a ticket
body is Thai prose; a PRD committed into a product repo is English.

## 4. How it's enforced

- **Every output-producing agent** (`.claude/agents/*.md`) carries a one-line pointer to this
  file and reads `language` before writing anything — from `workspace.config.local.yaml` if that
  personal override exists, else `workspace.config.yaml`. Because the headless workflows spawn
  these **same agent types**, this one channel covers both direct (Agent-tool) and workflow runs,
  and is what carries a *personal* `language` override into a headless run.
- **`dev-cycle.js` / `prd.js`** (headless) carry the mirrored `const LANGUAGE` and append a
  compact `LANGUAGE_DIRECTIVE` to their prose-producing prompts — in `dev-cycle.js` the build,
  plan, review, PR-fix, open-PR, and summary prompts; in `prd.js` the ticketing and summary
  prompts — reinforcing the agent-level rule where the highest-value prose is produced. Editing
  `workspace.config.yaml` requires `scripts/aiworks config` to refresh that mirror (the workflow
  can't read the live config at runtime).
- **`CLAUDE.md`** carries the operative one-liner for the main session (this chat + interactive
  skills that run in the main context).

Default `en` ⇒ every directive above is a no-op and behavior is unchanged.
