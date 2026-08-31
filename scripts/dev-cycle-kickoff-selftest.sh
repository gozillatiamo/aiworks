#!/usr/bin/env bash
#
# dev-cycle-kickoff-selftest.sh — offline, zero-token proof of three dev-cycle.js changes:
#   C10  Kickoff skip-gate, ticket-fingerprint guarded
#   C11  artifact-republish exclusivity with the skip path
#   C12  --feature-base-repos scopes the feature-base override
#
# Drives the REAL workflow source through the SAME function-body wrapper the engine loads it
# with (see .claude/hooks/dev-wrapper/posttool-workflow-compile.sh) — `node --check` parses the
# file as a module and would miss a function-body-context break — except here the wrapped
# function is EXPORTED instead of self-invoked, so this driver can hand it canned agent()
# responses and inspect what it spawned/logged/returned. No network, no git writes, no tokens.
#
# Usage: scripts/dev-cycle-kickoff-selftest.sh [-v]
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${WORKFLOW:-$DIR/.claude/workflows/dev-cycle.js}"
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

# dev-cycle.js is GENERATED from workspace.config.yaml, so the ticket prefix, the repo ids and
# each repo's base branch are that workspace's — not fixture values. Hardcoded, they made every
# scenario below fail on any workspace that had renamed them: the arg guard strips only
# <PREFIX>-<n> from the argument string, so "FM-12" against a workspace that renamed the
# prefix is left as residue, thrown out as an unrecognised argument before a scenario runs.
# Read the four facts the fixtures need out of the file under test, and substitute them in.
read -r TICKET APP SUITE SUITE_BASE <<<"$(awk '
  /^const TICKET_PREFIX = / {
    if (match($0, /\047[^\047]+\047/)) prefix = substr($0, RSTART + 1, RLENGTH - 2)
    next
  }
  /^const REPOS = \{/ { inr = 1; next }
  inr && /^\}/        { inr = 0; next }
  inr && match($0, /^  \047[^\047]+\047:/) {
    k = substr($0, RSTART + 3, RLENGTH - 5); order[++n] = k; next
  }
  inr && k != "" {
    if ($0 ~ /testSuite: *true/) isSuite[k] = 1
    if (base[k] == "" && match($0, /feature: *\047[^\047]+\047/)) {
      m = substr($0, RSTART, RLENGTH); sub(/^feature: *\047/, "", m); sub(/\047$/, "", m)
      base[k] = m
    }
  }
  END {
    for (i = 1; i <= n; i++) {
      r = order[i]
      if (isSuite[r]) { if (s == "") s = r } else if (a == "") a = r
    }
    print prefix "-12", a, s, base[s]
  }
' "$WORKFLOW")"
for v in TICKET APP SUITE SUITE_BASE; do
  [[ -n "${!v}" && "${!v}" != "-12" ]] || {
    echo "could not read $v out of $WORKFLOW — has the generator's shape changed?" >&2; exit 1; }
done

# Same strip-and-wrap the compile probe uses, except EXPORTED (not self-invoked): the driver
# below supplies the stubs and calls it itself.
python3 - "$WORKFLOW" "$HARNESS" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'^export\s+', '', src, count=1, flags=re.M)
open(sys.argv[2], 'w').write(
    "module.exports = (async function(args,budget,phase,agent,log,parallel,pipeline,workflow){\n"
    + src + "\n});\n")
PY

DRIVER="$TMP/driver.cjs"
# The driver below is written with the framework's own defaults so it stays readable; the names
# are swapped for this workspace's on the way out. `develop` is matched only in the four shapes
# it appears in as a BRANCH — a blanket substitution would also eat `development-planner`.
sed -e "s/FM-12/$TICKET/g" \
    -e "s/your-app/$APP/g" \
    -e "s/your-tests/$SUITE/g" \
    -e "s/'develop'/'$SUITE_BASE'/g" \
    -e "s/→develop/→$SUITE_BASE/g" \
    -e "s/→ develop/→ $SUITE_BASE/g" \
    -e "s/--feature-base develop/--feature-base $SUITE_BASE/g" \
    > "$DRIVER" <<'NODE'
