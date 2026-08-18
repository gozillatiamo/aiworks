export const meta = {
  name: 'dev-cycle',
  description: 'Full development cycle for one ticket — MULTI-REPO. Scopes which repos a ticket touches, runs each through plan→build→PR/MR→review in dependency WAVES, validates the candidate with the cross-repo test-suite (QA) gate, MERGES upstream→downstream, then distributes the merged build, and summarizes. Provider-agnostic: VCS via scripts/vcs/ (github/gitlab), tracker via scripts/tracker/ (notion/jira). The WORKFLOW owns the ticket status (monotonic, decoupled from the per-repo agents). Pass the ticket number as args, e.g. "FM-12". A single-repo ticket collapses to a one-repo flow.',
  whenToUse: 'Run one <KEY> ticket end to end across every repo it touches — through review, the cross-repo test-suite gate, the merge, and distribution — with a single command.',
  phases: [
    { title: 'Scope', detail: 'cto: classify which repos the ticket touches + dependency order + whether the cross-repo test-suite (QA) gate applies', model: 'opus' },
    { title: 'Kickoff', detail: 'per repo: development-planner runs /ticket-kickoff (code) · qa-planner designs the test plan + automation plan (test-suite repo) → branch + plan. The WORKFLOW moves the ticket to in_progress (per-repo agents no longer touch status). If planning.to_html, each plan is also rendered to interactive HTML; if planning.auto_approve is off, the run STOPS here for human plan approval (re-run with --approve-plan).', model: 'opus' },
    { title: 'Build', detail: 'ALL scoped repos in parallel (build-order decoupled from merge-order — a build needs only the agreed contract, not a merged upstream; depends_on is still honored at Merge, upstream→downstream): the build role implements (developer TDD / qa-runner POM). No pre-PR gate — guardian/perf review on the OPEN PR/MR (Review). The test-suite repo iterates SCOPED (`scripts/dev.sh test <spec>`) then runs the ticket scope — its spec(s) + regression scope — before the PR/MR.', model: 'sonnet/opus' },
    { title: 'Open PR', detail: 'build role opens the PR/MR right AFTER build, BEFORE review, via scripts/vcs/open-pr.sh, so every reviewer comments on the open PR/MR. Open only, never merge.', model: 'sonnet' },
    { title: 'Review', detail: 'on the OPEN PR/MR: code-reviewer (standards+spec, AND runs the repo suite — approval is gated on a green receipt; a suite that cannot run halts the repo rather than failing open) + guardian (quality gate) + performance ALL review, commenting via scripts/vcs/pr-comment.sh, FREEZE-once-passed; dev fixes the combined batch. First review is one COMPLETE pass per reviewer; every later round RE-VISITS only that reviewer\'s own findings (raise nothing new) — except a fix-CAUSED regression, which HALTS the repo loudly for human action; round cap. SKIPPED for the test-suite repo (no reviewers). When all repos pass, the WORKFLOW moves the ticket to ready_to_merge (or ready_to_test).', model: 'sonnet' },
    { title: 'Test suite', detail: 'qa-runner: build the CANDIDATE (the ticket\'s work branches, PRE-merge) and run THIS ticket\'s scope — its spec(s) + regression scope (the dev\'s "⚠️ Regression request" recap), SCOPED via `scripts/dev.sh test <specs>`, NOT the full suite, then reports the per-TC results to the ticket WITH the run\'s own screenshots embedded. The cross-repo QA gate (E2E / API / load) that must pass BEFORE the merge. NEVER fails open: the verdict needs a receipt (real command + exit code + summary line) AND a second agent must find the result comment on the ticket — otherwise the gate is recorded as NOT RUN, not as a pass, and nothing merges. A repo declared `suite_kind: load` must additionally be equal-or-better than the same scenario on the ticket\'s base branch, judged against the environment\'s own measured noise floor, so its verdict is pass / fail / unavailable; a regression the developer ATTRIBUTES to the change loops back for a fix (attribute first, fix second) up to loadtest.max_fix_rounds. The WORKFLOW moves the ticket to testing. Skipped when no test-suite gate applies.', model: 'sonnet' },
    { title: 'Merge', detail: 'the commit gate (after review + the test-suite gate validate the candidate). The squash-merge is outward + irreversible, so under auto-mode only a human clears it: with vcs.auto_merge ON the workflow does NOT merge — it emits the exact `! …/merge-pr.sh` command (upstream→downstream) for the main session to present, then stops (status awaiting-human-ship). With auto-merge OFF the validated PR/MR is left OPEN and the run stops. Either way the run itself merges/distributes nothing.', model: 'sonnet[1m]' },
    { title: 'Distribute', detail: 'outward + irreversible like Merge, so also a human `!` step: the workflow emits the `! … firebase appdistribution:distribute …` command (a template the main session resolves) to run AFTER the merge lands; the main session then moves the ticket to done.', model: 'sonnet' },
    { title: 'Summary', detail: 'documentor writes the run-summary + per-repo/role token table (summarize-workflow-performance)', model: 'haiku' },
    { title: 'Notify', detail: 'OPTIONAL — only when notify.enabled AND auto-merge is off: post a "please review" digest of the open PR/MR per repo to the configured chat channel via the /notify skill (scripts/notify/). With auto-merge on, the run hands the merge/distribute to a human as `!` commands, so this phase is skipped.', model: 'haiku' },
  ],
}

