export const meta = {
  name: 'prd',
  description: 'PRD / design+ticketing workflow: embrace a BRD → CPO feature briefs → design UI-bearing features in Figma (planner → graphic assets → designer) → Product Owner writes self-contained tickets into the issue tracker. Pass a brd work-key ("phase-2"), a doc-space URL, a docs/brd/<key>.md path — or an EXISTING ticket key (e.g. APP-123, "complete detail for ticket APP-123") to enter TICKET MODE: the run completes THAT ticket in place (full spec written onto it) and creates NO new tickets unless the work demonstrably cannot ship under it.\n\nSTAGES (args.stage): omit/"all" = full headless run (design phase needs a Figma MCP that survives the workflow runtime — the OAuth claude.ai remote does NOT, so use the /prd-design skill instead for real frames). "intake" = CPO briefs only, returns features for an in-session design phase. "ticketing" = write tickets+summary from caller-supplied features + figmaByFeature (the /prd-design skill builds frames in-session, then calls this). See .claude/skills/prd-design/SKILL.md.',
  whenToUse: 'Turn an approved BRD into production-ready designs + a ready-for-dev backlog of tickets (each a PRD, with its Figma frame linked when UI-bearing). For real Figma frames, run via the /prd-design skill (in-session OAuth) — a raw Workflow(prd) call cannot author frames (the Figma MCP is unauthenticated inside the workflow runtime).',
  phases: [
    { title: 'Intake', detail: 'CPO: read the BRD(if exists) → prioritized feature briefs, each flagged UI-bearing or not', model: 'opus' },
    { title: 'Design', detail: 'CONDITIONAL — skipped entirely when no feature is UI-bearing, and skipped in stage=intake/ticketing (the /prd-design skill builds frames in-session because the Figma MCP is unauthenticated in the workflow runtime). Else per UI-bearing feature: ux-ui-planner plan → graphic-designer assets → ux-ui-designer Figma frames (all features in parallel)', model: 'opus/sonnet' },
    { title: 'Ticketing', detail: 'Product Owner writes one self-contained FM ticket per feature onto the Notion board, linking the Figma frame (TICKET MODE: completes the given existing ticket in place instead — no new tickets)', model: 'sonnet[1m]' },
    { title: 'Summary', detail: 'documentor writes the run-summary + per-role token/time table (summarize-workflow-performance)', model: 'haiku' },
  ],
}

// ──────────────────────────────────────────────────────────────────────────
// CONFIG  —  GENERATED FROM workspace.config.yaml BY scripts/aiworks. DO NOT EDIT THE
// MARKED BLOCK BELOW BY HAND. Workflow scripts have NO filesystem access, so this is the
// design slice of workspace.config.yaml mirrored in-source. To change it: edit
// workspace.config.yaml's design: block, then run `scripts/aiworks config` (or any
// `aiworks add` / `remove` / `sync`). See docs/agents/figma.md for the convention.
//
// DESIGN_ENABLED       — design.enabled. false ⇒ the design phase is SKIPPED entirely (no
//                        Figma at all; tickets carry build-ready specs, no frames).
// DESIGN_FIGMA_FILE_KEY — design.figma_file_key. The org's canonical Figma file. Set ⇒ build
//                        every feature into THIS file on a NEW PAGE, reuse its variables/
//                        components, NEVER create_new_file. Empty ⇒ orphan file + a WARN.
// DESIGN_PAGE_NAMING   — design.page_naming. Page-name template; tokens {work_key} {feature}.
// IMAGE_GEN_ENABLED    — image_generation.enabled. false ⇒ the graphic-designer generates NO
//                        images (every asset comes back 'unavailable'); the design phase stays
//                        specs/placeholder-only. Needs GEMINI_API_KEY when true.
// IMAGE_GEN_QUALITY    — image_generation.quality (fast|balanced|quality).
// IMAGE_GEN_MAX_PER_REQUEST — image_generation.max_per_request. The graphic-designer's budget cap.
// ──────────────────────────────────────────────────────────────────────────
// >>> AIWORKS:CONFIG START — generated from workspace.config.yaml; do not edit by hand <<<
const DESIGN_ENABLED = false     // from workspace.config.yaml design.enabled; false ⇒ design phase skipped (no Figma)
const DESIGN_FIGMA_FILE_KEY = '' // from workspace.config.yaml design.figma_file_key; set ⇒ build into THIS file (new page/feature), never create_new_file; empty ⇒ orphan file + WARN
const DESIGN_PAGE_NAMING = '{work_key} / {feature}'  // from workspace.config.yaml design.page_naming; tokens {work_key} {feature}
const IMAGE_GEN_ENABLED = false     // from workspace.config.yaml image_generation.enabled; false ⇒ graphic-designer generates no images (assets 'unavailable')
const IMAGE_GEN_QUALITY = 'balanced' // from workspace.config.yaml image_generation.quality (fast|balanced|quality)
const IMAGE_GEN_MAX_PER_REQUEST = 2        // from workspace.config.yaml image_generation.max_per_request; the graphic-designer's per-request budget cap
// <<< AIWORKS:CONFIG END >>>

