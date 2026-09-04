# Graph Report - aiworks  (2026-09-04)

## Corpus Check
- 238 files · ~273,375 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2469 nodes · 2350 edges · 220 communities (204 shown, 7 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4521421a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Headroom — input-side context compression
- aiworks-dispatch — Slack `@bot` → Superset on-demand Claude
- README.md
- Resuming a workflow after the config changed
- Working this workspace from Cursor
- Agent harnesses
- A QA-attributed fix is quality-checked, not re-reviewed
- CLAUDE.md — {{ORG_NAME}} Organization workspace
- AI Workspace
- Plan artifacts — where a plan lives, and why it is never committed
- Tailwind CSS Utility Reference
- Brand Guidelines v1.0
- Voice adapter (`scripts/voice/`)
- Design
- Canvas Design System
- Form & Input Components
- Tailwind CSS Responsive Design
- Typography Specifications
- Process
- Logo Usage Rules
- Component Specifications
- shadcn/ui Accessibility Patterns
- Plan automation
- Asset Approval Checklist
- Logo AI Prompt Engineering
- Color Palette Management
- CIP Deliverable Guide
- States and Variants
- UI Styling Skill
- Workflow
- tdd/SKILL.md
- Tailwind CSS Customization
- Design System
- During the session
- Image Generation Prompt Best Practices
- Routing by Task Type
- shadcn/ui Theming & Customization
- Codegraph keeps the code, graphify maps the prose
- Asset Organization Guide
- Primary Color Meanings
- Core Logo Types
- 4. Test scenarios
- Brand Consistency Checklist
- CIP Mockup Prompt Engineering
- Color Semantics
- Voice — spoken output and dictation
- Interactive Debugger
- Diagnosing Bugs
- Component library
- stagehand — putting what the assistant touches on screen
- Design Principles
- Design Principles
- CIP Design Reference
- Icon Design Reference
- Copywriting Formulas
- Copywriting Formulas
- 2. Root causes, and which are fixed
- Banner Design - Multi-Format Creative Banner System
- Messaging Framework
- Brand Voice Framework
- Decomposing an oversized ticket
- Layout Patterns
- Tailwind Integration
- Layout Patterns
- update.md
- Logo Design Reference
- Token Architecture
- Primitive Tokens
- Process
- The test-suite gate does not halt on a red
- `aiworks doctor` — what is missing, and the command that fixes it
- developer.md
- qa-planner.md
- Core Visual Elements
- CIP Design Style Guide
- PG Triage — staging + production
- QA sub-task creation
- Telemetry Triage
- Quick Reference
- Write Interactive Docs
- Thai register (address mode)
- CLAUDE.md — {{ORG_NAME}} Organization workspace
- cpo.md
- qa-runner.md
- Caveman savings statusline
- Git submodule conventions
- Brand
- Slide Strategies
- Component Tokens
- Prod Redis Triage
- Slide Strategies
- to-prd/SKILL.md
- Diagrams — pick the kind that fits the content
- Worktree GC — reclaiming disk without serializing builds
- Kubernetes triage adapter
- Test standards
- Test standards
- ceo.md
- code-reviewer.md
- development-planner.md
- performance-engineer.md
- Ponytail
- Report test results
- Prerequisites
- Update a ticket
- Decision
- The review loop does not halt on a finding
- Cloud Monitoring triage adapter
- scripts/redis — production Redis, read-only
- graphic-designer.md
- guardian-engineer.md
- oncall.md
- One workflow, one slash entry — authored scripts live under `.claude/workflows/src/`
- Case file
- Estimating a ticket
- Kubernetes triage (read-only)
- Load-test baseline gate
- automation-plan-template.md
- Repair script
- `parse_agent_usage.py` — every agent, auto-discovered
- Summarize Team Performance
- Summarize Workflow Performance
- UI/UX Pro Max - Design Intelligence
- Cloud Monitoring triage shares the read-only identity, and owns its correctness contract
- Deferred scope does not stop a run
- dev-cycle keeps its own run state
- Human-review comments — the `Human:` convention
- Image generation (graphic-designer asset pipeline)
- The load-test gate — equal-or-better, or it does not ship
- PII provenance — redact what PRODUCTION gave us, and only that
- The review ledger — a finding is raised once, and resolved visibly
- Working from the workspace root
- scripts/db — deployed Postgres (staging + production), read-only
- product-owner.md
- ux-ui-planner.md
- Workspace coding style
- Installing Debug Adapters
- Slides Reference
- HTML Slide Template
- Diagramming a ticket
- Open PR
- Root cause in a deployed environment
- HTML Slide Template
- Localization — English + Thai (display-only)
- Theming — match the project, never plain black & white
- Triage MCPs cover every deployed environment; only production is gated
- Kubernetes triage authenticates as a separate read-only identity, not as you
- Workspace bring-up never bootstraps deployed-environment access
- A repo whose criteria already hold is finished, not stalled
- The build does not stop at the first partial
- Context handoff — an agent hands off to itself before the ceiling
- Diagram generation (ticket-clarification visuals)
- Issue tracker conventions
- Code minimalism (ponytail)
- Observability adapter
- PDF adapter — HTML/Markdown → PDF (image + Mermaid illustrations)
- cto.md
- documentor.md
- ux-ui-designer.md
- caveman/SKILL.md
- Clarifying a ticket
- Advanced Debugging Techniques
- Karpathy Guidelines
- report-template.md
- Slides
- Pre-Delivery Checklist
- How to Use This Skill
- Editing an existing doc (Mode B — partial update)
- A reviewed-but-unresolved repo still gets the gate
- A submodule pin needs a pushed commit, not a merge
- The local Harness set drives sync, and sync never removes a projection
- Figma (design authoring & reading convention)
- scripts/stagehand
- Tracker adapter
- Brand Guidelines Template
- monitoring-triage/SKILL.md
- Notify (review request)
- self-control-gitflow
- Ticket kickoff
- Common Rules for Professional UI
- Example Workflow
- Cursor gets a generated mirror of the Claude config, built from symlinks
- Organization knowledge lives in the script repo, not in the framework
- 0023-agent-harnesses-project-from-claude-canonical-source.md
- A ticket is a record, not a transcript
- An agent hands off to itself before the ceiling
- Declared plugins install at project scope, and every copy is kept current
- Output compression (caveman)
- Obsidian — shared vault settings for the workspace meta-repo
- Tunnel sidecars (optional — for managed Postgres behind a VPC)
- Notify adapter
- VCS adapter
- Apply human review
- Clarified ticket templates
- coding-feature/SKILL.md
- Decomposition piece-spec templates
- test-plan-template.md
- QA sub-task — worked example
- Vendored plugin skills — where they came from
- A cross-repo finding escalates instead of looping
- A passed gate is recorded, not re-derived
- Diagram adapter
- Vendored assets
- The run ticks its own approval; the merge stays human
- The run's base is state, and the PR/MR is asserted against it
- Vendored assets
- bug-log-template.md
- slides-create.md
- handoff/SKILL.md
- create.md
- hrun

## God Nodes (most connected - your core abstractions)
1. `Voice adapter (`scripts/voice/`)` - 22 edges
2. `UI Styling Skill` - 17 edges
3. `Component library` - 16 edges
4. `Design` - 15 edges
5. `Tailwind CSS Customization` - 14 edges
6. `Tailwind CSS Utility Reference` - 14 edges
7. `Interactive Debugger` - 13 edges
8. `Tailwind CSS Responsive Design` - 13 edges
9. `aiworks-dispatch — Slack `@bot` → Superset on-demand Claude` - 13 edges
10. `Token Architecture` - 12 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- None detected.

## Communities (220 total, 7 thin omitted)

### Community 0 - "Headroom — input-side context compression"
Cohesion: 0.09
Nodes (21): Compression is explicit and file-scoped, Corollary, The consequence that is not about tokens, What headroom offers, What this rules in, What this rules out, Why not the proxy, Config (+13 more)

### Community 1 - "aiworks-dispatch — Slack `@bot` → Superset on-demand Claude"
Cohesion: 0.13
Nodes (14): aiworks-dispatch — Slack `@bot` → Superset on-demand Claude, Cost note, Layout, Logs, Prerequisites, Redis state, Routing to a specific agent — `agent:<name>`, Security (+6 more)

### Community 2 - "README.md"
Cohesion: 0.22
Nodes (8): 🚀 First run, 🔄 Keeping the tooling current, 📚 Learn more, 🗂️ Managing repos, ✅ Prerequisites, 🔍 Production triage (optional), 🎫 Run a ticket, 📦 What's inside

### Community 3 - "Resuming a workflow after the config changed"
Cohesion: 0.06
Nodes (27): Code minimalism is a plugin, scoped by agent, not a prompt, What ponytail offers, What was rejected, Why not on every agent, Why the level is pinned, Why the plugin rather than our own prose, Why three carve-outs, and only three, Consequences (+19 more)

### Community 4 - "Working this workspace from Cursor"
Cohesion: 0.25
Nodes (8): Hooks: how the two protocols meet, If something looks unconfigured, Onboarding a teammate, Set your model to `auto`, The one commit that fails: prettier refuses a symlink, What lives where, Workflow support and remaining differences, Working this workspace from Cursor

### Community 5 - "Agent harnesses"
Cohesion: 0.17
Nodes (12): Adding Hermes, Agent compatibility contract, Agent harnesses, Commands, Harness registry contract, Interactive child-agent visibility, One canonical source, Projector interface (+4 more)

### Community 6 - "A QA-attributed fix is quality-checked, not re-reviewed"
Cohesion: 0.50
Nodes (4): A QA-attributed fix is quality-checked, not re-reviewed, Consequences, Context, Decision

### Community 7 - "CLAUDE.md — {{ORG_NAME}} Organization workspace"
Cohesion: 0.20
Nodes (9): CLAUDE.md — {{ORG_NAME}} Organization workspace, Configuration (read these first), DO NOT, Language, compression and code, Named-agent requests, Notifications, Product, Provider adapters (+1 more)

### Community 8 - "AI Workspace"
Cohesion: 0.25
Nodes (8): Agent harnesses, AI Workspace, Config, Language, Language, Orchestration, Providers, Repos

### Community 9 - "Plan artifacts — where a plan lives, and why it is never committed"
Cohesion: 0.29
Nodes (7): Enforcement, Gates, History, Never committed, Plan artifacts — where a plan lives, and why it is never committed, The paths, Why per repo, not one file

### Community 10 - "Tailwind CSS Utility Reference"
Cohesion: 0.05
Nodes (43): Arbitrary Values, Aspect Ratio, Background Colors, Border Color, Border Radius, Border Style, Border Width, Borders (+35 more)

### Community 14 - "Brand Guidelines v1.0"
Cohesion: 0.05
Nodes (37): 1. Color Palette, 2. Typography, 3. Logo Usage, 4. Voice & Tone, 5. Imagery Guidelines, 6. Design Components, Accessibility, AI Image Generation (+29 more)

### Community 15 - "Voice adapter (`scripts/voice/`)"
Cohesion: 0.05
Nodes (37): Bad news keeps the plain register, Ceiling, not quota — and it is enforced, not requested, Chattiness — how much it says, Config reference, Credentials, Declare a milestone with a tag, Everything is content-addressed, Identity prefix (+29 more)

### Community 16 - "Design"
Cohesion: 0.06
Nodes (35): Banner Design (Built-in), Banner: Design Rules, Banner: Quick Size Reference, Banner: Top Art Styles, Banner: Workflow, CIP Design (Built-in), CIP: Generate Brief, CIP: Generate Mockups (+27 more)

### Community 17 - "Canvas Design System"
Cohesion: 0.06
Nodes (35): 1. Visual Communication First, 2. Minimal Text Integration, 3. Expert Craftsmanship, 4. Systematic Patterns, Analog Meditation, Approach, Canvas Boundaries, Canvas Design System (+27 more)

### Community 18 - "Form & Input Components"
Cohesion: 0.06
Nodes (32): Accordion, Alert, Alert Dialog, Avatar, Badge, Button, Card, Checkbox (+24 more)

### Community 19 - "Tailwind CSS Responsive Design"
Cohesion: 0.06
Nodes (32): 1. Mobile-First Design, 2. Consistent Breakpoint Usage, 3. Test at Breakpoint Boundaries, 4. Use Container for Content Width, 5. Progressive Enhancement, 6. Avoid Too Many Breakpoints, Best Practices, Breakpoint System (+24 more)

### Community 20 - "Typography Specifications"
Cohesion: 0.06
Nodes (30): Accessibility, Base System, Best Practices, Clean & Modern, Common Font Pairings, Contrast Requirements, CSS Implementation, Editorial (+22 more)

### Community 21 - "Process"
Cohesion: 0.07
Nodes (27): 1. The requirements are the bar, 2. The coding standards are the bottom line, 3. The repo's knowledge is your instrument, 4. The review level sets how deep you report, 5. Every claim carries a receipt, The basis for a review verdict, 1. Pin the fixed point, 2. Identify the spec source (the requirements — the bar) (+19 more)

### Community 22 - "Logo Usage Rules"
Cohesion: 0.07
Nodes (28): Absolute Don'ts, Approved Backgrounds, Before Using Logo, Clear Space, Co-branding, Color Rules, Color Usage, Color Variants (+20 more)

### Community 23 - "Component Specifications"
Cohesion: 0.07
Nodes (28): Alert, Anatomy, Anatomy, Anatomy, Anatomy, Anatomy, Badge, Button (+20 more)

### Community 24 - "shadcn/ui Accessibility Patterns"
Cohesion: 0.07
Nodes (28): Accordion, Alert, ARIA Labels, Checkbox and Radio, Color Contrast, Command Palette Navigation, Component-Specific Patterns, Dialog/Modal Navigation (+20 more)

### Community 25 - "Plan automation"
Cohesion: 0.07
Nodes (24): 1. Resolve the ticket and read the two inputs, 2. Survey the code so what you write matches the project, 3. Implement — strictly POM, 4. Verify by running the suite, 5. On a red run — investigate with `why`, then triage, 5a. Log app bugs into agent_logs/, 6. Report back, Coding — automate the plan (+16 more)

### Community 26 - "Asset Approval Checklist"
Cohesion: 0.08
Nodes (25): Accessibility, Archival, Asset Approval Checklist, Automation Support, Color Compliance, Common Issues & Fixes, Content Accessibility, Content Quality (+17 more)

### Community 27 - "Logo AI Prompt Engineering"
Cohesion: 0.08
Nodes (25): Common Pitfalls, Core Prompt Structure, Detailed Brief, Eco/Sustainable, Effective Keywords by Style, Fashion Brand, Healthcare, Industry-Specific Prompts (+17 more)

### Community 28 - "Color Palette Management"
Cohesion: 0.08
Nodes (24): Accessibility Requirements, Brand Compliance Validation, Checking Contrast, Color Documentation Format, Color Extraction, Color Palette Examples, Color Palette Management, Color System Structure (+16 more)

### Community 29 - "CIP Deliverable Guide"
Cohesion: 0.08
Nodes (24): Apparel, Business Card, Car/Sedan, CIP Deliverable Guide, Core Identity, Digital Assets, Email Signature, Envelope (+16 more)

### Community 30 - "States and Variants"
Cohesion: 0.08
Nodes (24): Accessibility, Accessibility Requirements, ARIA States, Color Contrast, Color Variants, Disabled States, Error Messages, Error States (+16 more)

### Community 31 - "UI Styling Skill"
Cohesion: 0.08
Nodes (24): Accessibility Patterns, Alternative: Tailwind-Only Setup, Best Practices, Common Patterns, Component Layer: shadcn/ui, Component Library Guide, Component + Styling Setup, Core Stack (+16 more)

### Community 32 - "Workflow"
Cohesion: 0.08
Nodes (23): Art Direction Styles (Reuse from Banner), Color & Contrast, Design Best Practices, HTML Design Rules, HTML Template Structure, Option A: Chrome Headless CLI (Recommended — zero dependencies), Option B: chrome-devtools skill, Option C: Playwright script (+15 more)

### Community 33 - "tdd/SKILL.md"
Cohesion: 0.09
Nodes (17): Deep Modules, Interface Design for Testability, Designing for Mockability, When to Mock, Refactor Candidates, 1. Planning, 2. Tracer Bullet, 3. Incremental Loop (+9 more)

### Community 34 - "Tailwind CSS Customization"
Cohesion: 0.09
Nodes (22): @apply Directive, Best Practices, Color Customization, Complete Tailwind Config, Configuration Examples, Content Configuration, Custom Color Palette, Custom Font Sizes (+14 more)

### Community 35 - "Design System"
Cohesion: 0.09
Nodes (21): Best Practices, Chart.js Integration, Command, Component Spec Pattern, Contextual Decision Flow, Decision System CSVs, Design System, Integration (+13 more)

### Community 36 - "During the session"
Cohesion: 0.09
Nodes (19): ADR Format, Numbering, Optional sections, Template, What qualifies, When to offer an ADR, CONTEXT.md Format, Rules (+11 more)

### Community 37 - "Image Generation Prompt Best Practices"
Cohesion: 0.09
Nodes (21): 1. SUBJECT (What), 2. CONTEXT (Where/When), 3. STYLE (How), Ambiguous Cases, Atmospheric Enhancement, Camera Control Terminology, Character Consistency, Compositional Integration (+13 more)

### Community 38 - "Routing by Task Type"
Cohesion: 0.10
Nodes (19): Banner Design Tasks, Brand Identity Tasks, Component Creation, Corporate Identity Program Tasks, Design Routing Guide, Design System Migration, Icon Design Tasks, Implementation Tasks (+11 more)

### Community 39 - "shadcn/ui Theming & Customization"
Cohesion: 0.10
Nodes (19): Base Color Presets, Best Practices, Color Customization, Color Format, Component Customization, CSS Variable System, Customize Styles, Customize Variants (+11 more)

### Community 40 - "Codegraph keeps the code, graphify maps the prose"
Cohesion: 0.10
Nodes (18): Codegraph keeps the code, graphify maps the prose, Consequences, The cost we accepted, The gate it failed, The scope graphify gets, Two things measurement corrected, What the doc graph does not do, What was proposed (+10 more)

### Community 41 - "Asset Organization Guide"
Cohesion: 0.11
Nodes (18): Asset Entry (manifest.json), Asset Organization Guide, By Campaign, By Status, By Type, Cleanup Workflow, Components, Directory Structure (+10 more)

### Community 42 - "Primary Color Meanings"
Cohesion: 0.11
Nodes (18): Accessibility Considerations, Analogous, Black, Blue, Color Combinations by Industry, Color Harmony Types, Complementary, Green (+10 more)

### Community 43 - "Core Logo Types"
Cohesion: 0.11
Nodes (18): 1. Wordmark (Logotype), 2. Lettermark (Monogram), 3. Pictorial Mark (Brand Mark), 4. Abstract Mark, 5. Mascot, 6. Emblem, 7. Combination Mark, Aesthetic Styles (+10 more)

### Community 44 - "4. Test scenarios"
Cohesion: 0.11
Nodes (18): 0. Prerequisites (one-time), 1. Configure `.env`, 2. Pre-flight, 3. Start the service, 4. Test scenarios, 5. Inspect state (Terminal 2), 6. Teardown, 7. Troubleshooting (+10 more)

### Community 45 - "Brand Consistency Checklist"
Cohesion: 0.11
Nodes (17): Audit Frequency, Brand Consistency Checklist, Channel Audit, Collateral, Colors, Common Issues, Email, Imagery (+9 more)

### Community 46 - "CIP Mockup Prompt Engineering"
Cohesion: 0.11
Nodes (17): Apparel (Polo/T-Shirt), Base Prompt Structure, Business Card, CIP Mockup Prompt Engineering, Context Modifiers, Corporate Minimal, Deliverable-Specific Modifiers, Letterhead (+9 more)

### Community 47 - "Color Semantics"
Cohesion: 0.11
Nodes (17): Accent, Applying Semantic Tokens, Background & Foreground, Border & Ring, Color Semantics, Dark Mode Overrides, Destructive, Interactive States (+9 more)

### Community 48 - "Voice — spoken output and dictation"
Cohesion: 0.11
Nodes (17): Anything above `terse` is the ROOT checkout's alone, Credentials, Dictation, For agents: every finished turn speaks — name your own line, How much it says — `chattiness`, It is inert unless three things are true, `max`, and why it is a different kind of level, Mute is an off switch, not a volume knob (+9 more)

### Community 49 - "Interactive Debugger"
Cohesion: 0.12
Nodes (16): Advanced Scenarios, Cleanup, Conditional Breakpoints, Forming a Hypothesis, Interactive Debugger, Invariant Breakpoints, Know Your State, Managing Breakpoints Mid-Session (+8 more)

### Community 50 - "Diagnosing Bugs"
Cohesion: 0.12
Nodes (16): Completion criterion — a tight loop that goes red, Diagnosing Bugs, First: can you trigger it at all?, Minimise, Non-deterministic bugs, Output language — resolve BEFORE writing (do this FIRST), Phase 1 — Build a feedback loop, Phase 2 — Reproduce + minimise (+8 more)

### Community 51 - "Component library"
Cohesion: 0.12
Nodes (16): Accordion, Callout, Chart, Comparison, Component library, Composition rules of thumb, Diagram, KPI row (+8 more)

### Community 53 - "stagehand — putting what the assistant touches on screen"
Cohesion: 0.12
Nodes (16): Configuration, Files, If you turned it on and nothing happens, check the value first, Open, then actually work in there, Placement: `halves`, Requirements, Root worktree only, Shrinking a maximized terminal (+8 more)

### Community 54 - "Design Principles"
Cohesion: 0.12
Nodes (15): 22 Art Direction Styles, Banner Sizes & Art Direction Styles Reference, Complete Banner Sizes, CTA Rules, Design Principles, Pinterest Research Queries, Print, Print Specs (+7 more)

### Community 55 - "Design Principles"
Cohesion: 0.12
Nodes (15): 22 Art Direction Styles, Banner Sizes & Art Direction Styles Reference, Complete Banner Sizes, CTA Rules, Design Principles, Pinterest Research Queries, Print, Print Specs (+7 more)

### Community 56 - "CIP Design Reference"
Cohesion: 0.13
Nodes (14): CIP Brief (Start Here), CIP Design Reference, Commands, Deliverable Categories, Design Styles, Detailed References, Generate Mockups, HTML Presentation Features (+6 more)

### Community 57 - "Icon Design Reference"
Cohesion: 0.13
Nodes (14): Available Styles, CLI Options, Commands, Generate Batch Variations, Generate Multiple Sizes, Generate Single Icon, Icon Categories, Icon Design Reference (+6 more)

### Community 58 - "Copywriting Formulas"
Cohesion: 0.13
Nodes (14): AIDA (Attention-Interest-Desire-Action), Before-After-Bridge, Contrast Patterns, Copywriting Formulas, Core Formulas, Cost of Inaction, FAB (Features-Advantages-Benefits), Formula-to-Slide Mapping (+6 more)

### Community 59 - "Copywriting Formulas"
Cohesion: 0.13
Nodes (14): AIDA (Attention-Interest-Desire-Action), Before-After-Bridge, Contrast Patterns, Copywriting Formulas, Core Formulas, Cost of Inaction, FAB (Features-Advantages-Benefits), Formula-to-Slide Mapping (+6 more)

### Community 60 - "2. Root causes, and which are fixed"
Cohesion: 0.13
Nodes (15): 1. By the numbers, 2.1 The base was an argument, not state — *fixed (ADR 0025)*, 2.2 A wrong constant, validated by nothing — *fixed (ADR 0025)*, 2.3 An invented flag shape, warned about and not stopped — *fixed (ADR 0025)*, 2.4 The resume deadlock: a re-plan could not invalidate a build — *fixed (ADR 0025)*, 2.5 The dotenv ban is correct, and had no fast path — *open*, 2.6 "Re-confirm" substituted for "re-investigate" — *fixed at the prompt level (see §3)*, 2.7 No gate validated an MR's target branch — *fixed (ADR 0025)* (+7 more)

### Community 61 - "Banner Design - Multi-Format Creative Banner System"
Cohesion: 0.14
Nodes (13): Art Direction Styles (Top 10), Banner Design - Multi-Format Creative Banner System, Banner Size Quick Reference, Design Rules, Prerequisites, Security, Step 1: Gather Requirements (AskUserQuestion), Step 2: Research & Art Direction (+5 more)

### Community 62 - "Messaging Framework"
Cohesion: 0.14
Nodes (13): Core Statements, Elevator Pitches, Framework Structure, Message Architecture, Message by Audience, Message Testing, Messaging Framework, Mission Statement (+5 more)

### Community 63 - "Brand Voice Framework"
Cohesion: 0.14
Nodes (13): Brand Voice Framework, Character Spectrum, Emotion Spectrum, Language Spectrum, Step 1: Define Personality Traits, Step 2: Create Voice Chart, Step 3: Context Adaptation, Tone Spectrum (+5 more)

### Community 64 - "Decomposing an oversized ticket"
Cohesion: 0.14
Nodes (13): Advise flow (CTO), Decomposing an oversized ticket, Execute flow (PO), Guardrails, N >= 4 → new short-named epic, pieces as children, N < 4 → replace the original, Output, Output language — resolve BEFORE writing (do this FIRST) (+5 more)

### Community 65 - "Layout Patterns"
Cohesion: 0.14
Nodes (13): Card Styles, Component Variants, CSS Structures, Feature Grid (3 columns), Layout Decision Flow, Layout Patterns, Layout Selection by Use Case, Metric Styles (+5 more)

### Community 66 - "Tailwind Integration"
Cohesion: 0.14
Nodes (13): Animation Tokens, Base Layer, Button Example, Component Classes, CSS Variables Setup, Dark Mode Toggle, HSL Format Benefits, shadcn/ui Alignment (+5 more)

### Community 67 - "Layout Patterns"
Cohesion: 0.14
Nodes (13): Card Styles, Component Variants, CSS Structures, Feature Grid (3 columns), Layout Decision Flow, Layout Patterns, Layout Selection by Use Case, Metric Styles (+5 more)

### Community 68 - "update.md"
Cohesion: 0.15
Nodes (12): Color Presets, Examples, Files Modified, Important, Overview, Skills Used, Step 1: Gather Brand Input, Step 2: Update Brand Guidelines (+4 more)

### Community 69 - "Logo Design Reference"
Cohesion: 0.15
Nodes (12): Available Styles, Color Psychology, Commands, Design Brief (Start Here), Detailed References, Generate Logo, Industry Defaults, Logo Design Reference (+4 more)

### Community 70 - "Token Architecture"
Cohesion: 0.15
Nodes (12): Categories, Dark Mode, File Organization, Layer 1: Primitive Tokens, Layer 2: Semantic Tokens, Layer 3: Component Tokens, Layer Overview, Migration from Flat Tokens (+4 more)

### Community 71 - "Primitive Tokens"
Cohesion: 0.17
Nodes (11): Border Radius, Color Scales, Gray Scale, Motion / Duration, Primary Colors (Blue), Primitive Tokens, Shadows, Spacing Scale (+3 more)

### Community 72 - "Process"
Cohesion: 0.17
Nodes (11): 0. Design config — read it FIRST (gates everything below), 0a. Preflight — confirm Figma is connected, 0b. Preflight — confirm image generation is available, 1. INTAKE (headless workflow), 2. DESIGN (in-session — this is where you take control), 3. TICKETING + SUMMARY (headless workflow), 4. Report, Notes (+3 more)

### Community 73 - "The test-suite gate does not halt on a red"
Cohesion: 0.17
Nodes (12): A fail-open this closed on the way past, Across invocations, Configuration, Related, The cost, stated plainly, The distinction, again, The hole converting these exposed, The one retraction (+4 more)

### Community 74 - "`aiworks doctor` — what is missing, and the command that fixes it"
Cohesion: 0.17
Nodes (11): A doctor, not an installer, `aiworks doctor` — what is missing, and the command that fixes it, `aiworks fix`, and why `--fix` re-checks itself, How a check is scored, In a linked worktree, Selftest, The base check, and why it grades in two tiers, The `.env` rule (+3 more)

### Community 75 - "developer.md"
Cohesion: 0.18
Nodes (10): Bar, Bugs — diagnose before you fix (🛑 MUST DO, non-negotiable), Build commands — always via `scripts/dev.sh` (you are the only role that runs these), Inputs, Output language — resolve BEFORE writing (do this FIRST, before your role), PRD pipeline — pre-ticket bug/issue triage (sandbox, never commit), Prod data for a repro — the ONE sanctioned path (`/diagnosing-bugs` only), Standards (+2 more)

### Community 76 - "qa-planner.md"
Cohesion: 0.18
Nodes (10): Bug loop — one bug at a time, Delegation contract — the edges of this role, Grounding — a claim is measured, or it is handed back with the command that settles it, Handing off — ALWAYS via `/handoff`, Human-review directives, Output language — resolve BEFORE writing (do this FIRST, before your role), Planning policy — resolve `planning.*` before acting (both keys are local-first), Source of truth — the ticket (+2 more)

### Community 77 - "Core Visual Elements"
Cohesion: 0.18
Nodes (10): Color Palette, Colors, Core Visual Elements, Logo, Logo, Quick Checks, Typography, Typography (+2 more)

### Community 78 - "CIP Design Style Guide"
Cohesion: 0.18
Nodes (10): Bold Dynamic, CIP Design Style Guide, Classic Traditional, Color Psychology, Corporate Minimal, Fresh Modern, Luxury Premium, Modern Tech (+2 more)

### Community 79 - "PG Triage — staging + production"
Cohesion: 0.18
Nodes (10): Choosing the environment, Choosing the target, Output language — resolve BEFORE writing (do this FIRST), Persisting to a local repro (developer, `/diagnosing-bugs` only), PG Triage — staging + production, Preflight — is the MCP available?, Reporting, Safety — non-negotiable (+2 more)

### Community 80 - "QA sub-task creation"
Cohesion: 0.18
Nodes (10): 0. Establish parent context, 1. Choose which tools, 2. For each selected tool, author and create a sub-task, 3. Report, Authoring stance (instructions for you — DO NOT paste into the description), Create + link to parent (one adapter call), Description content (what goes into the ticket body), Output language — resolve BEFORE writing (do this FIRST) (+2 more)

### Community 81 - "Telemetry Triage"
Cohesion: 0.18
Nodes (10): Environments, Output language — resolve BEFORE writing (do this FIRST), Phase 1 — Frame the incident, Phase 2 — Pull the ground truth, Phase 3 — Build the timeline, locate the failure, Phase 4 — Root-cause finding — advisory/gate roles STOP HERE, Phase 5 — Apply the fix — CODE-OWNER ONLY (the developer), Relationship to `diagnosing-bugs` (+2 more)

### Community 82 - "Quick Reference"
Cohesion: 0.18
Nodes (11): 10. Charts & Data (LOW), 1. Accessibility (CRITICAL), 2. Touch & Interaction (CRITICAL), 3. Performance (HIGH), 4. Style Selection (HIGH), 5. Layout & Responsive (HIGH), 6. Typography & Color (MEDIUM), 7. Animation (MEDIUM) (+3 more)

### Community 83 - "Write Interactive Docs"
Cohesion: 0.18
Nodes (10): Bundled resources, Guardrails, Mode A — build a new doc, Mode B — update an existing doc, Output language — resolve BEFORE writing (do this FIRST), Plans vs. documents (the markdown contract & in-page approval), Publish to a shareable Artifact (gated), The bar (+2 more)

### Community 84 - "Thai register (address mode)"
Cohesion: 0.05
Nodes (39): Neither live file carries a comment, The workspace config files, Consequences, Headless workflows read config from a generated mirror, not the file, Rejected alternatives, Refinement (2026-07-17): `.md` is English, `.html` localizes, Rejected alternatives, Workspace output localization uses an English spine, not full translation (+31 more)

### Community 85 - "CLAUDE.md — {{ORG_NAME}} Organization workspace"
Cohesion: 0.20
Nodes (9): CLAUDE.md — {{ORG_NAME}} Organization workspace, Configuration (read these first), DO NOT, Language, compression and code, Named-agent requests, Notifications, Product, Provider adapters (+1 more)

### Community 86 - "cpo.md"
Cohesion: 0.20
Nodes (9): Bar, Design OS — your drafting studio (`design-os/`, per `@design-os/docs/usage.md`), How you evaluate every feature, Output formatting (PRD-ready), Output language — resolve BEFORE writing (do this FIRST, before your role), Roadmap you guard (4 phases + beyond), Team & collaboration, Voice & guiding principle (+1 more)

### Community 87 - "qa-runner.md"
Cohesion: 0.20
Nodes (9): Already-done short-circuit (check FIRST), Bar, Handing off — ALWAYS via `/handoff`, Human-review directives, Load suites — green is half the verdict, Output language — resolve BEFORE writing (do this FIRST, before your role), Source of truth — the planner's artifacts + the ticket, Step 0 — load your stance (always, first) (+1 more)

### Community 88 - "Caveman savings statusline"
Cohesion: 0.20
Nodes (9): 1. Statusline (required), 2. Auto-refresh on turn end (optional but recommended), Caveman savings statusline, Configuration, Files, How the numbers are sourced, Install, Notes (+1 more)

### Community 89 - "Git submodule conventions"
Cohesion: 0.20
Nodes (8): You are inside a git submodule checkout, …but READING one is fine, and so is a checkout that proves something, Detect it before you edit — two angles, check both, Git submodule conventions, Inside a dev-cycle run, a pointer move is the ONE sanctioned write — and it does not wait for a merge, It is enforced, not remembered, Redirect to the primary clone, The rule: never develop inside a submodule checkout

### Community 90 - "Brand"
Cohesion: 0.20
Nodes (9): Brand, Brand Sync Workflow, Quick Start, References, Routing, Scripts, Subcommands, Templates (+1 more)

### Community 91 - "Slide Strategies"
Cohesion: 0.20
Nodes (9): Common Structures, Duarte Sparkline Pattern, Matching Strategy to Context, Product Demo (6 slides), Sales Pitch (9 slides), Search Commands, Slide Strategies, Strategy Selection (+1 more)

### Community 92 - "Component Tokens"
Cohesion: 0.20
Nodes (9): Alert Tokens, Badge Tokens, Button Tokens, Card Tokens, Component Tokens, Dialog/Modal Tokens, Input Tokens, Table Tokens (+1 more)

### Community 93 - "Prod Redis Triage"
Cohesion: 0.20
Nodes (9): Choosing the target, Output language — resolve BEFORE writing (do this FIRST), Preflight, Prod Redis Triage, Reporting, Reproducing locally, Safety — non-negotiable, The keyspace (+1 more)

### Community 94 - "Slide Strategies"
Cohesion: 0.20
Nodes (9): Common Structures, Duarte Sparkline Pattern, Matching Strategy to Context, Product Demo (6 slides), Sales Pitch (9 slides), Search Commands, Slide Strategies, Strategy Selection (+1 more)

### Community 95 - "to-prd/SKILL.md"
Cohesion: 0.20
Nodes (9): Further Notes, Implementation Decisions, Out of Scope, Output language — resolve BEFORE writing (do this FIRST), Problem Statement, Process, Solution, Testing Decisions (+1 more)

### Community 96 - "Diagrams — pick the kind that fits the content"
Cohesion: 0.20
Nodes (9): Choose by the shape of the idea, Diagrams — pick the kind that fits the content, Don't let it break — the two rules that bite, Keep diagrams legible, Make the diagram interactive, Recipes, The export island (so the diagram survives export), Theming the diagram (+1 more)

### Community 97 - "Worktree GC — reclaiming disk without serializing builds"
Cohesion: 0.20
Nodes (9): Automatic sweeping, Classification, Git safety, Source of truth, The parallelism invariant, The rebuild cost, answered without a lock, The UI-Delete leftovers get their own job, What leaks, and why (+1 more)

### Community 98 - "Kubernetes triage adapter"
Cohesion: 0.20
Nodes (9): Admin runbook — one cluster at a time, Checks, CRD drift, Kubernetes triage adapter, Production, Targets are derived, never configured, Teammate setup, What it creates (+1 more)

### Community 99 - "Test standards"
Cohesion: 0.20
Nodes (8): Coding standards, **MUST DO**, **MUST NOT DO**, Case count — **MUST DO**, Date/time — **MUST DO**, File structure — **MUST DO**, **MUST NOT DO**, Test standards

### Community 100 - "Test standards"
Cohesion: 0.20
Nodes (8): Coding standards, **MUST DO**, **MUST NOT DO**, Case count — **MUST DO**, Date/time — **MUST DO**, File structure — **MUST DO**, **MUST NOT DO**, Test standards

### Community 101 - "ceo.md"
Cohesion: 0.22
Nodes (8): Bar, `/handoff` discipline, Hard rule — conductor only, never the hands, Inputs, Keep the technical group parallel & idle-free, Output language — resolve BEFORE writing (do this FIRST, before your role), Team & collaboration, What you do

### Community 102 - "code-reviewer.md"
Cohesion: 0.22
Nodes (8): Bar, Inputs, Main skill, Output language — resolve BEFORE writing (do this FIRST, before your role), Over-engineering is a Standards finding, Review level, Team & collaboration, Workflow

### Community 103 - "development-planner.md"
Cohesion: 0.22
Nodes (8): Delegation contract — the edges of this role, Human-review directives, Output, Output language — resolve BEFORE writing (do this FIRST, before your role), Planning policy — resolve `planning.*` before acting (both keys are local-first), Project context — authoritative, read it, Steps, Talking to other agents — `/handoff` first (non-negotiable)

### Community 104 - "performance-engineer.md"
Cohesion: 0.22
Nodes (8): Bar, Commands — profile through the repo's own harness, Output language — resolve BEFORE writing (do this FIRST, before your role), Review level, Skills, Team & collaboration, What you do, Your threads — tag them, then resolve them

### Community 105 - "Ponytail"
Cohesion: 0.22
Nodes (8): Boundaries, Intensity, Output, Persistence, Ponytail, Rules, The ladder, When NOT to be lazy

### Community 106 - "Report test results"
Cohesion: 0.22
Nodes (8): 1. Resolve the ticket and gather the inputs, 2. Determine the results — `scripts/dev.sh why test`, 3. Collect the evidence — `scripts/dev.sh artifacts`, 4. Build the human-readable report, 5. Post it to the ticket — with the evidence in the comment, 6. Requirements & report back, Output language — resolve BEFORE writing (do this FIRST), Report test results

### Community 107 - "Prerequisites"
Cohesion: 0.22
Nodes (9): Available Domains, Available Stacks, Common Sticking Points, Output Formats, Pre-Delivery Checklist, Prerequisites, Query Strategy, Search Reference (+1 more)

### Community 108 - "Update a ticket"
Cohesion: 0.22
Nodes (8): 1. Resolve the ticket, 2. Properties & status — `upsert-ticket-details.sh`, 3. Comments — `add-ticket-comment.sh`, 4. Attachments — show the file, don't just upload it, 5. Preview, then write, 6. Requirements & failures, Output language — resolve BEFORE writing (do this FIRST), Update a ticket

### Community 109 - "Decision"
Cohesion: 0.22
Nodes (9): ADR 0017 — Triage tunnels are declared beside the DSN, Consequences, Context, Decision, Enumeration hazard, Port safety, The prod gate ordering, Why the framework only port-forwards (+1 more)

### Community 110 - "The review loop does not halt on a finding"
Cohesion: 0.22
Nodes (9): Across invocations, Configuration, Related, The cost, stated plainly, The distinction the old code did not make, The review loop does not halt on a finding, The sanctioned "cannot", What each former halt became (+1 more)

### Community 111 - "Cloud Monitoring triage adapter"
Cohesion: 0.22
Nodes (8): Checks, Cloud Monitoring triage adapter, Related, Targets are configured, not derived, The catalog, The correctness contract, Where it sits among the triage servers, Why it shares the Kubernetes identity

### Community 112 - "scripts/redis — production Redis, read-only"
Cohesion: 0.22
Nodes (8): Local repro — `replay_shape.py`, Safety model (all layers are client-side — deliberately), scripts/redis — production Redis, read-only, Setup (one-time, per machine), Targets, The production gate, Tools, Verifying it

### Community 113 - "graphic-designer.md"
Cohesion: 0.25
Nodes (7): Asset rules, Bar, Company constraints — budget-tight, follow STRICTLY, Delivery to Figma (the Assets page), Main skill, Return contract (per asset — be honest, never paper over a gap), Step 0 — availability gate (do this BEFORE accepting an asset request)

### Community 114 - "guardian-engineer.md"
Cohesion: 0.25
Nodes (7): Bar, Commands, Output language — resolve BEFORE writing (do this FIRST, before your role), Scope & context, Team & collaboration, What you do, Your threads — tag them, then resolve them

### Community 115 - "oncall.md"
Cohesion: 0.25
Nodes (7): Bar, Handoff & tickets, How you work — one case timeline, five sources, one case file (or the repair itself), Output language — resolve BEFORE writing (do this FIRST, before your role), Safety — non-negotiable (production data), The rule everything else serves, When you are invoked

### Community 116 - "One workflow, one slash entry — authored scripts live under `.claude/workflows/src/`"
Cohesion: 0.40
Nodes (4): Consequences, Context, Decision, One workflow, one slash entry — authored scripts live under `.claude/workflows/src/`

### Community 117 - "Case file"
Cohesion: 0.25
Nodes (7): Case file, Step 1 — Name the case, Step 2 — Load the organization's template, Step 3 — Receipts before prose, Step 4 — Write the case file, Step 5 — The runbook, Step 6 — Publish by form

### Community 118 - "Estimating a ticket"
Cohesion: 0.25
Nodes (7): Estimating a ticket, Flow, Guardrails, Low-confidence mode, Output, Output language — resolve BEFORE writing (do this FIRST), Re-estimation

### Community 119 - "Kubernetes triage (read-only)"
Cohesion: 0.25
Nodes (7): Always start here, Kubernetes triage (read-only), Prod output is fingerprinted, Recipes, The identity is not yours, Tools, When you are done

### Community 120 - "Load-test baseline gate"
Cohesion: 0.25
Nodes (7): Arm check (step 0), Load-test baseline gate, On a fail, Output language — resolve BEFORE writing (do this FIRST), Receipt, Steps, The three verdicts

### Community 121 - "automation-plan-template.md"
Cohesion: 0.25
Nodes (7): Implementation checklist (in order), Page Objects, Project wiring & prerequisites, Scenario → automation, Selectors to confirm, Specs, {{ TC001 }} — {{ Automatable | Partial | Manual-only }}

### Community 122 - "Repair script"
Cohesion: 0.25
Nodes (7): Repair script, Step 1 — Fix the defect and the entity set, Step 2 — Load the organization's ladder, Step 3 — Pick the rung, with the receipt, Step 4 — Generate, Step 5 — Hand over, The ladder

### Community 123 - "`parse_agent_usage.py` — every agent, auto-discovered"
Cohesion: 0.25
Nodes (7): Examples, Flags, Monitoring a single agent run (not a team), `parse_agent_usage.py` — every agent, auto-discovered, `parse_team_usage.py` — one Agent Team mission, per role, Reading the columns (both scripts), Token-usage parsers

### Community 124 - "Summarize Team Performance"
Cohesion: 0.25
Nodes (7): Finish by appending the usage table to the summary file, How to run, Notes, Reading the output — important caveats, Summarize Team Performance, What is a "mission"?, When to use

### Community 125 - "Summarize Workflow Performance"
Cohesion: 0.25
Nodes (7): Finish by appending the usage table to the summary file, How to run, Notes, Reading the output — important caveats (identical to the team skill), Summarize Workflow Performance, What is a "run"?, When to use

### Community 126 - "UI/UX Pro Max - Design Intelligence"
Cohesion: 0.25
Nodes (7): How to Use, Must Use, Recommended, Rule Categories by Priority, Skip, UI/UX Pro Max - Design Intelligence, When to Apply

### Community 127 - "Cloud Monitoring triage shares the read-only identity, and owns its correctness contract"
Cohesion: 0.25
Nodes (7): Cloud Monitoring triage shares the read-only identity, and owns its correctness contract, Consequences, Discovery over a hand-maintained catalog, One identity for every deployed-GCP read, Targets are configured, not derived, The correctness contract belongs to the server, Why there is a fourth triage server at all

### Community 128 - "Deferred scope does not stop a run"
Cohesion: 0.25
Nodes (8): Consequences, Deferred scope does not stop a run, No ticket is filed, The cost we accepted, and what pays for it, The floor, What that cost, Why not simply proceed on `partial`, Why not stop at the PR, short of the gate

### Community 129 - "dev-cycle keeps its own run state"
Cohesion: 0.25
Nodes (8): Addendum — an unresolved `Human:` directive is the one comment a resume must see, Addendum — the `planned` row now skips, guarded by a ticket fingerprint, Addendum — upstream degrade, per-suite gate rows, and a fingerprint without the comment count, Consequences, dev-cycle keeps its own run state, What it is not, What that cost, Why it qualifies on all three counts

### Community 130 - "Human-review comments — the `Human:` convention"
Cohesion: 0.25
Nodes (8): Authority — blocking, top-priority, Human-review comments — the `Human:` convention, Mechanics — fix, reply, resolve (the agent resolves), Routing — classify each directive by what it asks for, Two kinds of `Human:` comment — directive vs disposition, When a human resolves a thread and writes nothing, Where they live, Who picks a directive up — including on a PR/MR that is already approved

### Community 131 - "Image generation (graphic-designer asset pipeline)"
Cohesion: 0.25
Nodes (7): Config: the `image_generation:` block (default OFF), Cost, How the pipeline fails loud (no silent placeholders), Image generation (graphic-designer asset pipeline), Setup (one-time, per machine), The backend: `mcp-image`, Verify

### Community 132 - "The load-test gate — equal-or-better, or it does not ship"
Cohesion: 0.25
Nodes (8): Metrics, Never fail open, On a fail: attribute first, fix second, Reading the result, The baseline cache, The load-test gate — equal-or-better, or it does not ship, Three verdicts, and why the third exists, What arms it

### Community 133 - "PII provenance — redact what PRODUCTION gave us, and only that"
Cohesion: 0.25
Nodes (7): Honest limits, Knobs, Pieces, PII provenance — redact what PRODUCTION gave us, and only that, The vault, What always survives, What happens on a hit

### Community 134 - "The review ledger — a finding is raised once, and resolved visibly"
Cohesion: 0.25
Nodes (8): 1. The threads are the finding set, 2. The ledger rows record what a thread cannot, 3. Resolving is part of the fix, 4. Consequences for the first pass, 5. The approval tick is the review's last act — and its third record, 6. The loop does not halt on a finding — it records what it cannot close, The one thing a frozen gate does not outrank: a `Human:` directive, The review ledger — a finding is raised once, and resolved visibly

### Community 135 - "Working from the workspace root"
Cohesion: 0.50
Nodes (4): Ignore the files, never the directory, The injector — the Claude Code half of the same problem, Two kinds of slice, because Cursor has two triggers, Working from the workspace root

### Community 136 - "scripts/db — deployed Postgres (staging + production), read-only"
Cohesion: 0.25
Nodes (7): Environments and targets, Repro seeding — `prod_repro_seed.py`, Safety model (layered), scripts/db — deployed Postgres (staging + production), read-only, Setup (one-time, per machine), Tools, Verifying it

### Community 137 - "product-owner.md"
Cohesion: 0.29
Nodes (6): Bar, Consistency, Inputs, Output language — resolve BEFORE writing (do this FIRST, before your role), Team & collaboration, What you do

### Community 138 - "ux-ui-planner.md"
Cohesion: 0.29
Nodes (6): Inputs, Output, Output language — resolve BEFORE writing (do this FIRST, before your role), Plan contents, Steps, Team & collaboration

### Community 139 - "Workspace coding style"
Cohesion: 0.29
Nodes (6): 1. Code tells the story — no body comments, 2. Storytelling — names carry the meaning, 3. flow → side-effect → pure, 4. ≤ 500 lines per file, Example, Workspace coding style

### Community 140 - "Installing Debug Adapters"
Cohesion: 0.29
Nodes (6): Go — Delve, Installing Debug Adapters, Known Gotchas, Node.js/TypeScript — js-debug, Python — debugpy, Rust/C/C++ — lldb-dap

### Community 141 - "Slides Reference"
Cohesion: 0.29
Nodes (6): Key Features, Knowledge Base, Slides Reference, Usage, When to Use, Workflow

### Community 142 - "HTML Slide Template"
Cohesion: 0.29
Nodes (6): Animation Classes, Background Images, Base Structure, Chart.js Integration, CSS Variables Reference, HTML Slide Template

### Community 143 - "Diagramming a ticket"
Cohesion: 0.29
Nodes (6): Budget, Diagramming a ticket, Flow, Gate — check before doing anything else, Output, Output language — this is structural, not prose

### Community 144 - "Open PR"
Cohesion: 0.29
Nodes (6): How media is hosted (per provider), Open PR, Output, Output language — resolve BEFORE writing (do this FIRST), Preconditions, Steps

### Community 145 - "Root cause in a deployed environment"
Cohesion: 0.29
Nodes (6): Reading a cold scene, Root cause in a deployed environment, Step 1 — Base rate, before any hypothesis, Step 2 — Ledger, at least two entries, Step 3 — Discriminator, Step 4 — Verdict

### Community 146 - "HTML Slide Template"
Cohesion: 0.29
Nodes (6): Animation Classes, Background Images, Base Structure, Chart.js Integration, CSS Variables Reference, HTML Slide Template

### Community 147 - "Localization — English + Thai (display-only)"
Cohesion: 0.29
Nodes (6): Limits (say them if they bite), Localization — English + Thai (display-only), Translate: `data-th` on leaf elements, Turn it on, Verify, What the reader/agent gets

### Community 148 - "Theming — match the project, never plain black & white"
Cohesion: 0.29
Nodes (6): Accessibility (non-negotiable), Consistency checklist, Step 1 — detect the project's existing style (preferred), Step 2 — map detected values onto the template tokens, Step 3 — if nothing exists, generate a fitting palette, Theming — match the project, never plain black & white

### Community 150 - "Triage MCPs cover every deployed environment; only production is gated"
Cohesion: 0.29
Nodes (5): Staging is not the thing that needs authorizing, Staging Postgres gets a one-instance shortcut, and its data is not PII, The names lost their `prod_` prefix, The production gate lives inside the servers, not in the registration, Triage MCPs cover every deployed environment; only production is gated

### Community 151 - "Kubernetes triage authenticates as a separate read-only identity, not as you"
Cohesion: 0.29
Nodes (6): A dedicated identity, obtained by impersonation, Kubernetes triage authenticates as a separate read-only identity, not as you, Production reuses `triage.prod`, Targets are derived from the cluster, not from a config or an alias, The credential problem, The MCP is only the only path if the shell is closed

### Community 152 - "Workspace bring-up never bootstraps deployed-environment access"
Cohesion: 0.29
Nodes (6): A bug this surfaced, Doctor takes over the scoring, split across its two tiers, The consequence, stated rather than discovered, What sync prints instead, and why the two halves differ, Why bring-up is the wrong place for either, Workspace bring-up never bootstraps deployed-environment access

### Community 155 - "A repo whose criteria already hold is finished, not stalled"
Cohesion: 0.29
Nodes (7): A repo whose criteria already hold is finished, not stalled, Related, The bar goes up, not down, Three places that read "finished" as "broken", What is deliberately NOT changed, What it does to the run, Why the empty-branch rule could not tell the difference

### Community 156 - "The build does not stop at the first partial"
Cohesion: 0.29
Nodes (7): Configuration, Related, The build does not stop at the first partial, The cost, stated plainly, What the continuation is, and is not, What this does NOT make true, Why ADR 0027 missed it

### Community 157 - "Context handoff — an agent hands off to itself before the ceiling"
Cohesion: 0.29
Nodes (6): Context handoff — an agent hands off to itself before the ceiling, Knobs, The loop, What the model cannot do, and what stands in for it, Why, Workflows — where this actually pays

### Community 158 - "Diagram generation (ticket-clarification visuals)"
Cohesion: 0.29
Nodes (6): Attaching to a ticket, Config: the `diagrams:` block (default OFF), Diagram generation (ticket-clarification visuals), The backend: mermaid.ink / mermaid.live, Which diagram type to pick, Why this is gated at all

### Community 159 - "Issue tracker conventions"
Cohesion: 0.29
Nodes (6): A ticket is a record, not a transcript, Issue tracker conventions, Notes, Status lifecycle, The adapter is the only entry point, This workspace's settings

### Community 160 - "Code minimalism (ponytail)"
Cohesion: 0.29
Nodes (7): Code minimalism (ponytail), Commands, How it reaches each spawn path, Installing it, The ladder, Where it stops, Who gets it, and why not everyone

### Community 161 - "Observability adapter"
Cohesion: 0.29
Nodes (6): Base rate first, Notes, Observability adapter, Provider interface (`lib.sh`), Setup, Usage

### Community 162 - "PDF adapter — HTML/Markdown → PDF (image + Mermaid illustrations)"
Cohesion: 0.29
Nodes (6): Browser resolution, Cloud / Docker, Files, How it works, Notes, PDF adapter — HTML/Markdown → PDF (image + Mermaid illustrations)

### Community 163 - "cto.md"
Cohesion: 0.33
Nodes (5): Bar, Inputs, Output language — resolve BEFORE writing (do this FIRST, before your role), Team & collaboration, What you do

### Community 164 - "documentor.md"
Cohesion: 0.33
Nodes (5): Bar, Inputs, Output language — resolve BEFORE writing (do this FIRST, before your role), Team & collaboration, What you do

### Community 165 - "ux-ui-designer.md"
Cohesion: 0.33
Nodes (5): Bar, Inputs, Output language — resolve BEFORE writing (do this FIRST, before your role), Team & collaboration, What you do

### Community 166 - "caveman/SKILL.md"
Cohesion: 0.33
Nodes (5): Auto-Clarity, Boundaries, Intensity, Persistence, Rules

### Community 167 - "Clarifying a ticket"
Cohesion: 0.33
Nodes (5): Clarifying a ticket, Flow, Modes (detect from how you were called), Output, Output language — resolve BEFORE writing (do this FIRST)

### Community 168 - "Advanced Debugging Techniques"
Cohesion: 0.33
Nodes (5): Advanced Debugging Techniques, Bisecting Loops (Wolf Fence), Concurrency Bugs, Digging Into Complex State, When the Program Hangs

### Community 169 - "Karpathy Guidelines"
Cohesion: 0.33
Nodes (5): 1. Think Before Coding, 2. Simplicity First, 3. Surgical Changes, 4. Goal-Driven Execution, Karpathy Guidelines

### Community 170 - "report-template.md"
Cohesion: 0.33
Nodes (5): Coverage, Failures, Results, Run history, {{ TC00n }} — {{ failing scenario title }}

### Community 171 - "Slides"
Cohesion: 0.33
Nodes (5): References (Knowledge Base), Routing, Slides, Subcommands, When to Use

### Community 172 - "Pre-Delivery Checklist"
Cohesion: 0.33
Nodes (6): Accessibility, Interaction, Layout, Light/Dark Mode, Pre-Delivery Checklist, Visual Quality

### Community 173 - "How to Use This Skill"
Cohesion: 0.33
Nodes (6): How to Use This Skill, Step 1: Analyze User Requirements, Step 2: Generate Design System (REQUIRED), Step 2b: Persist Design System (Master + Overrides Pattern), Step 3: Supplement with Detailed Searches (as needed), Step 4: Stack Guidelines

### Community 174 - "Editing an existing doc (Mode B — partial update)"
Cohesion: 0.33
Nodes (5): Common edits, Editing an existing doc (Mode B — partial update), How the doc is structured (so you can find things), The four rules, When the existing doc wasn't made by this skill

### Community 176 - "A reviewed-but-unresolved repo still gets the gate"
Cohesion: 0.33
Nodes (6): A reviewed-but-unresolved repo still gets the gate, Advisory means full work, no authority, Related, The bug this nearly shipped, The cost, stated plainly, When, exactly

### Community 177 - "A submodule pin needs a pushed commit, not a merge"
Cohesion: 0.33
Nodes (6): A submodule pin needs a pushed commit, not a merge, Related, Reordering was already tried, and it was not enough, The cost, stated plainly, The pointer is re-aimed before anything lands, What actually changed

### Community 178 - "The local Harness set drives sync, and sync never removes a projection"
Cohesion: 0.33
Nodes (5): Consequences, Context, Decision, Rejected, The local Harness set drives sync, and sync never removes a projection

### Community 179 - "Figma (design authoring & reading convention)"
Cohesion: 0.33
Nodes (5): 1. `design.enabled` — the workspace-wide Figma switch (default **OFF**), 2. `design.figma_file_key` — the org's ONE canonical design file, 3. Per-role behavior, 4. How it's enforced, Figma (design authoring & reading convention)

### Community 181 - "scripts/stagehand"
Cohesion: 0.33
Nodes (5): Adding a trigger, Run it by hand, scripts/stagehand, Test, Turning it off

### Community 182 - "Tracker adapter"
Cohesion: 0.33
Nodes (5): Layout, Notes / limitations, Setup, Tracker adapter, Usage

### Community 183 - "Brand Guidelines Template"
Cohesion: 0.40
Nodes (4): Brand Guidelines Template, Document Structure, Extractable Fields, Usage

### Community 184 - "monitoring-triage/SKILL.md"
Cohesion: 0.40
Nodes (4): Boundaries, Method, The division of labour, What a saturated resource looks like

### Community 185 - "Notify (review request)"
Cohesion: 0.40
Nodes (4): Notify (review request), Result, When NOT to use, When to use

### Community 186 - "self-control-gitflow"
Cohesion: 0.40
Nodes (4): FINISH — PR/MR + self squash-merge (only after ALL tests pass), Notes, self-control-gitflow, START — branch before coding

### Community 187 - "Ticket kickoff"
Cohesion: 0.40
Nodes (4): Input, Output, Steps, Ticket kickoff

### Community 188 - "Common Rules for Professional UI"
Cohesion: 0.40
Nodes (5): Common Rules for Professional UI, Icons & Visual Elements, Interaction (App), Layout & Spacing, Light/Dark Mode Contrast

### Community 189 - "Example Workflow"
Cohesion: 0.40
Nodes (5): Example Workflow, Step 1: Analyze Requirements, Step 2: Generate Design System (REQUIRED), Step 3: Supplement with Detailed Searches (as needed), Step 4: Stack Guidelines

### Community 191 - "Cursor gets a generated mirror of the Claude config, built from symlinks"
Cohesion: 0.40
Nodes (5): A root session gets each repo re-globbed, Cursor gets a generated mirror of the Claude config, built from symlinks, Mirror rather than rely on Cursor's third-party import, Symlinks, not copies — the frontmatter carries both vocabularies, The hook shim is the one deliberate copy

### Community 193 - "Organization knowledge lives in the script repo, not in the framework"
Cohesion: 0.40
Nodes (4): Consequences, Organization knowledge lives in the script repo, not in the framework, The binding is config for the repo, convention for the filenames, The split, and where the seam sits

### Community 194 - "0023-agent-harnesses-project-from-claude-canonical-source.md"
Cohesion: 0.40
Nodes (3): Agent harnesses project from the Claude canonical source, Consequences, Considered options

### Community 195 - "A ticket is a record, not a transcript"
Cohesion: 0.40
Nodes (5): A ticket is a record, not a transcript, Related, Rules a writer must follow, The decision, What it was

### Community 196 - "An agent hands off to itself before the ceiling"
Cohesion: 0.40
Nodes (4): An agent hands off to itself before the ceiling, Consequences, Context, Decision

### Community 197 - "Declared plugins install at project scope, and every copy is kept current"
Cohesion: 0.40
Nodes (4): Consequences, Context, Decision, Declared plugins install at project scope, and every copy is kept current

### Community 198 - "Output compression (caveman)"
Cohesion: 0.40
Nodes (5): How it reaches each spawn path, In Codex the skill is `$caveman`, In Cursor the skill is `/caveman`, Output compression (caveman), The boundary: compression is an OUTPUT rule

### Community 199 - "Obsidian — shared vault settings for the workspace meta-repo"
Cohesion: 0.40
Nodes (4): Commit vs keep local, Gotchas, Obsidian — shared vault settings for the workspace meta-repo, What `aiworks sync` does

### Community 200 - "Tunnel sidecars (optional — for managed Postgres behind a VPC)"
Cohesion: 0.40
Nodes (5): Declaring a tunnel, How it works, Port-in-use behaviour, Prerequisites, Tunnel sidecars (optional — for managed Postgres behind a VPC)

### Community 201 - "Notify adapter"
Cohesion: 0.40
Nodes (4): Auth (Slack), Layout, Notify adapter, Where it's used

### Community 202 - "VCS adapter"
Cohesion: 0.40
Nodes (4): Auth, Layout, Notes, VCS adapter

### Community 203 - "Apply human review"
Cohesion: 0.50
Nodes (3): Apply human review, Output language — resolve BEFORE writing (do this FIRST), Steps

### Community 204 - "Clarified ticket templates"
Cohesion: 0.50
Nodes (3): Bug, Clarified ticket templates, Task / Story / Improvement

### Community 205 - "coding-feature/SKILL.md"
Cohesion: 0.50
Nodes (3): Observations, Read first — the repo's own knowledge (authoritative), Steps

### Community 206 - "Decomposition piece-spec templates"
Cohesion: 0.50
Nodes (3): Decomposition piece-spec templates, Epic summary (N >= 4 split shape), Piece — Task / Story / Improvement

### Community 207 - "test-plan-template.md"
Cohesion: 0.50
Nodes (3): TC001 — {{ Short descriptive title }}, TC002 — {{ Short descriptive title }}, TC006 — {{ Short descriptive title }}

### Community 208 - "QA sub-task — worked example"
Cohesion: 0.50
Nodes (3): Example (E2E), QA sub-task — worked example, The pattern is universal

### Community 209 - "Vendored plugin skills — where they came from"
Cohesion: 0.50
Nodes (3): Keeping the copies honest, Vendored plugin skills — where they came from, Why a copy at all

### Community 211 - "A cross-repo finding escalates instead of looping"
Cohesion: 0.50
Nodes (4): A cross-repo finding escalates instead of looping, Consequences, Context, Decision

### Community 212 - "A passed gate is recorded, not re-derived"
Cohesion: 0.50
Nodes (4): A passed gate is recorded, not re-derived, The one carve-out: a declared upstream that moved, What we accept in exchange, Why it qualifies on all three counts

### Community 213 - "Diagram adapter"
Cohesion: 0.50
Nodes (3): Adding a self-hosted provider later, Backend: mermaid.ink / mermaid.live, Diagram adapter

### Community 216 - "The run ticks its own approval; the merge stays human"
Cohesion: 0.67
Nodes (3): The run ticks its own approval; the merge stays human, What it buys, What this costs

### Community 217 - "The run's base is state, and the PR/MR is asserted against it"
Cohesion: 0.67
Nodes (3): Related, The run's base is state, and the PR/MR is asserted against it, What this costs

## Knowledge Gaps
- **1807 isolated node(s):** `Output language — resolve BEFORE writing (do this FIRST, before your role)`, `Hard rule — conductor only, never the hands`, `Team & collaboration`, ``/handoff` discipline`, `Keep the technical group parallel & idle-free` (+1802 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1944 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `scripts/db — deployed Postgres (staging + production), read-only` connect `scripts/db — deployed Postgres (staging + production), read-only` to `Tunnel sidecars (optional — for managed Postgres behind a VPC)`?**
  _High betweenness centrality (0.004) - this node is a cross-community bridge._
- **Why does `Retro — a four-repo ticket that took seven `dev-cycle` invocations` connect `2. Root causes, and which are fixed` to `CONTEXT.md`?**
  _High betweenness centrality (0.002) - this node is a cross-community bridge._
- **Why does `Working this workspace from Cursor` connect `Working this workspace from Cursor` to `Working from the workspace root`, `ponytail.md`?**
  _High betweenness centrality (0.002) - this node is a cross-community bridge._
- **What connects `Output language — resolve BEFORE writing (do this FIRST, before your role)`, `Hard rule — conductor only, never the hands`, `Team & collaboration` to the rest of the system?**
  _1807 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Headroom — input-side context compression` be split into smaller, more focused modules?**
  _Cohesion score 0.08695652173913043 - nodes in this community are weakly interconnected._
- **Should `aiworks-dispatch — Slack `@bot` → Superset on-demand Claude` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._
- **Should `Resuming a workflow after the config changed` be split into smaller, more focused modules?**
  _Cohesion score 0.06451612903225806 - nodes in this community are weakly interconnected._