const HARNESS = process.env.HARNESS
const SCENARIO = process.env.SCENARIO
const FP = process.env.FP || ''
const ARGS = process.env.ARGS || 'FM-12'

const LINES = []
const SPAWNED = []
const PROMPTS = {}

const REPO_PLAN = (repo, base, acceptance) => ({
  repo, title: 'T', acceptance,
  base_branch: base, work_branch: 'feature/FM-12',
  plan_path: `/tmp/ws/${repo}/plan.md`,
  plan_html: `/tmp/ws/${repo}/plan.html`,
  summary: 'planned', unverified_claims: [],
})

const PLAN_GUARD_OK = {
  repos: [
    { repo: 'your-app', ok: ['agent_logs/development-planner/FM-12-your-app-plan.md', 'agent_logs/FM-12-your-app-plan.html'], relocated: [], missing: [] },
    { repo: 'your-tests', ok: ['agent_logs/FM-12-automation-plan.md', 'agent_logs/FM-12-your-tests-plan.html', 'agent_logs/FM-12-testcases.md'], relocated: [], missing: [] },
  ],
}

function scopeFor(scenario) {
  const base = {
    ticket: 'FM-12', title: 'T', type: 'feature',
    acceptance: ['A1', 'A2'], comment_count: 2,
    repos: [{ repo: 'your-app' }, { repo: 'your-tests', depends_on: ['your-app'] }],
    test_suite: { needed: true },
    tracker_reachable: true,
  }
  // C — the ticket was edited between invocations: the title a human would notice changed.
  if (scenario === 'C') return { ...base, title: 'T (edited)' }
  // E1/E2 (C12) — the fingerprint must ignore comment_count: E1 carries it, E2 drops the field
  // entirely. Title + acceptance are IDENTICAL between the two, so a correct fingerprint must
  // come out identical too.
  if (scenario === 'E1') return { ...base, comment_count: 2 }
  if (scenario === 'E2') { const { comment_count, ...rest } = base; return rest }
  return base
}

function rowsFor(scenario, fp) {
  if (scenario === 'A') {
    // No 'planned' row at all (first-run path) — but ONE 'artifact_published' row, to prove
    // C11's URL-threading fires even when C10's skip does not (they are independent rows).
    return [{ repo: 'your-app', milestone: 'artifact_published', status: 'done', artifact_url: 'https://claude.ai/public/artifacts/abc' }]
  }
  if (scenario === 'B' || scenario === 'C' || scenario === 'E1' || scenario === 'E2') {
    return ['your-app', 'your-tests'].map((repo) => ({
      repo, milestone: 'planned', status: 'done', degraded: false,
      ticket_fp: fp, plan_path: `/tmp/ws/${repo}/plan.md`, plan_bytes: 4096,
      title: 'T', acceptance: repo === 'your-app' ? ['A1'] : ['A2'],
      recorded_at: '2026-01-01T00:00:00Z',
    }))
  }
  return []
}

function cannedFor(scenario, fp) {
  return {
    'resolve-runtime-config': { language: 'en', plan_to_html: true, artifacts_enabled: true },
    'run-state:FM-12': { rows: rowsFor(scenario, fp) },
    'scope:FM-12': scopeFor(scenario),
    'status:FM-12:in_progress': { moved: true },
    'ws-root:FM-12': { workspace_root: '/tmp/ws' },
    'kickoff:FM-12:your-app': REPO_PLAN('your-app', 'develop', ['A1']),
    'kickoff:FM-12:your-tests': REPO_PLAN('your-tests', 'main', ['A2']),
    'plan-guard:FM-12': PLAN_GUARD_OK,
    'summary:FM-12': { summary_path: '/tmp/x.md', token_table_appended: true, note: 'ok' },
    'publish-request:FM-12': {},
  }
}

