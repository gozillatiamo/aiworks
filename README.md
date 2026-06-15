# AI Agents Workspace(aiworks) — multi-repo agent orchestration

A reusable, provider-agnostic starting point for running a **"product team" of Claude
agents** across multiple repos.

The team is flat but role-based — CEO → CPO/CTO → planners → developer/QA → reviewers →
guardian/perf → documentor — and it takes a single ticket all the way through:

> **plan → build → PR/MR → review → cross-repo test-suite gate → merge → distribute**

across every repo the ticket touches. The `dev-cycle` workflow drives the whole thing.

> ## 📖 Start here: <a href="docs/aiworks.html" target="_blank" rel="noopener noreferrer"><code>docs/aiworks.html</code></a>
>
> **That interactive guide is the authoritative, human-friendly walkthrough** of this
> workspace — the setup flow, the `aiworks` CLI, and the dev-cycle, with diagrams and
> examples. Open it in a browser and read it first. This README is just a quick map; when
> the two ever disagree, trust the doc.

---

## Why this exists

Most of this orchestration is identical from org to org. What changes is *your* stack:
which VCS you use, which tracker, whether merges are automatic, where builds get shipped.

So everything org-specific is **swappable from one config file**, and the agents/workflows
never call a provider tool directly — they go through a small adapter with a stable CLI.
Want to add Linear or Bitbucket? Drop one new file under `scripts/<axis>/` and nothing
else changes.

| What's swappable | Choices | Where you set it |
|---|---|---|
| **VCS** | `github` (`gh`) · `gitlab` (`glab`) | `scripts/vcs/` adapter + `vcs.provider` |
| **Auto-merge** | `true` · `false` (per-repo override) | `vcs.auto_merge` + `products[].repos[].auto_merge` |
| **Plan approval** | auto · human approves before build | `planning.auto_approve` (+ `--approve-plan`) |
| **Plan → HTML** | `true` · `false` | `planning.to_html` (write-interactive-docs) |
| **Tracker** | `notion` · `jira` (both shell + curl + jq) | `scripts/tracker/` adapter + `tracker.*` |
| **Quality gate** | `sonarqube` · `none` | `quality_gate.provider` + per-repo `guard` |
| **Distribution** | `firebase` · `none` · `custom` | per-repo `distribute` |
| **Repos / identity** | yours — just the URLs | `workspace.config.yaml` `products[].repos[]` |

---

## What's in here

```
workspace.config.example.yaml      # the ONE file you fill in (org, providers, repos)
CLAUDE.md                          # workspace instructions (templated)
mani.yaml + mani.d/<product>.yaml  # repo registry — GENERATED from the config
docs/agents/issue-tracker.md       # how agents read/write tickets
.claude/{agents,skills,workflows,hooks,settings.json}
scripts/vcs/                       # github | gitlab  PR/MR adapter
scripts/tracker/                   # notion | jira    ticket adapter
.superset/                         # workspace setup/teardown (mani sync + .env seeding)
```

---

## Get started (new org)

The whole setup is "fill in one config, then run one command." Here's the full path:

1. **Copy** this directory into your new workspace repo (or use it directly as one).

2. **Fill in the config.**
   ```sh
   cp workspace.config.example.yaml workspace.config.yaml
   ```
   Set your org name/product, `vcs.provider` + `vcs.auto_merge`, `tracker.provider` +
   `ticket_prefix` + `statuses`, `branch_model`, `quality_gate`, and `planning`. Then add
   your repos — **just the URL (+ `kind`)** under `products[].repos[]`. That `products:`
   block is the only repo list you maintain; `mani.d/` is generated from it.

3. **Add tracker credentials.**
   ```sh
   cp scripts/tracker/.env.example scripts/tracker/.env
   ```
   Set `TRACKER_PROVIDER` and that provider's block, then fill in
   `docs/agents/issue-tracker.md` (ids, status names).

4. **Log in to your VCS** — `gh auth login` or `glab auth login`. The provider
   auto-detects from the `origin` remote; override it in `scripts/vcs/.env` if needed.

