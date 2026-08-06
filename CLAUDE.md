# CLAUDE.md — {{ORG_NAME}} Organization workspace

**Multi-repo workspace.** Nested repos are independent clones (own git
history, remote, `CLAUDE.md`) — read a repo's own `CLAUDE.md` first.

⚠️ **Before any git op:** `git rev-parse --show-toplevel` to confirm the
repo.

⚠️ **Never read `.env` / `.env.*` files** (any adapter's `scripts/{vcs,tracker,notify,
observability}/.env`, or any other secrets file matched by the workspace's blanket
`.env`/`.env.*` gitignore rule) — **except `.env.example`** templates, which are safe
(no real values). This means no `Read`, no `cat`/`grep`/`sed`/`head`/`tail` on them, no
`rtk read`/`rtk pipe`/`rtk diff` (rtk renames the reading verbs — the rtk hook rewrites
your own `cat X` into `rtk read X`, so the renamed form is *not* a way past this rule), and
no `bash -x`/`set -x` around code that sources one (tracing prints the sourced values
into the transcript/logs verbatim). To check a var is set without exposing it, use
`grep -q '^VAR=.\+' .env` (prints only a boolean via exit code), never a form that echoes
the value. Enforced by `pretool-env-guard.sh`, wired on `Bash` + `Read` at the workspace
root **and in every repo** (a repo-level session guards its own `.env` too).

**Discover repos:** declared under `products[].repos[]` in `workspace.config.yaml`
(the source of truth); `mani.yaml` imports the per-product `mani.d/<product>.yaml`
files generated from it by `scripts/aiworks`. `mani list projects` for the full list.

**Open in an IDE:** `scripts/aiworks` also generates a multi-root
`<workspace-basename>.code-workspace` from `products[].repos[]` (one folder root per repo +
the meta-repo root). Open the **file** (`cursor <workspace>.code-workspace`), not the folder,
so each product repo gets its own Source Control panel — opening the folder makes Git skip the
gitignored clones and only the meta-repo shows. ⚠️ **Cursor**: the `.code-workspace` gives you the
Source Control panels but does NOT configure the agent — Cursor reads no configuration from
subdirectories. `aiworks cursor` closes most of that gap by generating, at the workspace root,
`.cursor/rules/repos/<repo>/` — each repo's `CLAUDE.md` and rules re-globbed under `<repo>/` so they
fire on that repo's files only. A repo's own **skills** still do not reach a root session, so for
sustained work in one repo open that repo: `cd <repo> && cursor .`. See `docs/agents/cursor.md`.

**Cross-repo (`mani`):** `sync` (clone missing) · `list projects` ·
`exec --all '<cmd>'` · `run <task>`

## Configuration (read these first)

- `workspace.config.yaml` — the org's providers, ticket prefix, status lifecycle,
  branch model, output-language policy (`language` — `en` default | `th`), auto-merge
  policy, planning policy (`planning.auto_approve` /
  `planning.to_html`), notification policy (`notify.enabled` / `notify.channel`), design
  policy (`design.enabled` — the workspace-wide Figma switch, default OFF —
  `design.figma_file_key` / `design.page_naming`), image-generation policy
  (`image_generation.enabled` — default OFF — `image_generation.quality` /
  `image_generation.max_per_request`), diagram-generation policy (`diagrams.enabled` —
  default OFF — `diagrams.provider` / `diagrams.theme` / `diagrams.max_per_ticket`),
  deployed-env triage policy (`triage.enabled` — default **ON** — whether THIS machine carries the
  read-only triage MCPs `pg_triage` + `redis_triage`, reconciled by `aiworks sync` via
  `scripts/triage-mcp.sh`; and `triage.prod` — default OFF — whether it may reach **PRODUCTION**,
  enforced in-process by the servers so staging needs no opt-in; both read local-first —
  `docs/adr/0005`), and
  the `products[].repos[]` registry
  (repo URLs). The source of truth for this workspace; `scripts/aiworks sync` sets
  everything up from it. Personal, non-shared overrides go in the git-ignored
  `workspace.config.local.yaml` (analogue of `.claude/settings.local.json`; see
  `workspace.config.local.example.yaml`) — it overrides this file for everything read at
  runtime (chat, agents, interactive skills); the committed workflow mirror stays shared-only.
  ⚠️ **Both live config files carry NO comments** — they are data. Every explanation (what a key
  does, its options, a measurement, a tombstone for a removed key) belongs in
  `workspace.config.example.yaml` / `workspace.config.local.example.yaml`, in `docs/`, or in the
  owning script's README — the templates are the documentation surface, and the drift guard
  already requires every live key to appear there. This file is `@`-injected into EVERY session,
  so a comment in it is re-read on every turn forever. Enforced by
  `pretool-config-comment-guard.sh` (`Write`/`Edit`) + an advisory check in `aiworks config`;
  clean a file with `python3 scripts/lib/yaml_comments.py --write <file>`. See `docs/adr/0006`.
- `CONTEXT.md` — the workspace glossary (ubiquitous language: orchestration, providers, repos,
  language, config). One place to look up a term; each entry links to its fuller home.
- `docs/adr/` — architecture decision records: why the workspace is shaped as it is
  (`0001` config mirror, `0002` output localization, `0003` personal runtime overrides,
  `0004` the Cursor mirror, `0005` deployed-env triage + the production gate, `0006` the live
  config carries no comments, `0007` Kubernetes triage runs as a separate read-only identity).
- `docs/agents/cursor.md` — how this workspace runs under **Cursor**. Everything (project
  instruction, rules, skills, subagents, hooks, permissions, MCP, adapters) works there via a
  GENERATED mirror — `aiworks cursor` — built from symlinks back to the `.claude/` files, so
  there is one copy of each and no drift. Author on the Claude side, never hand-edit `.cursor/`.
  Two rules to remember: rule frontmatter must carry **both** `paths:` (Claude) and `globs:`
  (Cursor), and **workflows do not cross** — `dev-cycle`/`prd`/`brd` are Claude Code only.
- `docs/agents/language.md` — the output-language convention: `language: th` ⇒ **English
  spine, Thai prose** (prose in Thai; titles/headings/labels, all code + commits + branch
  names, and technical/domain terms stay English; code, checked-in repo docs, and **any `.md`
  file** never Thai — only `.html` renders/tickets/chat/Slack localize).
  Default `en` = unchanged. See the `## Language` section below.