// ──────────────────────────────────────────────────────────────────────────
// CONFIG  —  GENERATED FROM workspace.config.yaml BY scripts/aiworks. DO NOT EDIT THE
// MARKED BLOCK BELOW BY HAND. Workflow scripts have NO filesystem access, so they can't
// read workspace.config.yaml at runtime — this is the workflow's own MIRROR of it. To
// change it: edit workspace.config.yaml, then run `scripts/aiworks config` (or any
// `aiworks add` / `remove` / `sync`, which regenerate it for you). Anything you type
// between the AIWORKS:CONFIG markers is OVERWRITTEN on the next regenerate.
//
// TICKET_PREFIX — the ticket id prefix (drives the <PREFIX>-\d+ regex).      ← tracker.ticket_prefix
// STATUS        — EVERY status the org declares, canonical_key → REAL name.  ← tracker.statuses.*
//                 The workflow drives a monotonic SUBSET (see STATUS_ORDER / moveTicket);
//                 keys it doesn't emit are carried for humans/other tools.
// REPOS         — one entry per repo (derived from products[].repos[] + its kind):
//   path        — dir relative to the workspace launch root                 ← repos[].path (or repo name)
//   kind        — free-form dev-context label (frontend|backend|web-app|…); 'test-suite' selects
//                 the QA archetype, any other kind selects the code archetype.            ← repos[].kind
//   base        — branch a ticket targets: { feature, fix }                 ← branch_model (test-suite ⇒ fix base)
//   plan/build/review — agentTypes set by kind. review:null ⇒ no code review (test-suite repo); its
//                 PR/MR is merged by the build role (qa-runner) instead of a code-reviewer.
//   guard/perf  — whether the guardian / performance gate applies (by kind).
//   green       — the "keep it green" check phrase.                          ← kind default, or repos[].green
//   guardianFocus — repo-specific guardian checklist.                        ← kind default, or repos[].guardian_focus
//   testSuite   — true for the repo that PROVIDES the cross-repo test-suite gate (the QA repo).
//   distribute  — 'firebase' | 'custom' | null (how the merged build ships).  ← repos[].distribute
//   autoMerge   — OPTIONAL per-repo override of AUTO_MERGE.                   ← repos[].auto_merge
// AUTO_MERGE — vcs.auto_merge. true ⇒ after review + the test-suite gate validate the candidate, the
//   Merge phase EMITS the `!` merge command and Distribute the `!` distribute command for a human to
//   run in-session (the auto-mode classifier clears these outward steps ONLY for a human, never a
//   background agent), and the run stops (awaiting-human-ship). false ⇒ the run reviews + runs the
//   test-suite gate then STOPS, leaving the PR/MR OPEN for a human. Either way the run merges/distributes nothing itself.
// AUTO_APPROVE_PLAN — planning.auto_approve. false ⇒ after Kickoff the run STOPS for human plan
//   approval before build; re-run with --approve-plan to proceed. Like PLAN_TO_HTML this const is
//   only the FALLBACK DEFAULT: it is RE-RESOLVED at runtime (local-first) into RESOLVED_AUTO_APPROVE
//   below — the value the gate actually reads — so a personal workspace.config.local.yaml
//   `planning: auto_approve:` reaches a headless run too. It is the ONE control-flow key that takes a
//   personal override: skipping the plan gate is reversible (review + the test-suite gate + merge all
//   still stand between the plan and anything shipping). See docs/adr/0003.
// PLAN_TO_HTML — planning.to_html. true ⇒ planners ALSO render each plan to interactive HTML. This
//   const is only the FALLBACK DEFAULT: like LANGUAGE it is RE-RESOLVED at runtime (local-first) into
//   RESOLVED_PLAN_TO_HTML below — the value the run actually uses — so a personal
//   workspace.config.local.yaml `planning: to_html:` reaches a headless run too. It is an output
//   preference, not control flow; AUTO_MERGE, the status lifecycle and REPOS stay shared-only.
// NOTIFY / NOTIFY_PROVIDER / NOTIFY_CHANNEL — notify.{enabled,provider,channel}. When NOTIFY is
//   true AND AUTO_MERGE is false, the final Notify phase posts a "please review" digest (the open
//   PR/MR per repo) to NOTIFY_CHANNEL via the scripts/notify/ adapter. With auto-merge ON the run
//   hands the merge/distribute to a human as `!` commands, so there is nothing to review and the phase is skipped.
// DESIGN_ENABLED — design.enabled (the workspace-wide Figma switch). false ⇒ Figma is OFF: the
//   dev/QA agents do NOT call Figma — they build from the ticket spec, not a Figma screenshot
//   (see FIGMA_DIRECTIVE below and docs/agents/figma.md). The /prd-design design phase is what authors
//   Figma; this flag only governs the read-side here.
// QUALITY_GATE — quality_gate.provider (the guardian's static-analysis gate). 'none' ⇒ the
//   guardian gate is SKIPPED and auto-passes (no SonarQube attempt); 'sonarqube' ⇒ the guardian
//   runs the gate. Editing workspace.config.yaml requires `scripts/aiworks config` to refresh THIS
//   mirror (the workflow has no filesystem access to read the live config at runtime).
// REVIEW_LEVEL — review.level. 'strict' (default) ⇒ the Review phase (code-reviewer + guardian +
//   performance) reports ONLY must-fixes: no "[minor / fold-in]" comments, no Improvement tickets,
//   and fold_in items never hold the merge. 'thorough' ⇒ must-fixes PLUS nice-to-have (fold-ins
//   folded into the PR, Improvement tickets filed). See STRICT / levelDirective below.
// LANGUAGE — language (workspace output language). 'th' ⇒ English spine, Thai prose: every
//   prose-producing role gets LANGUAGE_DIRECTIVE appended (write prose in Thai; keep titles/
//   headings/labels + ALL code + commit messages + branch names + technical/domain terms English;
//   code & checked-in repo docs are never Thai). 'en' (default) ⇒ no directive. See docs/agents/language.md.
// ──────────────────────────────────────────────────────────────────────────
// Regenerate with `scripts/aiworks config`. NOTE this block is snapshotted TWICE: once here,
// and again when the engine persists a copy of this script per run — so a resumed run replays
// the config it started with, and a change made since is invisible to it. Change the config ⇒
// invoke the workflow BY NAME (a fresh run). Never edit a constant in a persisted run script:
// docs/agents/workflow-resume.md says why, and what it cost.
// >>> AIWORKS:CONFIG START — generated from workspace.config.yaml; do not edit by hand <<<
const TICKET_PREFIX = 'OFB'
const AUTO_MERGE = false        // from workspace.config.yaml vcs.auto_merge; per-repo override via REPOS[id].autoMerge
const AUTO_APPROVE_PLAN = false // from workspace.config.yaml planning.auto_approve; false ⇒ halt after Kickoff (re-run with --approve-plan)
const PLAN_TO_HTML = false     // from workspace.config.yaml planning.to_html; true ⇒ planners also render the plan to interactive HTML
const NOTIFY = true        // from workspace.config.yaml notify.enabled; true + AUTO_MERGE false ⇒ Notify phase posts a review-request
const NOTIFY_PROVIDER = 'slack' // from workspace.config.yaml notify.provider (scripts/notify/ adapter)
const NOTIFY_CHANNEL = '#dev-oneforbet'  // from workspace.config.yaml notify.channel; the chat channel the digest goes to
const DESIGN_ENABLED = false     // from workspace.config.yaml design.enabled; false ⇒ Figma OFF workspace-wide (dev/QA build from spec, not a Figma screenshot)
const QUALITY_GATE = 'none'     // from workspace.config.yaml quality_gate.provider; 'none' ⇒ guardian gate skips+passes (no SonarQube attempt)
const REVIEW_LEVEL = 'strict'     // from workspace.config.yaml review.level; 'strict' ⇒ Review gates report must-fixes ONLY (no fold-ins/Improvement tickets); 'thorough' ⇒ + nice-to-have
const LANGUAGE = 'en'     // from workspace.config.yaml language; 'th' ⇒ English spine, Thai prose (docs/agents/language.md; see LANGUAGE_DIRECTIVE below); 'en' ⇒ unchanged
const LOADTEST = {   // from workspace.config.yaml loadtest.*; read by the base-branch non-degradation gate (docs/agents/loadtest-gate.md)
  tolerancePct: 10,            // a metric may degrade this much before it counts as a regression
  noiseRuns: 2,                // base-vs-base runs used to measure the env's own run-to-run spread
  noiseCeilingMultiple: 2,     // noise floor above tolerancePct × this ⇒ verdict 'unavailable' (env too coarse to judge)
  maxFixRounds: 2,             // attributed-regression → developer fix → re-run loops before halting
  baselineCache: '~/.cache/aiworks/loadtest-baselines',
}
const STATUS = {
  to_do: 'TO DO',
  in_progress: 'IN PROGRESS',
  code_review: 'CODE REVIEW',
  ready_to_merge: 'READY TO MERGE',
  ready_to_test: 'READY TO TEST',
  testing: 'TESTING',
  done: 'DONE',
}
const REPOS = {
  'turnover-commission-batch': {
    path: 'turnover-commission-batch', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'agent-db': {
    path: 'agent-db', kind: 'migration',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'migrate passed successfully and rollback able',
    guardianFocus: 'secrets',
    distribute: null,
  },
  'paotung-template': {
    path: 'paotung-template', kind: 'web-app',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'tests via stroybook and lint passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'customization-widget': {
    path: 'customization-widget', kind: 'package',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'tests via stroybook and lint passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'front-end': {
    path: 'front-end', kind: 'web-app',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'tests via stroybook and lint passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'agent-webservice': {
    path: 'agent-webservice', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection, input validation',
    knownFalseReds: 'a full cargo test run is non-deterministic because the suite shares one test database, so an unrelated test can fail on ordering or leftover rows; re-run the scoped test in isolation against the base branch before calling it a real failure',
    distribute: null,
  },
  'agent-paotung-cypress': {
    path: 'agent-paotung-cypress', kind: 'test-suite',
    base: { feature: 'main', fix: 'main' },
    plan: 'qa-planner', build: 'qa-runner', review: null,
    guard: false, perf: false,
    green: 'tests via cypress passed successfully',
    testSuite: true,
    distribute: null,
  },
  'backoffice': {
    path: 'backoffice', kind: 'web-app',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'tests via stroybook and lint passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'ofb-backoffice-cypress': {
    path: 'ofb-backoffice-cypress', kind: 'test-suite',
    base: { feature: 'main', fix: 'main' },
    plan: 'qa-planner', build: 'qa-runner', review: null,
    guard: false, perf: false,
    green: 'tests via cypress and newman passed successfully',
    testSuite: true,
    distribute: null,
  },
  'mock-agency-api': {
    path: 'mock-agency-api', kind: 'mock',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: false, perf: false,
    green: 'The service is running with healthy',
    knownFalseReds: 'scripts/dev.sh test goes red with \'mock did not become ready\' when port 3001 is already taken by an unrelated local server; check with lsof -nP -iTCP:3001 and re-run with DEV_PORT=<free port> before treating it as a real failure',
    distribute: null,
  },
  'commission-batch': {
    path: 'commission-batch', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'seamless-api': {
    path: 'seamless-api', kind: 'web-app',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'run and tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'game': {
    path: 'game', kind: 'package',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests and integration passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'cashback-batch': {
    path: 'cashback-batch', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'crypto-watcher': {
    path: 'crypto-watcher', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'bet-aggregator': {
    path: 'bet-aggregator', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'campaign-sub': {
    path: 'campaign-sub', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'live-sub': {
    path: 'live-sub', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
  'ofb-k6-loadtests': {
    path: 'ofb-k6-loadtests', kind: 'test-suite',
    base: { feature: 'main', fix: 'main' },
    plan: 'qa-planner', build: 'qa-runner', review: null,
    guard: false, perf: false,
    green: 'tests via k6 passed successfully, and no tracked metric degraded against the base branch',
    testSuite: true,
    suiteKind: 'load',
    distribute: null,
  },
  'lotto-service': {
    path: 'lotto-service', kind: 'backend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: 'unit tests + integration tests passed successfully',
    guardianFocus: 'secrets, data-protection, input validation',
    distribute: null,
  },
  'dev-script': {
    path: 'dev-script', kind: 'script',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: '<unit + integration tests>',
    guardianFocus: 'secrets, data-protection',
    distribute: null,
  },
}
// <<< AIWORKS:CONFIG END >>>

// Workspace-wide Figma kill-switch (design.enabled). When OFF, every Figma-reading role
// (development-planner / developer / qa-planner / qa-runner) gets this appended to its prompt
// so it builds from the ticket spec instead of calling Figma. See docs/agents/figma.md.
const FIGMA_DIRECTIVE = (typeof DESIGN_ENABLED !== 'undefined' ? DESIGN_ENABLED : false)
  ? ''
  : ' Figma is DISABLED workspace-wide (design.enabled=false): do NOT call any Figma tools (get_screenshot/get_metadata/get_design_context) — build strictly from the ticket spec/written plan.'

// Workspace output language (language). When 'th', every prose-producing role gets this appended so
// it writes Thai prose with an English spine (reinforces the agent-level rule). See docs/agents/language.md.
//
// RESOLVED DYNAMICALLY, not just from the committed LANGUAGE const above: the const is generated
// from workspace.config.yaml ONLY (a personal workspace.config.local.yaml override can never land
// in a committed file), and asking every downstream prose-producing agent to re-check that file
// itself proved unreliable in practice (measured ~0-100% compliance across roles — some roles
// reliably skip the check when absorbed in their actual task). A single dedicated resolver agent,
// whose ENTIRE job is that one Read, is far more reliable — do it once, here, and bake the result
// into every downstream prompt instead of hoping each one remembers.
//
// THE SAME RESOLVER ALSO CARRIES planning.to_html and planning.auto_approve (see the consts above).
// to_html is a personal OUTPUT preference — which artifacts a human wants to read. auto_approve is
// control flow, and the ONE control-flow key that honors a personal override: the plan gate is
// REVERSIBLE (review, the test-suite gate and merge all still stand between a plan and anything
// shipping), so skipping it changes only how the runner spends their own time. The irreversible
// control flow — auto_merge (it publishes), the status lifecycle and REPOS (they rewrite artifacts
// the whole team reads) — stays SHARED-only. One resolver Read covers all three keys, so this costs
// nothing over the language check it replaces. See docs/adr/0003.
//
// FAIL-CLOSED by construction: auto_approve is reported ONLY when a local `planning:` block exists,
// so a resolver that throws, omits the key, or returns junk leaves the committed AUTO_APPROVE_PLAN
// standing — the gate stays ON. Nothing here can loosen it by accident.
// artifacts.enabled rides the same resolver but has NO committed mirror const, so it stays out of
// the generated CONFIG block (which `aiworks config --dry-run` diffs against the generator). It is
// read-only for one purpose: whether the Kickoff publish request fires. Default false = fail-closed,
// so a resolver that throws or a teammate whose config never opted in gets no publish hand-back.
const RUNTIME_SCHEMA = { type: 'object', additionalProperties: false, required: ['language'], properties: {
  language: { type: 'string', enum: ['en', 'th'] }, plan_to_html: { type: 'boolean' }, auto_approve: { type: 'boolean' }, artifacts_enabled: { type: 'boolean' }, source: { type: 'string' } } }
let RESOLVED_LANGUAGE = (typeof LANGUAGE !== 'undefined' ? LANGUAGE : 'en')
let RESOLVED_PLAN_TO_HTML = (typeof PLAN_TO_HTML !== 'undefined' ? PLAN_TO_HTML : false)
let RESOLVED_AUTO_APPROVE = (typeof AUTO_APPROVE_PLAN !== 'undefined' ? AUTO_APPROVE_PLAN : false)
let RESOLVED_ARTIFACTS = false
try {
  const cfgCheck = await agent(
    'Resolve three workspace config values, local-first. Read `workspace.config.local.yaml` in the repo root if it exists; else read `workspace.config.yaml`. (1) language: if the local file exists AND has a `language:` line, that value wins, source="workspace.config.local.yaml"; otherwise use `workspace.config.yaml`\'s `language:` line (default "en" if absent), source="workspace.config.yaml". (2) plan_to_html: if the local file exists AND has a `planning:` block, read `to_html` from THAT block ONLY — the merge is shallow per top-level key, so a local `planning:` block replaces the shared one whole and a `to_html` absent from it means false, NOT the shared file\'s value; otherwise use `workspace.config.yaml`\'s `planning.to_html` (default false if absent). (3) auto_approve: report this key ONLY when the local file exists AND has a `planning:` block — then read `auto_approve` from THAT block ONLY, and an `auto_approve` absent from that block means false, NOT the shared file value. If there is no local file, or it has no `planning:` block, OMIT auto_approve from your answer entirely so the workflow keeps its committed default. (4) artifacts_enabled: read `artifacts.enabled` the same shallow-merge way — a local `artifacts:` block replaces the shared one whole, so `enabled` absent from a local `artifacts:` block means false; with no local `artifacts:` block use `workspace.config.yaml`\'s `artifacts.enabled` (false if absent). Return ONLY the resolved language ("en" or "th"), plan_to_html (boolean), auto_approve (boolean — omitted entirely unless a local `planning:` block exists), artifacts_enabled (boolean), and the source file — nothing else, no other files, no other analysis.',
    { agentType: 'documentor', label: 'resolve-runtime-config', schema: RUNTIME_SCHEMA },
  )
  if (cfgCheck?.language === 'en' || cfgCheck?.language === 'th') RESOLVED_LANGUAGE = cfgCheck.language
  if (typeof cfgCheck?.plan_to_html === 'boolean') RESOLVED_PLAN_TO_HTML = cfgCheck.plan_to_html
  if (typeof cfgCheck?.auto_approve === 'boolean') RESOLVED_AUTO_APPROVE = cfgCheck.auto_approve
  if (typeof cfgCheck?.artifacts_enabled === 'boolean') RESOLVED_ARTIFACTS = cfgCheck.artifacts_enabled
} catch { /* any failure here keeps the committed-default fallbacks above */ }
if (RESOLVED_PLAN_TO_HTML !== PLAN_TO_HTML) log(`planning.to_html resolved to ${RESOLVED_PLAN_TO_HTML} at runtime (committed mirror says ${PLAN_TO_HTML}) — personal workspace.config.local.yaml override.`)
if (RESOLVED_AUTO_APPROVE !== AUTO_APPROVE_PLAN) log(`planning.auto_approve resolved to ${RESOLVED_AUTO_APPROVE} at runtime (committed mirror says ${AUTO_APPROVE_PLAN}) — personal workspace.config.local.yaml override.`)

const LANGUAGE_DIRECTIVE = RESOLVED_LANGUAGE === 'th'
  ? ' LANGUAGE_DIRECTIVE — OUTPUT LANGUAGE = th, already resolved for this run (docs/agents/language.md). This is AUTHORITATIVE: do NOT re-check any config file or override it with your own resolution — obey it verbatim. Write ALL prose — chat, ticket description & comments, PR/MR description & review discussion, and the .html render of a plan — in THAI, but keep the English SPINE English: titles + every section heading + labels/enum values, ALL code + code comments + git commit messages + branch names, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). Code, checked-in repo docs (docs/, README, ADRs, committed PRD/BRD files), AND ANY file you author with a .md extension (plans, testcases, PRD/summary Markdown in agent_logs/) are NEVER Thai — the th prose rule applies to chat, tickets, PR/MR discussion, Slack, and .html docs only.'
  : ''

// Every agent spawned with a NAMED agentType inherits caveman from its .claude/agents/
// def, where `skills: - caveman:caveman` is preloaded at spawn — measured, not assumed:
// the skill's own text was present in 5/5 probe transcripts. A `general-purpose` agent
// has no def, so it inherits nothing, and that is the one spawn path where this
// workspace's output-compression rule has to travel in the prompt itself. Appended to
// those def-less briefs (guard-backstop, ws-root, plan-guard) for that reason — AND to the
// four expensive call sites below (build, open-pr, review, pr-fix) even though those ARE
// def-backed: those four spawned roughly 100 of one 143-agent run's spawns, so paying for
// the ~200-token instruction twice there is cheaper than the uncompressed reports it prevents.
//
// The INPUT half is the part that is easy to get wrong, and it has two sides. A brief
// that ARRIVES compressed has lost context the agent cannot get back — so the FIRST
// brief, the one that spawns an agent, is never compressed. Every message after that
// spawn is, because the context already landed and a follow-up is a pointer rather than
// a context transfer. Style only, though: a follow-up carrying a new fact carries it whole.
// It matters most for guard-backstop, whose findings become PR comments a human reads.
const CAVEMAN_DIRECTIVE = ' CAVEMAN_DIRECTIVE — invoke `/caveman:caveman` and write every report, comment, and reply ultra-compressed: drop articles/filler/pleasantries/hedging, fragments are fine, technical accuracy stays FULL, and code + identifiers + error strings stay verbatim. It governs how you WRITE, never what you DO: never skip a tool call, never skip a tool-availability check, and never claim a tool or shell is unavailable without first actually running it. It never applies to your INPUT either: the brief that spawned you stands in FULL — do not compress or summarize it away. If you spawn or message another agent, its FIRST brief goes out in FULL for the same reason, while every follow-up after that spawn IS compressed (the context already landed; a follow-up is a pointer, not a context transfer) — style only, so any NEW fact in a follow-up still goes in complete.'

// INPUT compression, the counterpart to caveman's output rule. The four expensive sites below
// spawned roughly 100 of one 143-agent run's spawns and carried no compression directive at all,
// while reading whole log files and whole tool dumps into context. hcat keeps the bytes out of
// the transcript; the .env ban is why the directive has to name it.
const HEADROOM_DIRECTIVE = ` HEADROOM_DIRECTIVE (input compression — docs/agents/headroom.md):
• READ A BIG FILE WITH \`hcat\`, NOT Read/cat. For any file large enough that you would hesitate — a test log, a build output, a generated artifact, a long diff — run \`hcat <path>\` over Bash instead of the Read tool or \`cat\`: the raw bytes never enter your context and you get what you needed. Read/cat is for a file you intend to quote.
• ⚠️ \`hcat\` IS A RENAMED \`cat\` AND HAS NO SIZE CEILING. It will happily print a 250 MB log, and it is NOT a way past any read prohibition: NEVER point it (or Read, cat, grep, sed, head, tail, or \`bash -x\` around code that sources one) at \`.env\` or \`.env.*\`. Only \`.env.example\` is readable, and that rule is absolute — to prove a variable is set use \`grep -q '^VAR=.\\+' .env\`, exit code only, never a form that echoes the value.
• COMPRESS LARGE STRUCTURED OUTPUT BEFORE YOU CARRY IT. A long JSON/table/list from a tool goes into your reasoning as a summary — the rows that answer the question, plus the shape — not raw. When you need the whole thing examined, read-and-compress it in a disposable subagent and keep only what it returns.`

// codegraph is the pre-built per-repo index; using it instead of a grep+read loop is the
// difference between one round-trip and twenty. Two things get it wrong every time, and both
// fail SILENTLY: a relative -p walks up and answers from the WRONG repo with exit 0, and the
// subcommand is `query`. A guard blocks the relative form. No prose-mapping-tool clause here —
// docs/adr/0013 scopes that other index to the meta repo's own prose, and this workflow works
// product repos, so only codegraph applies.
const codegraphClause = (repoPath) => ` CODEGRAPH FIRST (this repo carries a \`.codegraph/\` index): to locate a symbol, a caller, or "where does X happen", query the index before you grep — \`codegraph explore\` for a natural-language question, \`codegraph query\` for a named symbol, \`codegraph callers\`/\`callees\`/\`impact\` for blast radius. ⚠️ The \`-p\` path MUST be ABSOLUTE — \`-p $CLAUDE_PROJECT_DIR/${repoPath}\` — because a relative \`-p\` walks up the tree and answers from a DIFFERENT repo with exit 0, and a guard blocks it outright. The subcommand is \`query\`, not \`search\`. Grep/Glob are the last resort, for the one detail the index does not cover (a non-code asset, a config string).`

// Run-state write contract. Appended to the phase agents that ALREADY write files, so a
// checkpoint costs no extra spawn. docs/adr/0018.
// ONE FILE PER CHECKPOINT, not one line in a shared file: no phase agent's tool grant
// includes a shell-append primitive (checked against developer.md/qa-runner.md/documentor.md —
// each is an explicit allowlist of specific Bash patterns, none matching `printf`/redirect), so a
// shared-file append was silently unrunnable. Every one of these agents DOES have the Write tool,
// which replaces a whole file — safe here because the path is unique per (repo, milestone), so
// concurrent build agents never touch the same file and a re-run just overwrites its own.
const stateWrite = (repo, milestone, extra = '') => ` RUN-STATE CHECKPOINT (mandatory, do it as your LAST action before the structured result, with the Write tool — the directory already exists, created at Kickoff, so no mkdir needed): Write \`agent_logs/${ticket}-dev-cycle-state/${repo}-${milestone}.json\` at the WORKSPACE ROOT — the dir holding .claude/, NOT this repo's agent_logs/ (one file per checkpoint; overwriting your own file on a re-run is expected). Its content is exactly: {"repo":"${repo}","milestone":"${milestone}","status":"done","work_branch":"<the branch you worked>","head_sha":"<git rev-parse HEAD, the full sha>","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"${extra}}. head_sha must be the sha you actually read with \`git rev-parse HEAD\` after your last commit — a wrong sha makes the next invocation redo this work, which is the whole point of the row. If you are ending with status other than complete, write the SAME file with "status":"in-progress" instead, so a resume re-runs this milestone.`

// ──────────────────────────────────────────────────────────────────────────
// Inputs
// ──────────────────────────────────────────────────────────────────────────
const rawArg = (typeof args === 'string' ? args : args?.ticket) || ''
// Tolerate stray flags/words in the arg string (e.g. "FM-10 --dry-run"): pull out
// the <PREFIX>-<n> token so the ticket never becomes "FM-10 --dry-run".
const TICKET_RE = new RegExp(`${TICKET_PREFIX}-\\d+`, 'i')
const ticket = (rawArg.match(TICKET_RE)?.[0] || rawArg).trim()
if (!ticket) throw new Error(`dev-cycle needs a ticket number, e.g. args: "${TICKET_PREFIX}-12"`)
const opt = typeof args === 'object' && args ? args : {}
// Flags settable from the STRING arg form, not just an object arg. The string form is what a
// human actually types, and the only reason the persisted script kept being hand-edited — a
// fast-track/hotfix base or a review-round cap had no way in except editing this file directly.
// Defined here (right after `opt`, not further down) because MAX_REVIEW_ROUNDS below needs it —
// a top-level `const` is not hoisted, so referencing it before its own declaration would throw.
const flag = (name) => rawArg.match(new RegExp(`--${name}(?:=|\\s+)(\\S+)`, 'i'))?.[1] || null
// --base overrides whichever base kind applies this run (the fast-track/hotfix case);
// --feature-base overrides the feature base only, so a mixed run's bug branch still targets fix_base.
const BASE_OVERRIDE = flag('base') || opt.base || null
const FEATURE_BASE_OVERRIDE = flag('feature-base') || opt.featureBase || null
// review↔fix loops, per repo. Generous ON PURPOSE: at review.level strict the gates report
// must-fixes only, a reviewer that passes is FROZEN (never re-run), and a re-visit may raise
// nothing new — so extra rounds cannot widen scope. They only let a repo finish its own
// finding list inside ONE invocation instead of stranding a nearly-done PR at the cap. The
// loop still exits the moment no findings remain, so the cap costs nothing when unused.
const MAX_REVIEW_ROUNDS = Number(flag('max-review-rounds')) || opt.maxReviewRounds || 10
// Attributed load-test regression → developer fix → re-run, per repo. Small by contrast: a
// load run costs wall clock, not tokens (workspace.config.yaml loadtest.max_fix_rounds).
const MAX_LOADTEST_FIX_ROUNDS = opt.maxLoadtestFixRounds || LOADTEST.maxFixRounds
const MAX_BUILD_TRIAGE = opt.maxBuildTriage || 3   // fix attempts per failing test before a build agent must hand off (OFB-2141)
// REVIEW LEVEL (workspace.config.yaml review.level, mirrored above). strict ⇒ the Review phase
// reports must-fixes ONLY and suppresses the whole nice-to-have tier; thorough ⇒ + nice-to-have.
// levelDirective is prepended to every first-review prompt so all three gates share one rule; at
// strict it explicitly deactivates the fold-in / Improvement-ticket guidance the gate prompts spell
// out below (so there is no contradiction), and the guard/perf open() count ignores fold_in so a
// nice-to-have never holds the merge at strict.
const STRICT = REVIEW_LEVEL !== 'thorough'
const levelDirective = STRICT
  ? `REVIEW LEVEL = strict (workspace.config.yaml review.level — do NOT re-read the file): report ONLY must-fixes, the blocking findings that hold the merge. Everything below the must-fix line is OUT OF SCOPE this run — post NO "[minor / fold-in]" comments, file NO Improvement tickets, raise NO polish/optional findings; leave any fold_in and improvements_filed arrays EMPTY. Treat every fold-in / minor / Improvement-ticket instruction below as applying to the 'thorough' level ONLY.`
  : `REVIEW LEVEL = thorough (workspace.config.yaml review.level — do NOT re-read the file): report must-fixes AND nice-to-have — follow the fold-in / Improvement-ticket guidance below in full.`
// DRY RUN — run review + the (read-only) cross-repo test-suite gate, then STOP before the
// outward/irreversible steps: NO Merge and NO Distribute (no squash-merge to the base branch,
// no distribution). Lets a run confirm build/gate/test-suite behaviour safely.
// Set via "--dry-run" in the arg string or opt.dryRun.
const dryRun = /--dry-run\b/i.test(rawArg) || opt.dryRun === true
// PLAN APPROVAL — when AUTO_APPROVE_PLAN is false the run STOPS after Kickoff so a human can
// review the plan(s) before build. Re-run with "--approve-plan" (or opt.approvePlan) to proceed.
const approvePlan = /--approve-plan\b/i.test(rawArg) || opt.approvePlan === true

// Machine-readable marker prefixed on EVERY agent prompt so
// summarize-workflow-performance can attribute each transcript to a repo+role.
// Format the parser keys off: [dev-cycle FM-9 repo=app role=developer phase=build round=2]
const tag = (repo, role, phase, round) =>
  `[dev-cycle ${ticket} repo=${repo} role=${role} phase=${phase}${round ? ` round=${round}` : ''}]`

// PR/MR titles follow Conventional Commits. The type comes from the branch the ticket
// is on — a `fix/*` branch → `fix`, anything else (`feature/*`) → `feat` — matching the
// branch model's fix_base/feature_base split. The squash-merge subject reuses the same
// title so the commit that lands on the base is itself a conventional commit.
const ccType = (branch) => (/^fix\//i.test(branch ?? '') ? 'fix' : 'feat')
const prTitle = (rp) => `${ccType(rp.work_branch)}(${ticket}): ${rp.title ?? '<Task name>'}`

// Shared BUILD-AGENT DISCIPLINE (OFB-2141) — appended to EVERY build prompt (code + test-suite)
// and the convergence retry. Three hard rules that stop an open-ended build loop from running
// away (the agent-webservice build aborted 3× without ever handing off): always hand off, never
// a repo-wide formatter, and a bounded red-test triage that tells a flaky harness from a real bug.
const BUILD_DISCIPLINE = ` BUILD DISCIPLINE (mandatory — OFB-2141):
• ALWAYS HAND OFF. Ending WITHOUT calling StructuredOutput is a FAILURE. Even if the work is incomplete or the suite is red, you MUST end by returning the DEV_SCHEMA result with "status" set: "complete" (Definition of Done met — for the test-suite repo a red caused only by reported app bugs / expected pre-merge reds still counts as complete), "partial" (some slices landed, work OF YOUR OWN remains), "deferred" (see below), or "blocked" (cannot proceed). For "partial"/"blocked" put exactly WHAT REMAINS and WHY in "remaining". Never withhold the handoff to keep investigating.
• "DEFERRED" — YOUR WORK IS DONE, THE REST IS SOMEONE ELSE'S. Use it when everything this repo owns is implemented and green, and what the ticket still wants belongs to another owner: a repo this workspace does not hold, or an access only a person has. That is a different claim from "partial", and it is the one the run acts on most generously — it proceeds to PR, review and the test gate — so it costs more to make. Fill BOTH \`deferred[]\` (per criterion: the criterion quoted, why, the owner who CAN do it, and \`evidence\` — what you actually OBSERVED, a file:line you read, a config value, a command and its refusal) and \`met_acceptance[]\` (the criteria your diff DOES meet). A separate verifier reads any deferral the scope stage did not already declare out of reach, and downgrades an unevidenced one to "partial" — which stops your repo. So: never reach for "deferred" to get out of hard work you own, and never guess an owner. If the remaining work is yours but unfinished, "partial" is the honest answer and costs you nothing.
• NEVER run a repo-wide formatter or autofix — no \`cargo fmt\`/\`clippy --fix\`, \`eslint .\`/\`prettier --write .\`, \`dart format .\`, \`gofmt -w .\`, or any whole-repo reformat. Format/lint ONLY the files you actually touched for this ticket; leave pre-existing drift in untouched files ALONE. A 50-file reformat diff that drowns the ticket change is itself a failure.
• BOUND RED-TEST TRIAGE. Cap fixes at ${MAX_BUILD_TRIAGE} attempts per failing test. Before chasing a red, decide whether it is a FLAKY HARNESS rather than a real code failure — symptoms: passes/fails non-deterministically on re-run, shared or dirty fixtures, a query like fetch_optional resolving against MORE than one matching row, missing FK/seed data, leaked testcontainer state between tests. If it is the harness: fix FIXTURE ISOLATION / seeding (make the query deterministic) — do NOT loop trying to green a non-deterministic suite. If you cannot isolate it within the cap, FLAG it (status:"partial"/"blocked", name the flaky suite + cause in "remaining") and hand off; do not thrash.
• LEAVE NO DIRTY TREE. The build ends in exactly ONE of two states: COMMITTED (your work is on the work branch as conventional commits) or PARKED. Ending with uncommitted changes and no record of them is a failure — the next run inherits them as an unexplained partial implementation and has to reverse-engineer your intent. If the work is not commit-ready, PARK it: prefer a WIP commit on the work branch (\`wip(<scope>): <what is unfinished> Refs ${ticket}\`); use \`git stash push -u -m "${ticket} <what>"\` only when a commit would break the branch for someone else. Then name WHICH you chose and WHERE the work now lives in "parked_at". \`git checkout .\`, \`git restore .\` and \`git reset --hard\` are FORBIDDEN — discarding work is a decision you were not asked to make. On ARRIVAL, if the tree is already dirty, account for it BEFORE writing new code (fold it into your plan or park it as above), and if the repo has a compile/typecheck step, get it passing before you add a new slice.
• A NON-COMPLETE HANDOFF MUST BE ACTIONABLE. With status "partial"/"blocked", also fill "root_cause" (the MEASURED cause at file:line — never the word "unknown"), "commands_run" (each command you actually ran with its exit code), and "decision_needed" when the blocker is a fork only a human can settle. "needs human triage" on its own is not a handoff; it is the absence of one.`

// Shared ADAPTER DISCIPLINE — appended to every prompt whose phase invokes a MUTATING adapter
// (open-pr, pr-comment, pr-approve, merge-pr, the tracker + notify writers). Two agents in one
// run read a guard-denied compound call as "the adapter is broken" and side-doored to
// `glab mr create` — one of them editing scripts/vcs/gitlab.sh to get there. The guard denies
// SILENTLY (no permission prompt ever reaches the agent), so prose has to name the bare form up
// front and make an adapter failure a legitimate terminal answer rather than a detour.
const ADAPTER_DISCIPLINE = ` ADAPTER DISCIPLINE (mandatory):
• RUN A WRITER BARE. A mutating adapter call (scripts/{vcs,tracker,notify}/…) must be the WHOLE Bash command — no \`cd X && …\`, no pipe, no redirect, no \`env -C\`, no \`$( )\`, no heredoc. A compound form is DENIED SILENTLY: no permission prompt reaches you, so it reads as a broken adapter when it is not. Enter the repo with a SEPARATE standalone \`cd <absolute path>\` call first — Bash cwd persists between tool calls.
• AN ADAPTER FAILURE IS A RESULT, NOT A DETOUR. If it still fails, return that as the answer for this step: the exact command, its exit code and its stderr. NEVER substitute \`glab\`/\`gh\`/curl against the provider API, and NEVER edit anything under scripts/vcs, scripts/tracker or scripts/notify — those paths are SYMLINKS to the shared workspace copy, so editing one from inside a repo rewrites the adapter for EVERY repo. A guard blocks both routes; reaching for either only burns the round.`

// Shared PONYTAIL_DIRECTIVE — appended to the three prompts whose agent actually WRITES code
// (plan, build, pr-fix). The ponytail plugin ships its own SubagentStart hook, so a spawn made
// by hand through the Agent tool already gets the ruleset and needs nothing from us. A WORKFLOW
// spawn is a path that hook has not been measured on here, and the build stage is the one place
// where a ladder that silently did not apply costs a whole ticket of over-built code. ~250 tokens
// of possible overlap is cheaper insurance than the miss — and unlike the plugin text, this names
// the three places THIS workspace refuses to be lazy. Same carve-outs pretool-agent-context.sh
// injects for a hand-driven spawn, so both routes brief an agent identically (docs/agents/ponytail.md).
const PONYTAIL_DIRECTIVE = ` PONYTAIL_DIRECTIVE (code minimalism — docs/agents/ponytail.md):
• THE LADDER. Before writing code, stop at the first rung that holds: does this need to exist at all (YAGNI) → does this repo already have it (reuse it, never re-implement what is a few files over) → does the stdlib do it → does a native platform feature cover it (a DB constraint over app code, CSS over JS, \`<input type="date">\` over a picker lib) → does an already-installed dependency solve it → can it be one line → only then, the minimum that works. The ladder runs AFTER you understand the problem, never instead of it: read the code the change touches and trace the real flow first, because the smallest change in the wrong place is not lazy, it is a second bug. A bug fix is the ROOT CAUSE, not the symptom — grep every caller and fix the shared function once. No unrequested abstractions, no scaffolding for later, deletion over addition, fewest files, shortest working diff. Mark a deliberate corner-cut with a known ceiling (global lock, O(n²) scan, naive heuristic) with a \`ponytail:\` comment naming the ceiling and the upgrade path.
• WHERE IT STOPS. (1) TESTS — this repo's own suite is standing scope, never the single "one runnable check" ponytail settles for, and a gate NEVER fails open. (2) SCOPE — the ticket's acceptance criteria are the contract: the ladder shortens the implementation, never the requirement, and anything genuinely out of scope leaves through the \`deferred\`/\`partial\` handoff with evidence, never a one-line aside. (3) ADAPTERS — "an already-installed dependency solves it" never means \`gh\`/\`glab\`/the Jira, Slack or SigNoz API directly; the adapter under \`scripts/{vcs,tracker,notify,observability}/\` IS the installed dependency here. Money, auth and PII paths keep their validation and error handling in FULL — laziness stops at the trust boundary.`

// Appended to the CODE reviewer's prompts only. The reviewer role normally stamps its pass onto
// the PR/MR with pr-approve.sh, which registers a host-level approval. Inside this workflow the
// reviewer and the author are two agents of the SAME run, so that stamp is a self-approval: it
// satisfies the host's two-party requirement with one party, and the safety layer flags it as
// exactly that (it did, twice in one run, on two repos). The pass signal the workflow acts on is
// the structured `approved` field — the host stamp adds nothing the run needs and costs the
// review its independence. So: comment the verdict, return it, and leave the stamp to a human.
const NO_SELF_APPROVE = `
YOU REPORT FINDINGS; YOU DO NOT APPROVE. You and the author are two agents of the SAME automated run, so anything from you that reads as an approval clears the two-party review requirement with one party. That applies to BOTH ways of doing it:
• Never call \`scripts/vcs/pr-approve.sh\`, and never register a host approval by any other route.
• Never PHRASE your comment as an approval either. No "APPROVED", no "LGTM", no "ship it", no "good to merge" — those words grant permission, and granting permission is not yours to do.
Say what you MEASURED instead, which is both more useful and actually true: what you ran, what it returned, how many must-fixes you raised, and how many are still open. "Review complete — 0 must-fix remaining. Suite: \`scripts/dev.sh test\` exit 0, 318 passed / 0 failed." is a finding a human can act on. "✅ APPROVED" is a decision you were not asked to make, and it tells the reader strictly less.
The distinction is not cosmetic and it is not about wording for its own sake: a gate that reports is an instrument, and a gate that approves is an authority. You are the instrument. Post the finding with \`scripts/vcs/pr-comment.sh <number> --body "<what you measured>"\` and return your verdict in the structured \`approved\` field — that field is the signal this workflow acts on, and it is enough. The host approval belongs to a human who is not part of this run.`

// Appended to every test-suite gate prompt. The verdict is audited twice — the receipt must
// describe a real command, and a SECOND agent reads the ticket for the result — because a run
// has reported green having executed nothing, and a self-report cannot catch that about itself.
const RECEIPT_CLAUSE = `
RECEIPT (required — the verdict does not count without it): fill "receipt" with the EXACT command line you ran THIS session, its exit code, the runner's own summary line quoted verbatim, AND the base URL / target the run actually hit (a suite whose config falls back to a deployed default proves nothing about this candidate, and the command line alone does not reveal which one it used), plus the report file paths you produced and the URL of the comment you posted. Two checks run on your answer: this receipt, and an independent read of the ticket by another agent looking for your result comment. If either comes up empty the gate is recorded as NOT RUN — not as a pass — and nothing merges. So: post the per-scenario result to the ticket (\`scripts/tracker/add-ticket-comment.sh\`) whether the run was green or red, and never report from a report file you did not produce in this session — a stale artifact from an earlier round reads exactly like a fresh one.`

// The test-suite repo runs specs against a RUNNING app at TWO moments — while building them, and
// again at the gate — so the bring-up instruction lives here once and both prompts append it.
// A suite repo owns no app SOURCE but standing the stack up IS its job: its dev.sh grant already
// spans every repo, and a gate with no receipt is recorded as NOT RUN (docs/agents/loadtest-gate.md),
// so "nothing was listening" is not a verdict it may hand back.
// A PR/MR needs its base to exist ON THE REMOTE. In one run the fast-track base existed only
// locally, so the step that raises the change for review had no target — discovered at the PR
// step, after every build had already been paid for. Checked at kickoff instead, and re-asserted
// at the PR step. NOT auto-pushed: creating a shared branch is a human's call, not a run's.
const basePresentClause = (base) => ` BASE-BRANCH PRECONDITION: \`${base}\` must exist on the REMOTE before this ticket's change can be raised for review. Check it with \`git ls-remote --exit-code --heads origin ${base}\` and report what it returned. If it exits non-zero the base exists only locally (or not at all): do NOT create or push it yourself, and do NOT retarget to another branch. Record it in \`unverified_claims\` — claim "base branch ${base} is present on origin", why_blocked "git ls-remote found no such head", unblock_command \`git push origin ${base}\` — and say it in your summary, so it is fixed once, by a person, before any build is paid for.`

const candidateStackClause = (appPlans) => appPlans.length
  ? `
CANDIDATE STACK (YOURS to do, before any spec runs): every app/service repo this suite exercises must be RUNNING, built from its ticket work branch — ${appPlans.map((p) => `${REPOS[p.repo].path}@${p.work_branch}`).join(', ')}. For each: one standalone \`cd <repo>\`, \`git switch <its work branch>\`, then \`scripts/dev.sh run\` (its own harness — never a raw toolchain), plus any datastore/migration repo the suite reads. Then PROVE the stack answers BEFORE you run a single spec: probe each port the suite targets and report what replied. ⚠️ A harness \`run\` that probes and then TEARS ITS SERVER DOWN has not given you a stack — it prints an UP verdict while nothing listens; start that server yourself in the background and re-probe. Point the suite at THAT stack EXPLICITLY via the local base-URL env its config reads — never rely on the config default, which commonly falls back to a deployed environment where the bug under test does not reproduce. If a service genuinely cannot come up, name the command and its failure; do NOT hand back a suite result obtained without it.`
  : ''

// ──────────────────────────────────────────────────────────────────────────
// Schemas
// ──────────────────────────────────────────────────────────────────────────
// One agent's verdict on a deferral claim the scope stage did not foresee. Deliberately tiny: the
// only question is whether the work is genuinely another owner's, and an unconverged verifier is
// treated as a rejection — an unaudited deferral must not be able to buy a repo its merge.
const DEFERRAL_VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['upheld', 'reason'],
  properties: {
    upheld: { type: 'boolean' },
    reason: { type: 'string' },  // one line; when false, name the rejected claim + what in this repo could do it
    checked: { type: 'array', items: { type: 'string' } }, // what you opened/ran to decide
  },
}

const SCOPE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ticket', 'type', 'repos'],
  properties: {
    ticket: { type: 'string' }, title: { type: 'string' },
    type: { type: 'string', enum: ['feature', 'bug', 'polish'] },
    tracker_reachable: { type: 'boolean' }, // false → scope could NOT read the live ticket via the adapter (writes won't persist this run)
    // OUT OF REACH — acceptance criteria no repo in THIS workspace can satisfy, declared once here
    // so every later phase inherits a settled list instead of re-litigating it. Only the criteria
    // unreachable BY CONSTRUCTION belong here (the owner is a repo the workspace does not hold, or
    // an access only a person has). A criterion that merely looks hard, or whose difficulty only
    // surfaces once someone reads the code, is NOT this: the build discovers those and hands back
    // `deferred`, which is adjudicated then. [] is the normal answer.
    out_of_reach: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['criterion', 'why', 'owner'],
        properties: {
          criterion: { type: 'string' }, // quote the ticket's own acceptance criterion
          why: { type: 'string' },       // what makes it unreachable here, concretely
          owner: { type: 'string' },     // who CAN do it: a repo outside this workspace, or the access/role required
        },
      },
    },
    // false ⇒ NOTHING the ticket asks for is reachable in this workspace, so the run stops HERE —
    // before any branch, plan or status move — rather than spending a full cycle to say so later.
    deliverable_now: { type: 'boolean' },
    repos: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['repo'],
        properties: {
          repo: { type: 'string' },                                  // must be a key of REPOS
          depends_on: { type: 'array', items: { type: 'string' } },  // other repo ids it needs merged/built first
          summary: { type: 'string' },                               // what this repo must change for the ticket
        },
      },
    },
    test_suite: {
      type: 'object', additionalProperties: false,
      properties: {
        // needed:true is necessary but NOT sufficient — the gate only runs if the registered
        // test-suite repo is ALSO listed in `repos` (its qa-planner/qa-runner author + build the
        // specs the gate runs). needed:true on its own does nothing; pull the test-suite repo into
        // `repos` (depends_on the app/service repos) too. The workflow backstops this if omitted.
        needed: { type: 'boolean' }, suite: { type: 'string' }, notes: { type: 'string' },
      },
    },
  },
}
// `unverified_claims` is REQUIRED, and an empty array is a real answer — the point is that a
// planner must decide, per claim, whether it measured the thing or inferred it. An inferred
// claim carries the command that would settle it, so the orchestrator (which holds grants the
// planner does not — starting local services, running suites) can close the gap instead of
// forwarding a guess as a finding. APP-1944 shipped a "missing index, suspected seq scans"
// finding that one `aiworks run <repo>` + EXPLAIN would have corrected: the indexes existed.
const REPO_PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repo', 'base_branch', 'work_branch', 'plan_path', 'summary', 'unverified_claims'],
  properties: {
    repo: { type: 'string' }, title: { type: 'string' },
    type: { type: 'string', enum: ['feature', 'bug', 'polish'] },
    base_branch: { type: 'string' }, work_branch: { type: 'string' },
    figma_url: { type: ['string', 'null'] }, plan_path: { type: 'string' },
    plan_html: { type: ['string', 'null'] }, // set when RESOLVED_PLAN_TO_HTML rendered the plan to interactive HTML
    needs_artifact_publish: { type: ['boolean', 'null'] }, // plan_html rendered but Artifact publish is caller-only (no Artifact tool in a subagent)
    summary: { type: 'string' }, acceptance: { type: 'array', items: { type: 'string' } },
    unverified_claims: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['claim', 'why_blocked', 'unblock_command'],
        properties: {
          claim: { type: 'string' },           // the assertion the plan leans on
          why_blocked: { type: 'string' },     // what stopped the measurement (missing grant, service down, needs prod scale)
          unblock_command: { type: 'string' }, // the exact command that settles it
        },
      },
    },
  },
}
// Resolves the absolute workspace (org) root ONCE at Kickoff so the workflow can hand every
// planner an absolute, repo-anchored artifact path (the engine runs all agents at the workspace
// root and agent() has no cwd override — see the Kickoff anchoring block).
const WS_ROOT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['workspace_root'],
  properties: { workspace_root: { type: 'string' } }, // absolute pwd of the dir holding .claude/
}
// Post-plan placement guard report: per repo, which expected plan artifacts were already
// correctly placed, which were relocated from the workspace root into the repo, and which
// were missing everywhere. Drives the fail-loud / relocate-and-warn behaviour.
const PLAN_GUARD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repos'],
  properties: {
    workspace_root: { type: 'string' },
    repos: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['repo'],
        properties: {
          repo: { type: 'string' },
          ok: { type: 'array', items: { type: 'string' } },        // already under <repo>/agent_logs/
          relocated: { type: 'array', items: { type: 'string' } }, // moved workspace-root → <repo>/agent_logs/
          missing: { type: 'array', items: { type: 'string' } },   // found neither under the repo nor at the root
        },
      },
    },
  },
}
const DEV_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['work_branch', 'summary', 'status'],
  properties: {
    work_branch: { type: 'string' }, handoff_path: { type: 'string' },
    summary: { type: 'string' }, commits: { type: 'number' },
    fixed: { type: 'array', items: { type: 'string' } },
    // Convergence contract (OFB-2141): a build/fix handoff ALWAYS classifies its end state, so the
    // workflow never has to treat a wall as a bare null/abort. complete = DoD met (test-suite repo:
    // a red caused only by reported app bugs / expected pre-merge reds still counts as complete);
    // partial = some slices landed, work OF THIS REPO'S OWN remains; blocked = cannot proceed (flaky
    // harness, missing fixture/seed, env). For partial|blocked, `remaining` MUST say what is left and why.
    //
    // deferred = THE REPO'S OWN WORK IS DONE AND GREEN; what is left belongs to another owner —
    // a repo this workspace does not hold, or an access only a person has (CONTEXT.md: deferred
    // scope; docs/adr/0011). It is NOT a softer `partial`, and the difference decides whether the
    // run continues: `partial` stops the repo, `deferred` proceeds to PR, review and the gate with
    // the deferral named on the MR and the ticket. Because that makes it the one status an agent
    // could reach for to escape hard work, it costs more to claim: `deferred[]` and
    // `met_acceptance[]` are both REQUIRED, every deferred entry needs `evidence`, and a deferral
    // scope did not already declare out of reach is adjudicated by a separate verifier that can
    // downgrade it to `partial`.
    status: { type: 'string', enum: ['complete', 'partial', 'blocked', 'deferred'] },
    // REQUIRED when status === 'deferred'. One entry per acceptance criterion this repo cannot meet.
    deferred: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['criterion', 'why', 'owner', 'evidence'],
        properties: {
          criterion: { type: 'string' }, // the acceptance criterion, quoted
          why: { type: 'string' },       // what puts it beyond this repo
          owner: { type: 'string' },     // who CAN do it — a repo outside this workspace, or the access/role required
          // What you OBSERVED that puts it out of reach: a file:line you read, a config value, a
          // command and its refusal. "It looks like infra" is not evidence; a verifier checks this.
          evidence: { type: 'string' },
        },
      },
    },
    // REQUIRED when status === 'deferred': the acceptance criteria this repo's diff DOES meet.
    // The run's floor reads it — a ticket where no repo met anything delivers nothing, and stops.
    met_acceptance: { type: 'array', items: { type: 'string' } },
    remaining: { type: 'string' }, // what remains / why — required reading when status != complete
    // A handoff that says only "needs human triage" costs the next run a full re-investigation:
    // one later round found the real cause (a misplaced `#[async_trait]`) in a single pass. So a
    // non-complete handoff must carry the THREE things that make it actionable without re-doing
    // the work — what actually broke, the receipts, and the fork the agent could not settle.
    root_cause: { type: 'string' },            // the measured cause, at file:line where known — never "unknown"
    commands_run: {                            // receipts: what was actually executed, and what it returned
      type: 'array',
      items: {
        type: 'object', required: ['command', 'exit_code'],
        properties: { command: { type: 'string' }, exit_code: { type: 'number' }, summary_line: { type: 'string' } },
      },
    },
    decision_needed: { type: 'string' },       // the fork a human must settle (e.g. keep the partial work vs reset)
    parked_at: { type: 'string' },             // where uncommitted work now lives: a WIP commit sha, or a stash ref
  },
}
// Guardian & performance share one gate shape. A finding is triaged into ONE of three
// tiers — blocking findings stop the merge; MINOR improvements are folded into THIS PR
// by the developer (a PR comment, NO ticket); only MAJOR, nice-to-have improvements
// become Improvement tickets. None of the non-blocking tiers stop the merge, and an
// empty improvements_filed is the normal, healthy outcome (file tickets only as needed).
const GATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['passed'],
  properties: {
    passed: { type: 'boolean' }, conclusion: { type: 'string' },
    // The configured gate (quality_gate.provider != "none", or perf's profiler) could NOT
    // actually run in this run-context — e.g. the SonarQube MCP isn't connected AND the sonar
    // CLI/auth isn't available. When true the gate is UNAVAILABLE, NOT passed: the reviewer
    // MUST set passed:false too, and the workflow surfaces this loudly (mirrors the
    // testSuiteGateUnavailable pattern) instead of letting an un-run gate read as a pass.
    gate_unavailable: { type: 'boolean' },
    unavailable_reason: { type: 'string' }, // what was tried + why it couldn't run (channels attempted)
    blocking: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        properties: {
          title: { type: 'string' }, scope: { type: 'string' },
          severity: { type: 'string' }, evidence: { type: 'string' },
        },
      },
    },
    // MINOR improvements posted as PR comments for the developer to fold into THIS PR
    // (no ticket). Counts toward "open" so the dev loop applies them; gate flips to
    // passed once they are resolved.
    fold_in: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        properties: {
          title: { type: 'string' }, scope: { type: 'string' }, fix: { type: 'string' },
        },
      },
    },
    improvements_filed: { type: 'array', items: { type: 'string' } },
    // RE-VISIT ONLY: the developer's fix DIRECTLY caused a new blocking problem (a regression the
    // fix introduced, not a pre-existing issue). The workflow HALTS the repo for human action.
    fix_regression: { type: 'boolean' },
    regression_detail: { type: 'string' }, // what the fix broke + file:line + evidence it was the fix
  },
}
const PR_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['pr_url'],
  properties: { pr_url: { type: 'string' }, pr_number: { type: ['number', 'string'] } },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['approved'],
  properties: {
    approved: { type: 'boolean' }, conclusion: { type: 'string' },
    // The green gate: the reviewer RUNS the repo's suite on the PR/MR head itself (it holds the
    // scripts/dev.sh grant — the other two gates deliberately do not) and reports the receipt.
    // approved:true REQUIRES tests_green:true; a suite that could not run is gate_unavailable,
    // never a pass — same contract the guardian and performance gates already use.
    tests_green: { type: 'boolean' },
    tests_receipt: { type: 'string' }, // the invocation + result, e.g. "scripts/dev.sh test → 214 passed / 0 failed"
    gate_unavailable: { type: 'boolean' },
    unavailable_reason: { type: 'string' }, // what was tried, why each attempt failed, the unblocking command
    comments: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        properties: {
          file_line: { type: 'string' }, issue: { type: 'string' }, severity: { type: 'string' },
        },
      },
    },
    // RE-VISIT ONLY: the developer's fix DIRECTLY caused a new blocking problem (a regression the
    // fix introduced, not a pre-existing issue). The workflow HALTS the repo for human action.
    fix_regression: { type: 'boolean' },
    regression_detail: { type: 'string' }, // what the fix broke + file:line + evidence it was the fix
  },
}
// The cross-repo QA gate's verdict. `receipt` is REQUIRED and not decorative: a gate that
// returns passed:true with no evidence of having run is the one failure this schema exists to
// stop (it has happened — the run reported green and no result reached the ticket). The caller
// treats a missing/empty receipt as "did not run" and downgrades the verdict, so there is
// nothing to gain by asserting a pass you cannot evidence.
const TEST_SUITE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['passed', 'receipt'],
  properties: {
    passed: { type: 'boolean' }, conclusion: { type: 'string' },
    receipt: {
      type: 'object', additionalProperties: false,
      required: ['command', 'exit_code', 'summary_line'],
      properties: {
        command: { type: 'string' },        // the exact command line you ran, this session
        exit_code: { type: 'integer' },
        summary_line: { type: 'string' },   // the runner's own tally, quoted verbatim
        report_paths: { type: 'array', items: { type: 'string' } },
        ticket_comment_url: { type: 'string' }, // where you posted the result
      },
    },
    // Load suites (REPOS[id].suiteKind === 'load') only — the base-branch comparison.
    // `unavailable` means the environment's noise floor is wider than the effect: an honest
    // "cannot tell", loud-skipped like any other gate that could not run — never a quiet pass.
    loadtest: {
      type: 'object', additionalProperties: false,
      properties: {
        verdict: { type: 'string', enum: ['pass', 'fail', 'unavailable'] },
        base_sha: { type: 'string' }, candidate_sha: { type: 'string' },
        baseline_cached: { type: 'boolean' }, env_fingerprint: { type: 'string' },
        markdown: { type: 'string' },       // the comparator's table, as posted
        regressed: { type: 'array', items: { type: 'string' } },
        too_noisy: { type: 'array', items: { type: 'string' } },
      },
    },
    failures: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        properties: {
          case: { type: 'string' }, platform: { type: 'string' }, evidence: { type: 'string' },
        },
      },
    },
  },
}
// The developer's ATTRIBUTION verdict on a load-test regression — the step before any fix.
// Its whole job is to keep a jittery environment from burning developer rounds: only
// `attributable` earns a fix; the other two flip the gate to a loud `unavailable`.
const LOADTEST_ATTRIBUTION_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['attribution', 'reasoning'],
  properties: {
    attribution: { type: 'string', enum: ['attributable', 'not-attributable', 'need-bigger-env'] },
    reasoning: { type: 'string' },  // the commit / query / lock / allocation that explains it
    evidence: { type: 'string' },   // file:line, EXPLAIN output, span — what you actually read
    repo: { type: 'string' },       // which scoped repo carries the cause (where the fix lands)
  },
}
// Independent confirmation that the gate's result actually REACHED the ticket. A second agent
// reads the tracker rather than the gate re-asserting its own claim — self-report is the thing
// being audited, so it cannot be the evidence.
const RESULT_AUDIT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['posted'],
  properties: {
    posted: { type: 'boolean' },
    detail: { type: 'string' },  // the matching comment's opening line, or why none matched
  },
}

