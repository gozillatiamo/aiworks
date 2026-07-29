# AI Workspace

The bluePi OFB workspace for running a **team of Claude agents** across every OFB repo: one
command takes a Jira ticket through the whole delivery cycle. This is the meta-repo — the
product repos clone into it but stay independent. This glossary is the workspace's ubiquitous
language; each term links to its canonical home where a fuller one exists.

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
`gh`/`glab`/Jira/Slack directly, so the provider is swappable in one place.
_Avoid_: wrapper, integration

**Provider**:
The concrete tool behind an adapter — `gitlab`, `jira`, `slack` — selected in
`workspace.config.yaml`.

**vcs** / **tracker** / **notify**:
The three adapter families: pull/merge requests, tickets, and chat notifications.

**voice**:
The adapter that makes the workspace speak and listen (`scripts/voice/`) — a spoken
acknowledgement per prompt, a closing line on every finished turn, a voice note on Slack,
hold-to-dictate. `th`-only and off by default, per person. Full doc: `docs/agents/voice.md`.

**Sunmi** (ซันมี่):
The assistant's spoken name, used by the summarizer and (deferred) as the wake word.

**closing line**:
The spoken result at the end of a turn. Every finished turn gets one — the ack says what is
starting, this says what came out of it. `voice.autoplay.milestone_every_turn: false` reverts to
tag-only.

**chattiness**:
`voice.autoplay.chattiness: terse | balanced | chatty | max` — how MUCH the ack and closing line say,
never whether they speak. `terse` is the length the feature shipped with; `balanced` adds a softener,
a short reaction word and the second fact; `chatty` adds the third fact and the follow-through; `max`
adds the fourth, narrates the STEPS in the order they happen (the only level allowed to — the others
forbid it) and turns on the [[step narrator]] so the turn is described while it runs. The budget is a
ceiling, not a quota, and bad news keeps the plain register at every level.
`aiworks voice audition "…"` speaks all four.

**step narration**:
`voice.autoplay.narrate`, `chattiness: max` only — one spoken line per tool call, taken from the
assistant's OWN prose (the sentence it writes before reaching for a tool already says what it is doing
and what comes next), so it costs no summarizer call. Deduped per prose block, rate-floored, and
dropped after 12 s because its content goes off in seconds. It is the only mid-turn voice the feature
has: the timed heartbeat that used to fill that space was removed, because a clock cannot know whether
a step happened and says "still working" instead of what is being worked on.

**`VOICE:` tag**:
A `VOICE[group]: <one line>` line in a reply, which is how a turn writes its own closing line
(`green` · `red` · `ship` · `needs-you` · `incident`). Free and exact; without one the reply is
summarized instead, and the model gets the last word on the work.

**mute**:
`aiworks voice mute on` — one machine-global file that disables what THIS MACHINE says (and so its
spend). It does not reach the Slack voice note (`voice.notify_voice.enabled`, audio for the team) or
dictation. There is deliberately no automatic call detection: a browser meeting has no process to
find, so an auto-detect would cover some calls and silently miss others.

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

**Codegraph index** / **`-p` rule**:
The per-repo symbol/edge database under `<repo>/.codegraph/` (the marker is
`codegraph.db`, not the directory — `~/.codegraph/` is the CLI's own install dir).
Queried CLI-first: `query` `explore` `node` `callers` `callees` `impact` `affected`,
each of which **must** carry `-p $CLAUDE_PROJECT_DIR/<repo>` as an absolute path,
because a relative one resolves against a cwd that persists between tool calls and
makes codegraph answer from the wrong repo with exit 0. Enforced by
`pretool-codegraph-guard.sh`; kept current by `posttool-codegraph-sync.sh`.

## Editors

**Cursor layer**:
The `AGENTS.md` + `.cursor/` face of the same agent config, present at the workspace root and in
every repo. Generated by `aiworks cursor`, never hand-edited: symlinks back to the `.claude/`
files wherever the format already matches, plus the generated files. Workflows are the one
capability that does not cross. → [`docs/agents/cursor.md`](docs/agents/cursor.md) ·
[ADR-0004](docs/adr/0004-cursor-as-a-generated-mirror.md)

**Root slice** / **`.cursor/rules/repos/<repo>/`**:
One product repo's project instruction and rules, re-expressed so they work for a Cursor session
opened at the **workspace root** — every glob prefixed with the repo directory (`src/**` →
`<repo>/src/**`), so the rule fires on that repo's files and no other's. Generated by
`aiworks cursor` from `scripts/cursor/root-rule.awk`. Gitignored **by file**
(`.cursor/rules/repos/**/*.mdc`) — ignoring the *directory* makes Cursor prune the tree and lose
every rule in it.

**About card** / **`about.mdc`**:
The one rule per repo that carries a `description:` and **no** `globs:`, which is what makes it
Cursor's *Agent Requested* type — the agent pulls it in when a question is about that repo, with no
file of it open. The glob-scoped slices beside it only fire once a matching file is in context, so
the card is what answers "what is X's convention?" asked at the workspace root. Holds the repo's
`CLAUDE.md` inline plus an index of its rules, never their full text.

**Dual-key rule**:
A rule file whose frontmatter carries both `paths:` (what Claude Code scopes on) and `globs:`
(what Cursor scopes on), so one file serves both tools through a symlink. Each tool ignores the
key it does not know. `aiworks cursor` maintains the pair.

**Hook shim** / **`hook-shim.sh`**:
The translator that lets a Claude-shaped hook run under Cursor — event name, `Shell`↔`Bash`,
`Task`↔`Agent`, and the two context/deny output shapes. Copied into each repo (the one deliberate
copy in the Cursor layer) from `scripts/cursor/hook-shim.template.sh`, hash-checked by
`aiworks cursor --check`.
