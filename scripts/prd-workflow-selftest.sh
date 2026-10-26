#!/usr/bin/env bash
#
# prd-workflow-selftest.sh — offline, zero-token proof of a TICKET MODE audit's fixes to
# .claude/workflows/src/prd.js:
#   T1 — a tracker ticket URL (not just a bare key) is recognized as TICKET MODE.
#   T2 — TICKET MODE write scope stays the ONE named ticket even when Recon finds another
#        covering ticket; the anchor is the named ticket, never a Recon-suggested one.
#   T3 — Intake's prompt forbids splitting a grounding-finding into a second brief/bug ticket.
#   T4 — Ticketing's prompt forbids moving the anchor OUT of an active sprint, and forbids
#        minting a new ticket in TICKET MODE for a finding surfaced while grounding it.
#
# Same construction as scripts/dev-cycle-gate-selftest.sh: the REAL workflow source, stripped
# of `export` and wrapped in the engine's own function-body context, then driven with canned
# agent() responses so the real branch logic (and the exact prompt strings it builds) run with
# no network and no tokens.
#
# Usage: scripts/prd-workflow-selftest.sh [-v]
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$DIR/.claude/workflows/src/prd.js"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_err=; c_off=; }
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$c_err" "$c_off" "$1"; }

command -v node >/dev/null 2>&1 || { echo "node not found — cannot run selftest" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — cannot build the harness" >&2; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "workflow not found: $WORKFLOW" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness.cjs"

# Design/image-gen off (matches the committed default) so the Design phase is skipped
# entirely and this suite needs no ux-ui-planner/graphic-designer/ux-ui-designer stubs.
CONFIG_FIXTURE='const LANGUAGE = "en"
const DESIGN_ENABLED = false
const DESIGN_FIGMA_FILE_KEY = ""
const DESIGN_PAGE_NAMING = "{work_key} / {feature}"
const IMAGE_GEN_ENABLED = false
const IMAGE_GEN_QUALITY = "balanced"
const IMAGE_GEN_MAX_PER_REQUEST = 2'

python3 - "$WORKFLOW" "$HARNESS" <<PY
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'^export\s+', '', src, count=1, flags=re.M)
fixture = """$CONFIG_FIXTURE"""
src = re.sub(
    r'// >>> AIWORKS:CONFIG START.*?// <<< AIWORKS:CONFIG END >>>',
    fixture, src, count=1, flags=re.S)
open(sys.argv[2], 'w').write(
    "module.exports = (async function(args,budget,phase,agent,log,parallel,pipeline,workflow){\n"
    + src + "\n});\n")
PY
grep -q 'const DESIGN_ENABLED = false' "$HARNESS" || { echo "CONFIG_FIXTURE substitution failed — marker text may have drifted" >&2; exit 1; }

DRIVER="$TMP/driver.cjs"
cat > "$DRIVER" <<'NODE'
const HARNESS = process.env.HARNESS
const SCENARIO = process.env.SCENARIO
const ARGS = process.env.ARGS

const PROMPTS = {}
const LINES = []
let INVESTIGATE = 0
const investigateCalls = () => INVESTIGATE

async function runOnce(argsVal, canned) {
  INVESTIGATE = 0
  const budget = { spent: () => 0 }
  const phase = () => {}
  const log = (s) => LINES.push(String(s))
  const parallel = (fns) => Promise.all(fns.map((f) => f()))
  const agent = async (prompt, opts) => {
    const label = opts && opts.label
    if (!label || !(label in canned)) throw new Error('selftest: unstubbed agent label ' + label)
    if (label.startsWith('investigate:')) INVESTIGATE += 1
    PROMPTS[label] = prompt
    return canned[label]
  }
  const wf = require(HARNESS)
  return wf(argsVal, budget, phase, agent, log, parallel, undefined, undefined)
}

function report(name, ok, detail) {
  console.log(`RESULT ${name} ${ok ? 'PASS' : 'FAIL'}${detail ? ' ' + detail : ''}`)
}

