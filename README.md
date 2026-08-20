<h1 align="center">⚡ AI Workspace</h1>

<p align="center">
  <em>A multi-repo workspace template for running one <strong>agent team</strong> through Claude Code, Cursor, or Codex across every repo of your product.</em><br/>
  One command takes a ticket through the whole delivery cycle.
</p>

<p align="center">
  <img alt="Claude" src="https://img.shields.io/badge/Claude-agents-D97757?logo=anthropic&logoColor=white">
  <img alt="Cursor" src="https://img.shields.io/badge/Cursor-agents-111111?logo=cursor&logoColor=white">
  <img alt="Codex" src="https://img.shields.io/badge/Codex-agents-10A37F?logo=openai&logoColor=white">
  <img alt="GitHub" src="https://img.shields.io/badge/GitHub-PRs-181717?logo=github&logoColor=white">
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-MRs-FC6D26?logo=gitlab&logoColor=white">
  <img alt="Jira" src="https://img.shields.io/badge/Jira-tickets-0052CC?logo=jira&logoColor=white">
  <img alt="Notion" src="https://img.shields.io/badge/Notion-tickets-000000?logo=notion&logoColor=white">
  <img alt="Slack" src="https://img.shields.io/badge/Slack-notify-4A154B?logo=slack&logoColor=white">
</p>

<p align="center">
  <code>plan</code> → <code>build</code> → <code>PR/MR</code> → <code>review</code> → <code>test gate</code> → <code>merge</code> → <code>distribute</code>
</p>

<p align="center">
  📖 <strong>Full guide with diagrams:</strong> <a href="docs/aiworks.html">docs/aiworks.html</a> —
  open it in a browser. This README is the quick start; when they disagree, trust the doc.
</p>

---

Everything org-specific (VCS, tracker, chat, the repo list) lives in one file —
`workspace.config.yaml`. Agents never call providers directly; they go through the
adapters in `scripts/{vcs,tracker,notify}/`.

## 📦 What's inside

```
workspace.config.yaml       # source of truth: Harnesses, providers, repos, statuses, policies
workspace.config.example.yaml  # the template you copy it from
CLAUDE.md                   # workspace instructions for the agents
aiworks                     # workspace CLI (setup · sync · harnesses · workflow · run)
scripts/vcs|tracker|notify  # GitHub/GitLab · Jira/Notion · Slack adapters
.claude/                    # canonical agents, skills, rules, hooks and workflows
.cursor/ + .codex/          # generated Harness projections — never hand-edit
mani.yaml + mani.d/         # repo registry — generated, do not hand-edit
<workspace>.code-workspace  # multi-root IDE workspace — generated
.superset/products/         # local-stack definitions (copy example.sh; yours are gitignored)
```

The product repos clone **into** this folder but stay git-ignored — each is its own
independent clone.

## ✅ Prerequisites

