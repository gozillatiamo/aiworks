<h1 align="center">⚡ OFB AI Workspace</h1>

<p align="center">
  <em>The bluePi workspace for running a <strong>team of Claude agents</strong> across every OFB repo.</em><br/>
  One command takes a Jira ticket through the whole delivery cycle.
</p>

<p align="center">
  <img alt="Claude" src="https://img.shields.io/badge/Claude-agents-D97757?logo=anthropic&logoColor=white">
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-MRs-FC6D26?logo=gitlab&logoColor=white">
  <img alt="Jira" src="https://img.shields.io/badge/Jira-tickets-0052CC?logo=jira&logoColor=white">
  <img alt="Slack" src="https://img.shields.io/badge/Slack-notify-4A154B?logo=slack&logoColor=white">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-backend-000000?logo=rust&logoColor=white">
  <img alt="Next.js" src="https://img.shields.io/badge/Next.js-web-000000?logo=nextdotjs&logoColor=white">
  <img alt="PostgreSQL" src="https://img.shields.io/badge/Postgres-data-4169E1?logo=postgresql&logoColor=white">
</p>

<p align="center">
  <code>plan</code> → <code>build</code> → <code>PR/MR</code> → <code>review</code> → <code>test gate</code> → <code>merge</code> → <code>distribute</code>
</p>

<p align="center">
  📖 <strong>Full guide with diagrams:</strong> <a href="docs/aiworks.html">docs/aiworks.html</a> —
  open it in a browser. This README is the quick start; when they disagree, trust the doc.
</p>

---

Everything org-specific (GitLab, Jira, Slack, the repo list) lives in one file —
`workspace.config.yaml`. Agents never call providers directly; they go through the
adapters in `scripts/{vcs,tracker,notify}/`.

## 📦 What's inside

```
workspace.config.yaml       # source of truth: providers, repos, statuses, policies
CLAUDE.md                   # workspace instructions for the agents
aiworks                     # workspace CLI (sync · add · remove · config · setup · run)
scripts/vcs|tracker|notify  # GitLab · Jira · Slack adapters
.claude/                    # agents, skills, workflows (dev-cycle, prd, brd)
mani.yaml + mani.d/         # repo registry — generated, do not hand-edit
ai-workspace.code-workspace # multi-root IDE workspace — generated
```

The product repos clone **into** this folder but stay git-ignored — each is its own
independent clone.

## ✅ Prerequisites