5. **Onboard your repos** — one command does it all:
   ```sh
   scripts/aiworks sync       # clone + fully set up every repo in the config
   mani list projects         # confirm
   ```
   It's idempotent — re-run any time; already-onboarded repos just **SKIP**.

6. **De-brand pass.** Replace the `{{ORG_NAME}}` / `{{PRODUCT_DESCRIPTION}}` placeholders
   in `CLAUDE.md`. The agents and workflows are already provider-agnostic, but a few
   **stack-specific** skills still ship with the reference stack's copy/tooling (a Flutter
   app + an E2E automation test-suite repo). Adapt these to your stack:
   `.claude/skills/{coding-feature,coding-automate,plan-automate}` and the
   `coding-feature/*.md` references. (VCS/tracker wiring needs no further edits.)

> **You never hand-edit the workflow.** `.claude/workflows/dev-cycle.js` keeps a mirrored
> `── CONFIG ──` block (the `REPOS` registry, `TICKET_PREFIX`, `AUTO_MERGE`,
> `AUTO_APPROVE_PLAN`, `PLAN_TO_HTML`, status names) only because Workflow scripts can't
> read the filesystem at runtime. `scripts/aiworks sync` — and every `add` / `remove` —
> regenerates that block from `workspace.config.yaml` for you. (`prd.js` / `brd.js` use
> the same FS-mirror trick.)

---

## Managing repos — `scripts/aiworks`

`aiworks` is the workspace CLI. The golden rule: **`workspace.config.yaml`
`products[].repos[]` is the source of truth.** Declare a repo's URL there and `aiworks`
does the rest.

> For the full, illustrated walkthrough of `aiworks` and everything below, read
> **<a href="docs/aiworks.html" target="_blank" rel="noopener noreferrer"><code>docs/aiworks.html</code></a>** — the quick reference here is intentionally short.

```sh
scripts/aiworks sync                       # onboard EVERY repo in the config
scripts/aiworks sync your-product --dry-run # preview one product (runs nothing)
scripts/aiworks sync agent-db              # onboard ONLY one repo (by name)
scripts/aiworks sync --repo agent-db,paotung-template   # …or several named repos

scripts/aiworks add --url git@github.com:your-org/your-api.git \
                    --product backend --lang go --kind generic \
                    --desc "REST API + data layer"             # onboard one repo
scripts/aiworks remove your-api         # deregister (keeps the clone)
scripts/aiworks remove your-api --purge # also delete the clone (refuses if dirty/unpushed)

scripts/aiworks config                     # regen the dev-cycle.js CONFIG from the config
```

(Each subcommand has its own `-h`, e.g. `aiworks add -h`.)

### `sync` — the fast path

Reads `products[].repos[]` (optionally just one product) and runs the full per-repo
toolchain for each, pulling `url` / `kind` / `desc` / `lang` / `distribute` / `path` straight
from the config so you never retype them (`desc` is the one-line repo responsibility, surfaced
by `mani list projects`). Idempotent, so already-set-up repos report **SKIP** —
safe to re-run after adding a URL. Add `-n` / `--dry-run` to preview the commands.

### `add` — onboard one repo imperatively

Onboards a single repo from flags **and** writes its entry back into the config. Defaults
are derived from the URL:

- **clone dir / mani key / config entry** ← the repo name from the URL (e.g. `your-api/`)
- **`--product`** — its group under `products:` (and the `mani.d/<product>.yaml` file;
  default = the repo name)
- **`--kind`** — drives the role/gate defaults
- **`--lang` / `--distribute` / `--path`** — optional; `lang` is auto-detected if omitted

Under the hood, both `add` and `sync` will, for each repo:

- write a minimal entry under `products[].repos[]` (creating the config from the example
  if missing)
- generate its `mani.d/<product>.yaml` entry + `mani.yaml` `import:`, then clone via `mani sync`
- initialize git submodules first (`git submodule update --init --recursive`) when the repo
  declares a `.gitmodules` (a no-op otherwise)
