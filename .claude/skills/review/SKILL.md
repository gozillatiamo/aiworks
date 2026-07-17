---
name: review
description: Review the changes since a fixed point (commit, branch, tag, or merge-base) and render one verdict — are the originating ticket's requirements genuinely met? Verifies the diff against the repo's own knowledge (structure, design patterns, docs, ADRs, standards) along two parallel axes — Spec (is the bar cleared?) and Standards (does the implementation hold up?) — reported side by side. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X".
---

# Review

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write every review comment you post — the inline notes and the overview/verdict on the PR/MR in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code, checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files), **and ANY file you author with a `.md` extension** (plans, testcases, PRD/summary Markdown in `agent_logs/`) are **never** Thai — the `th` prose rule applies to chat, tickets, PR/MR discussion, Slack, and `.html` docs only. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

Review the diff between `HEAD` and a fixed point the user supplies, and render one
verdict: **are the originating ticket's requirements genuinely met?**

Before judging anything, read the **verdict basis** — [`basis.md`](basis.md) — and hold
it as the base context for everything below. In short:

- **The requirements are the bar.** The ticket is what the change exists to achieve;
  the verdict measures against it.
- **The coding standards are the bottom line.** The repo's coding-standards docs
  (`.claude/rules/coding_standards/`, `CLAUDE.md`, `CONTRIBUTING.md`) are a hard floor —
  a standards breach is a must-fix, not a judgement call, and caps a "met" verdict even
  when the bar is cleared.
- **The repo's knowledge is your instrument.** Structure, design patterns, docs, ADRs,
  and the codegraph index are how you verify that the bar is *genuinely* cleared — not
  just superficially. Every finding cites the requirement it bears on or the instrument
  that exposed it.
- **The review level sets the depth.** `review.level` in `workspace.config.yaml`
  (default **strict**) decides whether the nice-to-have tier is reported at all — see
  `basis.md` §4.
- **Every claim carries a receipt.** Cite what you actually ran or read — you have no
  build tool, so a compile/test result you didn't observe, or a claim about an unwritten
  fix, is a suggestion for the developer's gate to settle, not a verdict (`basis.md` §5).

