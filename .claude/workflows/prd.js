export const meta = {
  name: 'prd',
  description: 'PRD / design+ticketing workflow: embrace a BRD → CPO feature briefs → CTO technical consulting (feasibility/risk findings, folded into scope + a short "Technical notes" section — the ticket otherwise stays written in business-requirement voice) → design UI-bearing features in Figma (planner → graphic assets → designer) → Product Owner writes self-contained tickets into the issue tracker (splitting any ticket over 24 total points into independent, re-estimated pieces via /decompose-ticket). Pass a brd work-key ("phase-2"), a doc-space URL, a docs/brd/<key>.md path — or an EXISTING ticket key (e.g. APP-123, "complete detail for ticket APP-123") to enter TICKET MODE: the run completes THAT ticket in place (full spec written onto it) and creates NO new tickets unless the work demonstrably cannot ship under it. The run ALWAYS reconnoiters the board FIRST (Recon phase): when tickets already cover the request it AUTO-ENTERS TICKET MODE and revamps them in place rather than minting duplicates beside them. Every feature is a user-facing CAPABILITY — never a ticket whose deliverable is an ADR / doc / CONTEXT.md / skill (those are grounding, folded into the Technical notes of a ticket).\n\nSTAGES (args.stage): omit/"all" = full headless run (design phase needs a Figma MCP that survives the workflow runtime — the OAuth claude.ai remote does NOT, so use the /prd-design skill instead for real frames). "intake" = CPO briefs + CTO consult, returns features/ctoFindings for an in-session design phase. "ticketing" = write tickets+summary from caller-supplied features + ctoFindings + figmaByFeature (the /prd-design skill builds frames in-session, then calls this). See .claude/skills/prd-design/SKILL.md.',
  whenToUse: 'Turn an approved BRD into production-ready designs + a ready-for-dev backlog of tickets (each a PRD, with its Figma frame linked when UI-bearing). For real Figma frames, run via the /prd-design skill (in-session OAuth) — a raw Workflow(prd) call cannot author frames (the Figma MCP is unauthenticated inside the workflow runtime).',
  phases: [
    { title: 'Recon', detail: 'PO: read-only board search — do existing tickets already cover this request? Matches ⇒ auto TICKET MODE (revamp in place), never a duplicate set', model: 'haiku' },
    { title: 'Intake', detail: 'CPO: read the BRD(if exists) → prioritized feature briefs, each a user-facing CAPABILITY (never an ADR/doc/skill ticket), each flagged UI-bearing or not; in revamp mode each brief refreshes one existing ticket', model: 'opus' },
    { title: 'Consult', detail: 'CTO: technical consulting on the briefs — feasibility, risks, cross-repo touches, ADR implications, technical dependencies — per feature; consulting only, does not write the ticket. Also proposes independent decomposition (/decompose-ticket advise) for any feature heading past 24 total points', model: 'opus' },
    { title: 'Design', detail: 'CONDITIONAL — skipped entirely when no feature is UI-bearing, and skipped in stage=intake/ticketing (the /prd-design skill builds frames in-session because the Figma MCP is unauthenticated in the workflow runtime). Else per UI-bearing feature: ux-ui-planner plan → graphic-designer assets → ux-ui-designer Figma frames (all features in parallel)', model: 'opus/sonnet' },
    { title: 'Ticketing', detail: 'Product Owner writes one self-contained ticket per feature, folding CTO findings into scope + a short "Technical notes" section (rest of the ticket stays business-requirement voice), linking the Figma frame, and splitting any ticket over 24 total points via /decompose-ticket into independent, re-estimated pieces. REVAMP MODE (Recon found covering tickets): refreshes each existing ticket in place — inherits the anchor Sprint, groups a 4+ backlog under an Epic — and mints no duplicates. New tickets: dedup first, inherit sprint only from an anchor', model: 'sonnet' },
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
const LANGUAGE = 'en'     // from workspace.config.yaml language; 'th' ⇒ English spine, Thai prose (docs/agents/language.md; see LANGUAGE_DIRECTIVE); 'en' ⇒ unchanged
const DESIGN_ENABLED = false     // from workspace.config.yaml design.enabled; false ⇒ design phase skipped (no Figma)
const DESIGN_FIGMA_FILE_KEY = '' // from workspace.config.yaml design.figma_file_key; set ⇒ build into THIS file (new page/feature), never create_new_file; empty ⇒ orphan file + WARN
const DESIGN_PAGE_NAMING = '{work_key} / {feature}'  // from workspace.config.yaml design.page_naming; tokens {work_key} {feature}
const IMAGE_GEN_ENABLED = false     // from workspace.config.yaml image_generation.enabled; false ⇒ graphic-designer generates no images (assets 'unavailable')
const IMAGE_GEN_QUALITY = 'balanced' // from workspace.config.yaml image_generation.quality (fast|balanced|quality)
const IMAGE_GEN_MAX_PER_REQUEST = 2        // from workspace.config.yaml image_generation.max_per_request; the graphic-designer's per-request budget cap
// <<< AIWORKS:CONFIG END >>>

// Workspace output language (language). When 'th', prose-producing roles (ticketing, summary) get
// this appended so they write Thai prose with an English spine — see docs/agents/language.md.
const LANGUAGE_DIRECTIVE = (typeof LANGUAGE !== 'undefined' ? LANGUAGE : 'en') === 'th'
  ? ' OUTPUT LANGUAGE = th (docs/agents/language.md): write ALL prose — ticket description & comments, plans, the run summary — in THAI, but keep the English SPINE English: titles + every section heading + labels/enum values, ALL code + commit messages + branch names, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). A ticket SUMMARY/title stays English; its description & comments are Thai. Code and checked-in repo docs are NEVER Thai. If a git-ignored workspace.config.local.yaml sets a different language, that personal override wins — read it before you write.'
  : ''

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
// Recon — the READ-ONLY board search that runs BEFORE intake. Covering tickets it
// finds flip the run into revamp (auto TICKET MODE): refresh those in place, mint nothing.
const RECON_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['existing'],
  properties: {
    existing: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['key', 'title'],
      properties: {
        key: { type: 'string' },
        title: { type: 'string' },
        status: { type: 'string' },
        sprint: { type: ['string', 'null'] },   // the ticket's "Sprint: <name> (id <id>)" line, verbatim, if any
        parent: { type: ['string', 'null'] },    // its Parent/Epic key, if any
        covers: { type: 'string' },               // one line: which slice of the request this ticket covers
      } } },
    anchor: { type: ['string', 'null'] },         // the lead ticket the rest relate to — sprint + epic are inherited from it
    note: { type: 'string' },
  },
}
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
const CONSULT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['feature', 'feasible'],
      properties: {
        feature: { type: 'string' },
        feasible: { type: 'boolean' },
        approach: { type: 'string' },
        risks: { type: 'array', items: {
          type: 'object', additionalProperties: false,
          properties: { risk: { type: 'string' }, severity: { type: 'string' }, mitigation: { type: 'string' } } } },
        cross_repo: { type: 'array', items: { type: 'string' } },     // features that touch another repo
        adr_implications: { type: 'array', items: { type: 'string' } },
        technical_dependencies: { type: 'array', items: { type: 'string' } },  // sequencing vs other features
        // /decompose-ticket (advise): when a feature is heading past ~24 total points, the CTO
        // proposes independent vertical slices here — consulting only, the PO executes the split.
        decomposition: {
          type: 'object', additionalProperties: false,
          properties: {
            should_split: { type: 'boolean' },   // false ⇒ ships as one ticket (or irreducible)
            reason: { type: 'string' },
            pieces: { type: 'array', items: {
              type: 'object', additionalProperties: false,
              properties: {
                title: { type: 'string' }, goal: { type: 'string' },
                rough_dev: { type: 'number' }, rough_qa: { type: 'number' },
                depends_on: { type: 'array', items: { type: 'string' } },  // build order, not blocking-ownership
              } } },
          } },
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
  required: ['tickets', 'epic'],
  properties: {
    board_url: { type: 'string' }, coverage_note: { type: 'string' },
    tickets: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['task_name', 'url', 'sprint'],
      properties: {
        task_name: { type: 'string' }, url: { type: 'string' },
        ui_bearing: { type: 'boolean' }, figma_link: { type: ['string', 'null'] },
        priority: { type: 'string' }, effort: { type: 'string' },
        // Forces an explicit answer per ticket — "unscheduled" or the inherited sprint name/id,
        // never silently omitted. Catches the exact gap where a revamp rewrote ticket bodies
        // but never called --sprint on anything past the anchor.
        sprint: { type: 'string' },
      } } },
    // Whether this feature's backlog (4+ tickets touched/created) was grouped under an Epic.
    // Required so the decision is never silently skipped — if backlog < 4, applied:false with
    // reason "under 4 pieces" is the correct, expected answer.
    epic: { type: 'object', additionalProperties: false,
      required: ['applied', 'key', 'reason'],
      properties: {
        applied: { type: 'boolean' }, key: { type: ['string', 'null'] }, reason: { type: 'string' },
      } },
    // /decompose-ticket (execute): any ticket that re-estimated over 24 total points and was
    // split. Its pieces appear as their own entries in `tickets` above; this records the split.
    decompositions: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: {
        original: { type: 'string' },
        shape: { type: 'string', enum: ['replace', 'epic', 'irreducible'] },
        epic: { type: ['string', 'null'] },   // the new epic key when shape=epic
        pieces: { type: 'array', items: { type: 'string' } },  // the split ticket keys
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
let briefs, features, uiFeatures, consult
// Revamp state — populated by Recon (stage all/intake) or carried in from the
// /prd-design skill's intake call (stage ticketing). revampKeys non-empty ⇒ the board
// already covers this and we refresh those tickets in place instead of minting new ones.
let existing = [], anchorKey = ticketKey || null, revampKeys = ticketKey ? [ticketKey] : []
if (stage === 'all' || stage === 'intake') {
  // ──────────────────────────────────────────────────────────────────────────
  // 0. RECON  — the board is the source of truth: reconcile against it BEFORE
  //    minting anything. Read-only. Covering tickets ⇒ AUTO TICKET MODE: the
  //    Ticketing stage revamps them in place, never a parallel duplicate set.
  //    (This is the guardrail against filing 7 new tickets next to an existing backlog.)
  // ──────────────────────────────────────────────────────────────────────────
  phase('Recon')
  const recon = await agent(
    `${tag('product-owner', 'recon')} Board reconnaissance — READ-ONLY, create/modify NOTHING. The request is: ${brdRef}. Before any ticket is written, find every EXISTING tracker ticket that already covers a slice of this request: run \`scripts/tracker/find-tickets.sh --query "<distinctive term>" --open --json\` for a few distinctive terms drawn from the request (feature name, domain noun, entity), then \`get-ticket-details.sh\` the promising hits to confirm scope${ticketKey ? ` — and ALWAYS include ${ticketKey} plus every ticket it links to (relates/blocks) as covering tickets` : ''}. Return each covering ticket (key, title, status, its \`Sprint:\` line verbatim if present, its \`Parent:\`/epic if present, and one line on which slice it covers) and name the ANCHOR — the lead ticket the others relate to (Sprint + Epic are inherited from it). Return an empty list ONLY when the board genuinely tracks nothing on this. Missing an existing backlog and minting duplicates beside it is the exact failure this step exists to prevent.`,
    { agentType: 'product-owner', phase: 'Recon', label: `recon:${workKey}`, schema: RECON_SCHEMA },
  )
  existing = recon.existing || []
  const existingKeys = existing.map((e) => e.key).filter(Boolean)
  anchorKey = ticketKey || recon.anchor || existingKeys[0] || null
  revampKeys = Array.from(new Set([...(ticketKey ? [ticketKey] : []), ...existingKeys]))
  log(revampKeys.length
    ? `Recon: ${existing.length} existing ticket(s) cover this — AUTO-REVAMP in place (anchor ${anchorKey || '—'}); no duplicates minted`
    : `Recon: board has no covering tickets — fresh create mission`)
  tick('recon')

  phase('Intake')
  briefs = await agent(
    `${tag('cpo', 'intake')} As CPO, read the BRD (${brdRef}) and break it into a prioritized set of feature briefs for ${workKey}. UNIT OF WORK — every feature is a user-facing CAPABILITY (something an operator/user/system can now DO), NEVER a knowledge artifact: an ADR, a doc / CONTEXT.md / glossary, or a skill is GROUNDING and an engineering byproduct — it belongs in a ticket's "Technical notes", never as a feature/ticket of its own. If the request literally says "update the skills / docs / ADRs", that is the INPUT you build from, not the deliverable; the deliverable is the product capability underneath it.${revampKeys.length ? ` REVAMP MODE — the board ALREADY covers this: existing tickets ${JSON.stringify(existing).slice(0, 1400)}. Your briefs are NOT new tickets — each maps onto ONE existing ticket to REFRESH its spec (the Product Owner rewrites it in place). Propose a genuinely-new brief ONLY for a slice none of these cover, and say in each brief which existing ticket it refreshes. Do not re-slice work the backlog already carries.` : ''} For EACH feature give: name, whether it is UI-bearing — true ONLY if the feature adds or changes screens/flows/widgets the user actually sees and taps; false for pure logic/data/infra (e.g. business/advisory engines, repositories & persistence, DTOs/serialization, data migrations, background services). When uncertain, mark it FALSE — designers (planner→assets→Figma) are spawned ONLY for genuinely UI-bearing features, so a non-UI mission must pull in NO designers at all; over-flagging burns a full design chain. Then a short brief, user value, acceptance intent (verifiable, not yet ticket ACs), Priority (High/Medium/Low), Effort (Small/Medium/Large), and dependencies on other features. Keep features small enough to become one ticket each. Use the product's own vocabulary from the BRD / workspace.config.yaml / CLAUDE.md.`,
    { agentType: 'cpo', phase: 'Intake', label: `intake:${workKey}`, schema: BRIEFS_SCHEMA },
  )
  features = briefs.features || []
  uiFeatures = features.filter((f) => f.ui_bearing)
  log(`Intake: ${features.length} features (${uiFeatures.length} UI-bearing → design; ${features.length - uiFeatures.length} spec-only)`)
  tick('intake')

  // 2. CONSULT (CTO) — technical feasibility/risk findings per feature, ALWAYS run
  // (UI-bearing or not) and ALWAYS before tickets are written. Consulting only: the
  // CTO never writes ticket prose — the Product Owner (Ticketing stage) folds these
  // findings into scope/dependencies and a short "Technical notes" section, in the
  // ticket's own business-requirement voice.
  phase('Consult')
  consult = await agent(
    `${tag('cto', 'consult')} As CTO, do technical consulting on the CPO's feature briefs for ${workKey}${revampKeys.length ? ` (scoped to refreshing the existing ticket(s) ${revampKeys.join(', ')} in place — not new work)` : ''}. Features: ${JSON.stringify(features).slice(0, 3500)}. For EACH feature give: technical feasibility (true/false), the big-picture approach, risks (with severity + mitigation), any cross-repo touches, ADR implications, and technical dependencies/sequencing against the other features. This is consulting only — you do NOT write the ticket. The Product Owner will fold your risk/dependency findings into the ticket's scope and add a short "Technical notes" section for the developer from them; the rest of the ticket stays in business-requirement voice, so keep each finding a crisp, developer-actionable flag, not a design doc.\n  SOLUTION-FINDING — DECOMPOSE OVERSIZED WORK: for any feature large enough that its ticket would exceed ~24 total (Dev+QA) points, apply your /decompose-ticket (advise branch) judgment and fill the finding's \`decomposition\` field — propose independent VERTICAL SLICES (each a self-contained increment that can be built, reviewed, and shipped on its own, not a horizontal layer), giving each piece a title, one-line goal, rough Dev/QA sizing, and build order (\`depends_on\`). Set should_split=true only when the slices genuinely clear that independence bar; if the feature is irreducible, set should_split=false with the reason. Advise only — the Product Owner executes the split and re-estimates each piece.`,
    { agentType: 'cto', phase: 'Consult', label: `consult:${workKey}`, schema: CONSULT_SCHEMA },
  )
  const infeasible = (consult.findings || []).filter((f) => f.feasible === false)
  log(`Consult: ${consult.findings?.length ?? 0} feature(s) reviewed by CTO${infeasible.length ? ` — ⚠️ ${infeasible.length} feasibility concern(s)` : ''}`)
  tick('consult')

  // Hybrid hand-off: stop after intake+consult so the /prd-design skill can build Figma
  // frames IN-SESSION (the OAuth Figma MCP is unauthenticated inside this runtime), then
  // call back with stage:'ticketing'.
  if (stage === 'intake') {
    return {
      workKey, ticketKey, brdRef: rawIn, stage: 'intake', status: 'intake-done', maxRounds: MAX_ROUNDS,
      featureCount: features.length, uiFeatureCount: uiFeatures.length,
      features, uiFeatures, briefs, consult, ctoFindings: consult.findings || [],
      // Revamp state — the /prd-design skill MUST pass these back into its stage:'ticketing'
      // call so the Product Owner refreshes the existing backlog in place instead of creating.
      existing, anchorKey, revampKeys, spend,
    }
  }
} else {
  // stage === 'ticketing' — briefs AND CTO findings come from the orchestrating /prd-design
  // skill (carried over verbatim from its 'intake' call — intake/consult are not re-run).
  features = (typeof args === 'object' && Array.isArray(args?.features)) ? args.features : []
  uiFeatures = features.filter((f) => f.ui_bearing)
  briefs = { features }
  consult = { findings: (typeof args === 'object' && Array.isArray(args?.ctoFindings)) ? args.ctoFindings : [] }
  // Revamp state carried over from the intake stage (the /prd-design skill passes it back
  // verbatim). Recon does not re-run here, so an absent set means a plain create mission.
  existing = (typeof args === 'object' && Array.isArray(args?.existing)) ? args.existing : []
  anchorKey = (typeof args === 'object' && args?.anchorKey) || ticketKey || null
  revampKeys = (typeof args === 'object' && Array.isArray(args?.revampKeys) && args.revampKeys.length)
    ? args.revampKeys
    : (ticketKey ? [ticketKey] : [])
  if (!features.length) throw new Error("prd stage='ticketing' needs args.features (the CPO briefs from the intake stage)")
}

// ──────────────────────────────────────────────────────────────────────────
// 3. DESIGN  (legacy headless path — stage 'all' ONLY)
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
// 4. TICKETING  (Product Owner writes ALL FM tickets onto the Notion board —
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
// CTO consult findings, matched to features by name. Consulting input only — see the
// per-branch instruction below for exactly how these may touch the ticket text.
const ctoFindingsJson = JSON.stringify(consult.findings || []).slice(0, 3000)
const ctoNote = `CTO technical findings, from consulting (per feature, matched by name — informational, NOT ticket-ready prose): ${ctoFindingsJson}. Use these ONLY two ways: (1) fold any risk/dependency/cross-repo implication into the ticket's own scope-boundary and dependency-order language, written in plain business wording — never copy technical/architecture phrasing verbatim into those sections; (2) add ONE short "Technical notes" section at the end of the ticket — a few terse, developer-facing bullet lines (e.g. cross-repo touches, ADR flags, sequencing, risk+mitigation) — clearly separate from the business-requirement body above it, and never prescribing implementation, class/module design, or stack choices. Every OTHER section of the ticket must stay written from the business/user perspective. If any feature came back feasible:false or carries a high-severity risk, do not silently proceed — say so plainly in coverage_note. (A finding's \`decomposition\` field is handled separately — see the decomposition rule below, not the two text-uses above.)`
// The 24-point rule, wired into ticketing: an estimated ticket over 24 total points is split
// via /decompose-ticket. Shared by both prompt branches (feature-mode + ticket-mode).
const decompNote = `DECOMPOSE OVERSIZED TICKETS — the 24-point rule: after a ticket is estimated, if its total (Dev+QA) exceeds 24, invoke the \`decompose-ticket\` SKILL on <KEY> (execute branch) to split it into independently-deliverable pieces and re-estimate each — call it as a Skill, the same way a human would run \`/decompose-ticket <KEY>\`. Do NOT hand-roll the split yourself by calling \`upsert-ticket-details.sh new\` directly for the new pieces — the skill is the only place that reads the original's Sprint (and other original-ticket fields) and copies it onto every fresh piece via \`--sprint\`; bypassing it silently drops those fields from every split-off ticket. Start from the CTO finding's \`decomposition\` proposal for that feature when present (should_split=true lists the proposed independent slices); if a finding says should_split=false / the skill reports it irreducible, do NOT force a split. Each piece is itself a ticket — include every piece in the returned tickets list, and record each split in \`decompositions\` ({original, shape: replace|epic, epic, pieces[]}) and in coverage_note. Never let a >24 ticket flow onward whole unless /decompose-ticket reports it genuinely irreducible.`
const isRevamp = revampKeys.length > 0
const tickets = await agent(
  (isRevamp
    ? `${tag('product-owner', 'ticketing')} As Product Owner, REVAMP the existing backlog IN PLACE — Recon found the board already covers this request, so REFRESH those tickets rather than mint duplicates beside them. Existing covering tickets: ${JSON.stringify(existing).slice(0, 2000)}. Revamp keys: ${revampKeys.join(', ')}. Anchor (inherit its Sprint + any Epic from here): ${anchorKey || 'none'}.
  Work these steps IN ORDER — step 1 is whole-set bookkeeping and comes BEFORE any ticket body is touched, precisely so it never gets skipped as an afterthought once the per-ticket rewriting starts:
  STEP 1 — SPRINT + EPIC, decided ONCE for the whole ${revampKeys.length}-ticket set, before rewriting anything: (a) if ${revampKeys.length} >= 4 and they are not already under one shared Epic, create it now (\`upsert-ticket-details.sh new --issuetype Epic\`, inherit the anchor's Priority) and re-parent EVERY key in ${JSON.stringify(revampKeys)} under it via \`--parent <EPIC-KEY>\` — under 4 keys, skip the Epic (relates-to siblings suffice); (b) for every key in ${JSON.stringify(revampKeys)} that is NOT the anchor, read the anchor's Sprint (\`get-ticket-details.sh ${anchorKey || '<anchor>'}\`'s \`Sprint:\` line) and pass its id to \`--sprint\` on that key — every non-anchor ticket must end this step carrying the anchor's sprint, not just the anchor itself. Report this in the \`epic\` field of your return (required — answer it even when applied is false, e.g. "under 4 pieces").
  STEP 2 — for EACH existing ticket: map the matching brief(s) below onto it and rewrite its description via /clarifying-ticket (or /update-ticket) pointed AT THAT KEY — fold the refreshed spec in, CARRY FORWARD everything already on it (repro steps, acceptance criteria, links, pasted images) and DROP NOTHING; keep its Type and Status; adjust Priority/Effort only when clearly warranted. For UI-bearing aspects link the backing Figma frame inside the spec. Run /clarifying-ticket on EVERY key, not only the anchor. ${ctoNote}
  STEP 3 — create a NEW ticket ONLY for a slice that no existing ticket covers, inheriting the anchor's Sprint the same way as step 1(b) and relating it to the anchor. Explain any new ticket in coverage_note.
  STEP 4 — ESTIMATE every touched/created ticket: run \`/estimate-ticket <KEY>\` on EVERY key so calibrated Dev/QA points land in the point FIELDS (a comment alone does not count — this applies per-ticket, not just to the anchor). ${decompNote}
  Feature briefs: ${briefsJson}.
  Figma frame per feature: ${JSON.stringify(figmaByFeature).slice(0, 2000)}.
  Return every ticket touched (task_name + URL, its \`sprint\` — required per ticket, "unscheduled" if genuinely none), the \`epic\` decision (required), and any new piece created (recorded in \`decompositions\`), plus a coverage_note naming which tickets were refreshed vs created and why any new one was needed — and the board URL.`
    : `${tag('product-owner', 'ticketing')} As Product Owner, create one self-contained ticket per feature for ${workKey} in the issue tracker — via /clarifying-ticket (which uses the tracker adapter; see docs/agents/issue-tracker.md) and /to-prd. DEDUP FIRST — before creating each ticket, search the board (\`find-tickets.sh --query "<distinctive term>" --open\`); if a ticket already covers the feature, REFRESH that one in place (rewrite its body folding the brief in, keep its images/links) instead of filing a near-duplicate. For a genuinely-new ticket: clear goal + user value, verifiable acceptance criteria, scope boundaries + edge cases, Priority and Effort from the brief, a "feature" type, and the org's not-started status (see issue-tracker.md; never set read-only id fields). SPRINT — leave a brand-new feature UNSCHEDULED (do NOT pass --sprint); inherit --sprint only when the feature relates to an existing sprinted anchor ticket. For UI-bearing features, link the backing Figma frame in the ticket body/spec. Sequence tickets by dependency so the pipeline picks them up in order, and confirm full coverage (every feature → a ticket). ${ctoNote} Then ESTIMATE each ticket: run \`/estimate-ticket <KEY>\` per ticket so calibrated Dev/QA points land in the ticket's point FIELDS — not done until those fields are set (a comment alone does not count). ${decompNote} EPIC — a single feature that /decompose-ticket splits into 4+ pieces is grouped under an Epic by that skill (its N>=4 rule); do not hand-roll epics for features that ship as one ticket. Report this in the \`epic\` field of your return (required — applied:false with reason "single ticket, no split" is the normal answer here).
  Feature briefs: ${briefsJson}.
  Figma frame per feature: ${JSON.stringify(figmaByFeature).slice(0, 2000)}.
  Return every created/refreshed ticket (task_name + ticket URL + figma_link + its \`sprint\`, required per ticket — "unscheduled" unless inherited from an anchor) — each estimated (Dev/QA point fields set), the \`epic\` decision (required), plus any pieces produced by a split or Epic (recorded in \`decompositions\`) — and the board URL.`) + LANGUAGE_DIRECTIVE,
  { agentType: 'product-owner', phase: 'Ticketing', label: `tickets:${workKey}`, schema: TICKETS_SCHEMA },
)
log(isRevamp
  ? `Ticketing: revamped ${revampKeys.join(', ')} in place (${tickets.tickets?.length ?? 0} ticket(s) touched)`
  : `Ticketing: ${tickets.tickets?.length ?? 0} tickets created on the board`)
log(`Ticketing: epic ${tickets.epic?.applied ? `applied (${tickets.epic.key})` : 'not applied'} — ${tickets.epic?.reason || 'no reason given'}`)
tick('ticketing')

// ──────────────────────────────────────────────────────────────────────────
// 5. SUMMARY  (required closing step — run-summary + per-role token/time table)
// ──────────────────────────────────────────────────────────────────────────
phase('Summary')
const summary = await agent(
  `Run-recorder for the PRD/design+ticketing workflow on work-key ${workKey}. Write the run-summary to agent_logs/${workKey}-PRD-SUMMARY.md (git-ignored): a short narrative — features intaken, whether Recon found existing tickets and the run REVAMPED them in place (name the keys) vs created fresh, CTO feasibility concerns (if any), any oversized tickets decomposed into independent pieces, UI features designed (with Figma links), and the tickets created or refreshed (names + URLs) — from this result: ${JSON.stringify({ features: features.map((f) => f.name), revamped: revampKeys, cto_findings: consult.findings || [], decompositions: tickets.decompositions || [], designs: designs.map((d) => d.feature || d), tickets: tickets.tickets }).slice(0, 3500)}. Then, as the LAST step, run:\n  python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py ${workKey} --workflow prd\nand append its Markdown output VERBATIM under a "## Token & time usage" heading. Return the summary_path.` + LANGUAGE_DIRECTIVE,
  { agentType: 'documentor', phase: 'Summary', label: `summary:${workKey}`, schema: SUMMARY_SCHEMA },
)
tick('summary')
log(`Run summary: ${summary.summary_path}`)

return {
  workKey, ticketKey, brdRef: rawIn, stage, status: 'tickets-ready', maxRounds: MAX_ROUNDS,
  featureCount: features.length, uiDesigned: Object.keys(figmaByFeature).length,
  revamp: isRevamp, revampKeys, anchorKey, existing,
  tickets: tickets.tickets, decompositions: tickets.decompositions || [], epic: tickets.epic, board_url: tickets.board_url,
  briefs, consult, designs, figmaByFeature, summary, spend,
}