| Tool | Install |
|------|---------|
| **git** | [git-scm.com/downloads](https://git-scm.com/downloads) |
| **SSH key on your VCS host** (access to your org's repos) | GitHub / GitLab SSH docs |
| **Node.js** | [nodejs.org/en/download](https://nodejs.org/en/download) |
| **Docker** | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **mani** | [github.com/alajmo/mani](https://github.com/alajmo/mani#install) |
| **An Agent harness** | Pick Claude Code, Cursor, Codex, or several during `aiworks setup`; missing selected CLIs are installed interactively |

> 🔧 `jq`, `glab` (GitLab CLI), and `ngrok` are installed by `setup` if missing — just run
> `glab auth login` once after (GitLab orgs). You'll also need an API token for your
> tracker (e.g. a [Jira API token](https://id.atlassian.com/manage-profile/security/api-tokens))
> and access to the Slack channel you configure under `notify.channel`.

## 🚀 First run

**1. Clone this repo and enter it.**

**2. Describe your org.** Copy the example config and fill in your providers + repos —
this one file drives everything:

```sh
cp workspace.config.example.yaml workspace.config.yaml
```

**3. Set up the adapter env files.** Copy each example and fill in your credentials:

```sh
cp scripts/tracker/.env.example scripts/tracker/.env   # Jira/Notion token
cp scripts/vcs/.env.example     scripts/vcs/.env       # GitHub/GitLab
cp scripts/notify/.env.example  scripts/notify/.env    # Slack token
```

> 🔍 **MCP secrets (workspace-root `.env`)**. Put MCP tokens in the git-ignored root `.env`
> (loaded by the committed `.envrc` → `dotenv` / [direnv](https://direnv.net)). Do **not** put
> them in `.claude/settings.local.json` — that file only enables servers / prefs. Stdio
> wrappers under `scripts/mcp/` (e.g. `mcp-image`, `n8n-mcp`) read `.env` themselves so Cursor
> works without inheriting direnv. Typical keys:
> ```sh
> brew install direnv                       # + hook your shell:  eval "$(direnv hook zsh)"
> # GEMINI_API_KEY=…          # mcp-image (https://aistudio.google.com/apikey)
> # N8N_MCP_URL=https://…/mcp-server/http
> # N8N_MCP_ACCESS_TOKEN=…    # n8n instance MCP access token
> # SONARQUBE_TOKEN=squ_…     # SonarCloud user token (quality_gate.provider: sonarqube)
> direnv allow
> ```
> SonarQube MCP still uses HTTP headers from process env (shared container
> `aiworks-mcp-sonarqube`). Set `SONARQUBE_ORG` in `.superset/.env` if it differs from the
> default. Restart Claude Code / Cursor after the first setup so MCP reloads.

**4. Set up the workspace** — first choose one or more Agent harnesses, then install/login,
project their configuration, clone + onboard every repo, install dependencies, and start the
shared MCP services. Idempotent, safe to re-run:

```sh
./aiworks setup
```

**5. Fill the repo env files.** Setup ends with an **ACTION REQUIRED** list of the
`.env` files still needing real values — fill each one (ask a teammate for working values).

**6. Define + run your local stack** (optional). Copy
`.superset/products/example.sh` to `.superset/products/<product-id>.sh`, declare your
repos per tier (databases / backends / frontends), then:

```sh
./aiworks run                    # the default frontend profile
./aiworks run --site <profile>   # another profile your product file defines
```

## 🎫 Run a ticket

Open the IDE workspace — the **file**, not the folder, so every repo gets its own Source Control
panel — then invoke the canonical workflow through your selected Harness:

```sh
cursor <workspace>.code-workspace
# Claude Code: native Workflow
# Cursor:      /dev-cycle <PREFIX>-<n>
# Codex:       $dev-cycle <PREFIX>-<n>
```

**How a run behaves (with the default policies):**

- 🧭 **Plan approval is on** — the run stops after planning. Review, then re-run with
  `--approve-plan` to continue. Skip it on your own runs with `planning: auto_approve: true`
  in the git-ignored `workspace.config.local.yaml` (the one control-flow key that takes a
  personal override — see [ADR 0003](docs/adr/0003-personal-runtime-config-overrides.md)).
- 🔒 **Auto-merge is off** — the run reviews + tests, then leaves the PR/MR open for a
  human to merge, and posts a review digest to your `notify.channel`.
- 🎯 **Ticket status** is moved by the workflow itself — don't touch it by hand mid-run.

Flip these in `workspace.config.yaml` (`planning.auto_approve`, `vcs.auto_merge`,
`notify.*`).

## 🔍 Production triage (optional)

Two read-only MCP servers let an agent read **production ground truth** instead of guessing:
`pg_triage` for Postgres rows ([`scripts/db/`](scripts/db/README.md)) and
`redis_triage` for Redis keys and Streams ([`scripts/redis/`](scripts/redis/README.md)).
Both are read-only by construction and disconnect when done.

They live in **local scope**, not the shared `.mcp.json`: Claude Code spawns every enabled server
in every session, and prod triage is occasional work, so the machines that do it are the ones that
carry it. Opt in with one line in your git-ignored `workspace.config.local.yaml`:

```sh
cp scripts/db/.env.example    scripts/db/.env      # read-only DSNs, per target and per env
cp scripts/redis/.env.example scripts/redis/.env   # Redis targets (+ tunnel, if you need one)
scripts/triage-mcp.sh sync                         # register the servers (local scope)
scripts/triage-mcp.sh status                       # policy + what is registered
```

Registration is a step **you** run: `aiworks sync` does not do it (`docs/adr/0009`) — it reports
what is unregistered, and `aiworks doctor` fails on it with the same command attached. Once
registered, **staging triage needs no opt-in**.
**Production** does, and the servers enforce it themselves, so it is one line in your git-ignored
`workspace.config.local.yaml` and takes effect immediately (no re-register, no restart):

```yaml
triage:
  prod: true          # PRODUCTION targets; staging works without it
# enabled: false      # the other direction — keep both servers out of this machine's sessions
```

Restart the session for the tools to appear. Then verify (read-only):

```sh
uv run scripts/db/pg_triage_mcp.py --verify staging --target main   # + asserts prod is refused when off
uv run scripts/redis/redis_triage_mcp.py --selftest
```

<details>
<summary><strong>Under auto mode, add the authorization context (per machine)</strong></summary>

Read-only by construction is not the same as *authorized*: under auto mode Claude also needs to be
told that reading production through these prefixes is sanctioned, and where the line is. That
context is prose in your personal `~/.claude/settings.json` under `autoMode.environment` — adapt
the names to your setup:

> Deployed DB access is ONLY through the pg-triage MCP, tool prefix `mcp__pg_triage__*`. Every
> call names its environment explicitly (`env="staging"` | `env="prod"`; there is no default).
> Treat EVERY `env="prod"` call as a sensitive, read-only production read, regardless of the
> target name; `env="staging"` is ordinary non-production work. The server enforces a read-only
> role and refuses prod entirely unless `triage.prod` is on for this machine; if any call under
> this prefix ever mutates prod, treat it as a production write, not a read.

> The local dev databases are ordinary LOCAL dev resources — routine local reads, scratch tables
> and test queries there are fine. The ONE restriction: prod-derived data may reach them ONLY as
> the MASKED output of `scripts/db/prod_repro_seed.py`; a prod read written to a local database
> WITHOUT going through that tool is an unmasked prod-data flow and is NOT authorized.

> Production Redis access is ONLY through the redis-triage MCP, tool prefix
> `mcp__redis_triage__*` — typed READ tools only, with no command passthrough. That server
> owns its own port-forward and forwards the Redis port ONLY; it is never a remote shell, and the
> agent holds no `gcloud` grant. Treat every call against a `prod=true` target as a sensitive
> read-only production read; if any call under this prefix ever mutates Redis, treat it as a
> production write. A local dev Redis (`mcp__redis`) stays writable. Prod Redis VALUES are never
> persisted locally: the only sanctioned local repro path is `capture_shape` →
> `scripts/redis/replay_shape.py`, which writes SYNTHETIC values from a schema.

</details>

## 🗂️ Managing repos

`workspace.config.yaml` → `products[].repos[]` is the only repo list you edit.

```sh
./aiworks sync                 # onboard everything declared in the config
./aiworks sync <repo-name>     # onboard just one repo
./aiworks add --url <git-url> --product <product-id> --kind backend
./aiworks remove <repo-name>   # deregister (add --purge to delete the clone)
./aiworks config               # regen generated files after editing the config
./aiworks harnesses list       # organization-wide selected Harnesses
./aiworks harnesses configure --reconfigure
./aiworks harnesses check      # every selected projection matches .claude
./aiworks codex --check        # narrow Codex projection check
```

> 💡 Symlink the CLI onto your PATH once — `ln -s "$PWD/aiworks" ~/.local/bin/aiworks` —
> and run plain `aiworks run` from anywhere.

> ⚠️ Never hand-edit `mani.d/`, the `.code-workspace` file, or the CONFIG block in
> `.claude/workflows/dev-cycle.js` — all generated from the config.

## 🔄 Keeping the tooling current

`setup` only ever **installs what is missing** — it never moves a tool forward. `update` is
the other half: it upgrades each prerequisite through whichever installer owns it on your
machine (brew, rustup, corepack, gcloud, selected Harness CLIs + plugins, codegraph, the
shared MCP images), and skips anything brew doesn't own rather than shadowing it.

```sh
./aiworks update                        # every group; best-effort, one failure never aborts
./aiworks update -n                     # preview — print each command, change nothing
./aiworks update --only claude,cursor,codex,plugins
./aiworks update --check-deps           # …and report outdated deps per repo (read-only)
```

Two things it reports but never changes: **node** (an nvm major switch moves the global bin
dir, so `pnpm` and every other global silently leaves PATH — the safe command is printed for
you), and **repo dependencies** (`npm update` / `cargo update` rewrite a lockfile, so each is a
branch + tests + MR per repo, not a maintenance chore). Restart Claude Code after a plugin update.

## 📚 Learn more

- [`docs/aiworks.html`](docs/aiworks.html) — the full walkthrough (setup, CLI, dev-cycle)
- [`CONTEXT.md`](CONTEXT.md) — the workspace glossary (ubiquitous language, one place)
- [`docs/adr/`](docs/adr/) — architecture decision records (why the workspace is shaped this way)
- [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) — how agents read/write tickets
- [`docs/agents/harnesses.md`](docs/agents/harnesses.md) — projection/runtime contract and how to add Hermes next
- [`scripts/tracker/README.md`](scripts/tracker/README.md) · [`scripts/vcs/README.md`](scripts/vcs/README.md) — adapter details
