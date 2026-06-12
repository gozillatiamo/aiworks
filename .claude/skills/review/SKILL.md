---
name: review
description: Review the changes since a fixed point (commit, branch, tag, or merge-base) along two axes — Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/PRD asked for?). Runs both reviews in parallel sub-agents and reports them side by side. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X".
---

# Review

Two-axis review of the diff between `HEAD` and a fixed point the user supplies:

- **Standards** — does the code conform to this repo's documented coding standards?
- **Spec** — does the code faithfully implement the originating issue / PRD / spec?

Both axes run as **parallel sub-agents** so they don't pollute each other's context, then this skill aggregates their findings.

The issue-tracker conventions (how to fetch the originating ticket, the id format) live in `docs/agents/issue-tracker.md`; reads/writes go through the tracker adapter (`scripts/tracker/`).

## Process

### 1. Pin the fixed point

Whatever the user said is the fixed point — a commit SHA, branch name, tag, `main`, `HEAD~5`, etc. Don't be opinionated; pass it through. If they didn't specify one, ask: "Review against what — a branch, a commit, or `main`?" Don't proceed until you have it.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Also note the **changed symbols** (the functions/classes/methods the diff touches) — both sub-agents use the repo's codegraph index to trace their **blast radius** (`codegraph callers`/`codegraph impact`), so a change that breaks a dependent OUTSIDE the diff is caught, not just what the diff literally shows. Codegraph is the pre-built index for this repo; `Grep`/`Glob` are the last resort for a detail it didn't cover.

### 2. Identify the spec source

Look for the originating spec, in this order:

1. Issue references in the commit messages (`#123`, `Closes #45`, GitLab `!67`, etc.) — fetch via the workflow in `docs/agents/issue-tracker.md`.
2. A path the user passed as an argument.
3. A PRD/spec file under `docs/`, `specs/`, or `.scratch/` matching the branch name or feature.
4. If nothing is found, ask the user where the spec is. If they say there isn't one, the **Spec** sub-agent will skip and report "no spec available".

### 3. Identify the standards sources

Anything in the repo that documents how code should be written. Common locations:

- `CLAUDE.md`, `AGENTS.md`
- `CONTRIBUTING.md`
- `CONTEXT.md`, `CONTEXT-MAP.md`, per-context `CONTEXT.md` files
- `docs/adr/` (architectural decisions are standards)
- `.editorconfig`, `eslint.config.*`, `biome.json`, `prettier.config.*`, `tsconfig.json` (machine-enforced standards — note them but don't re-check what tooling already checks)
- Any `STYLE.md`, `STANDARDS.md`, `STYLEGUIDE.md`, or similar at the repo root or under `docs/`

Collect the list of files. The **Standards** sub-agent will read them.

### 4. Spawn both sub-agents in parallel

Send a single message with two `Agent` tool calls. Use the `general-purpose` subagent for both. Tell **both** sub-agents to lean on the repo's codegraph index for lookups — `codegraph explore`/`codegraph search` to understand a touched area, and **`codegraph callers`/`codegraph impact` to trace the blast radius of changed symbols** (what depends on them OUTSIDE the diff). It is the pre-built index for this repo, so prefer it over a grep+read sweep; `Grep`/`Glob` are the last resort for a detail it didn't cover. (The `general-purpose` subagent already has the tools — no extra grant needed.)

**Standards sub-agent prompt** — include:

- The full diff command and commit list.
- The list of standards-source files you found in step 3.
- The brief: "Read the standards docs. Then read the diff. For each changed symbol, run `codegraph callers`/`codegraph impact` to see its dependents before judging change-preventer/coupler smells and contract changes. Report — per file/hunk where relevant — every place the diff violates a documented standard (cite the standard: file + rule), plus any changed contract whose dependents (per codegraph) now break. Distinguish hard violations from judgement calls. Skip anything tooling enforces. Use `Grep`/`Glob` only as a last resort. Under 400 words."

**Spec sub-agent prompt** — include:

- The diff command and commit list.
- The path or fetched contents of the spec.
- The brief: "Read the spec. Then read the diff. Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the diff that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong — use `codegraph callers`/`codegraph impact` on changed symbols to check the change didn't break a dependent the spec relies on, outside the diff. Quote the spec line for each finding. Use `Grep`/`Glob` only as a last resort. Under 400 words."

If the spec is missing, skip the Spec sub-agent and note this in the final report.

### 5. Aggregate

Present the two reports under `## Standards` and `## Spec` headings, verbatim or lightly cleaned. Do **not** merge or rerank findings — the two axes are deliberately separate so the user can see them independently.

End with a one-line summary: total findings per axis, and the worst single issue (if any) flagged.

## Why two axes

A change can pass one axis and fail the other:

- Code that follows every standard but implements the wrong thing → **Standards pass, Spec fail.**
- Code that does exactly what the issue asked but breaks the project's conventions → **Spec pass, Standards fail.**

Reporting them separately stops one axis from masking the other.