- `docs/agents/issue-tracker.md` — how to read/write tickets (the tracker adapter,
  status names, id format).
- `docs/agents/human-review.md` — the `Human:` convention: a human reviewer's required
  changes, left as `Human:`-prefixed PR/MR review-thread comments, are blocking, top-priority
  directives the agents auto-route (code→developer, test→qa, scope→planner) and resolve. The
  `apply-human-review` skill drives them on demand ("take my review", no prefix needed).
- `docs/agents/image-generation.md` — how the graphic-designer generates assets
  (the `mcp-image` server + `GEMINI_API_KEY`), gated by `image_generation.enabled`
  (default OFF); the design/PRD phase fails loud when it's not set up rather than
  shipping placeholder art.
- `docs/agents/figma.md` — how every agent works with Figma: the `design.enabled`
  kill-switch (default OFF) and the canonical-file convention (`design.figma_file_key` —
  build product screens into ONE file on a new page per feature, never `create_new_file`).
- `docs/agents/diagram-generation.md` — how `/diagram-ticket` renders a Mermaid
  diagram and attaches it to a ticket (image + a mermaid.live edit link), gated by
  `diagrams.enabled` (default OFF); skipped quietly (not a fail-loud gate) when off,
  since a diagram is an enhancement to a ticket's spec, not a required deliverable.