// One recon result shared by every scenario: the request names APP-501, but Recon (a plain
// board search) ALSO surfaces APP-500 as a covering ticket — the exact shape the audited run
// hit. recon.anchor is deliberately set to the OTHER ticket, to prove the script ignores it
// and keeps the human-named ticket as anchor.
const RECON = {
  existing: [
    { key: 'APP-501', title: 'Clarify payment method tab', status: 'To Do', sprint: 'Sprint 74 (id 74)', parent: null, covers: 'the requested ticket itself' },
    { key: 'APP-500', title: 'Payment methods revamp', status: 'To Do', sprint: 'Sprint 75 (id 75)', parent: null, covers: 'a broader related slice' },
  ],
  anchor: 'APP-500',
  note: '',
}
const CANNED_BASE = {
  'resolve-language': { language: 'en', source: 'workspace.config.yaml' },
  'recon:app-501': RECON,
  'intake:app-501': { features: [{ name: 'Clarify APP-501', ui_bearing: false, is_bug: false, brief: 'b', user_value: 'v', acceptance_intent: ['A1'], priority: 'Medium', effort: 'Small', dependencies: [] }], notes: '' },
  'consult:app-501': { findings: [{ feature: 'Clarify APP-501', feasible: true, approach: 'a', risks: [], cross_repo: [], adr_implications: [], technical_dependencies: [] }], notes: '' },
  'tickets:app-501': { tickets: [{ task_name: 'Clarify APP-501', url: 'https://tracker/APP-501', ui_bearing: false, figma_link: null, priority: 'Medium', effort: 'Small', sprint: 'unscheduled' }], board_url: 'https://tracker', coverage_note: 'refreshed APP-501 only' },
  'summary:app-501': { summary_path: 'agent_logs/app-501-PRD-SUMMARY.md', note: '' },
}
// A generic doc-space URL (no ticket key, no "phase-N" in its slug) resolves workKey to the
// isUrl fallback 'brd-import' — separate stubs, since the label carries that workKey.
const CANNED_DOC_URL = {
  'resolve-language': CANNED_BASE['resolve-language'],
  'recon:brd-import': { existing: [], anchor: null, note: '' },
  'intake:brd-import': { features: [{ name: 'Some feature', ui_bearing: false, is_bug: false, brief: 'b', user_value: 'v', acceptance_intent: ['A1'], priority: 'Medium', effort: 'Small', dependencies: [] }], notes: '' },
  'consult:brd-import': { findings: [{ feature: 'Some feature', feasible: true, approach: 'a', risks: [], cross_repo: [], adr_implications: [], technical_dependencies: [] }], notes: '' },
  'tickets:brd-import': { tickets: [{ task_name: 'Some feature', url: 'https://tracker/NEW-1', ui_bearing: false, figma_link: null, priority: 'Medium', effort: 'Small', sprint: 'unscheduled' }], board_url: 'https://tracker', coverage_note: '' },
  'summary:brd-import': { summary_path: 'agent_logs/brd-import-PRD-SUMMARY.md', note: '' },
}
// Two briefs (one a bug) for the single-request collapse scenarios; stubs keyed by workKey.
// A collapsed run investigates only the merged feature (first brief's name → slug 'fix-login').
const TWO_FEATURES = [
  { name: 'Fix login', ui_bearing: false, is_bug: true, brief: 'login breaks', user_value: 'v', acceptance_intent: ['A1'], priority: 'Medium', effort: 'Small', dependencies: [] },
  { name: 'Add logout', ui_bearing: true, is_bug: false, brief: 'logout button', user_value: 'v', acceptance_intent: ['A2'], priority: 'High', effort: 'Large', dependencies: [] },
]
const INVESTIGATION = { root_cause: 'r', reproduce_steps: ['s1'], fix_guideline: 'f', affected: [], confidence: 'CONFIRMED' }
const cannedTwo = (wk) => ({
  'resolve-language': CANNED_BASE['resolve-language'],
  ['recon:' + wk]: { existing: [], anchor: null, note: '' },
  ['intake:' + wk]: { features: TWO_FEATURES, notes: '' },
  ['consult:' + wk]: { findings: [{ feature: 'Fix login', feasible: true }, { feature: 'Add logout', feasible: true }], notes: '' },
  'investigate:fix-login': INVESTIGATION,
  'investigate:add-logout': INVESTIGATION,
  ['tickets:' + wk]: { tickets: [{ task_name: 'Fix login', url: 'https://tracker/NEW-1', ui_bearing: false, figma_link: null, priority: 'High', effort: 'Large', sprint: 'unscheduled' }], board_url: 'https://tracker', coverage_note: '' },
  ['summary:' + wk]: { summary_path: 'agent_logs/' + wk + '-PRD-SUMMARY.md', note: '' },
})

