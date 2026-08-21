#!/usr/bin/env bash
#
# dev-cycle-gate-selftest.sh — offline, zero-token proof of the DEVCYCLE-RESILIENCE
# gate/repair changes: C1 (gate-only build), C2 (upstream degrade), C3 (blocked-on
# repair vs hard halt), C4 (red-gate triage), C5 (multi-suite fan-out), C9 (budget
# stop), C10 (notify vs DM).
#
# Same construction as scripts/dev-cycle-kickoff-selftest.sh: the REAL workflow
# source, stripped of `export` and wrapped in the engine's own function-body
# context, then driven with canned agent() responses so the real branch logic runs
# with no network and no tokens. Additionally substitutes the CONFIG block (between
# the AIWORKS:CONFIG markers) with a small fixture registry (2-4 repos, at least one
# test_suite:true) when CONFIG_FIXTURE is set — needed for a second test-suite repo
# (G3) and for NOTIFY/NOTIFY_DM (G5/G6), which the real committed config does not
# carry in a form this suite can rely on staying stable.
#
# Usage: scripts/dev-cycle-gate-selftest.sh [-v]
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$DIR/.claude/workflows/dev-cycle.js"
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

# A small, self-contained REPOS registry: three code repos ('db','svc', db→svc chain available
# for C2/C3, plus 'app' which DECLARES guard+perf so the scoped quality check of ADR 0024 has a
# repo to fire on — 'svc' declares neither, which is the other half of that test) and two
# test-suite repos ('e2e','api', for C5's fan-out).
# NOTIFY_DM/TEST_SUITE.maxFixRounds/DEV_CYCLE.tokenBudget read from process.env so one
# generated harness serves every scenario without being regenerated per run.
CONFIG_FIXTURE='const TICKET_PREFIX = "FM"
const AUTO_MERGE = false
const AUTO_APPROVE_PLAN = true
const PLAN_TO_HTML = false
const NOTIFY = true
const NOTIFY_PROVIDER = "slack"
const NOTIFY_CHANNEL = "#code-reviews"
const NOTIFY_DM = process.env.FIXTURE_NOTIFY_DM || "U012345"
const DESIGN_ENABLED = false
const QUALITY_GATE = "none"
const REVIEW_LEVEL = "strict"
const LANGUAGE = "en"
const LOADTEST = { tolerancePct: 10, noiseRuns: 2, noiseCeilingMultiple: 2, maxFixRounds: 2, baselineCache: "~/.cache/x" }
const TEST_SUITE = { maxFixRounds: Number(process.env.FIXTURE_TS_MAX_FIX_ROUNDS || 2) }
const DEV_CYCLE = { tokenBudget: Number(process.env.FIXTURE_TOKEN_BUDGET || 0) }
const STATUS = { in_progress: "In progress", ready_to_test: "Ready to test", testing: "Testing", done: "Done" }
const REPOS = {
  db:  { path: "db",  kind: "backend", base: { feature: "develop", fix: "main" }, plan: "development-planner", build: "developer", review: "code-reviewer", guard: false, perf: false, green: "db green" },
  svc: { path: "svc", kind: "backend", base: { feature: "develop", fix: "main" }, plan: "development-planner", build: "developer", review: "code-reviewer", guard: false, perf: false, green: "svc green" },
  app: { path: "app", kind: "frontend", base: { feature: "develop", fix: "main" }, plan: "development-planner", build: "developer", review: "code-reviewer", guard: true, perf: true, green: "app green", guardianFocus: "secrets, data-protection" },
  e2e: { path: "e2e", kind: "test-suite", base: { feature: "main", fix: "main" }, plan: "qa-planner", build: "qa-runner", review: null, guard: false, perf: false, green: "e2e green", testSuite: true },
  api: { path: "api", kind: "test-suite", base: { feature: "main", fix: "main" }, plan: "qa-planner", build: "qa-runner", review: null, guard: false, perf: false, green: "api green", testSuite: true },
}'

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
grep -q 'const REPOS = {' "$HARNESS" || { echo "CONFIG_FIXTURE substitution failed — marker text may have drifted" >&2; exit 1; }

DRIVER="$TMP/driver.cjs"
cat > "$DRIVER" <<'NODE'
const HARNESS = process.env.HARNESS
const SCENARIO = process.env.SCENARIO
const ARGS = process.env.ARGS || 'FM-12 --approve-plan'
// The ticket fingerprint, scraped from a probe run by the shell below (same idiom as
// dev-cycle-kickoff-selftest.sh): a 'planned' row is only skippable when it carries THIS run's fp.
const FP = process.env.FP || ''

const LINES = []
const SPAWNED = []
const PROMPTS = {}
const PHASES = []

const REPO_PLAN = (repo, base) => ({
  repo, title: 'T', acceptance: [`${repo} does its part`],
  base_branch: base, work_branch: 'feature/FM-12',
  plan_path: `/tmp/ws/${repo}/plan.md`, plan_html: null,
  summary: 'planned', unverified_claims: [],
})
const planGuardOk = (repos) => ({ repos: repos.map((r) => ({ repo: r, ok: ['x'], relocated: [], missing: [] })) })
const runStateRow = (repo, milestone, extra = {}) => ({ repo, milestone, status: 'done', recorded_at: '2026-01-01T00:00:00Z', degraded: false, ...extra })
const builtRow = (repo, sha) => runStateRow(repo, 'built', { work_branch: 'feature/FM-12', head_sha: sha || `sha-${repo}` })
const prRow = (repo, n) => runStateRow(repo, 'pr_open', { pr_number: n, pr_url: `https://x/${n}` })
const reviewedRow = (repo) => runStateRow(repo, 'reviewed')
// REVIEW LEDGER rows (ADR 0021). 'done' => that gate is frozen; 'in-progress' + first_pass
// => it did its one complete pass but findings are still open, so it RE-VISITS on resume.
const gatePassedRow = (repo, key) => ({ ...runStateRow(repo, `gate_${key}`), first_pass: true, head_sha: `sha-${repo}` })
const gateFirstPassRow = (repo, key) => ({ ...runStateRow(repo, `gate_${key}`), status: 'in-progress', first_pass: true, head_sha: `sha-${repo}` })
// A repo that should return 'ready' with ZERO agent spawns this run — fully resumed.
const readyRows = (repo, n) => [builtRow(repo), prRow(repo, n), reviewedRow(repo)]