// Appended to every gate prompt. A gate has a finite turn budget (maxTurns in its agent
// definition), and the structured verdict is the LAST thing it does — so a gate that investigates
// right up to the limit is cut off holding the one artifact the workflow needs, and the round is
// scored as if it had never run. Measured: three rounds in a row ended at 100/101/100 tool calls
// with the verdict never returned. Investigating less is the wrong lesson; returning EARLIER is
// the right one — an honest partial verdict is worth infinitely more than a perfect unreturned one.
const VERDICT_BEFORE_BUDGET = `
RETURN YOUR VERDICT BEFORE YOU RUN OUT OF TURNS. Your turn budget is finite and the structured verdict is your LAST action, so it is the one thing you can lose by running long — and if you lose it, this whole round counts as if you never ran, no matter how good the review was. So: as soon as you have enough to judge, stop investigating and return. If you notice you are deep into your budget with threads still open, do NOT keep digging — post what you have to the PR/MR, then return the verdict with what you did not get to named in it. "approved:false, and here is what I could not finish" is a real, useful answer. Silence is not.`

// A reviewer that ran out of turns leaves its findings ON THE PR/MR and returns nothing. This
// reads them back, so a review that happened is not thrown away for want of a return value.
const SALVAGE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unresolved_count'],
  properties: {
    unresolved_count: { type: 'integer' },   // unresolved reviewer findings currently on the PR/MR
    reviewed: { type: 'boolean' },           // did this reviewer post a real review pass at all?
    detail: { type: 'string' },              // one line per finding, or why none were found
  },
}
// One ticket-status move (the workflow's monotonic status driver — see moveTicket).
const STATUS_MOVE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['moved'],
  properties: {
    moved: { type: 'boolean' }, // true ONLY after the --status write actually persisted (re-read to confirm)
    status: { type: ['string', 'null'] }, note: { type: 'string' },
  },
}
const SUMMARY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['summary_path'],
  properties: {
    summary_path: { type: 'string' }, run_total_output: { type: ['number', 'string', 'null'] },
    token_table_appended: { type: 'boolean' }, // true ONLY if the parser ran and its table was appended (⑤)
    note: { type: 'string' },
  },
}
const NOTIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['sent'],
  properties: {
    sent: { type: 'boolean' }, // true ONLY after the notify adapter exited 0 (printed ok=1)
    channel: { type: ['string', 'null'] }, permalink: { type: ['string', 'null'] },
    note: { type: 'string' },
  },
}

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────
// Coarse per-phase output-token attribution (the faithful per-repo/role table
// comes from /summarize-workflow-performance afterward). spent() is shared.
const spend = []
let mark = budget.spent()
let trackerReachable = true // set by the scope stage; false → tracker writes (status/comments/improvement tickets) won't persist this run
// Set after Build if any repo's guardian/perf gate reported gate_unavailable (the configured
// quality/perf gate could not actually run). Fail-open policy: the run still merges/ships, but
// this is surfaced loudly (summary banner + run result) so it is never read as gate-validated.
let qualityGateUnavailable = null
// Set when a LOAD suite ran green but its base-branch comparison could not produce a verdict
// (the environment's noise floor is wider than the effect). Same loud-skip treatment: the run
// continues, and the summary says plainly that "no slower than base" is unproven.
let loadtestGateUnavailable = null
const tick = (label) => { const now = budget.spent(); spend.push({ label, out: now - mark }); mark = now }

// agent() THROWS when a subagent never returns StructuredOutput (after the engine's
// retries/nudges) — an uncaught throw aborts the ENTIRE run. safeAgent swallows that to
// null so the caller can degrade gracefully (re-loop, or halt THIS repo with a clean
// status) instead of killing the whole run. Generalizes the build-agent null-guard to
// every fix/review/merge/etc. agent() call. (Finding ⑥, 2026-06-07.)
const safeAgent = async (prompt, opts) => {
  try { return await agent(prompt, opts) }
  catch (e) {
    log(`⚠️ agent did not converge${opts?.label ? ` (${opts.label})` : ''} — treated as null: ${String(e?.message || e).slice(0, 140)}`)
    return null
  }
}

// ── Ticket status — OWNED BY THE WORKFLOW (option 2: decoupled from per-repo agents) ──
// The single ticket is shared by every repo it touches, so NO per-repo agent writes its
// status (that caused non-monotonic thrash — e.g. the test-suite planner jumping a still-
// building ticket to "testing"). Instead the WORKFLOW moves it FORWARD ONLY, once per
// aggregate milestone, through one confirmed helper.
//
// STATUS_ORDER is the canonical lifecycle rank (low → high). STATUS (generated from
// workspace.config.yaml) supplies the org's REAL name for whichever of these it declares;
// any it omits are simply skipped. At each milestone moveTicket() is given a PREFERENCE
// list and picks the first status that is (a) declared by the org and (b) strictly forward
// of the current rank — so a rich board (…ready_to_merge…) and the minimal board
// (…ready_to_test…) both work from the same call site.
const STATUS_ORDER = ['to_do', 'not_started', 'in_progress', 'code_review', 'ready_to_merge', 'ready_to_test', 'testing', 'done']
const rankOf = (key) => STATUS_ORDER.indexOf(key)
let statusRank = rankOf('in_progress') - 1 // ticket starts before in_progress (PO set to_do/not_started)
// keys: ordered preference list of canonical status keys for this milestone.
async function moveTicket(keys, why, phaseName, extraClause = '') {
  if (!trackerReachable) { log(`[status] tracker unreachable — ${ticket} NOT moved (${keys.join('/')}); best-effort only.`); return false }
  const cand = keys.find((k) => STATUS[k] && rankOf(k) > statusRank)
  if (!cand) { log(`[status] no forward move for [${keys.join('/')}] (rank ${statusRank}) — skipped (none declared/forward).`); return false }
  const real = STATUS[cand]
  const r = await safeAgent(
    `${tag('all', 'tracker', 'status')} Move ticket ${ticket} Status → "${real}" (canonical "${cand}"; ${why}). Run /update-ticket ${ticket} --status "${real}" through the tracker adapter (scripts/tracker/upsert-ticket-details.sh). Return moved:true ONLY after the write actually persisted (re-read with get-ticket-details.sh to confirm); on a rejected status return moved:false with the adapter's available targets in note. Do NOT do anything else — no branching, no code, no comments.${extraClause}`,
    { agentType: 'developer', model: 'haiku', phase: phaseName, label: `status:${ticket}:${cand}`, schema: STATUS_MOVE_SCHEMA },
  )
  if (r?.moved) { statusRank = rankOf(cand); log(`[status] ${ticket} → ${real} (${cand})`); return true }
  log(`⚠️ [status] move to ${real} (${cand}) NOT confirmed — ${r?.note ?? 'agent did not converge'}; board may be stale.`)
  return false
}

// Topologically sort the scoped repo plans into dependency WAVES. Build no longer
// gates on these waves — every scoped repo is built in parallel (build-order is
// decoupled from merge-order). The waves are kept for their FLATTENED order
// (waveList.flat()), the upstream→downstream sequence the Merge / Distribute phases
// follow. Edges referencing out-of-scope repos are ignored. A cycle/unmet-dep is not
// fatal: the remaining repos are emitted as one final wave so the order still resolves.
function toWaves(plans) {
  const ids = new Set(plans.map((p) => p.repo))
  const deps = {}
  plans.forEach((p) => { deps[p.repo] = (p.depends_on || []).filter((d) => ids.has(d) && d !== p.repo) })
  const done = new Set(); const out = []
  while (done.size < plans.length) {
    const wave = plans.filter((p) => !done.has(p.repo) && deps[p.repo].every((d) => done.has(d))).map((p) => p.repo)
    if (!wave.length) { out.push(plans.filter((p) => !done.has(p.repo)).map((p) => p.repo)); break }
    wave.forEach((r) => done.add(r)); out.push(wave)
  }
  return out
}

// The fingerprint of what is still unresolved this round. Two identical fingerprints with no
// new commit in between means the loop is not converging — it is repeating. Pure and top-level
// on purpose: the one thing worth a runnable check here is that it is stable under key order
// and reordered findings, and unstable when a finding actually changes.
const stallFp = (rows) => JSON.stringify(rows.map(([key, v]) => [
  key,
  (v?.comments || []).map((c) => `${c?.file_line}|${c?.issue}`).sort(),
  (v?.blocking || []).map((b) => `${b?.title}|${b?.scope}`).sort(),
]).sort())

// Required closing step — runs the per-repo/role usage parser over the run's
// transcripts and writes the run-summary file. This agent's prompt intentionally
// OMITS the [dev-cycle …] marker so the parser does NOT count the recorder itself.
async function writeSummary(runStatus, runResult, deferredScopeRun = []) {
  phase('Summary')
  const s = await safeAgent(
    `Run-recorder for the development-cycle workflow on ${ticket} (final status: ${runStatus}). You HAVE the Write tool + a narrow Bash perm for the usage parser — actually PRODUCE the file, do not just describe it.
1. Compose a short narrative: repos touched, per-repo gate/review rounds, the cross-repo test-suite gate result, distribution links, then merge order + SHAs (merge is the FINAL step) — from this run result: ${JSON.stringify(runResult).slice(0, 3000)}.${['repo-unresolved', 'review-regression-halt', 'review-tests-unverified', 'review-stalled', 'review-blocked-on'].includes(runStatus) ? ' Also state plainly, near the top, whether the cross-repo test-suite gate ran: on a stopped run it did NOT, so the change set is UNVALIDATED end-to-end and the run summary must not read as though it were.' : ''}
${deferredScopeRun.length ? `1b. ⚠️ DEFERRED SCOPE — this run did NOT meet every acceptance criterion, by design, and NO follow-up ticket was filed for the gap: it is recorded here for a human to decide what happens to it. Give it its own "## Deferred scope — your decision" section near the TOP (above the narrative), one row per item: the criterion, the repo that deferred it, the owner who can do it, and the evidence given. Then one line naming the decision waiting: file a ticket for these, route them to those owners, or accept the ticket as-is. Items: ${JSON.stringify(deferredScopeRun)}\n` : ''}
${trackerReachable ? '' : '2. ⚠️ The tracker was UNREACHABLE this run — put a prominent note at the TOP that ticket Status moves, comments, and /clarifying-ticket improvement tickets did NOT persist (best-effort only).\n'}${testSuiteGateUnavailable ? `2b. ⚠️ The cross-repo test-suite (QA) gate was REQUESTED for this ticket but did NOT run — put a prominent banner at the TOP (same treatment as the tracker-unreachable note): "${testSuiteGateUnavailable}" The ticket shipped WITHOUT its end-to-end validation, so do NOT describe this run as test-suite-validated.\n` : ''}${qualityGateUnavailable ? `2c. ⚠️ The configured quality/performance gate did NOT run this run — put a prominent banner at the TOP (same treatment as the tracker/test-suite notes): "${qualityGateUnavailable}" Do NOT describe this run as quality-gate-validated.\n` : ''}${loadtestGateUnavailable ? `2d. ⚠️ The load-test BASELINE comparison produced no verdict this run — put a prominent banner at the TOP (same treatment as the notes above): "${loadtestGateUnavailable}" The suite was green, but "no slower than the base branch" is UNPROVEN — do NOT describe this run as performance-validated, and state what would settle it (a run at the planned rate against a scaled environment).\n` : ''}3. WRITE that narrative with the Write tool to agent_logs/${ticket}-DEV-CYCLE-SUMMARY.md at the WORKSPACE (org) ROOT — the workflow's launch directory, the dir that holds .claude/ — NEVER inside a product repo's agent_logs/. Do NOT cd into any repo first; if your cwd is not the workspace root, return there before writing (the root agent_logs dir already exists).
4. As the LAST step, RUN:  python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py ${ticket}  — then Write the file AGAIN as the narrative PLUS the parser's Markdown output appended VERBATIM under a "## Token & time usage" heading. If the parser exits non-zero (no transcripts), write that fact under the heading — never a placeholder.
Return summary_path (the file you actually wrote + confirmed exists via Read), token_table_appended:true ONLY if you ran the parser and appended its real table, and a one-line note.` + LANGUAGE_DIRECTIVE,
    { agentType: 'documentor', phase: 'Summary', label: `summary:${ticket}`, schema: SUMMARY_SCHEMA },
  )
  tick('summary')
  if (s && s.token_table_appended === false) log('⚠️ Summary file written but the token/time table was NOT appended (parser empty/failed) — run parse_workflow_usage.py manually.')
  log(`Run summary: ${s?.summary_path ?? '(summary agent did not converge)'}`)
  return s ?? { summary_path: null, token_table_appended: false, note: 'summary agent did not converge' }
}

