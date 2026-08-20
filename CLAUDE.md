# CLAUDE.md — bluePi (OFB) organization workspace

**Multi-repo workspace.** Nested repos are independent clones (own git history, remote, `CLAUDE.md`) — read a
repo's own `CLAUDE.md` first, and confirm which repo you are in with `git rev-parse --show-toplevel` before any
git op. Repos are declared under `products[].repos[]` in `workspace.config.yaml`; `mani list projects` ·
`mani exec --all '<cmd>'` · `mani run <task>` · `mani sync` clones missing ones.

⚠️ **Never read `.env` / `.env.*`** (any adapter's `scripts/*/.env`, or anything matched by the blanket `.env*`
gitignore rule) — **except `.env.example`** templates, which hold no real values. No `Read`, no
`cat`/`grep`/`sed`/`head`/`tail`/`hcat` (nor any tool that renames those reading verbs — a renamed form is no
way past this), and no `bash -x`/`set -x` around code that sources one. To prove a var is set
without exposing it use `grep -q '^VAR=.\+' .env` — exit code only, never a form that echoes the value. Enforced
by `pretool-env-guard.sh` at the root **and in every repo**: a leaked adapter secret is a live credential.

## Configuration (read these first)

- `workspace.config.yaml` — the source of truth, `@`-imported below so it is already in context. Keys documented
  in `workspace.config.example.yaml`, overrides in `.local.yaml`, ⚠️ comments in neither — the rule beside it.
- `CONTEXT.md` — the workspace glossary · `docs/adr/` — why the workspace is shaped this way (`0001`–`0016`).
- `docs/agents/cursor.md` — under **Cursor** everything works through a GENERATED mirror (`aiworks cursor`):
  author on the Claude side, never hand-edit `.cursor/`, and open the `.code-workspace` **file**, not the folder.
- `docs/agents/language.md` · `register.md` · `caveman.md` · `ponytail.md` · `voice.md` · `stagehand.md` — the
  always-on conventions, summarized in their own sections below.
- `docs/agents/issue-tracker.md` — reading and writing tickets: the adapter, status names, id format.
- `docs/agents/human-review.md` — a `Human:` review comment is a blocking directive the agents auto-route and
  resolve; a `Human:` **reply on an agent's own must-fix CLEARS it** — approve and advance, never re-open it.
- `docs/agents/review-ledger.md` — a finding is raised ONCE: first pass IS the complete pass, `[gate:*]`
  threads are that closed set, no gate passes above an unresolved thread it owns, a re-run re-visits. A pass
  ENDS in the forge's approve tick — orchestrator-posted, ticket-wide or not at all; ticked ⇒ FROZEN whole.
- `docs/agents/loadtest-gate.md` — a green load suite is only **half** a verdict: a `suite_kind: load` repo must
  also beat its base branch against a measured noise floor. Home of the rule binding EVERY test-suite gate — it
  **never fails open**: no receipt (command + exit code + summary) and no result comment ⇒ recorded as *not run*.
- `docs/agents/pii-provenance.md` — egress masks personal data only when a sanctioned PRODUCTION read returned
  that value (keyed hash, never shape), leaving local and staging work untouched.
- `docs/agents/submodules.md` — never develop inside a submodule checkout, its primary clone is at the workspace
  root · `plan-artifacts.md` — one plan per repo, never committed · `worktree-gc.md` — bare `gc` only REPORTS ·
  `workflow-resume.md` — a run keeps the config it started with; change config ⇒ invoke BY NAME, never hand-edit
  a persisted run script · `doctor.md` — `aiworks doctor` reports what is missing/broken + the owner command per
  finding; `--fix` runs those.
- `docs/agents/figma.md` · `image-generation.md` · `diagram-generation.md` — design, asset and diagram surfaces,
  each behind its own `enabled` flag (default OFF) · `headroom.md` — `hcat`, not `Read`/`cat`, for a big data file.
- `scripts/k8s/README.md` — READ-ONLY Kubernetes triage (`k8s_triage` MCP) through a `view`-only impersonated
  identity, so the **API server** rejects writes. ⚠️ `Bash(kubectl *)`/`Bash(gcloud *)` denied — ask for `!kubectl`.
- **Test environment:** automated runs target **local**; staging is an explicit, QA-reserved opt-in
  (`CYPRESS_ENV=staging`). Defer to each repo's default — never hardcode one in agents or workflows.