The verdict runs along two axes, as **parallel sub-agents** (so they don't pollute each
other's context), then this skill aggregates them:

- **Spec** — is the bar cleared? Are the requirements present, complete, and correct?
- **Standards** — does the implementation hold up? Two duties: the **bottom line**
  (`basis.md` §2 — coding-standards breaches, reported as must-fixes) and the
  **instruments** (`basis.md` §3 — structure, ADRs, design patterns, blast radius).

Either axis can pass while the other fails (see [Why two axes](#why-two-axes)), so they
are reported side by side, never merged.

Ticket conventions (how to fetch the originating ticket, the id format) live in
`docs/agents/issue-tracker.md`; reads/writes go through the tracker adapter
(`scripts/tracker/`).

## Process

### 1. Pin the fixed point

Whatever the user said is the fixed point — a commit SHA, branch name, tag, `main`,
`HEAD~5`, etc. Don't be opinionated; pass it through. If they didn't specify one, ask:
"Review against what — a branch, a commit, or `main`?" Don't proceed until you have it.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the
comparison is against the merge-base). Note the commit list via
`git log <fixed-point>..HEAD --oneline`, and the **changed symbols** (the
functions/classes/methods the diff touches) — both sub-agents trace their blast radius
with the codegraph instrument (`basis.md` §3).

### 2. Identify the spec source (the requirements — the bar)

Find the originating requirements, in this order:

1. Issue references in the commit messages (`#123`, `Closes #45`, GitLab `!67`, etc.) —
   fetch via the workflow in `docs/agents/issue-tracker.md`.
2. A path the user passed as an argument.
3. A PRD/spec file under `docs/`, `specs/`, or `.scratch/` matching the branch name or
   feature.
4. If nothing is found, ask the user where the requirements are. If they say there are
   none, the **Spec** sub-agent skips and reports "no spec available" — and without a
   bar, the verdict is necessarily weaker. Say so.

### 3. Identify the standards sources (the instruments)

The repo-knowledge files the **Standards** sub-agent verifies against (`basis.md` §2).
Collect the list; common locations:

- `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`
- `CONTEXT.md`, `CONTEXT-MAP.md`, per-context `CONTEXT.md` files
- `docs/adr/` — architectural decisions are standards
- `STYLE.md`, `STANDARDS.md`, `STYLEGUIDE.md`, or similar at the repo root or under `docs/`
- `.editorconfig`, `eslint.config.*`, `biome.json`, `prettier.config.*`, `tsconfig.json`
  — machine-enforced; note them but don't re-check what tooling already checks.

### 4. Spawn both sub-agents in parallel

Send a single message with two `Agent` tool calls, both `general-purpose`. Give **each**
the absolute path to `basis.md` and tell it to read that first as its grounding context
(it already has the tools — no extra grant needed).

First read `review.level` from `workspace.config.yaml` (default **strict** if absent) and
add the **same** line to BOTH briefs: "Review level = `<strict|thorough>` (`basis.md` §4)
— at **strict** report ONLY must-fixes; at **thorough** also report nice-to-have findings,
clearly separated." One read, passed to both, so the axes stay consistent.

**Propagate the output language into BOTH briefs — non-negotiable.** These sub-agents are
`general-purpose` and carry NO output-language pointer of their own, and step 5 presents their
findings **verbatim**, so a finding written in the wrong language ships in the wrong language.
Take the language you resolved in the `## Output language` block above and add this line to BOTH
briefs: "OUTPUT LANGUAGE = `<en|th>` (authoritative — do NOT re-resolve). Write every finding's
prose in this language; under `th` the finding SENTENCES are Thai with an English spine — headings/
labels, ALL code + identifiers + file paths, and technical/domain/proper-noun terms stay English
(Arabic numerals always); under `en` write English." Pass the resolved value, never the literal
`<en|th>`.

**Standards sub-agent prompt** — include:

- The full diff command and commit list.
- The standards-source files from step 3.
- The brief: "Read `basis.md`, then the standards docs, then the diff. Your axis has two
  duties. **Bottom line (§2):** the repo's coding standards
  (`.claude/rules/coding_standards/`, `CLAUDE.md`, `CONTRIBUTING.md`) are a hard floor —
  report EVERY breach as a must-fix (cite the exact rule: file + section), not a
  judgement call. **Instruments (§3):** does the implementation hold up against the
  repo's knowledge? For each changed symbol, run `codegraph callers`/`codegraph impact`
  to see its dependents before judging change-preventer/coupler smells and contract
  changes; report any changed contract whose dependents now break (cite the ADR /
  structure / codegraph dependent). Separate the bottom-line must-fixes from the
  instrument judgement calls. Skip what tooling enforces. **Receipts (§5):** you have NO
  build/test tool — never assert it compiles or passes, and a claim about an unwritten
  fix ('widening this compiles, zero call-site changes') is a hypothesis for the
  developer's gate to settle, not yours to certify. Under 400 words."

**Spec sub-agent prompt** — include:

- The diff command and commit list.
- The path or fetched contents of the requirements.
- The brief: "Read `basis.md`, then the requirements, then the diff. Your axis is §1: is
  the bar genuinely cleared? Report (a) requirements missing or partial; (b) behaviour
  not asked for (scope creep); (c) requirements that look implemented but are wrong or
  superficial — use `codegraph callers`/`codegraph impact` on changed symbols to confirm
  the change didn't break an out-of-diff dependent the requirement relies on. Quote the
  requirement line for each finding. Under 400 words."

If there are no requirements (step 2), skip the Spec sub-agent and note it in the report.

### 5. Aggregate

Present the two reports under `## Standards` and `## Spec` headings, verbatim or lightly
cleaned. Do **not** merge or rerank findings — the axes are deliberately separate so the
user sees them independently. **Language check before you present:** if a sub-agent returned
its findings in the wrong language (it missed the directive), rewrite that prose into the
resolved OUTPUT LANGUAGE now — "lightly cleaned" includes fixing the language. Never present a
verbatim finding that violates the resolved language.

End with the **verdict**: are the requirements genuinely met? State it in one line —
met / partially met / not met — then the review level, the per-axis finding count and
the worst single issue. At **strict** the report carries must-fixes only (no nice-to-have
section) — that is the level working, not an omission. The Spec axis carries the verdict — **but a bottom-line breach (a coding-standards
must-fix, `basis.md` §2) caps the verdict at "partially met" no matter how clean Spec
is.** The instrument findings are the evidence that a "met" is real.

## Why two axes

The bar (requirements) and the instruments (repo knowledge) can diverge:

- Code that follows every standard but implements the wrong thing → **Standards pass,
  Spec fail.**
- Code that does exactly what the ticket asked but breaks the repo's conventions →
  **Spec pass, Standards fail.** When the Standards failure is a coding-standards breach
  it is a bottom-line breach — blocking, not advisory (it caps the verdict, see above);
  a Standards failure is also a signal that a requirement passing Spec may be only
  *superficially* met.

Reporting them separately stops one axis from masking the other.