- `docs/agents/loadtest-gate.md` — why a green load suite is only **half** a verdict. A repo
  declared `suite_kind: load` must also be **equal-or-better than the ticket's base branch**:
  the base scenario is run first, its run-to-run spread becomes the **noise floor**, and each
  metric's threshold is `max(loadtest.tolerance_pct, that floor)` — so a jittery laptop cannot
  manufacture a regression, and a floor wider than the effect returns **`unavailable`** (a loud
  skip; "the suite is green and whether it got slower is unproven here") instead of a guess. A
  `fail` goes back to the developer to **attribute before fixing** — only a regression traced to
  this ticket's diff earns a fix round. Also the home of the rule that applies to EVERY
  test-suite gate: it **never fails open** — the verdict needs a receipt (real command + exit
  code + summary line) AND a second agent must find the result comment on the ticket, or the
  gate is recorded as *not run* and nothing merges.
- `docs/agents/voice.md` — how the workspace TALKS: a spoken acknowledgement per prompt, a line
  when something happens, a voice note on the Slack messages it already sends, and hold-to-dictate.
  A **`th`-only, off-by-default, per-person** feature (`voice.enabled` in the git-ignored
  `workspace.config.local.yaml`) — inert for the team as shipped, and every command exits 0
  silently when a gate fails. **The one thing that concerns you when writing a reply: every
  finished turn speaks a closing line, so the only question is whether YOU write it.** Put a
  `VOICE[group]: <one line>` tag in the reply (`green` · `red` · `ship` · `needs-you` · `incident`)
  and that line is spoken verbatim — free, exact, and it picks the cue; leave it out and the reply
  is summarized instead, which costs a call and gives the model the last word on your work. Say the
  **result** — the finding, number, verdict, or what is waiting for the user — never that you
  finished, which they can already see. **And MID-TURN, at `chattiness: max` only, the same
  mechanism with a different word:** put `SAY[group]: <one line>` in your prose the moment you work
  something out — a root cause, a verdict, a number that answers the question, a decision about what
  to do next — and it is spoken while the work continues, free and verbatim, same groups. It is the
  ONLY thing spoken mid-turn: no tag ⇒ silence, which is correct for a stretch of work that has not
  concluded anything yet. Do NOT tag a step you are about to take ("อ่าน queue.sh ก่อน"), a status
  ("commit แล้ว"), or a claim you may retract two blocks later — a summarizer was tried for this
  decision and got all three wrong, which is why the judgement is yours. **It must sit MID-turn, with a tool call still to come:** a tag in the FINAL block of a
  reply is spoken by nobody — its own turn has no tool call left to trigger a hook, and the next
  turn's lookback is bounded to that turn. The closing line (`VOICE[…]`) is the mechanism for the
  end of a turn; these two do not substitute for each other. **A muted machine costs nothing** — `aiworks voice mute on`
  *or* simply muting the system output (read live from macOS) **disables** everything this machine
  says out loud, machine-wide: nothing summarized, nothing synthesized, no cue and no sound effect
  played. Neither reaches the Slack voice note (that is `voice.notify_voice.enabled` in config,
  audio for the team) or dictation. The assistant's spoken
  name is **Sunmi (ซันมี่)** — answer to it.
- `docs/agents/stagehand.md` — how the workspace SHOWS its work: a `PostToolUse` hook puts what a
  tool just touched on screen (edited file → editor at that line; fetched URL → browser tab),
  placed in whatever screen space is actually free on any display, without stealing the keyboard.
  **Off by default, per-person (`stagehand.enabled` in the git-ignored
  `workspace.config.local.yaml`), and ROOT WORKTREE ONLY** — a linked/Superset worktree shares the
  same physical screen and is gated out mechanically. Deliberately NOT built on Claude Code's
  `computer-use` MCP server: that hides every other app while it works, holds a machine-wide lock
  until the session exits, is view-only for browsers and click-only for IDEs (so it cannot open a
  URL or a file), and is Pro/Max only. `STAGEHAND=off` silences it for one command.
  **The one thing that concerns you when writing a reply:** a `Stop` hook also puts what the reply
  TALKED ABOUT on screen. Put a `SHOW: <target>` line in the reply (comma-separate up to
  `follow_max`) and exactly those open — a URL, `<repo>!<iid>` (e.g. `agent-db!555`), a ticket key,
  or a repo-relative path (`scripts/x.sh:42`); leave it out and the prose is scanned in reading
  order instead, which guesses. Name what the reader should be LOOKING at, and never hand-assemble
  a PR/MR URL — pass `<repo>!<iid>` and let the repo's git remote resolve it. Add a **focus phrase**
  with `~` (`SHOW: agent-db!555 ~signature_key`) and it opens ON that phrase — scrolled to and
  highlighted in the browser, the matching line in the editor. Use it whenever you name a symbol,
  column or identifier: without it the reader lands at the top of a page and has to hunt.