async function runOnce(argsStr, canned) {
  const budget = { spent: () => 0 }
  const phase = () => {}
  const log = (s) => LINES.push(String(s))
  const parallel = (fns) => Promise.all(fns.map((f) => f()))
  const agent = async (prompt, opts) => {
    const label = opts && opts.label
    if (label) { SPAWNED.push(label); PROMPTS[label] = prompt }
    if (!label || !(label in canned)) throw new Error('selftest: unstubbed agent label ' + label)
    return canned[label]
  }
  const wf = require(HARNESS)
  return wf(argsStr, budget, phase, agent, log, parallel, undefined, undefined)
}

function report(name, ok, detail) {
  console.log(`RESULT ${name} ${ok ? 'PASS' : 'FAIL'}${detail ? ' ' + detail : ''}`)
}

;(async () => {
  try {
    if (SCENARIO === 'A') {
      const result = await runOnce(ARGS, cannedFor('A', ''))
      report('scenario-A_first-run_both-repos-kickoff-spawned', SPAWNED.includes('kickoff:FM-12:your-app') && SPAWNED.includes('kickoff:FM-12:your-tests'))
      report('scenario-A_status-awaiting-plan-approval', !!result && result.status === 'awaiting-plan-approval', `got=${result && result.status}`)
      const fpLine = LINES.find((l) => /fp=([0-9a-f]+)/.test(l))
      const fp = fpLine ? fpLine.match(/fp=([0-9a-f]+)/)[1] : null
      report('scenario-A_fingerprint-logged', !!fp)
      if (fp) console.log(`FP=${fp}`)
      report('scenario-A_publish-request-spawned', SPAWNED.includes('publish-request:FM-12'))
      const prompt = PROMPTS['publish-request:FM-12'] || ''
      report('scenario-A_republish-url-threaded-for-your-app', prompt.includes('url=https://claude.ai/public/artifacts/abc'))
      report('scenario-A_your-tests-marked-not-published-before', /your-tests[\s\S]*not published before/.test(prompt))
      // ADR-0025/0026 — what a FRESH kickoff must ask its planner for, since these are the fields
      // the resume path and the ticket's records are built out of.
      const kp = PROMPTS['kickoff:FM-12:your-app'] || ''
      report('scenario-A_planner-asked-for-plan-sha', kp.includes('plan_sha') && kp.includes('shasum -a 256'))
      report('scenario-A_planned-row-records-the-base', kp.includes('"base_branch":"develop"'))
      const qp = PROMPTS['kickoff:FM-12:your-tests'] || ''
      report('scenario-A_qa-plan-is-a-durable-record', qp.includes('[qa-plan · your-tests]') && qp.includes('upsert-ticket-comment.sh'))
      report('scenario-A_qa-plan-history-is-a-ledger', qp.includes('FM-12-qa-plan-history.tsv'))
      report('scenario-A_automation-plan-not-published', qp.includes('AUTOMATION plan is NOT published'))
      report('scenario-A_plan-links-record-requested', prompt.includes('[plans · FM-12]') && prompt.includes('upsert-ticket-comment.sh'))
    } else if (SCENARIO === 'B') {
      const result = await runOnce(ARGS, cannedFor('B', FP))
      report('scenario-B_skip_no-kickoff-spawned', !SPAWNED.some((l) => l.startsWith('kickoff:')))
      report('scenario-B_skip_kickoff-skipped-logged-twice', LINES.filter((l) => l.includes('Kickoff SKIPPED')).length === 2)
      report('scenario-B_skip_no-publish-request-spawned', !SPAWNED.includes('publish-request:FM-12'))
      report('scenario-B_status-awaiting-plan-approval', !!result && result.status === 'awaiting-plan-approval')
      const plans = (result && result.plans) || []
      report('scenario-B_plans-carry-rehydrated-title', plans.length === 2 && plans.every((p) => p.title === 'T'))
      report('scenario-B_plans-carry-rehydrated-acceptance', plans.length === 2 && plans.every((p) => (p.acceptance || []).length >= 1))
    } else if (SCENARIO === 'C') {
      await runOnce(ARGS, cannedFor('C', FP))
      report('scenario-C_invalidation-logged', LINES.some((l) => l.includes("INVALIDATING every 'planned' row")))
      report('scenario-C_both-repos-replanned', SPAWNED.includes('kickoff:FM-12:your-app') && SPAWNED.includes('kickoff:FM-12:your-tests'))
    } else if (SCENARIO === 'D') {
      await runOnce(ARGS, cannedFor('D', ''))
      // The unscoped repo keeps ITS OWN base — which for a test-suite repo is now the workspace
      // feature base, not the fix base (docs/adr/0025). This assertion used to expect 'main',
      // encoding the very constant that cut suite branches off a dead trunk: it asserted the
      // projection instead of the intent, so it passed all the way through the incident.
      report('scenario-D_scoped-base-resolved', LINES.some((l) => l.includes('your-app@feature/FM-12→release/1.4')) && LINES.some((l) => l.includes('your-tests@feature/FM-12→develop')))
      report('scenario-D_resolved-base-table-printed-before-any-planner',
        LINES.findIndex((l) => l.startsWith('Resolved bases')) !== -1
        && LINES.findIndex((l) => l.startsWith('Resolved bases')) < LINES.findIndex((l) => l.includes('Build: all')))
      report('scenario-D_table-attributes-each-base-to-its-source',
        LINES.some((l) => l.includes('your-app→release/1.4 [flag]') && l.includes('your-tests→develop [repo default]')))
    } else if (SCENARIO === 'D2') {
      await runOnce(ARGS, cannedFor('D', ''))
      report('scenario-D2_unscoped-base-applies-to-both', LINES.some((l) => l.includes('your-app@feature/FM-12→release/1.4')) && LINES.some((l) => l.includes('your-tests@feature/FM-12→release/1.4')))
    } else if (SCENARIO === 'E1' || SCENARIO === 'E2') {
      // C12 — the fingerprint must ignore comment_count. Pre-existing 'planned' rows are recorded
      // under FP (computed upstream from scenario A, i.e. WITHOUT comment_count); this run's canned
      // scope differs from A only in whether/how comment_count is present. A correct fingerprint
      // still matches FP in both variants, so the skip fires and no kickoff is spawned.
      await runOnce(ARGS, cannedFor(SCENARIO, FP))
      report(`scenario-${SCENARIO}_skip_no-kickoff-spawned`, !SPAWNED.some((l) => l.startsWith('kickoff:')))
      report(`scenario-${SCENARIO}_skip_kickoff-skipped-logged-twice`, LINES.filter((l) => l.includes('Kickoff SKIPPED')).length === 2)
      const fpLine = LINES.find((l) => /fp=([0-9a-f]+)/.test(l))
      const fp = fpLine ? fpLine.match(/fp=([0-9a-f]+)/)[1] : null
      report(`scenario-${SCENARIO}_fingerprint-logged`, !!fp)
      if (fp) console.log(`FP=${fp}`)
    } else if (SCENARIO === 'F') {
      // ARG SANITY (docs/adr/0025). Each bad invocation must THROW, and must throw before any
      // agent is spawned at all — an argument the run cannot honour costs zero tokens. The
      // measured failure this replaces: one invocation spent ~20 agents resolving every repo to
      // its unchanged default because an invented flag shape was only ever logged.
      const cases = [
        ['free-text-base', 'FM-12 a fast-track for release/v7.10.3', ['unrecognised argument', 'looks like a branch', '--feature-base release/v7.10.3']],
        ['repos-without-value', 'FM-12 --feature-base-repos your-app', ['without --feature-base', 'no repo=value mapping form']],
        ['repo-eq-value-token', 'FM-12 --feature-base develop --feature-base-repos your-app=release/1.4', ['unregistered repo id', 'your-app=release/1.4']],
        ['base-and-feature-base', 'FM-12 --base main --feature-base develop', ['both given']],
      ]
      for (const [name, argv, wants] of cases) {
        SPAWNED.length = 0
        let msg = null
        try { await runOnce(argv, cannedFor('A', '')) } catch (e) { msg = String((e && e.message) || e) }
        report(`scenario-F_${name}_throws`, !!msg, msg ? '' : 'no error thrown')
        report(`scenario-F_${name}_spawned-nothing`, SPAWNED.length === 0, `spawned=${SPAWNED.join(',')}`)
        for (const w of wants) report(`scenario-F_${name}_says_${w.replace(/\W+/g, '-')}`, !!msg && msg.includes(w), msg || '')
      }
      // And the valid shapes still parse — a guard that rejects good input is worse than none.
      for (const [name, argv] of [['plain', 'FM-12'], ['scoped', 'FM-12 --feature-base release/1.4 --feature-base-repos your-app'], ['booleans', 'FM-12 --dry-run --approve-plan --token-budget 5 --accept-base-change']]) {
        let msg = null
        try { await runOnce(argv, cannedFor('A', '')) } catch (e) { msg = String((e && e.message) || e) }
        report(`scenario-F_valid-${name}_accepted`, !msg || !msg.includes('unrecognised'), msg || '')
      }
    } else if (SCENARIO === 'G' || SCENARIO === 'G2' || SCENARIO === 'G3') {
      // BASE AS STATE. The 'planned' rows record base_branch=release/1.4 for your-app.
      const canned = cannedFor('B', FP)
      canned['run-state:FM-12'] = { rows: rowsFor('B', FP).map((r) => (
        r.repo === 'your-app' ? { ...r, base_branch: 'release/1.4' } : { ...r, base_branch: 'develop' })) }
      let msg = null, result = null
      try { result = await runOnce(ARGS, canned) } catch (e) { msg = String((e && e.message) || e) }
      if (SCENARIO === 'G') {
        // No flag this invocation: the RECORDED base wins, so the silent revert to the repo
        // default cannot happen — the failure that put four MRs on unasked-for branches.
        report('scenario-G_recorded-base-wins', !msg && LINES.some((l) => l.includes('your-app → release/1.4') && l.includes('RECORDED')), msg || '')
        report('scenario-G_table-attributes-it-to-run-state', LINES.some((l) => l.includes('your-app→release/1.4 [run state]')))
        report('scenario-G_plan-carries-the-recorded-base', !!result && (result.plans || []).some((p) => p.repo === 'your-app' && p.base_branch === 'release/1.4'))
      } else if (SCENARIO === 'G2') {
        // A flag that DISAGREES, without --accept-base-change: stop, never silently re-base.
        report('scenario-G2_conflict-throws', !!msg && msg.includes('base conflict'), msg || 'no error')
        report('scenario-G2_names-both-branches', !!msg && msg.includes('release/1.4') && msg.includes('develop'), msg || '')
        report('scenario-G2_offers-the-flag', !!msg && msg.includes('--accept-base-change'), msg || '')
      } else {
        // With --accept-base-change: proceed, and invalidate what was proven against the old base.
        report('scenario-G3_accepted-does-not-throw', !msg, msg || '')
        report('scenario-G3_logs-the-rebase', LINES.some((l) => l.includes('RE-BASED release/1.4 → develop')))
        report('scenario-G3_degrades-the-old-proof', LINES.some((l) => l.includes('DEGRADED') && l.includes('its base changed')))
      }
    } else if (SCENARIO === 'H') {
      // PLAN → BUILD FINGERPRINT. The loader stamps the LIVE plan's sha onto the 'planned' row;
      // the reuse path must carry it into the plan so the Build phase can compare it against
      // what the 'built' row says it was built FROM. The deadlock this fixes: a re-plan does not
      // move the branch head, so 'built' stayed non-degraded, Build was skipped as already-done,
      // and the corrected plan was never built — twice, on one ticket.
      const canned = cannedFor('B', FP)
      canned['run-state:FM-12'] = { rows: rowsFor('B', FP).map((r) => ({ ...r, plan_sha: 'aaaaaaaaaaaaaaaa' })) }
      const result = await runOnce(ARGS, canned)
      const plan = (result && (result.plans || []).find((p) => p.repo === 'your-app')) || null
      report('scenario-H_reused-plan-carries-plan-sha', !!plan && plan.plan_sha === 'aaaaaaaaaaaaaaaa', plan ? `got=${plan.plan_sha}` : 'no plan')
    } else {
      throw new Error('unknown scenario ' + SCENARIO)
    }
  } catch (e) {
    report(`scenario-${SCENARIO}_crashed`, false, String((e && e.stack) || e).split('\n')[0])
    process.exitCode = 1
  }
})()
NODE

