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
WORKFLOW="${WORKFLOW:-$DIR/.claude/workflows/src/dev-cycle.js}"
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
const TEST_SUITE = { maxFixRounds: Number(process.env.FIXTURE_TS_MAX_FIX_ROUNDS || 2), maxSuiteRepairAttempts: Number(process.env.FIXTURE_TS_MAX_REPAIR || 3) }
// docs/adr/0027 — per-condition budgets for the review loop. Deliberately 1 here so a scenario can
// exhaust one in a single round instead of fourteen; real defaults live in workspace.config.yaml.
// (No apostrophes in this block: CONFIG_FIXTURE is a single-quoted shell string.)
const REVIEW = { maxRounds: Number(process.env.FIXTURE_RV_MAX_ROUNDS || 14), maxRegressionFixes: Number(process.env.FIXTURE_RV_MAX_REGRESSION || 1), maxStallReattempts: Number(process.env.FIXTURE_RV_MAX_STALL || 1), maxEscalationAttempts: Number(process.env.FIXTURE_RV_MAX_ESCALATION || 1) }
const BUILD = { maxContinuationPasses: Number(process.env.FIXTURE_BUILD_MAX_CONT || 2) }
const DEV_CYCLE = { tokenBudget: Number(process.env.FIXTURE_TOKEN_BUDGET || 0) }
const STATUS = { in_progress: "In progress", ready_to_test: "Ready to test", testing: "Testing", done: "Done" }
const REPOS = {
  db:  { path: "db",  kind: "backend", base: { feature: "develop", fix: "main" }, plan: "development-planner", build: "developer", review: "code-reviewer", guard: false, perf: false, green: "db green", knownFalseReds: "the suite shares one test database, so an unrelated test can fail on ordering" },
  svc: { path: "svc", kind: "backend", base: { feature: "develop", fix: "main" }, plan: "development-planner", build: "developer", review: "code-reviewer", guard: false, perf: false, green: "svc green" },
  app: { path: "app", kind: "frontend", base: { feature: "develop", fix: "main" }, plan: "development-planner", build: "developer", review: "code-reviewer", guard: true, perf: true, green: "app green", guardianFocus: "secrets, data-protection" },
  e2e: { path: "e2e", kind: "test-suite", base: { feature: "main", fix: "main" }, plan: "qa-planner", build: "qa-runner", review: null, guard: false, perf: false, green: "e2e green", testSuite: true },
  api: { path: "api", kind: "test-suite", base: { feature: "main", fix: "main" }, plan: "qa-planner", build: "qa-runner", review: null, guard: false, perf: false, green: "api green", testSuite: true },
  load: { path: "load", kind: "test-suite", base: { feature: "main", fix: "main" }, plan: "qa-planner", build: "qa-runner", review: null, guard: false, perf: false, green: "load green", testSuite: true, suiteKind: "load" },
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
// ADR-0027 §Across invocations. Items with status 'done' are CARRIED; the same row rewritten
// 'in-progress' with an empty list is how a clean run clears it (a workflow cannot delete a file).
const blockedRow = (repo, items) => ({ ...runStateRow(repo, 'blocked'), blocking: items })
const blockedClearedRow = (repo) => ({ ...runStateRow(repo, 'blocked'), status: 'in-progress', blocking: [] })

async function runOnce(argsStr, canned, opts = {}) {
  const spendJumpAfterPhase = opts.spendJumpAfterPhase || null
  const spendValue = opts.spendValue || 999999999
  const budget = { spent: () => (spendJumpAfterPhase && PHASES.includes(spendJumpAfterPhase)) ? spendValue : 0 }
  const phase = (name) => { PHASES.push(name) }
  const log = (s) => LINES.push(String(s))
  const parallel = (fns) => Promise.all(fns.map((f) => f()))
  // A label listed in opts.throwOn raises instead of answering — the one thing a canned table cannot
  // express, and the only way to exercise what the workflow does when an agent returns nothing at all.
  const throwOn = new Set(opts.throwOn || [])
  const agent = async (prompt, opts2) => {
    const label = opts2 && opts2.label
    if (label) { SPAWNED.push(label); PROMPTS[label] = prompt }
    if (label && throwOn.has(label)) throw new Error(opts.throwMessage || 'selftest: forced non-convergence')
    // The target-branch gate (docs/adr/0025) runs on EVERY repo that opens or resumes a PR/MR, so
    // stubbing it per scenario would mean adding a row to twenty canned tables to say "yes, the
    // MR points where it should". Default it to agreement, derived from the base the prompt itself
    // states — the same field a real agent reads off the forge — and let a scenario override the
    // label to exercise a mismatch. Absent this, every scenario halts on an unstubbed label and
    // the suite tests nothing but the gate.
    if (label && label.startsWith('target-gate:') && !(label in canned)) {
      const num = (prompt.match(/PR\/MR (\d+), read what it actually targets/) || [])[1] || 1
      const base = (prompt.match(/IS `([^`]+)`\. It is a fact of the run/) || [])[1] || 'develop'
      const repo = label.split(':').pop()
      return { repo, target_branch: base, matches: true, retargeted: false, detail: null,
               open_prs: [{ number: Number(num), target_branch: base, source_branch: 'feature/FM-12', url: `https://x/${num}` }] }
    }
    // The `Human:`-directive probe fires on EVERY repo that was about to skip its review, so
    // stubbing it per scenario would mean adding a row to a dozen canned tables to say "no, nobody
    // commented". Default it to the healthy answer — no directives, not blind — and let a scenario
    // override the label to exercise one. Same reasoning as the target-gate default above; without
    // it every resume scenario would be testing this probe instead of what it is about.
    if (label && (label.startsWith('human-probe:') || label.startsWith('human-verify:')) && !(label in canned)) {
      return { directives: [], blind: false, command: 'scripts/vcs/pr-threads.sh' }
    }
    // The branch-base reconcile fires on EVERY repo that is about to build, for the same reason the
    // two probes above fire on every repo that is about to review — so it gets the same treatment.
    // Default it to the healthy answer: the branch stands where the run says it does and nothing was
    // touched. A scenario that is ABOUT the base overrides the label. Without this default every
    // build scenario would be testing this probe instead of what it is about.
    if (label && label.startsWith('base-reconcile:') && !(label in canned)) {
      const repo = label.split(':').pop()
      return { repo, branch_exists: true, state: 'ok', ticket_commits: 1, foreign_commits: 0,
               commits: [{ sha: 'sha-head', subject: 'feat(FM-12): a slice', ticket: true }],
               head_sha: 'sha-head', parked_at: null, backup_ref: null, detail: 'branch stands on the run base' }
    }
    // The known-false-red screen fires on every FAILING round in a repo that declares any — which is
    // 'db' in this fixture — so it gets the same default treatment as the three probes above: the
    // healthy answer is "nothing this repo declares covers that failure", which is the outcome that
    // changes nothing. A scenario that is ABOUT the screen overrides the label.
    if (label && label.startsWith('false-red-screen:') && !(label in canned)) {
      const repo = label.split(':').pop().split('#')[0]   // the call site's stage rides the label as `#review`
      return { repo, state: 'no-match', failing: [], matched: null, base_command: null, base_exit_code: null,
               sole_obstacle: false, detail: 'nothing declared covers this failure' }
    }
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
    } else if (SCENARIO === 'G1B') {
      // C2, the half that degrading 'built'+'reviewed' alone did NOT close: svc carries a PASSED
      // review ledger as well. The skip at the top of reviewRepo() is an OR, so with the gate_*
      // rows left frozen svc re-BUILT against db's new head and then logged "review SKIPPED —
      // every gate is ledgered PASSED" over the re-pin diff nobody read. Assert the reviewer
      // actually runs, and that it runs as a RE-VISIT (ADR 0021: the row keeps first_pass:true,
      // so this is never a second first review).
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [
          builtRow('db', 'sha-db-OLD'), { ...runStateRow('db', 'built', { degraded: true }) },
          builtRow('svc'), runStateRow('svc', 'reviewed', { work_branch: 'feature/FM-12', head_sha: 'sha-svc' }),
          gatePassedRow('svc', 'review'), prRow('svc', 9),
        ] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }],
          test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'rebuilt', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/8', pr_number: 8 },
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 're-pinned db', status: 'complete', fixed: ['svc/vendor/schema.sql'] },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'review:FM-12:svc#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
      }
      await runOnce(ARGS, canned)
      report('G1B_review_not_skipped', !LINES.some((l) => l.includes('[svc] review SKIPPED')))
      report('G1B_gate_ledger_not_read_as_passed', !LINES.some((l) => l.includes('every gate is ledgered PASSED')))
      report('G1B_reviewer_spawned', SPAWNED.includes('review:FM-12:svc#1'))
      report('G1B_runs_as_revisit_not_first_pass', LINES.some((l) => l.includes('[svc] review ledger') && l.includes('re-visit only')))
      // pr_open is deliberately NOT degraded: same branch, same base, the PR/MR is still open, so
      // a second open-pr for svc would be a duplicate MR.
      report('G1B_no_second_pr_opened', !SPAWNED.includes('open-pr:FM-12:svc#1'))
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
      // ADR 0024 + ADR 0028 — a rejected scoped check retries the SAME red's fix inside this round.
      // An exhausted attempt bound no longer HALTS the suite: it RECORDS, the round's re-run still
      // happens, and the record is what keeps the un-cleared diff off the merge train even when
      // that re-run comes back GREEN. FIXTURE_TS_MAX_FIX_ROUNDS=2 ⇒ 2 attempts.
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
        // The fix DID make the symptom go green. Under the old halt this line was unreachable.
        'test-suite:FM-12:e2e#r1': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '4 passed' } },
      }
      const result = await runOnce(ARGS, canned)
      const bk = (result && result.blockingByRepo) || []
      const items = bk.flatMap((b) => b.items)
      report('G4b_rejected_check_retries_the_same_red_fix', SPAWNED.includes('gate-fix:FM-12:app#1.2'))
      report('G4b_retry_brief_carries_what_was_rejected', (PROMPTS['gate-fix:FM-12:app#1.2'] || '').includes('PRIOR ATTEMPT REJECTED') && (PROMPTS['gate-fix:FM-12:app#1.2'] || '').includes('N+1 introduced'))
      report('G4b_no_third_attempt', !SPAWNED.includes('gate-fix:FM-12:app#1.3'))
      // ADR 0028 — records, does not halt: the round's re-run still runs.
      report('G4b_records_and_reruns', SPAWNED.includes('test-suite:FM-12:e2e#r1'))
      report('G4b_records_the_unchecked_fix', items.some((i) => i.kind === 'gate-fix-unchecked' && String(i.detail).includes('TC001')), `got=${JSON.stringify(items.map((i) => i.kind))}`)
      report('G4b_names_the_human_action', items.some((i) => i.kind === 'gate-fix-unchecked' && String(i.human_action || '').includes('gate:')))
      // THE FAIL-OPEN GUARD. Green re-run + a recorded item ⇒ still not a pass, still no merge.
      report('G4b_green_rerun_is_not_a_pass', !!result && result.status === 'test-suite-unresolved', `got=${result && result.status}`)
      report('G4b_test_suite_reported_not_passed', !!result && result.testSuite && result.testSuite.passed === false)
      report('G4b_why_says_green_but_blocked', String((result || {}).why || '').includes('green, but'))
      report('G4b_never_reaches_merge', !PHASES.includes('Merge'))
      report('G4b_banner_is_loud', LINES.some((l) => l.includes('BLOCKING ITEM(S) the test-suite gate worked')))
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
      report('G4c_rounds_exhausted_fails_the_gate', !!result && result.status === 'test-suite-failed', `got=${result && result.status}`)
      report('G4c_third_round_never_spawned', !SPAWNED.includes('gate-fix:FM-12:app#3.1'))
      // ADR 0028 — the round budget running out is a RECORD carrying the reds it could not close,
      // not a bare `why` string. The status stays `failed` because the suite is genuinely red.
      report('G4c_records_the_standing_red', ((result && result.blockingByRepo) || []).flatMap((b) => b.items)
        .some((i) => i.kind === 'gate-red' && String(i.detail).includes('triage round') && String(i.detail).includes('TC001')))
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
      // ADR 0028 — a base that is already red gets its OWN record, so the reader is not left with a
      // generic "did not converge" for a finding that is not about this ticket at all.
      report('G4d_records_the_base_as_the_cause', ((result && result.blockingByRepo) || []).flatMap((b) => b.items)
        .some((i) => i.kind === 'reds-pre-existing-on-base' && String(i.human_action || '').includes('base branch')))
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
    } else if (SCENARIO === 'G13') {
      // Idempotent notify (this fix): same shape as G6A, but run-state already carries an
      // 'all'/'notified' row from an earlier invocation. A resumed run reaching the same
      // merge-skipped outcome must NOT re-send the review-request digest.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2), runStateRow('all', 'notified')] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: 'ok' } },
        'audit:FM-12:e2e': { posted: true, detail: 'x' },
      }
      const result = await runOnce(ARGS, canned)
      report('G13_status_merge_skipped', !!result && result.status === 'merge-skipped', `got=${result && result.status}`)
      report('G13_notify_not_spawned', !SPAWNED.includes('notify:FM-12'))
      report('G13_skip_logged', LINES.some((l) => l.includes('[notify]') && l.includes('SKIPPED') && l.includes('already')))
      report('G13_result_reports_sent', !!result && result.notify && result.notify.sent === true)
    } else if (SCENARIO === 'G14') {
      // Idempotent DM, keyed by run_status (this fix). A prior invocation already DM'd for
      // 'test-suite-failed' — same shape as G6B — so a resume hitting the SAME status again must
      // NOT re-send; run-state already carries an 'all'/'dm_sent' row for that exact status.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2), runStateRow('all', 'dm_sent', { run_status: 'test-suite-failed' })] },
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
      report('G14_status_test_suite_failed', !!result && result.status === 'test-suite-failed')
      report('G14_dm_not_respawned', !SPAWNED.includes('dm:FM-12:test-suite-failed'))
      report('G14_skip_logged', LINES.some((l) => l.includes('[notify]') && l.includes('DM SKIPPED')))
    } else if (SCENARIO === 'G15') {
      // A NEW ending status still DMs even though an OLDER status already has a dm_sent row —
      // proving the checkpoint is keyed by run_status, not "any DM ever sent for this ticket".
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2), runStateRow('all', 'dm_sent', { run_status: 'budget-stopped' })] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: 'red' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'dm:FM-12:test-suite-failed': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      report('G15_status_test_suite_failed', !!result && result.status === 'test-suite-failed')
      report('G15_dm_still_spawned_for_new_status', SPAWNED.includes('dm:FM-12:test-suite-failed'))
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
    } else if (SCENARIO === 'G8D' || SCENARIO === 'G8E' || SCENARIO === 'G8F' || SCENARIO === 'G8G') {
      // A `Human:` DIRECTIVE ON A SETTLED PR/MR (docs/agents/human-review.md). G8A above is this
      // exact shape minus the directive: every gate ledgered PASSED, so the review is skipped and
      // no reviewer is spawned. That skip's two proofs — a branch head that has not moved
      // (docs/adr/0018) and a ticket fingerprint of title + acceptance only (0018's addendum) —
      // are both blind to a comment, so a person's directive on the MR was returned as `ready`
      // with nobody having read it. Three cases, one per state the probe can be in:
      //   G8D  a directive exists   -> the skip is VETOED, the gates re-visit, the fix pass gets
      //                               the directive text FIRST, and the run ends ready once the
      //                               thread is resolved on the forge.
      //   G8E  the probe is BLIND   -> also not skipped. An unanswered question is not "none"
      //                               (the same rule as the approval probe's "unknown").
      //   G8F  never resolved       -> the reviewers pass, the thread does NOT, and the repo ends
      //                               `review-unresolved` carrying a `human-review` item rather
      //                               than reporting ready above a person's open instruction.
      //   G8G  a `reviewed` row and NO per-gate rows — the OTHER shape that reaches this skip (the
      //        merge phase writes `reviewed`, so a run that got that far completed the loop for
      //        every gate). Demoting only gates ledgered `done` would leave all three with no first
      //        pass on record and send them back to a FULL first review, re-deriving the closed
      //        finding set the ledger exists to protect. The veto must produce a re-visit here too.
      const directive ={ thread_id: 'th-9', location: 'lib/x.rs:42', body: 'Human: rename this to settle_batch and add the overflow guard' }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: SCENARIO === 'G8G'
          ? readyRows('db', 7)
          : [builtRow('db'), prRow('db', 7), gatePassedRow('db', 'review')] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'human-probe:FM-12:db': SCENARIO === 'G8E'
          ? { directives: [], blind: true, note: 'pr-threads.sh exited 1' }
          : { directives: [directive], blind: false },
        // The re-visit (not a second first review) and the fix pass the veto creates.
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'exit 0', comments: [], resolved_threads: [], still_open: [] },
        'pr-fix:FM-12:db#1': { work_branch: 'feature/FM-12', summary: 'applied the directive', status: 'complete', fixed: ['lib/x.rs'] },
        // G8F: the developer said done, the forge says the thread is still open. The forge wins.
        'human-verify:FM-12:db': SCENARIO === 'G8F'
          ? { directives: [directive], blind: false }
          : { directives: [], blind: false },
      }
      const result = await runOnce(ARGS, canned)
      const pre = SCENARIO
      report(`${pre}_skip_is_vetoed`, !LINES.some((l) => l.includes('[db] review SKIPPED')))
      report(`${pre}_reviewer_spawned`, SPAWNED.includes('review:FM-12:db#1'))
      // The veto must not become a re-review: the frozen gate is demoted to RE-VISIT, which is
      // the whole point of ADR-0021 surviving this change.
      report(`${pre}_mode_is_revisit`, (PROMPTS['review:FM-12:db#1'] || '').includes('RE-VISIT (round 1)'))
      report(`${pre}_gate_told_human_thread_blocks_it`, (PROMPTS['review:FM-12:db#1'] || '').includes('ONE THREAD YOU DO NOT OWN STILL BLOCKS YOU'))
      if (SCENARIO === 'G8G') {
        report('G8G_not_a_second_first_review', !(PROMPTS['review:FM-12:db#1'] || '').includes('First review (round 1)'))
        report('G8G_told_first_pass_was_earlier_invocation', (PROMPTS['review:FM-12:db#1'] || '').includes('EARLIER INVOCATION'))
      }
      if (SCENARIO === 'G8D' || SCENARIO === 'G8F' || SCENARIO === 'G8G') {
        const fp = PROMPTS['pr-fix:FM-12:db#1'] || ''
        report(`${pre}_logged_the_directive_count`, LINES.some((l) => l.includes('[db] 1 unresolved') && l.includes('is NOT skipped')))
        report(`${pre}_fix_pass_gets_the_directive_verbatim`, fp.includes('rename this to settle_batch and add the overflow guard'))
        report(`${pre}_fix_pass_gets_the_thread_id`, fp.includes('th-9'))
        report(`${pre}_directive_outranks_the_batch`, fp.includes('OUTRANKS every agent-reviewer comment'))
      }
      if (SCENARIO === 'G8E') {
        report('G8E_blindness_is_not_none', LINES.some((l) => l.includes('could NOT read the `Human:` threads')))
        report('G8E_no_directive_text_invented', !(PROMPTS['pr-fix:FM-12:db#1'] || '').includes('`Human:` DIRECTIVE —'))
      }
      if (SCENARIO === 'G8F') {
        report('G8F_repo_not_ready', (result?.repoResults?.db?.status) === 'review-unresolved')
        report('G8F_recorded_as_human_review', LINES.some((l) => l.includes('BLOCKING RECORDED (human-review)')))
        report('G8F_names_the_open_thread', LINES.some((l) => l.includes('BLOCKING RECORDED (human-review)') && l.includes('th-9')))
      } else {
        report(`${pre}_ends_ready_once_the_thread_is_resolved`, (result?.repoResults?.db?.status) === 'ready')
      }
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
      // ADR 0024 + ADR 0028 — a scoped check that could NOT run is never a pass. It sends the fix
      // back like any rejection; an exhausted bound RECORDS. The loop does not fail open on a
      // silent gate, and it does not stop working either.
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
        'test-suite:FM-12:e2e#r1': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 failed' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'still 500' }] },
      }
      const result = await runOnce(ARGS, canned)
      report('G12_unavailable_check_is_not_a_pass', SPAWNED.includes('gate-fix:FM-12:app#1.2'))
      report('G12_retry_brief_says_it_could_not_run', (PROMPTS['gate-fix:FM-12:app#1.2'] || '').includes('could not run'))
      report('G12_records_rather_than_failing_open', !!result && result.status === 'test-suite-failed'
        && ((result.blockingByRepo || []).flatMap((b) => b.items).some((i) => i.kind === 'gate-fix-unchecked')), `got=${result && result.status}`)
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
    } else if (SCENARIO === 'G16a' || SCENARIO === 'G16b' || SCENARIO === 'G16c' || SCENARIO === 'G16d') {
      // TARGET-BRANCH GATE (docs/adr/0025) — the postmortem's most serious miss. The pipeline was
      // thorough about the base right up to PR/MR creation and blind afterwards, so a four-repo
      // ticket reached its designed clean finish ("reviewed + validated", merge-skipped) with
      // every MR pointed at a branch nobody had asked for. A human caught it after the fact.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
      }
      const oneMr = (t) => [{ number: 7, target_branch: t, source_branch: 'feature/FM-12', url: 'https://x/7' }]
      if (SCENARIO === 'G16a') {
        // Mismatch the run could not repair (the base is not on the remote): halt, loudly, and
        // never tick an approval on it.
        canned['target-gate:FM-12:db'] = { repo: 'db', target_branch: 'main', matches: false, retargeted: false,
          detail: 'git ls-remote --exit-code --heads origin develop exited 2', open_prs: oneMr('main') }
      } else if (SCENARIO === 'G16b') {
        // TWO open MRs for one repo. `pr_open` proof is a head sha, not an MR identity, so a
        // resume could open another — and one measured repo really did carry two, targeting
        // different branches. Closing an MR stays a human call, so this halts rather than repairs.
        canned['target-gate:FM-12:db'] = { repo: 'db', target_branch: 'develop', matches: true, retargeted: false, detail: null,
          open_prs: [...oneMr('develop'), { number: 4, target_branch: 'main', source_branch: 'feature/FM-12', url: 'https://x/4' }] }
      } else if (SCENARIO === 'G16c') {
        // Repaired in place and re-read back: the run continues, and says so.
        canned['target-gate:FM-12:db'] = { repo: 'db', target_branch: 'develop', matches: true, retargeted: true, detail: null,
          open_prs: oneMr('develop') }
      } else {
        // NEVER FAIL OPEN: an assert that did not converge is not a pass. Same rule as the
        // test-suite audit — "nobody checked" was the previous state, and it is what shipped.
        canned['target-gate:FM-12:db'] = null
      }
      const result = await runOnce(ARGS, canned)
      const status = result && result.status
      if (SCENARIO === 'G16c') {
        report('G16c_repaired_run_continues', status !== 'target-branch-halt', `got=${status}`)
        report('G16c_repair_is_logged', LINES.some((l) => l.includes('target branch REPAIRED') && l.includes('approvals are unaffected')))
      } else if (SCENARIO === 'G16b') {
        // ADR-0027 splits this from the mismatch case: two open PR/MRs still leaves THIS run's own
        // MR with a computable diff, so the review is real work and the repo keeps going. What it
        // may never do is merge — closing the other MR is a human call.
        report('G16b_does_NOT_halt_the_repo', status !== 'target-branch-halt', `got=${status}`)
        report('G16b_but_cannot_reach_ready', status !== 'awaiting-human-ship' && status !== 'merge-skipped', `got=${status}`)
        report('G16b_records_it_as_blocking', LINES.some((l) => l.includes('BLOCKING RECORDED (multiple-open-prs)')))
        report('G16b_review_still_ran', SPAWNED.some((l) => l.startsWith('review:')))
        report('G16b_nothing_approved', !SPAWNED.some((l) => l.startsWith('approve:')))
      } else {
        const why = { G16a: 'a target that cannot be made right', G16d: 'a non-convergent assert' }[SCENARIO]
        report(`G16_${SCENARIO}_halts_on_${why.replace(/\W+/g, '_')}`, status === 'target-branch-halt', `got=${status}`)
        report(`G16_${SCENARIO}_nothing_approved`, !SPAWNED.some((l) => l.startsWith('approve:')))
        report(`G16_${SCENARIO}_banner_names_the_target_branch`, LINES.some((l) => l.includes('TARGET BRANCH')))
        // This one deliberately STAYS a halt: without the base ref on the remote there is no
        // `git diff base...head` to review, so sending reviewers at it buys misleading findings.
        report(`G16_${SCENARIO}_no_reviewer_was_paid`, !SPAWNED.some((l) => l.startsWith('review:') || l.startsWith('guard') || l.startsWith('perf')))
      }
      if (SCENARIO === 'G16a') {
        report('G16a_offers_the_retarget_command', LINES.some((l) => l.includes('retarget-pr.sh') && l.includes('--base develop')))
        report('G16a_before_any_reviewer_is_paid', !SPAWNED.some((l) => l.startsWith('review:') || l.startsWith('guard') || l.startsWith('perf')))
      }
      if (SCENARIO === 'G16b') report('G16b_offers_close_not_an_auto_close', LINES.some((l) => l.includes('close-pr.sh') && l.includes('human call')))
    } else if (SCENARIO === 'G18a' || SCENARIO === 'G18b') {
      // A ROUND BOUNDS ATTEMPTS, NOT HYPOTHESES. Measured: a wrong diagnosis ("a defect in the test
      // runner, fixable only by a repo-wide version bump") survived two rounds because round two
      // re-ran the same spec, got a byte-identical failure, and recorded it as confirmation —
      // "No new fix attempted". The real cause was one fixture line, derivable from screenshots
      // round one had already captured. So an UNCHANGED failure signature must change the brief.
      const red = (caseName) => ({
        passed: false,
        receipt: { command: 'scripts/dev.sh test x', exit_code: 1, summary_line: 'red' },
        triage: [{ case: caseName, kind: 'app', repo: 'db', spec: 'x', evidence: 'same TypeError' }],
        failures: [caseName],
      })
      // G18a: the signature REPEATS across rounds. G18b: it moves (a different case fails next).
      const second = SCENARIO === 'G18a' ? red('deposit.cy.js') : red('withdraw.cy.js')
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('db', 1)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'automated', status: 'complete', fixed: [] },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/5', pr_number: 5 },
        'test-suite:FM-12:e2e': red('deposit.cy.js'),
        'test-suite:FM-12:e2e#r1': second,
        'test-suite:FM-12:e2e#r2': second,
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'fix:FM-12:db': { work_branch: 'feature/FM-12', summary: 'fixed', status: 'complete', fixed: ['db/x'] },
        'dm:FM-12:test-suite-failed': { sent: true },
      }
      await runOnce(ARGS, canned)
      // The re-run brief is the artifact under test: find whichever re-run prompt was issued.
      const rerun = Object.keys(PROMPTS).filter((k) => k.startsWith('test-suite:FM-12:e2e#')).map((k) => PROMPTS[k]).join('\n')
      if (SCENARIO === 'G18a') {
        report('G18a_repeat_is_briefed_to_re-derive', rerun.includes('SAME FAILURE SIGNATURE AS THE PREVIOUS ROUND'))
        report('G18a_prior_conclusion_is_a_hypothesis', rerun.includes('HYPOTHESIS TO DISPROVE'))
        report('G18a_must_name_the_evidence_re-read', rerun.includes('WHICH prior evidence you re-read'))
        report('G18a_warns_the_error_may_be_a_mask', rerun.includes('is a mask, not the fault'))
        report('G18a_logged_for_the_operator', LINES.some((l) => l.includes('briefed to RE-DERIVE, not re-confirm')))
      } else {
        // A MOVING signature is progress: the fix landed and something else is red now. Demanding
        // a re-derivation there would be noise, so the directive must NOT fire.
        report('G18b_a_new_signature_is_not_briefed_to_re-derive', !rerun.includes('SAME FAILURE SIGNATURE'))
        report('G18b_and_nothing_is_logged_about_it', !LINES.some((l) => l.includes('briefed to RE-DERIVE')))
      }
      // Holds on every round, not just a repeat: the two inference errors that produced the wrong
      // diagnosis in the first place.
      const gate = PROMPTS['test-suite:FM-12:e2e'] || ''
      report(`${SCENARIO}_identical_control_means_shared_cause`, gate.includes('confirms a SHARED cause'))
      report(`${SCENARIO}_out_of_bounds_needs_a_second_read`, gate.includes('out_of_gate_bounds_second_read'))
    } else if (SCENARIO.startsWith('G19')) {
      // ADR-0027 — THE LOOP DOES NOT HALT ON A FINDING. Each of these used to end the repo on the
      // spot. The contract now: it becomes a must-fix in the developer's batch, the loop keeps
      // working, and if it cannot be closed it is RECORDED — which still keeps the repo out of
      // 'ready', because "does not halt" must never mean "passes without evidence".
      //
      // The fixture sets every per-condition budget to 1, so one round exhausts it and both halves
      // (the must-fix, then the recording) are observable inside a single scenario.
      // `comments` is what the loop counts as open findings for the code gate (rv.open), not `open`.
      const REVIEWERS_OPEN = { approved: false, tests_green: true, comments: [{ path: 'x.ts', line: 1, body: 'must-fix' }], conclusion: 'one finding', receipt: { command: 'scripts/dev.sh test', exit_code: 0, summary_line: 'ok' } }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'build:FM-12:app': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] },
        'open-pr:FM-12:app': { pr_url: 'https://x/7', pr_number: 7 },
      }
      // Every reviewer/fix label the loop may reach, answered so the loop runs its full course.
      for (let n = 1; n <= 4; n++) {
        canned[`review:FM-12:app#${n}`] = REVIEWERS_OPEN
        canned[`guard:FM-12:app#${n}`] = { passed: true, blocking: [] }
        canned[`perf:FM-12:app#${n}`] = { passed: true, blocking: [] }
        canned[`pr-fix:FM-12:app#${n}`] = { work_branch: 'feature/FM-12', summary: 'fixed', status: 'complete', fixed: ['x.ts'], commits: 1 }
      }
      // A suite that cannot run does not fix itself between rounds, so the gate keeps reporting
      // gate_unavailable — which is what lets the repair budget actually run out inside a scenario.
      const SUITE_DOWN = (why) => ({ approved: false, tests_green: false, gate_unavailable: true, unavailable_reason: why, comments: [], conclusion: 'suite did not run' })
      if (SCENARIO === 'G19a') {
        // SUITE COULD NOT RUN. Used to return review-tests-unverified immediately.
        for (let n = 1; n <= 4; n++) canned[`review:FM-12:app#${n}`] = SUITE_DOWN('docker daemon unreachable')
      } else if (SCENARIO === 'G19b') {
        // FIX-CAUSED REGRESSION on re-visit. Used to return review-regression-halt.
        canned['review:FM-12:app#2'] = { ...REVIEWERS_OPEN, fix_regression: true, regression_detail: 'the r1 fix broke checkout totals' }
      } else if (SCENARIO === 'G19c') {
        // STALL: same finding set, and the fix pass produces NO commit.
        for (let n = 1; n <= 4; n++) canned[`pr-fix:FM-12:app#${n}`] = { work_branch: 'feature/FM-12', summary: 'nothing to change', status: 'complete', fixed: [], commits: 0 }
      } else if (SCENARIO === 'G19d') {
        // A DECLARED "CANNOT" with evidence closes that condition's attempts early.
        for (let n = 1; n <= 4; n++) canned[`review:FM-12:app#${n}`] = SUITE_DOWN('no container runtime')
        canned['pr-fix:FM-12:app#1'] = { work_branch: 'feature/FM-12', summary: 'cannot', status: 'complete', fixed: [], commits: 0,
          cannot_fix: [{ kind: 'suite-unverified', why: 'class (d): no container runtime on this host', evidence: '`docker info` exit 1, repeated', tried: 'dev.sh clean, stack probe, port check' }] }
      } else if (SCENARIO === 'G19e') {
        // A "CANNOT" with NO evidence must be DROPPED, not honoured.
        for (let n = 1; n <= 4; n++) canned[`review:FM-12:app#${n}`] = SUITE_DOWN('no container runtime')
        canned['pr-fix:FM-12:app#1'] = { work_branch: 'feature/FM-12', summary: 'cannot', status: 'complete', fixed: [], commits: 0,
          cannot_fix: [{ kind: 'suite-unverified', why: 'infra', evidence: 'no', tried: 'x' }] }
      }
      const result = await runOnce(ARGS, canned)
      const st = result && result.status
      const fixPrompts = Object.keys(PROMPTS).filter((k) => k.startsWith('pr-fix:FM-12:app')).map((k) => PROMPTS[k]).join('\n')
      // NONE of these may end the repo on the halt status it used to return.
      for (const dead of ['review-tests-unverified', 'review-regression-halt', 'review-stalled']) {
        report(`${SCENARIO}_no_longer_returns_${dead.replace(/\W+/g, '_')}`, st !== dead, `got=${st}`)
      }
      report(`${SCENARIO}_repo_did_not_reach_ready`, st !== 'awaiting-human-ship' && st !== 'merge-skipped', `got=${st}`)
      report(`${SCENARIO}_nothing_approved`, !SPAWNED.some((l) => l.startsWith('approve:')))
      if (SCENARIO === 'G19a') {
        report('G19a_suite_failure_reaches_the_developer', fixPrompts.includes('THE SUITE DID NOT RUN'))
        report('G19a_brief_quotes_what_the_gate_got', fixPrompts.includes('docker daemon unreachable'))
        report('G19a_brief_carries_the_failure_classes', fixPrompts.includes('(a) THE HARNESS ITSELF') && fixPrompts.includes('(d) GENUINELY ABSENT'))
        report('G19a_brief_demands_a_receipt', fixPrompts.includes('YOU MUST END WITH A RECEIPT'))
        report('G19a_recorded_when_attempts_run_out', LINES.some((l) => l.includes('BLOCKING RECORDED (suite-unverified)')))
      }
      if (SCENARIO === 'G19b') {
        report('G19b_regression_handed_straight_back', fixPrompts.includes('YOUR OWN LAST FIX CAUSED THIS'))
        report('G19b_brief_carries_the_detail', fixPrompts.includes('broke checkout totals'))
        report('G19b_told_not_to_just_revert', fixPrompts.includes('undoing your fix to clear the regression'))
      }
      if (SCENARIO === 'G19c') {
        report('G19c_stall_escalates_instead_of_repeating', LINES.some((l) => l.includes('escalating the next attempt')))
        report('G19c_brief_says_do_something_different', fixPrompts.includes('Repeating it is not an option'))
        report('G19c_recorded_when_reattempts_run_out', LINES.some((l) => l.includes('BLOCKING RECORDED (stalled)')))
      }
      if (SCENARIO === 'G19d') {
        report('G19d_evidenced_cannot_is_accepted', LINES.some((l) => l.includes('BLOCKING RECORDED (suite-unverified)')))
        report('G19d_and_closes_the_attempts_early', !LINES.some((l) => l.includes('attempt 2/')))
      }
      if (SCENARIO === 'G19e') {
        report('G19e_unevidenced_cannot_is_DROPPED', LINES.some((l) => l.includes('was DROPPED')))
        report('G19e_and_attempts_continue', LINES.some((l) => l.includes('attempt 2/')))
      }
    } else if (SCENARIO === 'G20a' || SCENARIO === 'G20b') {
      // ADR 0028 — a `prereq` and an `automation` red used to get NO agent at all: only kind 'app'
      // was ever routed, so the round counter ticked, the suite re-ran byte-identically, and the
      // gate "did not converge" having never once been asked to fix what it found. Both route now:
      // prereq to a code repo (the first one, when the gate named none), automation to the SUITE
      // repo, because a wrong spec is the suite's own to fix.
      const prereq = SCENARIO === 'G20a'
      const owner = prereq ? 'app' : 'e2e'
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        // NOTE: no `repo` on the triage row — a prereq failure usually names none, which is exactly
        // the shape that used to fall through every filter.
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 error' },
          triage: [prereq
            ? { case: 'TC001', kind: 'prereq', evidence: 'nothing answered on :8080 for the whole run' }
            : { case: 'TC001', kind: 'automation', evidence: 'the selector moved; the assertion never saw the row' }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        [`gate-fix:FM-12:${owner}#1.1`]: { work_branch: 'feature/FM-12', summary: 'fixed', status: 'complete', fixed: ['x'] },
        [`gate-guard:FM-12:${owner}#1.1`]: { passed: true, conclusion: 'clean' },
        [`gate-perf:FM-12:${owner}#1.1`]: { passed: true, conclusion: 'clean' },
        'test-suite:FM-12:e2e#r1': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '4 passed' } },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      const p = PROMPTS[`gate-fix:FM-12:${owner}#1.1`] || ''
      report(`${SCENARIO}_red_is_routed_at_all`, SPAWNED.includes(`gate-fix:FM-12:${owner}#1.1`), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('gate-fix:')))}`)
      report(`${SCENARIO}_brief_matches_the_kind`, prereq
        ? p.includes('PRECONDITION failure') && p.includes('THE ONLY CLASS NOTHING CAN FIX')
        : p.includes("SUITE'S OWN") && p.includes('a spec bent to match whatever the app currently does'))
      report(`${SCENARIO}_brief_offers_the_evidenced_cannot`, p.includes('cannot_fix') && p.includes('without evidence and `tried` it is refused'))
      report(`${SCENARIO}_a_working_fix_still_passes_the_gate`, !!result && result.status !== 'test-suite-failed' && result.status !== 'test-suite-unresolved', `got=${result && result.status}`)
      report(`${SCENARIO}_nothing_recorded_when_the_fix_worked`, !((result && result.blockingByRepo) || []).length)
    } else if (SCENARIO === 'G21a' || SCENARIO === 'G21b') {
      // ADR 0028 — the sanctioned "cannot" for ONE red. Evidenced: that red's attempts end, it is
      // recorded, and the SIBLING red in the same round is still worked (the whole point — the old
      // early return threw the sibling away). Unevidenced: dropped, and attempt 2 happens.
      const evidenced = SCENARIO === 'G21a'
      const cf = evidenced
        ? [{ kind: 'gate-red', why: 'the device matrix has no such platform', evidence: 'scripts/dev.sh test e2e --platform=x → exit 64, "unknown platform"', tried: 'ruled out the harness and the stack: both green for the sibling case' }]
        : [{ kind: 'gate-red', why: 'infra', evidence: 'nope', tried: 'no' }]
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('svc', 2), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'svc' }, { repo: 'e2e', depends_on: ['app', 'svc'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'svc', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '2 failed' }, triage: [
          { case: 'TC001', kind: 'app', repo: 'app', evidence: 'expected 200 got 500' },
          { case: 'TC002', kind: 'app', repo: 'svc', evidence: 'expected 201 got 409' },
        ] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'gate-fix:FM-12:app#1.1': { work_branch: 'feature/FM-12', summary: 'cannot', status: 'blocked', fixed: [], cannot_fix: cf },
        // Only reached when the claim is DROPPED — an accepted one ends this red's attempts.
        'gate-fix:FM-12:app#1.2': { work_branch: 'feature/FM-12', summary: 'attempt 2', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.2': { passed: true, conclusion: 'clean' },
        'gate-perf:FM-12:app#1.2': { passed: true, conclusion: 'clean' },
        // The SIBLING red, which the old early return never got to.
        'gate-fix:FM-12:svc#1.1': { work_branch: 'feature/FM-12', summary: 'sibling fixed', status: 'complete', fixed: ['svc/src/y.rs'] },
        'test-suite:FM-12:e2e#r1': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '4 passed' } },
      }
      const result = await runOnce(ARGS, canned)
      const items = ((result && result.blockingByRepo) || []).flatMap((b) => b.items)
      report(`${SCENARIO}_sibling_red_is_still_worked`, SPAWNED.includes('gate-fix:FM-12:svc#1.1'))
      if (evidenced) {
        report('G21a_accepted_claim_ends_that_reds_attempts', !SPAWNED.includes('gate-fix:FM-12:app#1.2'))
        report('G21a_accepted_claim_is_recorded', items.some((i) => i.kind === 'gate-red' && String(i.detail).includes('unknown platform')), `got=${JSON.stringify(items.map((i) => i.kind))}`)
        report('G21a_green_rerun_still_not_a_pass', !!result && result.status === 'test-suite-unresolved', `got=${result && result.status}`)
      } else {
        report('G21b_unevidenced_claim_is_dropped', LINES.some((l) => l.includes('was DROPPED') && l.includes('gate-red')))
        report('G21b_attempts_continue', SPAWNED.includes('gate-fix:FM-12:app#1.2'))
        report('G21b_nothing_recorded_from_the_dropped_claim', !items.some((i) => i.kind === 'gate-red'))
      }
    } else if (SCENARIO === 'G22') {
      // ADR 0028 — a gate that returns no RECEIPT is telling us the suite would not run, and
      // re-briefing the qa-runner a third time does not make a stack listen. Every repair attempt
      // after the first sends a DEVELOPER at the stack first, on the same four-class ladder the
      // review loop got in ADR 0027. FIXTURE_TS_MAX_REPAIR=2 ⇒ one unblock pass, then a record.
      const noReceipt = { passed: true, conclusion: 'ran it', receipt: { command: '', exit_code: 0, summary_line: '' } }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': noReceipt,
        'test-suite:FM-12:e2e#rverify1': noReceipt,
        'test-suite:FM-12:e2e#rverify2': noReceipt,
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'audit:FM-12:e2e#verify1': { posted: true, detail: 'result posted' },
        'audit:FM-12:e2e#verify2': { posted: true, detail: 'result posted' },
        'gate-unblock:FM-12:app#verify2': { work_branch: 'feature/FM-12', summary: 'brought the stack up', status: 'complete', fixed: ['app/compose.yml'] },
      }
      const result = await runOnce(ARGS, canned)
      const up = PROMPTS['gate-unblock:FM-12:app#verify2'] || ''
      const items = ((result && result.blockingByRepo) || []).flatMap((b) => b.items)
      report('G22_developer_is_sent_at_an_unrunnable_gate', SPAWNED.includes('gate-unblock:FM-12:app#verify2'), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('gate-unblock:')))}`)
      report('G22_no_developer_on_the_first_attempt', !SPAWNED.includes('gate-unblock:FM-12:app#verify1'))
      report('G22_brief_carries_the_four_classes', up.includes('(a) THE HARNESS ITSELF') && up.includes('(d) GENUINELY ABSENT FROM THIS ENVIRONMENT'))
      report('G22_brief_demands_a_receipt', up.includes('YOU MUST END WITH A RECEIPT'))
      report('G22_brief_names_the_unmerged_candidate', up.includes('THE CANDIDATE IS UNMERGED') && up.includes('app@feature/FM-12'))
      report('G22_records_and_never_passes', !!result && result.status === 'test-suite-unverified', `got=${result && result.status}`)
      report('G22_record_says_unverified', items.some((i) => i.kind === 'gate-unverified' && String(i.detail).includes('receipt')), `got=${JSON.stringify(items.map((i) => i.kind))}`)
    } else if (SCENARIO === 'G23') {
      // ADR 0028 — a load suite that met its own thresholds but LOST to its base is recorded, not
      // halted, and the run must not log a passed baseline for it. The `cannot_fix` the brief has
      // always offered is now actually read: evidenced, it ends the load rounds.
      const green = { command: 'k6 run x.js', exit_code: 0, summary_line: 'checks 100%' }
      const regressed = { verdict: 'fail', base_sha: 'base1', candidate_sha: 'cand1', regressed: ['p95 +38%'], markdown: '| m | base | cand |' }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('svc', 1), ...readyRows('load', 2)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'svc' }, { repo: 'load', depends_on: ['svc'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['svc', 'load']),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:load': REPO_PLAN('load', 'main'),
        'test-suite:FM-12:load': { passed: true, receipt: green, loadtest: regressed },
        'audit:FM-12:load': { posted: true, detail: 'result posted' },
        'lt-attribute:FM-12:1': { attribution: 'attributable', reasoning: 'the new lookup runs per row', evidence: 'svc/src/q.rs:88', repo: 'svc' },
        'lt-fix:FM-12:1': { work_branch: 'feature/FM-12', summary: 'inherent', status: 'blocked', fixed: [],
          cannot_fix: [{ kind: 'loadtest-regression', why: 'the ticket requires a per-request authorization lookup that cannot be batched', evidence: 'p95 +38% with the lookup, +2% without it — svc/src/q.rs:88', tried: 'batched it per request, cached it per caller: both changed what a caller observes' }] },
      }
      const result = await runOnce(ARGS, canned)
      const items = ((result && result.blockingByRepo) || []).flatMap((b) => b.items)
      report('G23_attribution_runs_before_any_fix', SPAWNED.indexOf('lt-attribute:FM-12:1') >= 0 && SPAWNED.indexOf('lt-attribute:FM-12:1') < SPAWNED.indexOf('lt-fix:FM-12:1'))
      report('G23_fix_brief_carries_the_threshold_shape', (PROMPTS['lt-fix:FM-12:1'] || '').includes('the environment\'s own noise floor'))
      report('G23_fix_brief_forbids_the_escapes', (PROMPTS['lt-fix:FM-12:1'] || '').includes('do NOT relax a threshold'))
      report('G23_evidenced_cannot_ends_the_rounds', !SPAWNED.includes('lt-fix:FM-12:2'))
      // ONE row for one condition: the developer's evidenced claim carries the number and what was
      // ruled out, so the generic post-loop record must not add a second — a reader counting
      // blocking items would double-count it.
      report('G23_regression_is_recorded_once', items.filter((i) => i.kind === 'loadtest-regression').length === 1
        && String(items[0].detail).includes('p95 +38%') && String(items[0].detail).includes('cannot be batched'), `got=${JSON.stringify(items.map((i) => i.kind))}`)
      report('G23_green_suite_is_still_not_a_pass', !!result && result.status === 'test-suite-unresolved', `got=${result && result.status}`)
      // The verdict branches are an if/else-if chain now that 'fail' no longer returns. A regression
      // must land in NEITHER neighbour: not the ✅ line, not the loud "could not judge" one.
      report('G23_no_passed_baseline_logged', !LINES.some((l) => l.includes('no tracked metric degraded')))
      report('G23_not_reported_as_unavailable_either', !LINES.some((l) => l.includes('LOAD-TEST BASELINE UNAVAILABLE')))
      report('G23_never_reaches_merge', !PHASES.includes('Merge'))
      report('G23_gate_told_not_to_checkpoint_a_lost_baseline', (PROMPTS['test-suite:FM-12:load'] || '').includes('LOAD SUITE THAT MET ITS OWN THRESHOLDS BUT LOST TO ITS BASE IS NOT GREEN'))
    } else if (SCENARIO === 'G24') {
      // ADR 0028's ONE retraction. Round 1's fix for TC001 is rejected to exhaustion and recorded.
      // Round 2 fixes the same case and the SAME scoped check clears it — a fresher statement by
      // the same reviewer over a superset of the same diff — so the record is retracted and the run
      // is not blocked by a finding that no longer holds. Nothing else is retractable.
      const rejected = { passed: false, conclusion: 'still slower', blocking: [{ title: 'N+1 introduced', scope: 'app/src/x.ts:20', evidence: 'query in the loop' }] }
      const cleared = { passed: true, conclusion: 'clean' }
      const red = { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 failed' }, triage: [{ case: 'TC001', kind: 'app', repo: 'app', evidence: 'expected 200 got 500' }] }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': red,
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'gate-fix:FM-12:app#1.1': { work_branch: 'feature/FM-12', summary: 'try 1', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.1': cleared,
        'gate-perf:FM-12:app#1.1': rejected,
        'gate-fix:FM-12:app#1.2': { work_branch: 'feature/FM-12', summary: 'try 2', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#1.2': cleared,
        'gate-perf:FM-12:app#1.2': rejected,
        'test-suite:FM-12:e2e#r1': red,
        'gate-fix:FM-12:app#2.1': { work_branch: 'feature/FM-12', summary: 'try 3, properly', status: 'complete', fixed: ['app/src/x.ts'] },
        'gate-guard:FM-12:app#2.1': cleared,
        'gate-perf:FM-12:app#2.1': cleared,
        'test-suite:FM-12:e2e#r2': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '5 passed' } },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      report('G24_round1_recorded_the_unchecked_fix', LINES.some((l) => l.includes('BLOCKING RECORDED (gate-fix-unchecked)')))
      report('G24_round2_retracted_it', LINES.some((l) => l.includes('RETRACTED (gate-fix-unchecked · TC001)')))
      report('G24_run_is_not_blocked_by_a_finding_that_no_longer_holds', !((result && result.blockingByRepo) || []).length, `got=${JSON.stringify(((result && result.blockingByRepo) || []).flatMap((b) => b.items.map((i) => i.kind)))}`)
      report('G24_gate_passes', !!result && result.status !== 'test-suite-unresolved' && result.status !== 'test-suite-failed', `got=${result && result.status}`)
    } else if (SCENARIO === 'G25') {
      // ADR 0028 — an `app` red naming a repo this run does not carry is a finding about SCOPE. The
      // prereq fallback ("no repo named ⇒ the first code repo") must NOT apply to it: sending its
      // fix to an unrelated repo would be a confident wrong answer, which is worse than a record.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [...readyRows('app', 1), ...readyRows('e2e', 3)] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: false, receipt: { command: 'x', exit_code: 1, summary_line: '1 failed' },
          triage: [{ case: 'TC001', kind: 'app', repo: 'billing', evidence: 'the invoice total came back wrong' }] },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
      }
      const result = await runOnce(ARGS, canned)
      const items = ((result && result.blockingByRepo) || []).flatMap((b) => b.items)
      report('G25_no_fix_sent_to_an_unrelated_repo', !SPAWNED.some((l) => l.startsWith('gate-fix:')), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('gate-fix:')))}`)
      report('G25_records_the_scope_gap', items.some((i) => i.kind === 'gate-red-unowned' && String(i.detail).includes('billing')), `got=${JSON.stringify(items.map((i) => i.kind))}`)
      report('G25_never_a_pass', !!result && result.status === 'test-suite-failed', `got=${result && result.status}`)
      // A round that routed nothing must not re-run the gate: no branch moved, so the verdict would
      // be byte-identical. And it must not stack a generic "did not converge" row on top of the
      // specific reason — one condition, one row.
      report('G25_no_pointless_rerun', !SPAWNED.includes('test-suite:FM-12:e2e#r1') && LINES.some((l) => l.includes('routed no fix at all')))
      report('G25_records_exactly_once', items.length === 1, `got=${JSON.stringify(items.map((i) => i.kind))}`)
    } else if (SCENARIO === 'G26' || SCENARIO === 'G27') {
      // ADR-0027 §Across invocations — the cross-invocation fail-open. A repo that ended
      // `review-unresolved` has every gate ledgered PASSED (the gates DID pass; the blocking item
      // was not a gate finding), so the next invocation skipped review at the early `ready` return
      // and merged exactly what the previous run recorded as unclosable. G26: the item is carried,
      // so review runs and the item reaches the developer. G27: the same row rewritten CLEARED is
      // ignored, so a repo whose blocker was resolved still resumes for free.
      const carried = SCENARIO === 'G26'
      const item = { kind: 'cross-repo', detail: 'the root fix for the totals finding belongs in billing, which this ticket does not carry', human_action: 'widen FM-12 to billing, or waive the finding' }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [
          ...readyRows('app', 7),
          gatePassedRow('app', 'review'), gatePassedRow('app', 'guard'), gatePassedRow('app', 'perf'),
          carried ? blockedRow('app', [item]) : blockedClearedRow('app'),
        ] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'notify:FM-12': { sent: true },
      }
      // Reviewers pass on sight: the point is that the loop RUNS at all and the carried item lands
      // in the fix batch — not that a reviewer re-derives it (a re-visit may only raise a
      // fix-caused regression, so the reviewer was never going to be the one that re-finds it).
      for (let n = 1; n <= 3; n++) {
        canned[`review:FM-12:app#${n}`] = { approved: true, tests_green: true, comments: [], conclusion: 'clean', receipt: { command: 'x', exit_code: 0, summary_line: 'ok' } }
        canned[`guard:FM-12:app#${n}`] = { passed: true, blocking: [] }
        canned[`perf:FM-12:app#${n}`] = { passed: true, blocking: [] }
        canned[`pr-fix:FM-12:app#${n}`] = { work_branch: 'feature/FM-12', summary: 'the billing gap was closed by hand last week; verified', status: 'complete', fixed: ['app/src/x.ts'], commits: 1 }
      }
      const result = await runOnce(ARGS, canned)
      const skipped = LINES.some((l) => l.includes('review SKIPPED'))
      if (carried) {
        report('G26_review_is_not_skipped_over_a_carried_item', !skipped, `lines=${JSON.stringify(LINES.filter((l) => l.includes('SKIPPED')))}`)
        report('G26_carried_item_is_logged_loudly', LINES.some((l) => l.includes('blocking item(s) CARRIED from a previous invocation') && l.includes('cross-repo')))
        // The proof the freeze was lifted is that the reviewers RAN at all: with `gate_*: done`
        // rows and no carried item, every one of them would have been frozen. (No `guard` here —
        // this fixture sets QUALITY_GATE="none", so guard is never in the reviewer set at all.)
        report('G26_frozen_gates_are_re_opened', SPAWNED.includes('review:FM-12:app#1') && SPAWNED.includes('perf:FM-12:app#1'),
          `spawned=${JSON.stringify(SPAWNED.filter((l) => /^(review|guard|perf):/.test(l)))}`)
        report('G26_item_reaches_the_developer', (PROMPTS['pr-fix:FM-12:app#1'] || '').includes('CARRIED FROM AN EARLIER RUN')
          && (PROMPTS['pr-fix:FM-12:app#1'] || '').includes('belongs in billing'))
        report('G26_developer_told_to_check_it_still_stands', (PROMPTS['pr-fix:FM-12:app#1'] || '').includes('FIRST, CHECK WHETHER IT STILL STANDS'))
        // NOT permanently blocking: re-worked, and a run that closes it proceeds.
        report('G26_a_closed_item_lets_the_run_proceed', !!result && result.status === 'merge-skipped', `got=${result && result.status}`)
        report('G26_summary_is_told_to_clear_the_row', (PROMPTS['summary:FM-12'] || '').includes('app-blocked.json') && (PROMPTS['summary:FM-12'] || '').includes('"status":"in-progress"'))
      } else {
        report('G27_a_cleared_row_is_ignored', skipped)
        report('G27_no_carry_logged', !LINES.some((l) => l.includes('CARRIED from a previous invocation')))
        report('G27_no_fix_pass_invented', !SPAWNED.some((l) => l.startsWith('pr-fix:')))
        report('G27_resumes_for_free', !!result && result.status === 'merge-skipped', `got=${result && result.status}`)
      }
    } else if (SCENARIO === 'G28') {
      // The same veto on the suite side. The gate brief tells the agent not to write a `test_suite`
      // row while a blocking item stands — but an instruction is not a mechanism, so a row that got
      // written anyway must not let the gate be skipped.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [
          ...readyRows('app', 1), ...readyRows('e2e', 3),
          runStateRow('e2e', 'test_suite'),
          blockedRow('e2e', [{ kind: 'loadtest-regression', detail: 'p95 +38% vs base after 3 fix round(s)', human_action: 'decide whether FM-12 ships at this cost' }]),
        ] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '5 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'notify:FM-12': { sent: true },
      }
      const result = await runOnce(ARGS, canned)
      report('G28_gate_is_not_skipped_over_a_carried_item', SPAWNED.includes('test-suite:FM-12:e2e'), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('test-suite:')))}`)
      report('G28_not_reported_as_resumed', !LINES.some((l) => l.includes('SKIPPED — run state says this suite already passed')))
      report('G28_a_genuinely_green_rerun_proceeds', !!result && result.status === 'merge-skipped', `got=${result && result.status}`)
    } else if (SCENARIO === 'G29' || SCENARIO === 'G30') {
      // ADR-0029 — a repo short of `ready` used to end the run BEFORE the cross-repo gate, so a run
      // with a ready repo and one carrying a recorded blocking item never learned whether the change
      // set breaks the suite; that answer cost a whole extra invocation. G29: every unresolved repo
      // is `review-unresolved` (reviewed, fixed to budget — the final state this run can reach), so
      // the gate RUNS, advisory. G30: one repo has no build result at all, so the candidate is unfit
      // to measure and the run returns exactly as it always did.
      const advisory = SCENARIO === 'G29'
      const SUITE_DOWN = { approved: false, tests_green: false, gate_unavailable: true, unavailable_reason: 'docker daemon unreachable', comments: [], conclusion: 'suite did not run' }
      const PASSES = { approved: true, tests_green: true, comments: [], conclusion: 'clean', receipt: { command: 'x', exit_code: 0, summary_line: 'ok' } }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'svc' }, { repo: 'e2e', depends_on: ['app', 'svc'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'svc', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'build:FM-12:app': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] },
        // G30's unfit candidate: no structured handoff at all ⇒ `build-unresolved`.
        'build:FM-12:svc': advisory ? { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] } : null,
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'specs', status: 'complete', fixed: [] },
        'open-pr:FM-12:app': { pr_url: 'https://x/11', pr_number: 11 },
        'open-pr:FM-12:svc': { pr_url: 'https://x/12', pr_number: 12 },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/13', pr_number: 13 },
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '6 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
        'dm:FM-12:repo-unresolved': { sent: true },
      }
      // `app` records `suite-unverified` (FIXTURE_TS_MAX_REPAIR=1 ⇒ one must-fix, then the record)
      // and ends `review-unresolved`. `svc` passes on sight.
      for (let n = 1; n <= 4; n++) {
        canned[`review:FM-12:app#${n}`] = SUITE_DOWN
        canned[`perf:FM-12:app#${n}`] = { passed: true, blocking: [] }
        canned[`pr-fix:FM-12:app#${n}`] = { work_branch: 'feature/FM-12', summary: 'tried the stack', status: 'complete', fixed: ['app/x'], commits: 1 }
        canned[`review:FM-12:svc#${n}`] = PASSES
      }
      const result = await runOnce(ARGS, canned)
      const gp = PROMPTS['test-suite:FM-12:e2e'] || ''
      if (advisory) {
        report('G29_gate_runs_instead_of_deferring_the_answer', SPAWNED.includes('test-suite:FM-12:e2e'), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('test-suite:')))}`)
        report('G29_gate_is_told_it_is_advisory', gp.includes('ADVISORY RUN') && gp.includes('suite-unverified'))
        report('G29_gate_is_told_to_write_no_state_row', gp.includes('Write NO row, whatever your verdict'))
        report('G29_logged_for_the_operator', LINES.some((l) => l.includes('ADVISORY GATE')))
        // Authority: none. The tick is ticket-wide (ADR-0022), so it is all or nothing.
        report('G29_nothing_is_approved', !SPAWNED.some((l) => l.startsWith('approve:')), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('approve:')))}`)
        report('G29_ticket_is_not_advanced', !SPAWNED.includes('status:FM-12:ready_to_merge') && !SPAWNED.includes('status:FM-12:ready_to_test') && !SPAWNED.includes('status:FM-12:testing'))
        report('G29_never_reaches_merge', !PHASES.includes('Merge'))
        // The ending is about the repos, not the gate: a green advisory gate must not relabel the run.
        report('G29_ends_on_the_unresolved_repo', !!result && result.status === 'repo-unresolved', `got=${result && result.status}`)
        report('G29_records_that_the_gate_ran', String((result || {}).advisory_gate || '').includes('advisory') && String(result.advisory_gate).includes('does not break the suite'))
        report('G29_review_records_still_carried', ((result && result.blockingByRepo) || []).flatMap((b) => b.items).some((i) => i.kind === 'suite-unverified'))
      } else {
        report('G30_gate_does_not_run_on_an_unfit_candidate', !SPAWNED.some((l) => l.startsWith('test-suite:')), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('test-suite:')))}`)
        report('G30_no_advisory_log', !LINES.some((l) => l.includes('ADVISORY GATE')))
        report('G30_returns_as_it_always_did', !!result && result.status === 'repo-unresolved', `got=${result && result.status}`)
        report('G30_nothing_approved', !SPAWNED.some((l) => l.startsWith('approve:')))
      }
    } else if (SCENARIO === 'G39' || SCENARIO === 'G39B') {
      // An already-satisfied repo is FINISHED, and three places used to read it as broken:
      //  (a) a reviewer finding naming it recorded a `blocked-on` item, keeping the DOWNSTREAM out of
      //      `ready` over a repo with nothing wrong with it — the new state turned into a run failure;
      //  (b) a cross-repo escalation routed a fix into it, opening commits and a PR/MR in a repo every
      //      ship phase has already filtered out — a merge that tells nobody;
      //  (c) with every CODE repo satisfied, the run walked on to the gate with an EMPTY candidate
      //      list and a green pass over nothing.
      // This drives (a) and (b): db is satisfied, app is live and its reviewer names db.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'app', depends_on: ['db'] }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'app']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        // app PINS db, so db finishes in wave 1 and app's review sees its verdict — which is what
        // makes an `already-satisfied` upstream visible to the blocked-on check at all.
        'kickoff:FM-12:app': { ...REPO_PLAN('app', 'develop'), submodule_pins: [{ repo: 'db', path: 'vendor/db' }] },
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'nothing to do', status: 'already-satisfied', satisfied_by: [{ criterion: 'A1', commit: 'a1b2c3d', path_line: 'db/src/x.ts:9', quote: 'export const supportsFallback = (p) => p.flags.fallback' }] },
        'verify-satisfied:FM-12:db': { upheld: true, reason: 'holds', checked: [] },
        'build:FM-12:app': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] },
        'open-pr:FM-12:app': { pr_url: 'https://x/8', pr_number: 8 },
        'review:FM-12:app#1': { approved: false, tests_green: true, tests_receipt: 'ok', comments: [{ path: 'app/src/a.ts', line: 3, body: 'the db repo returns the wrong shape here' }], resolved_threads: [], still_open: ['db shape'], upstream_fix_needed: [{ repo: 'db', finding: 'wrong shape', evidence: 'observed' }] },
        'guard:FM-12:app#1': { approved: true, tests_green: true, comments: [] },
        'perf:FM-12:app#1': { approved: true, tests_green: true, comments: [] },
        // The escalation comes from the FIX agent's handoff, not the reviewer's — this is the ask
        // that used to open commits and a PR/MR in a repo every ship phase had already filtered out.
        'pr-fix:FM-12:app#1': { work_branch: 'feature/FM-12', summary: 'fixed here', status: 'complete', fixed: ['app/src/a.ts'], ...(SCENARIO === 'G39B' ? { upstream_fix_needed: [{ repo: 'db', finding: 'the shape is wrong at the source', evidence: 'observed: db/src/x.ts:9 returns a bare boolean where the caller reads an object' }] } : {}) },
        'review:FM-12:app#2': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: ['db shape'], still_open: [] },
        'guard:FM-12:app#2': { approved: true, tests_green: true, comments: [] },
        'perf:FM-12:app#2': { approved: true, tests_green: true, comments: [] },
        'approve:FM-12': { approved: true },
        'summary:FM-12': { path: 'x.md' },
      }
      const result = await runOnce(ARGS, canned)
      const blocked = JSON.stringify(result?.blockingByRepo || [])
      if (SCENARIO === 'G39') {
        report('G39a_satisfied_upstream_is_not_a_blocking_item', !blocked.includes('blocked-on'))
        report('G39a_downstream_still_reaches_ready', !!result && result.status !== 'repo-unresolved' && result.status !== 'review-unresolved')
        report('G39a_fix_pass_told_to_resolve_it_here', Object.entries(PROMPTS).some(([k, v]) => k.startsWith('pr-fix:FM-12:app') && /needed NO change for FM-12/.test(v)))
      } else {
        report('G39b_no_fix_routed_into_the_satisfied_repo', !SPAWNED.some((l) => l.startsWith('xrepo-fix:FM-12:db')))
        report('G39b_no_pr_opened_in_the_satisfied_repo', !SPAWNED.includes('open-pr:FM-12:db'))
        // Refusing to route it is not pretending the finding went away: it is a real gap in shipped
        // code, so it is RECORDED and the repo stays out of ready.
        report('G39b_refusal_is_recorded_not_swallowed', blocked.includes('cross-repo') && blocked.includes('left the run'))
      }
    } else if (SCENARIO === 'G40') {
      // (c) — every CODE repo satisfied, a suite repo still live and the gate REQUESTED. There is no
      // candidate, so the gate must not run and must not be reported as a pass; the run ends
      // already-satisfied and says the suite work is unvalidated.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }], test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'nothing to do', status: 'already-satisfied', satisfied_by: [{ criterion: 'A1', commit: 'a1b2c3d', path_line: 'db/src/x.ts:9', quote: 'export const supportsFallback = (p) => p.flags.fallback' }] },
        'verify-satisfied:FM-12:db': { upheld: true, reason: 'holds', checked: [] },
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'specs', status: 'complete', fixed: [] },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/9', pr_number: 9 },
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '5 passed' } },
        'summary:FM-12': { path: 'x.md' },
      }
      const result = await runOnce(ARGS, canned)
      report('G40_gate_not_run_over_an_empty_candidate', !SPAWNED.some((l) => l.startsWith('test-suite:FM-12')))
      report('G40_not_reported_as_a_pass', !!result && result.status === 'already-satisfied')
      report('G40_gate_unavailable_is_stated', /no candidate build to run against/.test(result?.testSuiteGateUnavailable || ''))
      report('G40_says_the_suite_work_is_unvalidated', /unvalidated/.test(result?.decision_needed || ''))
      report('G40_nothing_approved', !SPAWNED.some((l) => l.startsWith('approve:FM-12')))
    } else if (SCENARIO.startsWith('G44')) {
      // THE LAST NON-BUDGET STOPS. The goal behind this branch is that budget exhaustion should be
      // close to the only thing that ends a run, so every remaining terminal path was swept. Three
      // were one non-converging agent away from a stop that a single re-ask fixes:
      //   G44_SCOPE   — the scope stage THREW. No summary, no run-state, no record, no DM: the
      //                 operator got a stack trace and the next invocation started from nothing.
      //   G44_PR      — open-PR had NO retry at all, so one flaky agent ended a repo whose branch
      //                 was already built and pushed, and with it the whole change set.
      //   G44_REPLAN  — a missing plan FILE ended the run for every repo, including the ones whose
      //                 plans were fine, over the one artifact a re-ask reliably reproduces.
      const base = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12': { approved: true },
        'summary:FM-12': { path: 'x.md' },
      }
      if (SCENARIO === 'G44_SCOPE' || SCENARIO === 'G44_SCOPE_DEAD') {
        const canned = { ...base, 'scope:FM-12': null }
        if (SCENARIO === 'G44_SCOPE') canned['scope-retry:FM-12'] = base['scope:FM-12']
        else canned['scope-retry:FM-12'] = null
        const result = await runOnce(ARGS, canned)
        if (SCENARIO === 'G44_SCOPE') {
          report('G44_scope_is_retried_not_thrown', SPAWNED.includes('scope-retry:FM-12'))
          report('G44_run_continues_after_the_retry', SPAWNED.includes('build:FM-12:db'))
          report('G44_retry_brief_says_stop_investigating', /STOP investigating now/.test(PROMPTS['scope-retry:FM-12'] || ''))
        } else {
          report('G44_dead_scope_reports_instead_of_throwing', !!result && result.status === 'scope-unresolved')
          report('G44_dead_scope_still_writes_a_summary', SPAWNED.includes('summary:FM-12'))
          report('G44_dead_scope_names_the_decision', /could not be scoped/.test(result?.decision_needed || ''))
          report('G44_dead_scope_branched_nothing', !SPAWNED.some((l) => l.startsWith('kickoff:') || l.startsWith('build:')))
        }
      } else if (SCENARIO === 'G44_PR') {
        const result = await runOnce(ARGS, { ...base, 'open-pr:FM-12:db': null, 'open-pr-retry:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 } })
        report('G44_open_pr_is_retried', SPAWNED.includes('open-pr-retry:FM-12:db'))
        report('G44_repo_recovers_to_review', SPAWNED.some((l) => l.startsWith('review:FM-12:db')))
        report('G44_run_is_not_pr_unresolved', !!result && result.status !== 'repo-unresolved')
        report('G44_retry_brief_forbids_a_compound_writer', /run BARE/.test(PROMPTS['open-pr-retry:FM-12:db'] || ''))
      } else {
        const guardMissing = { repos: [{ repo: 'db', ok: [], relocated: [], missing: ['agent_logs/development-planner/FM-12-db-plan.md'] }] }
        const canned = { ...base, 'plan-guard:FM-12': guardMissing }
        if (SCENARIO === 'G44_REPLAN') canned['replan:FM-12:db'] = REPO_PLAN('db', 'develop')
        else canned['replan:FM-12:db'] = null
        const result = await runOnce(ARGS, canned)
        if (SCENARIO === 'G44_REPLAN') {
          report('G44_missing_plan_is_rewritten', SPAWNED.includes('replan:FM-12:db'))
          report('G44_run_proceeds_to_build', SPAWNED.includes('build:FM-12:db'))
          report('G44_replan_writes_no_code_and_no_branch', /Do NOT create or switch a branch/.test(PROMPTS['replan:FM-12:db'] || ''))
        } else {
          report('G44_unrecovered_plan_still_stops', !!result && result.status === 'plan-missing')
          report('G44_but_only_after_trying', SPAWNED.includes('replan:FM-12:db'))
        }
      }
    } else if (SCENARIO.startsWith('G43')) {
      // ADR 0032 — a `partial` handoff is the most continuable condition in the run, and it used to
      // end the repo on attempt one. `partial` means "some slices landed, work OF MY OWN remains":
      // the next invocation then paid for Scope, Kickoff and a resume to stand where this one already
      // was. Four shapes: it finishes on continuation (G43), it never finishes and the BOUND is what
      // stops it (G43_EXHAUST), an unmoved pass escalates the brief (G43_STALL), and an evidenced
      // cannot_fix ends the passes early rather than burning the budget to reach the same answer
      // (G43_DECLINE).
      const PARTIAL = (n) => ({ work_branch: 'feature/FM-12', summary: `slice ${n} landed`, status: 'partial', remaining: SCENARIO === 'G43_STALL' ? 'the same thing, unchanged' : `slices ${n + 1}-11 remain`, root_cause: 'db/src/x.ts:9 needs the new column', commands_run: [{ command: 'cargo test', exit_code: 1 }] })
      const DONE = { work_branch: 'feature/FM-12', summary: 'all slices landed', status: 'complete', fixed: ['db/src/x.ts'] }
      const DECLINE = { work_branch: 'feature/FM-12', summary: 'cannot proceed', status: 'blocked', remaining: 'the vendor API is not in this environment', cannot_fix: [{ kind: 'environment', reason: 'the vendor sandbox is absent from this environment', evidence: 'curl -sS https://vendor.local/health -> exit 7 (could not connect)', tried: 'harness restart, docker compose up, fixture seed, VPN check' }] }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': SCENARIO === 'G43_DECLINE' ? { ...PARTIAL(1), status: 'blocked' } : PARTIAL(1),
        'build-continue:FM-12:db#1': SCENARIO === 'G43' ? DONE : SCENARIO === 'G43_DECLINE' ? DECLINE : PARTIAL(2),
        'build-continue:FM-12:db#2': PARTIAL(3),
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12': { approved: true },
        'summary:FM-12': { path: 'x.md' },
      }
      const result = await runOnce(ARGS, canned)
      const conts = SPAWNED.filter((l) => l.startsWith('build-continue:FM-12:db'))
      if (SCENARIO === 'G43') {
        report('G43_partial_is_continued_not_stopped', conts.length === 1)
        report('G43_repo_reaches_ready', !!result && result.status !== 'repo-unresolved')
        report('G43_pr_opened_after_the_continuation', SPAWNED.includes('open-pr:FM-12:db'))
        const p = PROMPTS['build-continue:FM-12:db#1'] || ''
        report('G43_brief_carries_what_remains', p.includes('slices 2-11 remain'))
        report('G43_brief_forbids_a_restart', /it is not a restart/.test(p) && /What is already committed is DONE/.test(p))
      } else if (SCENARIO === 'G43_EXHAUST') {
        report('G43_bound_is_what_stops_it', conts.length === 2)
        report('G43_no_pass_past_the_bound', !SPAWNED.includes('build-continue:FM-12:db#3'))
        report('G43_repo_still_not_ready', !!result && result.status === 'repo-unresolved')
        report('G43_record_says_the_bound_stopped_it', JSON.stringify(result?.handoffs || result?.repoResults || {}).includes('continuation pass(es) ran and could not finish it'))
        report('G43_no_pr_on_an_unfinished_build', !SPAWNED.includes('open-pr:FM-12:db'))
      } else if (SCENARIO === 'G43_STALL') {
        report('G43_stall_escalates_the_brief', /YOUR LAST PASS MOVED NOTHING/.test(PROMPTS['build-continue:FM-12:db#2'] || ''))
        report('G43_first_pass_is_not_accused_of_stalling', !/YOUR LAST PASS MOVED NOTHING/.test(PROMPTS['build-continue:FM-12:db#1'] || ''))
      } else {
        report('G43_evidenced_decline_ends_the_passes', conts.length === 1)
        report('G43_decline_does_not_burn_the_budget', !SPAWNED.includes('build-continue:FM-12:db#2'))
        report('G43_blocked_brief_rules_out_the_cheap_classes', /YOU REPORTED BLOCKED/.test(PROMPTS['build-continue:FM-12:db#1'] || ''))
        report('G43_decline_reaches_the_handoff', JSON.stringify(result?.handoffs || result?.repoResults || {}).includes('declined this with evidence'))
      }
    } else if (SCENARIO.startsWith('G45')) {
      // The branch base is a fact of the run (ADR 0025) but nothing checked the work BRANCH against
      // it before the build agent read both. A branch left standing on the wrong base made the
      // repair the round's first slice: the whole slice budget and all of ADR 0032's continuation
      // passes went on git surgery, and the round reported as "the build did not finish" with no
      // sign that it never got to the feature at all. Five shapes: the healthy branch is untouched
      // and costs nothing extra (G45_OK), a branch carrying only foreign commits is repaired as its
      // OWN accounted step and the round keeps its budget (G45), a branch carrying BOTH this
      // ticket's commits and foreign ones is refused rather than rebased over (G45_UNREPAIRABLE), a
      // probe that fails leaves the repo exactly where it stood before the check existed AND has its
      // reason recorded (G45_FLAKE), and a resumed build does not pay to re-probe (G45_RESUMED).
      const DONE = { work_branch: 'feature/FM-12', summary: 'all slices landed', status: 'complete', fixed: ['db/src/x.ts'] }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: SCENARIO === 'G45_RESUMED' ? [builtRow('db')] : [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': DONE,
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { approved: true },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
      }
      if (SCENARIO === 'G45') {
        canned['base-reconcile:FM-12:db'] = { repo: 'db', branch_exists: true, state: 'repaired', ticket_commits: 0, foreign_commits: 2,
          commits: [{ sha: 'sha-inh2', subject: 'chore: inherited', ticket: false }, { sha: 'sha-inh1', subject: 'chore: inherited', ticket: false }],
          head_sha: 'sha-repaired', parked_at: 'stash@{0}', backup_ref: 'backup/FM-12-sha-inh', detail: 're-pointed at origin/develop; inherited commits dropped' }
      }
      if (SCENARIO === 'G45_UNREPAIRABLE') {
        canned['base-reconcile:FM-12:db'] = { repo: 'db', branch_exists: true, state: 'unrepairable', ticket_commits: 3, foreign_commits: 2,
          commits: [{ sha: 'sha-t3', subject: 'feat: c', ticket: true }, { sha: 'sha-t2', subject: 'feat: b', ticket: true },
            { sha: 'sha-t1', subject: 'feat: a', ticket: true }, { sha: 'sha-fork', subject: 'chore: inherited', ticket: false },
            { sha: 'sha-fork0', subject: 'chore: inherited', ticket: false }],
          head_sha: 'sha-mixed', parked_at: null, backup_ref: null, detail: 'the branch carries this ticket\'s commits on top of ones it inherited' }
      }
      const FLAKE = 'cursor-agent exited 1: Cursor stream ended without a successful result event'
      const result = await runOnce(ARGS, canned, SCENARIO === 'G45_FLAKE' ? { throwOn: ['base-reconcile:FM-12:db'], throwMessage: FLAKE } : {})
      const buildPrompt = PROMPTS['build:FM-12:db'] || ''
      const repairAccounted = (result?.spend || []).some((s) => s && s.label === 'db:base-reconcile')
      if (SCENARIO === 'G45') {
        report('G45_repair_is_its_own_accounted_step', repairAccounted, `spend=${JSON.stringify((result?.spend || []).map((s) => s && s.label))}`)
        report('G45_repair_is_not_a_continuation_pass', !SPAWNED.some((l) => l.startsWith('build-continue:')))
        report('G45_round_still_builds', SPAWNED.includes('build:FM-12:db'))
        report('G45_reported_distinctly_in_the_log', LINES.some((l) => l.includes('[db] BRANCH BASE REPAIRED as its own accounted step')))
        report('G45_brief_tells_the_round_not_to_redo_it', /THE BRANCH BASE WAS ALREADY REPAIRED FOR YOU/.test(buildPrompt) && /not paid for out of your budget/.test(buildPrompt))
        report('G45_repo_still_reaches_ready', !!result && result.status !== 'repo-unresolved')
      } else if (SCENARIO === 'G45_UNREPAIRABLE') {
        report('G45_mixed_history_is_refused_not_rebased_over', !SPAWNED.includes('build:FM-12:db'))
        report('G45_ends_on_the_target_branch_halt', !!result && result.status === 'target-branch-halt', `status=${result && result.status}`)
        report('G45_blocking_item_is_recorded', JSON.stringify(result?.blockingByRepo || []).includes('branch-base'))
        report('G45_human_action_names_the_rebase', JSON.stringify(result?.blockingByRepo || []).includes('rebase --onto origin/develop'))
        report('G45_no_pr_on_a_branch_that_cannot_be_diffed', !SPAWNED.includes('open-pr:FM-12:db'))
      } else if (SCENARIO === 'G45_FLAKE') {
        report('G45_flake_does_not_halt_the_repo', SPAWNED.includes('build:FM-12:db'))
        report('G45_flake_says_it_is_proceeding_unchecked', LINES.some((l) => l.includes('branch-base reconcile did not converge') && l.includes('UNCHECKED')))
        report('G45_reason_is_captured_not_swallowed', LINES.some((l) => l.includes(FLAKE)))
        report('G45_reason_reaches_the_summary_brief', (PROMPTS['summary:FM-12'] || '').includes('AGENTS THAT RETURNED NOTHING') && (PROMPTS['summary:FM-12'] || '').includes(FLAKE))
        report('G45_reason_reaches_the_run_result', JSON.stringify(result?.summary?.non_convergences || []).includes(FLAKE))
      } else if (SCENARIO === 'G45_RESUMED') {
        report('G45_resumed_build_does_not_re_probe', !SPAWNED.includes('base-reconcile:FM-12:db'))
      } else {
        report('G45_healthy_branch_costs_no_repair', !LINES.some((l) => l.includes('BRANCH BASE REPAIRED')))
        report('G45_healthy_branch_is_still_probed', SPAWNED.includes('base-reconcile:FM-12:db'))
        report('G45_healthy_brief_carries_no_repair_clause', !/THE BRANCH BASE WAS ALREADY REPAIRED FOR YOU/.test(buildPrompt))
        report('G45_healthy_run_records_no_non_convergence', !(result?.summary?.non_convergences || []).length, `recorded=${JSON.stringify(result?.summary?.non_convergences || [])}`)
        report('G45_healthy_repo_still_reaches_ready', !!result && result.status !== 'repo-unresolved')
      }
    } else if (SCENARIO.startsWith('G54')) {
      // The branch-base probe returns FACTS and the workflow decides. Measured on one ticket, both
      // halves went wrong at once: the probe was handed `git log --oneline`, which prints only the
      // SUBJECT, while this framework's own convention puts `Refs <ticket>` in the commit TRAILER —
      // so a branch carrying three of the ticket's commits read as "0 ticket, 4 foreign", which is
      // the arm that re-points the branch and DELETES them. And the rebase command it handed a
      // person for the other arm ended `<oldest foreign>^`, whose caret puts the foreign commit
      // back INTO the range it is there to exclude, so running it changes nothing a re-run can see.
      const commits = {
        stacked: [   // git log order: newest first. Foreign sits UNDER this ticket's own work.
          { sha: 'sha-t3', subject: 'docs(app): correct the documented line numbers', ticket: true },
          { sha: 'sha-t2', subject: 'test(app): assert the panel stays confined', ticket: true },
          { sha: 'sha-t1', subject: 'feat(app): show the instruction panel', ticket: true },
          { sha: 'sha-f1', subject: 'chore: regenerate the generated mirror', ticket: false },
        ],
        interleaved: [   // a foreign commit ABOVE one of the ticket's — no single boundary expresses it
          { sha: 'sha-t2', subject: 'test(app): assert the panel stays confined', ticket: true },
          { sha: 'sha-f2', subject: 'chore: unrelated', ticket: false },
          { sha: 'sha-t1', subject: 'feat(app): show the instruction panel', ticket: true },
          { sha: 'sha-f1', subject: 'chore: regenerate the generated mirror', ticket: false },
        ],
      }
      const DONE = { work_branch: 'feature/FM-12', summary: 'all slices landed', status: 'complete', fixed: ['db/src/x.ts'] }
      const drift = SCENARIO === 'G54_INTERLEAVED' ? commits.interleaved : commits.stacked
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': DONE,
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { approved: true },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
        // The probe reports what it READ. It no longer authors a command, and the two integers are
        // deliberately the WRONG ones a subject-only read produced — the workflow must count the
        // list it was given rather than trust a total the probe arrived at some other way.
        'base-reconcile:FM-12:db': { repo: 'db', branch_exists: true, state: SCENARIO === 'G54_LOST' ? 'repaired' : 'unrepairable',
          ticket_commits: 0, foreign_commits: 4, commits: drift, head_sha: 'sha-t3',
          parked_at: null, backup_ref: 'backup/FM-12-sha-t3', detail: 'drift read off the branch' },
      }
      const result = await runOnce(ARGS, canned, {})
      const blocking = JSON.stringify(result?.blockingByRepo || [])
      const probePrompt = PROMPTS['base-reconcile:FM-12:db'] || ''
      if (SCENARIO === 'G54') {
        report('G54_the_boundary_is_the_newest_foreign_commit_with_no_caret',
          blocking.includes('rebase --onto origin/develop sha-f1 feature/FM-12') && !blocking.includes('sha-f1^'),
          blocking.slice(0, 400))
        report('G54_the_branch_is_saved_before_the_person_rewrites_it', blocking.includes('branch backup/FM-12-sha-t3 feature/FM-12'))
        report('G54_the_halt_counts_the_list_it_was_given_not_the_probes_total',
          blocking.includes('3 that are') && !blocking.includes('0 that are'), blocking.slice(0, 300))
      } else if (SCENARIO === 'G54_INTERLEAVED') {
        report('G54_interleaved_history_is_not_given_a_single_boundary_rebase', !blocking.includes('rebase --onto'), blocking.slice(0, 300))
        report('G54_interleaved_history_is_replayed_commit_by_commit_oldest_first', blocking.includes('cherry-pick sha-t1 sha-t2'), blocking.slice(0, 400))
      } else if (SCENARIO === 'G54_LOST') {
        report('G54_a_repair_that_dropped_the_tickets_own_commits_is_not_reported_as_success',
          LINES.some((l) => l.includes('BRANCH BASE REPAIR CONTRADICTS ITSELF')), LINES.filter((l) => l.includes('BRANCH BASE')).join(' | ').slice(0, 300))
        report('G54_the_backup_ref_is_named_so_the_work_can_be_recovered', blocking.includes('backup/FM-12-sha-t3'), blocking.slice(0, 300))
      } else {
        report('G54_probe_is_told_to_match_the_whole_message', /--grep=FM-12/.test(probePrompt))
        report('G54_probe_is_told_where_the_reference_actually_lives', /TRAILER/.test(probePrompt) && /--oneline/.test(probePrompt))
        report('G54_probe_no_longer_authors_the_rebase_command', !/rebase --onto/.test(probePrompt))
        report('G54_repair_checks_for_an_index_a_failed_park_wedged', /ls-files -u/.test(probePrompt) && /MERGE_HEAD/.test(probePrompt))
        report('G54_repair_stops_when_the_park_itself_fails', /exits non-zero/.test(probePrompt))
        report('G54_repair_saves_the_branch_before_moving_it', /branch backup\//.test(probePrompt))
      }
    } else if (SCENARIO.startsWith('G55')) {
      // The scoping stage got ONE bounded retry, for the case where it returned nothing structured,
      // on the reasoning that a non-converging agent is the cheapest thing in the run to ask twice.
      // The case where it returns a well-formed NON-ANSWER got none, because the code read "parsed"
      // as "converged". Measured: a scope came back `[{"repo":"<repo>_PLACEHOLDER","summary":
      // "placeholder"}]` — schema-valid, and a template rather than a reading of the ticket. The run
      // ended before Kickoff and a person had to re-invoke it; the plain retry that fixed it is the
      // one this stage already knows how to do.
      const DONE = { work_branch: 'feature/FM-12', summary: 'all slices landed', status: 'complete', fixed: ['db/src/x.ts'] }
      const goodScope = { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
        repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true }
      const placeholderScope = { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
        repos: [{ repo: 'db_PLACEHOLDER', summary: 'placeholder' }], test_suite: { needed: false }, tracker_reachable: true }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': placeholderScope,
        'scope-registry-retry:FM-12': SCENARIO === 'G55_TWICE' ? placeholderScope : goodScope,
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': DONE,
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { approved: true },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
      }
      const result = await runOnce(ARGS, canned, {})
      if (SCENARIO === 'G55_TWICE') {
        report('G55_a_second_non_answer_still_stops_the_run', !!result && result.status === 'scope-unresolved', `status=${result && result.status}`)
        report('G55_the_stop_says_what_came_back', JSON.stringify(result?.decision_needed || '').includes('db_PLACEHOLDER'))
      } else {
        report('G55_a_scope_naming_no_registered_repo_is_asked_once_more', SPAWNED.includes('scope-registry-retry:FM-12'))
        report('G55_the_retry_is_told_which_repos_exist', /registered/.test(PROMPTS['scope-registry-retry:FM-12'] || '') && /db_PLACEHOLDER/.test(PROMPTS['scope-registry-retry:FM-12'] || ''))
        report('G55_the_run_carries_on_instead_of_ending_before_kickoff', !!result && result.status !== 'scope-unresolved', `status=${result && result.status}`)
        report('G55_and_it_plans_the_repo_the_retry_named', SPAWNED.includes('kickoff:FM-12:db'))
      }
    } else if (SCENARIO.startsWith('G46')) {
      // A repo declares its own known_false_reds, every prose surface says to rule one out against
      // the base before calling a red real, and the RETRY LOOP never did: it continued the round from
      // scratch, with a fresh agent, which rebuilt everything and re-ran the same declared flake. Six
      // shapes. It fails on the base too and is ALL the round owes, so it is recorded and bought no
      // continuation pass (G46); the same, but the round owes real work as well, so it IS continued
      // and the brief tells it not to chase the flake (G46_PARTIAL); it PASSES on the base, so it is
      // a regression and nothing about today changes (G46_GENUINE); nothing declared covers it, same
      // (G46_NO_MATCH); the repo declares none, so no screen is even spawned (G46_UNDECLARED); and a
      // screen that returns nothing charges the round exactly as before (G46_FLAKE).
      const REPO = SCENARIO === 'G46_UNDECLARED' ? 'svc' : 'db'
      const sole = SCENARIO === 'G46'
      const FLAKE46 = 'selftest: the screen itself fell over'
      const FLAKY = (n) => ({ work_branch: 'feature/FM-12', summary: `slice ${n} landed`, status: 'partial',
        remaining: sole ? 'nothing of my own — only the shared-database test aborting' : `slices ${n + 1}-11 remain, and the shared-database test aborts`,
        root_cause: 'tests/orders:88 aborts when the shared test database is reused',
        commands_run: [{ command: 'scripts/dev.sh test orders::settles', exit_code: 134 }] })
      const SCREEN = (state) => ({ repo: REPO, state, failing: ['orders::settles'],
        matched: 'the suite shares one test database', base_command: 'scripts/dev.sh test orders::settles',
        base_exit_code: state === 'genuine' ? 0 : 134, sole_obstacle: sole, detail: `it is ${state} on the base` })
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: REPO }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk([REPO]),
        [`kickoff:FM-12:${REPO}`]: REPO_PLAN(REPO, 'develop'),
        [`build:FM-12:${REPO}`]: FLAKY(1),
        [`build-continue:FM-12:${REPO}#1`]: FLAKY(2),
        [`build-continue:FM-12:${REPO}#2`]: FLAKY(3),
        'summary:FM-12': { path: 'x.md' },
      }
      if (SCENARIO === 'G46' || SCENARIO === 'G46_PARTIAL') canned[`false-red-screen:FM-12:${REPO}`] = SCREEN('pre-existing')
      if (SCENARIO === 'G46_GENUINE') canned[`false-red-screen:FM-12:${REPO}`] = SCREEN('genuine')
      const result = await runOnce(ARGS, canned, SCENARIO === 'G46_FLAKE' ? { throwOn: [`false-red-screen:FM-12:${REPO}`], throwMessage: FLAKE46 } : {})
      const conts = SPAWNED.filter((l) => l.startsWith(`build-continue:FM-12:${REPO}`))
      const blockingJson = JSON.stringify(result?.blockingByRepo || [])
      if (SCENARIO === 'G46') {
        report('G46_screen_is_its_own_accounted_step', (result?.spend || []).some((s) => s && s.label === `${REPO}:false-red-screen`), `spend=${JSON.stringify((result?.spend || []).map((s) => s && s.label))}`)
        report('G46_confirmed_flake_buys_no_continuation_pass', conts.length === 0, `conts=${JSON.stringify(conts)}`)
        report('G46_recorded_on_its_own_row', blockingJson.includes('known-false-red'), blockingJson.slice(0, 200))
        report('G46_record_says_it_fails_on_the_base_too', blockingJson.includes('fails on develop too'))
        report('G46_human_action_is_stabilise_not_fix_the_ticket', blockingJson.includes('stabilise orders::settles'))
        report('G46_handoff_says_it_is_not_this_rounds_failure', JSON.stringify(result?.repoResults || {}).includes("NOT THIS ROUND'S FAILURE"))
        report('G46_screen_verdict_rides_the_repo_result', JSON.stringify(result?.repoResults || {}).includes('"false_red"'))
        report('G46_repo_still_not_ready', !!result && result.status === 'repo-unresolved', `status=${result && result.status}`)
      } else if (SCENARIO === 'G46_PARTIAL') {
        report('G46_round_with_real_work_left_is_still_continued', conts.length === 2, `conts=${JSON.stringify(conts)}`)
        report('G46_brief_tells_the_pass_not_to_chase_it', /DO NOT CHASE ORDERS::SETTLES/.test(PROMPTS[`build-continue:FM-12:${REPO}#1`] || ''))
        report('G46_brief_forbids_the_rebuild_and_the_data_wipe', /do not wipe or recreate a local data directory/.test(PROMPTS[`build-continue:FM-12:${REPO}#1`] || ''))
        report('G46_flake_is_recorded_even_when_work_remains', blockingJson.includes('known-false-red'))
      } else if (SCENARIO === 'G46_GENUINE') {
        report('G46_a_pass_on_the_base_changes_nothing', conts.length === 2, `conts=${JSON.stringify(conts)}`)
        report('G46_genuine_is_not_recorded_as_a_flake', !blockingJson.includes('known-false-red'), blockingJson.slice(0, 200))
        report('G46_brief_says_the_regression_is_yours', /IS YOURS/.test(PROMPTS[`build-continue:FM-12:${REPO}#1`] || ''))
      } else if (SCENARIO === 'G46_NO_MATCH') {
        report('G46_no_match_is_still_screened', SPAWNED.includes(`false-red-screen:FM-12:${REPO}`))
        report('G46_no_match_leaves_the_budget_alone', conts.length === 2, `conts=${JSON.stringify(conts)}`)
        report('G46_no_match_carries_no_clause', !/DO NOT CHASE/.test(PROMPTS[`build-continue:FM-12:${REPO}#1`] || ''))
        report('G46_no_match_records_nothing', !blockingJson.includes('known-false-red'))
      } else if (SCENARIO === 'G46_UNDECLARED') {
        report('G46_a_repo_declaring_none_pays_for_no_screen', !SPAWNED.some((l) => l.startsWith('false-red-screen:')), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('false-red-screen:')))}`)
        report('G46_undeclared_round_runs_exactly_as_before', conts.length === 2, `conts=${JSON.stringify(conts)}`)
      } else {
        report('G46_screen_that_returns_nothing_does_not_halt', conts.length === 2, `conts=${JSON.stringify(conts)}`)
        report('G46_non_convergence_says_the_round_is_charged', LINES.some((l) => l.includes('known-false-red screen did not converge') && l.includes('charged to this round')))
        report('G46_non_convergence_excuses_nothing', !blockingJson.includes('known-false-red'))
        report('G46_reason_reaches_the_run_result', JSON.stringify(result?.summary?.non_convergences || []).includes(FLAKE46))
      }
    } else if (SCENARIO.startsWith('G47')) {
      // G46 screened the BUILD round. It is not the only loop a declared flake can empty: the review
      // gate re-runs this repo's WHOLE suite every round, its pass predicate requires tests_green,
      // and a declared flake reds it every time — so the reviewer can never pass, and the loop grinds
      // its rounds (14 by default, against the build round's 3) re-running a suite whose red the repo
      // wrote down in advance. Every repo in a run has a review, so this one is not one repo's shape.
      // Three shapes: it fails on the base too, so it is recorded and the gate is not asked again
      // (G47); it PASSES there, so it is this diff's regression and the loop works it exactly as
      // before, told the red is theirs (G47_GENUINE); the repo declares nothing, so no screen is
      // spawned at all and the rounds run as they do today (G47_UNDECLARED).
      const REPO = SCENARIO === 'G47_UNDECLARED' ? 'svc' : 'db'
      const RED = { approved: false, tests_green: false, comments: [], resolved_threads: [], still_open: [],
        tests_receipt: 'scripts/dev.sh test → orders::settles ABORTED (signal 6), exit 134',
        conclusion: 'the repo suite is red on the PR head' }
      const SCREEN = (state) => ({ repo: REPO, state, failing: ['orders::settles'],
        matched: 'the suite shares one test database', base_command: 'scripts/dev.sh test orders::settles',
        base_exit_code: state === 'genuine' ? 0 : 134, sole_obstacle: true, detail: `it is ${state} on the base` })
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: REPO }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk([REPO]),
        [`kickoff:FM-12:${REPO}`]: REPO_PLAN(REPO, 'develop'),
        [`build:FM-12:${REPO}`]: { work_branch: 'feature/FM-12', summary: 'the feature landed', status: 'complete', fixed: ['src/orders.rs'] },
        [`open-pr:FM-12:${REPO}`]: { pr_url: 'https://x/8', pr_number: 8 },
        [`review:FM-12:${REPO}#1`]: RED,
        [`review:FM-12:${REPO}#2`]: SCENARIO === 'G47_GENUINE'
          ? { approved: true, tests_green: true, tests_receipt: 'scripts/dev.sh test → 214 passed', comments: [], resolved_threads: ['t1'], still_open: [] }
          : RED,
        [`review:FM-12:${REPO}#3`]: RED,
        [`pr-fix:FM-12:${REPO}#1`]: { work_branch: 'feature/FM-12', summary: 'fixed the regression the red named', status: 'complete', commits: 1, fixed: ['src/orders.rs'] },
        'summary:FM-12': { path: 'x.md' },
      }
      if (SCENARIO !== 'G47_UNDECLARED') canned[`false-red-screen:FM-12:${REPO}#review`] = SCREEN(SCENARIO === 'G47_GENUINE' ? 'genuine' : 'pre-existing')
      const result = await runOnce(ARGS, canned)
      const reviews = SPAWNED.filter((l) => l.startsWith(`review:FM-12:${REPO}#`))
      const blockingJson = JSON.stringify(result?.blockingByRepo || [])
      if (SCENARIO === 'G47') {
        report('G47_screen_is_its_own_accounted_step', (result?.spend || []).some((s) => s && s.label === `${REPO}:false-red-screen#review`), `spend=${JSON.stringify((result?.spend || []).map((s) => s && s.label))}`)
        report('G47_confirmed_flake_does_not_burn_the_review_rounds', reviews.length === 1, `reviews=${JSON.stringify(reviews)}`)
        report('G47_recorded_on_its_own_row', blockingJson.includes('known-false-red'), blockingJson.slice(0, 200))
        report('G47_record_says_it_fails_on_the_base_too', blockingJson.includes('fails on develop too'), blockingJson.slice(0, 300))
        report('G47_human_action_is_stabilise_not_fix_the_ticket', blockingJson.includes('stabilise orders::settles'))
        report('G47_repo_still_not_ready', !!result && result.status === 'repo-unresolved', `status=${result && result.status}`)
      } else if (SCENARIO === 'G47_GENUINE') {
        report('G47_a_pass_on_the_base_changes_nothing', reviews.length === 2, `reviews=${JSON.stringify(reviews)}`)
        report('G47_genuine_is_not_recorded_as_a_flake', !blockingJson.includes('known-false-red'), blockingJson.slice(0, 200))
        report('G47_brief_says_the_red_suite_is_yours', /THE RED SUITE IS YOURS/.test(PROMPTS[`pr-fix:FM-12:${REPO}#1`] || ''))
      } else {
        report('G47_a_repo_declaring_none_pays_for_no_screen', !SPAWNED.some((l) => l.startsWith('false-red-screen:')), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('false-red-screen:')))}`)
        report('G47_undeclared_rounds_run_exactly_as_before', reviews.length === 3, `reviews=${JSON.stringify(reviews)}`)
        report('G47_undeclared_records_no_flake', !blockingJson.includes('known-false-red'))
      }
    } else if (SCENARIO.startsWith('G48')) {
      // A build agent ENDED FROM OUTSIDE mid-work — the engine's own `[Request interrupted by user]`,
      // a timeout, a killed stream — never reaches StructuredOutput, so the round sees exactly what a
      // runaway agent leaves: nothing. Measured on one repo: three sequential attempts, the same
      // prompt re-sent from zero context each time (~6.3M then ~9.6M cumulative tokens), each cut off
      // during exploration before a single line landed. The run said `build-unresolved` and recorded
      // NOTHING — no blocking row, so no banner, no "needs a person" section in the summary, no line
      // in the incomplete-run DM — and the engine's reason, the one string that separates an external
      // cut-off from a broken plan, reached only the token table. So the next person re-ran it from
      // zero and paid for it again. The two causes need opposite continuations and opposite human
      // actions, which is why the reason has to be read rather than assumed.
      const ARGS = 'FM-12'
      const CUT = 'agent ended without a structured result: [Request interrupted by user]'
      const SCHEMA_ERR = 'schema validation failed: required property "work_branch" missing'
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { approved: true },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
      }
      // The bounded continuation is the run's one chance to salvage a cut-off attempt: here it lands.
      if (SCENARIO === 'G48_SALVAGED') canned['build-handoff:FM-12:db'] = { work_branch: 'feature/FM-12', summary: 'parked the slice and handed off', status: 'complete', fixed: ['a.rs'], commits: 1 }
      const throwOn = SCENARIO === 'G48_SALVAGED' ? ['build:FM-12:db'] : ['build:FM-12:db', 'build-handoff:FM-12:db']
      const result = await runOnce(ARGS, canned, { throwOn, throwMessage: SCENARIO === 'G48_RUNAWAY' ? SCHEMA_ERR : CUT })
      const blockingJson = JSON.stringify(result?.blockingByRepo || [])
      const handoffPrompt = PROMPTS['build-handoff:FM-12:db'] || ''
      if (SCENARIO === 'G48') {
        report('G48_a_build_that_never_hands_off_is_recorded', blockingJson.includes('build-no-handoff'), blockingJson.slice(0, 300))
        report('G48_record_carries_the_engine_reason_verbatim', blockingJson.includes('[Request interrupted by user]'), blockingJson.slice(0, 300))
        report('G48_named_as_a_cut_off_not_a_runaway', blockingJson.includes('ENDED FROM OUTSIDE'), blockingJson.slice(0, 300))
        report('G48_human_action_is_re_run_not_read_the_branch_yourself', /re-run/i.test(blockingJson), blockingJson.slice(0, 300))
        report('G48_second_attempt_is_told_it_was_cut_off', /ENDED FROM OUTSIDE/.test(handoffPrompt) && !/ran away/.test(handoffPrompt), handoffPrompt.slice(0, 240))
        report('G48_repo_does_not_reach_ready', !!result && result.status !== 'ready', `status=${result && result.status}`)
      } else if (SCENARIO === 'G48_RUNAWAY') {
        report('G48_a_runaway_is_recorded_too', blockingJson.includes('build-no-handoff'), blockingJson.slice(0, 300))
        report('G48_a_runaway_is_not_called_a_cut_off', !blockingJson.includes('ENDED FROM OUTSIDE'), blockingJson.slice(0, 300))
        report('G48_a_runaway_keeps_todays_framing', /ran away/.test(handoffPrompt), handoffPrompt.slice(0, 240))
      } else {
        report('G48_a_salvaged_round_records_no_missing_handoff', !blockingJson.includes('build-no-handoff'), blockingJson.slice(0, 300))
        report('G48_a_salvaged_round_still_opens_its_pr', SPAWNED.includes('open-pr:FM-12:db'), `spawned=${JSON.stringify(SPAWNED.filter((l) => l.startsWith('open-pr:')))}`)
      }
    } else if (SCENARIO.startsWith('G49')) {
      // The cost of a cut-off attempt, not its record (G48). An external end arrives mid-sentence:
      // there is no final step, so every durability rule in the build brief — park the tree, commit
      // or stash, name where it went — is unreachable, and an attempt that spent 115 messages and
      // ~8.4M cache-read tokens exploring leaves NOTHING on the branch. The relaunch then re-sends
      // the identical brief into an empty context and pays for the same exploration again.
      // Two things the workflow itself controls: tell the build to land slices AS IT GOES, so a
      // cut-off costs the tail rather than the attempt; and tell a relaunch what its predecessor
      // already landed, which `reconcileBranchBase` has measured and thrown away.
      const ARGS = 'FM-12'
      const DONE = { work_branch: 'feature/FM-12', summary: 'all slices landed', status: 'complete', fixed: ['db/src/x.ts'] }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'base-reconcile:FM-12:db': { repo: 'db', branch_exists: true, state: 'ok', foreign_commits: 0,
          ticket_commits: SCENARIO === 'G49_CLEAN' ? 0 : 3,
          head_sha: 'sha-partial', parked_at: null, rebase_command: null, detail: 'stands on develop' },
        'build:FM-12:db': DONE,
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { approved: true },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
      }
      const result = await runOnce(ARGS, canned, {})
      const buildPrompt = PROMPTS['build:FM-12:db'] || ''
      if (SCENARIO === 'G49_CLEAN') {
        report('G49_clean_branch_carries_no_prior_work_claim', !/WORK IS ALREADY ON THIS BRANCH/.test(buildPrompt))
        report('G49_clean_brief_still_carries_the_durability_rule', /CAN END FROM OUTSIDE WITHOUT WARNING/.test(buildPrompt))
      } else {
        report('G49_brief_names_what_the_branch_already_carries', /WORK IS ALREADY ON THIS BRANCH/.test(buildPrompt) && /3 commit\(s\)/.test(buildPrompt), buildPrompt.slice(0, 200))
        report('G49_brief_says_continue_not_redo', /CONTINUE from where they stop/.test(buildPrompt) && /do NOT rebuild/.test(buildPrompt))
        report('G49_brief_gives_the_command_to_read_them', buildPrompt.includes('log --oneline develop..feature/FM-12'))
        report('G49_every_brief_carries_the_cut_off_durability_rule', /CAN END FROM OUTSIDE WITHOUT WARNING/.test(buildPrompt) && /commit each slice the moment it is green/.test(buildPrompt))
        report('G49_repo_still_reaches_ready', !!result && result.status !== 'repo-unresolved', `status=${result && result.status}`)
      }
    } else if (SCENARIO.startsWith('G50')) {
      // G49 narrowed what a cut-off costs the BUILD phase. The cut-off is not a build phenomenon:
      // the same external end lands on a QA runner writing specs, on a reviewer mid-thread, on a
      // planner mid-plan — any phase, any repo, any role — and every one of those briefs carried
      // its durability discipline only in the build's own constant. So the rule belongs where
      // EVERY agent passes, not in one phase's prompt, and a step whose predecessor was killed
      // should hear so whatever phase it is in.
      const ARGS = 'FM-12'
      const RULE = /CAN END FROM OUTSIDE WITHOUT WARNING/
      const everyBriefHasIt = () => {
        const missing = Object.keys(PROMPTS).filter((k) => !RULE.test(PROMPTS[k] || ''))
        return { ok: Object.keys(PROMPTS).length > 0 && missing.length === 0, missing }
      }
      // G50 made progress durable everywhere. Durability saves the COMMITS; it does not save the
      // STRUCTURED RESULT, which is every agent's last action and therefore the one artifact a
      // ceiling always takes. This file already recorded that failure once — gate rounds ending at
      // 100/101/100 tool calls with the verdict never returned — and the answer written down then,
      // "return EARLIER", was pinned to the three gate call sites. It belongs on every brief.
      const RETURNS = /BEFORE YOU RUN OUT OF TURNS/
      const everyBriefReturnsEarly = () => {
        const missing = Object.keys(PROMPTS).filter((k) => !RETURNS.test(PROMPTS[k] || ''))
        return { ok: Object.keys(PROMPTS).length > 0 && missing.length === 0, missing }
      }
      // G51 told every brief to return before the ceiling, and named the wrong ceiling: a step
      // count. Measured over 235 agents of this workflow's own runs, a step count barely predicts
      // anything — the killed agents ran 22 to 411 steps and the survivors 4 to 527, and 64 of the
      // 90 deaths happened before the 80 steps G51 warned at. Context does predict it: 84 of those
      // 90 were past 160k input tokens, none ever got past 170,912, and the agents that finished
      // averaged 71k. So the brief has to name the thing that actually fills — and the read
      // discipline that controls how fast it fills, since 9% of results (the ones over 8 KB) were
      // 56% of everything the killed agents spent.
      const CONTEXT = /WHAT ACTUALLY ENDS YOU IS CONTEXT, NOT TURNS/
      const READS = /grep the decisive lines/
      const everyBriefKnowsTheUnit = () => {
        const missing = Object.keys(PROMPTS).filter((k) => !CONTEXT.test(PROMPTS[k] || ''))
        return { ok: Object.keys(PROMPTS).length > 0 && missing.length === 0, missing }
      }
      if (SCENARIO === 'G50_ROLES') {
        // Empty run state, so the phases that spawn the widest set of roles all run: kickoff and
        // the reviewers reach the engine through raw agent() calls of their own, NOT through the
        // wrapper the rest of the run uses — a fix applied at that wrapper would miss them.
        const canned = {
          ...BASE,
          'run-state:FM-12': { rows: [] },
          'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
            repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
          'plan-guard:FM-12': planGuardOk(['db']),
          'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
          'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: ['db/src/x.ts'] },
          'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
          'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
          'approve:FM-12:db': { approved: true },
          'notify:FM-12': { sent: true },
          'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
        }
        await runOnce(ARGS, canned, {})
        const cover = everyBriefHasIt()
        report('G50_planner_and_reviewer_briefs_reach_the_engine', !!PROMPTS['kickoff:FM-12:db'] && !!PROMPTS['review:FM-12:db#1'])
        report('G50_the_rule_reaches_briefs_that_bypass_the_wrapper', RULE.test(PROMPTS['kickoff:FM-12:db'] || '') && RULE.test(PROMPTS['review:FM-12:db#1'] || ''))
        report('G50_every_brief_of_every_role_carries_the_rule', cover.ok, `missing: ${cover.missing.join(', ')}`)
        const early = everyBriefReturnsEarly()
        report('G51_every_brief_of_every_role_is_told_to_return_before_the_ceiling', early.ok, `missing: ${early.missing.join(', ')}`)
        report('G51_a_gate_brief_that_already_says_it_is_not_told_twice',
          ((PROMPTS['review:FM-12:db#1'] || '').match(/BEFORE YOU RUN OUT OF TURNS/g) || []).length === 1)
        const unit = everyBriefKnowsTheUnit()
        report('G52_every_brief_of_every_role_is_told_the_ceiling_is_context_not_turns', unit.ok, `missing: ${unit.missing.join(', ')}`)
        report('G52_a_gate_hears_the_context_rule_even_though_its_return_rule_is_deduped',
          CONTEXT.test(PROMPTS['review:FM-12:db#1'] || ''))
      } else {
        // Resumed repos, so the only thing left to run is the QA gate — the exact phase and role
        // the second report named (a suite runner, 172 messages in, ended from outside).
        const canned = {
          ...BASE,
          'run-state:FM-12': { rows: [...readyRows('db', 1), ...readyRows('e2e', 2)] },
          'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
            repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }], test_suite: { needed: true }, tracker_reachable: true },
          'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
          'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
          'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
          'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'npx cypress run', exit_code: 0, summary_line: '5 passed' } },
          'audit:FM-12:e2e': { posted: true, detail: 'result posted' },
          'notify:FM-12': { sent: true },
          'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
        }
        const cut = SCENARIO === 'G50_CUT'
        await runOnce(ARGS, canned, cut ? { throwOn: ['test-suite:FM-12:e2e'], throwMessage: 'Error: [Request interrupted by user]' } : {})
        const audit = PROMPTS['audit:FM-12:e2e'] || ''
        if (cut) {
          report('G50_a_cut_off_outside_the_build_is_told_to_the_next_agent', /ENDED FROM OUTSIDE/.test(audit) && /interrupted by user/.test(audit), audit.slice(-260))
          report('G50_the_next_agent_is_told_to_check_not_assume', /do NOT assume/.test(audit))
          report('G51_the_replacement_ask_is_narrowed_not_repeated',
            /SMALLEST USEFUL INCREMENT/.test(audit) && /the workflow will continue you/i.test(audit), audit.slice(-300))
        } else {
          const cover = everyBriefHasIt()
          report('G50_the_qa_gate_brief_carries_the_rule', RULE.test(PROMPTS['test-suite:FM-12:e2e'] || ''))
          report('G50_every_brief_of_every_phase_carries_the_rule', cover.ok, `missing: ${cover.missing.join(', ')}`)
          report('G50_no_cut_off_means_no_cut_off_notice', !Object.keys(PROMPTS).some((k) => /WAS ENDED FROM OUTSIDE/.test(PROMPTS[k] || '')))
          const early = everyBriefReturnsEarly()
          report('G51_the_qa_gate_brief_is_told_to_return_before_the_ceiling', RETURNS.test(PROMPTS['test-suite:FM-12:e2e'] || ''))
          report('G51_every_brief_of_every_phase_is_told_to_return_before_the_ceiling', early.ok, `missing: ${early.missing.join(', ')}`)
          report('G51_a_clean_run_narrows_nobodys_ask', !Object.keys(PROMPTS).some((k) => /SMALLEST USEFUL INCREMENT/.test(PROMPTS[k] || '')))
          const unit = everyBriefKnowsTheUnit()
          report('G52_every_brief_of_every_phase_is_told_the_ceiling_is_context_not_turns', unit.ok, `missing: ${unit.missing.join(', ')}`)
          report('G52_every_brief_carries_the_read_discipline_that_controls_it',
            READS.test(PROMPTS['test-suite:FM-12:e2e'] || ''))
          report('G52_no_brief_still_names_the_step_count_the_measurement_disproved',
            !Object.keys(PROMPTS).some((k) => /roughly 80 tool calls/.test(PROMPTS[k] || '')))
          report('G52_a_partial_is_told_to_hand_over_what_it_learned',
            /what you LEARNED/.test(PROMPTS['test-suite:FM-12:e2e'] || ''))
        }
      }
    } else if (SCENARIO === 'G53') {
      // A re-invoked run does not re-run its agents: the runtime memoises every completed agent()
      // call and serves it back, keyed on the prompt and the options. That is right for a step that
      // PRODUCES something and wrong for a step that READS THE WORLD, because a probe's answer is
      // a function of the repo, the forge and the tracker at the moment it runs — and none of that
      // is in the key. Measured on one ticket: a run reported "branch base OK, nothing on top" three
      // and a half hours after four commits landed, and the next day's run halted on a foreign
      // commit two minutes after a person rebased it away. So the property under test is about the
      // BRIEF, which is the only half of that key this workflow writes: a probe's brief must differ
      // between two invocations, and a producing step's must not.
      const ARGS = 'FM-12'
      const PROBE = /^(run-state|base-reconcile|target-gate|approval-probe|human-probe|human-verify|audit):/
      const FRESH = /FRESH READING REQUIRED/
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: ['db/src/x.ts'] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12:db': { approved: true },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { summary_path: 'x.md', token_table_appended: true, note: 'ok' },
      }
      // The stamp is passed IN, because the script may not mint one: Claude Code rejects a
      // workflow script containing Date.now()/new Date()/Math.random() at compile time. Two
      // invocations therefore look exactly like this — same ticket, a fresh --invocation each.
      await runOnce(`${ARGS} --invocation i1`, canned, {})
      const first = { ...PROMPTS }
      await runOnce(`${ARGS} --invocation i2`, canned, {})
      const second = { ...PROMPTS }
      const differs = (k) => !!first[k] && !!second[k] && first[k] !== second[k]
      report('G53_the_branch_base_probe_is_asked_again_on_the_next_invocation', differs('base-reconcile:FM-12:db'))
      // The loader is the one that must never be memoised: it exists to re-validate every checkpoint
      // against the live branches, and it is also where the run reads its own ordinal. Answered from
      // a memo, every `degraded` flag describes a world that has moved and RUN_SEQ stops advancing.
      report('G53_the_run_state_loader_is_asked_again_too', differs('run-state:FM-12'))
      const probes = Object.keys(second).filter((k) => PROBE.test(k))
      const unstamped = probes.filter((k) => !FRESH.test(second[k] || ''))
      report('G53_every_live_state_probe_is_told_to_read_the_world_now', probes.length > 0 && unstamped.length === 0, `missing: ${unstamped.join(', ')}`)
      // The other half of the fix, and the half a careless widening would destroy: replaying a
      // finished build is what a resume is FOR. A producing step's brief has to stay byte-identical
      // across invocations or the memo stops paying and every re-run costs full price.
      const same = (k) => !!first[k] && first[k] === second[k]
      const producing = Object.keys(second).filter((k) => !PROBE.test(k))
      const drifted = producing.filter((k) => !same(k))
      report('G53_a_producing_step_keeps_its_memo_across_invocations', producing.length > 0 && drifted.length === 0, `drifted: ${drifted.join(', ')}`)
    } else if (SCENARIO === 'G42_FP') {
      // Fingerprint probe, same idiom as G11_FP: a `planned` row is skippable only when it carries
      // THIS run's fp, so the assertion run needs the value this one logs.
      await runOnce(ARGS, {
        ...BASE,
        'resolve-runtime-config': { language: 'en', plan_to_html: false, auto_approve: false, artifacts_enabled: false },
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }], test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
      })
      const fpLine = LINES.find((l) => /fp=([0-9a-f]+)/.test(l))
      const fp = fpLine ? fpLine.match(/fp=([0-9a-f]+)/)[1] : null
      report('G42_FP_fingerprint_logged', !!fp)
      if (fp) console.log(`FP=${fp}`)
      // The row must be TOLD to carry the pins, or there is nothing to read back on the resume.
      report('G42_planned_row_records_the_pins', /"submodule_pins":/.test(PROMPTS['kickoff:FM-12:e2e'] || ''))
    } else if (SCENARIO === 'G42') {
      // A RESUMED invocation reuses each plan from its `planned` run-state row instead of re-planning.
      // `submodule_pins` lives only on a live planner result, so the rehydrated plan dropped it and
      // the whole wave ordering silently stopped firing from run 2 onward — the mechanism working
      // exactly once per ticket, on the run least likely to need it. The row carries it now.
      const scope42 = { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
        repos: [{ repo: 'db' }, { repo: 'e2e', depends_on: ['db'] }], test_suite: { needed: true }, tracker_reachable: true }
      const plannedRow = (repo, pins) => runStateRow(repo, 'planned', {
        ticket_fp: FP, plan_path: `/tmp/ws/${repo}/plan.md`, plan_bytes: 4096, title: 'T', acceptance: ['A1'],
        ...(pins ? { submodule_pins: pins } : {}),
      })
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [plannedRow('db'), plannedRow('e2e', [{ repo: 'db', path: 'vendor/db' }])] },
        'scope:FM-12': scope42,
        'plan-guard:FM-12': planGuardOk(['db', 'e2e']),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'specs', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/1', pr_number: 1 },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/2', pr_number: 2 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12': { approved: true },
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '5 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'posted' },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { path: 'x.md' },
      }
      const result = await runOnce(ARGS, canned)
      report('G42_no_planner_respawned', !SPAWNED.some((l) => l.startsWith('kickoff:')))
      report('G42_pin_survives_the_resume', SPAWNED.indexOf('build:FM-12:db') < SPAWNED.indexOf('build:FM-12:e2e'))
      report('G42_pin_targets_the_pushed_branch', (PROMPTS['build:FM-12:e2e'] || '').includes('PUSHED earlier in this run'))
      report('G42_upstream_still_told_to_push', /PUSH BEFORE YOU HAND OFF/.test(PROMPTS['build:FM-12:db'] || ''))
      report('G42_repin_ship_step_is_emitted', JSON.stringify(result?.shipSteps || []).includes('submodule-repin'))
    } else if (SCENARIO === 'G41') {
      // One pin must not serialize an unrelated depends_on chain. db+svc+app is a depends_on chain and
      // e2e pins db; the merge waves would give three sequential build waves for one real edge. Only
      // the pin graph orders the build, so this is TWO waves: everything, then e2e.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }, { repo: 'app', depends_on: ['svc'] }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc', 'app', 'e2e']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': { ...REPO_PLAN('e2e', 'main'), submodule_pins: [{ repo: 'db', path: 'vendor/db' }] },
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'build:FM-12:app': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'specs', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/1', pr_number: 1 },
        'open-pr:FM-12:svc': { pr_url: 'https://x/2', pr_number: 2 },
        'open-pr:FM-12:app': { pr_url: 'https://x/3', pr_number: 3 },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/4', pr_number: 4 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'review:FM-12:svc#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'review:FM-12:app#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'guard:FM-12:app#1': { approved: true, tests_green: true, comments: [] },
        'perf:FM-12:app#1': { approved: true, tests_green: true, comments: [] },
        'approve:FM-12': { approved: true },
        'test-suite:FM-12:e2e': { passed: true, receipt: { command: 'x', exit_code: 0, summary_line: '5 passed' } },
        'audit:FM-12:e2e': { posted: true, detail: 'posted' },
        'notify:FM-12': { sent: true },
        'summary:FM-12': { path: 'x.md' },
      }
      await runOnce(ARGS, canned)
      // The three code repos share wave 1 despite a full depends_on chain; only the pinned edge waits.
      const iDb = SPAWNED.indexOf('build:FM-12:db'), iSvc = SPAWNED.indexOf('build:FM-12:svc')
      const iApp = SPAWNED.indexOf('build:FM-12:app'), iE2e = SPAWNED.indexOf('build:FM-12:e2e')
      report('G41_depends_on_chain_is_not_serialized', iDb >= 0 && iSvc >= 0 && iApp >= 0 && Math.max(iDb, iSvc, iApp) < iE2e)
      report('G41_pinned_repo_waits', iE2e > iDb)
      report('G41_pin_still_targets_the_pushed_branch', (PROMPTS['build:FM-12:e2e'] || '').includes('PUSHED earlier in this run'))
    } else if (SCENARIO === 'G38') {
      // The wave ran is NOT the same as the wave pushed. A `build-unresolved` upstream handed back
      // no complete state, so its branch may hold nothing and may never have reached the remote —
      // pinning to it aims the pointer at a commit that does not exist, and fails deep inside the
      // downstream's harness instead of here. It must fall back to the merged base.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': { ...REPO_PLAN('svc', 'develop'), submodule_pins: [{ repo: 'db', path: 'vendor/db' }] },
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'stuck', status: 'blocked', remaining: 'liquibase would not run' },
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'open-pr:FM-12:svc': { pr_url: 'https://x/8', pr_number: 8 },
        'review:FM-12:svc#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'summary:FM-12': { path: 'x.md' },
      }
      await runOnce(ARGS, canned)
      const svcBuild = PROMPTS['build:FM-12:svc'] || ''
      report('G38_downstream_still_builds', SPAWNED.includes('build:FM-12:svc'))
      report('G38_does_not_pin_to_an_unpushed_branch', !svcBuild.includes('PUSHED earlier in this run'))
      report('G38_falls_back_to_the_merged_base', /db.*→ origin\/develop \(not built this run/.test(svcBuild))
    } else if (SCENARIO === 'G36' || SCENARIO === 'G37') {
      // SUBMODULE PIN ORDERING. G36: `svc` vendors `db` at "vendor/db", so db must build (and push)
      // in an EARLIER wave, and svc's pin target must be db's pushed BRANCH, not db's merged base —
      // the difference between svc doing its work this round and stalling until the next one.
      // G37: the same two repos with NO pin declared keep today's single fully-parallel wave, so the
      // ordering costs nothing on the tickets that do not need it.
      const pinned = SCENARIO === 'G36'
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc', depends_on: ['db'] }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': { ...REPO_PLAN('svc', 'develop'), ...(pinned ? { submodule_pins: [{ repo: 'db', path: 'vendor/db' }] } : {}) },
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'migration', status: 'complete', fixed: [] },
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'open-pr:FM-12:svc': { pr_url: 'https://x/8', pr_number: 8 },
        'review:FM-12:db#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'review:FM-12:svc#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12': { approved: true },
        'summary:FM-12': { path: 'x.md' },
      }
      await runOnce(ARGS, canned)
      const svcBuild = PROMPTS['build:FM-12:svc'] || ''
      const dbBuild = PROMPTS['build:FM-12:db'] || ''
      if (pinned) {
        // The upstream's whole build must be finished before the downstream's is even spawned —
        // "started first" is not enough, the commit has to be on the remote.
        report('G36_upstream_builds_before_downstream', SPAWNED.indexOf('build:FM-12:db') < SPAWNED.indexOf('build:FM-12:svc'))
        report('G36_upstream_told_to_push', /PUSH BEFORE YOU HAND OFF/.test(dbBuild) && dbBuild.includes('push -u origin feature/FM-12'))
        report('G36_pin_targets_the_pushed_branch', svcBuild.includes('origin/feature/FM-12') && svcBuild.includes('PUSHED earlier in this run'))
        report('G36_pin_not_capped_at_the_merged_base', !/db → origin\/develop \(not built this run/.test(svcBuild))
        report('G36_pin_names_the_real_submodule_path', svcBuild.includes('db (at "vendor/db")'))
        report('G36_downstream_not_told_to_push_for_a_pin', !/PUSH BEFORE YOU HAND OFF/.test(svcBuild))
        report('G36_reviewer_told_the_unmerged_pin_is_intended', /SUBMODULE PIN, already decided/.test(PROMPTS['review:FM-12:svc#1'] || ''))
      } else {
        report('G37_no_pin_no_push_obligation', !/PUSH BEFORE YOU HAND OFF/.test(dbBuild))
        report('G37_pin_stays_capped_at_the_merged_base', /db.*→ origin\/develop \(not built this run/.test(svcBuild))
        report('G37_reviewer_gets_no_pin_note', !/SUBMODULE PIN, already decided/.test(PROMPTS['review:FM-12:svc#1'] || ''))
      }
    } else if (SCENARIO === 'G32' || SCENARIO === 'G33') {
      // ALREADY-SATISFIED — a repo whose criteria are met by code that shipped before this ticket.
      // G32: the verifier upholds it, so `db` leaves the run with no branch, no PR/MR and nothing to
      // merge, while `svc` proceeds normally — the run must NOT stop, and must NOT try to open a PR
      // or review the repo that has no diff. G33: the same handoff, refused by the verifier, must
      // land back on the old road — 'partial', which stops the repo.
      const CITED = [
        { criterion: 'A1: the warning renders for a flagged provider', commit: 'a1b2c3d', path_line: 'db/src/warn.ts:42', quote: 'if (provider.timeout_ban_warning) return <Warning/>  // generic, flag-driven' },
      ]
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }, { repo: 'svc' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db', 'svc']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'kickoff:FM-12:svc': REPO_PLAN('svc', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'nothing to do', status: 'already-satisfied', satisfied_by: CITED },
        'build:FM-12:svc': { work_branch: 'feature/FM-12', summary: 'ok', status: 'complete', fixed: [] },
        'verify-satisfied:FM-12:db': { upheld: SCENARIO === 'G32', reason: SCENARIO === 'G32' ? 'all four checks hold' : 'A2 is uncited and the generic path does not cover it — db/src/route.ts', checked: ['git show a1b2c3d'] },
        'open-pr:FM-12:svc': { pr_url: 'https://x/8', pr_number: 8 },
        'review:FM-12:svc#1': { approved: true, tests_green: true, tests_receipt: 'ok', comments: [], resolved_threads: [], still_open: [] },
        'approve:FM-12': { approved: true },
        'summary:FM-12': { path: 'x.md' },
      }
      const result = await runOnce(ARGS, canned)
      if (SCENARIO === 'G32') {
        report('G32_verifier_adjudicated_the_claim', SPAWNED.includes('verify-satisfied:FM-12:db'))
        report('G32_no_pr_opened_for_the_satisfied_repo', !SPAWNED.includes('open-pr:FM-12:db'))
        report('G32_no_review_for_the_satisfied_repo', !SPAWNED.some((l) => l.startsWith('review:FM-12:db')))
        report('G32_run_does_not_stop', !!result && result.status !== 'repo-unresolved' && result.status !== 'nothing-delivered')
        report('G32_other_repo_proceeds', SPAWNED.includes('open-pr:FM-12:svc'))
        // The verifier is told the one thing that broke this before: an empty branch is the
        // EXPECTED shape here, so commit count must not be the test.
        report('G32_brief_forbids_the_commit_count_test', /DO NOT REJECT ON COMMIT COUNT/.test(PROMPTS['verify-satisfied:FM-12:db'] || ''))
        report('G32_brief_demands_full_coverage', /THE LIST IS COMPLETE/.test(PROMPTS['verify-satisfied:FM-12:db'] || ''))
      } else {
        report('G33_rejected_claim_stops_the_repo', !!result && result.status === 'repo-unresolved')
        report('G33_still_no_pr_for_it', !SPAWNED.includes('open-pr:FM-12:db'))
        report('G33_reason_reaches_the_handoff', JSON.stringify(result?.handoffs || result || '').includes('downgraded to'))
      }
    } else if (SCENARIO === 'G34' || SCENARIO === 'G35') {
      // G34 — EVERY scoped repo already satisfied. That is a clean ending of its own: the ticket was
      // done before the run started. It must NOT be reported as `nothing-delivered` (ADR 0011),
      // which is the opposite finding, and it must not fall through to a merge phase with no repos.
      // G35 — the structural bar, before any agent is paid for: a claim with no usable citation is
      // refused outright, and the verifier is never spawned.
      const GOOD = [{ criterion: 'A1', commit: 'a1b2c3d', path_line: 'db/src/warn.ts:42', quote: 'if (provider.timeout_ban_warning) return <Warning/>' }]
      const JUNK = [{ criterion: 'A1', commit: 'the last release', path_line: 'somewhere in the UI', quote: 'it works' }]
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'nothing to do', status: 'already-satisfied', satisfied_by: SCENARIO === 'G34' ? GOOD : JUNK },
        'verify-satisfied:FM-12:db': { upheld: true, reason: 'holds', checked: [] },
        'summary:FM-12': { path: 'x.md' },
      }
      const result = await runOnce(ARGS, canned)
      if (SCENARIO === 'G34') {
        report('G34_its_own_ending', !!result && result.status === 'already-satisfied')
        report('G34_not_reported_as_nothing_delivered', !!result && result.status !== 'nothing-delivered')
        report('G34_carries_the_citations_out', JSON.stringify(result?.satisfied || []).includes('a1b2c3d'))
        report('G34_names_the_decision', /Close the ticket/.test(result?.decision_needed || ''))
        report('G34_nothing_merged_or_opened', !SPAWNED.some((l) => l.startsWith('open-pr:') || l.startsWith('approve:')))
      } else {
        report('G35_unusable_citation_costs_no_verifier', !SPAWNED.includes('verify-satisfied:FM-12:db'))
        report('G35_repo_stops', !!result && result.status === 'repo-unresolved')
      }
    } else if (SCENARIO === 'G31') {
      // ADR-0029 — the SIBLINGS of the near-miss. Removing the abort `return` promoted every return
      // below it into a new reachable state, and those were written when "a repo was not ready"
      // could not be true — so each would end the run having DROPPED the recorded blocking items.
      // Dropped items means no `blocked` rows, which re-opens the cross-invocation fail-open
      // ADR-0027 §Across invocations closed. This drives the budget-stop one (both it and
      // `nothing-delivered` thread the same `abortFields()`); the assertion that matters is that the
      // rows still get written on the way out.
      const SUITE_DOWN = { approved: false, tests_green: false, gate_unavailable: true, unavailable_reason: 'docker daemon unreachable', comments: [], conclusion: 'suite did not run' }
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'app' }, { repo: 'e2e', depends_on: ['app'] }],
          test_suite: { needed: true }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['app', 'e2e']),
        'kickoff:FM-12:app': REPO_PLAN('app', 'develop'),
        'kickoff:FM-12:e2e': REPO_PLAN('e2e', 'main'),
        'build:FM-12:app': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] },
        'build:FM-12:e2e': { work_branch: 'feature/FM-12', summary: 'specs', status: 'complete', fixed: [] },
        'open-pr:FM-12:app': { pr_url: 'https://x/11', pr_number: 11 },
        'open-pr:FM-12:e2e': { pr_url: 'https://x/13', pr_number: 13 },
        'summary:FM-12': { summary_path: '/tmp/x.md', token_table_appended: true, note: 'ok' },
        'dm:FM-12:budget-stopped': { sent: true },
      }
      for (let n = 1; n <= 4; n++) {
        canned[`review:FM-12:app#${n}`] = SUITE_DOWN
        canned[`perf:FM-12:app#${n}`] = { passed: true, blocking: [] }
        canned[`pr-fix:FM-12:app#${n}`] = { work_branch: 'feature/FM-12', summary: 'tried', status: 'complete', fixed: ['app/x'], commits: 1 }
      }
      // Spend jumps once phase('Build') has fired ⇒ the Test-suite boundary is the first check to
      // trip, which is exactly the newly reachable return.
      const result = await runOnce(ARGS, canned, { spendJumpAfterPhase: 'Build' })
      const sp = PROMPTS['summary:FM-12'] || ''
      report('G31_stops_on_the_budget_not_the_repo', !!result && result.status === 'budget-stopped' && result.stopped_before === 'Test suite', `got=${result && result.status}/${result && result.stopped_before}`)
      report('G31_records_are_not_dropped_on_the_way_out', ((result && result.blockingByRepo) || []).flatMap((b) => b.items).some((i) => i.kind === 'suite-unverified'),
        `got=${JSON.stringify(((result && result.blockingByRepo) || []).flatMap((b) => b.items.map((i) => i.kind)))}`)
      report('G31_blocked_row_is_still_written', sp.includes('app-blocked.json') && sp.includes('"status":"done"') && sp.includes('suite-unverified'))
      report('G31_gate_never_ran', !SPAWNED.some((l) => l.startsWith('test-suite:')))
      report('G31_nothing_approved', !SPAWNED.some((l) => l.startsWith('approve:')))
    } else if (SCENARIO === 'G17') {
      // R12 — writeSummary used to write ONE fixed path with Write, so every invocation destroyed
      // the previous round's summary. That is why one postmortem's timeline had to be rebuilt from
      // a chat log instead of the repo. Each invocation now also keeps its own numbered file.
      const canned = {
        ...BASE,
        'run-state:FM-12': { rows: [] },
        'scope:FM-12': { ticket: 'FM-12', title: 'T', type: 'feature', acceptance: ['A1'],
          repos: [{ repo: 'db' }], test_suite: { needed: false }, tracker_reachable: true },
        'plan-guard:FM-12': planGuardOk(['db']),
        'kickoff:FM-12:db': REPO_PLAN('db', 'develop'),
        'build:FM-12:db': { work_branch: 'feature/FM-12', summary: 'built', status: 'complete', fixed: [] },
        'open-pr:FM-12:db': { pr_url: 'https://x/7', pr_number: 7 },
        'notify:FM-12': { sent: true },
      }
      await runOnce(ARGS, canned)
      const sp = PROMPTS['summary:FM-12'] || ''
      report('G17_per_invocation_summary_written', sp.includes('FM-12-DEV-CYCLE-SUMMARY-r1.md'))
      report('G17_latest_pointer_still_written', sp.includes('FM-12-DEV-CYCLE-SUMMARY.md'))
      report('G17_budget_unit_stated_as_output_tokens', sp.includes('OUTPUT tokens') && sp.includes('29x'))
      report('G17_per_ticket_total_reported', sp.includes('across r1..r1'))
    } else {
      throw new Error('unknown scenario ' + SCENARIO)
    }
  } catch (e) {
    report(`scenario-${SCENARIO}_crashed`, false, String((e && e.stack) || e).split('\n')[0])
    process.exitCode = 1
  }
  // DUMP_LINES=1 prints the run's own log and the labels it spawned. A failing assertion here says
  // only "false", and the interesting question is always what the loop actually did.
  if (process.env.DUMP_LINES) {
    console.log('--- LOG ---'); LINES.forEach((l) => console.log(l))
    console.log('--- SPAWNED ---'); console.log(SPAWNED.join('\n'))
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

echo "── G1b — upstream-degrade also un-freezes the review ledger (C2)"
out="$(run_scenario G1B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

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

echo "── G13 — notify is idempotent (docs/adr/0018): a resumed run does not re-send the digest"
out="$(FIXTURE_NOTIFY_DM=U012345 run_scenario G13)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G14 — the DM is idempotent per run_status: the SAME ending does not re-DM on resume"
out="$(FIXTURE_NOTIFY_DM=U012345 run_scenario G14)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G15 — a NEW ending status still DMs despite an older status' dm_sent row"
out="$(FIXTURE_NOTIFY_DM=U012345 run_scenario G15)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G7 — gate-only build (C1)"
out="$(run_scenario G7)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8a — review ledger (ADR 0021): a passed gate is frozen, loop skipped with no 'reviewed' row"
out="$(run_scenario G8A)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8b — review ledger: first pass on record resumes as RE-VISIT, not a second first review"
out="$(run_scenario G8B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8c — no ledger: genuine first pass, brief carries tag + resolve + checkpoint contracts"
out="$(run_scenario G8C)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8d — an unresolved \`Human:\` directive VETOES the skip (human-review.md), re-visit not re-review"
out="$(run_scenario G8D)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8e — a BLIND \`Human:\` probe is not 'no directives': the skip is vetoed too"
out="$(run_scenario G8E)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8f — a directive still open at the end is RECORDED, never reported ready"
out="$(run_scenario G8F)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G8g — a vetoed skip on a 'reviewed' row RE-VISITS; it never re-derives a first review"
out="$(run_scenario G8G)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

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

echo "── G16a — a PR/MR targeting the wrong branch halts the repo (ADR 0025)"
out="$(run_scenario G16a)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G16b — two open PR/MRs for one repo halts too; closing one stays human"
out="$(run_scenario G16b)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G16c — a repaired target is re-read and the run continues"
out="$(run_scenario G16c)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G16d — an assert that did not converge is not a pass"
out="$(run_scenario G16d)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G18a — an unchanged failure signature is briefed to re-derive, not re-confirm"
out="$(run_scenario G18a)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G18b — a signature that MOVED is progress, and gets no such directive"
out="$(run_scenario G18b)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G19a — a suite that could not run becomes a must-fix, then a recorded blocking item"
out="$(run_scenario G19a)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G19b — a fix-caused regression is handed straight back instead of halting"
out="$(run_scenario G19b)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G19c — a stall escalates the attempt rather than repeating or halting"
out="$(run_scenario G19c)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G19d — an EVIDENCED 'cannot' closes that condition's attempts early"
out="$(run_scenario G19d)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G19e — an UNEVIDENCED 'cannot' is dropped and the attempts continue"
out="$(run_scenario G19e)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G20a — a prereq red is routed to a developer instead of ticking a round away"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G20a)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G20b — an automation red is routed to the suite repo that owns the spec"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G20b)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G21a — an EVIDENCED 'cannot' on one red ends its attempts; the sibling is still worked"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G21a)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G21b — an UNEVIDENCED 'cannot' is dropped and the attempts continue"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G21b)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G22 — an unrunnable gate routes to a developer, then records; never a pass"
out="$(FIXTURE_TS_MAX_REPAIR=2 run_scenario G22)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G23 — a load regression that stands is recorded, and a green suite is still not a pass"
out="$(run_scenario G23)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G24 — the one retraction: a later CLEARED check on the same case drops its record"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G24)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G25 — an app red naming an out-of-scope repo is recorded, never misrouted"
out="$(FIXTURE_TS_MAX_FIX_ROUNDS=2 run_scenario G25)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G26 — a carried blocking item survives the resume and reaches the developer"
out="$(run_scenario G26)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G27 — a CLEARED blocked row is ignored, so a resolved repo still resumes for free"
out="$(run_scenario G27)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G28 — a carried item vetoes the suite-gate skip too, whatever the test_suite row says"
out="$(run_scenario G28)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G29 — the gate runs advisory when every unresolved repo is review-unresolved"
out="$(FIXTURE_TS_MAX_REPAIR=1 run_scenario G29)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G30 — and does NOT run when the candidate is unfit to measure"
out="$(FIXTURE_TS_MAX_REPAIR=1 run_scenario G30)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G31 — a return newly reachable past the abort point still carries the records out"
out="$(FIXTURE_TS_MAX_REPAIR=1 FIXTURE_TOKEN_BUDGET=1000000 run_scenario G31)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G39 — a satisfied repo is finished: not a blocker, and never an escalation target"
out="$(run_scenario G39)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G39B — …and an escalation aimed at it is refused and recorded, never routed"
out="$(run_scenario G39B)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G40 — no code candidate means the requested gate does not run and is not reported as a pass"
out="$(run_scenario G40)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G44 — the last non-budget stops: scope, open-PR and a missing plan all get one re-ask"
for s in G44_SCOPE G44_SCOPE_DEAD G44_PR G44_REPLAN G44_REPLAN_DEAD; do
  out="$(run_scenario $s)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"