// Build the per-feature directive the planner/designer get about WHERE to build. When a
// canonical file is configured we forbid create_new_file and name the page; otherwise we
// warn the output will be an orphan file (see docs/agents/figma.md).
const figmaTarget = (featureName, workKey) => {
  if (DESIGN_FIGMA_FILE_KEY) {
    const page = String(DESIGN_PAGE_NAMING || '{work_key} / {feature}')
      .split('{work_key}').join(workKey)
      .split('{feature}').join(featureName)
    return ` Build into the org's CANONICAL Figma file (fileKey ${DESIGN_FIGMA_FILE_KEY}) on a NEW PAGE named "${page}" — reuse that file's existing variables/components, add any genuinely-new tokens to ITS collections, and NEVER create_new_file. Return node URLs within that file.`
  }
  return ` No canonical Figma file is configured (design.figma_file_key is empty), so this run will create a NEW, ORPHAN Figma file — set design.figma_file_key in workspace.config.yaml to build into the org's one canonical file instead.`
}

// Image-generation policy the graphic-designer (Fiona) gets. OFF ⇒ generate nothing; ON ⇒
// carry the configured quality + per-request budget cap. See docs/agents/image-generation.md.
const imageGenRule = IMAGE_GEN_ENABLED
  ? ` Budget: generate AT MOST ${IMAGE_GEN_MAX_PER_REQUEST} image(s) this request, and pass quality='${IMAGE_GEN_QUALITY}' to every generate_image call.`
  : ` Image generation is DISABLED (image_generation.enabled=false in workspace.config.yaml): do NOT generate any image — set image_gen_available=false and return EVERY asset status='unavailable' with reason='image generation disabled by config'.`

// ──────────────────────────────────────────────────────────────────────────
// Input — auto-detect: brd work-key | doc-space/Figma URL | docs/brd/<key>.md path
// ──────────────────────────────────────────────────────────────────────────
const rawIn = (typeof args === 'string'
  ? args
  : (args?.brd || args?.input || args?.workKey || args?.phase || args?.url || args?.path || ''))?.trim()
if (!rawIn) throw new Error('prd needs a BRD ref: a work-key ("phase-2"), a doc-space URL, or a docs/brd/<key>.md path')

// Stage gate (see meta.description): 'all' (legacy full headless), 'intake', or 'ticketing'.
// The /prd-design skill drives 'intake' → in-session design → 'ticketing' so Figma frames are
// authored where the OAuth Figma session is valid (it is stripped inside this runtime).
const stage = (typeof args === 'object' && args?.stage) || 'all'

const isUrl = /^https?:\/\//i.test(rawIn)
const isPath = !isUrl && (/\.md$/i.test(rawIn) || rawIn.includes('/'))
const phaseMatch = rawIn.match(/phase\s*-?\s*(\d+)/i)
// TICKET MODE — the input names an EXISTING tracker ticket (e.g. "APP-2193", or a
// directive like "complete detail for bug ticket APP-2193"). The mission then is to
// COMPLETE that one ticket in place — enrich its spec — NOT to mint new per-feature
// tickets. "phase-N" refs are stripped before matching so "phase-2" never reads as a key.
const ticketMatch = !isUrl && !isPath
  && rawIn.replace(/phase\s*-?\s*\d+/gi, '').match(/\b([A-Za-z][A-Za-z0-9]{1,9}-\d+)\b/)
const ticketKey = ticketMatch ? ticketMatch[1].toUpperCase() : null
const workKey = ticketKey ? ticketKey.toLowerCase()
  : phaseMatch ? `phase-${phaseMatch[1]}`
  : isPath ? (rawIn.split('/').pop().replace(/\.md$/i, '') || 'brd')
  : isUrl ? 'brd-import'
  : (rawIn.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'brd')