async function runOnce(argsStr, canned, opts = {}) {
  const spendJumpAfterPhase = opts.spendJumpAfterPhase || null
  const spendValue = opts.spendValue || 999999999
  const budget = { spent: () => (spendJumpAfterPhase && PHASES.includes(spendJumpAfterPhase)) ? spendValue : 0 }
  const phase = (name) => { PHASES.push(name) }
  const log = (s) => LINES.push(String(s))
  const parallel = (fns) => Promise.all(fns.map((f) => f()))
  const agent = async (prompt, opts2) => {
    const label = opts2 && opts2.label
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

const BASE = {
  'resolve-runtime-config': { language: 'en', plan_to_html: false, auto_approve: true, artifacts_enabled: false },
  'ws-root:FM-12': { workspace_root: '/tmp/ws' },
  'status:FM-12:in_progress': { moved: true },
  'status:FM-12:ready_to_test': { moved: true },
  'status:FM-12:testing': { moved: true },
}

;(async () => {
  try {
    if (SCENARIO === 'G1') {
      // C2 — upstream degrade. db's 'built' row has moved (live_sha != head_sha, so the loader
      // already marked it degraded); svc's 'built' row is NOT degraded; svc depends_on db;
      // e2e depends_on svc (chain). Assert: svc degrades TOO, in the same pass; build:FM-12:svc
      // IS spawned (its own 'built' row is no longer skippable); "[svc] build SKIPPED" never logs.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [
          builtRow('db', 'sha-db-OLD'), { ...runStateRow('db', 'built', { degraded: true }) },
          builtRow('svc'), builtRow('e2e'),
        ] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }, { repo: 'e2e', depends_on: ['svc'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
      }
      await runOnce(ARGS, canned)
      report('G1_svc_degraded_logged', LINES.some((l) => l.includes('svc') && l.includes('DEGRADED') && l.includes('declared upstream db')))
      report('G1_build_svc_spawned', SPAWNED.includes('build:FM-12:svc'))
      report('G1_build_svc_not_skipped', !LINES.some((l) => l.includes('[svc] build SKIPPED')))
      report('G1_chain_e2e_also_degraded', LINES.some((l) => l.includes('e2e') && l.includes('DEGRADED') && l.includes('declared upstream svc')))
    } else if (SCENARIO === 'G2A') {
      // C3 — repair path. db has NO row at all this run (repoResults[db] is undefined during
      // Build by construction — the whole batch's results are assigned only after every
      // sibling's pipeline has returned, so "no repoResults entry" is the ONLY reachable case
      // for a same-batch sibling; see docs/adr/0019 / the change-set report for the measured
      // limit this implies for a genuine hard-halt). svc's reviewer names db in a comment.
      // Expect: NOT review-blocked-on; pr-fix:FM-12:svc#1 spawned with UPSTREAM SYNC + path "db".
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }],
          test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'open-pr:FM-12:svc': { pr_url: 'https://x/9', pr_number: 9 },
        'review:FM-12:svc#1': { approved: false, tests_green: true, tests_receipt: 'ok', comments: [{ file_line: 'a:1', issue: 'needs the change in db', severity: 'blocking' }] },
      }
      const result = await runOnce(ARGS, canned)
      report('G2A_not_blocked_on', !(result && result.status === 'review-blocked-on'))
      report('G2A_pr_fix_spawned', SPAWNED.includes('pr-fix:FM-12:svc#1'))
      const p = PROMPTS['pr-fix:FM-12:svc#1'] || ''
      report('G2A_prompt_has_upstream_sync', p.includes('UPSTREAM SYNC'))
      report('G2A_prompt_names_db_path', p.includes('path "db"'))
    } else if (SCENARIO === 'G2B') {
      // C3, LOGIC LEVEL (not end-to-end — see G2A's note on why repoResults[id] cannot hold a
      // value for a same-batch sibling). Re-implements upstreamState()/hardBlockers verbatim
      // against a MOCKED repoResults, to prove the CLASSIFICATION itself is correct: a sibling
      // whose pipeline genuinely finished WITHOUT reaching 'ready' (repoResults populated —
      // reachable only on an already-resolved batch, e.g. a resumed second wave in a future
      // engine shape) is a hard blocker, never silently repaired.
      const repoResults = { db: { status: 'build-unresolved' } }
      const doneAt = () => false
      const upstreamState = (id) => repoResults[id] ? repoResults[id].status : (doneAt(id, 'reviewed') ? 'ready' : 'pending')
      const named = ['db']
      const hardBlockers = named.filter((id) => upstreamState(id) !== 'ready' && upstreamState(id) !== 'pending')
      report('G2B_logic_hard_blocker_when_repoResults_populated_nonready', hardBlockers.length === 1 && hardBlockers[0] === 'db')
      const repoResults2 = {}
      const upstreamState2 = (id) => repoResults2[id] ? repoResults2[id].status : (doneAt(id, 'reviewed') ? 'ready' : 'pending')
      const hardBlockers2 = named.filter((id) => upstreamState2(id) !== 'ready' && upstreamState2(id) !== 'pending')
      report('G2B_logic_no_hard_blocker_when_repoResults_empty_pending', hardBlockers2.length === 0)
    } else if (SCENARIO === 'G3') {
      // C5 — multi-suite fan-out. TWO test-suite repos (e2e, api), both scoped, db as the one
      // app repo. All three fully resumed-ready except the two gates, which must BOTH run.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2), ...readyRows('api', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }, { repo: 'api', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e', 'api']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'kickoff:FM-12:api': REPO_PLAN('api', 'main'),
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'scripts/dev.sh test e2e', exit_code: 0, summary_line: '5 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'test-suite:FM-12:api': { passed: false, receipt: { command: 'scripts/dev.sh test api', exit_code: 1, summary_line: '1 failed' }, failures: [{ case: 'TC1', evidence: 'boom' }], triage: [] },
        'audit:FM-12:api': { posted: true, detail: 'result posted' },
      }
      const result = await runOnce(ARGS, canned)
      report('G3_both_gates_spawned', SPAWNED.includes('test-suite:FM-12:e2e') && SPAWNED.includes('test-suite:FM-12:api'))
      report('G3_api_red_fails_the_run_naming_api', result && result.status === 'test-suite-failed' && String(result.why || '').includes('api'))
      const e2eRow = "agent_logs/FM-12-dev-cycle-state/e2e-test_suite.json"
      const apiRow = "agent_logs/FM-12-dev-cycle-state/api-test_suite.json"
      report('G3_e2e_prompt_names_its_own_run_state_row', (PROMPTS['test-suite:FM-12:e2e'] || '').includes(e2eRow))
      report('G3_api_prompt_names_its_own_run_state_row', (PROMPTS['test-suite:FM-12:api'] || '').includes(apiRow))
    } else if (SCENARIO === 'G3_GREEN') {
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2), ...readyRows('api', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }, { repo: 'api', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e', 'api']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'kickoff:FM-12:api': REPO_PLAN('api', 'main'),
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'scripts/dev.sh test e2e', exit_code: 0, summary_line: '5 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'test-suite:FM-12:api': { passed: true, receipt: { command: 'scripts/dev.sh test api', exit_code: 0, summary_line: '3 passed' } },
        'audit:FM-12:api': { posted: true, detail: 'result posted' },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      report('G3_GREEN_reaches_merge_gate', result && (result.status === 'merge-skipped' || result.status === 'awaiting-human-ship'))
    } else if (SCENARIO === 'G4') {
      // C4 + ADR 0024 — the repair loop. Gate 1 returns passed:false with one "app" red naming the
      // `app` repo, which DECLARES guard+perf. The fix lands, both scoped quality checks clear it
      // over the fix diff, and gate 2 (round 1's re-run) is green. No code reviewer anywhere in
      // this loop: the repo's code review was already cleared in the Review phase.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'scripts/dev.sh test e2e', exit_code: 1, summary_line: '1 failed' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'expected 200 got 500' }] },
        'gate-fix:FM-12:app#1.1': { work_branch: 'feature/FM-12', summary: 'fixed', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.1': { passed: true, conclusion: 'no smell introduced by the fix diff' },
        'gate-perf:FM-12:app#1.1': { passed: true, conclusion: 'no added round-trip on the changed flow' },
        'test-suite:FM-12:e2e#r1': { passed: true, receipt: { command: 'scripts/dev.sh test e2e', exit_code: 0, summary_line: '5 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      const iFix = SPAWNED.indexOf('gate-fix:FM-12:app#1.1')
      report('G4_fix_then_scoped_checks_spawned_in_order', iFix >= 0
        && SPAWNED.indexOf('gate-guard:FM-12:app#1.1') > iFix
        && SPAWNED.indexOf('gate-perf:FM-12:app#1.1') > iFix)
      report('G4_no_code_reviewer_in_this_loop', !SPAWNED.some((l) => l.startsWith('gate-review:')))
      const gp = PROMPTS['gate-guard:FM-12:app#1.1'] || ''
      report('G4_check_is_diff_scoped_and_names_the_case', gp.includes('SCOPED QUALITY CHECK') && gp.includes('TC001') && gp.includes('Raise NOTHING else'))
      report('G4_check_is_told_review_already_cleared', gp.includes('already passed in this run'))
      report('G4_fix_told_its_diff_is_checked', (PROMPTS['gate-fix:FM-12:app#1.1'] || '').includes('YOUR FIX IS CHECKED ON GUARD + PERF'))
      report('G4_gate_reran', SPAWNED.includes('test-suite:FM-12:e2e#r1'))
      report('G4_run_proceeds_past_gate', !!result && result.status !== 'test-suite-failed' && result.status !== 'test-suite-unverified')
    } else if (SCENARIO === 'G4_CHECK_REJECTED') {
      // ADR 0024 — a rejected scoped check does NOT halt on the first rejection and does NOT fall
      // through to the suite re-run: it retries the SAME red's fix inside this round, and only an
      // exhausted attempt bound halts the suite. FIXTURE_TS_MAX_FIX_ROUNDS=2 ⇒ 2 attempts.
      const rejected = { passed: false, conclusion: 'the fix bought its green with a per-row query', blocking: [{ title: 'N+1 introduced', scope: 'app/src/x.ts:20', evidence: 'query inside the loop' }] }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 failed' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'expected 200 got 500' }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'gate-fix:FM-12:app#1.1': { work_branch: 'feature/FM-12', summary: 'attempt 1', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.1': { passed: true, conclusion: 'clean' },
        'gate-perf:FM-12:app#1.1': rejected,
        'gate-fix:FM-12:app#1.2': { work_branch: 'feature/FM-12', summary: 'attempt 2', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.2': { passed: true, conclusion: 'clean' },
        'gate-perf:FM-12:app#1.2': rejected,
      }
      const result = await runOnce(ARGS, canned)
      report('G4b_rejected_check_retries_the_same_red_fix', SPAWNED.includes('gate-fix:FM-12:app#1.2'))
      report('G4b_retry_brief_carries_what_was_rejected', (PROMPTS['gate-fix:FM-12:app#1.2'] || '').includes('PRIOR ATTEMPT REJECTED') && (PROMPTS['gate-fix:FM-12:app#1.2'] || '').includes('N+1 introduced'))
      report('G4b_suite_not_rerun_while_the_check_is_unresolved', !SPAWNED.includes('test-suite:FM-12:e2e#r1'))
      report('G4b_halts_once_the_attempt_bound_is_exhausted', !!result && result.status === 'test-suite-failed' && String(result.why || '').includes('quality check for TC001 did not clear'))
      report('G4b_no_third_attempt', !SPAWNED.includes('gate-fix:FM-12:app#1.3'))
    } else if (SCENARIO === 'G4_ROUNDS_EXHAUSTED') {
      const cleared = { passed: true, conclusion: 'clean' }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        // The same "app" red every round, and every round's fix CLEARS its quality check — so the
        // only thing that ends this is the ROUND budget (FIXTURE_TS_MAX_FIX_ROUNDS=2).
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'still 500' }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'gate-fix:FM-12:app#1.1': { work_branch: 'feature/FM-12', summary: 'try 1', status: 'complete', fixed: [] },
        'gate-guard:FM-12:app#1.1': cleared,
        'gate-perf:FM-12:app#1.1': cleared,
        'test-suite:FM-12:e2e#r1': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'still 500' }] },
        'gate-fix:FM-12:app#2.1': { work_branch: 'feature/FM-12', summary: 'try 2', status: 'complete', fixed: [] },
        'gate-guard:FM-12:app#2.1': cleared,
        'gate-perf:FM-12:app#2.1': cleared,
        'test-suite:FM-12:e2e#r2': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'still 500' }] },
      }
      const result = await runOnce(ARGS, canned, {})
      report('G4c_rounds_exhausted_fails_the_gate', !!result && result.status === 'test-suite-failed' && String(result.why || '').includes('triage round'))
      report('G4c_third_round_never_spawned', !SPAWNED.includes('gate-fix:FM-12:app#3.1'))
    } else if (SCENARIO === 'G4_PRE_EXISTING') {
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('svc', 2), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }, { repo: 'e2e', depends_on: ['svc'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' }, triage: [{ case: 'TC001', kind: 'app', repo: 'svc', evidence: 'red on base too', pre_existing_on_base: true }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
      }
      const result = await runOnce(ARGS, canned)
      report('G4d_pre_existing_no_fix_spawned', !SPAWNED.some((l) => l.startsWith('gate-fix:')))
      report('G4d_halts_with_evidence', !!result && result.status === 'test-suite-failed')
    } else if (SCENARIO === 'G5') {
      // C9 — budget stop. spent() jumps to a big number the moment phase('Kickoff') has fired,
      // so the "before Build" overBudget() check (which runs after phase('Kickoff') but before
      // phase('Build')) is the first one to trip.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'summary:FM-12': { summary_path: '/tmp/x.md', token_table_appended: true, note: 'ok' },
      }
      const result = await runOnce(ARGS, canned, { spendJumpAfterPhase: 'Kickoff' })
      report('G5_status_budget_stopped', !!result && result.status === 'budget-stopped', `got=${result && result.status}`)
      report('G5_stopped_before_build', !!result && result.stopped_before === 'Build')
      report('G5_summary_spawned', SPAWNED.includes('summary:FM-12'))
      report('G5_notify_not_spawned', !SPAWNED.includes('notify:FM-12'))
      report('G5_dm_spawned', SPAWNED.includes('dm:FM-12:budget-stopped'))
      report('G5_no_build_spawned', !SPAWNED.some((l) => l.startsWith('build:')))
    } else if (SCENARIO === 'G6A') {
      // C10 — a full green run, AUTO_MERGE=false (the fixture's committed value) ⇒ 'merge-skipped'
      // is a COMPLETE ending: notify:FM-12 fires, no dm: label.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: 'ok' } },
        'audit:FM-12:e2e': { posted: true, detail: 'x' },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      report('G6a_status_merge_skipped', !!result && result.status === 'merge-skipped', `got=${result && result.status}`)
      report('G6a_notify_spawned', SPAWNED.includes('notify:FM-12'))
      report('G6a_no_dm_spawned', !SPAWNED.some((l) => l.startsWith('dm:')))
    } else if (SCENARIO === 'G6B') {
      // Same shape, gate fails with an unclassified red (no triage) ⇒ test-suite-failed, an
      // INCOMPLETE ending: dm:FM-12:test-suite-failed fires, no notify:FM-12.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
      }
      const result = await runOnce(ARGS, canned)
      report('G6b_status_test_suite_failed', !!result && result.status === 'test-suite-failed')
      report('G6b_dm_spawned', SPAWNED.includes('dm:FM-12:test-suite-failed'))
      report('G6b_no_notify_spawned', !SPAWNED.includes('notify:FM-12'))
      const dmPrompt = PROMPTS['dm:FM-12:test-suite-failed'] || ''
      report('G6b_dm_prompt_has_summary_and_resume', dmPrompt.includes('/dev-cycle FM-12') && dmPrompt.includes('Summary'))
    } else if (SCENARIO === 'G6C') {
      // Same red gate, but notify.dm_on_incomplete left at the shipped placeholder ⇒ neither
      // label fires.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
      }
      const result = await runOnce(ARGS, canned)
      report('G6c_neither_label_spawned', !SPAWNED.some((l) => l.startsWith('dm:') || l === 'notify:FM-12'))
    } else if (SCENARIO === 'G7') {
      // C1 — gate-only build. e2e's build is NOT resumed (must actually run, to capture its
      // prompt); db is fully resumed-ready. Assert the build prompt forbids suite execution and
      // omits CANDIDATE STACK, while the gate prompt carries CANDIDATE STACK.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'automated', status: 'complete', fixed: ['e2e/specs/x.spec.ts'] },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/5', pr_number: 5 },
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: 'ok' } },
        'audit:FM-12:e2e': { posted: true, detail: 'x' },
        'notify:FM-12': { sent: true },
      }
      await runOnce(ARGS, canned)
      const buildPrompt = PROMPTS['build:FM-12:e2e'] || ''
      const gatePrompt = PROMPTS['test-suite:FM-12:e2e'] || ''
      report('G7_build_prompt_has_no_suite_execution', buildPrompt.includes('NO SUITE EXECUTION AT BUILD'))
      report('G7_build_prompt_omits_candidate_stack', !buildPrompt.includes('CANDIDATE STACK'))
      report('G7_gate_prompt_has_candidate_stack', gatePrompt.includes('CANDIDATE STACK'))
    } else if (SCENARIO === 'G8A') {
      // ADR 0021 — a gate whose ledger row says PASSED is frozen: the review loop is skipped
      // outright even though no 'reviewed' row exists (the merge phase writes that one, so a run
      // that died before the merge never had it). No reviewer is spawned at all.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [builtRow('db'), prRow('db', 7), gatePassedRow('db', 'review')] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
      }
      const result = await runOnce(ARGS, canned)
      report('G8A_no_reviewer_spawned', !SPAWNED.some((l) => l.startsWith('review:FM-12:db')))
      report('G8A_skip_logged_from_ledger', LINES.some((l) => l.includes('[db] review SKIPPED') && l.includes('every gate is ledgered PASSED')))
      report('G8A_ledger_line_says_frozen', LINES.some((l) => l.includes('review ledger') && l.includes('PASSED (frozen')))
      report('G8A_repo_ready', !!result)
    } else if (SCENARIO === 'G8B') {
      // ADR 0021 — a gate that completed its first pass with findings still open resumes in
      // RE-VISIT mode, NOT as a second "first review". This is the regression the ledger exists
      // for: without the row, round 1 of the next invocation re-derives a whole new finding set.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [builtRow('db'), prRow('db', 7), gateFirstPassRow('db', 'review')] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: ['t1'], still_open: [] },
      }
      await runOnce(ARGS, canned)
      const p = PROMPTS['review:FM-12:db#1'] || ''
      report('G8B_reviewer_spawned', SPAWNED.includes('review:FM-12:db#1'))
      report('G8B_mode_is_revisit', p.includes('RE-VISIT (round 1)'))
      report('G8B_not_first_review', !p.includes('First review (round 1)'))
      report('G8B_told_first_pass_was_earlier_invocation', p.includes('EARLIER INVOCATION'))
      report('G8B_ledger_line_says_revisit_only', LINES.some((l) => l.includes('review ledger') && l.includes('re-visit only')))
    } else if (SCENARIO === 'G8C') {
      // No ledger at all => a genuine first pass, and the brief carries the three contracts the
      // ledger depends on: the gate tag, the resolve-what-you-own rule, and the checkpoint write.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
      }
      await runOnce(ARGS, canned)
      const p = PROMPTS['review:FM-12:db#1'] || ''
      report('G8C_mode_is_first_review', p.includes('First review (round 1)'))
      report('G8C_no_earlier_invocation_claim', !p.includes('EARLIER INVOCATION'))
      report('G8C_prompt_has_gate_tag_rule', p.includes('[gate:review]') && p.includes('THREAD OWNERSHIP'))
      report('G8C_prompt_has_resolve_rule', p.includes('THREAD RESOLUTION') && p.includes('pr-resolve-thread.sh'))
      report('G8C_prompt_has_ledger_checkpoint', p.includes('REVIEW-LEDGER CHECKPOINT') && p.includes('db-gate_review.json'))
      report('G8C_prompt_first_pass_is_only_pass', p.includes('across INVOCATIONS'))
    } else if (SCENARIO === 'G9A') {
      // THE APPROVAL TICK, and the already-approved short-circuit. db's PR predates this
      // invocation (a pr_open row) and the forge says it is already approved, so NO reviewer is
      // spawned for it — the tick a human (or an earlier run) left IS the settled review.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [builtRow('db'), prRow('db', 7)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'approval-probe:FM-12:db': { approved: 'yes', command: 'scripts/vcs/pr-view.sh 7 --approved' },
        'approve:FM-12:db': { posted: [{ repo: 'db', pr: 7, note: 'already approved — nothing to do' }], failed: [] },
      }
      await runOnce(ARGS, canned)
      report('G9A_probe_spawned', SPAWNED.includes('approval-probe:FM-12:db'))
      report('G9A_no_reviewer_spawned', !SPAWNED.some((l) => l.startsWith('review:FM-12:db')))
      report('G9A_skip_logged_from_forge', LINES.some((l) => l.includes('ALREADY APPROVED on the forge')))
      report('G9A_probe_writes_sourced_row', (PROMPTS['approval-probe:FM-12:db'] || '').includes('"source":"forge-approval"'))
      report('G9A_probe_is_read_then_ledger_only', (PROMPTS['approval-probe:FM-12:db'] || '').includes('no review, no code, no comments'))
    } else if (SCENARIO === 'G9B') {
      // "unknown" is NOT "yes". A forge that will not answer must leave the gates to run — a
      // review skipped on a fiction is the one outcome worse than a review run needlessly.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [builtRow('db'), prRow('db', 7)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'approval-probe:FM-12:db': { approved: 'unknown', note: 'approvals disabled on this instance' },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { posted: [{ repo: 'db', pr: 7 }], failed: [] },
      }
      await runOnce(ARGS, canned)
      report('G9B_reviewer_still_spawned', SPAWNED.includes('review:FM-12:db#1'))
      report('G9B_unknown_logged_as_unapproved', LINES.some((l) => l.includes('approval state UNKNOWN') && l.includes('never skipping')))
      report('G9B_tick_still_posted', SPAWNED.includes('approve:FM-12:db'))
    } else if (SCENARIO === 'G9C') {
      // The tick is ORCHESTRATOR-owned and lands per gate-that-was-cleared: code repos at the end
      // of Review, the test-suite repo after ITS gate passes (it has no reviewer at all). And the
      // brief must carry the VCS_REPO rule — PR numbers collide across repos here.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e' }], test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'open-pr:FM-12:e2e': { pr_url: 'https://y/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { posted: [{ repo: 'db', pr: 7 }], failed: [] },
        'test-suite:FM-12:e2e': { passed: true, failures: [], receipt: { command: 'scripts/dev.sh test a', exit_code: 0, summary_line: '3 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'run r1 stamp matches' },
        'approve:FM-12:e2e': { posted: [{ repo: 'e2e', pr: 7 }], failed: [] },
        'notify:FM-12': { permalink: 'https://slack/x' },
        'summary:FM-12': { path: 'x.md' },
      }
      await runOnce(ARGS, canned)
      const code = PROMPTS['approve:FM-12:db'] || ''
      report('G9C_code_repo_ticked', SPAWNED.includes('approve:FM-12:db'))
      report('G9C_suite_repo_ticked_separately', SPAWNED.includes('approve:FM-12:e2e'))
      report('G9C_tick_before_status_move', SPAWNED.indexOf('approve:FM-12:db') < SPAWNED.indexOf('status:FM-12:ready_to_test'))
      report('G9C_brief_forces_vcs_repo', code.includes('VCS_REPO=') && code.includes('COLLIDE across repos'))
      report('G9C_brief_forbids_merge', code.includes('Do NOT merge anything'))
      report('G9C_brief_treats_idempotent_as_success', code.includes('already approved') && code.includes('is a SUCCESS'))
      report('G9C_audit_reads_the_marker', (PROMPTS['audit:FM-12:e2e'] || '').includes('find-ticket-comment.sh') && (PROMPTS['audit:FM-12:e2e'] || '').includes('[test-report · e2e]'))
      report('G9C_report_step_upserts', (PROMPTS['test-suite:FM-12:e2e'] || '').includes('upsert-ticket-comment.sh') && (PROMPTS['test-suite:FM-12:e2e'] || '').includes('never `add-ticket-comment.sh`'))
    } else if (SCENARIO === 'G9D') {
      // TICKET-WIDE HOLD. svc never reaches 'ready', so NOTHING is ticked — not even on db,
      // which came back clean. The repos are ship-order-coupled; approving the clean one reads
      // as "mergeable on its own", and the absence of a tick IS the changes-requested signal.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 'partial', status: 'partial', remaining: 'not done' },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'summary:FM-12': { path: 'x.md' },
      }
      await runOnce(ARGS, canned)
      report('G9D_no_tick_anywhere', !SPAWNED.some((l) => l.startsWith('approve:FM-12')))
      report('G9D_clean_repo_not_ticked_alone', !SPAWNED.includes('approve:FM-12:db'))
    } else if (SCENARIO === 'G10') {
      // ADR 0024, the accepted gap — `svc` declares NEITHER guard nor perf, so a QA-attributed fix
      // there gets no agent check at all: the suite re-run is the only bar, exactly as before. The
      // loop must not invent a check a repo never had.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('svc', 2), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'svc' }, { repo: 'e2e', depends_on: ['svc'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['svc', 'e2e']),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 failed' }, triage: [{ case: 'TC001', kind: 'app', repo: 'svc', evidence: 'expected 200 got 500' }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'gate-fix:FM-12:svc#1.1': { work_branch: 'feature/FM-12', summary: 'fixed', status: 'complete', fixed: ['svc/src/x.rs'] },
        'test-suite:FM-12:e2e#r1': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '5 passed' } },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      report('G10_fix_spawned', SPAWNED.includes('gate-fix:FM-12:svc#1.1'))
      report('G10_no_quality_check_agent_for_an_undeclared_gate', !SPAWNED.some((l) => l.startsWith('gate-guard:') || l.startsWith('gate-perf:') || l.startsWith('gate-review:')))
      report('G10_fix_brief_claims_no_check', !(PROMPTS['gate-fix:FM-12:svc#1.1'] || '').includes('YOUR FIX IS CHECKED'))
      report('G10_straight_to_the_suite_rerun', SPAWNED.includes('test-suite:FM-12:e2e#r1'))
      report('G10_run_proceeds_past_gate', !!result && result.status !== 'test-suite-failed' && result.status !== 'test-suite-unverified')
    } else if (SCENARIO === 'G12') {
      // ADR 0024 — a scoped check that could NOT run is never a pass. It sends the fix back like
      // any rejection, and an exhausted bound halts: the loop does not fail open on a silent gate.
      const unavailable = { passed: false, gate_unavailable: true, unavailable_reason: 'the profiler could not run in this run-context' }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 failed' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'expected 200 got 500' }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'gate-fix:FM-12:app#1.1': { work_branch: 'feature/FM-12', summary: 'attempt 1', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.1': { passed: true, conclusion: 'clean' },
        'gate-perf:FM-12:app#1.1': unavailable,
        'gate-fix:FM-12:app#1.2': { work_branch: 'feature/FM-12', summary: 'attempt 2', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.2': { passed: true, conclusion: 'clean' },
        'gate-perf:FM-12:app#1.2': unavailable,
      }
      const result = await runOnce(ARGS, canned)
      report('G12_unavailable_check_is_not_a_pass', SPAWNED.includes('gate-fix:FM-12:app#1.2'))
      report('G12_retry_brief_says_it_could_not_run', (PROMPTS['gate-fix:FM-12:app#1.2'] || '').includes('could not run'))
      report('G12_halts_rather_than_failing_open', !!result && result.status === 'test-suite-failed' && !SPAWNED.includes('test-suite:FM-12:e2e#r1'))
    } else if (SCENARIO === 'G11_FP' || SCENARIO === 'G11') {
      // THE AUDITED SHAPE, in one run (defensive regression test — no new mechanism). Four repos,
      // TWO bases in play (--feature-base-repos scopes the override), a RESUMED invocation with
      // MIXED run state: db + app fully resumed-ready, svc mid-review (its gate did its first pass
      // and left findings open), e2e built + PR open with its suite gate still pending. In the SAME
      // run: nothing already proven is re-spawned, the in-flight repo's review→fix loop actually
      // fires, and a finding whose root fix lives in another repo escalates and is re-gated there.
      // G11_FP is the fingerprint probe: same scope, no rows, plan-approval OFF so it stops right
      // after Kickoff having logged the fp the assertion run needs for its 'planned' rows.
      const scope = { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
        repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }, { repo: 'app', depends_on: ['svc'] }, { repo: 'e2e', depends_on: ['db', 'svc', 'app'] }],
        test_suite: { needed: true }, tracker_reachable: true }
      const kickoffs = {
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'release/1.4'),
        'kickoff:FM-12:app': REPO_PLAN('app', 'release/1.4'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
      }
      if (SCENARIO === 'G11_FP') {
        await runOnce(ARGS, {
          ...BASE,
          'resolve-runtime-config': { language: 'en', plan_to_html: false, auto_approve: false, artifacts_enabled: false },
          'run-state:FM-12': { rows: [] },
          'scope:FM-12': scope,
          'plan-guard:FM-12': planGuardOk(['db', 'svc', 'app', 'e2e']),
          ...kickoffs,
        })
        const fpLine = LINES.find((l) => /fp=([0-9a-f]+)/.test(l))
        const fp = fpLine ? fpLine.match(/fp=([0-9a-f]+)/)[1] : null
        report('G11_FP_fingerprint_logged', !!fp)
        if (fp) console.log(`FP=${fp}`)
      } else {
        const planned = (repo) => runStateRow(repo, 'planned', { ticket_fp: FP, plan_path: `/tmp/ws/${repo}/plan.md`, plan_bytes: 4096, title: 'T', acceptance: ['A1'] })
        const canned = {
          ...BASE,
          'run-state:FM-12': { rows: [
            planned('db'), ...readyRows('db', 1),
            planned('svc'), builtRow('svc'), prRow('svc', 2), gateFirstPassRow('svc', 'review'),
            planned('app'), ...readyRows('app', 3),
            planned('e2e'), builtRow('e2e'), prRow('e2e', 4),
          ] },
          'scope:FM-12': scope,
          'plan-guard:FM-12': planGuardOk(['db', 'svc', 'app', 'e2e']),
          ...kickoffs,
          'approval-probe:FM-12:db': { approved: 'no' },
          'approval-probe:FM-12:svc': { approved: 'no' },
          'approval-probe:FM-12:app': { approved: 'no' },
          // svc's gate re-visits its own open finding, whose ROOT fix lives in app.
          'review:FM-12:svc#1': { approved: false, tests_green: true, tests_receipt: 'ok', comments: [{ file_line: 'svc/src/a.rs:10', issue: 'the hot path needs an index this repo cannot add', severity: 'blocking' }] },
          'pr-fix:FM-12:svc#1': { work_branch: 'feature/FM-12', summary: 'proved the fix belongs upstream', status: 'complete', commits: 1, fixed: ['svc/src/a.rs'],
            upstream_fix_needed: [{ repo: 'app', finding: 'add the composite index the hot path reads', evidence: 'grepped the app migrations: no such index exists there, and svc vendors it read-only' }] },
          'xrepo-fix:FM-12:app#1': { work_branch: 'feature/FM-12', summary: 'index added', status: 'complete', commits: 1, fixed: ['app/migrations/x.sql'] },
          'xrepo-regate:FM-12:app#1': { approved: true, tests_green: true, tests_receipt: 'ok' },
          'review:FM-12:svc#2': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: ['t1'], still_open: [] },
          'approve:FM-12:db+svc+app': { posted: [{ repo: 'db' }, { repo: 'svc' }, { repo: 'app' }], failed: [] },
          'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'scripts/dev.sh test e2e', exit_code: 0, summary_line: '9 passed' } },
          'audit:FM-12:e2e': { posted: true, detail: 'run r1 stamp matches' },
          'approve:FM-12:e2e': { posted: [{ repo: 'e2e' }], failed: [] },
          'notify:FM-12': { sent: true },
        }
        const result = await runOnce(ARGS, canned)
        report('G11_no_kickoff_respawned', !SPAWNED.some((l) => l.startsWith('kickoff:')))
        report('G11_no_build_respawned', !SPAWNED.some((l) => l.startsWith('build:')))
        report('G11_no_open_pr_respawned', !SPAWNED.some((l) => l.startsWith('open-pr:')))
        report('G11_two_bases_resolved_in_one_run', LINES.some((l) => l.includes('svc@feature/FM-12→release/1.4')) && LINES.some((l) => l.includes('db@feature/FM-12→develop')))
        report('G11_in_flight_repo_resumes_as_revisit', (PROMPTS['review:FM-12:svc#1'] || '').includes('RE-VISIT (round 1)'))
        report('G11_review_loop_actually_runs_a_fix_pass', SPAWNED.includes('pr-fix:FM-12:svc#1'))
        report('G11_cross_repo_finding_escalates_and_is_re_gated', SPAWNED.includes('xrepo-fix:FM-12:app#1') && SPAWNED.includes('xrepo-regate:FM-12:app#1'))
        report('G11_loop_converges_on_the_next_round', SPAWNED.includes('review:FM-12:svc#2'))
        report('G11_pending_suite_gate_ran', SPAWNED.includes('test-suite:FM-12:e2e'))
        report('G11_reaches_the_merge_gate', !!result && result.status === 'merge-skipped', `got=${result && result.status}`)
      }
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
  local scenario="$1"; shift
  HARNESS="$HARNESS" SCENARIO="$scenario" ARGS="${ARGS:-FM-12 --approve-plan}" "$@" node "$DRIVER" 2>&1
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