done

echo "── G43 — a partial build is CONTINUED to a finish, not stopped at attempt one"
out="$(run_scenario G43)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G43_EXHAUST — and when it never finishes, the BOUND is what stops it, recorded"
out="$(run_scenario G43_EXHAUST)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G43_STALL — a pass that moved nothing escalates the brief instead of repeating it"
out="$(run_scenario G43_STALL)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G43_DECLINE — an evidenced cannot_fix ends the passes rather than burning the budget"
out="$(run_scenario G43_DECLINE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G45_OK — a branch that already stands on the run's base is probed and otherwise untouched"
out="$(run_scenario G45_OK)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G45 — a base repair is its own accounted step, not the build round's first slice"
out="$(run_scenario G45)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G45_UNREPAIRABLE — a branch carrying both the ticket's commits and foreign ones is refused"
out="$(run_scenario G45_UNREPAIRABLE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G45_FLAKE — a probe that returns nothing proceeds unchecked, and its reason is captured"
out="$(run_scenario G45_FLAKE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G45_RESUMED — a build that is skipped does not pay to re-probe the base it already stands on"
out="$(run_scenario G45_RESUMED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G48 — a build cut off from outside is recorded with its reason, not silently re-run"
out="$(run_scenario G48)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G48_RUNAWAY — a build that returns nothing for its own reasons is recorded, but not as a cut-off"
out="$(run_scenario G48_RUNAWAY)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G48_SALVAGED — a cut-off the bounded continuation recovers records nothing and carries on"
out="$(run_scenario G48_SALVAGED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G49 — a build is told to commit as it goes, and a relaunch is told what the last attempt landed"
out="$(run_scenario G49)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G49_CLEAN — a branch with nothing on it is not told it carries prior work"
out="$(run_scenario G49_CLEAN)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G50/G51/G52 — every brief carries the cut-off rule, the return rule, and the context (not turn) rule it is measured in"
out="$(run_scenario G50)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G50_ROLES/G51/G52 — all three rules reach the planner and reviewer briefs that bypass the wrapper"
out="$(run_scenario G50_ROLES)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G50_CUT/G51 — a QA gate ended from outside is told to the next agent, whose ask is NARROWED"
out="$(run_scenario G50_CUT)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G53 — a probe of live state is re-asked on the next invocation; a producing step keeps its memo"
out="$(run_scenario G53)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G54 — the branch-base probe reports what it read; the workflow decides what a person runs"
out="$(run_scenario G54_BRIEF)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G54 — the rebase handed to a person drops the foreign commits and saves the branch first"
out="$(run_scenario G54)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G54 — an interleaved history gets a replay, not a boundary that would swallow ticket commits"
out="$(run_scenario G54_INTERLEAVED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G54 — a repair that dropped the ticket's own commits is caught, not reported as success"
out="$(run_scenario G54_LOST)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G55 — a scope that names no registered repo is asked once more before the run ends"
out="$(run_scenario G55)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G55 — a second non-answer still stops the run"
out="$(run_scenario G55_TWICE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G46 — a declared false red confirmed on the base is recorded, not retried"
out="$(run_scenario G46)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G46_PARTIAL — a round that still owes real work is continued, and told not to chase the flake"
out="$(run_scenario G46_PARTIAL)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G46_GENUINE — a check that passes on the base is a regression, and today's behaviour stands"
out="$(run_scenario G46_GENUINE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G46_NO_MATCH — a failure no declared entry covers is judged on its own evidence, as before"
out="$(run_scenario G46_NO_MATCH)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G46_UNDECLARED — a repo that declares no false reds pays for no screen at all"
out="$(run_scenario G46_UNDECLARED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G46_FLAKE — a screen that returns nothing charges the round exactly as before"
out="$(run_scenario G46_FLAKE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G47 — a declared false red at REVIEW is screened once and recorded, not ground at for every round"
out="$(FIXTURE_RV_MAX_ROUNDS=3 run_scenario G47)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G47_GENUINE — a red that passes on the base is this diff's regression, and the loop works it as before"
out="$(FIXTURE_RV_MAX_ROUNDS=3 run_scenario G47_GENUINE)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G47_UNDECLARED — a repo that declares no false reds pays for no screen at review either"
out="$(FIXTURE_RV_MAX_ROUNDS=3 run_scenario G47_UNDECLARED)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G42 — the pin survives a resume, and the required re-pin ships even with auto-merge off"
outFp42="$(run_scenario G42_FP)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$outFp42" | sed 's/^/      /'; ingest "$outFp42"
FP42="$(grep -o 'FP=[0-9a-f]\+' <<<"$outFp42" | head -1 | cut -d= -f2)"
if [[ -n "$FP42" ]]; then pass "G42_fingerprint_scraped (fp=$FP42)"; else fail "G42_fingerprint_scraped — could not scrape fp= from the probe run"; fi
out="$(FP="$FP42" run_scenario G42)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G41 — one pin orders one edge, not a whole depends_on chain"
out="$(run_scenario G41)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G38 — a wave that RAN is not a wave that pushed: an unresolved upstream keeps the safe pin"
out="$(run_scenario G38)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G36 — a submodule-pinned upstream builds and pushes first; the downstream pins to that tip"
out="$(run_scenario G36)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G37 — and with no pin declared, the build stays one fully-parallel wave"
out="$(run_scenario G37)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G32 — a verified already-satisfied repo leaves the run; the rest of the change set proceeds"
out="$(run_scenario G32)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G33 — and a refused claim lands back on 'partial', which stops the repo"
out="$(run_scenario G33)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G34 — every repo already satisfied is its own ending, not 'nothing delivered'"
out="$(run_scenario G34)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G35 — an unusable citation is refused before a verifier is ever paid for"
out="$(run_scenario G35)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo "── G17 — each invocation keeps its own summary, and the budget unit is stated honestly"
out="$(run_scenario G17)"; [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'; ingest "$out"

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
