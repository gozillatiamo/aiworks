# CLAUDE.md — {{ORG_NAME}} Organization workspace

**Multi-repo workspace.** Nested repos are independent clones (own git
history, remote, `CLAUDE.md`) — read a repo's own `CLAUDE.md` first.

⚠️ **Before any git op:** `git rev-parse --show-toplevel` to confirm the
repo.

**Discover repos:** declared under `products[].repos[]` in `workspace.config.yaml`
(the source of truth); `mani.yaml` imports the per-product `mani.d/<product>.yaml`
files generated from it by `scripts/aiworks`. `mani list projects` for the full list.

**Cross-repo (`mani`):** `sync` (clone missing) · `list projects` ·
`exec --all '<cmd>'` · `run <task>`

## Configuration (read these first)

- `workspace.config.yaml` — the org's providers, ticket prefix, status lifecycle,
  branch model, auto-merge policy, planning policy (`planning.auto_approve` /
  `planning.to_html`), notification policy (`notify.enabled` / `notify.channel`), and the
  `products[].repos[]` registry (repo URLs). The source of truth for this workspace;
  `scripts/aiworks sync` sets everything up from it.
- `docs/agents/issue-tracker.md` — how to read/write tickets (the tracker adapter,
  status names, id format).
- Provider adapters: `scripts/vcs/` (PR/MR via `github`|`gitlab`),
  `scripts/tracker/` (tickets via `notion`|`jira`), and `scripts/notify/` (chat via
  `slack`). **Always go through the adapters — never call `gh`/`glab`/Notion/Jira/Slack
  directly.**

## Product Overview
{{PRODUCT_DESCRIPTION}}

## Tech Stack
- <frontend / app stack>
- <e2e testing stack>

## Product Structure
The group's repos are declared under `products:` in @workspace.config.yaml
(and cloned via the generated `mani.d/<product>.yaml` files).

**DO NOT:**
- codegraph is not allowed at the organization (workspace) level — only inside an
  individual repo.