const brdRef = ticketKey ? `the EXISTING tracker ticket ${ticketKey} — fetch it (scripts/tracker/get-ticket-details.sh ${ticketKey} and get-ticket-comments.sh ${ticketKey}); the requirement source is that ticket's current content PLUS the caller's directive "${rawIn}"`
  : isUrl ? `the doc-space URL ${rawIn} — fetch it`
  : isPath ? `the repo file ${rawIn} — Read it`
  : phaseMatch ? `roadmap ${workKey}: Read docs/brd/${workKey}.md (and/or its page in the team doc space, if any)`
  : `"${rawIn}": resolve as a BRD work-key — Read docs/brd/${workKey}.md (or the team doc space's BRD page)`

const tag = (role, phase, sub) => `[prd ${workKey} role=${role} phase=${phase}${sub ? ` sub=${sub}` : ''}]`

// Round cap — hard ceiling of 3 for any review↔revise loop (mirrors dev-cycle's
// MAX_GATE_ROUNDS). This linear pipeline has no loop wired yet; the constant
// bounds a future one to ≤3 (override LOWER via args.maxRounds — never higher).
const MAX_ROUNDS = Math.min(3, (typeof args === 'object' && args?.maxRounds) || 3)

// ──────────────────────────────────────────────────────────────────────────
// Schemas
// ──────────────────────────────────────────────────────────────────────────
const BRIEFS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['features'],
  properties: {
    features: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['name', 'ui_bearing', 'brief'],
      properties: {
        name: { type: 'string' },
        ui_bearing: { type: 'boolean' },
        brief: { type: 'string' },
        user_value: { type: 'string' },
        acceptance_intent: { type: 'array', items: { type: 'string' } },
        priority: { type: 'string', enum: ['High', 'Medium', 'Low'] },
        effort: { type: 'string', enum: ['Small', 'Medium', 'Large'] },
        dependencies: { type: 'array', items: { type: 'string' } },
      } } },
    notes: { type: 'string' },
  },
}
const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['plan_path'],
  properties: {
    plan_path: { type: 'string' }, flow: { type: 'string' },
    screens: { type: 'array', items: { type: 'string' } },
    asset_requests: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: { name: { type: 'string' }, spec: { type: 'string' } } } },
    states_summary: { type: 'string' },
  },
}
const ASSETS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['assets', 'image_gen_available'],
  properties: {
    // false → no usable image backend (no mcp-image / no GEMINI_API_KEY / quota): nothing was generated.
    image_gen_available: { type: 'boolean' },
    assets: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['name', 'status'],
      properties: {
        name: { type: 'string' },
        // created = generated this run; reused = already on the Assets page; placeholder = temp
        // stand-in (NOT dev-ready); unavailable = image-gen unusable, nothing produced.
        status: { type: 'string', enum: ['created', 'reused', 'placeholder', 'unavailable'] },
        figma_location: { type: ['string', 'null'] },
        reason: { type: 'string' },
      } } },
    note: { type: 'string' },
  },
}
const FIGMA_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['dev_ready'],
  properties: {
    dev_ready: { type: 'boolean' }, figma_file_url: { type: ['string', 'null'] },
    figma_frames: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: { screen: { type: 'string' }, url: { type: 'string' } } } },
    // States/frames still on a placeholder or unavailable asset — MUST be non-empty when any
    // asset-dependent state was built on a stand-in, and dev_ready MUST be false in that case.
    asset_gaps: { type: 'array', items: { type: 'string' } },
    note: { type: 'string' },
  },
}
const TICKETS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['tickets'],
  properties: {
    board_url: { type: 'string' }, coverage_note: { type: 'string' },
    tickets: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['task_name', 'url'],
      properties: {
        task_name: { type: 'string' }, url: { type: 'string' },
        ui_bearing: { type: 'boolean' }, figma_link: { type: ['string', 'null'] },
        priority: { type: 'string' }, effort: { type: 'string' },
      } } },
  },
}
const SUMMARY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['summary_path'],
  properties: { summary_path: { type: 'string' }, note: { type: 'string' } },
}

const spend = []
let mark = budget.spent()
const tick = (label) => { const now = budget.spent(); spend.push({ label, out: now - mark }); mark = now }

