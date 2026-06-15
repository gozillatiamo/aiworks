---
name: coding-feature 
description: Coding a feature for the application with Flutter to support Android and iOS.
when_to_use: Adding a new feature or modifying an existing feature.
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
    - Bash(flutter *)
    - Bash(dart *)
    - Bash(mkdir *)
    - Bash(xcrun *)
    - mcp__claude_ai_Figma
model: sonnet[1m]
effort: high
---

## Reference:
- Project knowledge lives in @docs/ — read it before coding and treat it as authoritative:
    - @docs/adr/ — Architecture Decision Records. You MUST honor these decisions while coding. If your implementation would contradict an ADR, stop and surface the conflict instead of silently diverging.
    - @CONTEXT.md — the domain glossary. Use its exact terms (and avoid the listed `_Avoid_` synonyms) in names, comments, and tests.
    - @docs/agents/domain.md — explains how to consume the docs above.
- @.claude/skills/coding-feature/observability-sentry.md — how this app does logging, tracing, and metrics with Sentry (the single observability backend). Apply it to every feature you build or modify.
- @.claude/skills/coding-feature/animation.md — MANDATORY motion standard. Every page, action, transition, and branding element (logo, iconic marks, mascot) must be animated. A static screen is an incomplete feature.
- @.claude/skills/coding-feature/localization.md — English-first, multi-locale-ready i18n. No hard-coded user-facing strings; everything goes through ARB-based `AppLocalizations` so adding Thai/Chinese/etc. is just a new translation file.
- In depth detail for each feature in @design-os/product-plan/instructions/incremental directory.
- Try to understand the content base product plan.
    - Finding these variables to use in product plan prompt, depend on $feature-name.
        - **SECTION_NAME** = {{section-name}} 
        - **SECTION_ID** = {{section-id}}
        - **NN** = {{nn}}
        **Example:** @design-os/product-plan/instructions/incremental/02-foundation.md -> **SECTION_NAME** = Foundation, **SECTION_ID** = foundation, **NN** = 02
    - use these variables in @design-os/product-plan/prompts/section-prompt.md as your reference.

## When coding a feature:
- Read project knowledge in @docs/ first — the relevant ADRs in @docs/adr/ and the @CONTEXT.md glossary — and follow the recorded decisions and terminology throughout.
- Read UI desgin in Figma Dev Mode $figma-url if provided, specific to $feature-name
- **Locate the work via codegraph FIRST.** Before designing where code goes, query the repo's codegraph index (`codegraph explore` for "where is the <feature> module / how does <flow> work", `codegraph search` for a named symbol, `codegraph callers`/`codegraph impact` for blast radius) to see what already exists vs. what's new — it is the pre-built index for this repo, so use it instead of a grep+read sweep. Reserve `Grep`/`Glob` for a last-resort detail codegraph didn't cover (a non-code asset, a config string).
- Design code staructure, files and feature layer.
- Download necessary assets from Figma, into the project.
- Document @docs in the project, to read later.
- Take your experience from the @docs/logs/coding-experience.md file, to improve the coding process.
- Prepare the tests, to keep the TDD flow.
- Codeing the feature(Any API logic should not included, it's interface application).
- Apply observability, mandatory motion, and localization per the three guides linked in **Reference** above — observability-sentry, animation, localization. Follow each in full; don't re-derive them here.
- Run the tests, to ensure the feature is working as expected.
- Fix bugs if exists. If a new issue surfaces, write a failing test first, then code the fix.
- Verify the feature is **buildable, installable, and runable**: it builds (`flutter build`), installs, and launches/runs on Android and iOS without crashing. Behavioral and design-fidelity verification (matching the Figma, exercising the UI flows) is **not** done here — it is covered by the `your-tests` E2E automation suite downstream.

## Observations
- Write your implementation logs to `agent_logs/Noah_developer/<work-key>-<NN>.md` (work-key = the `FM-<n>` ticket) per the **Agent work logs** convention in `CLAUDE.md` — git-ignored, ≤~200 lines/file, sequential.
- Write your mistakes and memory the solution knowledge append in to @docs/logs/coding-experience.md file.