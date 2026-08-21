export const meta = {
  name: 'prd',
  description: 'PRD workflow: a BRD becomes CPO feature briefs, a CTO feasibility consult, runtime root-cause triage for bug briefs, Figma design, then self-contained tickets in the tracker - ONE per feature with no points ceiling (the run never splits and never flags a ticket oversized; /decompose-ticket stays a human call). Recon runs FIRST: where tickets already cover the request it revamps them in place instead of minting duplicates beside them, and a DONE ticket is read-only reference. Pass a BRD work-key ("phase-2"), a doc-space URL, a docs/brd/<key>.md path, or an EXISTING ticket key to complete that ticket in place. args.stage: omit or "all" = full headless run, "intake" = briefs + consult only, "ticketing" = write tickets from caller-supplied features. WARNING: a raw Workflow(prd) call CANNOT author Figma frames - the Figma MCP is unauthenticated inside the workflow runtime - so use the /prd-design skill when real frames are wanted.',
  whenToUse: 'Turn an approved BRD into production-ready designs plus a ready-for-dev ticket backlog, each ticket a PRD with its Figma frame linked when UI-bearing. For real frames run it through /prd-design - a raw Workflow(prd) call cannot author them.',
  phases: [
    { title: 'Recon', detail: 'PO: read-only board search — do existing tickets already cover this request? Matches ⇒ auto TICKET MODE (revamp in place), never a duplicate set', model: 'haiku' },
    { title: 'Intake', detail: 'CPO: read the BRD(if exists) → prioritized feature briefs, each a user-facing CAPABILITY (never an ADR/doc/skill ticket), each flagged UI-bearing or not; in revamp mode each brief refreshes one existing ticket', model: 'opus' },
    { title: 'Consult', detail: 'CTO: technical consulting on the briefs — feasibility, risks, cross-repo touches, ADR implications, technical dependencies — per feature; consulting only, does not write the ticket, and never proposes a split (no points ceiling in this run)', model: 'opus' },
    { title: 'Investigate', detail: 'CONDITIONAL — only for briefs the CPO flagged as a bug/issue (skipped when every brief is a new capability): the developer (Noah) triages each at runtime — /root-cause-deployed when the symptom only exists in a deployed env (base rate -> hypothesis ledger -> discriminator -> CONFIRMED/LEADING/SPECULATIVE, with k8s_triage for the cluster\'s own account), /diagnosing-bugs (reproduce-first loop) + the /debugging-code DAP debugger when it is reproducible, returning the root cause + concrete reproduce steps + a SUGGESTED fix direction for the Product Owner to ground the ticket in. A THROWAWAY SANDBOX — MAY edit code/storage + run services to reproduce, but reverts every change and never commits; no /ticket-kickoff, no branch, no status change, no plan file, no PR. Runs on opus (model override) — Noah\'s tools + /diagnosing-bugs with the stronger model for root-cause reasoning', model: 'opus' },
    { title: 'Design', detail: 'CONDITIONAL — skipped entirely when no feature is UI-bearing, and skipped in stage=intake/ticketing (the /prd-design skill builds frames in-session because the Figma MCP is unauthenticated in the workflow runtime). Else per UI-bearing feature: ux-ui-planner plan → graphic-designer assets → ux-ui-designer Figma frames (all features in parallel)', model: 'opus/sonnet' },
    { title: 'Ticketing', detail: 'Product Owner writes one self-contained ticket per feature, folding CTO findings into scope + a short "Technical notes" section (rest of the ticket stays business-requirement voice), linking the Figma frame. One ticket per feature, no points ceiling, no split proposals. REVAMP MODE (Recon found covering tickets): refreshes each WRITABLE ticket in place and mints no duplicates — a DONE ticket is held read-only, an existing Parent/Epic is never changed, an Epic is minted only over 4+ PARENTLESS writable keys, and a sprint is only ever FILLED (never rescheduled: a ticket past not-started that already sits in an active sprint is left alone). New tickets: dedup first, inherit sprint only from an anchor', model: 'sonnet' },
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

// Workspace output language (language). When 'th', every prose-producing prompt (recon, intake,
// consult, ticketing, summary) gets this appended so they write Thai prose with an English spine
// — see docs/agents/language.md.
//
// RESOLVED DYNAMICALLY, not just from the committed LANGUAGE const above: the const is generated
// from workspace.config.yaml ONLY (a personal workspace.config.local.yaml override can never land
// in a committed file), and asking every downstream prose-producing agent to re-check that file
// itself proved unreliable in practice (measured ~0-100% compliance across roles — some roles
// reliably skip the check when absorbed in their actual task). A single dedicated resolver agent,
// whose ENTIRE job is that one Read, is far more reliable — do it once, here, and bake the result
// into every downstream prompt instead of hoping each one remembers.
const LANG_SCHEMA = { type: 'object', additionalProperties: false, required: ['language'], properties: {
  language: { type: 'string', enum: ['en', 'th'] }, source: { type: 'string' } } }
let RESOLVED_LANGUAGE = (typeof LANGUAGE !== 'undefined' ? LANGUAGE : 'en')
try {
  const langCheck = await agent(
    'Read `workspace.config.local.yaml` in the repo root if it exists AND has a `language:` line — that value wins, source="workspace.config.local.yaml". Otherwise read `workspace.config.yaml`\'s `language:` line (default "en" if absent), source="workspace.config.yaml". Return ONLY the resolved language ("en" or "th") and the source file — nothing else, no other files, no other analysis.',
    { agentType: 'documentor', label: 'resolve-language', schema: LANG_SCHEMA },
  )
  if (langCheck?.language === 'en' || langCheck?.language === 'th') RESOLVED_LANGUAGE = langCheck.language
} catch { /* any failure here keeps the committed-default fallback above */ }

const LANGUAGE_DIRECTIVE = RESOLVED_LANGUAGE === 'th'
  ? ' LANGUAGE_DIRECTIVE — OUTPUT LANGUAGE = th, already resolved for this run (docs/agents/language.md). This is AUTHORITATIVE: do NOT re-check any config file or override it with your own resolution — obey it verbatim. Write ALL prose — ticket description & comments and the .html render of a plan — in THAI, but keep the English SPINE English: titles + every section heading + labels/enum values, ALL code + commit messages + branch names, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). A ticket SUMMARY/title stays English; its description & comments are Thai. Code, checked-in repo docs, AND ANY file you author with a .md extension (plans, PRD/summary Markdown in agent_logs/) are NEVER Thai — the th prose rule applies to chat, tickets, PR/MR discussion, Slack, and .html docs only.'
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
// TICKET MODE — the input names an EXISTING tracker ticket (e.g. "OFB-2193", or a
// directive like "complete detail for bug ticket OFB-2193"). The mission then is to
// COMPLETE that one ticket in place — enrich its spec — NOT to mint new per-feature
// tickets. "phase-N" refs are stripped before matching so "phase-2" never reads as a key.
// A tracker "view ticket" URL (Jira browse/KEY, Linear issue/KEY/slug, ...) is TICKET MODE
// too — the key sits in its own path segment, unlike a generic doc-space/BRD URL. Matched as
// a whole path segment (bounded by / ? # or end) so a slug word never false-positives.
// Audited failure mode: a ticket's URL fell through to generic-BRD import instead of
// TICKET MODE because isUrl short-circuited the ticket-key check entirely — Recon then ran
// the multi-ticket revamp path instead of completing the one named ticket in place.
const urlTicketMatch = isUrl
  && rawIn.replace(/phase\s*-?\s*\d+/gi, '').match(/\/([A-Za-z][A-Za-z0-9]{1,9}-\d+)(?:[/?#]|$)/)
const ticketMatch = (!isUrl && !isPath
  && rawIn.replace(/phase\s*-?\s*\d+/gi, '').match(/\b([A-Za-z][A-Za-z0-9]{1,9}-\d+)\b/)) || urlTicketMatch
const ticketKey = ticketMatch ? ticketMatch[1].toUpperCase() : null
const workKey = ticketKey ? ticketKey.toLowerCase()
  : phaseMatch ? `phase-${phaseMatch[1]}`
  : isPath ? (rawIn.split('/').pop().replace(/\.md$/i, '') || 'brd')
  : isUrl ? 'brd-import'
  : (rawIn.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'brd')
const brdRef = ticketKey ? `the EXISTING tracker ticket ${ticketKey} — its current content is GROUND TRUTH, not background reading. Fetch ALL of it: scripts/tracker/get-ticket-details.sh ${ticketKey}, get-ticket-comments.sh ${ticketKey}, AND get-ticket-attachments.sh ${ticketKey}. Every attachment/image the last one lists MUST be downloaded (download-ticket-attachment.sh ${ticketKey} <ref> <path>) and viewed before drafting a single brief — a mockup or spec sitting in an attachment is core requirement, never decoration. This ticket's existing detail + comments + attachments is the PRIMARY requirement source; the caller's directive "${rawIn}" only narrows or refines it — it never overrides or substitutes for what the ticket already carries.`
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
      // `status` is REQUIRED, not decorative: the script derives the WRITABLE set from it
      // (a done ticket is reference-only, never rewritten), so an absent status would
      // silently re-open the hole this schema exists to close.
      required: ['key', 'title', 'status'],
      properties: {
        key: { type: 'string' },
        title: { type: 'string' },
        status: { type: 'string' },               // verbatim board status, e.g. "To Do" / "Done"
        sprint: { type: ['string', 'null'] },   // the ticket's "Sprint: <name> (id <id>)" line, verbatim, if any
        parent: { type: ['string', 'null'] },    // its Parent/Epic key, if any
        covers: { type: 'string' },               // one line: which slice of the request this ticket covers
      } } },
    anchor: { type: ['string', 'null'] },         // the lead ticket the rest relate to — its sprint MAY be inherited (never its epic)
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
        // true ⇒ this brief is a DEFECT/bug/issue-fix (a reported broken behavior), not a new
        // capability — it gets a developer (Noah) runtime root-cause triage before ticketing.
        is_bug: { type: 'boolean' },
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
        // NOTE: there is deliberately no `decomposition` field. This run never sizes a feature
        // against a points threshold and never proposes a split — one feature ships as one
        // ticket, however big. Splitting is a human decision: `/decompose-ticket <KEY> advise`.
      } } },
    notes: { type: 'string' },
  },
}
// Investigate — the developer's (Noah's) sandbox bug/issue triage (one per bug brief). Its facts
// (root cause + concrete repro + a SUGGESTED fix direction) ground the Product Owner's ticket; it
// is triage, not a plan/fix — every change is thrown away and Noah fixes for real once the ticket
// is picked up.
const INVESTIGATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feature', 'root_cause', 'reproduce_steps'],
  properties: {
    feature: { type: 'string' },                                    // matches the bug brief's name
    root_cause: { type: 'string' },                                 // where/why execution reaches the bad state
    reproduce_steps: { type: 'array', items: { type: 'string' } },  // runbook: ordered actions a human can follow (each the exact command/click), from a stated clean state
    fix_guideline: { type: 'string' },                              // a SUGGESTED direction, NOT a full plan
    affected: { type: 'array', items: { type: 'string' } },         // repos/files/symbols implicated
    // The evidence tier from /root-cause-deployed. SPECULATIVE is the ceiling for a single
    // sighting (n=1) however well the story fits — the Product Owner must not state one as
    // the cause. See .claude/skills/root-cause-deployed/SKILL.md.
    confidence: { type: 'string', enum: ['CONFIRMED', 'LEADING', 'SPECULATIVE'] },
    note: { type: 'string' },
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
    // OPTIONAL, and absent is the normal answer: an Epic is minted only over 4+ PARENTLESS
    // writable tickets (see EPIC_RULE). It is deliberately NOT required — a required field
    // whose only honest answer is "did not apply" is answered with confident filler instead
    // (a run once reported 4 tickets synced to a sprint the board says never changed).
    epic: { type: 'object', additionalProperties: false,
      required: ['applied', 'key', 'reason'],
      properties: {
        applied: { type: 'boolean' }, key: { type: ['string', 'null'] }, reason: { type: 'string' },
      } },
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
// Bug/issue triage state — populated by the Investigate phase (stage all/intake) or carried in
// from the /prd-design skill's intake call (stage ticketing). One entry per bug brief; empty on a
// pure-capability run. The Product Owner grounds each bug ticket in its matching investigation.
let bugInvestigations = []
if (stage === 'all' || stage === 'intake') {
  // ──────────────────────────────────────────────────────────────────────────
  // 0. RECON  — the board is the source of truth: reconcile against it BEFORE
  //    minting anything. Read-only. Covering tickets ⇒ AUTO TICKET MODE: the
  //    Ticketing stage revamps them in place, never a parallel duplicate set.
  //    (This is the guardrail against filing 7 new tickets next to an existing backlog.)
  // ──────────────────────────────────────────────────────────────────────────
  phase('Recon')
  const recon = await agent(
    `${tag('product-owner', 'recon')} Board reconnaissance — READ-ONLY, create/modify NOTHING. The request is: ${brdRef}. Before any ticket is written, find every EXISTING tracker ticket that already covers a slice of this request: run \`scripts/tracker/find-tickets.sh --query "<distinctive term>" --json\` for a few distinctive terms drawn from the request (feature name, domain noun, entity) — deliberately WITHOUT \`--open\`, so shipped work shows up too: a done ticket is what tells you a capability already exists, and the write-scope guard downstream keeps it read-only for you — then \`get-ticket-details.sh\` the promising hits to confirm scope${ticketKey ? ` — and ALWAYS include ${ticketKey} plus every ticket it links to (relates/blocks) as covering tickets` : ''}. Return each covering ticket (key, title, \`status\` — REQUIRED and verbatim, because a done ticket is held read-only downstream and a missing status defeats that guard — its \`Sprint:\` line verbatim if present, its \`Parent:\`/epic if present, and one line on which slice it covers) and name the ANCHOR — the lead ticket the others relate to (its Sprint MAY be inherited by tickets that have none; its Epic is NEVER copied to anything). Include a done/shipped ticket when it genuinely covers a slice — it will be kept as read-only context, so it costs nothing to report and losing it costs the run real grounding. Return an empty list ONLY when the board genuinely tracks nothing on this. Missing an existing backlog and minting duplicates beside it is the exact failure this step exists to prevent.` + LANGUAGE_DIRECTIVE,
    { agentType: 'product-owner', phase: 'Recon', label: `recon:${workKey}`, schema: RECON_SCHEMA },
  )
  existing = recon.existing || []
  const existingKeys = existing.map((e) => e.key).filter(Boolean)
  // TICKET MODE (ticketKey set): the caller named ONE ticket to complete in place — per the
  // skill's own contract that IS the whole write scope. Recon may still surface other
  // "covering" tickets (e.g. a broader ticket that also touches this slice); keep them in
  // `existing` as read-only context for the Product Owner, never fold them into revampKeys —
  // doing so previously turned a single-ticket clarify into an unwanted second write target
  // (audited failure: a second, merely-related ticket got revamped alongside the one ticket
  // the user actually named).
  if (ticketKey) {
    anchorKey = ticketKey
    revampKeys = [ticketKey]
  } else {
    anchorKey = recon.anchor || existingKeys[0] || null
    revampKeys = Array.from(new Set(existingKeys))
  }
  log(revampKeys.length
    ? `Recon: ${existing.length} existing ticket(s) cover this — AUTO-REVAMP in place (anchor ${anchorKey || '—'}); no duplicates minted`
    : `Recon: board has no covering tickets — fresh create mission`)
  tick('recon')

  phase('Intake')
  briefs = await agent(
    `${tag('cpo', 'intake')} As CPO, read the BRD (${brdRef}) and break it into a prioritized set of feature briefs for ${workKey}. UNIT OF WORK — every feature is a user-facing CAPABILITY (something an operator/user/system can now DO), NEVER a knowledge artifact: an ADR, a doc / CONTEXT.md / glossary, or a skill is GROUNDING and an engineering byproduct — it belongs in a ticket's "Technical notes", never as a feature/ticket of its own. If the request literally says "update the skills / docs / ADRs", that is the INPUT you build from, not the deliverable; the deliverable is the product capability underneath it.${ticketKey ? ` TICKET MODE — the caller named ONE existing ticket, ${ticketKey}, to complete in place: return EXACTLY ONE brief, for ${ticketKey} itself. A defect, gap, or missing-guard you discover while grounding/reading ${ticketKey} is NOT a second brief and is NEVER \`is_bug: true\` on its own — fold it straight into this one brief's \`acceptance_intent\` as an added acceptance criterion. Propose a second brief ONLY if the request genuinely names a second, independent ticket to touch (rare) — never for a finding surfaced while scoping the ticket you were handed (audited failure: this exact pattern spawned an unwanted sibling ticket that duplicated scope already inside the named ticket).`
  : revampKeys.length ? ` REVAMP MODE — the board ALREADY covers this: existing tickets ${JSON.stringify(existing).slice(0, 1400)}. Your briefs are NOT new tickets — each maps onto ONE existing ticket to REFRESH its spec (the Product Owner rewrites it in place). Propose a genuinely-new brief ONLY for a slice none of these cover, and say in each brief which existing ticket it refreshes. Do not re-slice work the backlog already carries.` : ''} For EACH feature give: name, whether it is UI-bearing — true ONLY if the feature adds or changes screens/flows/widgets the user actually sees and taps; false for pure logic/data/infra (e.g. business/advisory engines, repositories & persistence, DTOs/serialization, data migrations, background services). When uncertain, mark it FALSE — designers (planner→assets→Figma) are spawned ONLY for genuinely UI-bearing features, so a non-UI mission must pull in NO designers at all; over-flagging burns a full design chain. Also flag \`is_bug\`: true when the brief is a DEFECT/bug/issue-fix — a reported broken behavior to correct — rather than a NEW capability; false (the default) for genuine new capabilities. Each is_bug=true brief gets a developer (Noah) runtime root-cause investigation before ticketing (root cause + reproduce steps + a suggested fix), so the resulting ticket is grounded in facts, not a vague symptom — flag it whenever the source is a bug report / broken behavior (this INCLUDES a Bug-type ticket in TICKET MODE). Then a short brief, user value, acceptance intent (verifiable, not yet ticket ACs), Priority (High/Medium/Low), Effort (Small/Medium/Large), and dependencies on other features. Keep features small enough to become one ticket each. Use the product's own vocabulary from the BRD / workspace.config.yaml / CLAUDE.md.` + LANGUAGE_DIRECTIVE,
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
    `${tag('cto', 'consult')} As CTO, do technical consulting on the CPO's feature briefs for ${workKey}${revampKeys.length ? ` (scoped to refreshing the existing ticket(s) ${revampKeys.join(', ')} in place — not new work)` : ''}. Features: ${JSON.stringify(features).slice(0, 3500)}. For EACH feature give: technical feasibility (true/false), the big-picture approach, risks (with severity + mitigation), any cross-repo touches, ADR implications, and technical dependencies/sequencing against the other features. This is consulting only — you do NOT write the ticket. The Product Owner will fold your risk/dependency findings into the ticket's scope and add a short "Technical notes" section for the developer from them; the rest of the ticket stays in business-requirement voice, so keep each finding a crisp, developer-actionable flag, not a design doc.\n  DO NOT PROPOSE A SPLIT: this run has no points ceiling and one feature becomes one ticket however large. Do not size a feature against a threshold, do not propose decomposition, and do not name seams "for later" — splitting is a human decision made by running \`/decompose-ticket <KEY> advise\`, and an unbidden split proposal here becomes noise the Product Owner then has to reconcile. If a feature is genuinely enormous, say so in \`notes\` as a risk, in one line, with no proposed pieces.` + LANGUAGE_DIRECTIVE,
    { agentType: 'cto', phase: 'Consult', label: `consult:${workKey}`, schema: CONSULT_SCHEMA },
  )
  const infeasible = (consult.findings || []).filter((f) => f.feasible === false)
  log(`Consult: ${consult.findings?.length ?? 0} feature(s) reviewed by CTO${infeasible.length ? ` — ⚠️ ${infeasible.length} feasibility concern(s)` : ''}`)
  tick('consult')

  // ──────────────────────────────────────────────────────────────────────────
  // 2b. INVESTIGATE (developer / Noah) — bug/issue TRIAGE in a THROWAWAY SANDBOX.
  //    CONDITIONAL: runs only for briefs the CPO flagged is_bug. A Product Owner can't
  //    write a real bug ticket from a vague symptom, so Noah confirms the cause in the
  //    running code via /diagnosing-bugs (reproduce-first loop) + the /debugging-code DAP
  //    debugger, and returns the root cause, concrete reproduce steps, and a SUGGESTED fix
  //    direction. To reproduce he MAY edit code, write storage, and run services — but it is a
  //    THROWAWAY SANDBOX: he reverts every change (git clean + rolled-back/scratch storage +
  //    stopped services), NEVER commits/opens a PR, and does NOT /ticket-kickoff, branch,
  //    change Status, or write a plan file. The workspace ends exactly as found; Noah fixes for
  //    real only once the ticket is later picked up.
  //    WHY Noah, not the planner: he already holds every write/run/DB tool + /diagnosing-bugs +
  //    debugging-code, so no new grant and no erosion of the planner's clean read-only role.
  //    Runs per bug brief in parallel; feeds the Ticketing stage (and the intake hand-off).
  // ──────────────────────────────────────────────────────────────────────────
  const bugFeatures = features.filter((f) => f.is_bug)
  if (bugFeatures.length) {
    phase('Investigate')
    bugInvestigations = (await parallel(bugFeatures.map((f) => async () => {
      const finding = (consult.findings || []).find((c) => c.feature === f.name)
      const slug = (f.name || 'bug').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 32)
      return agent(
        `${tag('developer', 'investigate', slug)} Bug/issue TRIAGE for the PRD pipeline — a SANDBOX investigation to GROUND the ticket, NOT feature development and NOT shipping. You are Noah, but here you do NOT implement/commit/ship — you reproduce the bug, pin the cause, and report, throwing every change away (see the SANDBOX rules at the end). Reported bug/issue: ${JSON.stringify(f).slice(0, 1600)}.${finding ? ` CTO technical consult on it (cross-repo touches, risks, ADR flags): ${JSON.stringify(finding).slice(0, 1200)}.` : ''}${ticketKey ? ` The tracker ticket is ${ticketKey} — fetch it read-only (scripts/tracker/get-ticket-details.sh ${ticketKey}, get-ticket-comments.sh ${ticketKey}) for the reported symptom + any repro the reporter gave.` : ''} FIRST decide which discipline applies, because picking wrong is how this phase produced a confident wrong answer before. If the symptom exists ONLY in a deployed environment and there is nothing to press — a prod trace id, an intermittent 5xx, a pod already replaced — there is no loop to build: invoke \`/root-cause-deployed\` and follow it (count the failure class with scripts/observability/find-traces.sh BEFORE theorising, keep a ledger of at least two competing hypotheses, run a discriminator, grade the answer CONFIRMED / LEADING / SPECULATIVE). Use \`k8s_triage\` for the cluster's own account of whether the request ever arrived — pod replacements, previous=true logs, endpoint membership, gateway route/upstream config. Otherwise, when the bug IS reproducible, invoke \`/diagnosing-bugs\` to drive a reproduce-first loop (locate the touched repo/module via codegraph, get the bug reproducing from a clean state), and when a static read / print can't reveal HOW execution reaches the bad state, step through the running program with the \`/debugging-code:debugging-code\` DAP debugger (breakpoints — incl. conditional — step line-by-line, inspect live variables + the call stack). Return: \`root_cause\` (where/why execution reaches the bad state), \`reproduce_steps\` (a runbook a teammate can follow blind: an ordered list where each step is ONE actionable thing they DO — the exact command / click path / field+value, imperative — not a narration of what happened; state the clean starting state as the first entry so it is reproducible from scratch), \`fix_guideline\` (a SUGGESTED direction for the fix — a pointer, NOT a full implementation plan; Noah plans the real fix later), \`affected\` (repos/files/symbols), and \`confidence\` — the evidence tier, CONFIRMED only when a discriminator left one hypothesis standing or you reproduced it, SPECULATIVE whenever you have a single sighting. Do not round it up. 🛑 THROWAWAY SANDBOX — to reproduce/pin the cause you MAY edit code, write storage, and run services/builds (a probe/log line, the failing service via scripts/dev.sh, a seeded row / pushed stream event, the DAP debugger). But leave the workspace EXACTLY as found: NEVER git commit/push/tag or open an MR; do NOT /ticket-kickoff, create/checkout a branch, change ticket Status, or write a plan file. Before returning, restore every touched repo to pristine (git checkout -- . + git clean -fd, or drop your stash) so git status is clean, and edit ONLY in the primary clone, never a submodule. Storage writes go inside a ROLLED-BACK transaction or a scratch schema/keys you DROP/DEL — never persistently mutate the shared dev Postgres/Redis. Run services ephemerally and STOP them; touch no shared/staging environment. Verify zero residue (clean git status, services down, storage restored) and report that you did. Return the findings only.` + LANGUAGE_DIRECTIVE,
        // model:'opus' overrides Noah's default sonnet — root-cause reasoning is the hard part here,
        // so pair his tools + /diagnosing-bugs discipline with the stronger model for this phase only.
        { agentType: 'developer', model: 'opus', phase: 'Investigate', label: `investigate:${slug}`, schema: INVESTIGATE_SCHEMA },
      )
    }))).filter(Boolean)
    log(`Investigate: ${bugInvestigations.length}/${bugFeatures.length} bug/issue item(s) triaged (root cause + repro + suggested fix) for the Product Owner`)
  } else {
    log(`Investigate: SKIPPED — no bug/issue briefs (every feature is a new capability); nothing to triage`)
  }
  tick('investigate')

  // Hybrid hand-off: stop after intake+consult so the /prd-design skill can build Figma
  // frames IN-SESSION (the OAuth Figma MCP is unauthenticated inside this runtime), then
  // call back with stage:'ticketing'.
  if (stage === 'intake') {
    return {
      workKey, ticketKey, brdRef: rawIn, stage: 'intake', status: 'intake-done', maxRounds: MAX_ROUNDS,
      featureCount: features.length, uiFeatureCount: uiFeatures.length,
      features, uiFeatures, briefs, consult, ctoFindings: consult.findings || [],
      // Bug/issue triage — the /prd-design skill MUST pass this back into its stage:'ticketing'
      // call verbatim so the Product Owner grounds each bug ticket in its investigation.
      bugInvestigations,
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
  // Bug/issue triage carried over from the intake stage (the /prd-design skill passes it back
  // verbatim). Investigate does not re-run here, so an absent set means no bug briefs to ground.
  bugInvestigations = (typeof args === 'object' && Array.isArray(args?.bugInvestigations)) ? args.bugInvestigations : []
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
// ── WRITE SCOPE — the single choke point ────────────────────────────────────
// Both entry paths converge here: revampKeys computed by Recon (stage all/intake) and
// revampKeys handed in by a caller (stage 'ticketing', e.g. the /prd-design skill). The
// filter therefore sits HERE and nowhere else, so neither path can smuggle a done ticket
// into the Product Owner's prompt.
//
// A DONE ticket is a REFERENCE ticket: shipped work, kept for coverage context and as the
// estimation calibration set. It is never rewritten, re-parented, or re-sprinted. Saying so
// in the prompt was already tried — Recon's search has always passed `--open` — and a run
// still rewrote three shipped tickets, so the rule lives in code, not in wording.
//
// EXCEPTION: a ticket key the human named explicitly (TICKET MODE) is honored even when
// done — an operator naming a key means it, and the ban exists to stop the RUN guessing.
const isDoneStatus = (s) => String(s || '').trim().toLowerCase() === 'done'
// Canonical done name comes from workspace.config.yaml `tracker.statuses.done` ("DONE" here),
// which prd.js's generated CONFIG block does not (yet) mirror — if the org renames its done
// status to something other than Done/DONE, extend this predicate and say so in the MR.
const statusOf = (k) => (existing.find((e) => e.key === k) || {}).status
const referenceKeys = revampKeys.filter((k) => k !== ticketKey && isDoneStatus(statusOf(k)))
const writableKeys = revampKeys.filter((k) => !referenceKeys.includes(k))
if (referenceKeys.length) {
  log(`Ticketing: ${referenceKeys.length} done ticket(s) held READ-ONLY (reference, not revamped): ${referenceKeys.map((k) => `${k} [${statusOf(k)}]`).join(', ')}`)
}
// A key whose status we do not know cannot be filtered — say so rather than silently
// treating "unknown" as "open" (only reachable when a caller passes revampKeys without the
// matching `existing` entries; Recon and /prd-design always supply both).
const unknownStatusKeys = revampKeys.filter((k) => k !== ticketKey && statusOf(k) === undefined)
if (unknownStatusKeys.length) {
  log(`Ticketing: WARN — no status known for ${unknownStatusKeys.join(', ')} (no matching \`existing\` entry); treated as writable — pass \`existing\` to have the done-ticket guard cover them`)
}
if (ticketKey && isDoneStatus(statusOf(ticketKey))) {
  log(`Ticketing: WARN — ${ticketKey} is done but was named explicitly, so it IS being written; the Product Owner flags this in coverage_note`)
}
// The anchor must itself be writable — a done anchor would hand the PO a key it cannot touch.
const writableAnchor = (anchorKey && writableKeys.includes(anchorKey)) ? anchorKey : (writableKeys[0] || null)
if (anchorKey && writableAnchor !== anchorKey) {
  log(`Ticketing: anchor ${anchorKey} is a reference ticket — anchor for writing is ${writableAnchor || 'none'}`)
}
revampKeys = writableKeys
anchorKey = writableAnchor
// Briefs JSON for the Product Owner — no silent caps: warn when the slice actually cuts
// features (a 4000-char cap once dropped 2 of 7 briefs without a trace).
const briefsJsonFull = JSON.stringify(features)
if (briefsJsonFull.length > 12000) log(`Ticketing: WARN — feature-brief JSON is ${briefsJsonFull.length} chars, truncated to 12000; later features may be cut from the Product Owner's context`)
const briefsJson = briefsJsonFull.slice(0, 12000)
// CTO consult findings, matched to features by name. Consulting input only — see the
// per-branch instruction below for exactly how these may touch the ticket text.
const ctoFindingsJson = JSON.stringify(consult.findings || []).slice(0, 3000)
const ctoNote = `CTO technical findings, from consulting (per feature, matched by name — informational, NOT ticket-ready prose): ${ctoFindingsJson}. Use these ONLY two ways: (1) fold any risk/dependency/cross-repo implication into the ticket's own scope-boundary and dependency-order language, written in plain business wording — never copy technical/architecture phrasing verbatim into those sections; (2) add ONE short "Technical notes" section at the end of the ticket — a few terse, developer-facing bullet lines (e.g. cross-repo touches, ADR flags, sequencing, risk+mitigation) — clearly separate from the business-requirement body above it, and never prescribing implementation, class/module design, or stack choices. Every OTHER section of the ticket must stay written from the business/user perspective. If any feature came back feasible:false or carries a high-severity risk, do not silently proceed — say so plainly in coverage_note.`
// Bug/issue triage from the developer (Noah), matched to features by `feature` name.
// For any ticket whose feature has a matching investigation, these facts turn a vague symptom into
// a real, reproducible bug ticket. Empty string when the run had no bug briefs.
const bugInvestigationsJson = JSON.stringify(bugInvestigations || []).slice(0, 3500)
const bugNote = (bugInvestigations && bugInvestigations.length)
  ? `BUG/ISSUE TRIAGE — the developer (Noah) investigated the bug/issue brief(s) at runtime (match to a ticket by its \`feature\` name): ${bugInvestigationsJson}. For EACH ticket that has a matching investigation, GROUND it in these facts: (1) render the Bug template's \`Reproduce steps\` runbook from \`reproduce_steps\` verbatim — a \`Precondition:\` line (the clean starting state) then each step as ONE actionable command/click a human can follow, drop NO step; (2) state the confirmed \`root_cause\` in the ticket's own business wording inside the description/scope (what is broken and where, not a code walkthrough); (3) put \`fix_guideline\` under the "Technical notes" section, LABELLED a suggested direction for the developer — NOT a mandated implementation (Noah plans the real fix). State \`confidence\` in the ticket whenever it is not CONFIRMED: a LEADING cause is written as the leading explanation with the missing evidence named, and a SPECULATIVE one is written as a lead to investigate — never as the cause. Do not silently upgrade it. This applies ONLY to tickets with a matching bug investigation; every other ticket stays a plain capability ticket.`
  : ''
const decompNote = `TICKET SIZE — there is NO points ceiling in this run: one feature is one ticket however large it estimates. Do not split, do not propose a split, do not flag a ticket as oversized, and never invoke the \`decompose-ticket\` skill (\`disable-model-invocation: true\` — the human runs \`/decompose-ticket <KEY>\` themselves if and when they want a split). Estimate the ticket, write the points, move on. Never hand-roll pieces via \`upsert-ticket-details.sh new\`.`
const isRevamp = revampKeys.length > 0
const tickets = await agent(
  (isRevamp
    ? `${tag('product-owner', 'ticketing')} As Product Owner, REVAMP the existing backlog IN PLACE — Recon found the board already covers this request, so REFRESH those tickets rather than mint duplicates beside them. Existing covering tickets: ${JSON.stringify(existing).slice(0, 2000)}. WRITABLE keys — the ONLY keys you may write to: ${revampKeys.join(', ')}. Anchor: ${anchorKey || 'none'}.${referenceKeys.length ? ` READ-ONLY REFERENCE keys (done/shipped — ${referenceKeys.join(', ')}): read them for context and cite them in the specs, but do NOT rewrite, re-parent, re-sprint, re-estimate or comment on them. They are the board's shipped record and the estimation calibration set. If one of them turns out to cover a slice nobody else does, say so in coverage_note — do not reopen it yourself.` : ''}${ticketKey && isDoneStatus(statusOf(ticketKey)) ? ` NOTE — ${ticketKey} is DONE but was named explicitly by the human, so it IS in scope; state plainly in coverage_note that a shipped ticket was rewritten on request.` : ''}
  Work these steps IN ORDER — step 1 is whole-set bookkeeping and comes BEFORE any ticket body is touched, precisely so it never gets skipped as an afterthought once the per-ticket rewriting starts:
  STEP 1 — SPRINT + EPIC, decided ONCE for the whole ${revampKeys.length}-ticket set, before rewriting anything. Both rules below are HARD — the failure they exist to prevent (an unasked-for Epic stealing three shipped tickets off their real epics, and a parking sprint appended to them) actually happened.
    (a) EPIC — an existing parent is NEVER changed: any key that already has a Parent/Epic keeps it, full stop, and is not moved under anything new. An Epic may be minted ONLY over the keys that have NO parent at all, and only when there are 4 or MORE of them — count the parentless writable keys, not the whole set. With 4+ parentless keys: create it (\`upsert-ticket-details.sh new --issuetype Epic\`, inherit the anchor's Priority) and \`--parent <EPIC-KEY>\` those parentless keys ONLY. Fewer than 4 parentless keys ⇒ NO Epic (relates-to siblings suffice). Never re-parent, never "consolidate" existing epics, never parent a reference key.
    (b) SPRINT — scheduling is the human's, so this only ever FILLS a gap, never reschedules. HARD RULE, no exception for the anchor: a writable key ALREADY sitting in an ACTIVE sprint is NEVER moved to a different sprint — not even to the anchor's own sprint, not even the anchor itself. An anchor named explicitly (TICKET MODE) keeps its OWN current sprint untouched, full stop — this rule exists because a prior run moved the human-named ticket OUT of its active sprint and INTO the anchor's sprint as a silent side effect (audited failure). Read the anchor's Sprint (\`get-ticket-details.sh ${anchorKey || '<anchor>'}\`'s \`Sprint:\` line) and classify it with ONE \`scripts/tracker/jira/discover-sprints.sh\` call (it lists active + future; an id absent from that list is CLOSED). If the anchor's sprint is CLOSED (or it has none): write NO sprint anywhere, and say so in coverage_note. If it is ACTIVE or FUTURE, then for each OTHER writable key — never the anchor — decide per TARGET: write \`--sprint <anchor sprint id>\` when the target's status is the org's not-started status (e.g. "To Do") OR the target's current sprint is absent / future / closed; write NOTHING when the target is past not-started AND already sits in an ACTIVE sprint — that ticket is committed work in flight and rescheduling it is not yours to do. Never write a sprint to a reference key or to the anchor. Report what you did in the \`epic\` field and coverage_note.
  STEP 2 — for EACH WRITABLE ticket: map the matching brief(s) below onto it and rewrite its description via /clarifying-ticket (or /update-ticket) pointed AT THAT KEY — fold the refreshed spec in, CARRY FORWARD everything already on it (repro steps, acceptance criteria, links, pasted images) and DROP NOTHING; keep its Type and Status; adjust Priority/Effort only when clearly warranted. For UI-bearing aspects link the backing Figma frame inside the spec. Run /clarifying-ticket on EVERY writable key, not only the anchor.  ${ctoNote} ${bugNote}
  STEP 3 — create a NEW ticket ONLY for a slice that no existing ticket covers, applying step 1(b)'s sprint rule to it (a brand-new ticket has no sprint, so it inherits when the anchor's sprint is active or future) and relating it to the anchor. Explain any new ticket in coverage_note.${ticketKey ? ` NEVER create a new ticket in TICKET MODE (single named ticket ${ticketKey}) for a finding surfaced while grounding it — per Intake's rule that finding is already folded into ${ticketKey}'s own acceptance_intent; if a brief nonetheless proposes a second ticket for it, fold it back into ${ticketKey} instead of ticketing it separately.` : ''}
  STEP 4 — ESTIMATE every touched/created ticket EXCEPT a Bug: run \`/estimate-ticket <KEY>\` on every writable key so calibrated Dev/QA points land in the point FIELDS (a comment alone does not count — this applies per-ticket, not just to the anchor) — SKIP it for any key whose feature is flagged \`is_bug\` (or whose tracker Type is Bug), per your standing no-estimate-on-bugs rule. ${decompNote}
  Feature briefs: ${briefsJson}.
  Figma frame per feature: ${JSON.stringify(figmaByFeature).slice(0, 2000)}.
  Return every ticket touched (task_name + URL, its \`sprint\` — required per ticket, "unscheduled" if genuinely none), plus a coverage_note naming which tickets were refreshed vs created, which were held read-only, and why any new one was needed — and the board URL. Include the \`epic\` field only if an Epic actually came up.`
    : `${tag('product-owner', 'ticketing')} As Product Owner, create one self-contained ticket per feature for ${workKey} in the issue tracker — via /clarifying-ticket (which uses the tracker adapter; see docs/agents/issue-tracker.md) and /to-prd. DEDUP FIRST — before creating each ticket, search the board (\`find-tickets.sh --query "<distinctive term>" --open\`); if a ticket already covers the feature, REFRESH that one in place (rewrite its body folding the brief in, keep its images/links) instead of filing a near-duplicate. For a genuinely-new ticket: clear goal + user value, verifiable acceptance criteria, scope boundaries + edge cases, Priority and Effort from the brief, a "feature" type, and the org's not-started status (see issue-tracker.md; never set read-only id fields). SPRINT — leave a brand-new feature UNSCHEDULED (do NOT pass --sprint); inherit --sprint only when the feature relates to an existing sprinted anchor ticket. For UI-bearing features, link the backing Figma frame in the ticket body/spec. Sequence tickets by dependency so the pipeline picks them up in order, and confirm full coverage (every feature → a ticket). ${ctoNote} Then ESTIMATE each ticket EXCEPT a Bug: run \`/estimate-ticket <KEY>\` per ticket so calibrated Dev/QA points land in the ticket's point FIELDS — not done until those fields are set (a comment alone does not count) — SKIP it for any ticket whose feature is flagged \`is_bug\` (or whose tracker Type is Bug), per your standing no-estimate-on-bugs rule. ${decompNote} ${bugNote} EPIC — do not create one. Each feature ships as a single ticket here, and grouping tickets under an Epic is a human's call; leave the \`epic\` field out. An existing ticket you refresh keeps whatever parent it already has — never re-parent it.
  Feature briefs: ${briefsJson}.
  Figma frame per feature: ${JSON.stringify(figmaByFeature).slice(0, 2000)}.
  Return every created/refreshed ticket (task_name + ticket URL + figma_link + its \`sprint\`, required per ticket — "unscheduled" unless inherited from an anchor) — each estimated (Dev/QA point fields set) — and the board URL.`) + LANGUAGE_DIRECTIVE,
  { agentType: 'product-owner', phase: 'Ticketing', label: `tickets:${workKey}`, schema: TICKETS_SCHEMA },
)
log(isRevamp
  ? `Ticketing: revamped ${revampKeys.join(', ')} in place (${tickets.tickets?.length ?? 0} ticket(s) touched)`
  : `Ticketing: ${tickets.tickets?.length ?? 0} tickets created on the board`)
// An Epic is the exception now (4+ parentless writable keys), so log it only when one happened.
if (tickets.epic?.applied) log(`Ticketing: epic applied (${tickets.epic.key}) — ${tickets.epic.reason || 'no reason given'}`)
tick('ticketing')

// ──────────────────────────────────────────────────────────────────────────
// 5. SUMMARY  (required closing step — run-summary + per-role token/time table)
// ──────────────────────────────────────────────────────────────────────────
phase('Summary')
const summary = await agent(
  `Run-recorder for the PRD/design+ticketing workflow on work-key ${workKey}. Write the run-summary to agent_logs/${workKey}-PRD-SUMMARY.md (git-ignored): a short narrative — features intaken, whether Recon found existing tickets and the run REVAMPED them in place (name the keys) vs created fresh, CTO feasibility concerns (if any), any bug/issue items triaged by the developer (Noah) (root cause + reproduce steps grounded into the ticket), any done tickets held read-only as reference, UI features designed (with Figma links), and the tickets created or refreshed (names + URLs) — from this result: ${JSON.stringify({ features: features.map((f) => f.name), revamped: revampKeys, held_read_only: referenceKeys, cto_findings: consult.findings || [], bug_triage: bugInvestigations || [], designs: designs.map((d) => d.feature || d), tickets: tickets.tickets }).slice(0, 3500)}. Then, as the LAST step, run:\n  python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py ${workKey} --workflow prd\nand append its Markdown output VERBATIM under a "## Token & time usage" heading. Return the summary_path.` + LANGUAGE_DIRECTIVE,
  { agentType: 'documentor', phase: 'Summary', label: `summary:${workKey}`, schema: SUMMARY_SCHEMA },
)
tick('summary')
log(`Run summary: ${summary.summary_path}`)

return {
  workKey, ticketKey, brdRef: rawIn, stage, status: 'tickets-ready', maxRounds: MAX_ROUNDS,
  featureCount: features.length, uiDesigned: Object.keys(figmaByFeature).length,
  // revampKeys is the WRITABLE set (done tickets filtered out); referenceKeys is what was held
  // read-only, reported so the caller can see coverage the run deliberately did not touch.
  revamp: isRevamp, revampKeys, referenceKeys, anchorKey, existing,
  tickets: tickets.tickets, epic: tickets.epic || null, board_url: tickets.board_url,
  briefs, consult, bugInvestigations, designs, figmaByFeature, summary, spend,
}