// ──────────────────────────────────────────────────────────────────────────
// 1. INTAKE  (CPO: BRD → prioritized feature briefs, UI-bearing flagged)
//    Runs for stage 'all' and 'intake'. For 'ticketing' the caller (the
//    /prd-design skill) supplies the briefs in args.features — intake is not re-run.
// ──────────────────────────────────────────────────────────────────────────
let briefs, features, uiFeatures
if (stage === 'all' || stage === 'intake') {
  phase('Intake')
  briefs = await agent(
    `${tag('cpo', 'intake')} As CPO, read the BRD (${brdRef}) and break it into a prioritized set of feature briefs for ${workKey}.${ticketKey ? ` TICKET MODE: these briefs are NOT future tickets — they are the aspects/sections of ONE complete spec the Product Owner will write back onto the existing ticket ${ticketKey}. Keep the set minimal and scoped to what ${ticketKey} itself needs to be complete and actionable; do not expand into a roadmap of adjacent work.` : ''} For EACH feature give: name, whether it is UI-bearing — true ONLY if the feature adds or changes screens/flows/widgets the user actually sees and taps; false for pure logic/data/infra (e.g. business/advisory engines, repositories & persistence, DTOs/serialization, data migrations, background services). When uncertain, mark it FALSE — designers (planner→assets→Figma) are spawned ONLY for genuinely UI-bearing features, so a non-UI mission must pull in NO designers at all; over-flagging burns a full design chain. Then a short brief, user value, acceptance intent (verifiable, not yet ticket ACs), Priority (High/Medium/Low), Effort (Small/Medium/Large), and dependencies on other features. Keep features small enough to become one ticket each. Use the product's own vocabulary from the BRD / workspace.config.yaml / CLAUDE.md.`,
    { agentType: 'cpo', phase: 'Intake', label: `intake:${workKey}`, schema: BRIEFS_SCHEMA },
  )
  features = briefs.features || []
  uiFeatures = features.filter((f) => f.ui_bearing)
  log(`Intake: ${features.length} features (${uiFeatures.length} UI-bearing → design; ${features.length - uiFeatures.length} spec-only)`)
  tick('intake')

  // Hybrid hand-off: stop after intake so the /prd-design skill can build Figma frames
  // IN-SESSION (the OAuth Figma MCP is unauthenticated inside this runtime), then
  // call back with stage:'ticketing'.
  if (stage === 'intake') {
    return {
      workKey, ticketKey, brdRef: rawIn, stage: 'intake', status: 'intake-done', maxRounds: MAX_ROUNDS,
      featureCount: features.length, uiFeatureCount: uiFeatures.length,
      features, uiFeatures, briefs, spend,
    }
  }
} else {
  // stage === 'ticketing' — briefs come from the orchestrating /prd-design skill.
  features = (typeof args === 'object' && Array.isArray(args?.features)) ? args.features : []
  uiFeatures = features.filter((f) => f.ui_bearing)
  briefs = { features }
  if (!features.length) throw new Error("prd stage='ticketing' needs args.features (the CPO briefs from the intake stage)")
}

