<h1 align="center">⚡ AI Workspace</h1>

<p align="center">
  <em>A multi-repo workspace template for running a <strong>team of Claude agents</strong> across every repo of your product.</em><br/>
  One command takes a ticket through the whole delivery cycle.
</p>

<p align="center">
  <img alt="Claude" src="https://img.shields.io/badge/Claude-agents-D97757?logo=anthropic&logoColor=white">
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
workspace.config.yaml       # source of truth: providers, repos, statuses, policies (yours; gitignored)
workspace.config.example.yaml  # the template you copy it from
CLAUDE.md                   # workspace instructions for the agents
aiworks                     # workspace CLI (sync · add · remove · config · setup · run)
scripts/vcs|tracker|notify  # GitHub/GitLab · Jira/Notion · Slack adapters
.claude/                    # agents, skills, workflows (dev-cycle, prd, brd)
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
| **Claude Code** | [claude.com/claude-code](https://claude.com/claude-code) |

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

> 🔍 **SonarQube MCP token** (only with `quality_gate.provider: sonarqube`). The `sonarqube`
> MCP server runs as a **shared** container (`aiworks-mcp-sonarqube`, HTTP transport, like the
> postgres MCP services); its `.mcp.json` entry sends your SonarCloud token as a per-request
> `Authorization: Bearer` header, expanded from `SONARQUBE_TOKEN` **in the environment Claude
> Code is launched from**. Claude Code does not auto-load `.env`, so load one into your shell
> first. Get a token on [sonarcloud.io](https://sonarcloud.io) → **My Account → Security** →
> Generate Tokens → **User Token** (the `squ_…` value). Put it in a git-ignored `.env`; the
> committed `.envrc` (a one-line `dotenv`) auto-loads it with [`direnv`](https://direnv.net):
> ```sh
> brew install direnv                       # + hook your shell:  eval "$(direnv hook zsh)"
> printf 'SONARQUBE_TOKEN=squ_your_token\n' >> .env   # workspace root; already git-ignored
> direnv allow                              # trust the checked-in .envrc once
> ```
> Set `SONARQUBE_ORG` to your SonarCloud organization slug (in `.superset/.env`) if it differs
> from the default. Restart Claude Code after the first setup so the MCP config reloads.

**4. Set up the workspace** — clones + onboards every declared repo, installs node
dependencies, and starts the shared MCP services. Idempotent, safe to re-run:

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

Open the IDE workspace — the **file**, not the folder, so every repo gets its own
Source Control panel — then start a Claude Code session in this folder:

```sh
cursor <workspace>.code-workspace
/dev-cycle <PREFIX>-<n>     # one ticket, end to end across every repo it touches
```

**How a run behaves (with the default policies):**

- 🧭 **Plan approval is on** — the run stops after planning. Review, then re-run with
  `--approve-plan` to continue.
- 🔒 **Auto-merge is off** — the run reviews + tests, then leaves the PR/MR open for a
  human to merge, and posts a review digest to your `notify.channel`.
- 🎯 **Ticket status** is moved by the workflow itself — don't touch it by hand mid-run.

Flip these in `workspace.config.yaml` (`planning.auto_approve`, `vcs.auto_merge`,
`notify.*`).

## 🔍 Production triage (optional)

Two read-only MCP servers let an agent read **production ground truth** instead of guessing:
`prod_pg_triage` for Postgres rows ([`scripts/db/`](scripts/db/README.md)) and
`prod_redis_triage` for Redis keys and Streams ([`scripts/redis/`](scripts/redis/README.md)).
Both are read-only by construction and disconnect when done.

They live in **local scope**, not the shared `.mcp.json`: Claude Code spawns every enabled server
in every session, and prod triage is occasional work, so the machines that do it are the ones that
carry it. Opt in with one line in your git-ignored `workspace.config.local.yaml`:

```yaml
prod_triage:
  enabled: true
```

```sh
cp scripts/db/.env.example    scripts/db/.env      # read-only DSNs, per target
cp scripts/redis/.env.example scripts/redis/.env   # Redis targets (+ tunnel, if you need one)
./aiworks setup                                    # or: scripts/prod-triage-mcp.sh sync
scripts/prod-triage-mcp.sh status                  # policy + what is registered
```

`aiworks sync` reconciles both servers against that flag in both directions, so flipping it off
and re-running deregisters them again. Restart the session for the tools to appear.

<details>
<summary><strong>Under auto mode, add the authorization context (per machine)</strong></summary>

Read-only by construction is not the same as *authorized*: under auto mode Claude also needs to be
told that reading production through these prefixes is sanctioned, and where the line is. That
context is prose in your personal `~/.claude/settings.json` under `autoMode.environment` — adapt
the names to your setup:

> Production DB access is ONLY through the prod-pg-triage MCP, tool prefix
> `mcp__prod_pg_triage__*`. Treat EVERY call to that prefix as a sensitive, read-only production
> read, regardless of the target name. The server enforces a read-only role; if any call under
> this prefix ever mutates prod, treat it as a production write, not a read.

> The local dev databases are ordinary LOCAL dev resources — routine local reads, scratch tables
> and test queries there are fine. The ONE restriction: prod-derived data may reach them ONLY as
> the MASKED output of `scripts/db/prod_repro_seed.py`; a prod read written to a local database
> WITHOUT going through that tool is an unmasked prod-data flow and is NOT authorized.

> Production Redis access is ONLY through the prod-redis-triage MCP, tool prefix
> `mcp__prod_redis_triage__*` — typed READ tools only, with no command passthrough. That server
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
```

> 💡 Symlink the CLI onto your PATH once — `ln -s "$PWD/aiworks" ~/.local/bin/aiworks` —
> and run plain `aiworks run` from anywhere.

> ⚠️ Never hand-edit `mani.d/`, the `.code-workspace` file, or the CONFIG block in
> `.claude/workflows/dev-cycle.js` — all generated from the config.

## 🔄 Keeping the tooling current

`setup` only ever **installs what is missing** — it never moves a tool forward. `update` is
the other half: it upgrades each prerequisite through whichever installer owns it on your
machine (brew, rustup, corepack, gcloud, the Claude Code CLI + its plugins, codegraph, the
shared MCP images), and skips anything brew doesn't own rather than shadowing it.

```sh
./aiworks update                        # every group; best-effort, one failure never aborts
./aiworks update -n                     # preview — print each command, change nothing
./aiworks update --only claude,plugins  # just the Claude Code CLI + its plugins
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
- [`scripts/tracker/README.md`](scripts/tracker/README.md) · [`scripts/vcs/README.md`](scripts/vcs/README.md) — adapter details