- git-ignore the clone in the workspace `.gitignore` (and `agent_logs/` inside the repo)
- re-include the clone for **Cursor** indexing via a workspace-root `.cursorindexingignore`
  (`!<repo>/`) — Cursor honours `.gitignore` as a hard baseline and would otherwise skip the
  whole clone, so this negated entry keeps it git-ignored yet searchable (best-effort; varies
  by Cursor version). `.cursorignore` can't do this — its negations don't override `.gitignore`.
- make the clone searchable in **VS Code** via a workspace-root `.vscode/settings.json`
  (jq-merged, preserving your own keys): `search.useIgnoreFiles: false` so VS Code search
  stops honouring `.gitignore` (which hid the clones), plus `search.exclude` globs that
  re-exclude the noise — a few workspace-global `**/` keys and this repo's language-derived,
  repo-scoped build dirs (e.g. `<repo>/build`, `<repo>/.dart_tool`)
- build the codegraph index
- install the agent skill packs **at project scope** (karpathy plugin installed *and*
  enabled via `--scope project`; mattpocock skills installed one `--skill` per call)

Then, best-effort via `claude -p` (with live docker-style "glance" logs, a per-step token
report, and a per-step `--claude-timeout` so a hung step can't stall the run), it:

- scaffolds a **`CLAUDE.md`** from the repo's anatomy (≤60 lines; overflow goes into
  `.claude/rules/<topic>.md`; if one already exists it asks *regenerate / combine / skip*)
- runs the `/setup-matt-pocock-skills` skill
- seeds a **hardcoded, sonar-free hook + permission baseline** (`.claude/hooks` copied from
  the workspace; `settings.json` jq-merged so existing plugin enablement is preserved)
- scaffolds a **`scripts/dev.sh`** shaped by the repo's own toolchain, and runs the skill
  generator

Anything already done is skipped and reported. Any missing tool
(mani / codegraph / claude / npx / jq) is skipped with a printed summary + manual
follow-ups. At the end it **regenerates the `dev-cycle.js` CONFIG block** from the config.

### `remove` — the inverse

Deregisters the repo from `workspace.config.yaml` (matched by repo name in its URL), from
`mani.d/<product>.yaml` (deleting the file + its `mani.yaml` import if it was the product's
last repo), from the workspace `.gitignore`, from the workspace `.cursorindexingignore`
(the Cursor re-include line; the shared header comment is left behind), and from the workspace
`.vscode/settings.json` (this repo's `search.exclude` keys; the shared workspace-global keys
stay). The clone stays unless you pass `--purge`
(which refuses on a dirty/unpushed tree unless you also pass `--force`). It then
regenerates the `dev-cycle.js` CONFIG block too, so the repo drops out of the workflow
mirror automatically.

### `config` — keep the workflow mirror in sync

Regenerates the `── CONFIG ──` mirror in `.claude/workflows/dev-cycle.js` straight from
`workspace.config.yaml`. `sync` / `add` / `remove` all run it for you — call it directly
only after hand-editing a **non-repo** field (ticket prefix, statuses, flags).

---

## Run it

```sh
/dev-cycle FM-12                 # one ticket, end to end across every repo it touches
/dev-cycle FM-12 --dry-run       # review + test-suite gate, then STOP before merge + distribute
/dev-cycle FM-12 --approve-plan  # proceed past the plan-approval gate (when auto_approve is off)
```

A ticket that touches only one repo collapses to a simple single-repo flow.

---

## Verify the wiring (nothing destructive)

```sh
# Tracker (after .env) — reads print plain text; writes preview with --dry-run
scripts/tracker/get-ticket-details.sh <KEY>
scripts/tracker/find-tickets.sh --query "<keyword>" --open
scripts/tracker/upsert-ticket-details.sh <KEY> --status "<your in-progress name>" --dry-run
scripts/tracker/upsert-ticket-details.sh new --title "TEST" --body-file spec.md --dry-run

# VCS — provider auto-detect + dry-run the commands
scripts/vcs/default-branch.sh
scripts/vcs/open-pr.sh --title "TEST" --dry-run

# Sanity — workflows parse, adapters lint
node --check .claude/workflows/dev-cycle.js
bash -n scripts/vcs/*.sh scripts/tracker/*.sh
```