// ──────────────────────────────────────────────────────────────────────────
// 2. DESIGN  (legacy headless path — stage 'all' ONLY)
//    CONDITIONAL — skipped ENTIRELY for non-UI missions. NOTE: a raw headless
//    Workflow(prd) run cannot author Figma frames — the OAuth Figma MCP is
//    stripped inside the workflow runtime (403). Real frames come from the
//    /prd-design skill, which runs this chain IN-SESSION (stage intake → design → ticketing).
//    This block is kept for the rare case a token-auth/local Figma MCP is wired
//    into the workflow runtime; otherwise the designer step returns dev_ready=false.
// ──────────────────────────────────────────────────────────────────────────
let designs = []
let figmaByFeature = {}
if (stage === 'all') {
  if (!DESIGN_ENABLED) {
    log(`Design: SKIPPED — Figma is disabled workspace-wide (design.enabled=false in workspace.config.yaml); tickets carry build-ready specs, no frames. Set design.enabled: true to design.`)
  } else if (uiFeatures.length === 0) {
    log(`Design: SKIPPED — 0/${features.length} features are UI-bearing; no designers spawned (spec-only mission → straight to Ticketing)`)
  } else {
    if (!DESIGN_FIGMA_FILE_KEY) log(`Design: WARN — design.figma_file_key is unset; frames go to a NEW ORPHAN Figma file. Set it in workspace.config.yaml to build into the org's canonical file.`)
    phase('Design')
    designs = (await parallel(uiFeatures.map((f) => async () => {
      const slug = (f.name || 'screen').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 32)
      // 2a. Plan (Mia) — flow, per-screen states, motion intent, asset request list.
      const plan = await agent(
        `${tag('ux-ui-planner', 'design', slug)} Design-plan the UI-bearing feature "${f.name}" (${workKey}). Brief: ${JSON.stringify(f).slice(0, 1500)}. Read the design system (read-only), map the flow, enumerate every per-screen state (loading/empty/error/success + feature-specific), name motion intent, select real design-system tokens/components, and produce the asset request list.${figmaTarget(f.name, workKey)} Record that implementation target (file + page + tokens/components to reuse) in the plan so Jane builds there. Write the plan to agent_logs/Mia_ux-ui-planner/${workKey}-${slug}-design-plan.md and return it.`,
        { agentType: 'ux-ui-planner', phase: 'Design', label: `plan:${slug}`, schema: PLAN_SCHEMA },
      )
      // 2b. Assets (Fiona) — only if the plan requested any.
      let assets = null
      if (plan.asset_requests && plan.asset_requests.length) {
        assets = await agent(
          `${tag('graphic-designer', 'design', slug)} Generate the assets requested by the design plan for "${f.name}" (${workKey}) and lay them into the Figma Assets page (6-col grid, transparent, species+number snake_case, @1x/2x/3x), under the budget rules.${imageGenRule} Requests: ${JSON.stringify(plan.asset_requests).slice(0, 1800)}. Run your availability gate FIRST: if image generation is disabled by config, or mcp__mcp-image is not in your toolset, or generation errors on auth/key/quota, set image_gen_available=false and mark every asset status='unavailable' with a reason+fix — do NOT improvise placeholders or claim assets exist. Otherwise return per-asset status (created/reused/placeholder/unavailable) and where each lives. Never report a placeholder/missing asset as created.`,
          { agentType: 'graphic-designer', phase: 'Design', label: `assets:${slug}`, schema: ASSETS_SCHEMA },
        )
      }
      // 2c. Build (Jane) — production Figma frames from the plan, using the assets.
      const figma = await agent(
        `${tag('ux-ui-designer', 'design', slug)} Build the production-ready Figma frames for "${f.name}" (${workKey}) from Mia's plan at ${plan.plan_path} — all screens and states, design-system tokens only, motion intent noted.${figmaTarget(f.name, workKey)} Assets available: ${assets ? JSON.stringify(assets.assets).slice(0, 1200) : 'none requested'}. Honor each asset's status: any state depending on a 'placeholder' or 'unavailable' asset is NOT dev-ready — list it in asset_gaps and set dev_ready=false. Return the frame URLs + the file URL; dev_ready=true ONLY when every state is covered, dev-ready, and asset_gaps is empty.`,
        { agentType: 'ux-ui-designer', phase: 'Design', label: `figma:${slug}`, schema: FIGMA_SCHEMA },
      )
      return { feature: f.name, plan, assets, figma }
    }))).filter(Boolean)
    log(`Design: ${designs.length}/${uiFeatures.length} UI features have Figma frames`)
  }
  tick('design')

  // Map feature name → primary Figma frame URL for the Product Owner to link.
  for (const d of designs) {
    const first = d.figma?.figma_frames?.[0]?.url || d.figma?.figma_file_url || null
    if (first) figmaByFeature[d.feature] = first
  }
} else {
  // stage === 'ticketing' — design happened in-session; the /prd-design skill passes the
  // results in. `designed` is a light [{ feature, figma_url }] list for the summary.
  figmaByFeature = (typeof args === 'object' && args?.figmaByFeature && typeof args.figmaByFeature === 'object') ? args.figmaByFeature : {}
  designs = (typeof args === 'object' && Array.isArray(args?.designed)) ? args.designed : []
}