run_scenario() {
  local scenario="$1" fp="${2:-}" args="${3:-$TICKET}"
  HARNESS="$HARNESS" SCENARIO="$scenario" FP="$fp" ARGS="$args" node "$DRIVER" 2>&1
}

ingest() {
  local out="$1"
  while IFS= read -r line; do
    case "$line" in
      RESULT\ *\ PASS*) pass "${line#RESULT }" ;;
      RESULT\ *\ FAIL*) fail "${line#RESULT }" ;;
    esac
  done <<<"$out"
}

echo "── scenario A — first run, no 'planned' state"
outA="$(run_scenario A)"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outA" | sed 's/^/      /'
ingest "$outA"
FP="$(grep -o 'FP=[0-9a-f]\+' <<<"$outA" | head -1 | cut -d= -f2)"
if [[ -n "$FP" ]]; then pass "scraped ticket fingerprint fp=$FP for B/C"; else fail "could not scrape fp= from scenario A output"; fi

echo "── scenario B — skip (ticket unchanged since last plan)"
outB="$(run_scenario B "$FP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outB" | sed 's/^/      /'
ingest "$outB"

echo "── scenario C — invalidate everywhere (ticket edited)"
outC="$(run_scenario C "$FP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outC" | sed 's/^/      /'
ingest "$outC"

