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

- **Every output-producing agent** (`.claude/agents/*.md`) leads its body — the FIRST section,
  right under the frontmatter, before the role description — with an EXPLICIT IMPERATIVE
  `## Output language` block: as its first action before composing any prose, read
  `workspace.config.local.yaml` (if that personal override exists) else `workspace.config.yaml`
  from disk — never from memory — and state the resolved value + source in one line before the
  rest of its output. The block also states that **a `LANGUAGE_DIRECTIVE` already present in the
  prompt is authoritative — obey it, do NOT re-resolve over it** (a stale self-resolution must
  never override the value the workflow already resolved). This channel covers both direct
  (Agent-tool) and workflow runs. **Measured self-resolve compliance (no directive present, n=5
  per role, dry-run 2026-07-16): ~56% when this block sat at the BOTTOM of the agent file → ~92%
  once moved to the TOP** — placement was the dominant factor (the buried block was crowded out by
  the long role description above it). Still not fully deterministic on its own: a couple of roles
  occasionally skip the Read and mis-resolve to `en`. Treat this as a strong reinforcement, not a
  guarantee, for any role invoked directly (e.g. via `/review`) outside a workflow; the workflow
  path below is the deterministic one.
- **Prose-producing skills** (`.claude/skills/*/SKILL.md`) that compose a user-facing artifact
  themselves ALSO lead their body — right under the title — with the same `## Output language`
  block: ticket bodies & comments (`clarifying-ticket`, `to-prd`, `update-ticket`,
  `decompose-ticket`, `estimate-ticket`, `report-test-results`, `qa-subtasks`, `diagnosing-bugs`),
  PR/MR review comments (`review`, `apply-human-review`), the PR/MR description (`open-pr`), and
  plans / interactive HTML docs (`plan-automate`, `plan-testcases`, `write-interactive-docs`). This
  is the third reinforcement layer, added 2026-07-16 to close a measured gap: the agent-file block
  sits atop the *agent* system prompt, but a skill's instructions load *later* — closest to the
  moment the artifact is actually composed — and crowd the agent-file block out. A `/prd` run
  resolved `th` correctly (CPO/CTO briefs came back Thai) yet the product-owner (Haiku) wrote all
  three ticket bodies (APP-201/202/203) in English, because the ticket-writing skills carried no
  language reminder at the point of composition. The block defers to a `LANGUAGE_DIRECTIVE` already
  in the prompt (authoritative) and otherwise self-resolves from disk, exactly like the agent-file
  block. Built-in commands (`/code-review`, `/security-review`) have no editable `SKILL.md`, so they
  rely on the agent-file block only.
- **`dev-cycle.js` / `prd.js` / `brd.js`** (headless) each run a small dedicated resolver
  sub-agent (`documentor`, label `resolve-language`) as their FIRST step — its only job is to
  Read `workspace.config.local.yaml` else `workspace.config.yaml` and return the resolved value.
  This is deterministic where the per-agent pointer above is not: a single-purpose check is far
  more reliable than asking every busy prose-writing agent to remember its own. The result feeds
  `LANGUAGE_DIRECTIVE`, appended to every prose-producing prompt — in `dev-cycle.js` the build,
  plan, review, PR-fix, open-PR, and summary prompts; in `prd.js` recon, intake, consult,
  ticketing, and summary; in `brd.js` only the summary (the BRD file itself, `docs/brd/<key>.md`,
  is a checked-in repo doc and stays English regardless — see the table in §3). The directive is
  phrased as **authoritative** ("already resolved for this run … do NOT re-check any config file
  or override it") precisely because a measured failure showed an agent self-resolving wrong and
  overriding a correct directive; the agent-file block above defers to it. The committed
  `const LANGUAGE` mirror (regenerated by `scripts/aiworks config` from workspace.config.yaml)
  is kept only as the fallback if the resolver call itself errors. **Measured directive-present
  compliance (n=5 per role, dry-run 2026-07-16): ~93%** — and the authoritative wording + top
  placement above target the residual case (an agent that re-resolves and overrides).
- **`CLAUDE.md`** carries the operative one-liner for the main session (this chat + interactive
  skills that run in the main context).
- **`.claude/hooks/resolve-language.sh`** is wired under BOTH `SessionStart` (full policy
  explanation, once per session) and `UserPromptSubmit` (a compact one-line reminder,
  re-injected on every single turn) in `.claude/settings.json`. The per-turn reinjection exists
  because a single SessionStart injection was found (2026-07-16) to get crowded out of attention
  over a long, tool-heavy session — the model can quietly drift back to English even with `th`
  resolved. This brings the interactive CLI session to parity with the per-prompt
  `LANGUAGE_DIRECTIVE` that `dev-cycle.js`/`prd.js` already give headless workflow agents on
  every prompt. Because `.claude/settings.json` and the hook script are both committed, this
  reinforcement applies to every teammate's session automatically — it does not depend on any
  one person's Claude Code memory, which is local to that person and never reaches a teammate.

Default `en` ⇒ every directive above is a no-op and behavior is unchanged.
