export const meta = {
  name: 'brd',
  description: 'Business workflow: turn a roadmap phase OR a free-text directive into a Business Requirements Document. Research → CEO strategy → CPO product → CTO feasibility → Documentor writes the BRD to the repo (docs/brd/<key>.md) and, optionally, the team doc space. Pass a phase ("Phase 2") or a directive ("add vet booking").',
  whenToUse: 'Produce the BRD for a phase or a new business initiative end to end. Output (repo + optional doc space) is the handoff into the PRD/ticketing workflow.',
  phases: [
    { title: 'Research', detail: 'discovery pass — market, competitors, pricing, opportunity (web)', model: 'sonnet' },
    { title: 'Strategy', detail: 'CEO: vision, goals, success metrics, scope in/out, priorities', model: 'opus' },
    { title: 'Product', detail: 'CPO: feature set with user value, unit economics, acceptance intent', model: 'opus' },
    { title: 'Feasibility', detail: 'CTO: technical feasibility, risks, big-picture approach, cross-repo + ADR flags', model: 'opus' },
    { title: 'Write', detail: 'Documentor: assemble + publish the BRD to repo (docs/brd/<key>.md) AND Notion', model: 'haiku' },
    { title: 'Summary', detail: 'documentor writes the run-summary + per-role token/time table (summarize-workflow-performance)', model: 'haiku' },
  ],
}

// ──────────────────────────────────────────────────────────────────────────
// Input — auto-detect phase ("Phase 2", "phase-2") vs free-text directive
// ──────────────────────────────────────────────────────────────────────────
const raw = (typeof args === 'string' ? args : (args?.directive || args?.phase || ''))?.trim()
if (!raw) throw new Error('brd needs a phase or directive, e.g. args: "Phase 2" or "add a vet-booking marketplace"')
const phaseMatch = raw.match(/phase\s*-?\s*(\d+)/i)
const mode = phaseMatch ? 'phase' : 'directive'
const workKey = phaseMatch
  ? `phase-${phaseMatch[1]}`
  : (raw.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'initiative')
const scope = phaseMatch
  ? `roadmap Phase ${phaseMatch[1]} (consult the 4-phase roadmap — memory/CONTEXT.md/docs — for that phase's intent and scope it)`
  : `the business directive: "${raw}"`
const repoPath = `docs/brd/${workKey}.md`

const tag = (role, phase) => `[brd ${workKey} role=${role} phase=${phase}]`

// Workspace output language (language) — resolved dynamically (see docs/agents/language.md; the
// same pattern as prd.js/dev-cycle.js). Note the SCOPE here is narrow: the BRD file itself
// (docs/brd/<key>.md, step 5 below) is a checked-in repo doc and MUST stay English regardless —
// only the run-summary (a working deliverable, not committed beside code) is Thai-eligible.
const LANG_SCHEMA = { type: 'object', additionalProperties: false, required: ['language'], properties: {
  language: { type: 'string', enum: ['en', 'th'] }, source: { type: 'string' } } }
let RESOLVED_LANGUAGE = 'en'
try {
  const langCheck = await agent(
    'Read `workspace.config.local.yaml` in the repo root if it exists AND has a `language:` line — that value wins, source="workspace.config.local.yaml". Otherwise read `workspace.config.yaml`\'s `language:` line (default "en" if absent), source="workspace.config.yaml". Return ONLY the resolved language ("en" or "th") and the source file — nothing else, no other files, no other analysis.',
    { agentType: 'documentor', label: 'resolve-language', schema: LANG_SCHEMA },
  )
  if (langCheck?.language === 'en' || langCheck?.language === 'th') RESOLVED_LANGUAGE = langCheck.language
} catch { /* any failure here keeps the 'en' fallback */ }
const LANGUAGE_DIRECTIVE = RESOLVED_LANGUAGE === 'th'
  ? ' LANGUAGE_DIRECTIVE — OUTPUT LANGUAGE = th, already resolved for this run (docs/agents/language.md). This is AUTHORITATIVE: do NOT re-check any config file or override it with your own resolution — obey it verbatim. Write your chat/Slack prose in THAI, but keep the English SPINE English: titles + every section heading + labels/enum values, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). ANY file you author with a .md extension — including the run-summary Markdown in agent_logs/ and the BRD file (docs/brd/<key>.md) — is NEVER Thai; the th prose rule applies to chat, tickets, PR/MR discussion, Slack, and .html docs only.'
  : ''

