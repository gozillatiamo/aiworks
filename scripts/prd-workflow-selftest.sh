#!/usr/bin/env bash
#
# prd-workflow-selftest.sh — offline, zero-token proof of the OFB-2335 audit fixes to
# .claude/workflows/prd.js (agent_logs/OFB-2335-prd-workflow-audit.md):
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
WORKFLOW="$DIR/.claude/workflows/prd.js"
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

async function runOnce(argsVal, canned) {
  const budget = { spent: () => 0 }
  const phase = () => {}
  const log = (s) => LINES.push(String(s))
  const parallel = (fns) => Promise.all(fns.map((f) => f()))
  const agent = async (prompt, opts) => {
    const label = opts && opts.label
    if (!label || !(label in canned)) throw new Error('selftest: unstubbed agent label ' + label)
    PROMPTS[label] = prompt
    return canned[label]
  }
  const wf = require(HARNESS)
  return wf(argsVal, budget, phase, agent, log, parallel, undefined, undefined)
}

function report(name, ok, detail) {
  console.log(`RESULT ${name} ${ok ? 'PASS' : 'FAIL'}${detail ? ' ' + detail : ''}`)
}

// One recon result shared by every scenario: the request names OFB-2335, but Recon (a plain
// board search) ALSO surfaces OFB-2324 as a covering ticket — the exact shape the audited run
// hit. recon.anchor is deliberately set to the OTHER ticket, to prove the script ignores it
// and keeps the human-named ticket as anchor.
const RECON = {
  existing: [
    { key: 'OFB-2335', title: 'Clarify payment method tab', status: 'To Do', sprint: 'Sprint 74 (id 74)', parent: null, covers: 'the requested ticket itself' },
    { key: 'OFB-2324', title: 'Payment methods revamp', status: 'To Do', sprint: 'Sprint 75 (id 75)', parent: null, covers: 'a broader related slice' },
  ],
  anchor: 'OFB-2324',
  note: '',
}
const CANNED_BASE = {
  'resolve-language': { language: 'en', source: 'workspace.config.yaml' },
  'recon:ofb-2335': RECON,
  'intake:ofb-2335': { features: [{ name: 'Clarify OFB-2335', ui_bearing: false, is_bug: false, brief: 'b', user_value: 'v', acceptance_intent: ['A1'], priority: 'Medium', effort: 'Small', dependencies: [] }], notes: '' },
  'consult:ofb-2335': { findings: [{ feature: 'Clarify OFB-2335', feasible: true, approach: 'a', risks: [], cross_repo: [], adr_implications: [], technical_dependencies: [] }], notes: '' },
  'tickets:ofb-2335': { tickets: [{ task_name: 'Clarify OFB-2335', url: 'https://tracker/OFB-2335', ui_bearing: false, figma_link: null, priority: 'Medium', effort: 'Small', sprint: 'unscheduled' }], board_url: 'https://tracker', coverage_note: 'refreshed OFB-2335 only' },
  'summary:ofb-2335': { summary_path: 'agent_logs/ofb-2335-PRD-SUMMARY.md', note: '' },
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

;(async () => {
  try {
    if (SCENARIO === 'T1_URL_IS_TICKET_MODE') {
      // A Jira-style "view ticket" URL, not a bare key — the exact input shape of the audited
      // run (`Workflow({ name: "prd", args: "https://bluepi.atlassian.net/browse/OFB-2335" })`).
      const result = await runOnce('https://bluepi.atlassian.net/browse/OFB-2335', CANNED_BASE)
      report('T1_ticketKey_resolved', result && result.ticketKey === 'OFB-2335', `got ${result && result.ticketKey}`)
      report('T1_workKey_from_ticket', result && result.workKey === 'ofb-2335', `got ${result && result.workKey}`)
    } else if (SCENARIO === 'T1B_DOC_URL_STAYS_GENERIC') {
      // Guard against over-matching: a generic doc-space URL with no ticket-shaped path
      // segment must NOT be misread as a ticket key.
      const result = await runOnce('https://notion.so/team/Some-Feature-42-notes-abcdef0123456789', CANNED_DOC_URL)
      report('T1B_no_false_ticket_key', result && result.ticketKey === null, `got ${result && result.ticketKey}`)
    } else if (SCENARIO === 'T2_WRITE_SCOPE_STAYS_NAMED_TICKET') {
      const result = await runOnce('https://bluepi.atlassian.net/browse/OFB-2335', CANNED_BASE)
      report('T2_revampKeys_is_named_ticket_only', JSON.stringify(result.revampKeys) === JSON.stringify(['OFB-2335']), `got ${JSON.stringify(result.revampKeys)}`)
      report('T2_anchor_is_named_ticket_not_recon_anchor', result.anchorKey === 'OFB-2335', `got ${result.anchorKey}`)
      report('T2_other_covering_ticket_kept_as_context_only', result.existing.some((e) => e.key === 'OFB-2324') && !result.revampKeys.includes('OFB-2324'))
      const ticketingPrompt = PROMPTS['tickets:ofb-2335'] || ''
      report('T2_prompt_writable_keys_is_named_ticket_only', ticketingPrompt.includes('WRITABLE keys — the ONLY keys you may write to: OFB-2335.') || ticketingPrompt.includes('OFB-2335.'), 'writable-keys clause')
      report('T2_prompt_never_lists_other_ticket_as_writable', !/write to: [^.]*OFB-2324/.test(ticketingPrompt))
    } else if (SCENARIO === 'T3_INTAKE_FORBIDS_SPLIT_BUG_TICKET') {
      await runOnce('https://bluepi.atlassian.net/browse/OFB-2335', CANNED_BASE)
      const intakePrompt = PROMPTS['intake:ofb-2335'] || ''
      report('T3_prompt_names_ticket_mode', intakePrompt.includes('TICKET MODE'))
      report('T3_prompt_demands_exactly_one_brief', intakePrompt.includes('EXACTLY ONE brief'))
      report('T3_prompt_bans_is_bug_on_grounding_finding', intakePrompt.includes('is NEVER `is_bug: true`'))
    } else if (SCENARIO === 'T4_TICKETING_GUARDS_SPRINT_AND_NEW_TICKET') {
      await runOnce('https://bluepi.atlassian.net/browse/OFB-2335', CANNED_BASE)
      const ticketingPrompt = PROMPTS['tickets:ofb-2335'] || ''
      report('T4_prompt_bans_moving_anchor_off_active_sprint', ticketingPrompt.includes('a writable key ALREADY sitting in an ACTIVE sprint is NEVER moved'))
      report('T4_prompt_never_the_anchor_itself', ticketingPrompt.includes('not even the anchor itself'))
      report('T4_prompt_bans_new_ticket_for_grounding_finding', ticketingPrompt.includes('NEVER create a new ticket in TICKET MODE'))
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

echo "PRD workflow selftest (OFB-2335 audit fixes)"

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

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
