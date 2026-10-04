# Cursor agents run on `auto` and fall back by tier on a usage-limit block

**Status:** Accepted. Amends `docs/adr/0004` (the generated-file list) and `docs/adr/0023` (the
Cursor model sentence).

## Context

The canonical subagents under `.claude/agents/*.md` carry Claude Code's tier vocabulary in their
frontmatter — `model: opus` / `sonnet` / `haiku` / `fable`. Until now `aiworks cursor` exposed that
directory to Cursor as a symlink, and `docs/agents/cursor.md` asserted that Cursor ignores a model
value it cannot resolve and falls back to the session model.

Measured on `cursor-agent 2026.09.26-dd393fe`, that assertion is false:

- `cursor-agent -p --model opus …` emits an init event with `"model":"Claude Opus 4.5"` and exits 1:
  `ActionRequiredError: You've hit your usage limit for Opus … Switch to a different model or set a
  Spend Limit to continue with Opus.` `--model sonnet` fails the same way (`… continue with Sonnet`).
- `--model haiku` and `--model fable` are rejected client-side: `Cannot use this model: haiku.
  Available models: …`.
- `--model auto`, `grok-4.7-high`, `grok-4.7-medium` and `composer-2.5` succeeded at the same moment.

So `opus` and `sonnet` are Cursor aliases for quota-gated Claude models: 11 of 17 roles pinned an
old model and never used `auto`; the 6 `haiku`/`fable` roles carried an id Cursor cannot start.

The workflow runtime had the mirror-image gap. `scripts/workflows/adapters/cursor.mjs` hard-coded
`--model auto` and turned any `ActionRequiredError` into a failed phase. There was no retry path.

Inferred, not measured: Cursor subagent frontmatter resolves `model:` with the same alias table as
the CLI flag (U1 below).

## Decision

1. **Interactive subagents are generated, not linked, and carry `model: inherit`.** `aiworks cursor`
   projects each `.claude/agents/<n>.md` onto `.cursor/agents/<n>.md` through
   `scripts/cursor/agent.awk`: the first frontmatter block's `model:` line becomes `model: inherit`,
   line 2 gains the ownership marker `# aiworks-cursor: generated from .claude/agents/<n>.md …`, and
   every other byte — `effort:`, `tools:`, `skills:`, the body — is copied verbatim. The subagent
   follows the session model, which this workspace keeps on `auto`.
2. **Workflow agents start on `auto` and retry once on a usage-limit block.** The Cursor adapter
   calls `cursor-agent -p --model auto`; when the call fails with `ActionRequiredError` / `hit your
   usage limit`, it retries exactly once on the role's tier fallback — `fable`, `opus`, `sonnet`
   and an untiered role → `grok-4.7-high`; `haiku` → `composer-2.5` — and writes one stderr line
   naming the switch. Schema-correction resumes of the same `run()` stay on the fallback model;
   spent tokens of every attempt are carried. Nothing else is retried: a non-limit exit, schema
   exhaustion, or an invalid model fails exactly as before. The fallback ids live in the adapter's
   `FALLBACK` table, like the Codex `modelMap`.

## Considered options

- **Change the canonical frontmatter.** Would break Claude Code, which needs the tier names.
- **A `workspace.config.yaml` key for the fallback ids.** YAGNI: the ids were verified against this
  account's `--list-models`; revisit on the first stale id.
- **Pin the tier fallback statically in the interactive files** (`grok-4.7-high` instead of
  `inherit`). Would downgrade every interactive subagent even while quota is fine. Rejected in
  favour of `inherit` (decision D1 of the plan).
- **Detect the quota block in a hook and switch models.** Cursor has no model-switch hook and its
  `subagentStart` never fires (`docs/agents/cursor.md`). Interactive Cursor therefore cannot fall
  back automatically; the person switches the session model in the picker.

## Consequences

- Amends `docs/adr/0004`: `.cursor/agents/*.md` join the generated list (the fifth generated
  artefact, after the `0038` `mcp.json`). Amends `docs/adr/0023`: Cursor still routes workflow
  agents through `auto`, plus the one-shot fallback.
- The first `aiworks cursor` on a checkout that committed the directory link replaces it with
  files; `--check` reports the legacy link as drift until then. An `ADR-0033` reconcile, not a
  removal: generator-owned link → generator-owned files, same Harness.
- A hand-written `.cursor/agents/*.md` (no marker) is never overwritten or deleted; `--remove`
  deletes only marked files. A generated file whose canonical source is gone is pruned.
- Editing a canonical agent now needs `aiworks cursor` to re-project it; `--check` catches drift.
- Model ids churn (`grok-4.5` → `4.6` → `4.7` already). A stale fallback id fails the phase closed
  with `Cannot use this model: <id>`; the fix is editing `FALLBACK`. A doctor check that every
  `FALLBACK` id appears in `cursor-agent --list-models` is deferred until the first id goes stale.
- Automatic fallback exists only in workflow runs. Interactive Cursor has no mechanism to switch a
  subagent's model on error.

## Measured after the fact, and still open

- **U1 — measured, works.** In a throwaway project with `.cursor/agents/probe.md` carrying
  `model: inherit`, `cursor-agent -p --trust --model composer-2.5 --output-format stream-json "Use
  the probe subagent …"` emitted a `taskToolCall` with `"name":"probe"` and
  `"model":"composer-2.5"` — the session model. `inherit` resolves as intended.
- **U2** — whether a limit hit mid-turn arrives as exit 1 + stderr (measured at start) or as a
  `result` event with `is_error:true`. The adapter inspects both.
- **U3 — measured, works.** A session started with `--model auto` was resumed with
  `--model composer-2.5 --resume <id>`: exit 0, the reply recalled the earlier turn. So a limit hit
  during a correction resume while still on `auto` can fall back on the same session.
- **U4** — whether `auto` itself can be usage-limited. Not reproducible while Opus/Sonnet were
  blocked and `auto` was not.
