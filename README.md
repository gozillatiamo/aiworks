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
```

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

## 📚 Learn more

- [`docs/aiworks.html`](docs/aiworks.html) — the full walkthrough (setup, CLI, dev-cycle)
- [`CONTEXT.md`](CONTEXT.md) — the workspace glossary (ubiquitous language, one place)
- [`docs/adr/`](docs/adr/) — architecture decision records (why the workspace is shaped this way)
- [`ofb-instruction/README.md`](ofb-instruction/README.md) — full local-env guide (DBs, Redis, games, accounts)
- [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) — how agents read/write Jira tickets
- [`scripts/tracker/README.md`](scripts/tracker/README.md) · [`scripts/vcs/README.md`](scripts/vcs/README.md) — adapter details