;(async () => {
  try {
    if (SCENARIO === 'T1_URL_IS_TICKET_MODE') {
      // A Jira-style "view ticket" URL, not a bare key — the exact input shape of the audited
      // run (`Workflow({ name: "prd", args: "https://tracker.example/browse/APP-501" })`).
      const result = await runOnce('https://tracker.example/browse/APP-501', CANNED_BASE)
      report('T1_ticketKey_resolved', result && result.ticketKey === 'APP-501', `got ${result && result.ticketKey}`)
      report('T1_workKey_from_ticket', result && result.workKey === 'app-501', `got ${result && result.workKey}`)
    } else if (SCENARIO === 'T1B_DOC_URL_STAYS_GENERIC') {
      // Guard against over-matching: a generic doc-space URL with no ticket-shaped path
      // segment must NOT be misread as a ticket key.
      const result = await runOnce('https://notion.so/team/Some-Feature-42-notes-abcdef0123456789', CANNED_DOC_URL)
      report('T1B_no_false_ticket_key', result && result.ticketKey === null, `got ${result && result.ticketKey}`)
    } else if (SCENARIO === 'T2_WRITE_SCOPE_STAYS_NAMED_TICKET') {
      const result = await runOnce('https://tracker.example/browse/APP-501', CANNED_BASE)
      report('T2_revampKeys_is_named_ticket_only', JSON.stringify(result.revampKeys) === JSON.stringify(['APP-501']), `got ${JSON.stringify(result.revampKeys)}`)
      report('T2_anchor_is_named_ticket_not_recon_anchor', result.anchorKey === 'APP-501', `got ${result.anchorKey}`)
      report('T2_other_covering_ticket_kept_as_context_only', result.existing.some((e) => e.key === 'APP-500') && !result.revampKeys.includes('APP-500'))
      const ticketingPrompt = PROMPTS['tickets:app-501'] || ''
      report('T2_prompt_writable_keys_is_named_ticket_only', ticketingPrompt.includes('WRITABLE keys — the ONLY keys you may write to: APP-501.') || ticketingPrompt.includes('APP-501.'), 'writable-keys clause')
      report('T2_prompt_never_lists_other_ticket_as_writable', !/write to: [^.]*APP-500/.test(ticketingPrompt))
    } else if (SCENARIO === 'T3_INTAKE_FORBIDS_SPLIT_BUG_TICKET') {
      await runOnce('https://tracker.example/browse/APP-501', CANNED_BASE)
      const intakePrompt = PROMPTS['intake:app-501'] || ''
      report('T3_prompt_names_ticket_mode', intakePrompt.includes('TICKET MODE'))
      report('T3_prompt_demands_exactly_one_brief', intakePrompt.includes('EXACTLY ONE brief'))
      report('T3_prompt_bans_is_bug_on_grounding_finding', intakePrompt.includes('is NEVER `is_bug: true`'))
    } else if (SCENARIO === 'T4_TICKETING_GUARDS_SPRINT_AND_NEW_TICKET') {
      await runOnce('https://tracker.example/browse/APP-501', CANNED_BASE)
      const ticketingPrompt = PROMPTS['tickets:app-501'] || ''
      report('T4_prompt_bans_moving_anchor_off_active_sprint', ticketingPrompt.includes('a writable key ALREADY sitting in an ACTIVE sprint is NEVER moved'))
      report('T4_prompt_never_the_anchor_itself', ticketingPrompt.includes('not even the anchor itself'))
      report('T4_prompt_bans_new_ticket_for_grounding_finding', ticketingPrompt.includes('NEVER create a new ticket in TICKET MODE'))
    } else if (SCENARIO === 'T5_TICKETING_CARRIES_DETAILS_RULE') {
      await runOnce('https://tracker.example/browse/APP-501', CANNED_BASE)
      const p = PROMPTS['tickets:app-501'] || ''
      report('T5_prompt_names_description_shape', p.includes('DESCRIPTION SHAPE (docs/adr/0044)'))
      report('T5_prompt_puts_rest_under_details', p.includes('## Details'))
      report('T5_technical_notes_under_details', p.includes('"Technical notes" block under the `## Details` heading'))
    } else if (SCENARIO === 'T6_FREE_TEXT_COLLAPSES_TO_ONE') {
      const text = 'fix the login page and add a logout button'
      const wk = text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)
      const result = await runOnce(text, cannedTwo(wk))
      report('T6_one_feature', result.featureCount === 1, `got ${result.featureCount}`)
      report('T6_intake_asks_one_brief', (PROMPTS['intake:' + wk] || '').includes('SINGLE REQUEST — return EXACTLY ONE brief'))
      report('T6_one_investigate_run', investigateCalls() === 1, `got ${investigateCalls()}`)
      const m = result.briefs.features[0]
      report('T6_merged_is_bug_and_highest_priority', m.is_bug === true && m.ui_bearing === true && m.priority === 'High' && m.effort === 'Large', JSON.stringify([m.is_bug, m.ui_bearing, m.priority, m.effort]))
      report('T6_merged_brief_lists_slices', m.brief.startsWith('Slice: Fix login — ') && m.brief.includes('\nSlice: Add logout — ') && m.acceptance_intent.length === 2)
      report('T6_log_says_collapsed', LINES.some((l) => l.includes('collapsed 2 briefs into 1')))
    } else if (SCENARIO === 'T7_KEY_AND_AGENT_LOGS_PATH_COLLAPSE') {
      const r1 = await runOnce('APP-501', cannedTwo('app-501'))
      report('T7_ticket_key_one_feature', r1.featureCount === 1, `got ${r1.featureCount}`)
      const r2 = await runOnce('agent_logs/x/brief.md', cannedTwo('brief'))
      report('T7_agent_logs_path_one_feature', r2.featureCount === 1, `got ${r2.featureCount}`)
    } else if (SCENARIO === 'T8_BRD_INPUTS_KEEP_ALL_FEATURES') {
      const r1 = await runOnce('phase-2', cannedTwo('phase-2'))
      report('T8_phase_two_features', r1.featureCount === 2, `got ${r1.featureCount}`)
      const r2 = await runOnce('docs/brd/phase-2.md', cannedTwo('phase-2'))
      report('T8_brd_path_two_features', r2.featureCount === 2, `got ${r2.featureCount}`)
      const r3 = await runOnce('https://notion.so/team/Some-Feature-42-notes-abcdef0123456789', cannedTwo('brd-import'))
      report('T8_doc_url_two_features', r3.featureCount === 2, `got ${r3.featureCount}`)
      report('T8_ticketing_prompt_has_no_single_rule', !(PROMPTS['tickets:brd-import'] || '').includes('SINGLE REQUEST'))
      const r4 = await runOnce({ brd: 'phase-2', single: true }, cannedTwo('phase-2'))
      report('T8_single_true_overrides_to_one', r4.featureCount === 1, `got ${r4.featureCount}`)
      const r5 = await runOnce({ brd: 'APP-501', single: false }, cannedTwo('app-501'))
      report('T8_single_false_overrides_to_two', r5.featureCount === 2, `got ${r5.featureCount}`)
    } else if (SCENARIO === 'T9_TICKETING_STAGE_COLLAPSES') {
      const result = await runOnce({
        brd: 'APP-501', stage: 'ticketing',
        features: TWO_FEATURES,
        ctoFindings: [{ feature: 'Fix login', feasible: true }, { feature: 'Add logout', feasible: true }],
        bugInvestigations: [],
      }, cannedTwo('app-501'))
      report('T9_one_feature', result.featureCount === 1, `got ${result.featureCount}`)
      const p = PROMPTS['tickets:app-501'] || ''
      report('T9_findings_renamed_to_merged', p.includes('{"feature":"Fix login","feasible":true},{"feature":"Fix login","feasible":true}'))
      report('T9_prompt_demands_exactly_one_ticket', p.includes('EXACTLY ONE ticket'))
      report('T9_prompt_never_split', p.includes('never split it, never flag it oversized'))
    } else if (SCENARIO === 'T10_IMAGES_PASS_THROUGH') {
      await runOnce({ brd: 'APP-501', images: ['/tmp/a.png', { path: '/tmp/b.png', caption: 'before' }] }, CANNED_BASE)
      const p1 = PROMPTS['tickets:app-501'] || ''
      report('T10_images_block_present', p1.includes('IMAGES —') && p1.includes('/tmp/a.png') && p1.includes('/tmp/b.png'))
      report('T10_images_embedded_in_core', p1.includes('## Evidence'))
      await runOnce('https://tracker.example/browse/APP-501', CANNED_BASE)
      report('T10_images_block_absent_without_args', !(PROMPTS['tickets:app-501'] || '').includes('IMAGES —'))
    } else {
      throw new Error('unknown SCENARIO ' + SCENARIO)
    }
  } catch (e) {
    console.log('RESULT harness_error FAIL ' + (e && e.message))
    process.exitCode = 1
  }
})()
NODE