// ──────────────────────────────────────────────────────────────────────────
// 3. TICKETING  (Product Owner writes ALL FM tickets onto the Notion board —
//    one self-contained PRD per feature, Figma linked for UI-bearing ones.)
//    Runs for stage 'all' and 'ticketing'. Touches no Figma MCP — only links
//    the frame URL strings supplied above — so it is headless-safe.
// ──────────────────────────────────────────────────────────────────────────
phase('Ticketing')
// Briefs JSON for the Product Owner — no silent caps: warn when the slice actually cuts
// features (a 4000-char cap once dropped 2 of 7 briefs without a trace).
const briefsJsonFull = JSON.stringify(features)
if (briefsJsonFull.length > 12000) log(`Ticketing: WARN — feature-brief JSON is ${briefsJsonFull.length} chars, truncated to 12000; later features may be cut from the Product Owner's context`)
const briefsJson = briefsJsonFull.slice(0, 12000)
const tickets = await agent(
  ticketKey
    ? `${tag('product-owner', 'ticketing')} As Product Owner, COMPLETE the EXISTING ticket ${ticketKey} IN PLACE — via /update-ticket (the tracker adapter; see docs/agents/issue-tracker.md). Synthesize ALL the briefs below into ONE self-contained spec and write it onto ${ticketKey}'s description: clear goal + user value, reproduction steps and expected-vs-actual if it is a bug, root-cause hypothesis, affected repos, verifiable acceptance criteria, scope boundaries + edge cases, and a dependency-ordered work breakdown as sections INSIDE the ticket. Do NOT create any new ticket unless the work demonstrably cannot ship under ${ticketKey} alone — and then explain why in coverage_note. Keep the ticket's existing Type (a Bug stays a Bug) and Status; never set read-only id fields; adjust Priority/Effort only when clearly warranted. For UI-bearing aspects, link the backing Figma frame inside the spec. Then ESTIMATE it: run \`/estimate-ticket ${ticketKey}\` so its calibrated Dev/QA points land in the point FIELDS — not done until those fields are set (a comment alone does not count).
  Feature briefs: ${briefsJson}.
  Figma frame per feature: ${JSON.stringify(figmaByFeature).slice(0, 2000)}.
  Return the updated ticket (task_name + ticket URL) — estimated (Dev/QA point fields set) — plus any ticket you genuinely had to create — and the board URL.`
    : `${tag('product-owner', 'ticketing')} As Product Owner, create one self-contained ticket per feature for ${workKey} in the issue tracker — via /clarifying-ticket (which uses the tracker adapter; see docs/agents/issue-tracker.md) and /to-prd. For each ticket: clear goal + user value, verifiable acceptance criteria, scope boundaries + edge cases, Priority and Effort from the brief, a "feature" type, and the org's not-started status (see issue-tracker.md; never set read-only id fields). For UI-bearing features, link the backing Figma frame in the ticket body/spec. Sequence tickets by dependency so the pipeline picks them up in order, and confirm full coverage (every feature → a ticket). Then ESTIMATE each ticket: run \`/estimate-ticket <KEY>\` per created ticket so calibrated Dev/QA points land in the ticket's point FIELDS — a ticket is NOT done until its point fields are set (a comment alone does not count).
  Feature briefs: ${briefsJson}.
  Figma frame per feature: ${JSON.stringify(figmaByFeature).slice(0, 2000)}.
  Return every created ticket (task_name + ticket URL + figma_link) — each already estimated (Dev/QA point fields set) — and the board URL.`,
  { agentType: 'product-owner', phase: 'Ticketing', label: `tickets:${workKey}`, schema: TICKETS_SCHEMA },
)
log(ticketKey
  ? `Ticketing: ${ticketKey} completed in place (${tickets.tickets?.length ?? 0} ticket(s) touched)`
  : `Ticketing: ${tickets.tickets?.length ?? 0} tickets created on the board`)
tick('ticketing')

// ──────────────────────────────────────────────────────────────────────────
// 4. SUMMARY  (required closing step — run-summary + per-role token/time table)
// ──────────────────────────────────────────────────────────────────────────
phase('Summary')
const summary = await agent(
  `Run-recorder for the PRD/design+ticketing workflow on work-key ${workKey}. Write the run-summary to agent_logs/${workKey}-PRD-SUMMARY.md (git-ignored): a short narrative — features intaken, UI features designed (with Figma links), and the FM tickets created (names + URLs) — from this result: ${JSON.stringify({ features: features.map((f) => f.name), designs: designs.map((d) => d.feature || d), tickets: tickets.tickets }).slice(0, 3500)}. Then, as the LAST step, run:\n  python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py ${workKey} --workflow prd\nand append its Markdown output VERBATIM under a "## Token & time usage" heading. Return the summary_path.`,
  { agentType: 'documentor', phase: 'Summary', label: `summary:${workKey}`, schema: SUMMARY_SCHEMA },
)
tick('summary')
log(`Run summary: ${summary.summary_path}`)

return {
  workKey, ticketKey, brdRef: rawIn, stage, status: 'tickets-ready', maxRounds: MAX_ROUNDS,
  featureCount: features.length, uiDesigned: Object.keys(figmaByFeature).length,
  tickets: tickets.tickets, board_url: tickets.board_url,
  briefs, designs, figmaByFeature, summary, spend,
}
