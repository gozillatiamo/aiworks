# AI Workspace

The workspace for running a **team of Claude agents** across every product repo: one command
takes a ticket through the whole delivery cycle. This is the meta-repo — the product repos
clone into it but stay independent. This glossary is the workspace's ubiquitous language; each
term links to its canonical home where a fuller one exists.

## Language

**Term** definitions are one line each. When several words compete for one concept, the
canonical term is the heading and the rest are listed under `_Avoid_`.

## Orchestration

**Workflow**:
A deterministic, multi-agent orchestration script (`.claude/workflows/*.js`) run headless — it
fans out and sequences agents rather than reasoning turn-by-turn.

**dev-cycle**:
The end-to-end delivery Workflow for a single ticket: plan → build → PR/MR → review → test gate
→ merge → distribute. → `.claude/workflows/dev-cycle.js`

**prd** / **brd**:
Workflows that produce a Product / Business Requirements Document from a brief.

**Skill**:
A packaged, named instruction set (`.claude/skills/`) invoked to do one kind of task the repo's
way — the reusable procedure a Workflow or agent steps through.

**Agent** / **the agent team**:
The roles that run the pipeline (CEO, CPO, CTO, developer, code-reviewer, QA, …); each is a
`.claude/agents/*.md` definition reused by *both* the Agent tool and the headless Workflows.
→ `.claude/agents/`

**mani**:
The cross-repo CLI (`sync` · `list projects` · `exec` · `run`) driven by the generated
`mani.d/<product>.yaml` files.

**Superset**:
The parallel run harness (`.superset/`) that gives each ticket its own git **worktree** so
several `dev-cycle` runs proceed at once.

**Worktree**:
An isolated git checkout Superset provisions per ticket; git-ignored root state (`.env*`, the
personal local config) is symlinked into it.

**`Human:` review**:
The convention where a human reviewer's PR/MR comments prefixed `Human:` are blocking,
top-priority directives the agents auto-route and resolve. → `docs/agents/human-review.md`

## Providers

**Adapter**:
A script wrapper (`scripts/vcs` · `scripts/tracker` · `scripts/notify`) agents call *instead of*
`gh`/`glab`/Notion/Jira/Slack directly, so the provider is swappable in one place.
_Avoid_: wrapper, integration

**Provider**:
The concrete tool behind an adapter — `github`|`gitlab`, `jira`|`notion`, `slack` — selected in
`workspace.config.yaml`.

**vcs** / **tracker** / **notify**:
The three adapter families: pull/merge requests, tickets, and chat notifications.

## Repos

**Product**:
A top-level grouping in `workspace.config.yaml` (`products[]`) that owns a set of repos.

**Repo**:
A clone declared under `products[].repos[]` — its own independent clone with its own git
history and `CLAUDE.md`, git-ignored inside the workspace.
_Avoid_: submodule (a submodule is a read-only pointer to a repo that is *also* a primary clone
at the root — never develop in the submodule checkout; see `docs/agents/submodules.md`)

**kind**:
A repo's role tag — `backend`, `web-app`, `package`, `migration`, `test-suite`, `document`.

**green**:
A repo's own definition of "tests pass" (the `green:` string), e.g. "unit + integration tests
passed". The bar a change must clear before it ships.

**guardian_focus**:
The security concerns the guardian reviews for that repo — `secrets`, `data-protection`,
`injection attacks`.

**distribute**:
A repo's build-distribution target after merge (`none` when nothing is distributed).

**lang**:
A repo's primary stack — `rust`, `next.js`, `cypress`, `postgres`, … — steering which tooling
the agents use.

## Language

**English spine, Thai prose**:
The `language: th` model — write prose in Thai while keeping an English spine.
→ `docs/agents/language.md`, [ADR-0002](docs/adr/0002-workspace-output-localization.md)

**Spine bucket**:
One of the three categories kept English under `th` — **Structure** (titles, headings, labels,
enum values), **Code** (all code & comments, identifiers, commits, branch names), **Terms**
(technical/transliterated words, domain jargon, proper nouns).

**Collaboration surface**:
A working/communication surface — this chat, tickets, Slack, PR/MR discussion, plans shown to
you — which is **Thai** under `th`.
_Avoid_: working surface

**Committed-beside-code**:
A file committed into a repo (`docs/`, `README`, ADRs, PRD/BRD files committed into a product
repo) — always **English**, even under `th`, since it lives beside the code.

## Config

**`workspace.config.yaml`**:
The shared source of truth — providers, ticket prefix, status lifecycle, policies, and the
`products[].repos[]` registry. `aiworks sync` sets the workspace up from it.

**Personal override** / **`workspace.config.local.yaml`**:
A git-ignored, per-user file (analogue of `.claude/settings.local.json`) that overrides the
shared config at **runtime only**. → [ADR-0003](docs/adr/0003-personal-runtime-config-overrides.md)

**Config mirror** / **`AIWORKS:CONFIG` block**:
The generated `const` block `scripts/aiworks-config.sh` writes into `dev-cycle.js`/`prd.js` so
headless Workflows can read config; regenerated by `aiworks config`, never hand-edited.
→ [ADR-0001](docs/adr/0001-headless-workflow-config-mirror.md)

**Directive injection**:
Appending a `const` directive string (`LANGUAGE_DIRECTIVE`, `FIGMA_DIRECTIVE`) to an agent's
prompt — empty when the feature is off, so a default run is a no-op.