run_scenario() {
  local name="$1"
  HARNESS="$HARNESS" SCENARIO="$name" node "$DRIVER"
}

ingest() {
  while IFS= read -r line; do
    [[ "$line" == RESULT\ * ]] || continue
    local rest="${line#RESULT }"
    local rname="${rest%% *}"
    local status_and_detail="${rest#* }"
    local status="${status_and_detail%% *}"
    local detail="${status_and_detail#* }"
    [[ "$detail" == "$status" ]] && detail=""
    if [[ "$status" == "PASS" ]]; then pass "$rname"; else fail "$rname${detail:+ — $detail}"; fi
  done <<<"$1"
}

echo "PRD workflow selftest (TICKET MODE audit fixes)"

echo "── T1 — a tracker ticket URL is recognized as TICKET MODE, not generic BRD import"
out="$(run_scenario T1_URL_IS_TICKET_MODE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T1b — a generic doc-space URL with no ticket-shaped segment stays generic"
out="$(run_scenario T1B_DOC_URL_STAYS_GENERIC)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T2 — write scope stays the one named ticket even when Recon finds another covering ticket"
out="$(run_scenario T2_WRITE_SCOPE_STAYS_NAMED_TICKET)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T3 — Intake's prompt forbids splitting a grounding-finding into a second brief/bug ticket"
out="$(run_scenario T3_INTAKE_FORBIDS_SPLIT_BUG_TICKET)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T4 — Ticketing's prompt bans moving the anchor off its active sprint + minting a sibling ticket"
out="$(run_scenario T4_TICKETING_GUARDS_SPRINT_AND_NEW_TICKET)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T5 — Ticketing's prompt carries the short-page description rule (core first, rest under ## Details)"
out="$(run_scenario T5_TICKETING_CARRIES_DETAILS_RULE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T6 — free text is a single request: two briefs collapse into one feature, one Investigate run"
out="$(run_scenario T6_FREE_TEXT_COLLAPSES_TO_ONE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T7 — a ticket key and an agent_logs/ path are single requests too"
out="$(run_scenario T7_KEY_AND_AGENT_LOGS_PATH_COLLAPSE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T8 — phase-N, docs/brd path and a doc URL keep one ticket per feature; args.single overrides"
out="$(run_scenario T8_BRD_INPUTS_KEEP_ALL_FEATURES)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T9 — stage:'ticketing' collapses a single request's features and renames the CTO findings"
out="$(run_scenario T9_TICKETING_STAGE_COLLAPSES)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── T10 — args.images reach the Ticketing prompt as an ## Evidence embed instruction"
out="$(run_scenario T10_IMAGES_PASS_THROUGH)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