| Tool | Install |
|------|---------|
| **git** | [git-scm.com/downloads](https://git-scm.com/downloads) |
| **SSH key on GitLab** (access to `gitlab.com/bluepicode`) | [docs.gitlab.com/user/ssh](https://docs.gitlab.com/user/ssh/) |
| **Node.js** | [nodejs.org/en/download](https://nodejs.org/en/download) |
| **Docker** | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **mani** | [github.com/alajmo/mani](https://github.com/alajmo/mani#install) |
| **Claude Code** | [claude.com/claude-code](https://claude.com/claude-code) |
| **gcloud CLI** | [cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install) |

> 🔧 `jq`, `glab` (GitLab CLI), `pnpm`, and `ngrok` are installed by `setup` if missing — just run
> `glab auth login` once after. You'll also need a
> [Jira API token](https://id.atlassian.com/manage-profile/security/api-tokens) and access
> to the `#dev-oneforbet` Slack channel.

## 🚀 First run

**1. Clone this repo and enter it.**

**2. Set up the adapter env files.** Copy each example and fill in your credentials
(fastest path: ask a teammate for working values):

```sh
cp scripts/tracker/.env.example scripts/tracker/.env   # Jira token
cp scripts/vcs/.env.example     scripts/vcs/.env       # GitLab (defaults usually fine)
cp scripts/notify/.env.example  scripts/notify/.env    # Slack token
```

**3. Set up the workspace** — clones + onboards every OFB repo, installs node
dependencies, and starts the shared MCP services. Idempotent, safe to re-run:

```sh
./aiworks setup
```

**4. Fill the repo env files.** Setup ends with an **ACTION REQUIRED** list of the
`.env` files still needing real values — fill each one (ask your manager or a teammate):

| File | Purpose |
|------|---------|
| `agent-webservice/.env` + `.env.local` | backend (`.env.local` required by docker-compose) |
| `backoffice/.env` · `front-end/.env` · `paotung-template/.env` + `.env.local` | web apps |
| `agent-webservice/.env.amb` | AMB aggregator — without it `run` skips the AMB phase ([docs](agent-webservice/docs/amb_setup_flow.md)) |

4.1 glab auth login
```sh
glab auth login
```

4.2 gcloud auth login
```sh
gcloud auth application-default login
gcloud auth login                        # user credential — `gcloud compute ssh` needs this one
```

4.2.1 **Prod triage authorization** — the two read-only production-triage MCPs
(`prod_pg_triage` for Postgres, `prod_redis_triage` for Redis/Streams) are read-only by
construction, but under **auto mode** Claude also needs to be told that reading production
through them is sanctioned, and where the line is. That context lives in your **personal**
`~/.claude/settings.json` under `autoMode.environment` — per-machine, not shared, so each
teammate adds it once:

<details>
<summary><strong>Show the three paragraphs to add (one-time, per machine)</strong></summary>

Append these to the `autoMode.environment` array in `~/.claude/settings.json` (create the key
if it isn't there). They are prose, not config — Claude reads them as standing authorization:

> Production DB access is ONLY through the prod-pg-triage MCP, tool prefix
> `mcp__prod_pg_triage__*`. Treat EVERY call to that prefix as a sensitive, read-only production
> read against the OFB PRODUCTION Postgres (MAD master + 16 hex shards shard_0..shard_f),
> regardless of hostname (targets carry no 'prod' segment). The server enforces a read-only
> role; if any call under this prefix ever mutates prod, treat it as a production write, not a
> read.

> Local Postgres from `agent-db run` (localhost:5432 master, localhost:5433 shard) is an
> ordinary LOCAL dev resource — routine local reads, scratch tables, and test queries there are
> fine. The ONE restriction: prod-derived data may reach it ONLY as the MASKED output of
> `scripts/db/prod_repro_seed.py`; a prod read (`mcp__prod_pg_triage__*`) written to local
> Postgres WITHOUT going through `prod_repro_seed.py` is an unmasked prod-data flow and is NOT
> authorized.

> Production Redis access is ONLY through the prod-redis-triage MCP, tool prefix
> `mcp__prod_redis_triage__*` — typed READ tools only, with no command passthrough. That server
> owns its own `gcloud compute ssh` port-forward (127.0.0.1:6377 for prod, :6378 for staging)
> and forwards the Redis port ONLY; it is never a remote shell, and the agent holds no `gcloud`
> grant. Treat every `target="prod"` call as a sensitive read-only production read; if any call
> under this prefix ever mutates Redis, treat it as a production write, not a read. Local Redis
> (`mcp__redis`, localhost:6379) is an ordinary LOCAL dev resource and stays writable. Prod
> Redis VALUES are never persisted locally: the only sanctioned local repro path is
> `capture_shape` → `scripts/redis/replay_shape.py`, which writes SYNTHETIC values from a schema.

Both servers live in **local scope**, not the shared `.mcp.json` — prod triage is occasional
work, and Claude Code spawns every enabled server in every session, so the people doing it are
the ones who carry it. Opt in with **one line** in your personal, git-ignored
`workspace.config.local.yaml`, then re-run setup:

```yaml
prod_triage:
  enabled: true
```

```sh
./aiworks setup                     # or: scripts/prod-triage-mcp.sh sync
scripts/prod-triage-mcp.sh status   # what the policy says + what is registered
```

`aiworks sync` reconciles both servers against that flag — registering them when it is on,
deregistering them when it is off — so your session spawns exactly what you opted into.

Then verify the tunnels work on your machine (read-only; the second command touches prod with
three cheap reads and disconnects):

```sh
uv run scripts/redis/prod_redis_mcp.py --verify staging
uv run scripts/redis/prod_redis_mcp.py --smoke prod
```

Details: [`scripts/db/README.md`](scripts/db/README.md) ·
[`scripts/redis/README.md`](scripts/redis/README.md)
</details>

4.3 SonarQube MCP token — the `sonarqube` MCP server runs as a **shared** container
(`aiworks-mcp-sonarqube`, HTTP transport, like the postgres MCP services). Its
`.mcp.json` entry sends your SonarCloud token as a per-request `Authorization: Bearer`
header, expanded from **`SONARQUBE_TOKEN` in the environment Claude Code is launched
from**. Claude Code does not auto-load `.env`, and `settings.json` `env` does not feed
`.mcp.json` expansion — so load a `.env` into your shell before launching Claude.

Get a token: on [sonarcloud.io](https://sonarcloud.io) sign in with an account that is a
**member of the `ofb` organization** (ask an org admin to add you under Organization `ofb`
→ Administration → Members if not), then **My Account → Security**
(https://sonarcloud.io/account/security) → Generate Tokens → type **User Token** → copy the
`squ_…` value.

Put it in a git-ignored `.env`; the committed `.envrc` (a one-line `dotenv`) auto-loads it
with [`direnv`](https://direnv.net):
```sh
brew install direnv                       # + hook your shell:  eval "$(direnv hook zsh)"  in ~/.zshrc
printf 'SONARQUBE_TOKEN=squ_your_token\n' >> .env   # workspace root; already git-ignored
direnv allow                              # trust the checked-in .envrc once
```
Now every shell entering the workspace exports `SONARQUBE_TOKEN`; launch Claude Code from
there and restart it after the first time so the MCP config reloads. (No direnv? Instead
`export SONARQUBE_TOKEN=…` from a file sourced in your shell profile.) The org defaults to
`ofb`; override with `SONARQUBE_ORG` in `.superset/.env` only if yours differs.

**5. Run the product** — starts the full local stack (databases + migrations, backend,
backoffice, **one** player site, AMB aggregator):

```sh
./aiworks run                    # PAOTUNG theme (default)
./aiworks run --site ohanabet    # OHANABET theme instead
./aiworks run --site all         # both player sites (each Next dev ≈ 2 GB RAM)
```

**6. Claim your admin & agent accounts.** The DB ships with placeholder accounts —
point them at your own Google account. Full steps in
[`ofb-instruction/README.md`](ofb-instruction/README.md); the short version:

<details>
<summary><strong>Show the claim steps (one-time)</strong></summary>

```sh
# Get your Google sub (sign in with your @bluepi.co.th account)
gcloud auth login
curl -s "https://oauth2.googleapis.com/tokeninfo?id_token=$(gcloud auth print-identity-token)" | jq -r .sub
```

Then, on the **MAD** database (`localhost:5432`, `postgres/postgres`):

```sql
-- OWNER admin → your @bluepi.co.th account
UPDATE bo_auth_google SET email = '<your @bluepi.co.th email>', sub = '<your google sub>'
WHERE email = 'local.admin@bluepi.co.th';
UPDATE admin SET email = '<your @bluepi.co.th email>'
WHERE email = 'local.admin@bluepi.co.th';

-- AGENT → a personal (non-bluepi) Google account
UPDATE bo_auth_google SET email = '<your personal email>'
WHERE email = 'local.agent@gmail.com';
```

</details>

**7. Play with the product.** 🎉

| Service | URL | Sign in with |
|---------|-----|--------------|
| 🛠️ **Backoffice** | http://localhost:3001 | your `@bluepi.co.th` → OWNER admin · personal Google → agent |
| 🎰 **Player site — PAOTUNG** | http://localhost:3004 | test player below |
| 🎲 **Player site — OHANABET** | http://localhost:3002 | test player below |
| 🔌 **API** | http://localhost:3000 | — |

Seeded **test player** → phone `0800000000` · PIN `888` · funded wallet. Plain
`localhost` resolves to the default site.

<details>
<summary><strong>Visit a site by its site code</strong> (host-based theme resolution)</summary>

A player site picks its theme + config from the hostname. We standardize the local
domain on **`oneforbet.local`** — set `OFB_DOMAIN_NAME=oneforbet.local` in
`agent-webservice/.env`, then add the seeded subdomains to `/etc/hosts`:

```
127.0.0.1 localhost paotl.oneforbet.local ohnbl.oneforbet.local
```

- `http://paotl.oneforbet.local:3004` → PAOTUNG site (code `PAOTL`)
- `http://ohnbl.oneforbet.local:3002` → OHANABET site (code `OHNBL`)

</details>

## 🎫 Run a ticket

Open the IDE workspace — the **file**, not the folder, so every repo gets its own
Source Control panel — then start a Claude Code session in this folder:

```sh
cursor ai-workspace.code-workspace
/dev-cycle OFB-<n>       # one ticket, end to end across every repo it touches
```

**How a run behaves here:**

- 🧭 **Plan approval is on** — the run stops after planning. Review, then re-run with
  `--approve-plan` to continue.
- 🔒 **Auto-merge is off** — the run reviews + tests, then leaves the PR/MR open for a
  human to merge, and posts a review digest to `#dev-oneforbet`.
- 🎯 **Jira status** is moved by the workflow itself — don't touch it by hand mid-run.

## 🗂️ Managing repos

`workspace.config.yaml` → `products[].repos[]` is the only repo list you edit.

```sh
./aiworks sync                 # onboard everything declared in the config
./aiworks sync <repo-name>     # onboard just one repo
./aiworks add --url <git-url> --product ofb-platform --kind backend
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
- [`ofb-instruction/README.md`](ofb-instruction/README.md) — full local-env guide (DBs, Redis, games, accounts)
- [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) — how agents read/write Jira tickets
- [`scripts/tracker/README.md`](scripts/tracker/README.md) · [`scripts/vcs/README.md`](scripts/vcs/README.md) — adapter details