// ── Notify (review request) — OPTIONAL phase, runs LAST (after Summary) ──
// Called ONLY from the auto-merge-OFF (merge-skipped) path: every repo is built + reviewed
// and the cross-repo test-suite gate is green, but the validated PR/MR are left OPEN for a
// human to merge — so we ping the team to review them. Gated on notify.enabled (NOTIFY). With
// auto-merge ON the run hands the merge/distribute off to a human (nothing to review), so this is never
// reached. Best-effort: a send failure NEVER changes the run's outcome — the PRs are already
// open + validated. The command is `scripts/voice/notify-voice.sh`, which is send.sh plus a
// voice note: when `voice.notify_voice.enabled` is on (a `th`-only, opt-in, per-machine flag) the
// review request goes out as ONE message carrying the text AND a short spoken line; with the flag
// off — the shipped default, so this is a no-op for the team — it forwards to send.sh verbatim.
// The /notify skill owns the digest: `scripts/notify/send.sh --review <KEY>`
// GATHERS the ticket's open PR/MR across every workspace repo, composes the message, and sends —
// one source of truth for format + gather (no repo missed, nothing hand-assembled here). This
// phase only decides WHETHER to notify: repoResults gives a cheap "is there any open PR?" check
// so we don't spawn an agent for nothing. `reposInOrder` = repo ids in dependency order.
async function notifyReview(reposInOrder) {
  if (!NOTIFY) return null
  phase('Notify')
  const title = scope?.title || plans.find((p) => p?.title)?.title || ''
  if (!reposInOrder.some((id) => repoResults[id]?.pr?.pr_url)) {
    log('[notify] no open PR/MR to announce — Notify skipped.'); return null
  }
  const channelArg = NOTIFY_CHANNEL ? ` --channel ${JSON.stringify(NOTIFY_CHANNEL)}` : ''
  const titleArg = title ? ` --title ${JSON.stringify(title)}` : ''
  const r = await safeAgent(
    `${tag('all', 'notifier', 'notify')} Post the review-request notification for ${ticket} via the /notify skill. ONE command does it all — it gathers the ticket's open PR/MR across every workspace repo, composes the digest, and sends. Run it from the WORKSPACE (org) ROOT (the dir holding .claude/); do NOT cd into a repo, touch git, or the tracker.

scripts/voice/notify-voice.sh --review ${ticket}${titleArg}${channelArg}

On success it prints \`ok=1\` and a \`permalink=\` line. Return sent:true ONLY if it exited 0 (printed ok=1), with the permalink + channel="${NOTIFY_CHANNEL}" when printed; on ANY failure (including "no open PR/MR found … nothing to announce") return sent:false with the command's stderr in note. Do NOT retry more than once.`,
    { agentType: 'documentor', phase: 'Notify', label: `notify:${ticket}`, schema: NOTIFY_SCHEMA },
  )
  tick('notify')
  log(`[notify] review request → ${NOTIFY_CHANNEL || '(default channel)'}: ${r?.sent ? (r.permalink || 'sent') : `NOT sent (${r?.note ?? 'agent did not converge'})`}`)
  return r ?? { sent: false, note: 'notify agent did not converge' }
}