echo "── scenario D — --feature-base-repos scopes the override"
outD="$(run_scenario D "" "$TICKET --feature-base release/1.4 --feature-base-repos $APP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outD" | sed 's/^/      /'
ingest "$outD"

echo "── scenario D2 — no regression: --feature-base alone still applies to every repo"
outD2="$(run_scenario D2 "" "$TICKET --feature-base release/1.4")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outD2" | sed 's/^/      /'
ingest "$outD2"

echo "── scenario E — fingerprint ignores comment_count (C12)"
outE1="$(run_scenario E1 "$FP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outE1" | sed 's/^/      /'
ingest "$outE1"
FP_E1="$(grep -o 'FP=[0-9a-f]\+' <<<"$outE1" | head -1 | cut -d= -f2)"
outE2="$(run_scenario E2 "$FP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outE2" | sed 's/^/      /'
ingest "$outE2"
FP_E2="$(grep -o 'FP=[0-9a-f]\+' <<<"$outE2" | head -1 | cut -d= -f2)"
if [[ -n "$FP_E1" && "$FP_E1" == "$FP_E2" ]]; then
  pass "scenario-E_fingerprint-identical-with-and-without-comment_count (fp=$FP_E1)"
else
  fail "scenario-E_fingerprint-identical-with-and-without-comment_count (E1=$FP_E1 E2=$FP_E2)"
fi

echo "── scenario F — a bad argument stops the run before it costs an agent"
outF="$(run_scenario F)"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outF" | sed 's/^/      /'
ingest "$outF"

echo "── scenario G — the recorded base wins on a resume with no flag"
outG="$(run_scenario G "$FP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outG" | sed 's/^/      /'
ingest "$outG"

echo "── scenario G2 — a disagreeing override stops instead of re-basing quietly"
outG2="$(run_scenario G2 "$FP" "$TICKET --feature-base $SUITE_BASE")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outG2" | sed 's/^/      /'
ingest "$outG2"

echo "── scenario G3 — --accept-base-change re-bases and invalidates the old proof"
outG3="$(run_scenario G3 "$FP" "$TICKET --feature-base $SUITE_BASE --accept-base-change")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outG3" | sed 's/^/      /'
ingest "$outG3"

echo "── scenario H — a reused plan carries the live plan's fingerprint"
outH="$(run_scenario H "$FP")"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outH" | sed 's/^/      /'
ingest "$outH"

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