// Round cap — hard ceiling of 3 for any review↔revise loop (mirrors dev-cycle's
// MAX_GATE_ROUNDS). This linear pipeline has no loop wired yet; the constant
// bounds a future one to ≤3 (override LOWER via args.maxRounds — never higher).
const MAX_ROUNDS = Math.min(3, (typeof args === 'object' && args?.maxRounds) || 3)

// ──────────────────────────────────────────────────────────────────────────
// Schemas
// ──────────────────────────────────────────────────────────────────────────
const RESEARCH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['summary'],
  properties: {
    summary: { type: 'string' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: { topic: { type: 'string' }, insight: { type: 'string' }, source: { type: 'string' } } } },
    competitors: { type: 'array', items: { type: 'string' } },
    opportunities: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
  },
}
const STRATEGY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['vision', 'goals'],
  properties: {
    vision: { type: 'string' },
    goals: { type: 'array', items: { type: 'string' } },
    success_metrics: { type: 'array', items: { type: 'string' } },
    scope_in: { type: 'array', items: { type: 'string' } },
    scope_out: { type: 'array', items: { type: 'string' } },
    priorities: { type: 'array', items: { type: 'string' } },
  },
}
const PRODUCT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['features'],
  properties: {
    personas: { type: 'array', items: { type: 'string' } },
    features: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['name', 'user_value'],
      properties: {
        name: { type: 'string' }, user_value: { type: 'string' },
        priority: { type: 'string' }, unit_economics: { type: 'string' },
        acceptance_intent: { type: 'string' },
      } } },
    open_questions: { type: 'array', items: { type: 'string' } },
  },
}
const FEASIBILITY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feasible'],
  properties: {
    feasible: { type: 'boolean' }, approach: { type: 'string' },
    risks: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: { risk: { type: 'string' }, severity: { type: 'string' }, mitigation: { type: 'string' } } } },
    cross_repo: { type: 'array', items: { type: 'string' } },     // mobile vs separate backend repo
    adr_implications: { type: 'array', items: { type: 'string' } },
  },
}
const BRD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repo_path'],
  properties: {
    repo_path: { type: 'string' }, doc_url: { type: ['string', 'null'] },
    summary: { type: 'string' },
  },
}
const SUMMARY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['summary_path'],
  properties: {
    summary_path: { type: 'string' }, note: { type: 'string' },
  },
}

const spend = []
let mark = budget.spent()
const tick = (label) => { const now = budget.spent(); spend.push({ label, out: now - mark }); mark = now }

// Required closing step — per-role token/time recap. The recorder's prompt omits
// the [brd …] marker so the parser does not count the recorder itself.
async function writeSummary(runResult) {
  phase('Summary')
  const s = await agent(
    `Run-recorder for the business/BRD workflow on work-key ${workKey}. Write the run-summary to agent_logs/${workKey}-BRD-SUMMARY.md (git-ignored): a short narrative — what the BRD covers, the repo path + Notion URL, and any feasibility blockers — from this run result: ${JSON.stringify(runResult).slice(0, 3500)}. Then, as the LAST step, run:\n  python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py ${workKey} --workflow brd\nand append its Markdown output VERBATIM under a "## Token & time usage" heading at the bottom of the file. Return the summary_path.` + LANGUAGE_DIRECTIVE,
    { agentType: 'documentor', phase: 'Summary', label: `summary:${workKey}`, schema: SUMMARY_SCHEMA },
  )
  tick('summary')
  log(`Run summary: ${s.summary_path}`)
  return s
}

// ──────────────────────────────────────────────────────────────────────────
// 1. RESEARCH / DISCOVERY  (web pass feeding strategy)
// ──────────────────────────────────────────────────────────────────────────
phase('Research')
const research = await agent(
  `${tag('research', 'research')} You are the discovery pass for a Business Requirements Document on ${scope}. The product is described in workspace.config.yaml (org.product) and the workspace CLAUDE.md — ground your research in that product. Research with the web: market size/trend, direct & indirect competitors (their offering + pricing/monetization), user pain points, and the concrete opportunity for this scope. Be specific and cite sources. Return structured findings — keep it tight and decision-useful.`,
  { agentType: 'general-purpose', phase: 'Research', label: `research:${workKey}`, schema: RESEARCH_SCHEMA },
)
log(`Research: ${research.competitors?.length ?? 0} competitors, ${research.opportunities?.length ?? 0} opportunities`)
tick('research')