- `docs/agents/pii-provenance.md` — how personal data is kept inside the prod boundary
  **without** getting in the way of local/staging work. A value is redacted at egress (ticket
  / Slack) if and only if a sanctioned PRODUCTION read actually returned it — tracked by keyed
  hash, never by shape — so test/mock data flows untouched even when prod, staging and local
  work run in parallel. Egress **masks** (`<prod-pii:…>`) instead of blocking; `PII_GATE=off`
  is the escape hatch, `PII_GATE=on` the paranoid one.
- `docs/agents/submodules.md` — never develop inside a git **submodule** checkout: it's a
  read-only pointer to a repo that is *also* cloned as its own primary clone at the
  workspace root — branch/commit/PR in that primary clone (the coding-lifecycle skills
  consult this to redirect submodule'd changes to the right repo).
- `docs/agents/worktree-gc.md` — `aiworks gc`, which reclaims disk from Superset worktrees.
  Superset's UI Delete drops the workspace row but leaves the worktree DIRECTORY, the
  `git worktree` registration and the local branch behind; slack-dispatch leaked one worktree
  per @-mention (it now sweeps itself). Bare `aiworks gc` only REPORTS. It deliberately creates
  no shared build state — a shared `CARGO_TARGET_DIR` would serialize concurrent builds — so
  worktrees stay fully parallel; it only deletes from worktrees three independent liveness
  checks prove are idle, and `--force` never overrides those. `--install-schedule` adds the
  weekly launchd job that collects the UI-Delete leftovers — nothing else does.
- Provider adapters: `scripts/vcs/` (PR/MR via `github`|`gitlab`),
  `scripts/tracker/` (tickets via `notion`|`jira`), `scripts/notify/` (chat via
  `slack`), and `scripts/observability/` (traces/logs via `signoz`). **Always go
  through the adapters — never call `gh`/`glab`/Notion/Jira/Slack/the SigNoz API
  directly.**
- `scripts/k8s/` — READ-ONLY Kubernetes triage over the deployed GKE clusters, as the
  `k8s_triage` MCP (skill: `k8s-triage`). It never uses your kubeconfig credential: it
  impersonates `k8s-triage@<project>.iam.gserviceaccount.com`, whose `view`-based RBAC makes
  the **API server** reject writes, so a delete is a 403 rather than a code path we trust.
  Targets are DERIVED from each context's `gke_<project>_<region>_<cluster>` string (never
  from its personal alias), so `product` + `env` are required per call, there is no config
  file, and nothing is ever written to `~/.kube/config`. Production reuses `triage.prod`.
  ⚠️ `Bash(kubectl *)` and `Bash(gcloud *)` are **denied** — a read-only MCP beside an open
  shell would be decoration. Ask the user to run `!kubectl …` for anything outside the tools.
  Bootstrap + runbook: `scripts/k8s/README.md`; rationale: `docs/adr/0007`.
- **Test environment:** automated runs target **local** by default; staging is an
  explicit, QA-reserved opt-in (`CYPRESS_ENV=staging`). Defer to each repo's default —
  never hardcode an environment in agents/skills/workflow.

