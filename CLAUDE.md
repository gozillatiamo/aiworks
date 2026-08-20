# CLAUDE.md — bluePi (OFB) organization workspace

**Multi-repo workspace.** Nested repos are independent clones (own git history, remote, `CLAUDE.md`) — read a repo's own
`CLAUDE.md` first, and confirm which repo you are in with `git rev-parse --show-toplevel` before any git op. Repos are
declared under `products[].repos[]` in `workspace.config.yaml`; `mani list projects` · `mani exec --all '<cmd>'` ·
`mani run <task>` · `mani sync` clones missing ones.

⚠️ **Never read `.env` / `.env.*`** (any adapter's `scripts/*/.env`, or anything the blanket `.env*` gitignore matches) —
**except `.env.example`**, which holds no real values. No `Read`, no `cat`/`grep`/`sed`/`head`/`tail`/`hcat` (nor any tool
that renames those reading verbs — a renamed form is no way past this), no `bash -x`/`set -x` around code that sources
one. To prove a var is set without exposing it: `grep -q '^VAR=.\+' .env` — exit code only, never a form that echoes the
value. Enforced by `pretool-env-guard.sh` at the root **and in every repo**: a leaked adapter secret is live.

## Configuration (read these first)

- `workspace.config.yaml` — the source of truth, `@`-imported below so already in context. Keys documented in
  `workspace.config.example.yaml`, overrides in `.local.yaml`, ⚠️ comments in neither · `CONTEXT.md` — the glossary ·
  `docs/adr/` — why the workspace is shaped this way (`0001`–`0022`).
- `docs/agents/cursor.md` — under **Cursor** everything works through a GENERATED mirror (`aiworks cursor`): author on
  the Claude side, never hand-edit `.cursor/`, open the `.code-workspace` **file**, not the folder · `language.md` ·
  `register.md` · `caveman.md` · `ponytail.md` · `voice.md` · `stagehand.md` — always-on conventions, own sections
  below · `issue-tracker.md` — tickets: the adapter, status names, id format · `human-review.md` — a `Human:` review
  comment is a blocking directive the agents auto-route and resolve; a `Human:` **reply on an agent's own must-fix
  CLEARS it** — approve and advance, never re-open it.
- `docs/agents/review-ledger.md` — a finding is raised ONCE: first pass IS the complete pass, `[gate:*]` threads are that
  closed set, no gate passes above an unresolved thread it owns, a re-run re-visits. A pass ENDS in the forge's approve
  tick — orchestrator-posted, ticket-wide or not at all; ticked ⇒ FROZEN whole.
- `docs/agents/loadtest-gate.md` — a green load suite is only **half** a verdict: a `suite_kind: load` repo must also beat
  its base branch against a measured noise floor. Home of the rule binding EVERY test-suite gate — it **never fails
  open**: no receipt (command + exit code + summary) and no result comment ⇒ *not run* · `pii-provenance.md` — egress
  masks personal data only when a sanctioned PRODUCTION read returned it (keyed hash, never shape).
- `docs/agents/submodules.md` — never develop inside a submodule checkout, its primary clone is at the workspace root ·
  `plan-artifacts.md` — one plan per repo, never committed · `worktree-gc.md` — bare `gc` only REPORTS ·
  `workflow-resume.md` — a run keeps the config it started with; change config ⇒ invoke BY NAME, never hand-edit a
  persisted run script · `doctor.md` — `aiworks doctor` names what is broken + its owner command, `--fix` runs it ·
  `figma.md` · `image-generation.md` · `diagram-generation.md` — each behind its `enabled` flag (default OFF) ·
  `headroom.md` — `hcat` for a big file, never a bare `cat`: an unbounded read ≥8 KiB is hook-BLOCKED, as is a read-modify-write
  heredoc patch (`Edit` ships only the delta).
- `scripts/k8s/README.md` — READ-ONLY Kubernetes triage (`k8s_triage` MCP) through a `view`-only impersonated identity,
  so the **API server** rejects writes. ⚠️ `Bash(kubectl *)`/`Bash(gcloud *)` denied — ask for `!kubectl`.
- **Test environment:** automated runs target **local**; staging is an explicit, QA-reserved opt-in
  (`CYPRESS_ENV=staging`) — defer to each repo's default, never hardcode one in agents or workflows.
- **Known false-reds:** rule one out before calling a failure real — each repo declares its own under
  `known_false_reds:`; workspace-wide, also suspect a stale persistent test DB, submodule branch drift, and dual-formatter
  conflicts on generated files. Re-run the scoped test in isolation against the base branch. When estimating, fetch the
  persisted story-point fields first (`/estimate-ticket`) — never conclude "no history".

## Provider adapters

`scripts/vcs/` (PR/MR) · `scripts/tracker/` (tickets) · `scripts/notify/` (chat) · `scripts/observability/` (traces).
**Always go through the adapters — never `gh`/`glab`/Notion/Jira/Slack/the SigNoz API directly.** ⚠️ **Run a WRITER bare**:
no pipe, `&&`, `;`, `$( )`, heredoc. Allow rules match the WHOLE command string, so a compound matches nothing, falls to
the classifier, and is denied **silently**. Readers and `--dry-run` pipe freely. `pretool-adapter-pipe-guard.sh`.

## Language, compression and code

Injected mechanically; this carries only what those injections do **not** say. If the language directive is ever missing
(a stripped session), read the config yourself first; under `th`, **any `.md` file you author is still English —
always**, and Thai prose is address mode, never exposition — ⚠️ the pronoun follows the SPEAKER, so an assistant speaking
as itself never signs `ผม` (`register.md`). ⚠️ **Compression is an OUTPUT rule: the first brief that spawns an agent is
INPUT and goes in FULL** — that message is the agent's whole world; everything after is caveman, style never content, so
a follow-up's NEW facts still go complete. **Ponytail is that rule for code** — YAGNI, reuse, stdlib/native before a
dependency — stopping at a repo's test suite, a ticket's acceptance criteria and the adapters: it shortens the
implementation, never the requirement (`ponytail.md`).

## Speaking and showing

Per-person and off by default; what concerns you is what you put in a **reply**.
- **`VOICE[group]: <one line>`** — every finished turn speaks a closing line; the only question is whether YOU write it.
  Groups `green` · `red` · `ship` · `needs-you` · `incident`. Say the **result** — finding, number, verdict, or what is
  waiting for the user — never that you finished, which they can already see.
- **`SAY[group]: <one line>`** — the same, MID-turn at `chattiness: max` only, the moment you work something out; must
  have a tool call still to come, and never tags a step you are about to take.
- **`SHOW: <target>`** — puts what the reply TALKED ABOUT on screen: a URL, `<repo>!<iid>` (`agent-db!555`), a ticket key,
  or a repo-relative path (`scripts/x.sh:42`) — never a hand-assembled PR/MR URL. A `~` focus phrase (`agent-db!555
  ~signature_key`) lands the reader ON the thing, not atop a page.

## Notifications

**Product work — auto-post, never ask.** When a workflow's code-review or ship step completes for a ticket (the PR/MR
carries `tracker.ticket_prefix` in its title or branch), post the Slack notification as part of that step. Not optional,
not a follow-up, not something to ask permission for.

**Workspace/framework work — ASK first.** A change to THIS workspace repo has no ticket and is not the team's sprint
traffic; same for any PR/MR with no ticket key. Report it in chat and ask — announcing infra work to a product channel
spends attention nobody was waiting to give. Retract with `send.sh --delete <permalink>`, but those already looking saw
it, so say so if it mattered.

## DO NOT

Three hook-enforced bans: a **comment** in `workspace.config[.local].yaml` (`.claude/rules/workspace-config.md`) · a
create/edit/commit **inside a git submodule checkout** (`.claude/rules/submodules.md` — reading, and `git -C <sub>
checkout <ref>` to prove something, are fine) · `codegraph` without an **absolute** `-p $CLAUDE_PROJECT_DIR/<repo>`,
which otherwise walks up and answers from the WRONG repo with exit 0 (`pretool-codegraph-guard.sh`; subcommand `query`).

## Product

**OFB** — a multi-tenant betting platform: agencies and player sites over a sharded Postgres estate, a Rust backend with
batch jobs and stream consumers, Next.js themes and backoffice, Cypress/Newman/k6 suites. Every repo's role, stack and
green criterion is declared under `products:` in @workspace.config.yaml, cloned via generated `mani.d/<product>.yaml`.