// ──────────────────────────────────────────────────────────────────────────
// PER-REPO PIPELINE  —  build ↔ gates ↔ PR ↔ review for ONE repo, up to
// "approved, ready to merge". This is the OLD single-repo flow, parameterized by
// the repo descriptor. Does NOT merge (merge is the ordered, cross-repo phase).
// Returns { repo, status:'ready'|'build-unresolved'|'pr-unresolved'|'review-unresolved'|'review-tests-unverified'|'review-regression-halt'|'review-stalled'|'review-blocked-on', ... }.
// NOTE: never calls phase() — multiple of these run in parallel within a wave, so
// every agent() sets opts.phase explicitly to avoid racing the global phase state.
// ──────────────────────────────────────────────────────────────────────────
async function runRepoPipeline(rp, desc, branchKind) {
  const R = rp.repo
  // The agent's shell starts at the WORKSPACE ROOT, not in the repo — so "cwd <repo>/" was a
  // cwd it did not have, and the only one-liner that fixes it (`cd <repo> && <writer>`) is the
  // exact compound form the adapter guard denies silently. Hand it the absolute path and the
  // cd-persists fact instead; that is the whole gap the two side-door incidents fell through.
  const absRepo = haveAbs ? `${WORKSPACE_ROOT}/${desc.path}` : desc.path
  const inRepo = `Work in the ${R} repo — its path is ${absRepo}. Your shell starts at the workspace root and Bash cwd PERSISTS between tool calls, so enter the repo with ONE standalone \`cd ${absRepo}\` call and stay there; never prefix a later command with \`cd … &&\`. VCS ADAPTER CALLS NEED MORE THAN THAT: several repos build in parallel this run, sharing ONE Bash session, so a concurrent repo's \`cd\` can leave you pointed at the wrong repo at the exact moment you call \`scripts/vcs/*.sh\` — cwd alone is not reliable for that adapter here. Resolve VCS_REPO ONCE, in its own standalone command: \`git -C ${absRepo} remote get-url origin\`. From what it prints, strip the leading \`git@<host>:\` or \`https://<host>/\` and any trailing \`.git\` — what remains (\`owner/repo\` on GitHub, \`group/subgroup/project\` on GitLab) is this repo's VCS_REPO. Prefix EVERY \`scripts/vcs/*.sh\` call for the rest of this task with it, as a plain env-var on the SAME bare line as the writer — \`VCS_REPO=<that value> scripts/vcs/<script>.sh …\` — never inside \`$( )\`, a pipe, or \`&&\` (any of those denies the call silently, same as wrapping the writer itself).`

  // BUILD — initial implementation from the plan. Code repos: developer (TDD).
  // The test-suite repo: qa-runner branches, implements POM, iterates SCOPED, then
  // runs the ticket scope (spec(s) + regression specs) before handoff (full-suite run is
  // on-demand, not here) — and never opens/merges the PR here.
  // NOTE: build agents do NOT touch the ticket status — the workflow owns it (moveTicket).
  // SUBMODULE PIN AT BUILD TIME. This repo's harness may build its DB/fixtures from a vendored
  // submodule checkout, so a pin at a pre-migration commit makes the suite run green against a
  // tree that does not contain the change it is meant to prove — or red for a reason that is not
  // the ticket. Narrow on purpose: only a DECLARED dependency (depends_on, from Scope), only when
  // .gitmodules actually declares the path, and only as far forward as we can justify. This does
  // NOT reintroduce build-order serialization: nothing here waits on another repo — the target is
  // either "already built this run" (doneAt, C2) or "as far merged as the upstream's own base".
  const pinUpstreams = (rp.depends_on || []).filter((u) => REPOS[u])
  const pinTargets = pinUpstreams.map((u) => ({
    repo: u, path: REPOS[u].path,
    target: doneAt(u, 'built')
      ? `the tip of ${rowAt(u, 'built')?.work_branch || `${branchKind}/${ticket}`} on origin (run state: already built for this ticket)`
      : `origin/${REPOS[u].base[branchKind]} (not yet built this run — its merged base is as far as you may go)`,
  }))
  const submodulePinClause = pinTargets.length
    ? ` SUBMODULE PIN (check before you run the suite): this repo declares ${pinTargets.map((p) => `${p.repo} (path "${p.path}")`).join(', ')} as an upstream for ${ticket}. ⚠️ If your harness builds its schema, migrations or fixtures from a vendored checkout of one of those, a stale pin makes your suite prove nothing. For EACH of them: (1) detect, do not guess — \`git config -f .gitmodules --get-regexp path\` from this repo's root. If .gitmodules does not declare that path, do NOTHING and say so; that is the normal answer. (2) If it IS declared, bring the pin forward to: ${pinTargets.map((p) => `${p.repo} → ${p.target}`).join('; ')}. Commit the pointer move on its own: \`git -C <path> fetch origin && git -C <path> checkout <the sha> && git add <path> && git commit -m "chore(<path>): bump submodule pin for ${ticket}"\`. (3) NEVER edit files INSIDE the submodule checkout — a guard blocks it, and that repo's primary clone is at the workspace root. If the pin is already at or ahead of the target, leave it and say so.`
    : ''
  const buildPrompt = desc.kind === 'test-suite'
    ? `${tag(R, desc.build, 'build', 0)} Build the test-suite automation for ${ticket} in the ${R} repo from the plan at ${rp.plan_path} (behaviour reference: agent_logs/${ticket}-testcases.md). ${inRepo}${candidateStackClause(plans.filter((p) => p.repo !== R && !REPOS[p.repo].testSuite))}
1. BRANCH ONLY — create it with EXPLICIT git, never a skill that resolves its own base: \`git fetch origin && git switch -c ${rp.work_branch} origin/${rp.base_branch}\`. The base is ${rp.base_branch} because THIS RUN says so — do not re-derive it from \`origin/HEAD\`, \`default-branch.sh\`, or the repo's usual default, which is how a run's base override gets silently discarded. PROVE it before step 2: \`git rev-parse HEAD\` == \`git rev-parse origin/${rp.base_branch}\` and \`git log --oneline origin/${rp.base_branch}..HEAD\` prints nothing; report both. If the branch already exists on the wrong base, recreate it. Do NOT finish/merge (the workflow opens + merges the PR later, in order).
2. IMPLEMENT — strictly POM via /coding-automate ${ticket}, in THIS repo's own layout and idiom (read its CLAUDE.md + .claude/rules/ — never assume a directory or a framework). Each test's title MUST open with its TC id from agent_logs/${ticket}-testcases.md, and each scenario MUST end by capturing a screenshot: the runner names artifacts after the test title, so that id is what ties the evidence to the results row. Commit each slice conventionally (Refs ${ticket}).
3. ITERATE SCOPED, not full — while building/fixing one feature run only its spec(s), through THIS repo's harness: \`scripts/dev.sh test <the repo's own spec-scoping args>\`. Do NOT run the whole suite on every change, and do NOT reach for \`npm test\` — in several repos here it is a stub that exits 1.
4. BOUNDED TRIAGE on a break — re-run the broken case ONCE (the same scoped \`scripts/dev.sh test\` + ONE \`scripts/dev.sh why test\`), classify it, then ACT and MOVE ON — do not keep digging:
   • automation/selector/flake → fix the spec/Page Object and re-run that one case until green.
   • genuine APP/feature bug → log it to agent_logs/${ticket}-bugs.md and comment it ON THE TICKET (scripts/tracker/add-ticket-comment.sh) with the repro AND the failure screenshot's path from \`scripts/dev.sh artifacts\`, then move on. You own the ${R} repo ONLY — NEVER read, reason about, or edit the app repo's SOURCE; root-causing app behaviour is the developer's job at the test-suite gate, not yours. That bans READING and EDITING app code, and nothing else: RUNNING an app repo's own harness to stand its service up (\`<repo>/scripts/dev.sh run\`) is expected of you, not a scope violation — see step 0.
   • a brand-new feature spec red only because the app change is not built into this run yet is EXPECTED — note it and move on; it validates at the test-suite gate against the candidate build, not here.
5. SCOPED RUN before handoff — once your automation is correct, run THIS ticket's scope ONCE via \`scripts/dev.sh test <scoping args>\` covering (a) the ticket's own spec(s) you built + (b) the ticket's regression spec(s) from the "**Regressions**" block at the bottom of agent_logs/${ticket}-testcases.md (the dev's "⚠️ Regression request" — the SOLE source of regression scope; if that block is absent there is NO regression scope, so run just the ticket's spec(s)). Do NOT run the whole suite (\`scripts/dev.sh test\` with no scoping args): the full-suite run is ON-DEMAND only (the user triggers a full run separately), not part of this flow. Then confirm \`scripts/dev.sh artifacts\` lists a capture per scenario you automated — a green run with no rows means the capture step did not take effect, and the results report will have nothing to attach. ${desc.green} is the target — but a scoped red caused ONLY by reported app bugs or expected pre-merge reds is a VALID handoff state; record it, do not chase it.
6. RETURN CONTRACT (mandatory) — /handoff, then END by calling StructuredOutput with the DEV_SCHEMA result: work_branch=${rp.work_branch}, a one-line summary of the suite state (green, or red + the bug ids you reported), commit count, status="complete" (a green run, OR a red caused only by reported app bugs / expected pre-merge reds — both are a valid complete handoff for this phase) else "partial"/"blocked" with what's left in "remaining", and in "fixed" the spec/Page Object files you touched. Do NOT move the ticket status — the workflow does that. A red-but-reported suite is SUCCESS for this phase — never withhold the structured result to investigate further, and never exceed the step-4 triage budget.`
    : `${tag(R, desc.build, 'build', 0)} Implement ${ticket} in the ${R} repo on branch ${rp.work_branch} from the plan at ${rp.plan_path}. ${inRepo} Treat this repo's docs/adr/* and CONTEXT.md as AUTHORITATIVE context the plan defers to: read them FIRST, and where the plan text and an ADR disagree, the ADR wins. If ${rp.work_branch} ALREADY exists with prior work (an approved re-run over an existing branch), RECONCILE existing code that contradicts the updated ADRs/plan — reshape it to the canonical schema/shape (e.g. a stale snake_case seed → the canonical kebab/Section schema) rather than only appending new code on top of the old shape. Run /coding-feature (it loads this repo's CLAUDE.md + coding_standards AND the workspace coding-style — storytelling code, NO body comments — "read before your first edit", and its Step 4 drives the build test-first through /tdd's red-green-refactor loop) and /karpathy-guidelines, committing each slice conventionally (Refs ${ticket}), keep ${desc.green}. When the Definition of Done is met, /handoff. Do NOT move the ticket status — the workflow owns it.${outOfReachBrief}${submodulePinClause} When you post your dev-status comment on the ticket, and you are handing back any \`deferred\` criterion, give it ONE line there naming the criterion and its owner — the ticket should record what this run did not deliver, and no separate ticket is filed for it.`
  // RESUME: a 'built' row whose recorded head still matches the live branch means this repo's
  // build already landed on an earlier invocation — skip re-paying for it (docs/adr/0018).
  const builtRow = rowAt(R, 'built')
  let dev = builtRow
    ? { work_branch: builtRow.work_branch || rp.work_branch, summary: `resumed from run state (head ${String(builtRow.head_sha).slice(0, 8)} unchanged)`, status: 'complete', fixed: [] }
    : await safeAgent(
        buildPrompt + BUILD_DISCIPLINE + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + FIGMA_DIRECTIVE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE
          + stateWrite(R, 'built') + ` If your handoff status is "deferred", write that RUN-STATE file with "status":"in-progress" instead of "done" — a deferred build is deliberately NOT checkpointed as built, because the deferral itself (deferred[]/met_acceptance[]) does not fit in a state row and must be re-derived by the next invocation.`,
        { agentType: desc.build, phase: 'Build', label: `build:${ticket}:${R}`, schema: DEV_SCHEMA },
      )
  if (builtRow) log(`[${R}] build SKIPPED — run state says built at ${String(builtRow.head_sha).slice(0, 8)} and the branch has not moved.`)
  // CONVERGENCE RETRY — a null build means the agent never produced a structured
  // handoff (it ran away triaging a red / reformatting instead of returning). Don't abort the
  // wave: retry ONCE with a bounded "stop working, hand off NOW" continuation, bumped to opus +
  // high so the wrap-up is reliable. It must emit DEV_SCHEMA with whatever state it reached
  // (status partial/blocked is fine) — no new work.
  if (!dev) {
    log(`⚠️ [${R}] build returned no structured handoff — retrying once (bounded: emit handoff now, no more work).`)
    dev = await safeAgent(
      `${tag(R, desc.build, 'build', 1)} Your build of ${ticket} in the ${R} repo (branch ${rp.work_branch}, plan ${rp.plan_path}) did NOT return a structured handoff last time — you likely ran away triaging a red or reformatting. ${inRepo} STOP doing work now: run NO more tests, fixes, or formatters. Two things only, in ONE step. FIRST, leave no dirty tree: \`git status --porcelain\` — if anything is uncommitted, PARK it (a \`wip(<scope>): … Refs ${ticket}\` commit on ${rp.work_branch}, or \`git stash push -u -m "${ticket} …"\`) and record where it went; NEVER \`git checkout .\`/\`git restore .\`/\`git reset --hard\`. SECOND, END by calling StructuredOutput with the DEV_SCHEMA result — work_branch=${rp.work_branch}, a one-line summary, commit count, the files you touched in "fixed", status="complete" ONLY if the Definition of Done is genuinely met else "partial" (slices landed, work remains) or "blocked" (cannot proceed). For partial/blocked also fill "remaining" (what is left and why), "root_cause" (the MEASURED cause at file:line — never "unknown"), "commands_run" (each command you ran + its exit code), "decision_needed" if a human must settle a fork, and "parked_at" (the WIP commit sha or stash ref). Returning this handoff IS the task — emit it immediately.`,
      { agentType: desc.build, model: 'opus', effort: 'high', phase: 'Build', label: `build-handoff:${ticket}:${R}`, schema: DEV_SCHEMA },
    )
  }
  if (!dev) {
    log(`⚠️ [${R}] build did not converge to a structured handoff even after the bounded retry — left mid-flight; downstream skipped.`)
    return { repo: R, status: 'build-unresolved', plan: rp, handoff: { status: 'blocked', summary: 'build agent never returned a structured handoff (2 attempts)', remaining: `no handoff was produced, so nothing is known about what landed. Recover the state from the branch itself, in ${desc.path}: \`git log --oneline ${rp.base_branch}..${rp.work_branch}\` for what was committed, \`git status --porcelain\` for work left uncommitted, and \`git stash list\` for anything parked.`, decision_needed: 'whether to keep whatever is on the work branch and continue, or reset it and re-run the build from the plan' } }
  }
  // DEFERRED — the repo's own work is green and what remains belongs to another owner. The run
  // continues (docs/adr/0011), but the claim is audited first, because `deferred` is the one status
  // an agent could reach for to escape work it actually owns:
  //   1. structurally — deferred[] entries with an owner AND observed evidence, or it is not a claim;
  //   2. against the SETTLED list — a criterion scope already declared out of reach needs no further
  //      adjudication, so a run pays for a verifier only on a deferral nobody foresaw;
  //   3. by a verifier — one agent reads the diff, the branch state and the evidence, and downgrades
  //      an unevidenced deferral to `partial`, which stops the repo exactly as before.
  let deferredScope = []
  if (dev.status === 'deferred') {
    const claimed = (dev.deferred || []).filter((d) => d?.criterion && d?.owner && (d?.evidence || '').trim().length > 20)
    if (!claimed.length) {
      log(`⚠️ [${R}] handoff claimed status=deferred but carried no evidenced deferral — treating it as PARTIAL (the repo stops). Deferring requires per-criterion owner + observed evidence.`)
      dev.status = 'partial'
      dev.remaining = `${dev.remaining || ''} [workflow: a 'deferred' handoff was downgraded to 'partial' because ${(dev.deferred || []).length ? 'its entries carried no observed evidence' : 'it named no deferred criterion'}.]`.trim()
    } else {
      const settled = (c) => outOfReach.some((o) => {
        const a = o.criterion.toLowerCase().replace(/\s+/g, ' ').trim()
        const b = c.toLowerCase().replace(/\s+/g, ' ').trim()
        return a.includes(b) || b.includes(a)
      })
      const novel = claimed.filter((d) => !settled(d.criterion))
      let upheld = true
      let downgradeReason = null
      if (novel.length) {
        const verdict = await safeAgent(
          `${tag(R, 'general-purpose', 'verify-deferral')} ADJUDICATE a deferral claim for ${ticket} in the ${R} repo — read-only, no edits, no commits, no tracker or PR writes. ${inRepo}
The build agent reports its own work COMPLETE and green, and claims ${novel.length} acceptance criterion/criteria cannot be met HERE because they belong to another owner. Your job is to decide whether that is true of the CODE, or whether it is work this repo could in fact do.
THE CLAIMS: ${novel.map((d, i) => `(${i + 1}) criterion "${d.criterion}" — owner claimed: ${d.owner} — why: ${d.why} — evidence offered: ${d.evidence}`).join(' ')}
CHECK, in this order, and quote what you find:
1. The evidence is REAL: open each file:line, config value or command the claim cites and confirm it says what the claim says. An unverifiable citation fails the claim.
2. The work is genuinely OUTSIDE this repo: nothing in this repo's own source could satisfy the criterion. Grep for the mechanism before you agree — if the fix would live in a file here, the claim is false however hard the work is.
3. The rest really is done: \`git status --porcelain\` is clean and \`git log --oneline origin/${rp.base_branch}..${rp.work_branch}\` lists real commits. A "deferred" claim over an empty or dirty branch is false by definition.
Uphold ONLY what all three support. Difficulty is NOT deferral: "this needs a big refactor", "the tests are awkward", "I ran out of budget" are all work this repo owns. Return upheld:false with a one-line reason naming the claim you rejected and what in this repo could do it.`,
          { agentType: 'general-purpose', model: 'sonnet', phase: 'Build', label: `verify-deferral:${ticket}:${R}`, schema: DEFERRAL_VERDICT_SCHEMA },
        )
        if (!verdict) {
          log(`⚠️ [${R}] the deferral verifier did not converge — the claim stands unaudited, so it is NOT trusted: treating as PARTIAL (the repo stops).`)
          upheld = false
          downgradeReason = 'the deferral verifier did not converge, and an unaudited deferral is not trusted'
        } else if (verdict.upheld === false) {
          upheld = false
          downgradeReason = verdict.reason || 'the verifier rejected the deferral'
        } else {
          log(`[${R}] deferral upheld by the verifier: ${novel.length} novel criterion/criteria genuinely owned elsewhere.`)
        }
      } else {
        log(`[${R}] deferral matches the out-of-reach list scope already settled — no verifier needed.`)
      }
      if (!upheld) {
        log(`⚠️ [${R}] DEFERRAL REJECTED — ${downgradeReason}. Treating as PARTIAL: the repo stops here rather than shipping with a criterion it could have met.`)
        dev.status = 'partial'
        dev.remaining = `${dev.remaining || ''} [workflow: a 'deferred' handoff was downgraded to 'partial' — ${downgradeReason}.]`.trim()
      } else {
        deferredScope = claimed
      }
    }
  }
  // A converged-but-not-complete handoff (partial/blocked) is a CLEAN stop for THIS repo: the whole
  // change set must be ready before any merge, so we surface the handoff rather than pretend ready.
  if (dev.status && dev.status !== 'complete' && dev.status !== 'deferred') {
    log(`⚠️ [${R}] build handoff status=${dev.status}: ${(dev.remaining || dev.summary || '(no detail)').slice(0, 140)} — repo not build-complete; downstream skipped.`)
    return { repo: R, status: 'build-unresolved', plan: rp, handoff: { status: dev.status, summary: dev.summary, remaining: dev.remaining, root_cause: dev.root_cause, commands_run: dev.commands_run, decision_needed: dev.decision_needed, parked_at: dev.parked_at } }
  }
  log(`[${R}] initial build: ${dev.summary?.slice(0, 70) ?? 'done'}`)
  tick(`${R}:build`)

  // ONE rendering of the deferral, reused by the PR body, the reviewers' bar and the merge command,
  // so the person clearing the merge, the reviewer judging the diff and the summary all read the
  // same sentence — and there is a single place to change it.
  const deferredNote = deferredScope.length
    ? `\n\n**Deferred scope** — this branch does NOT meet every acceptance criterion, by design:\n${deferredScope.map((d) => `- ${d.criterion} — owned by ${d.owner}. ${d.why}`).join('\n')}\nMet here: ${(dev.met_acceptance || []).length ? (dev.met_acceptance || []).join('; ') : '(the build named none)'}. No follow-up ticket was filed; the deferred items ride the run summary for a human to decide.`
    : ''

  // OPEN PR — open the PR/MR right after build so EVERY reviewer comments on the OPEN
  // PR/MR via the VCS adapter. Code repos via /open-pr; the test-suite repo via the adapter
  // directly. Open ONLY — never merge (the final cross-repo Merge phase merges).
  const openPrPrompt = desc.kind === 'test-suite'
    ? `${tag(R, desc.build, 'open-pr')} The ticket scope (spec(s) + regression specs) for ${ticket} is green in ${R}. ${inRepo} Ensure git status is clean, then open the PR/MR with the VCS adapter (it pushes ${rp.work_branch} for you): \`scripts/vcs/open-pr.sh --base ${rp.base_branch} --head ${rp.work_branch} --title "${prTitle(rp)}" --body "<what was automated + the scoped (ticket spec(s) + regression) green evidence>${deferredNote ? ' PLUS the Deferred scope block below, verbatim' : ''}"\`.${deferredNote} The title is Conventional Commits (\`<type>(${ticket}): <title>\`) — keep it exactly as given. Do NOT merge it — the workflow squash-merges in dependency order. Return the PR/MR URL (pr_url) + number (the adapter prints \`number=<n>\`).`
    : `${tag(R, desc.build, 'open-pr')} ${ticket} is built in ${R} — open the PR/MR now so the reviewers (code-reviewer + guardian + performance) can review it on the host. ${inRepo} PRECONDITION — before you run /open-pr, confirm the base exists on the remote: \`git ls-remote --exit-code --heads origin ${rp.base_branch}\`. If it does not, STOP: do not push the base yourself and do not retarget. Return the failure as the result for this step — the exact command, its exit code, and \`git push origin ${rp.base_branch}\` as the unblocking command. Otherwise: ensure git status is clean (commit any stray artifact), then run /open-pr ${ticket} to open the PR/MR for ${rp.work_branch} → ${rp.base_branch}, titled per Conventional Commits "${prTitle(rp)}". THE BASE IS ${rp.base_branch}, stated by this run: pass it to the skill and do NOT let the branch model re-derive it from the branch prefix — that derivation answers where a branch of this shape USUALLY goes, and silently retargets a run that overrode its base.${deferredNote ? ' The PR/MR body MUST carry the Deferred scope block below verbatim — a reviewer must not have to guess which criteria this branch leaves unmet.' : ''} Do NOT merge it. Return the PR/MR URL + number.${deferredNote}`
  // RESUME: a 'pr_open' row is only usable when it actually carries a number/url — a row with
  // neither is unusable, and every downstream prompt interpolates pr.pr_number ?? '<number>', so
  // falling through to the live call beats letting a placeholder reach a real adapter call.
  const prRow = rowAt(R, 'pr_open')
  const prRowUsable = !!(prRow && (prRow.pr_number || prRow.pr_url))
  const pr = prRowUsable
    ? { pr_url: prRow.pr_url || null, pr_number: prRow.pr_number ?? null }
    : await safeAgent(
        openPrPrompt + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + stateWrite(R, 'pr_open', ',"pr_number":<the PR/MR number>,"pr_url":"<the PR/MR url>"'),
        { agentType: desc.build, phase: 'Open PR', label: `open-pr:${ticket}:${R}`, schema: PR_SCHEMA },
      )
  if (!pr) {
    log(`⚠️ [${R}] open-PR did not converge — left for human review.`)
    return { repo: R, status: 'pr-unresolved', plan: rp }
  }
  if (prRowUsable) log(`[${R}] open-PR SKIPPED — run state says pr_open at ${pr.pr_url || pr.pr_number}.`)
  log(`[${R}] opened PR: ${pr.pr_url}`)
  tick(`${R}:open-pr`)

  // REVIEW — code-reviewer + guardian + performance ALL review the OPEN PR/MR, each
  // commenting via the VCS adapter (never the tracker). FREEZE-once-passed: a reviewer
  // that verdicts passed/approved is frozen and NOT re-reviewed in later rounds — only
  // the still-open reviewers re-run. FIRST REVIEW is each reviewer's ONE complete pass
  // (the whole change set, every must-fix in one batch — the CLOSED finding set). The
  // developer fixes the combined batch on the PR/MR; every later round is a RE-VISIT:
  // each reviewer verifies ONLY its own first-review findings (its PR/MR threads) are
  // resolved and raises NOTHING new — round-capped. The ONE exception is a fix-CAUSED
  // regression (a new blocking problem the fix itself introduced): the reviewer flags it
  // (fix_regression) and the workflow HALTS this repo loudly (status review-regression-halt)
  // for human action, PR left OPEN — re-run the dev-cycle to resume. A crashed reviewer is
  // INCONCLUSIVE (re-runs in first-review mode, never a silent pass). The test-suite repo
  // has no reviewers → it is ready as soon as the PR/MR is open.
  // HONOR THE LIVE PROVIDER (OFB-2141 §2.3): when quality_gate.provider is 'none' the guardian
  // gate is skipped entirely (auto-pass) — it never spins up an agent and so never attempts
  // SonarQube nor risks tripping a usage-policy safeguard.
  if (desc.guard && QUALITY_GATE === 'none') log(`[${R}] quality_gate.provider=none — guardian gate skipped (auto-pass, no SonarQube attempt).`)
  const reviewers = [
    // tests_green is part of the pass predicate, not just the brief: an approval that cannot point
    // at a suite the reviewer actually ran is the exact failure the green gate exists to prevent,
    // so the workflow enforces it deterministically rather than trusting the return text.
    desc.review && { key: 'review', role: desc.review, schema: REVIEW_SCHEMA, passed: (r) => r?.approved === true && r?.tests_green === true, open: (r) => r?.comments?.length || 0 },
    desc.guard && QUALITY_GATE !== 'none' && { key: 'guard', role: 'guardian-engineer', schema: GATE_SCHEMA, passed: (r) => r?.passed === true, open: (r) => (r?.blocking?.length || 0) + (STRICT ? 0 : (r?.fold_in?.length || 0)) },
    desc.perf && { key: 'perf', role: 'performance-engineer', schema: GATE_SCHEMA, passed: (r) => r?.passed === true, open: (r) => (r?.blocking?.length || 0) + (STRICT ? 0 : (r?.fold_in?.length || 0)) },
  ].filter(Boolean)
  if (!reviewers.length) {
    log(`[${R}] no reviewers (QA repo) — ready to merge.`)
    return { repo: R, status: 'ready', plan: rp, pr, reviewRound: 0, verdict: {}, deferred: deferredScope, met_acceptance: dev.met_acceptance || [], build: { summary: dev.summary, fixed: Array.isArray(dev.fixed) ? dev.fixed : [] } }
  }

  const verdict = {}, done = {}, didFirstReview = {}
  // Gates (guard/perf) that reported gate_unavailable — frozen as UNAVAILABLE (not a pass,
  // not a dev-fixable finding). key → reason. Surfaced loudly by the workflow (fail-open).
  const gatesUnavail = {}
  // RESUME: this repo already reached 'reviewed' on an earlier invocation and its branch has not
  // moved since — skip the whole review↔fix loop rather than re-paying for it (docs/adr/0018).
  if (doneAt(R, 'reviewed') && pr) {
    log(`[${R}] review SKIPPED — run state says reviewed and the branch has not moved. PR ${pr.pr_number ?? '?'}.`)
    return { repo: R, status: 'ready', plan: rp, pr, reviewRound: 0, verdict: {}, gatesUnavailable: {}, deferred: deferredScope, met_acceptance: dev.met_acceptance || [], build: { summary: dev.summary, fixed: [] } }
  }
  let reviewRound = 0, fixPasses = 0, lastFixed = []
  let lastFp = null, stalled = 0
  while (reviewRound < MAX_REVIEW_ROUNDS) {
    reviewRound++
    const isRetest = fixPasses > 0
    // MODE is PER-REVIEWER, not per-round. A reviewer does its ONE full "first review" the first time
    // it COMPLETES a pass; every later pass is a "re-visit" — verify ONLY its own first-review findings
    // (the PR/MR threads it opened) are resolved, raise NOTHING new. A reviewer that has only ever
    // crashed has no first review yet, so it stays in first-review mode (never re-visits empty-handed).
    const modeThisRound = {}
    reviewers.forEach((rv) => { modeThisRound[rv.key] = didFirstReview[rv.key] ? 'revisit' : 'first' })
    const changed = lastFixed.length ? ` The developer's last fix touched: ${lastFixed.join('; ')} — look there to confirm your threads are resolved and to judge whether the fix itself caused a regression.` : ''
    const prRef = `the OPEN PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}; ${rp.work_branch} → ${rp.base_branch})`
    // GREEN GATE (code reviewer only — it is the one gate holding the scripts/dev.sh grant).
    // A review that never ran the suite cannot say the PR/MR doesn't break the tests, so
    // approved:true is gated on a receipt from a run the reviewer ACTUALLY performed. Mirrors
    // the gate_unavailable contract the guardian + performance gates already use: a suite that
    // could not run is UNVERIFIED, never a silent pass.
    const greenGate = `🛑 MUST DO before you approve — RUN THE SUITE yourself on ${rp.work_branch} (workflow step 5, "Verify green"): \`scripts/dev.sh test\` from inside ${R}, plus \`scripts/dev.sh analyze\`/\`gen\` when this repo's definition of green names them — green here means "${desc.green ?? 'the repo suite passes'}". Run the WHOLE suite, never the raw toolchain (cargo/npm/pnpm), and drill a failure with \`scripts/dev.sh why test\` rather than dumping the log. The developer built on this same clone, so HEAD should already be ${rp.work_branch} — confirm with \`git rev-parse HEAD\` before trusting the run. Return tests_green + tests_receipt (the invocation and its result). A RED suite is a must-fix: comment it inline (failing test + shortest decisive output line + the change you believe caused it) and return approved:false — but first rule out a KNOWN FALSE-RED by re-running it in isolation against ${rp.base_branch}${desc.knownFalseReds ? `. This repo declares its own: ${desc.knownFalseReds}` : ' — this repo declares none, so judge the red on its own evidence'}. If the suite needs a local stack, bring it up via that repo's own harness (\`<dep-repo>/scripts/dev.sh run\`) and re-run — "the environment was down" is not an answer. If it STILL genuinely cannot run, set tests_green:false + gate_unavailable:true + unavailable_reason (what you tried, why each attempt failed, the exact unblocking command), post ONE loud PR/MR comment that the test gate could not run, and do NOT approve — never fabricate a green.
BUDGET A RED, DO NOT CHASE IT. Classifying a red is bounded work: ONE isolated re-run of that test decides it, and a diff of the files on its path against ${rp.base_branch} settles whose red it is. That is enough to call it pre-existing and move on — say so in one line and keep going. Two dead ends specifically, both already paid for: a throwaway \`git worktree\` cannot reproduce anything that needs credentials, because a new worktree has NO \`.env\` and copying one there is forbidden, so every test in it dies at "environment variable not found"; and re-triaging a red you already classified in an earlier round buys nothing. If a red resists that bounded check, report it as unattributed with what you tried — an unattributed red is a legitimate finding, and spending the rest of your turns on it is not.`
    // RE-VISIT — uniform across all three reviewers, with a per-role "what to re-check" line. The
    // first review is the COMPLETE, CLOSED finding set: confirm your OWN prior findings are addressed,
    // add nothing new. The ONE exception is a fix-CAUSED regression → fix_regression + a loud comment;
    // the workflow halts the repo for human action rather than looping the dev.
    const revisitTask = (rv) => {
      const recheck = rv.key === 'review'
        ? `Do NOT run /review again — that re-derives a full review from scratch and surfaces new findings, exactly what re-visit forbids. Instead list the review threads YOU opened (\`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\`) and, for each must-fix you raised in your first review, confirm the developer's fix + reply genuinely resolve it. The green gate is NOT scoped down by a re-visit: the developer changed code, so RE-RUN the suite (\`scripts/dev.sh test\` from inside ${R}, plus analyze/gen where this repo's green needs them) and return a FRESH tests_green + tests_receipt — last round's green proves nothing about this commit, and a fix that resolves your thread while breaking a test is exactly what this catches. Return approved:true ONLY when EVERY one of your first-review must-fixes is resolved AND tests_green is true; else approved:false listing which of YOUR threads remain open (a newly-red suite counts as one).${NO_SELF_APPROVE}`
        : `Do NOT re-scan or re-profile broadly. Re-check ONLY the blocking + fold_in items YOU raised in your first review (\`scripts/vcs/pr-comments.sh ${pr.pr_number ?? '<number>'}\` / \`pr-threads.sh\`): confirm each is resolved on the PR/MR. Return passed:true ONLY when EVERY one of your first-review items is resolved; else passed:false listing which of YOUR items remain. File NO new Improvement tickets and add NO new blocking/fold_in items.`
      return `RE-VISIT (round ${reviewRound}) of ${prRef}. ${inRepo} Your first review is the COMPLETE, CLOSED finding set — you are ONLY confirming your OWN prior findings are addressed, NOT reviewing afresh. Raise, comment on, or file NOTHING new.${changed} ${recheck}
THE ONE EXCEPTION — a fix-caused regression: if the developer's fix DIRECTLY caused a NEW blocking problem (a regression the fix introduced — NOT a pre-existing issue your first review missed), do NOT fold it into the loop. Post ONE loud PR/MR comment via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "⚠️ REGRESSION: <what the fix broke + evidence it was this fix>"\`, then return ${rv.key === 'review' ? 'approved:false' : 'passed:false'} with fix_regression:true and regression_detail (what broke, file:line, why it is the fix). The workflow then HALTS this repo loudly for human action — it is not yours to fix in-loop.`
    }
    const scopeNote = `First review (round ${reviewRound}): this is your ONE complete pass — review the whole change set and report EVERY must-fix together in a single batch, because later rounds only RE-VISIT these findings and add nothing new.`
    // THE BAR, INLINE. A reviewer is asked to judge the diff against the ticket's requirements, but
    // no reviewer holds a tracker grant — so a brief that says "read the ticket" points at a door
    // it cannot open, and the agent falls back to inferring the bar from commit messages. The
    // planner already returned the acceptance criteria, so they travel WITH the prompt: deterministic,
    // one network call fewer, and identical on every round.
    const deferredBar = deferredScope.length
      ? ` DEFERRED, already decided — do NOT raise these as must-fixes and do NOT ask for them in this PR/MR: ${deferredScope.map((d) => `"${d.criterion}" (owned by ${d.owner})`).join(', ')}. They are recorded on the MR and in the run summary. What you MAY do is check the diff does not silently half-implement one; say so if it does.`
      : ''
    const theBar = rp.acceptance?.length
      ? ` THE BAR for this repo's slice — the acceptance criteria to judge the diff against, as the planner recorded them (you have NO tracker access; this list is authoritative, do not go looking for the ticket): ${rp.acceptance.map((a, i) => `(${i + 1}) ${a}`).join(' ')} Where a criterion is NOT met by the diff, that is a must-fix. Where one is deliberately out of scope for this repo, say so in your verdict rather than silently dropping it.`
      : ` THE BAR: the planner recorded no acceptance criteria for this repo's slice, and you have NO tracker access to fetch them — so judge STANDARDS and internal consistency only, and say plainly in your verdict that the spec axis could not be judged for want of a bar.`
    const onPr = `the OPEN PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}; ${rp.work_branch} → ${rp.base_branch}). ${inRepo} ${scopeNote} Post each must-fix as a comment ON THE PR/MR at the specific file:line via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "<comment>"\` — NEVER on the tracker.`
    const firstReviewPrompt = (rv) =>
      rv.key === 'review'
        ? `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} Review ${onPr}${theBar}${deferredBar} Run /review (standards + spec) against the target — for its "identify the spec source" step, the bar above IS the spec source, already resolved for you. ${greenGate} Return approved:true ONLY when the diff meets the bar, tests_green is true, and every ${STRICT ? 'must-fix' : 'must-fix AND nice-to-have'} comment is resolved; otherwise approved:false with the open comments.${NO_SELF_APPROVE}`
        : rv.key === 'guard'
          ? `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} You are the REPORTER for this repo's configured static-analysis tool on ${ticket} in ${R}, on ${onPr} You do not audit the code yourself and you do not write a security assessment: you run the configured scanner, relay what IT reported, and triage those findings. Every judgement below belongs to the tool; your job is to fetch it, classify it and post it. The workspace's configured quality-gate provider is quality_gate.provider="${QUALITY_GATE}" (mirrored from workspace.config.yaml — do NOT re-read the file). If it is 'none', skip the scan and pass cleanly. Otherwise (SonarQube) run the gate by whichever channel is LIVE in THIS run-context: FIRST try the SonarQube MCP — if the mcp__sonarqube tools are not already in your toolset, load them with ToolSearch (e.g. \`select:mcp__sonarqube__get_project_quality_gate_status,mcp__sonarqube__search_sonar_issues_in_projects,mcp__sonarqube__search_security_hotspots\`) and read the quality-gate status, the issue list and the hotspot list the tool reports for the PR SHA; if the MCP is NOT reachable, FALL BACK to the installed \`sonar\` CLI over Bash (\`sonar analyze\` / \`sonar verify --file <changed-file>\`). GATE-UNAVAILABLE: if NEITHER channel can actually run the scan (no MCP AND no working CLI/auth), you MUST NOT pass — set passed:false AND gate_unavailable:true with unavailable_reason naming both channels you tried and why each failed, and post ONE loud PR/MR comment via scripts/vcs/pr-comment.sh that the configured SonarQube gate could NOT run in this run-context; never fabricate a green status. For each finding the tool marks BLOCKING, post a PR/MR comment carrying the tool's own rule id, file:line and suggested remediation, and list it under "blocking" — quote the tool, do not restate it as your own conclusion. As a light secondary pass, check whether its output happens to touch this repo's declared sensitive areas (${desc.guardianFocus}) and say so if it does; finding nothing there is the normal result, not a gap in your work. Triage every NON-blocking finding into ONE of two tiers — do NOT file a ticket for every finding: (a) MINOR fix (small, local, low-risk — a few lines, mechanical, no new design/contract/QA scope) → post a PR/MR comment at file:line prefixed "[minor / fold-in]" with the exact remediation and list it under "fold_in"; the developer applies it in THIS PR, NO ticket. (b) MAJOR, nice-to-have hardening (needs its own design, touches multiple layers, changes a contract/permission model, or carries a documented trade-off — AND is genuinely optional for this ticket, not must-have) → file ONE Improvement ticket YOURSELF by invoking /clarifying-ticket (Mode A — pass the finding + "source ${ticket}"), and put the REAL <KEY> it returns (with the title) into improvements_filed — NEVER a placeholder like "<PREFIX>-pending". /clarifying-ticket DEDUPS against the board first (scripts/tracker/find-tickets.sh): if the finding (same scope + root cause) is already tracked it returns that EXISTING <KEY> — record that one instead and NEVER file a second ticket for it; also don't re-file findings you already filed earlier in this same run, and never file a ticket for a MINOR fold-in. If a "minor" fold-in turns out non-trivial mid-loop, reclassify it as (b) rather than looping on it. Whoever reports the topic owns the ticket; do not defer it to a human. If the tracker is unreachable, note that in the entry instead of a fake number. Filing tickets and posting fold-ins are both non-blocking for the gate — neither holds up the merge, and an empty improvements_filed is the normal, healthy outcome. Return passed:false while ANY blocking OR unresolved fold_in item remains (so the developer folds the minor ones into this PR); passed:true ONLY when you ACTUALLY obtained a green quality-gate result (or the provider is 'none') AND no fold_in item is left unresolved — NEVER passed:true for a scan you could not run (use gate_unavailable for that). Return the structured gate result.`
          : `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} Performance review of ${ticket} in ${R} on ${onPr} Profile the changed flows with this repo's profiling tooling (e.g. for a Flutter app every profiling command goes through scripts/perf.sh, never raw flutter/dart: perf.sh build --profile, perf.sh run --profile + perf.sh devtools); measure jank, startup, memory, rebuild storms, unbounded lists, costly/unindexed queries; mandatory animations stay 60fps. For each CRITICAL regression post a PR/MR comment WITH the measurement as evidence and list it under "blocking". Triage every NON-blocking optimization into ONE of two tiers — do NOT file a ticket for every finding: (a) MINOR optimization (small, local, low-risk — a few lines, mechanical, no new design/contract/QA scope; e.g. MediaQuery.of(context).size → MediaQuery.sizeOf(context), or an O(n²) lookup → a Set) → post a PR/MR comment at file:line prefixed "[minor / fold-in]" with the measurement/mechanism + exact fix direction and list it under "fold_in"; the developer applies it in THIS PR, NO ticket. (b) MAJOR, nice-to-have optimization (needs its own design, touches multiple layers, changes a query/index/schema, or carries a documented trade-off — AND is genuinely optional for this ticket, not must-have; e.g. a composite (status, createdAt) index) → file ONE Improvement ticket YOURSELF by invoking /clarifying-ticket (Mode A — pass the finding + "source ${ticket}"), and put the REAL <KEY> it returns (with the title) into improvements_filed — NEVER a placeholder like "<PREFIX>-pending". /clarifying-ticket DEDUPS against the board first (scripts/tracker/find-tickets.sh): if the finding (same scope + root cause) is already tracked it returns that EXISTING <KEY> — record that one instead and NEVER file a second ticket for it; also don't re-file findings you already filed earlier in this same run, and never file a ticket for a MINOR fold-in. If a "minor" fold-in turns out non-trivial mid-loop, reclassify it as (b) rather than looping on it. Whoever reports the topic owns the ticket; do not defer it to a human. If the tracker is unreachable, note that in the entry instead of a fake number. Filing tickets and posting fold-ins are both non-blocking for the gate — neither holds up the merge, and an empty improvements_filed is the normal, healthy outcome. GATE-UNAVAILABLE: if your profiling tooling cannot actually run in this run-context (e.g. scripts/perf.sh / the profiler is unavailable so you could measure nothing), you MUST NOT pass — set passed:false AND gate_unavailable:true with unavailable_reason explaining what you tried and why it couldn't run, and post ONE loud PR/MR comment via scripts/vcs/pr-comment.sh that the performance gate could NOT run; never fabricate a clean profile. Return passed:false while ANY blocking regression OR unresolved fold_in item remains (so the developer folds the minor ones into this PR); passed:true ONLY when you ACTUALLY profiled the changed flows AND found zero blocking regressions AND no fold_in item is left unresolved — NEVER passed:true for a profile you could not run (use gate_unavailable for that). Return the structured gate result.`

    const promptFor = (rv) =>
      modeThisRound[rv.key] === 'revisit'
        ? `${tag(R, rv.role, 'review', reviewRound)} ${revisitTask(rv)}`
        : firstReviewPrompt(rv)

    const openReviewers = reviewers.filter((rv) => !done[rv.key])
    reviewers.filter((rv) => done[rv.key]).forEach((rv) => log(`[${R}] review round ${reviewRound}: ${rv.key} ${done[rv.key] === 'unavailable' ? 'UNAVAILABLE (gate could not run)' : 'already PASSED'} — frozen, not re-reviewed.`))
    // A guard/perf gate that DIES — e.g. an Anthropic usage-policy safeguard tripping on the
    // security-review phrasing, or a transient API error — must NOT read as a hard run failure.
    // Guard: Layer 2 backstop (neutral general-purpose checklist over the diff). Perf: map to
    // gate_unavailable so the run continues (fail-open). A code reviewer that DIES stays null
    // (inconclusive, re-run next round) — distinct from the code reviewer REPORTING
    // gate_unavailable, which means its test gate could not run and HALTS the repo (never
    // fail-open: an unverified suite must not reach a merge).
    const guardBackstop = async (msg) => {
      log(`⚠️  [${R}] guardian subagent could not complete (${msg}) — running checklist inline via neutral agent (backstop).`)
      try {
        const bk = await agent(
          `${tag(R, 'general-purpose', 'guard-backstop', reviewRound)} Static code-quality pass over the diff of ${prRef}. ${inRepo} Read the diff (\`git diff ${rp.base_branch}...${rp.work_branch}\`) and check the CHANGED lines for: ${desc.guardianFocus}. Post each concrete file:line issue via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "<issue + fix>"\` and list under "blocking" (no generic advice). Return passed:true when clean, else passed:false with the blocking list.` + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
          { agentType: 'general-purpose', phase: 'Review', label: `guard-backstop:${ticket}:${R}#${reviewRound}`, schema: GATE_SCHEMA },
        )
        if (bk) return { ...bk, via_backstop: true }
      } catch (e2) {
        log(`⚠️  [${R}] guardian backstop also failed (${String(e2?.message || e2).slice(0, 120)}).`)
      }
      return { passed: false, gate_unavailable: true, unavailable_reason: `guard agent + backstop could not complete: ${msg}` }
    }
    const runReviewer = async (rv) => {
      try {
        return await agent(promptFor(rv) + VERDICT_BEFORE_BUDGET + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + codegraphClause(desc.path), { agentType: rv.role, phase: 'Review', label: `${rv.key}:${ticket}:${R}#${reviewRound}`, schema: rv.schema })
      } catch (e) {
        const msg = String(e?.message || e).slice(0, 200)
        if (rv.key === 'guard') return guardBackstop(msg)
        if (rv.key === 'perf') {
          log(`⚠️  [${R}] perf reviewer errored (${msg}) — mapped to gate_unavailable; run continues.`)
          return { passed: false, gate_unavailable: true, unavailable_reason: `perf agent could not complete in this run-context: ${msg}` }
        }
        log(`⚠️ [${R}] ${rv.key} reviewer errored (${msg}) — inconclusive, will re-run.`)
        return null
      }
    }
    const results = await parallel(openReviewers.map((rv) => () => runReviewer(rv)))
    results.forEach((r, i) => { verdict[openReviewers[i].key] = r })
    // A guard/perf gate that reports gate_unavailable is frozen as UNAVAILABLE — NOT a pass, but it
    // can't be "fixed" by the developer either, so we stop re-running it (fail-open: the
    // repo can still reach 'ready'; the workflow surfaces the unavailability loudly).
    // The CODE gate is NOT fail-open: its gate_unavailable means the SUITE never ran, so nothing in
    // this run can say the PR/MR doesn't break the tests. Shipping on "it reads correct" is exactly
    // what the green gate exists to stop, so it halts the repo instead (handled just below).
    openReviewers.forEach((rv) => {
      const v = verdict[rv.key]
      const unavail = v?.gate_unavailable === true
      if (unavail && rv.key !== 'review') { done[rv.key] = 'unavailable'; gatesUnavail[rv.key] = v.unavailable_reason || 'configured gate could not run in this run-context' }
      else if (!unavail && rv.passed(v)) done[rv.key] = true
    })

    // BLOCKED-ON. A reviewer that says "this needs the change in <upstream>" is describing a
    // dependency, not a defect this repo can fix. Only a DECLARED dependency counts: a reviewer
    // naming an unrelated repo in passing is common, and halting on a mention would be a false
    // halt. `depends_on` comes from the Scope stage, so the edge is already agreed.
    const upstreams = (rp.depends_on || []).filter((id) => REPOS[id])
    const namedBlockers = upstreams.filter((id) => {
      const hay = JSON.stringify(openReviewers.map((rv) => verdict[rv.key] ?? null))
      return new RegExp(`(^|[^\\w-])(${id}|${REPOS[id].path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})([^\\w-]|$)`).test(hay)
    }).filter((id) => repoResults[id]?.status !== 'ready')
    if (namedBlockers.length) {
      log(`⛔ [${R}] BLOCKED ON ${namedBlockers.join(', ')} — a reviewer finding names a declared upstream that has not reached 'ready'. Halting this repo; PR left OPEN. Resolve ${namedBlockers.join(' + ')}, then re-run \`/dev-cycle ${ticket}\` — the run state lets this repo resume from its own last milestone.`)
      return { repo: R, status: 'review-blocked-on', plan: rp, pr, reviewRound, verdict, blockedOn: namedBlockers, handoff: { status: 'blocked', summary: `review finding names upstream ${namedBlockers.join(', ')}`, remaining: `this repo cannot resolve a finding that lives in ${namedBlockers.join(', ')}`, decision_needed: `whether to land ${namedBlockers.join(' + ')} first, or re-scope the finding onto this repo` } }
    }

    // TEST GATE COULD NOT RUN — hard halt, never fail-open. The reviewer tried the repo harness
    // (and any dependency stack it needs) and still could not produce a green receipt, so the
    // verdict is UNVERIFIED: leave the PR/MR OPEN, merge nothing, and surface the unblocking
    // command for a human. Re-run the dev-cycle once the suite can run.
    const testGateDown = openReviewers.find((rv) => rv.key === 'review' && verdict[rv.key]?.gate_unavailable === true)
    if (testGateDown) {
      const why = verdict.review?.unavailable_reason || 'the repo test suite could not run in this run-context (no reason given)'
      log(`⛔ [${R}] TEST GATE COULD NOT RUN on review round ${reviewRound} — ${why}. No approval, nothing merged; PR left OPEN. Unblock the suite, then re-run the dev-cycle.`)
      return { repo: R, status: 'review-tests-unverified', plan: rp, pr, reviewRound, verdict, handoff: { status: 'blocked', summary: 'code review could not verify the suite is green', remaining: why } }
    }

    // A reviewer that COMPLETED a pass in first-review mode has now done its one full review, so
    // every later pass for it is a re-visit. A crash (null verdict) leaves it in first-review mode.
    openReviewers.forEach((rv) => { if (verdict[rv.key] != null && modeThisRound[rv.key] === 'first') didFirstReview[rv.key] = true })

    // FIX-CAUSED REGRESSION (re-visit only) — the ONE thing a re-visit may raise. It is NOT a dev-fix
    // loop item: HALT this repo LOUDLY and leave the PR open for human action; re-run to resume.
    const regressed = openReviewers.filter((rv) => modeThisRound[rv.key] === 'revisit' && verdict[rv.key]?.fix_regression === true)
    if (regressed.length) {
      const detail = regressed.map((rv) => `${rv.key}: ${verdict[rv.key]?.regression_detail || 'fix-caused regression (no detail)'}`).join(' | ')
      log(`⛔ [${R}] FIX-CAUSED REGRESSION on re-visit round ${reviewRound} — ${detail}. Halting this repo LOUDLY for human action; PR left OPEN. Address it, then re-run the dev-cycle to resume.`)
      return { repo: R, status: 'review-regression-halt', plan: rp, pr, reviewRound, verdict, handoff: { status: 'blocked', summary: `fix-caused regression flagged by ${regressed.map((rv) => rv.key).join('+')} on re-visit`, remaining: detail } }
    }

    const crashed = openReviewers.filter((rv) => verdict[rv.key] == null).map((rv) => rv.key)
    const openFindings = openReviewers.reduce((n, rv) => n + (done[rv.key] || verdict[rv.key] == null ? 0 : rv.open(verdict[rv.key])), 0)
    log(`[${R}] review round ${reviewRound}${isRetest ? ' (re-visit)' : ' (first review)'}: ${reviewers.map((rv) => `${rv.key} ${done[rv.key] === 'unavailable' ? 'UNAVAILABLE' : done[rv.key] ? 'PASS' : crashed.includes(rv.key) ? 'ERRORED' : `${rv.open(verdict[rv.key])} open`}`).join(', ')}`)
    tick(`${R}:review#${reviewRound}`)

    // Converge ONLY when EVERY reviewer has an explicit pass/approve (freeze-once-passed).
    if (reviewers.every((rv) => done[rv.key])) break
    if (reviewRound >= MAX_REVIEW_ROUNDS) {
      const why = crashed.length ? `${crashed.join('+')} reviewer ERRORED (inconclusive)` : 'open findings'
      log(`⚠️ [${R}] hit MAX_REVIEW_ROUNDS (${MAX_REVIEW_ROUNDS}) with ${why} — NOT merge-ready; PR left open for human review.`)
      return { repo: R, status: 'review-unresolved', plan: rp, pr, reviewRound, verdict, crashed }
    }
    // SALVAGE — a reviewer that returned nothing is not the same as a reviewer that found nothing.
    // A gate posts its findings to the PR/MR as it goes and returns its verdict LAST, so one that
    // runs out of turns leaves a complete review on the MR and hands back null. Counting that as
    // "0 open findings" skips the developer pass and re-runs the identical review next round — the
    // findings sit on the MR, unread, while the loop burns every remaining round and fixes nothing.
    // (Measured: 4 rounds, 5 must-fixes live on the MR, 0 developer passes.) So before believing a
    // null, read the MR back. If a review IS there, it counts: the developer fixes it this round,
    // and the reviewer is marked as having done its first pass so next round is a cheap RE-VISIT of
    // its own threads rather than another full review it cannot finish.
    let salvaged = 0
    if (crashed.length && openFindings === 0 && pr?.pr_number) {
      const sv = await safeAgent(
        `${tag(R, 'general-purpose', 'review-salvage', reviewRound)} READ ONLY — change no code, post no comment, run no tests. The ${crashed.join(' + ')} gate(s) for ${ticket} in ${R} returned no verdict this round, most likely cut off before they could. Their findings, if any, are already on the PR/MR. ${inRepo} List the review threads on PR/MR ${pr.pr_number} (\`scripts/vcs/pr-threads.sh ${pr.pr_number}\`) and read its comments (\`scripts/vcs/pr-comments.sh ${pr.pr_number}\`). Count the UNRESOLVED findings a reviewer posted that a developer still has to act on — a must-fix, a blocking item, or a "[minor / fold-in]". Do NOT count: the PR/MR description, the author's own replies, a thread already marked resolved, or a note that merely reports what was run. Set reviewed:true if a genuine review pass is visible at all (even fully resolved), and put one line per unresolved finding in detail.`,
        { agentType: 'general-purpose', phase: 'Review', label: `salvage:${ticket}:${R}#${reviewRound}`, schema: SALVAGE_SCHEMA },
      )
      salvaged = Math.max(0, sv?.unresolved_count || 0)
      if (salvaged > 0) {
        // Its review reached the MR, so its first pass DID happen — re-visit from here, never re-review.
        crashed.forEach((k) => { didFirstReview[k] = true })
        log(`[${R}] SALVAGED ${salvaged} unresolved finding(s) off PR/MR ${pr.pr_number} from the ${crashed.join('+')} gate(s) that returned no verdict — running the developer pass on them instead of re-reviewing. ${String(sv?.detail || '').slice(0, 200)}`)
      } else if (sv?.reviewed) {
        log(`[${R}] the ${crashed.join('+')} gate(s) returned no verdict, but their review IS on PR/MR ${pr.pr_number} with nothing unresolved — re-visiting to collect the verdict, not re-reviewing.`)
        crashed.forEach((k) => { didFirstReview[k] = true })
      }
    }
    // Nothing to fix — no verdict AND no findings on the MR → just re-run the inconclusive reviewer.
    if (openFindings === 0 && salvaged === 0) {
      log(`[${R}] no findings to fix — re-running inconclusive reviewer(s) next round: ${crashed.join(', ') || 'none'}.`)
      continue
    }

    // Developer fixes the WHOLE combined batch (every open reviewer's PR comments) in ONE pass, pushing to the PR.
    const fix = await safeAgent(
      `${tag(R, desc.build, 'pr-fix', reviewRound)} PR/MR review-fix batch for ${ticket} in ${R} (round ${reviewRound}) on ${rp.work_branch}, PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}). ${inRepo} Read ALL open review comments on the PR/MR (code-reviewer + guardian + performance) via \`scripts/vcs/pr-comments.sh ${pr.pr_number ?? '<number>'}\`. ${STRICT ? 'The batch is must-fixes only (review.level=strict) — there are no "[minor / fold-in]" comments to apply.' : 'The batch includes both must-fixes AND any comment prefixed "[minor / fold-in]" — those are small guardian/perf improvements to apply in THIS PR (no separate ticket); fold them in too.'} Fix the WHOLE batch in this single pass: reproduce with a failing test first where applicable (/tdd) — a mechanical fold-in may not need one — fix to green, commit (fix(…) Refs ${ticket}), and push (git push). Reply on each resolved comment via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --body "<reply>"\` so the reviewers can re-check, THEN check its "Resolve thread" box: list the thread ids with \`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\`, match each unresolved thread by its file:line to the comment you fixed, and resolve it via \`scripts/vcs/pr-resolve-thread.sh ${pr.pr_number ?? '<number>'} <thread-id>\` — resolve ONLY threads you actually addressed in this pass (leave anything still open unresolved). Keep ${desc.green}. In the returned "fixed" array, list the files/areas you changed — the reviewers use this to locate your fixes and to judge whether the fix itself introduced any regression. Set status="complete" when you resolved the whole batch, else "partial" (what's still open in "remaining"); never end without the structured handoff.` + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE,
      { agentType: desc.build, phase: 'Review', label: `pr-fix:${ticket}:${R}#${reviewRound}`, schema: DEV_SCHEMA },
    )
    // STALL DETECTOR — the same unresolved finding set, with no new commit, surviving two
    // consecutive rounds means this repo is not converging, it is repeating. Fingerprint the
    // still-open reviewers' verdicts BEFORE the fix (what this round actually had to resolve).
    const fpThisRound = stallFp(openReviewers.filter((rv) => !done[rv.key]).map((rv) => [rv.key, verdict[rv.key]]))
    if (fix) fixPasses++
    lastFixed = Array.isArray(fix?.fixed) ? fix.fixed : []
    const noNewCommit = !(fix?.commits > 0)
    if (fpThisRound === lastFp && noNewCommit) stalled++; else stalled = 0
    lastFp = fpThisRound
    log(`[${R}] review-fix round ${reviewRound}: ${fix?.summary?.slice(0, 60) ?? 'done'}${lastFixed.length ? ` (scope: ${lastFixed.length})` : ''}`)
    tick(`${R}:pr-fix#${reviewRound}`)
    if (stalled >= 1) {
      log(`⛔ [${R}] REVIEW STALLED — the same unresolved finding set survived two rounds with no new commit on ${rp.work_branch}. Halting this repo rather than spending the remaining ${MAX_REVIEW_ROUNDS - reviewRound} round(s) on a finding it cannot converge on; PR left OPEN.`)
      return { repo: R, status: 'review-stalled', plan: rp, pr, reviewRound, verdict, handoff: { status: 'blocked', summary: `review loop stalled at round ${reviewRound}`, remaining: `the same finding set was still open after a fix round that produced no commit. Unresolved: ${String(fpThisRound).slice(0, 400)}`, decision_needed: 'whether the finding is genuinely actionable, or should be waived / re-scoped' } }
    }
  }

  return { repo: R, status: 'ready', plan: rp, pr, reviewRound, verdict, gatesUnavailable: gatesUnavail, deferred: deferredScope, met_acceptance: dev.met_acceptance || [], build: { summary: dev.summary, fixed: Array.isArray(dev.fixed) ? dev.fixed : [] } }
}