## Language
Output language follows `language` — from `workspace.config.local.yaml` if that personal
override exists, else `workspace.config.yaml` (full policy: `docs/agents/language.md`).
**This is resolved mechanically, not from memory:** a hook
(`.claude/hooks/resolve-language.sh`, wired in `.claude/settings.json`) reads
`workspace.config.local.yaml` if present (it's git-ignored and personal — see
`docs/adr/0003`), else falls back to `workspace.config.yaml`, and injects the resolved
language into context at `SessionStart` (full policy, once) AND on every
`UserPromptSubmit` (a compact reminder, every turn) — for every teammate, since both the
hook and its wiring are committed. A prose reminder to "check the file" was tried first
and was missed twice, since it depended on the model remembering to act; a SessionStart-only
injection was tried next and was still missed over a long tool-heavy session (the one-time
injection gets crowded out) — the per-turn reinjection closes that gap. If the hook's
injected context is ever missing (e.g. a stripped session), fall back to reading the file
directly before your first output. **A subagent gets it mechanically too:**
`.claude/hooks/dev-wrapper/pretool-agent-context.sh` (`PreToolUse(Agent)`) appends the resolved
`LANGUAGE_DIRECTIVE` to every spawn brief, so a direct `Agent` spawn is now as deterministic as a
workflow one — the imperative "read the file first" line in each agent file had still let two of
five probe agents resolve `en` on a `th` workspace. When the resolved language is **`th`**, write **English spine,
Thai prose** — prose in Thai (this CLI chat, tickets, PR/MR discussion, code review, Slack,
and the `.html` interactive render of a plan) while the English **spine** stays English: titles +
every section heading + labels/enum values, ALL code + code comments + git commit messages + branch
names, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). **Any
`.md` file you author is English — always** (plans, testcases, PRD/BRD/summary Markdown in
`agent_logs/`, and every checked-in repo doc — `docs/`, `README`, ADRs, committed PRD/BRD files):
the `th` prose rule never touches `.md`. Default **`en`** ⇒ everything English, no change.

