# Figma (design authoring & reading convention)

The single reference for **how every agent works with Figma** in this workspace —
both the design pipeline that *authors* frames (`ux-ui-planner` → `graphic-designer`
→ `ux-ui-designer`) and the dev/QA roles that *read* a design screen
(`development-planner`, `developer`, `qa-planner`, `qa-runner`, `documentor`).

It is governed by two fields under `design:` in `workspace.config.yaml` (see
`workspace.config.example.yaml`). The `scripts/aiworks config`/`sync` step mirrors
them into the workflow CONFIG blocks (`dev-cycle.js`, `prd.js`), because workflow
scripts can't read the filesystem at runtime.

## 1. `design.enabled` — the workspace-wide Figma switch (default **OFF**)

```yaml
design:
  enabled: false   # default — Figma is OFF for the whole workspace
```

- **`false` (default):** **no agent calls Figma.** The `/prd` design phase is
  **skipped entirely** (no planner/assets/designer spawned) — tickets carry
  build-ready written specs, not frame links. The dev/QA roles build from the ticket
  spec, **never** opening a Figma screenshot (the workflow appends an explicit "Figma
  is DISABLED — build from the spec" directive to their prompts).
- **`true`:** the design pipeline runs and the read-side roles may consult Figma. This
  needs a Figma MCP that is connected **in-session** — see the `/prd` skill preflight
  (`mcp.figma.com` OAuth is valid in-session but 403s inside a headless workflow, so
  real frames come from the `/prd` skill, not a raw `Workflow(prd)`).

An existing org that wants Figma must set `design.enabled: true` — it does not turn
on by itself.

## 2. `design.figma_file_key` — the org's ONE canonical design file

```yaml
design:
  figma_file_key: ""                        # the <KEY> in figma.com/design/<KEY>/…
  page_naming: "{work_key} / {feature}"     # page-name template; tokens {work_key} {feature}
```

Teams keep ONE canonical "Design System / UI" file. When `figma_file_key` is **set**
(and `enabled: true`), every `/prd` run builds its product screens **inside that
file** — never a fresh one:

- **Build on a NEW PAGE**, named from `page_naming` (default → one page per feature,
  e.g. `phase-2 / Vet booking`; use `"{work_key}"` for one shared page per run).
- **Reuse** the file's existing variables/components; add **genuinely-new** tokens to
  **its** collections (don't fork a parallel token set).
- **NEVER `create_new_file`** — that is the rule that prevents orphan files. Tickets
  then link node URLs *within* the canonical file.

When `figma_file_key` is **empty** (but `enabled: true`), behavior falls back to the
old `create_new_file` path **and the run WARNs** that the output is an orphan file
plus how to configure the canonical one. This is a degraded mode, not the goal.

## 3. Per-role behavior

| Role | When Figma is OFF (`enabled:false`) | When ON + canonical file set |
|---|---|---|
| **ux-ui-planner** | Not spawned by `/prd` (design phase skipped). | Reads the design system read-only; records the implementation target (file key + page name + tokens/components to reuse) in the plan. Never writes Figma. |
| **graphic-designer** | Not spawned. | Lays assets into the **canonical file's** Assets page. |
| **ux-ui-designer** | Not spawned. | Builds into the canonical file on the new page named by the orchestrator; reuses its variables/components; adds new tokens to its collections; **never `create_new_file`**. |
| **development-planner / developer / qa-planner / qa-runner** | Do **not** call Figma — build from the ticket spec / written plan. | May verify the linked design screen (read-only `get_screenshot`/`get_metadata`/`get_design_context`). |
| **documentor** | Skips Figma Slides/Canvas decks. | May build decks in Figma. |

## 4. How it's enforced

- **`/prd` skill** (in-session, has FS access): reads `design.*` from
  `workspace.config.yaml` at preflight; skips the whole design phase when off; passes
  the `fileKey` + per-feature page name to the planner/designer when on; warns on the
  empty-key orphan path.
- **`prd.js`** (headless): reads the mirrored `DESIGN_ENABLED` / `DESIGN_FIGMA_FILE_KEY`
  / `DESIGN_PAGE_NAMING`; same gating + `figmaTarget()` directive in the designer/planner
  prompts.
- **`dev-cycle.js`** (headless): mirrors `DESIGN_ENABLED` and appends a `FIGMA_DIRECTIVE`
  to the planner/build prompts when off, so the dev/QA agents don't reach for Figma.
- **Agents with FS access** should read `design.*` from `workspace.config.yaml` before
  any Figma call; agents inside a headless workflow honor the orchestrator's directive.
</content>