// ──────────────────────────────────────────────────────────────────────────
// DISPATCHER
// ──────────────────────────────────────────────────────────────────────────

// ── RUN STATE (docs/adr/0018) — the engine's resume cache is prefix-scoped, so any edit at
// or after Build invalidates every Build/review call behind it. This file therefore keeps its
// OWN checkpoint. Workflow scripts have no filesystem access, so the read is an agent's shell
// and the writes ride the phase agents that already write files (no new spawns for writing).
const RUN_STATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['rows'],
  properties: {
    found: { type: 'boolean' }, path: { type: 'string' },
    rows: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['repo', 'milestone', 'status'],
        properties: {
          repo: { type: 'string' },                // a REPOS key, or "all" for a run-level row
          milestone: { type: 'string', enum: ['planned', 'built', 'pr_open', 'reviewed', 'test_suite', 'merged', 'distributed'] },
          status: { type: 'string', enum: ['done', 'in-progress'] },
          work_branch: { type: ['string', 'null'] },
          head_sha: { type: ['string', 'null'] },   // the sha recorded WHEN the milestone landed
          live_sha: { type: ['string', 'null'] },   // what the branch points at NOW
          pr_number: { type: ['number', 'string', 'null'] },
          pr_url: { type: ['string', 'null'] },
          recorded_at: { type: ['string', 'null'] },
          degraded: { type: 'boolean' },            // recorded head != live head → NOT skippable
        },
      },
    },
  },
}
const runState = await safeAgent(
  `${tag('all', 'general-purpose', 'run-state')} READ ONLY — write nothing, touch no git branch, run no tests. Load this run's checkpoint for ${ticket} and validate it against the live branches.
1. \`ls agent_logs/${ticket}-dev-cycle-state/*.json\` from your cwd (the workspace root). ONE FILE PER CHECKPOINT (not one shared file), named \`<repo>-<milestone>.json\`. If the directory does not exist or is empty, return found:false with rows:[] — that is the normal first-invocation answer, not an error.
2. \`cat\` each file and parse it as one JSON object. A file that fails to parse is DISCARDED with no attempt to repair it. There is no duplicate-row question here — each (repo, milestone) has its own path, so nothing to dedupe.
3. For every row carrying a work_branch, resolve what that branch points at NOW, using the repo dir from this map (do NOT cd; use git -C): ${Object.entries(REPOS).map(([id, d]) => `${id}=${d.path}`).join(', ')}. Run \`git -C <that dir> rev-parse --verify <work_branch>\` and put the result in live_sha (null when the branch does not exist).
4. DEGRADE mechanically: set degraded:true AND status:"in-progress" on any row whose live_sha is null or differs from its recorded head_sha. Do not reason about whether the difference matters — a moved head means the milestone is no longer proven, full stop. Leave degraded:false only on an exact match.
5. Return every row you parsed, degraded flags applied, plus found and the directory path. Add nothing, invent nothing, and never fabricate a head_sha you did not read from a file.` + CAVEMAN_DIRECTIVE,
  { agentType: 'general-purpose', model: 'haiku', phase: 'Scope', label: `run-state:${ticket}`, schema: RUN_STATE_SCHEMA },
)
const stateRows = runState?.rows || []
// The ONE predicate every gate below reads. A degraded row is not done.
const doneAt = (repo, milestone) => stateRows.some((r) => r.repo === repo && r.milestone === milestone && r.status === 'done' && r.degraded !== true)
const rowAt = (repo, milestone) => stateRows.find((r) => r.repo === repo && r.milestone === milestone && r.status === 'done' && r.degraded !== true)
if (stateRows.length) log(`[run-state] ${stateRows.length} row(s) loaded${runState?.found === false ? '' : ` from ${runState?.path || `agent_logs/${ticket}-dev-cycle-state.json`}`}; skippable: ${stateRows.filter((r) => r.status === 'done' && r.degraded !== true).map((r) => `${r.repo}:${r.milestone}`).join(', ') || 'none'}; degraded: ${stateRows.filter((r) => r.degraded).map((r) => `${r.repo}:${r.milestone}`).join(', ') || 'none'}.`)

// 1. SCOPE — which repos does this ticket touch, and in what dependency order?
phase('Scope')
// The repo(s) that PROVIDE the cross-repo test-suite (QA) gate — injected into the scope
// prompt so the cto knows which repo must be scoped for the gate to run at all.
const testSuiteRepoIds = Object.keys(REPOS).filter((id) => REPOS[id].testSuite)
const scope = await safeAgent(
  `${tag('all', 'cto', 'scope')} You are the scoping stage for ${ticket}. Read the ticket via the tracker adapter (\`scripts/tracker/get-ticket-details.sh ${ticket}\`, + \`get-ticket-comments.sh\`) and decide which of the workspace's repos it requires changes in: ${Object.keys(REPOS).join(', ')} (only these are registered). For each touched repo return { repo, depends_on (other touched repo ids that must be built/merged first — typically a backend → app → test-suite order), summary (what that repo must change) }. The registered cross-repo test-suite (QA) repo(s) are: ${testSuiteRepoIds.length ? testSuiteRepoIds.join(', ') : 'none'}. When this change should be validated end-to-end by the cross-repo test suite (E2E / API / load) against the candidate build, set test_suite.needed:true AND include that test-suite repo in \`repos\`, with depends_on listing the app/service repos it validates (so it builds + merges LAST). The gate CANNOT run unless the test-suite repo is in \`repos\` — needed:true on its own does nothing. If no test-suite repo is registered, leave needed:false. Most tickets touch only the app repo; when they also need end-to-end validation, return the app repo PLUS the test-suite repo. Also set tracker_reachable: true ONLY if the adapter actually returned the live ticket this call — set it false if the tracker was unreachable and you proceeded from inline/contextual info (the run then loudly flags that Status moves, comments, and improvement tickets did NOT persist).
OUT OF REACH — read the ticket's acceptance criteria one by one and ask of each: can ANY repo registered above satisfy it? List in \`out_of_reach\` only those that cannot be satisfied here BY CONSTRUCTION — the owner is a repo this workspace does not hold (gateway/infra config, a third party's system), or the work needs an access only a person has (a dashboard, a certificate, a production credential). Quote the criterion, say concretely why, and name who CAN do it. Judge reachability, NOT difficulty: a criterion that is merely hard, or whose real obstacle only appears once someone reads the code, is NOT out of reach — the build will discover those and hand back \`deferred\`, which gets adjudicated then. An empty list is the normal, healthy answer, and a criterion you are unsure about belongs OUT of the list. Then set \`deliverable_now\`: true if at least ONE acceptance criterion remains reachable here, false ONLY if the ticket asks for nothing this workspace can deliver — false STOPS the run immediately, before any branch or plan exists, so do not use it to express that a ticket is partly blocked. Return the structured scope.`,
  { agentType: 'cto', phase: 'Scope', label: `scope:${ticket}`, schema: SCOPE_SCHEMA },
)
if (!scope) throw new Error(`dev-cycle: scope stage did not converge for ${ticket}`)
trackerReachable = scope.tracker_reachable !== false
if (!trackerReachable) log('⚠️ TRACKER UNREACHABLE — ticket Status moves, comments, and /clarifying-ticket improvement tickets will NOT persist this run; all ticket-tracking is best-effort. Flagged in the run result + summary.')
const scoped = (scope.repos || []).filter((r) => REPOS[r.repo])
if (!scoped.length) throw new Error(`Scope returned no known repos for ${ticket} (got: ${JSON.stringify(scope.repos)})`)
// OUT-OF-REACH criteria, settled once for the whole run. Every later phase reads THIS list rather
// than re-deciding what is reachable: a build deferral that matches an entry here is already
// adjudicated, and only a deferral scope did not foresee pays for a verifier.
const outOfReach = (scope.out_of_reach || []).filter((o) => o?.criterion)
const outOfReachBrief = outOfReach.length
  ? ` OUT OF REACH, already settled for this run — do NOT re-argue these and do NOT try to satisfy them: ${outOfReach.map((o, i) => `(${i + 1}) "${o.criterion}" — ${o.why} [owner: ${o.owner}]`).join(' ')} A criterion on this list that your slice cannot meet is EXPECTED; report it in \`deferred\` and move on.`
  : ''
if (outOfReach.length) log(`[scope] ${outOfReach.length} acceptance criterion/criteria declared OUT OF REACH for this workspace: ${outOfReach.map((o) => o.owner).join(', ')} — the run proceeds on what IS reachable.`)
const testSuiteRequested = scope.test_suite?.needed === true
// A flagged test-suite gate is only RUNNABLE if the test-suite repo is in the built set
// (its qa-planner/qa-runner author + build the specs the gate runs). The scope agent can
// flag needed without listing the repo — reconcile here so the gate can never be silently
// requested-but-skipped.
let testSuiteGateUnavailable = null
if (scope.test_suite?.needed && !scoped.some((r) => REPOS[r.repo]?.testSuite)) {
  const tsRepo = Object.keys(REPOS).find((id) => REPOS[id].testSuite)
  if (tsRepo) {
    scoped.push({
      repo: tsRepo,
      depends_on: scoped.map((r) => r.repo),
      summary: `Cross-repo ${scope.test_suite.suite || 'E2E'} validation for ${ticket}`,
    })
    log(`[scope] test-suite gate requested — auto-added ${tsRepo} to scope (depends_on: ${scoped.filter((r) => r.repo !== tsRepo).map((r) => r.repo).join(', ') || 'none'}).`)
  } else {
    testSuiteGateUnavailable = `test_suite.needed was set but NO test-suite repo is registered in REPOS — gate cannot run.`
    log(`⚠️  [scope] ${testSuiteGateUnavailable}`)
  }
}
log(`Scope ${ticket} (${scope.type}): ${scoped.map((r) => r.repo).join(', ')}${scope.test_suite?.needed ? ' + test-suite gate' : ''}`)
tick('scope')

// THE FLOOR (docs/adr/0011): a run that can deliver nothing the ticket asks for stops HERE — no
// branch cut, no plan written, the ticket still in the status a human left it in — rather than
// spending a full cycle to reach the same verdict at the merge gate. Placed after the gate-state
// declarations above because writeSummary reads them.
if (scope.deliverable_now === false) {
  log(`⛔ NOTHING DELIVERABLE HERE — scope found no acceptance criterion this workspace can satisfy for ${ticket}. Stopping at Scope: no branch, no plan, no status move. ${outOfReach.length} criterion/criteria out of reach.`)
  const summary = await writeSummary('nothing-deliverable', { ticket, out_of_reach: outOfReach, scoped: scoped.map((r) => r.repo), testSuiteRequested })
  return {
    ticket,
    status: 'nothing-deliverable',
    out_of_reach: outOfReach,
    decision_needed: `Every acceptance criterion for ${ticket} is owned outside this workspace (${outOfReach.map((o) => o.owner).join(', ') || 'owners unnamed'}). Re-scope the ticket, hand it to those owners, or name explicitly which criteria you want attempted here anyway.`,
    summary,
    spend,
  }
}

// 2. KICKOFF — per touched repo (parallel). Code repos: development-planner runs
//    /ticket-kickoff (branch + plan). The test-suite repo: qa-planner designs the test
//    plan + automation plan and does NOT branch (qa-runner branches at build).
//    The WORKFLOW owns the ticket status — it moves the ticket to in_progress ONCE here
//    (not the per-repo planners), so a multi-repo ticket can't thrash its status.
phase('Kickoff')
await moveTicket(['in_progress'], 'kickoff started', 'Kickoff')
const branchKind = scope.type === 'bug' ? 'fix' : 'feature' // polish rides the feature flow

// ── Per-repo plan artifacts MUST land under their repo clone, NOT the workspace root ──
// The workflow engine runs every agent with cwd = the workspace (org) root and agent() exposes
// NO cwd override, so we cannot rely on a planner voluntarily cd-ing into its repo before it
// writes a bare `agent_logs/...` path — some do, some don't (OFB-2141: two planners dumped their
// plan/.html/testcases at the workspace root). We make placement cwd-independent in three steps:
//   (1) resolve the absolute workspace root ONCE here,
//   (2) hand each planner an ABSOLUTE, repo-anchored output path (code repos write the plan
//       themselves → absolute Write target; the test-suite repo's skills write a FIXED relative
//       path → require cd-into-repo-first), and
//   (3) run a post-plan guard that relocates anything a planner still misfiled and normalizes the
//       recorded plan_path/plan_html. Workspace-level run summaries are never touched.
const repoDirs = [...new Set(scoped.map((r) => REPOS[r.repo].path.replace(/\/+$/, '')))]
const wsRootRes = await safeAgent(
  `${tag('all', 'workspace', 'kickoff')} One-shot setup for the ${ticket} planning phase — touch NO git, NO tracker, write NO plan files. Your cwd IS the workspace (org) root (the dir that holds .claude/ and workspace.config.yaml).
1. Print its ABSOLUTE path with \`pwd -P\` (resolve symlinks).
2. Pre-create the plan-artifact dirs so later writes have a target UNDER each repo, PLUS the run-state checkpoint dir at the workspace root (paths are relative to your cwd — do NOT cd): \`mkdir -p ${repoDirs.map((d) => `"${d}/agent_logs" "${d}/agent_logs/development-planner"`).join(' ')} "agent_logs/${ticket}-dev-cycle-state"\`. This matters because the planner/build/review/gate agents that write into that run-state dir do NOT hold a Bash(mkdir) grant themselves — the directory must already exist before their first Write into it, or the write fails with nowhere to land.
Return workspace_root = the absolute path from step 1.` + CAVEMAN_DIRECTIVE,
  { agentType: 'general-purpose', model: 'haiku', phase: 'Kickoff', label: `ws-root:${ticket}`, schema: WS_ROOT_SCHEMA },
)
const WORKSPACE_ROOT = (wsRootRes?.workspace_root || '').trim().replace(/\/+$/, '')
const haveAbs = WORKSPACE_ROOT.startsWith('/')
if (!haveAbs) log(`⚠️ [kickoff] could NOT resolve an absolute workspace root (got ${JSON.stringify(wsRootRes?.workspace_root)}) — planners will anchor by cd-into-repo and the post-plan guard relocates any artifact still misfiled at the root.`)

// Per-repo path bookkeeping (computed in JS, NOT from the agent, so it's consistent for every
// repo). planRel/planHtmlRel are repo-ROOT-relative (the data-plan-md convention + what the
// build/gate phases read from inside the repo); planPath/planHtmlPath are the ABSOLUTE forms we
// hand the planner and record on the plan.
//
// The naming rule below is the EXECUTABLE expression of docs/agents/plan-artifacts.md — that
// document is the single source of truth. Change it there first, then here; and do not restate
// these paths anywhere else (an agent definition once carried a third, stale spelling, and the
// resulting three-way disagreement is why APP-1944's plan landed where nothing could read it).
// One plan file PER REPO: a build agent is spawned with its own repo as cwd, so a single file
// covering several repos is unreadable to all but one of them.
const planMeta = {}
for (const r of scoped) {
  const desc = REPOS[r.repo]
  const repoDir = desc.path.replace(/\/+$/, '')
  const repoRoot = haveAbs ? `${WORKSPACE_ROOT}/${repoDir}` : null
  const planRel = desc.kind === 'test-suite' ? `agent_logs/${ticket}-automation-plan.md` : `agent_logs/development-planner/${ticket}-${r.repo}-plan.md`
  const planHtmlRel = `agent_logs/${ticket}-${r.repo}-plan.html`
  const testcasesRel = `agent_logs/${ticket}-testcases.md`
  // baseBranch/workBranch resolved HERE, once, so the plan's `base_branch`/`work_branch` (below)
  // and the run-state rows (C2) always agree on the same spelling. BASE_OVERRIDE/FEATURE_BASE_OVERRIDE
  // (C1) win over the repo's own REPOS[].base when set — this is the ONE place that resolution happens.
  planMeta[r.repo] = {
    kind: desc.kind, repoDir, repoRoot, planRel, planHtmlRel, testcasesRel,
    baseBranch: BASE_OVERRIDE || (branchKind === 'feature' ? FEATURE_BASE_OVERRIDE : null) || desc.base[branchKind],
    workBranch: `${branchKind}/${ticket}`,
    planPath: repoRoot ? `${repoRoot}/${planRel}` : planRel,
    planHtmlPath: repoRoot ? `${repoRoot}/${planHtmlRel}` : planHtmlRel,
  }
}