---

## Good to know

**The candidate is validated *before* merge.** Review and the cross-repo test-suite gate
both run on the ticket's work branches pre-merge, so a failing candidate never reaches the
base branch. Merge is the commit gate; distribution ships the *merged* build right after.
The test-suite gate runs only when the ticket's scope includes the registered test-suite
repo — needing end-to-end validation pulls that repo into scope (it builds + merges last).
If the scope flags the gate but omits the repo, the run auto-adds it; if no test-suite repo
is registered at all, the run ships with a loud warning (recorded in the summary) that the
requested gate did not run — it never reports an unvalidated run as test-suite-validated.

**Auto-merge** (`vcs.auto_merge`, default `true`) decides whether that merge happens
automatically. Set it `false` — or override a single repo with
`products[].repos[].auto_merge: false` — and the run still reviews + runs the test-suite
gate, then **stops and leaves the PR/MR open** for a human to merge. Nothing is merged or
distributed. (`--dry-run` stops at the same point.)

**Plan approval** (`planning.auto_approve`, default `true`) gates the *planning* step the
same way auto-merge gates the *merge* step. Set it `false` and the run produces the
plan(s), then stops for a human to approve — re-run with `--approve-plan` to continue.
With **Plan → HTML** (`planning.to_html`, default `false`) on, each plan is also rendered
to a self-contained interactive HTML doc (via write-interactive-docs) next to its
markdown — handy for sharing when approval is required.

**Ticket status is owned by the workflow**, not the per-repo agents. The dev-cycle moves
the ticket forward (monotonically) only at aggregate milestones, so a multi-repo ticket
can't thrash its status. It uses whatever you declare under `tracker.statuses`, picking
the best match per milestone (e.g. `ready_to_merge` if you have it, else `ready_to_test`).

**The reference impls are optional.** SonarQube (quality gate) and Firebase (distribution)
are just defaults — set `quality_gate.provider: none` and per-repo `distribute: none` to
skip them.

**Shared MCP services.** Container-backed MCP servers run as ONE long-lived, shared
container instead of a per-client `docker run` in `.mcp.json`. An stdio MCP server is
spawned once per client process, so the fan-out workflow's many subagents each spawned
their own container — and a crashed agent never closes the pipe, so `--rm` never fires and
the container orphans. The shared model fixes both: `.superset/mcp-compose.yml` defines the
stack (currently `postgres-mcp` over SSE on `127.0.0.1:8000`), `.mcp.json` points every
client at the SSE URL, and one container serves them all.

- **Lifecycle:** `scripts/aiworks setup` starts it (`up -d`, idempotent); `restart:
  unless-stopped` keeps it alive across reboots; `scripts/aiworks teardown` stops it and
  reaps any stray per-client MCP containers left by the old model.
- **Manual:** `.superset/mcp-services.sh up | down | reap | status`. `reap` kills orphan
  `postgres-mcp` / `mcp/sonarqube` containers while leaving the shared stack running.
- **Config:** override `DATABASE_URI` / `MCP_POSTGRES_PORT` in `.superset/.env` (git-ignored).
  If you change the port, update the URL in `.mcp.json` to match.
- **Not converted:** `redis` (run via `uvx`, not a container — upstream is stdio-only, no
  orphan problem) and `sonarqube` (managed by the `sonar` CLI). Their orphans, if any, are
  cleaned by `reap`.
- **Optional zero-touch start:** to bring the stack up automatically whenever a session
  begins (not just on `setup`), add a `SessionStart` hook to `.claude/settings.json` that
  runs `.superset/mcp-services.sh up` in the background.

**More docs:** `scripts/tracker/README.md` and `scripts/vcs/README.md` explain each
adapter and how to add a new provider.
