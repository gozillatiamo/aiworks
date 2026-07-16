# CLAUDE.md — {{ORG_NAME}} Organization workspace

**Multi-repo workspace.** Nested repos are independent clones (own git
history, remote, `CLAUDE.md`) — read a repo's own `CLAUDE.md` first.

⚠️ **Before any git op:** `git rev-parse --show-toplevel` to confirm the
repo.

**Discover repos:** declared under `products[].repos[]` in `workspace.config.yaml`
(the source of truth); `mani.yaml` imports the per-product `mani.d/<product>.yaml`
files generated from it by `scripts/aiworks`. `mani list projects` for the full list.

**Open in an IDE:** `scripts/aiworks` also generates a multi-root
`<workspace-basename>.code-workspace` from `products[].repos[]` (one folder root per repo +
the meta-repo root). Open the **file** (`cursor <workspace>.code-workspace`), not the folder,
so each product repo gets its own Source Control panel — opening the folder makes Git skip the
gitignored clones and only the meta-repo shows.

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
  `image_generation.max_per_request`), and the `products[].repos[]` registry
  (repo URLs). The source of truth for this workspace; `scripts/aiworks sync` sets
  everything up from it. Personal, non-shared overrides go in the git-ignored
  `workspace.config.local.yaml` (analogue of `.claude/settings.local.json`; see
  `workspace.config.local.example.yaml`) — it overrides this file for everything read at
  runtime (chat, agents, interactive skills); the committed workflow mirror stays shared-only.
- `CONTEXT.md` — the workspace glossary (ubiquitous language: orchestration, providers, repos,
  language, config). One place to look up a term; each entry links to its fuller home.
- `docs/adr/` — architecture decision records: why the workspace is shaped as it is
  (`0001` config mirror, `0002` output localization, `0003` personal runtime overrides).
- `docs/agents/language.md` — the output-language convention: `language: th` ⇒ **English
  spine, Thai prose** (prose in Thai; titles/headings/labels, all code + commits + branch
  names, and technical/domain terms stay English; code & checked-in repo docs never Thai).
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
- `docs/agents/submodules.md` — never develop inside a git **submodule** checkout: it's a
  read-only pointer to a repo that is *also* cloned as its own primary clone at the
  workspace root — branch/commit/PR in that primary clone (the coding-lifecycle skills
  consult this to redirect submodule'd changes to the right repo).
- Provider adapters: `scripts/vcs/` (PR/MR via `github`|`gitlab`),
  `scripts/tracker/` (tickets via `notion`|`jira`), and `scripts/notify/` (chat via
  `slack`). **Always go through the adapters — never call `gh`/`glab`/Notion/Jira/Slack
  directly.**
- **Test environment:** automated runs target **local** by default; staging is an
  explicit, QA-reserved opt-in (`CYPRESS_ENV=staging`). Defer to each repo's default —
  never hardcode an environment in agents/skills/workflow.

## Language
Output language follows `language` — from `workspace.config.local.yaml` if that personal
override exists, else `workspace.config.yaml` (full policy: `docs/agents/language.md`).
**Resolve this by reading the file on disk before your first output each session — never from
memory or from a value already quoted earlier in context.** `workspace.config.local.yaml` is
git-ignored, so it will not appear in any committed-file listing or prior summary of
`workspace.config.yaml`; its absence/presence must be checked directly (e.g. `ls`/`cat`), every
session, even if `workspace.config.yaml` was already read. When it is **`th`**, write **English
spine, Thai prose** — prose
in Thai (this CLI chat, tickets, PR/MR discussion, code review, plans, Slack) while the English
**spine** stays English: titles + every section heading + labels/enum values, ALL code + code
comments + git commit messages + branch names, and technical/transliterated/domain terms +
proper nouns (Arabic numerals always). **Code and checked-in repo docs** (`docs/`, `README`,
ADRs, committed PRD/BRD files) are **never** Thai. Default **`en`** ⇒ everything English, no change.

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
- Never edit, add, or commit **inside a git submodule checkout** (e.g.
  `your-app/shared-lib/`, `your-web/packages/ui-kit/`). That
  code belongs to a repo that is *also* cloned as its own primary clone at the workspace
  root — make the change there. See `docs/agents/submodules.md`.