const plans = (await parallel(scoped.map((r) => () => {
  const desc = REPOS[r.repo]
  const planner = desc.plan
  const slice = r.summary || 'see ticket'
  const m = planMeta[r.repo]
  // baseBranch/workBranch come from planMeta (resolved once, override-aware, C1) — never
  // recomputed here, so this prompt and the recorded plan can't disagree on either.
  const { repoDir, repoRoot, planRel, planPath, planHtmlPath, testcasesRel, baseBranch, workBranch } = m
  // ANCHORING directive — front-loaded so a planner can't miss it. Code repos: the planner WRITES
  // the plan itself, so an absolute target makes placement cwd-independent. Test-suite repo:
  // /plan-testcases + /plan-automate write to FIXED relative `agent_logs/...` paths, so the agent
  // MUST cd into the repo first (the guard relocates if it doesn't). Either way: never the root.
  const anchor = desc.kind === 'test-suite'
    ? (repoRoot
        ? ` ARTIFACT ANCHORING (mandatory): the ${r.repo} clone is at ${repoRoot}. /plan-testcases and /plan-automate write to FIXED relative \`agent_logs/...\` paths, so your VERY FIRST action must be \`cd ${repoRoot}\` and you must run every planning skill from there — so ${testcasesRel} and ${planRel} land under ${repoRoot}/agent_logs/, NEVER at the workspace-root agent_logs/ (that dir is for run-level summaries only).`
        : ` ARTIFACT ANCHORING (mandatory): your VERY FIRST action must be \`cd ${repoDir}\` (the ${r.repo} clone, relative to the workspace root) and run every planning skill from there, so /plan-testcases + /plan-automate write their fixed \`agent_logs/...\` files UNDER the repo, NEVER at the workspace-root agent_logs/.`)
    : (repoRoot
        ? ` ARTIFACT ANCHORING (mandatory): the ${r.repo} clone is at ${repoRoot}. Write the implementation plan (and, if asked below, its HTML) with the Write tool to the ABSOLUTE path(s) given — NEVER a bare \`agent_logs/...\` relative to your cwd, and NEVER to the workspace-root agent_logs/ (that dir is for run-level summaries only).`
        : ` ARTIFACT ANCHORING (mandatory): \`cd ${repoDir}\` (the ${r.repo} clone) before writing the plan, so its \`agent_logs/...\` path lands UNDER the repo, NEVER at the workspace-root agent_logs/.`)
  // --approve-plan PRESERVE (OFB-2141 §3): on an approved re-run a human may have hand-edited the
  // plan/ADRs after a bad run. The planner must NOT regenerate or overwrite an existing plan —
  // --approve-plan ("the plan is approved") implies "do not regenerate the approved plan". It runs
  // /ticket-kickoff for BRANCH SETUP ONLY, reads the existing plan as-is (validated against current
  // code + docs/adr/* + CONTEXT.md), and returns the structured plan FROM it. Only when NO plan
  // file exists does it author one (no regression to the first-run flow).
  const preserveCode = approvePlan
    ? ` APPROVED RE-RUN (--approve-plan) — PRESERVE THE PLAN: FIRST, try to Read ${planPath}. If it EXISTS and is non-empty, the human may have hand-edited it — do NOT regenerate, rewrite, or overwrite it. Run /ticket-kickoff ${ticket} for BRANCH SETUP ONLY (create/checkout ${workBranch}); then READ the existing plan at ${planPath} together with this repo's docs/adr/* and CONTEXT.md, validate it against the CURRENT code (note any drift in your summary), and return the structured repo plan populated FROM the existing plan (its title/acceptance/summary) with plan_path=${planPath} byte-unchanged. ONLY if NO plan file exists at ${planPath} do you author one as described below.`
    : ''
  const preserveTest = approvePlan
    ? ` APPROVED RE-RUN (--approve-plan) — PRESERVE THE PLAN: FIRST, try to Read ${planPath} (the automation plan) and ${testcasesRel}. If the automation plan EXISTS and is non-empty, the human may have edited it — do NOT re-run /plan-testcases or /plan-automate and do NOT re-publish to the ticket. Read both files as-is and return the structured repo plan FROM them, with plan_path=${planPath} byte-unchanged. ONLY if the automation plan does NOT exist do you run the full planning chain described below.`
    : ''
  // RESOLVED_PLAN_TO_HTML: after the plan markdown exists, render it to a shareable interactive HTML.
  // The markdown at planPath stays the SOURCE OF TRUTH this workflow reads at build — the HTML
  // is human-only. data-plan-md stays REPO-ROOT-RELATIVE (planRel) per the in-HTML convention;
  // the on-disk file is the absolute planPath. When auto_approve is OFF, turn on plan-approval mode.
  // RESOLVED_AUTO_APPROVE, not the committed const: a personal local override must not leave an
  // approval widget on a plan this run will never stop at (or drop one off a plan it will).
  const approvalClause = !RESOLVED_AUTO_APPROVE
    ? ` Since planning.auto_approve is OFF, turn ON plan-approval mode in that HTML: set data-plan-approval="pending", data-plan-md="${planRel}" (the repo-root-relative path to the authoritative markdown this workflow reads at build — never replace it with the HTML), data-plan-cmd="/dev-cycle ${ticket} --approve-plan", and inline plan-approval.js. The human approves in the page; approving downloads the markdown to drop over the on-disk plan at ${planPath} before the re-run.`
    : ''
  // Both branches state the resolved value EXPLICITLY so the planner never re-resolves it from
  // disk (its agent file tells it to self-resolve local-first only when no directive is present —
  // without the OFF clause a personal local override could make it render HTML this run never asked
  // for, or skip one it did, whenever the resolver above fell back to the committed default).
  const htmlClause = RESOLVED_PLAN_TO_HTML
    ? (approvePlan
        ? ` PLAN-TO-HTML is ON but this is an APPROVED RE-RUN: the interactive HTML at ${planHtmlPath} was already rendered on the first run — do NOT re-render it (wasted cost). Run /write-interactive-docs to create it ONLY if ${planHtmlPath} is MISSING. Set plan_html=${planHtmlPath}.`
        : ` PLAN-TO-HTML is ON: before returning, ALSO run /write-interactive-docs to render the plan at ${planPath} into a self-contained interactive HTML at ${planHtmlPath} (write it to that ${repoRoot ? 'ABSOLUTE ' : ''}path UNDER the repo, NEVER the workspace root; it must read as a human-facing plan write-up; the markdown at ${planPath} stays the source of truth a later phase executes), and set plan_html to that path in your structured result.${approvalClause}`)
    : ' PLAN-TO-HTML is OFF for this run — planning.to_html was already resolved for you (local-first) and this is AUTHORITATIVE: do NOT re-check any config file. Render NO interactive HTML; the plan markdown is the only artifact. Leave plan_html null.'
  // Grounding contract. A planner has narrow grants (no dev.sh, no docker, no Artifact tool), so
  // whatever it could not measure has to travel back as a claim + the command that settles it —
  // the orchestrator holds those grants and can close the gap. Without this, "the local DB was
  // down" reads as a finished answer and an inferred claim ships as a finding.
  const groundingClause = ` GROUNDING (mandatory): every claim in the plan is either MEASURED (you ran the query/EXPLAIN/test and quote the real numbers) or returned in unverified_claims — each with why_blocked and the exact unblock_command that would settle it (e.g. \`aiworks run ${r.repo}\` then an EXPLAIN, or \`scripts/dev.sh test\`). unverified_claims is REQUIRED; [] is a valid answer and means you measured everything you assert. Never present an inferred claim as a finding, and never end at "the service was down" — name the command.${RESOLVED_PLAN_TO_HTML ? ' Since you rendered an interactive HTML, set needs_artifact_publish=true: publishing a shareable Artifact needs the Artifact tool, which you do not have — the caller does it.' : ''} Plan paths, naming, and the never-commit rule: docs/agents/plan-artifacts.md — do not commit, stage, push, or open a PR/MR for anything you wrote.`
  const prompt = desc.kind === 'test-suite'
    ? `${tag(r.repo, planner, 'kickoff')} Kickoff ${ticket} for the ${r.repo} repo (cwd ${desc.path}/) — the test-suite (QA) repo.${anchor}${preserveTest} Run your planning chain: /plan-testcases ${ticket} (user-voice BDD Given/When/Then for this ticket), /update-ticket (publish the plan ONLY — do NOT move the ticket status; the workflow owns it), then /plan-automate ${ticket} (map it to this repo's Page Object Model — Page Objects/specs to add or reuse, selectors, automatable vs manual). Do NOT create a git branch — the qa-runner branches at build time. Return the structured repo plan with repo=${r.repo}, type=${scope.type}, base_branch=${baseBranch}, work_branch=${workBranch} (the branch the runner will create), plan_path=${planPath}, and the acceptance/summary for this slice (${slice}).${htmlClause}`
    : `${tag(r.repo, planner, 'kickoff')} Kickoff ${ticket} for the ${r.repo} repo (cwd ${desc.path}/).${anchor}${preserveCode} Run /ticket-kickoff ${ticket} to fetch + classify the ticket and create the work branch IN THIS REPO from base ${baseBranch} — THIS RUN says so: pass it to /ticket-kickoff and do NOT let the branch model re-derive it from the branch prefix or origin/HEAD, which is how a run's base override gets silently discarded.${basePresentClause(baseBranch)} The workflow has already moved the ticket to in_progress, so you don't need to. Comprehend the ticket for this repo's slice (${slice}), verify the design screen if any, and write the implementation plan to ${planPath} (git-ignored). Return the structured repo plan with plan_path=${planPath}.${htmlClause}`
  return agent(prompt + groundingClause + PONYTAIL_DIRECTIVE + FIGMA_DIRECTIVE + LANGUAGE_DIRECTIVE + codegraphClause(desc.path) + stateWrite(r.repo, 'planned'), { agentType: planner, phase: 'Kickoff', label: `kickoff:${ticket}:${r.repo}`, schema: REPO_PLAN_SCHEMA })
}))).filter(Boolean)
// Normalize the recorded paths to the ABSOLUTE, repo-anchored forms — consistently for every
// repo, regardless of what the planner echoed back (a planner that returned a bare-relative or
// workspace-rooted path is overwritten with the canonical one) — and carry the dependency edges.
plans.forEach((p) => {
  const m = planMeta[p.repo]
  if (m) {
    p.plan_path = m.planPath; if (RESOLVED_PLAN_TO_HTML) p.plan_html = m.planHtmlPath
    // A planner echoing a DIFFERENT base (e.g. re-deriving it from origin/HEAD) must not win —
    // this run's resolved base_branch/work_branch (C1) are authoritative over anything returned.
    p.base_branch = m.baseBranch; p.work_branch = m.workBranch
  }
  p.depends_on = (scoped.find((s) => s.repo === p.repo)?.depends_on) || []
})

