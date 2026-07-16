---
name: ultra-review
description: Run a ticket's open MR/PR through three specialist review gates at once — code-reviewer (clean-code + spec), guardian-engineer (SonarQube security + data-protection), performance-engineer (profiling) — spawned in parallel, then aggregated into one combined verdict where a blocking finding at any gate caps the result. Honors the workspace output language and review.level. Use when the user wants a deep / full / ultra review, a multi-gate review, or a combined code + security + performance review of a <KEY> ticket — distinct from /review, the single spec+standards pass.
disable-model-invocation: true
---

# Ultra-review

Runs one ticket's open MR/PR through **three specialist gates in parallel** — Daniel
(code-reviewer), Ethan (guardian-engineer), Liam (performance-engineer) — then aggregates
their verdicts into one. A **blocking finding at ANY gate caps the combined verdict**, no
matter how clean the others are.

Distinct from `/review` (the single 2-axis spec+standards pass by two `general-purpose`
sub-agents): ultra-review fans out the three *acting* specialist agents, which comment
inline on the live MR/PR and render their own verdicts. The verdict grounding is shared —
[`.claude/skills/review/basis.md`](../review/basis.md) — and every gate reads it first.

**Scope — review, never merge.** The gates review, comment findings inline, and render a
verdict/approval; they must **NOT merge** (even where `auto_merge` is on). Ultra-review is a
review pass — merge stays a separate, later decision.

## 0. Resolve language + review level BEFORE spawning (do this FIRST)

These two values are resolved **once here** and pasted **verbatim** into all three gate
briefs. The gates are real sub-agents that would otherwise each re-resolve from disk and can
drift; passing the resolved directive is the proven fix (mirrors `/review` step 4). Both
agent definitions honor an in-prompt directive over any self-resolution.

- **Output language.** If a `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line is already in
  your prompt, that value is authoritative — do NOT re-resolve. Otherwise read
  `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a
  `language:` line, else `workspace.config.yaml` — never from memory.
- **Review level.** Read `review.level` from `workspace.config.yaml` (default **strict** if
  absent).

State both resolved values + their source in one line before spawning. Hold this block to
paste into **every** gate brief (substitute the resolved values, never the literal `<…>`):

```
OUTPUT LANGUAGE = <en|th> (authoritative — do NOT re-resolve). Write every finding's prose
in this language; under th the finding SENTENCES are Thai with an English spine — headings/
labels, ALL code + identifiers + file paths, and technical/domain/proper-noun terms stay
English (Arabic numerals always); under en write English.
Review level = <strict|thorough> (passed in — do NOT re-read the config). At strict report
blocking must-fixes only; at thorough also triage the nice-to-have tier.
```

## Process

### 1. Pin the ticket + its open MR/PR

Resolve the `<KEY>` ticket (id format + fetch via `docs/agents/issue-tracker.md`, through
`scripts/tracker/`). Find its **open MR/PR(s)** via the VCS adapter (`scripts/vcs/`) — for
each, capture the branch, the target branch, and the MR/PR number/ref.

**Completion:** you hold the ticket plus at least one open MR/PR (branch → target). If the
ticket has **no open MR/PR**, STOP and say so: these gates comment on a live MR/PR — open one
first (`/open-pr`), or use `/review` for a branch-only pass. Do not fabricate a diff.

*(Multi-repo ticket: collect every repo's open MR/PR and hand each gate the full list — the
gates review each. No wave engine here; that is dev-cycle's job.)*

### 2. Spawn the three gates in parallel

Send **one message with three `Agent` tool calls** — `code-reviewer`, `guardian-engineer`,
`performance-engineer` — so they run concurrently and don't pollute each other's context.
Into **each** brief put:

- The shared directive block from §0 (language + review level), verbatim.
- The ticket `<KEY>` and the open MR/PR ref(s) + branch + target.
- `"This is an ultra-review pass — review, comment findings inline on the MR/PR, and render
  your verdict. Do NOT merge, even if auto_merge is on; merge is a separate decision."`

Each gate then runs its own instrument (Daniel: `/review` + codegraph blast radius; Ethan:
SonarQube static analysis; Liam: profiling) per its own definition — no extra tool grant
needed. **Completion:** all three gates have returned a verdict.

### 3. Aggregate

Present the three results under `## Code (Daniel)`, `## Guardian (Ethan)`, and
`## Performance (Liam)` — verbatim or lightly cleaned, **not merged or reranked**: the gates
are deliberately independent so the user sees each. **Language check first:** if a gate
returned prose in the wrong language, rewrite that prose into the resolved OUTPUT LANGUAGE
before presenting — never ship a finding in the wrong language.

End with **one combined verdict** line: requirements genuinely **met / partially met / not
met**, then the review level and the worst single issue per gate. The combined verdict is
**capped by any blocking finding at any gate** — a guardian security must-fix or a critical
perf regression caps the verdict at "partially met" even when the code-quality gate is clean.

**Notify** is the gates' own job: when `notify.enabled` and a review-request thread exists,
each posts its threaded verdict under it (built-in step). The skill does not double-post.
