---
name: coding-feature
description: Implement a feature or fix in the current repo, test-first, conforming to that repo's own architecture, standards, and existing patterns. Use when coding a ticket/feature, modifying existing behavior, or fixing a bug in any repo of this multi-repo workspace (Next.js web apps, the Rust backend, Postgres migrations, …), and when the developer needs the repo's coding standards loaded before writing code.
when_to_use: Adding a feature, modifying existing behavior, or fixing a bug in any repo of the workspace.
argument-hint: [feature-name, figma-url]
arguments: [feature-name, figma-url]
disable-model-invocation: false
allowed-tools:
    - Read
    - Grep
    - Glob
    # Codegraph (per-repo index): the FIRST lookup for "where does this code live / what
    # exists already" — codegraph explore/search/callers/impact before any grep (Grep/Glob last resort).
    - Bash(codegraph *)
    - Write
    - Edit
    - Bash(git *)
    # The uniform per-repo dev harness — test/gen/analyze/clean/run/status/why mapped onto
    # whatever stack the repo uses. Build and test through this, never the raw toolchain.
    - Bash(scripts/dev.sh *)
    - Bash(mkdir *)
    - mcp__claude_ai_Figma
model: sonnet[1m]
effort: high
---

Implement one feature or fix in the **current repo**, test-first. This is a polyglot, multi-repo workspace (Next.js web apps, the Rust backend, Postgres migrations, …) — there is no single stack to assume. **The repo you are in is the authority:** its `CLAUDE.md`, its `docs/`, and the code already on disk define the architecture, standards, and conventions you conform to. New code should read like the code beside it.

**Never develop inside a git submodule.** If the code you need to change lives in a submodule checkout — a repo embedded in this one (e.g. `your-app/shared-lib/`), which is *also* cloned as its own primary clone at the workspace root — edit the **primary clone at the root** (`shared-lib/`), not the submodule. Detect (`git rev-parse --show-superproject-working-tree` non-empty ⇒ inside a submodule; `.gitmodules` lists the mounted paths) and redirect per the workspace-root `docs/agents/submodules.md`.

## Read first — the repo's own knowledge (authoritative)
- `CLAUDE.md` — architecture, coding standards, dependency/version policy. Obey it; don't restate it.
- `docs/adr/` — Architecture Decision Records. Honor them. If your change would contradict an ADR, **stop and surface the conflict** instead of diverging silently.
- `CONTEXT.md` — domain glossary. Use its exact terms (avoid the listed `_Avoid_` synonyms) in names, comments, and tests.
- `docs/agents/domain.md` — how to consume the docs above.
- **Cross-cutting standards** (observability/logging, i18n, error handling, security, accessibility/motion) are stack-specific — apply the approach the repo's `CLAUDE.md`/`docs/` document for *that* stack; never import another stack's convention.

## Steps
1. **Locate the work — codegraph FIRST.** Query the repo's codegraph index (`codegraph explore` for "where is the `<feature>` / how does `<flow>` work", `codegraph search` for a named symbol, `codegraph callers`/`codegraph impact` for blast radius) to map what already exists vs. what's new. Reserve `Grep`/`Glob` for a detail codegraph didn't cover. **Done when:** you can name the modules/files you'll touch and what's reused vs. added.
2. **Read the design — only if a frame is referenced.** Figma is gated by `design.enabled`; skip if it's off or `$figma-url` is absent. Otherwise read it in **Dev Mode**: `get_design_context` is the primary read (tokens, specs, measurements), backed by `get_metadata` and `get_screenshot`. Download any required assets into the project.
3. **Design the change to fit the repo.** Lay out the layers/modules/files, interfaces, and data shapes — matching the repo's existing patterns. Scope is the repo's call: its `CLAUDE.md` decides whether this repo owns UI, API, data, or migrations. **Done when:** the change conforms to an existing ADR-compatible pattern (or you've surfaced a genuine conflict).
4. **Implement the change via `/tdd`.** Run `/tdd` to drive the red-green-refactor loop — it owns the rhythm (vertical tracer-bullet slices, one behavior at a time; a new edge case is a new failing test, not a separate cycle). Don't restate the loop here. As you write each slice's code, hold to the workspace **coding style** — **storytelling** code (no body comments), the **flow → side-effect → pure** split (complex logic in pure functions), files ≤500 lines; rules + example in the shared `../coding-style.md` beside this skill (read before your first edit). Keep it surgical: the simplest code that satisfies the plan, no scope creep.
5. **Verify through the repo's harness.** `scripts/dev.sh gen` (only if a codegen/format step changed) → `scripts/dev.sh analyze` → `scripts/dev.sh test`, and confirm it launches via `scripts/dev.sh run`. On red, drill with `scripts/dev.sh why <name>` and fix before moving on. **Done when:** `analyze` + `test` are green and it runs. (Behavioral and design-fidelity verification — exercising flows, matching the Figma — is the downstream QA/E2E suite's job, not this skill's.)

## Observations
- Log your implementation to `agent_logs/Noah_developer/<work-key>-<NN>.md` (work-key = the `FM-<n>` ticket) per the **Agent work logs** convention in `CLAUDE.md` — git-ignored, ≤~200 lines/file, sequential.
- Append any mistake + the solution you found to `docs/logs/coding-experience.md`, and read that file before coding to avoid repeating them.
