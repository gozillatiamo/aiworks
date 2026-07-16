---
name: prd-design
description: Run the PRD pipeline (BRD → CPO briefs → in-session Figma design → tickets) as a main-agent-orchestrated hybrid so the Figma frames are actually built. Use this instead of a raw Workflow(prd) call whenever UI-bearing features need real Figma frames. Pass a BRD ref — a work-key ("phase-2"), a doc-space URL, or a docs/brd/<key>.md path.
---

# /prd-design — orchestrated PRD pipeline (with working Figma writes)

## Why this skill exists (read first)

The `prd` workflow's design phase builds Figma frames. But the only Figma MCP
connected here is the **claude.ai OAuth remote** (`mcp.figma.com`,
`mcp__claude_ai_Figma__*`), and **an interactively-OAuth'd MCP server is
unauthenticated inside the headless workflow runtime** → every Figma call from a
workflow `agent()` returns **403** → "No Figma frames". This is a platform
boundary, not a config: `mcp.figma.com` has no PAT/token mode, so it cannot be
made to authenticate inside `Workflow(...)`.

**The fix is structural:** the OAuth session is valid in the *main* session and
in any sub-agent spawned from it with the **Agent tool** (verified — an in-session
sub-agent's `whoami` returns the user identity). So this skill keeps the
non-Figma phases as headless workflows but runs the **design chain in-session**,
where Figma reads *and* writes work.

```
INTAKE      → Workflow(prd, {stage:'intake'})            headless, no Figma
DESIGN      → Agent(ux-ui-planner / graphic-designer /   in-session, OAuth Figma VALID
              ux-ui-designer) per UI feature              → real frames
TICKETING   → Workflow(prd, {stage:'ticketing', ...})    headless, links URL strings
+ SUMMARY
```

## Process

### 0. Design config — read it FIRST (gates everything below)
Read the `design:` block from `workspace.config.yaml` (the governance convention is
`docs/agents/figma.md`):
```bash
sed -n '/^design:/,/^[A-Za-z]/p' workspace.config.yaml   # enabled / figma_file_key / page_naming
```
- **`design.enabled` is `false` (the default) or the block is absent** → **Figma is OFF.**
  Skip preflights 0a/0b and **skip step 2 (DESIGN) entirely** — spawn NO ux-ui-planner /
  graphic-designer / ux-ui-designer. Tell the user "Figma is disabled (design.enabled=false)
  — producing spec-only tickets, no frames", then go straight to step 3 with an empty
  `figmaByFeature`. (Enabling Figma is a one-line config change: `design.enabled: true`.)
- **`design.enabled` is `true`** → proceed to 0a. Capture `figma_file_key` and
  `page_naming` (default `"{work_key} / {feature}"`) — you pass them into step 2:
  - **`figma_file_key` set** → the designer builds into THAT canonical file on a NEW PAGE
    per feature; **forbid `create_new_file`**.
  - **`figma_file_key` empty** → WARN the user the output will be a NEW ORPHAN file and how
    to configure the canonical one, then continue (create_new_file is allowed in this
    fallback only).

### 0a. Preflight — confirm Figma is connected
Run `claude mcp list` (Bash) and confirm a Figma server is **✔ Connected**
(`claude.ai Figma` → `mcp__claude_ai_Figma__*`).
- If connected: proceed.
- If **not** connected: tell the user to authenticate Figma (`/mcp` → connect
  Figma), or offer to run a **specs-only** pass (skip step 2's frame build; the
  designers still produce build-ready markdown specs, tickets link those instead
  of frames). Do not silently 403.

### 0b. Preflight — confirm image generation is available
**Config gate first:** read `image_generation.enabled` from `workspace.config.yaml`
(`sed -n '/^image_generation:/,/^[A-Za-z]/p' workspace.config.yaml`). If it is `false`
(the default) or absent, **image-gen is OFF by config** — don't probe the server or key;
treat image-gen as UNAVAILABLE and run the **placeholder/specs-only** path (the
graphic-designer returns every asset `unavailable`, the designer flags asset-dependent
states in `asset_gaps` and never marks them `dev_ready`). Tell the user how to enable it
(`image_generation.enabled: true`). If it is `true`, also capture `quality`
(fast|balanced|quality) and `max_per_request` to pass to Fiona, then continue:

The graphic-designer (`Fiona`) generates assets via the **`mcp-image`** server
(`mcp__mcp-image__generate_image`, Gemini) + the `/image-generation` skill. It
needs the server enabled **and** `GEMINI_API_KEY` set. A connected server with no
key still cannot generate — so check BOTH:
1. From `claude mcp list`, is **`mcp-image` ✔ Connected**?
2. Is the key present? `[ -n "$GEMINI_API_KEY" ]`, or a non-empty `GEMINI_API_KEY`
   in `.claude/settings.local.json` `env` (e.g.
   `grep -A2 '"env"' .claude/settings.local.json`).

- **Both true → image-gen available.** Proceed; the designers generate real assets.
- **Otherwise → image-gen UNAVAILABLE.** Do **not** proceed silently into placeholder
  art. Warn the user and offer an explicit choice:
  - **(a) Enable it** — set `GEMINI_API_KEY` in `.claude/settings.local.json`'s `env`
    block (get a key at https://aistudio.google.com/apikey), then restart the session
    so `mcp-image` picks it up. See `docs/agents/image-generation.md`.
  - **(b) Proceed placeholder/specs-only** — designers still build frames, but any
    asset-dependent state stays on an **explicit placeholder**, the graphic-designer
    returns `unavailable`/`placeholder`, and the ux-ui-designer must **flag those
    frames in `asset_gaps` and NOT mark them `dev_ready`**. Surface this in the final
    report so nobody mistakes a placeholder frame for finished work.
  - **(c) Abort** — stop the run.

  Pick the path with the user; never default into (b) silently.

### 1. INTAKE (headless workflow)
```
Workflow({ name: 'prd', args: { brd: '<the BRD ref the user passed>', stage: 'intake' } })
```
Returns `{ features, uiFeatures, briefs, workKey, ctoFindings, existing, anchorKey, revampKeys }`.
`ctoFindings` is the CTO's technical consulting pass (feasibility/risk/cross-repo/ADR/dependency
findings per feature) — it already ran headless in this call, no Figma needed. The `existing` /
`anchorKey` / `revampKeys` fields are the Recon result: a non-empty `revampKeys` means the board
ALREADY covers this and the Ticketing stage must REVAMP those tickets in place, not create new
ones. Keep `features`, `ctoFindings`, **and the three Recon fields** verbatim — you pass them all
back in step 3 untouched (this skill never edits or interprets them, just carries them across the
in-session design gap). If `uiFeatures` is empty, skip step 2 entirely (spec-only mission) and go
to step 3 with an empty `figmaByFeature`.

### 2. DESIGN (in-session — this is where you take control)
For **each** feature in `uiFeatures`, run the design chain with the **Agent tool**
(NOT a workflow). Run different features **concurrently** — issue the planner calls
for all features in one message — but keep each feature's own chain sequential
(plan → [assets] → frames). Pass `workKey` and the feature brief into each prompt —
and, when `figma_file_key` is set (preflight 0), the **fileKey + the per-feature page
name** (resolve `page_naming`: `{work_key}`→`workKey`, `{feature}`→the feature name).

1. **Plan** — `Agent(subagent_type: 'ux-ui-planner')`: design-plan the feature
   (reads the design system via Figma, writes the plan md, returns `plan_path` +
   `asset_requests`). Mirror the prompt the workflow used (see `prd.js` step 2a).
2. **Assets** — only if the plan returned `asset_requests`:
   `Agent(subagent_type: 'graphic-designer')` to generate them into the Figma
   Assets page. (prd.js step 2b.) Pass the `image_generation` policy from preflight 0b:
   if **disabled**, instruct it to generate nothing (return every asset `unavailable`);
   if **enabled**, tell it to pass `quality='<quality>'` to each generate_image call and
   generate at most `max_per_request` images. Require it to return `image_gen_available`
   plus a per-asset `status` (`created`/`reused`/`placeholder`/`unavailable`). If you chose
   the **placeholder/specs-only** path at preflight 0b (or the agent reports
   `image_gen_available:false`), expect `placeholder`/`unavailable` here — carry that
   forward, don't discard it.
3. **Build frames** — `Agent(subagent_type: 'ux-ui-designer')`: build the
   production Figma frames from the plan, using the assets. **When `figma_file_key` is
   set, instruct it to build into THAT canonical file on the NEW PAGE you name (reuse its
   variables/components, add new tokens to its collections) and to NEVER `create_new_file`;
   when the key is empty it may `create_new_file` (the warned orphan fallback).** Its Figma
   calls succeed because you are in-session. Require it to return `figma_frames[].url` +
   `figma_file_url`,
   `asset_gaps`, and `dev_ready`. Pass the asset statuses in; instruct it that any
   state on a `placeholder`/`unavailable` asset goes in `asset_gaps` and forces
   `dev_ready:false` — never let a placeholder frame come back `dev_ready:true`.
   (prd.js step 2c.)

Collect two structures as features complete:
- `figmaByFeature` — `{ "<feature name>": "<primary frame or file URL>" }`
- `designed` — `[ { feature: "<name>", figma_url: "<url>" } ]` (for the summary)

If a feature's frame build fails or returns no URL, record it with a `null`/note
and keep going — don't abort the whole run.

### 3. TICKETING + SUMMARY (headless workflow)
```
Workflow({ name: 'prd', args: {
  brd: '<same BRD ref>', stage: 'ticketing',
  features: <the features array from step 1>,
  ctoFindings: <the ctoFindings array from step 1>,
  existing: <the existing array from step 1>,       // Recon result — carry verbatim
  anchorKey: <the anchorKey from step 1>,            // so the PO revamps the existing
  revampKeys: <the revampKeys array from step 1>,    // backlog in place, not create anew
  figmaByFeature: <map from step 2>,
  designed: <list from step 2>,
} })
```
The Product Owner writes one self-contained ticket per feature, folds each feature's
CTO findings into its scope/dependencies plus a short "Technical notes" section (the
rest of the ticket stays business-requirement voice — see `prd.js`'s Ticketing step),
and links the Figma frame for UI-bearing ones (it only handles the URL *strings* — no
Figma MCP call, so it's headless-safe). The documentor writes the run summary.

### 4. Report
Summarize to the user: features intaken, frames built (with URLs), tickets created
(names + URLs + board URL), and any feature that fell back to specs-only or failed
to get a frame. Surface failures honestly — don't imply frames exist if a build
returned `dev_ready:false` or no URL. **Call out image-gen explicitly:** if assets
came back `placeholder`/`unavailable` or any frame reported `asset_gaps`, list those
frames as **not dev-ready (placeholder art)** and restate how to enable real
generation (preflight 0b option (a)). Never present a placeholder-backed frame as
finished.

## Notes
- Pass `args` as a real JSON object to Workflow, not a stringified one.
- Concurrency: the per-feature design chains are independent — batch them. The
  serial cost is one chain (plan→assets→frames), not the sum across features.
- This skill is the ONLY supported way to get real frames today. A raw
  `Workflow(prd)` (stage `all`) still runs end-to-end but its design phase will
  403 on Figma and produce no frames — use it only for spec/non-UI missions or
  if a token-auth/local Figma MCP has been wired into the workflow runtime.