## Output compression (caveman)
Every session and **every agent** writes ultra-compressed prose — the `caveman:caveman`
plugin skill. It reaches each spawn path by a different mechanism, and all three are
mechanical rather than remembered: the **main session** gets it from the plugin's own
`SessionStart`/`UserPromptSubmit` hooks; a **named agent** preloads it via
`skills: - caveman:caveman` in its `.claude/agents/<name>.md` frontmatter (measured, not
assumed — the skill's text was present in 5/5 probe transcripts); a **def-less agent type**
(`general-purpose`, `Explore`, `Plan`) has no frontmatter to preload from, so it is fed a
`CAVEMAN_DIRECTIVE` — by `pretool-agent-context.sh` for a direct `Agent` spawn, and by a
constant in each workflow for a workflow spawn (`grep agentType` if you add a call site).

⚠️ **Compression is an OUTPUT rule, and the FIRST brief is INPUT.** The brief that *spawns*
an agent goes in **FULL** — never compressed, summarized, or trimmed to save tokens. That
one message is the agent's whole world: it cannot recover context you dropped and has no
way to know something is missing, so a starved brief reads as a bad agent rather than a
starved one.

**Every message after that is caveman** — a follow-up, re-review ping, next-slice nudge, or
`SendMessage` to a live agent goes out compressed, because the context already landed and
the follow-up is a pointer, not a context transfer. Compression there is style, never
content: any NEW fact a follow-up carries (a QA bug report, a failing line, a changed
requirement) still goes in complete — drop the filler, never the facts.

The same boundary applies inside an agent: caveman governs how it **writes**, never what it
**does** — it must never skip a tool call, skip a tool-availability check, or claim a
tool/shell is unavailable without actually running it first.

A **repo-only session** (`cd <repo> && claude`) is covered too: each repo's
`.claude/settings.json` enables the plugin, and `.superset/setup.sh` installs it once at
**user** scope — declaring alone is not installing, which was measured, not assumed.

**In Cursor the skill is `/caveman`, not `caveman:caveman`** — Cursor cannot resolve the
`plugin:skill` form at all. `aiworks cursor` links each enabled plugin's skills to
`.claude/skills/<name>` (git-ignored), which Cursor reads through `.cursor/skills`, so both
names are the same file. Every agent file names both forms; see `docs/agents/cursor.md`.

## Product Overview
{{PRODUCT_DESCRIPTION}}

## Tech Stack
- <frontend / app stack>
- <e2e testing stack>

## Product Structure
The group's repos are declared under `products:` in @workspace.config.yaml
(and cloned via the generated `mani.d/<product>.yaml` files).

## Notifications
**Product work — auto-post, never ask.** When a workflow's code review or ship step
completes for a ticket (the PR/MR carries the tracker key — `tracker.ticket_prefix`,
e.g. `OFB-123` — in its title or branch), always post the Slack notification as part
of that step. Do not treat it as optional, a follow-up, or something to ask permission
for.

**Workspace/framework work — ASK first.** A change to THIS meta-repo (`ai-workspace`
itself: agents, skills, hooks, adapters, docs, config) has no ticket and is not the
team's sprint traffic. Opening an MR for it is not a review-request broadcast: report
it in chat and ask before posting to Slack. The same holds for any MR with no ticket
key. Announcing infra work to a product channel spends the team's attention on
something they were not waiting for.

Retracting one, if it goes out anyway: `scripts/notify/send.sh --delete <permalink>`
(bot-token only, and only a message this bot posted). A deleted message is gone for
new readers but the ones already looking saw it — say so in the channel if it mattered.

## Submodules & Worktrees
Never edit files inside submodule checkouts. Before diagnosing test failures
involving missing tables/data, verify submodule branch alignment first — a
wrong submodule branch is a common false-red cause.

## Test Diagnosis
Before concluding a test failure is real, check for known false-reds:
appium-flutter-driver hit-testability limits, stale persistent test DB,
submodule branch drift, and dual-formatter conflicts on generated files.
Validate on a live emulator/run where relevant before declaring red.

## Estimation
When estimating tickets, always fetch the persisted story-point fields first
to build calibration history before producing an estimate; do not conclude
'no calibration history' without querying those fields.

**DO NOT:**
- Read, print, or trace-dump any `.env` / `.env.*` file (except `.env.example`) — see the
  ⚠️ warning above. Highest priority: a leaked adapter secret (Jira/GitLab/Slack/SigNoz/...)
  is a live credential, not just a file.
- Never write a **comment** into `workspace.config.yaml` or `workspace.config.local.yaml` —
  not a header, not a section divider, not a trailing note, not a tombstone for a key you
  removed. Both are data; the `*.example.yaml` template beside them (or `docs/`) is where the
  explanation goes, and every live key must be documented there anyway. The rule holds when
  you ADD a key too: add it to the template in the same change, with the comment there.
  Enforced by `pretool-config-comment-guard.sh`; rationale in `docs/adr/0006`.
- Never run `codegraph` without naming the repo. The index is **per-repo** and the
  workspace root has none, so every query needs `-p $CLAUDE_PROJECT_DIR/<repo>` — an
  **absolute** path. A relative `-p` is only right when the cwd happens to be the
  workspace root, and the Bash cwd persists between calls: from inside another repo,
  `-p <repo>` resolves to a path that does not exist, codegraph walks up to the
  nearest index, and answers from the WRONG repo with exit 0. `pretool-codegraph-guard.sh`
  rewrites a relative `-p` to absolute and blocks a query with none, so this is
  enforced rather than remembered. The CLI subcommand is `query`, not `search`;
  `explore` and `node` exist as of CLI 1.5.0 and return source directly, so the CLI
  covers everything the MCP server does — prefer it. `posttool-codegraph-sync.sh`
  keeps the touched repo's index current after every Write/Edit.
- Never edit, add, or commit **inside a git submodule checkout** (e.g.
  `agent-webservice/agent-db/`, `paotung-template/packages/customization-widget/`). That
  code belongs to a repo that is *also* cloned as its own primary clone at the workspace
  root — make the change there. **Reading one is fine, and so is `git -C <sub> checkout
  <ref>` to PROVE something** (does the suite go green once the pointer is bumped?) — the
  ban is on create/edit/commit, not on inspection; restore the ref or use a throwaway
  `git worktree add` when you're done. Enforced by `pretool-submodule-guard.sh`, which
  blocks the write half and **pre-approves** the read half so a proof run isn't denied by
  the permission classifier. See `docs/agents/submodules.md`.