// ──────────────────────────────────────────────────────────────────────────
// 2. STRATEGY  (CEO)
// ──────────────────────────────────────────────────────────────────────────
phase('Strategy')
const strategy = await agent(
  `${tag('ceo', 'strategy')} As CEO/strategy owner, set the business direction for ${scope}. Inputs — research findings: ${JSON.stringify(research).slice(0, 4000)}. Define the vision, business goals, success metrics (measurable), what's explicitly in vs out of scope, and the priority order. ${mode === 'phase' ? 'Anchor this to the existing 4-phase roadmap.' : 'State how this initiative fits the roadmap.'} Keep it crisp — this seeds the BRD.`,
  { agentType: 'ceo', phase: 'Strategy', label: `strategy:${workKey}`, schema: STRATEGY_SCHEMA },
)
log(`Strategy: ${strategy.goals?.length ?? 0} goals, ${strategy.success_metrics?.length ?? 0} metrics`)
tick('strategy')

// ──────────────────────────────────────────────────────────────────────────
// 3. PRODUCT  (CPO)
// ──────────────────────────────────────────────────────────────────────────
phase('Product')
const product = await agent(
  `${tag('cpo', 'product')} As CPO, turn the CEO's direction into a prioritized feature set for ${scope}. CEO direction: ${JSON.stringify(strategy).slice(0, 3000)}. For each feature give: name, clear user value, priority, unit economics (cost/value lever), and acceptance intent (what "done & valuable" means — not yet ticket-level ACs). Add target personas and open questions. This is the product "what", not the "how".`,
  { agentType: 'cpo', phase: 'Product', label: `product:${workKey}`, schema: PRODUCT_SCHEMA },
)
log(`Product: ${product.features?.length ?? 0} features`)
tick('product')

// ──────────────────────────────────────────────────────────────────────────
// 4. FEASIBILITY  (CTO)
// ──────────────────────────────────────────────────────────────────────────
phase('Feasibility')
const feasibility = await agent(
  `${tag('cto', 'feasibility')} As CTO, assess technical feasibility of the proposed features for ${scope}. Features: ${JSON.stringify(product.features).slice(0, 3500)}. This repo is the offline-first Flutter mobile app with NO backend (backend, when needed, is a separate DDD/event-based repo). Give the big-picture approach, risks (with severity + mitigation), what would need the separate backend repo (cross_repo), and any ADR implications. Flag anything that blocks or reshapes scope.`,
  { agentType: 'cto', phase: 'Feasibility', label: `feasibility:${workKey}`, schema: FEASIBILITY_SCHEMA },
)
log(`Feasibility: ${feasibility.feasible ? 'feasible' : '⚠️ concerns'}, ${feasibility.risks?.length ?? 0} risks`)
tick('feasibility')

// ──────────────────────────────────────────────────────────────────────────
// 5. WRITE  (Documentor — assemble + publish to the repo, and the doc space if any)
// ──────────────────────────────────────────────────────────────────────────
phase('Write')
const brd = await agent(
  `${tag('documentor', 'write')} As Documentor, assemble the Business Requirements Document for ${scope} and publish it:
  1. Repo file ${repoPath} (create docs/brd/ if needed) — version-controlled markdown. This is the durable artifact (always write it).
  2. OPTIONALLY, also publish the same content to the team's documentation space if one is configured (e.g. a Notion/Confluence page); skip if none. Put its URL in doc_url (else null).
  Compose from these stage outputs (use them verbatim where useful, organize into a clean BRD):
  - Research: ${JSON.stringify(research).slice(0, 2500)}
  - Strategy (CEO): ${JSON.stringify(strategy).slice(0, 2500)}
  - Product (CPO): ${JSON.stringify(product).slice(0, 3000)}
  - Feasibility (CTO): ${JSON.stringify(feasibility).slice(0, 2500)}
  BRD sections: Overview & context · Business goals & success metrics · Scope (in/out) · Market & competitive insight · Feature set with user value, priority & unit economics · Technical feasibility & risks (incl. cross-repo) · Open questions · Roadmap fit. Return the repo path + doc_url (or null).`,
  { agentType: 'documentor', phase: 'Write', label: `write:${workKey}`, schema: BRD_SCHEMA },
)
log(`BRD written: ${brd.repo_path}${brd.doc_url ? ` + ${brd.doc_url}` : ''}`)
tick('write')

// Required closing step — run-summary + per-role token/time table.
const summary = await writeSummary({
  workKey, mode, scope: raw, brd,
  goals: strategy.goals, features: (product.features || []).map((f) => f.name),
  feasible: feasibility.feasible,
})

return {
  workKey, mode, scope: raw, status: 'brd-ready', maxRounds: MAX_ROUNDS,
  brd, research, strategy, product, feasibility, summary,
  spend, // per-phase output-token deltas; the per-role table lives in summary.summary_path
}