// (3) POST-PLAN GUARD — anchoring is the first line of defense; this is the guarantee. One agent
// asserts each expected artifact sits under its repo clone, relocates any a planner still misfiled
// at the workspace root, and reports anything missing. It never touches the workspace-level run
// summaries. A source-of-truth plan markdown that is missing everywhere is fatal (build can't run).
const guardRepos = plans.map((p) => {
  const m = planMeta[p.repo]
  const files = [m.planRel]
  if (RESOLVED_PLAN_TO_HTML) files.push(m.planHtmlRel)
  if (m.kind === 'test-suite') files.push(m.testcasesRel) // /plan-testcases output, read by build + the gate
  return { repo: p.repo, repoDir: m.repoDir, files }
})
const guard = await safeAgent(
  `${tag('all', 'plan-guard', 'kickoff')} Plan-artifact placement guard for ${ticket}. Each planner was told to write its artifacts UNDER its own repo clone's agent_logs/, but some agents misfile them at the workspace root instead. Your cwd is the workspace (org) root${haveAbs ? ` (${WORKSPACE_ROOT})` : ''} — do NOT cd. For each repo + repo-relative file path below, make sure the file lives under the repo, NOT at the workspace root:
${guardRepos.map((g) => `- repo ${g.repo} — clone dir "${g.repoDir}/":\n${g.files.map((f) => `    • ${f}`).join('\n')}`).join('\n')}
For each file <f> of clone dir <dir>:
  1. If "<dir>/<f>" already exists → correctly placed; add to that repo's "ok".
  2. Else if the bare workspace-root "<f>" exists (a misfile) → \`mkdir -p\` the target's parent under "<dir>", \`mv "<f>" "<dir>/<f>"\`, and add to "relocated".
  3. Else → missing everywhere; add to "missing".
Use plain shell only (test -f, mkdir -p, mv). Touch NO git, NO tracker, and NO file other than the relocations above. Do NOT move or alter the workspace-root run summaries (e.g. ${ticket}-DEV-CYCLE-SUMMARY.md) or anything not listed. Return the per-repo { repo, ok, relocated, missing } report.` + CAVEMAN_DIRECTIVE,
  { agentType: 'general-purpose', model: 'haiku', phase: 'Kickoff', label: `plan-guard:${ticket}`, schema: PLAN_GUARD_SCHEMA },
)
const relocatedAll = (guard?.repos || []).flatMap((g) => (g.relocated || []).map((f) => `${g.repo}:${f}`))
const missingAll = (guard?.repos || []).flatMap((g) => (g.missing || []).map((f) => `${g.repo}:${f}`))
if (relocatedAll.length) log(`⚠️ [plan-guard] relocated ${relocatedAll.length} misfiled plan artifact(s) from the workspace root into their repo: ${relocatedAll.join(', ')}.`)
if (!guard) log(`⚠️ [plan-guard] guard did not converge — plan-artifact placement for ${ticket} is UNVERIFIED; the recorded paths are the canonical ones but were not asserted on disk.`)
else if (missingAll.length) log(`⚠️ [plan-guard] expected plan artifact(s) found NOWHERE (neither repo nor workspace root): ${missingAll.join(', ')}.`)
// A missing source-of-truth plan markdown is fatal: the build phase reads it. Fail loud + stop.
const missingPlans = plans.filter((p) => {
  const rep = (guard?.repos || []).find((g) => g.repo === p.repo)
  return rep ? (rep.missing || []).includes(planMeta[p.repo].planRel) : false
}).map((p) => p.repo)
if (missingPlans.length) {
  log(`⛔ [plan-guard] source-of-truth plan markdown missing for ${missingPlans.join(', ')} — these repos have no plan to build from; stopping for human attention.`)
  const summary = await writeSummary('plan-missing', { ticket, repos: plans.map((p) => p.repo), plans, missingPlans, guard, testSuiteRequested, testSuiteGateUnavailable })
  return { ticket, status: 'plan-missing', missingPlans, plans, guard, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}

// PUBLISH REQUEST (mid-run) — a rendered plan HTML is only shareable once it is PUBLISHED, and the
// Artifact tool exists in the main session alone: no subagent, in a workflow or out of one, holds it.
// That used to make plan_to_html a guaranteed hand-back at the end of every run. Instead one agent
// asks the main session for the publish NOW, right after the plans are on disk and verified, and the
// run walks straight into Build without waiting for an answer — the human gets a link while the code
// is being written, which is exactly when a plan is still worth reading.
// Delivery is QUEUED for the main conversation's next turn (measured, not assumed), so this is
// "while the run continues", not "instantly". Gated on artifacts.enabled, which defaults FALSE, so a
// teammate who never opted in gets no request at all rather than an unactionable ping.
const htmlPlans = RESOLVED_PLAN_TO_HTML ? plans.filter((p) => p.plan_html) : []
if (htmlPlans.length && RESOLVED_ARTIFACTS) {
  await safeAgent(
    `${tag('all', 'general-purpose', 'publish-request')} Ask the MAIN SESSION to publish this run's plan page(s) as an Artifact. You are not publishing anything yourself — you do not have the Artifact tool, and neither does any other agent in this run.
1. Load the messaging tool: ToolSearch with query "select:SendMessage".
2. Send ONE message with to: "main". It must stand on its own, because the reader has none of your context and will act on it as a teammate's request:
   • name the ticket (${ticket}) and the repo(s) whose plan is ready;
   • give the ABSOLUTE path of each page to publish: ${htmlPlans.map((p) => `${p.repo} → ${p.plan_html}`).join(' ; ')};
   • say that a CSP-safe copy may sit beside it as \`<same-name>.artifact.html\` and that THAT is the one to publish when it exists;
   • state plainly that the reader must READ each file in full before publishing it, since publishing distributes content they did not write;
   • ask them to reply to the ticket or hold the URL for the run summary — and to publish nothing if the page looks like anything other than an implementation plan.
3. Report whether the send succeeded, verbatim. Do NOT wait for a reply, do NOT retry more than once, and do NOT do any other work — the run is already moving on to Build.` + LANGUAGE_DIRECTIVE,
    { agentType: 'general-purpose', model: 'haiku', phase: 'Kickoff', label: `publish-request:${ticket}` },
  )
} else if (htmlPlans.length) {
  log(`[kickoff] ${htmlPlans.length} plan HTML rendered but artifacts.enabled is false — no publish requested; the files on disk are the deliverable.`)
}

const waveList = toWaves(plans)
if (BASE_OVERRIDE || FEATURE_BASE_OVERRIDE) log(`Base override in effect: ${BASE_OVERRIDE ? `--base ${BASE_OVERRIDE} (all repos)` : `--feature-base ${FEATURE_BASE_OVERRIDE}`} — repo defaults from REPOS[].base were NOT used.`)
log(`Plan ${ticket}: ${plans.map((p) => `${p.repo}@${p.work_branch}→${p.base_branch}`).join(', ')}`)
log(`Plan artifacts: ${plans.map((p) => `${p.repo}=${p.plan_path}`).join(', ')}`)
if (RESOLVED_PLAN_TO_HTML) log(`Plan HTML: ${plans.map((p) => `${p.repo}=${p.plan_html ?? '(not rendered)'}`).join(', ')}`)
log(`Build: all ${plans.length} repo(s) in parallel · merge order: ${waveList.map((w) => `[${w.join(', ')}]`).join(' → ')}`)
tick('kickoff')

// PLAN-APPROVAL GATE — when planning.auto_approve is off, STOP here with the plan(s) ready
// for a human to review/approve; the run does NOT proceed to build. Re-run with --approve-plan.
// Reads RESOLVED_AUTO_APPROVE (local-first, see the resolver above), not the committed const.
if (!RESOLVED_AUTO_APPROVE && !approvePlan) {
  const planList = plans.map((p) => `${p.repo}: ${p.plan_path}${p.plan_html ? ` (html: ${p.plan_html})` : ''}`).join('; ')
  log(`⏸️ Plan approval required (planning.auto_approve=false) — plans ready for human review, NOT proceeding to build: ${planList}. Re-run \`/dev-cycle ${ticket} --approve-plan\` once approved.`)
  const summary = await writeSummary('awaiting-plan-approval', { ticket, repos: waveList.flat(), plans, testSuiteRequested, testSuiteGateUnavailable })
  return { ticket, status: 'awaiting-plan-approval', plans, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}

// 3. BUILD → OPEN PR → REVIEW — ALL scoped repos IN PARALLEL.
// Build-order is decoupled from merge-order: a repo's build only needs the agreed
// contract, not a merged upstream artifact, so every scoped repo is built + reviewed
// concurrently regardless of depends_on. depends_on is still honored at Merge
// (mergeOrder, below) so the squash-merges land upstream → downstream. Reviewers
// (code-reviewer + guardian + performance) all review the OPEN PR.
phase('Build')
const repoResults = {}
const buildIds = waveList.flat() // every scoped repo, in dependency (merge) order
const buildRes = await parallel(buildIds.map((id) => () => runRepoPipeline(plans.find((p) => p.repo === id), REPOS[id], branchKind)))
buildRes.forEach((r, i) => { if (r) repoResults[buildIds[i]] = r })
const aborted = buildIds.filter((id) => !repoResults[id] || repoResults[id].status !== 'ready')
if (aborted.length) {
  // Surface each unresolved repo's partial/blocked HANDOFF (status + what remains) instead of a
  // bare "aborted" — the run stops at the merge gate (the whole change set must be ready before any
  // merge), but the human/summary sees what landed and what's missing per repo. (OFB-2141 §1.5)
  const handoffs = aborted.map((id) => {
    const r = repoResults[id]
    const h = r?.handoff
    // Surface the ACTIONABLE half of the handoff (cause / fork / where parked work went), not just
    // `remaining` — a run that reports only "needs human triage" makes the next round re-investigate.
    const detail = h && [h.root_cause && `root cause: ${h.root_cause}`, h.remaining && `remaining: ${h.remaining}`, h.decision_needed && `decision needed: ${h.decision_needed}`, h.parked_at && `parked at: ${h.parked_at}`].filter(Boolean).join(' — ')
    log(`⚠️ [${id}] unresolved (${r?.status ?? 'no-result'})${h ? ` — handoff:${h.status}: ${detail || h.summary || '(no detail)'}` : ''}`)
    return `${id}: ${r?.status ?? 'no-result'}${h ? ` — handoff:${h.status}${detail ? ` — ${detail}` : ''}` : ''}`
  })
  log(`⚠️ ${aborted.join(', ')} did not reach 'ready' — the whole change set must be ready before any merge; stopping. Handoffs: ${handoffs.join(' | ')}`)
  // A fix-caused regression flagged on re-visit is a LOUDER, distinct halt (human-action-required):
  // banner it and give the run a distinct status so the summary/caller treat it as a pause, not a
  // routine unresolved build. The PR is left OPEN — a human addresses it, then re-runs to resume.
  const regressionHalts = aborted.filter((id) => repoResults[id]?.status === 'review-regression-halt')
  if (regressionHalts.length) {
    log(`⛔⛔ FIX-CAUSED REGRESSION HALT — human action required before this run can finish: ${regressionHalts.map((id) => `${id} (${repoResults[id]?.handoff?.remaining ?? 'see PR'})`).join(' | ')}. Nothing merged or distributed; the PR(s) are left OPEN. Fix the regression, then re-run \`/dev-cycle ${ticket}\` to resume.`)
  }
  // A code gate that could not RUN the suite is its own loud halt — distinct from open findings,
  // because nothing here failed review: the review simply could not prove the branch is green, and
  // approving/merging on that is precisely what the green gate forbids.
  const testsUnverified = aborted.filter((id) => repoResults[id]?.status === 'review-tests-unverified')
  if (testsUnverified.length) {
    log(`⛔⛔ TEST GATE UNVERIFIED — the code review could not run the suite, so no approval was posted and nothing was merged: ${testsUnverified.map((id) => `${id} (${repoResults[id]?.handoff?.remaining ?? 'see PR'})`).join(' | ')}. The PR(s) are left OPEN. Unblock the suite, then re-run \`/dev-cycle ${ticket}\` to resume.`)
  }
  // STALLED / BLOCKED-ON (C4) — same loud-banner treatment: neither failed review, both need a
  // human decision (waive a stuck finding, or land a named upstream) before a re-run can converge.
  const stalls = aborted.filter((id) => repoResults[id]?.status === 'review-stalled')
  if (stalls.length) log(`⛔⛔ REVIEW STALLED — ${stalls.map((id) => `${id} (round ${repoResults[id]?.reviewRound})`).join(' | ')}: the same finding set survived two rounds with no commit. A human decides whether the finding is actionable; nothing merged, PR(s) OPEN.`)
  const blocked = aborted.filter((id) => repoResults[id]?.status === 'review-blocked-on')
  if (blocked.length) log(`⛔⛔ BLOCKED ON ANOTHER REPO — ${blocked.map((id) => `${id} → ${(repoResults[id]?.blockedOn || []).join('+')}`).join(' | ')}. Land the upstream, then re-run; the run state resumes each repo from its own milestone.`)
  const runStatus = regressionHalts.length ? 'review-regression-halt' : testsUnverified.length ? 'review-tests-unverified' : blocked.length ? 'review-blocked-on' : stalls.length ? 'review-stalled' : 'repo-unresolved'
  const summary = await writeSummary(runStatus, { ticket, aborted, handoffs, regressionHalts, testsUnverified, stalls, blocked, repoResults, testSuiteRequested, testSuiteGateUnavailable })
  // The barrier stays hard — no partial merge across repos — but a stopped invocation should
  // still leave the artifacts a human needs. The Summary is written above; the review request
  // is the other half: several repos DID open a reviewed PR/MR, and those are worth a human's
  // eyes even though the change set as a whole is not merge-ready.
  const notify = await notifyReview(buildIds)
  return { ticket, status: runStatus, aborted, handoffs, regressionHalts, testsUnverified, stalls, blocked, repoResults, testSuiteRequested, testSuiteGateUnavailable, summary, notify, spend }
}

// All scoped repos are built, reviewed, and approved — the WHOLE change set is ready.
// Repo order (upstream → downstream) for the test-suite, distribute, and final merge phases.
const mergeOrder = waveList.flat()
// Did any repo's guardian/perf gate fail to RUN (gate_unavailable)? Fail-open: we still
// proceed, but record it loudly so the run is never described as quality-gate-validated.
const gateUnavailRows = mergeOrder.flatMap((id) =>
  Object.entries(repoResults[id]?.gatesUnavailable || {}).map(([k, reason]) => `${id}:${k} — ${reason}`))
if (gateUnavailRows.length) {
  qualityGateUnavailable = `Configured quality/perf gate did NOT run for: ${gateUnavailRows.join(' | ')}. The change shipped WITHOUT a live gate result (loud-skip policy) — do NOT treat this run as gate-validated.`
  log(`⚠️  QUALITY/PERF GATE UNAVAILABLE — ${qualityGateUnavailable}`)
}
// DEFERRED SCOPE, run-wide. Collected here so the gate, the merge handoff and the summary all read
// one list rather than each walking repoResults.
const runDeferred = mergeOrder.flatMap((id) => (repoResults[id]?.deferred || []).map((d) => ({ repo: id, ...d })))
const runMet = mergeOrder.flatMap((id) => repoResults[id]?.met_acceptance || [])
if (runDeferred.length) log(`⚠️  DEFERRED SCOPE — ${runDeferred.length} acceptance criterion/criteria are NOT met by this change set, owned elsewhere: ${runDeferred.map((d) => `${d.repo}: ${d.owner}`).join(' | ')}. The run continues; the deferral rides the MR, the ticket and the summary.`)
// THE FLOOR (docs/adr/0011): every repo deferred and not one acceptance criterion met means the
// change set delivers nothing the ticket asked for. Reviewed, green and pointless is still pointless
// — stop and let a human re-scope rather than hand over a merge command for it.
if (runDeferred.length && !runMet.length) {
  log(`⛔ NOTHING DELIVERED — every scoped repo deferred its criteria and none reported one met for ${ticket}. NOT advancing the ticket, NOT running the gate, NOTHING merged; PR/MR left OPEN for human decision.`)
  const summary = await writeSummary('nothing-delivered', { ticket, deferred: runDeferred, repos: mergeOrder, repoResults, testSuiteRequested, testSuiteGateUnavailable }, runDeferred)
  return { ticket, status: 'nothing-delivered', deferred: runDeferred, decision_needed: `${ticket}'s change set meets none of its acceptance criteria — every one is owned elsewhere (${[...new Set(runDeferred.map((d) => d.owner))].join(', ')}). The branches and their PR/MR are open and reviewed; decide whether to re-scope the ticket, route it to those owners, or merge the groundwork deliberately.`, repoResults, summary, spend }
}
// The workflow advances the ticket ONCE here (decoupled from the per-repo agents): a rich
// board lands on ready_to_merge; the minimal board on ready_to_test.
await moveTicket(['ready_to_merge', 'ready_to_test'], runDeferred.length ? `all repos built & reviewed; ${runDeferred.length} criterion/criteria deferred to other owners` : 'all repos built, reviewed & approved', 'Review',
  mergeOrder.map((id) => stateWrite(id, 'reviewed')).join(' '))

// 4. TEST-SUITE GATE — the cross-repo QA suite (E2E / API / load) against the CANDIDATE
// (the ticket's work branches, PRE-merge): the join check that the repos work together,
// run BEFORE the final merge so we validate the candidate, not after committing it. Runs
// when a test-suite gate is needed, a test-suite repo is in scope, and at least one
// non-test-suite (app/service) repo is present for the suite to run against.
let testSuite = null
const testSuiteRepo = mergeOrder.find((id) => REPOS[id].testSuite)
// RESUME: the gate never fails open (docs/agents/loadtest-gate.md), so a skip is only legitimate
// when the artifact it judged is byte-identical — i.e. it already passed AND no work branch has
// moved (degraded) since. A degraded 'built' row means at least one candidate branch changed, so
// the earlier green proves nothing about what would run now.
const tsAlreadyGreen = doneAt('all', 'test_suite') && !stateRows.some((r) => r.milestone === 'built' && r.degraded === true)
if (tsAlreadyGreen) {
  log(`[test-suite] SKIPPED — run state says the cross-repo gate already passed and no work branch has moved since.`)
} else if (scope.test_suite?.needed && testSuiteRepo && mergeOrder.some((id) => !REPOS[id].testSuite)) {
  phase('Test suite')
  await moveTicket(['testing'], 'cross-repo test-suite gate running', 'Test suite')
  const candidates = mergeOrder.filter((id) => !REPOS[id].testSuite).map((id) => `${id}@${repoResults[id].plan.work_branch}`)
  const testSuiteFixed = repoResults[testSuiteRepo]?.build?.fixed || []
  const specHint = testSuiteFixed.length
    ? ` The ${testSuiteRepo} build for this ticket touched these spec/Page-Object files — use them to pin the ticket's own spec scope: ${testSuiteFixed.join(', ')}.`
    : ''
  // A LOAD suite measures numbers, so passing its own thresholds proves only that the system
  // still works — not that it is no slower. Green stays necessary; equal-or-better than the
  // ticket's base branch becomes the actual bar.
  const isLoadSuite = REPOS[testSuiteRepo].suiteKind === 'load'
  const loadClause = isLoadSuite
    ? `
3. LOAD SUITE — ${testSuiteRepo} is declared suite_kind: load, so a green run is NOT a pass on its own. Invoke \`/loadtest-baseline-gate ${ticket}\` and run the SAME scenario against the ticket's base branch as well, so the candidate has a number to beat. The base is the branch this ticket's PR/MR actually TARGETS (${mergeOrder.filter((id) => !REPOS[id].testSuite).map((id) => `${id} → ${repoResults[id]?.plan?.base_branch}`).join(', ')}), not the repo default. The skill measures the environment's own noise floor from ${LOADTEST.noiseRuns} base runs, sets each metric's threshold to max(${LOADTEST.tolerancePct}%, that floor), and returns pass / fail / unavailable — fill the "loadtest" object from its output verbatim, including base_sha, candidate_sha and its markdown table. Do NOT compute the comparison yourself and do NOT relax a k6 threshold to make a run green: moving the bar is not passing the gate. If the noise floor is too wide to judge, "unavailable" is the correct, expected answer — report it rather than picking a side.`
    : ''
  testSuite = await safeAgent(
    `${tag(testSuiteRepo, 'qa-runner', 'test-suite')} CROSS-REPO TEST-SUITE gate for ${ticket} — SCOPED to THIS ticket, NOT the full suite. Validate the CANDIDATE (the ticket's work branches, NOT yet merged — ${candidates.join(', ')}).${candidateStackClause(mergeOrder.filter((id) => !REPOS[id].testSuite).map((id) => repoResults[id].plan))} Work in the ${testSuiteRepo} repo (cwd ${REPOS[testSuiteRepo].path}/, already on its work branch ${repoResults[testSuiteRepo].plan.work_branch}).${runDeferred.length ? ` COVERAGE BOUNDARY — this change set deliberately does NOT meet every acceptance criterion: ${runDeferred.map((d) => `"${d.criterion}" (owned by ${d.owner})`).join(', ')}. No spec can cover those, and their absence is NOT a failure. State the boundary in your verdict — which criteria you covered, and which you could not because they are deferred — so your pass reads as scoped to what you actually exercised. Do NOT fail the gate over a deferred criterion, and do NOT quietly report a clean pass as though the whole ticket were validated.` : ''} Then run ONLY this ticket's scope:
1. SCOPE = (a) the ticket's own spec(s) automated for ${ticket} + (b) the ticket's regression spec(s). Derive (a) from the spec map in agent_logs/${ticket}-automation-plan.md${specHint} Derive (b) from the "**Regressions**" block at the bottom of agent_logs/${ticket}-testcases.md (the dev's "⚠️ Regression request" recap — the SOLE source of regression scope; if that block is absent there is NO regression scope, so run just the ticket's spec(s)).
2. RUN SCOPED — \`scripts/dev.sh test <this repo's own spec-scoping args>\` covering exactly the ticket + regression spec(s). Never \`npm test\` (a stub that exits 1 in several repos here), and never \`scripts/dev.sh test\` with no scoping args: the FULL-suite run is ON-DEMAND (the user triggers it separately) and is NOT part of this gate.
3. REPORT WITH EVIDENCE — /report-test-results ${ticket}. It reads \`scripts/dev.sh why test\` + \`scripts/dev.sh artifacts\` and posts the per-TC results table to the ticket with the run's OWN screenshots embedded in the comment (failures full-width, passes as a thumbnail strip). A green run that captured no artifacts is reported as unevidenced — say so, never dress it up as proven.
On a red: SINGLE-CASE triage — re-run just the broken case to rule out flake (the same scoped \`scripts/dev.sh test\` + \`scripts/dev.sh why test\`). If it reproduces as a genuine APP/feature bug, report it as-is — comment a reproducible report ON THE TICKET (scripts/tracker/add-ticket-comment.sh) with the evidence, list it in failures, and fail the gate (you do NOT fix app code here — only re-run to triage).
Return passed:true only if the scoped run (ticket + regression spec(s)) is green; otherwise passed:false with the failures.${loadClause}${RECEIPT_CLAUSE}
RUN-STATE (only on a GREEN verdict — a red/unavailable gate must leave no row, or a later resume would treat a gate that never passed as already proven): if and ONLY IF you are returning passed:true, as your LAST action before the structured result, with the Write tool (the directory already exists, created at Kickoff): Write \`agent_logs/${ticket}-dev-cycle-state/all-test_suite.json\` at the WORKSPACE ROOT (the dir holding .claude/, NOT this repo) — ONE FILE for this checkpoint, so nothing else you write can collide with it — content exactly {"repo":"all","milestone":"test_suite","status":"done","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}. If your verdict is passed:false or the gate could not run, write NOTHING there.`,
    { agentType: 'qa-runner', phase: 'Test suite', label: `test-suite:${ticket}`, schema: TEST_SUITE_SCHEMA },
  )
  log(`Test-suite gate (scoped: ticket + regression): ${testSuite?.passed ? 'PASS' : `${testSuite?.failures?.length ?? '?'} failure(s)`}`)
  tick('test-suite')

  // 4a. NEVER FAIL OPEN. A gate result is only worth what its evidence is worth, so the
  // verdict is checked twice before it counts: the receipt must describe a real command, and
  // a SECOND agent must find the result on the ticket. (A run has reported green with neither
  // — the suite was never executed and nothing reached the ticket, which is exactly the shape
  // a self-report cannot catch about itself.) Mirrors the code reviewer's green-gate rule at
  // review time: a gate that could not run HALTS the repo rather than passing.
  const rc = testSuite?.receipt
  const receiptOk = !!(rc?.command && Number.isInteger(rc.exit_code) && rc.summary_line)
  const audit = await safeAgent(
    `${tag(testSuiteRepo, 'qa-runner', 'test-suite-audit')} AUDIT ONLY — run no tests, fix nothing. The ${ticket} test-suite gate claims: exit_code=${rc?.exit_code ?? '(none)'}, summary="${(rc?.summary_line || '(none)').slice(0, 160)}". Read the ticket's comments (\`scripts/tracker/get-ticket-comments.sh ${ticket}\`) and decide ONE thing: is there a comment reporting THIS run's results — the per-scenario outcome of the run just described? Set posted:true only if you can quote its opening line back in "detail". A comment from an earlier round, a plan, or a bug report is NOT a result comment: posted:false, and say what you found instead.`,
    { agentType: 'qa-runner', phase: 'Test suite', label: `audit:${ticket}`, schema: RESULT_AUDIT_SCHEMA },
  )
  if (!receiptOk || !audit?.posted) {
    const why = !receiptOk
      ? 'the gate returned no usable receipt (command + exit code + summary line)'
      : `an independent read of the ticket found no result comment for this run (${audit?.detail || 'no detail'})`
    log(`⛔ TEST-SUITE GATE UNVERIFIED — ${why}. Treating the verdict as NOT RUN, never as a pass. NOTHING merged; PR/MR left OPEN. Re-run the dev-cycle once the suite genuinely runs and reports.`)
    const summary = await writeSummary('test-suite-unverified', { ticket, mergeOrder, repoResults, testSuite, testSuiteRequested, why }, runDeferred)
    return { ticket, status: 'test-suite-unverified', mergeOrder, repoResults, testSuite, testSuiteRequested, why, summary, spend }
  }

  if (!testSuite?.passed) {
    log('⚠️ Test-suite gate failed — stopping before Distribute + Merge. The candidate does not pass; NOTHING merged; left for human review.')
    const summary = await writeSummary('test-suite-failed', { ticket, mergeOrder, repoResults, testSuite, testSuiteRequested }, runDeferred)
    return { ticket, status: 'test-suite-failed', mergeOrder, repoResults, testSuite, testSuiteRequested, summary, spend }
  }

  // 4b. LOAD SUITE — green is only half the bar. A load suite exists to measure NUMBERS, so
  // the candidate must also be equal-or-better than the same scenario on the ticket's base
  // branch. Three verdicts, and `unavailable` is a real one: when the environment's own
  // run-to-run noise floor is wider than the effect, no honest call exists, so the gate
  // loud-skips instead of inventing one in either direction.
  if (isLoadSuite) {
    let lt = testSuite?.loadtest
    let ltRound = 0
    while (lt?.verdict === 'fail' && ltRound < MAX_LOADTEST_FIX_ROUNDS) {
      ltRound++
      // Attribute BEFORE fixing. A percentile that moved on a laptop is not yet a regression,
      // and a developer round spent on jitter is worse than no round at all.
      const attrRepo = mergeOrder.find((id) => !REPOS[id].testSuite)
      const attribution = await safeAgent(
        `${tag(attrRepo, 'developer', 'loadtest-attribution', ltRound)} ATTRIBUTION ONLY for ${ticket} — do NOT change code in this step. The load-test gate measured a regression against base ${lt.base_sha || '(base)'} on candidate ${lt.candidate_sha || '(candidate)'}:
${lt.markdown || (lt.regressed || []).join('; ')}
Decide ONE of three, and ground it in something you actually read:
• attributable — you can name the commit, query, lock, allocation or added round-trip in THIS ticket's diff that explains the measured move. Put it in "reasoning" with file:line evidence, and set "repo" to the repo that carries it.
• not-attributable — the diff contains nothing that plausibly explains it; the move is environmental (host load, container jitter, a cold cache). Say what you checked to rule the diff out.
• need-bigger-env — the effect could be real but this environment cannot show it (single container, rate tuned down); name the environment that could.
Only "attributable" earns a fix round — the other two flip the gate to a loud "unavailable" and no code is touched. Guessing "attributable" to look thorough costs a real load run.`,
        { agentType: 'developer', phase: 'Test suite', label: `lt-attribute:${ticket}:${ltRound}`, schema: LOADTEST_ATTRIBUTION_SCHEMA },
      )
      if (attribution?.attribution !== 'attributable') {
        lt = { ...lt, verdict: 'unavailable', too_noisy: [...(lt.too_noisy || []), `developer attribution: ${attribution?.attribution || 'unavailable'} — ${attribution?.reasoning || 'no reasoning returned'}`] }
        log(`[loadtest] round ${ltRound}: developer says ${attribution?.attribution || 'no verdict'} — not a regression of this change; gate → unavailable, no fix round spent.`)
        break
      }
      const fixRepo = REPOS[attribution.repo] ? attribution.repo : attrRepo
      log(`[loadtest] round ${ltRound}: ATTRIBUTED to ${fixRepo} — ${String(attribution.reasoning).slice(0, 120)}`)
      const fix = await safeAgent(
        `${tag(fixRepo, 'developer', 'loadtest-fix', ltRound)} Fix the ATTRIBUTED load-test regression for ${ticket} in ${fixRepo}, on ${repoResults[fixRepo]?.plan?.work_branch}. Cause (your own attribution): ${attribution.reasoning}${attribution.evidence ? ` — evidence: ${attribution.evidence}` : ''}. Measured: ${(lt.regressed || []).join('; ') || 'see the comparison table on the PR/MR'}. Fix the cause, keep ${REPOS[fixRepo]?.green}, commit (fix(…) Refs ${ticket}) and push — the gate re-runs the candidate against the SAME cached baseline, so the next measurement is comparable only if you push. Do not touch the load-test repo or its thresholds: moving the bar is not fixing the regression.`,
        { agentType: 'developer', phase: 'Test suite', label: `lt-fix:${ticket}:${ltRound}`, schema: DEV_SCHEMA },
      )
      log(`[loadtest] round ${ltRound} fix: ${fix?.summary?.slice(0, 80) ?? 'no summary'}`)
      const reRun = await safeAgent(
        `${tag(testSuiteRepo, 'qa-runner', 'test-suite', ltRound)} RE-RUN the load-test gate for ${ticket} after a fix in ${fixRepo} (round ${ltRound}). Rebuild the candidate from the ticket work branches — ${candidates.join(', ')} — then invoke /loadtest-baseline-gate ${ticket} again. The baseline is UNCHANGED (same base SHA), so reuse the cached base runs and measure the candidate only. Post the fresh comparison to the ticket and the PR/MR, and return the same structured result as before — receipt included.${RECEIPT_CLAUSE}`,
        { agentType: 'qa-runner', phase: 'Test suite', label: `test-suite:${ticket}:r${ltRound}`, schema: TEST_SUITE_SCHEMA },
      )
      if (reRun) { testSuite = reRun; lt = reRun.loadtest }
      tick(`loadtest-round-${ltRound}`)
    }
    testSuite = { ...testSuite, loadtest: lt }
    if (lt?.verdict === 'fail') {
      log(`⛔ LOAD-TEST REGRESSION stands after ${ltRound} fix round(s) — ${(lt.regressed || []).join('; ')}. The candidate is slower than ${lt.base_sha || 'base'} by more than the environment's own noise. NOTHING merged; PR/MR left OPEN for human action.`)
      const summary = await writeSummary('loadtest-degraded-halt', { ticket, mergeOrder, repoResults, testSuite, testSuiteRequested, rounds: ltRound }, runDeferred)
      return { ticket, status: 'loadtest-degraded-halt', mergeOrder, repoResults, testSuite, testSuiteRequested, summary, spend }
    }
    if (lt?.verdict === 'unavailable' || !lt?.verdict) {
      loadtestGateUnavailable = `The load-test gate could not judge ${ticket} against its base branch: ${(lt?.too_noisy || []).join('; ') || 'no baseline comparison was returned'}. The suite is GREEN, but "equal-or-better than base" is UNPROVEN — do NOT describe this run as performance-validated.`
      log(`⚠️  LOAD-TEST BASELINE UNAVAILABLE — ${loadtestGateUnavailable}`)
    } else {
      log(`✅ Load-test baseline: no tracked metric degraded past its threshold vs ${lt.base_sha || 'base'}${lt.baseline_cached ? ' (cached baseline)' : ''}.`)
    }
  }
} else if (scope.test_suite?.needed && !testSuiteRepo) {
  testSuiteGateUnavailable = testSuiteGateUnavailable
    || `test-suite gate was requested but no test-suite repo reached the build set — gate did NOT run.`
  log(`⚠️  ${testSuiteGateUnavailable} The ticket is shipping WITHOUT the requested E2E validation.`)
}

// DRY RUN stop — repos built/reviewed and the test-suite gate passed. Stop BEFORE the
// outward/irreversible steps (Merge, then Distribute): no squash-merge, no distribution.
if (dryRun) {
  log(`🧪 DRY RUN — all repos 'ready'${testSuite ? ` + test-suite ${testSuite.passed ? 'PASS' : 'n/a'}` : ''}; stopping before Merge + Distribute (no merge, no distribution). Per-repo: ${mergeOrder.map((id) => `${id}=${repoResults[id]?.status}`).join(', ')}.`)
  const summary = await writeSummary('dry-run', { ticket, repos: mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable }, runDeferred)
  return { ticket, status: 'dry-run', dryRun: true, repoResults, testSuite, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}

// 5. MERGE — the commit gate. After review + the test-suite gate have validated the candidate
// (PRE-merge), squash-merge UPSTREAM → DOWNSTREAM (sequential), record each SHA. Gated by
// auto-merge (workspace.config.yaml vcs.auto_merge, per-repo override via REPOS[id].autoMerge):
// when a repo opts OUT, its reviewed + validated PR/MR is left OPEN for a human and the run stops
// here — NOTHING is merged or distributed (review + the test-suite gate still ran, so the human
// merges a fully-validated candidate). Exactly like a dry-run, but with real, reviewed PRs.
phase('Merge')
// The `!` hand-off (auto-merge ON). The squash-merge — and everything downstream (distribute,
// close) — is outward + irreversible. Under auto-mode the permission classifier clears these ONLY
// for a HUMAN running them in-session (the `!` prefix); a background Workflow agent is always
// denied ([Merge Without Review] / self-approval / [Production Deploy]). So the workflow no longer
// dispatches doomed merge/distribute agents (they burned tokens + tripped a SECURITY WARNING every
// run) — it emits the exact `!` commands, upstream->downstream, for the main session to present.
const merges = {}
const shipSteps = [] // ordered human `!` hand-off: merges (upstream->downstream), then distributes
for (const id of mergeOrder) {
  const rr = repoResults[id], desc = REPOS[id], rp = rr.plan
  if ((desc.autoMerge ?? AUTO_MERGE) === false) {
    merges[id] = { merged: false, base: rp.base_branch, note: 'auto-merge disabled — PR/MR left open for a human', pr: rr.pr?.pr_url }
    log(`⏸️ [${id}] auto-merge disabled — reviewed + validated PR/MR left OPEN for human merge: ${rr.pr?.pr_url ?? '(see run)'}. Nothing merged or distributed this run.`)
    const summary = await writeSummary('merge-skipped', { ticket, mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable, merges }, runDeferred)
    // NOTIFY (final phase) — auto-merge is off, so the validated PR/MR are awaiting a human:
    // ping the configured chat channel to review them. No-op unless notify.enabled.
    const notify = await notifyReview(mergeOrder)
    return { ticket, status: 'merge-skipped', haltedAt: id, repoResults, merges, testSuite, testSuiteRequested, testSuiteGateUnavailable, qualityGateUnavailable, loadtestGateUnavailable, summary, notify, spend }
  }
  // AUTO-MERGE ON → emit the `!` merge command (never dispatch the doomed agent; see above).
  // TWO commands, not `cd X && writer`: merge-pr.sh is a mutating adapter, and the compound form
  // is denied by the workspace guard — so the one-liner this phase used to emit could never run.
  // Bash cwd persists between calls, so the cd stands on its own.
  const absRepo = haveAbs ? `${WORKSPACE_ROOT}/${desc.path}` : desc.path
  const mergeCmd = `! cd ${absRepo}\n! scripts/vcs/merge-pr.sh ${rr.pr?.pr_number ?? '<pr-number>'} --subject ${JSON.stringify(prTitle(rp))}`
  const repoDeferred = rr.deferred || []
  merges[id] = { merged: false, handoff: true, base: rp.base_branch, pr: rr.pr?.pr_url, command: mergeCmd, deferred: repoDeferred }
  shipSteps.push({ repo: id, kind: 'merge', pr_number: rr.pr?.pr_number ?? null, pr_url: rr.pr?.pr_url ?? null, base: rp.base_branch, command: mergeCmd, deferred: repoDeferred })
  log(`🫱 [${id}] MERGE → run in-session (only a human clears the auto-mode ship guard):\n    ${mergeCmd.split('\n').join('\n    ')}`)
  // A deferral must be in front of the person at the moment they decide, not only in the summary
  // they may read afterwards — merging is the irreversible step.
  if (repoDeferred.length) log(`   ⚠️  BEFORE YOU RUN IT — ${id} does NOT meet ${repoDeferred.length} acceptance criterion/criteria, deliberately: ${repoDeferred.map((d) => `"${d.criterion}" (owned by ${d.owner})`).join('; ')}. Merging ships the rest; those items stay open and no ticket was filed for them.`)

  // POINTER BUMP — a downstream repo that VENDORS this one as a git submodule keeps pointing at
  // the pre-merge commit until someone moves it, and nothing in this workflow ever did: the two
  // places that mention it (docs/agents/submodules.md, pretool-submodule-guard.sh) both call it
  // "a separate, deliberate step" without naming an owner. The cost is silent — the downstream
  // repo's integration tests build their DB/fixtures from the submodule checkout, so they run
  // green against a tree that does not contain the change they are meant to prove.
  // Detected, not guessed: .gitmodules is ground truth, the same gate mani.yaml already uses.
  // NOT the same fault as the build-time submodulePinClause above: that one moves the pin forward
  // BEFORE this repo's own suite runs, against a not-yet-merged target; this one moves it AFTER
  // this repo's merge lands, for a downstream repo's own history. Two different moments, same repo.
  for (const dsId of mergeOrder) {
    if (dsId === id) continue
    const dsDesc = REPOS[dsId]
    if (!dsDesc || !haveAbs) continue
    const dsAbs = `${WORKSPACE_ROOT}/${dsDesc.path}`
    const bump = `! cd ${dsAbs}\n! git submodule status ${desc.path} 2>/dev/null && git -C ${desc.path} fetch origin && git -C ${desc.path} checkout <the ${id} merge sha> && git add ${desc.path} && git commit -m ${JSON.stringify(`chore(${desc.path}): bump to the merged ${ticket} commit\n\nRefs ${ticket}`)} && git push`
    shipSteps.push({ repo: dsId, kind: 'submodule-bump', upstream: id, submodule_path: desc.path, after: `merge:${id}`, command_template: bump, resolve: `run only if ${dsAbs}/.gitmodules declares ${desc.path}; the main session fills <the ${id} merge sha> from the merge output` })
    log(`🔗 [${dsId}] IF it vendors ${id} as a submodule → bump the pointer AFTER the ${id} merge lands (skip when .gitmodules does not declare it).`)
  }
}

// 6. DISTRIBUTE + CLOSE sit downstream of a landed merge, so under the `!` hand-off they're human
// steps too. Emit the distribute `!` command per distributing repo — a TEMPLATE, because the
// concrete app id / tester group / artifact path live in files the workflow can't read; the main
// session fills the <…> placeholders (firebase.json + `firebase appdistribution:group:list` + the
// built artifact) before presenting, and moves the ticket to done once the ship lands.
phase('Distribute')
for (const id of mergeOrder) {
  const desc = REPOS[id], rp = repoResults[id].plan
  if (!desc.distribute || desc.distribute === 'none') continue
  const absRepo = haveAbs ? `${WORKSPACE_ROOT}/${desc.path}` : desc.path
  const distCmd = desc.distribute === 'firebase'
    ? `! cd ${absRepo} && flutter build apk --release && firebase appdistribution:distribute build/app/outputs/flutter-apk/app-release.apk --app <android appId from firebase.json> --project <firebase projectId> --groups <tester group from: firebase appdistribution:group:list> --release-notes ${JSON.stringify(prTitle(rp))}`
    : `! cd ${absRepo} && <run this repo's "${desc.distribute}" distribution command — see the repo's docs/scripts>`
  shipSteps.push({ repo: id, kind: 'distribute', target: desc.distribute, after: 'merge', command_template: distCmd, resolve: 'main session fills the <…> placeholders from the repo before presenting' })
  log(`🫱 [${id}] DISTRIBUTE → run in-session AFTER the merge lands:\n    ${distCmd}`)
}

// Hand off + STOP: the run can't proceed past its own outward steps. The main session presents the
// `!` commands (merge upstream->downstream, then distribute), then closes the ticket to done.
const nMerge = shipSteps.filter((s) => s.kind === 'merge').length
const nDist = shipSteps.filter((s) => s.kind === 'distribute').length
log(`⏭️  ${ticket}: review + test-suite validated; ${nMerge} merge + ${nDist} distribute step(s) handed off as \`!\` commands (only a human clears the auto-mode ship guard). After you run them, the main session closes ${ticket} → ${STATUS.done}.`)
const summary = await writeSummary('awaiting-human-ship', { ticket, mergeOrder, repoResults, merges, shipSteps, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable }, runDeferred)

return {
  ticket, status: 'awaiting-human-ship',
  repos: mergeOrder, repoResults, merges, shipSteps,
  testSuite, testSuiteRequested, testSuiteGateUnavailable, qualityGateUnavailable, loadtestGateUnavailable,
  summary, trackerReachable,
  spend, // per-phase output-token deltas; the per-repo/role table lives in summary.summary_path
}