- **Known false-reds:** rule one out before calling a failure real — each repo declares its own under
  `known_false_reds:`; workspace-wide, also suspect a stale persistent test DB, submodule branch drift, and
  dual-formatter conflicts on generated files. Re-run the scoped test in isolation against the base branch. When
  estimating, fetch the persisted story-point fields first (`/estimate-ticket`) — never conclude "no history".

## Provider adapters

`scripts/vcs/` (PR/MR) · `scripts/tracker/` (tickets) · `scripts/notify/` (chat) · `scripts/observability/`
(traces/logs). **Always go through the adapters — never call `gh`/`glab`/Notion/Jira/Slack/the SigNoz API
directly.** ⚠️ **Run a WRITER bare** — never in a pipe, `&&`, `;`, `$( )` or a heredoc. The allow rules match the
WHOLE command string, so a bare call matches and runs while a compound matches nothing, falls through to the
permission classifier, and is denied **silently, without prompting anyone**. Readers and any `--dry-run` may be
piped freely. Enforced by `pretool-adapter-pipe-guard.sh`.

## Language, compression and code

All injected mechanically, so this section carries only what those injections do **not** say. If the language
directive is ever missing (a stripped session), read the config yourself first; under `th`, **any `.md` file you
author is still English — always**, and Thai prose is address mode, never exposition mode — ⚠️ the pronoun follows
the SPEAKER, so an assistant speaking as itself never signs `ผม` (`register.md`). ⚠️ **Compression is an OUTPUT
rule: the first brief that spawns an agent is INPUT and goes in FULL** — that one message is the agent's whole
world; everything after it is caveman, style never content, so a follow-up's NEW facts still go in complete.
**Ponytail is that rule for code** — YAGNI, reuse, stdlib/native before a dependency — and it stops at a repo's own
test suite, a ticket's acceptance criteria, and the adapters: it shortens the implementation, never the
requirement (`ponytail.md`).

## Speaking and showing

Per-person and off by default; what concerns you is what you put in a **reply**.

- **`VOICE[group]: <one line>`** — every finished turn speaks a closing line; the only question is whether YOU
  write it. Groups `green` · `red` · `ship` · `needs-you` · `incident`. Say the **result** — the finding, number,
  verdict, or what is waiting for the user — never that you finished, which they can already see.
- **`SAY[group]: <one line>`** — the same, spoken MID-turn at `chattiness: max` only, the moment you work
  something out. Must sit mid-turn with a tool call still to come, and never tags a step you are about to take.
- **`SHOW: <target>`** — puts what the reply TALKED ABOUT on screen: a URL, `<repo>!<iid>` (`agent-db!555`), a
  ticket key, or a repo-relative path (`scripts/x.sh:42`) — never a hand-assembled PR/MR URL. A `~` focus phrase
  (`agent-db!555 ~signature_key`) lands the reader ON the thing, not atop a page.

## Notifications

**Product work — auto-post, never ask.** When a workflow's code-review or ship step completes for a ticket (the
PR/MR carries `tracker.ticket_prefix` in its title or branch), post the Slack notification as part of that step.
Not optional, not a follow-up, not something to ask permission for.

**Workspace/framework work — ASK first.** A change to THIS workspace repo itself has no ticket and is not the
team's sprint traffic; the same holds for any PR/MR with no ticket key. Report it in chat and ask — announcing infra
work to a product channel spends attention nobody was waiting to give. Retract with `send.sh --delete <permalink>`,
but those already looking saw it, so say so if it mattered.

## DO NOT

Three more bans, each hook-enforced rather than remembered: a **comment** in `workspace.config[.local].yaml`
(`.claude/rules/workspace-config.md`) · a create/edit/commit **inside a git submodule checkout**
(`.claude/rules/submodules.md` — reading, and `git -C <sub> checkout <ref>` to prove something, are fine) ·
`codegraph` without an **absolute** `-p $CLAUDE_PROJECT_DIR/<repo>`, which otherwise walks up and answers from
the WRONG repo with exit 0 (`pretool-codegraph-guard.sh`; the subcommand is `query`).

## Product

**OFB** — a multi-tenant betting platform: agencies and player sites over a sharded Postgres estate, a Rust
backend with batch jobs and stream consumers, Next.js themes and backoffice, Cypress/Newman/k6 suites. Every
repo's role, stack and green criterion is declared under `products:` in @workspace.config.yaml.