echo "── G1 — upstream-degrade (C2), chain propagation"
out="$(run_scenario G1)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G2a — blocked-on: repair path (C3)"
out="$(run_scenario G2A)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G2b — blocked-on: hard-halt classification (C3, logic-level — see driver comment)"
out="$(run_scenario G2B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G3 — multi-suite fan-out (C5), one suite red fails the run"
out="$(run_scenario G3)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G3 (both green) — reaches the merge gate"
out="$(run_scenario G3_GREEN)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G4 — repair loop (C4 + ADR 0024): app red fixed, scoped guard+perf check, no code reviewer"
out="$(run_scenario G4)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G4 variant — a rejected scoped check retries the fix, then halts on its own bound"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G4_CHECK_REJECTED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G4 variant — max_fix_rounds exhausted"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G4_ROUNDS_EXHAUSTED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G4 variant — pre_existing_on_base: true skips the fix"
out="$(run_scenario G4_PRE_EXISTING)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G5 — budget stop (C9)"
out="$(FIXTURE_TOKEN_BUDGET=1000000 run_scenario G5)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G6a — notify (complete ending: merge-skipped)"
out="$(FIXTURE_NOTIFY_DM=U012345 run_scenario G6A)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G6b — DM (incomplete ending: test-suite-failed)"
out="$(FIXTURE_NOTIFY_DM=U012345 run_scenario G6B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G6c — dm_on_incomplete left at the placeholder: neither fires"
out="$(FIXTURE_NOTIFY_DM=U000000000000 run_scenario G6C)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G7 — gate-only build (C1)"
out="$(run_scenario G7)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8a — review ledger (ADR 0021): a passed gate is frozen, loop skipped with no 'reviewed' row"
out="$(run_scenario G8A)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8b — review ledger: first pass on record resumes as RE-VISIT, not a second first review"
out="$(run_scenario G8B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8c — no ledger: genuine first pass, brief carries tag + resolve + checkpoint contracts"
out="$(run_scenario G8C)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G9a — forge approval freezes the whole review (already-approved ⇒ no re-entry)"
out="$(run_scenario G9A)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G9b — approval 'unknown' is NOT 'no': the gates still run"
out="$(run_scenario G9B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G9c — the tick is orchestrator-owned: code repos at Review, suite repos at their own gate"
out="$(run_scenario G9C)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G9d — ticket-wide hold: one unready repo ⇒ no tick anywhere, not even on the clean one"
out="$(run_scenario G9D)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G10 — a repo declaring neither guard nor perf gets NO scoped check (ADR 0024's accepted gap)"
out="$(run_scenario G10)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G12 — a scoped check that could not run is not a pass (never fail open)"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G12)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

# G11 — the audited shape, in ONE run: 4 repos, 2 bases, mixed resume state, a live review→fix
# loop and a cross-repo escalation. The probe run first, to learn the ticket fingerprint its
# 'planned' rows must carry (same two-step as dev-cycle-kickoff-selftest.sh).
echo "── G11 probe — scrape the ticket fingerprint for the resumed run"
G11_ARGS="FM-12 --feature-base release/1.4 --feature-base-repos app,svc"
outFp="$(ARGS="$G11_ARGS" run_scenario G11_FP)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outFp" | sed 's/^/      /'; ingest "$outFp"
G11_FP_VALUE="$(grep -o 'FP=[0-9a-f]\+' <<<"$outFp" | head -1 | cut -d= -f2)"
if [[ -n "$G11_FP_VALUE" ]]; then pass "G11_fingerprint_scraped (fp=$G11_FP_VALUE)"; else fail "G11_fingerprint_scraped — could not scrape fp= from the probe run"; fi

echo "── G11 — resumed multi-repo run: nothing re-spawned, the in-flight loop fires, escalation re-gated"
out="$(ARGS="$G11_ARGS" FP="$G11_FP_VALUE" run_scenario G11)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
