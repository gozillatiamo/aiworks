export const meta = {
  name: 'dev-cycle',
  description: 'Full development cycle for one ticket — MULTI-REPO. Scopes which repos a ticket touches, runs each through plan→build→PR/MR→review in dependency WAVES, validates the candidate with the cross-repo test-suite (QA) gate, MERGES upstream→downstream, then distributes the merged build, and summarizes. Provider-agnostic (github/gitlab, notion/jira). Pass the ticket number as args, e.g. "FM-12". A single-repo ticket collapses to a one-repo flow.',
  whenToUse: 'Run one <KEY> ticket end to end across every repo it touches — through review, the cross-repo test-suite gate, the merge, and distribution — with a single command.',
  phases: [
    { title: 'Scope', detail: 'cto: classify which repos the ticket touches + dependency order + whether the cross-repo test-suite (QA) gate applies', model: 'opus' },
    { title: 'Kickoff', detail: 'per repo: development-planner runs /ticket-kickoff (code) · qa-planner designs the test plan + automation plan (test-suite repo) → branch + plan. The WORKFLOW moves the ticket to in_progress (per-repo agents no longer touch status). If planning.to_html, each plan is also rendered to interactive HTML; if planning.auto_approve is off, the run STOPS here for human plan approval (re-run with --approve-plan).', model: 'opus' },
    { title: 'Build', detail: 'ALL scoped repos in parallel (build-order decoupled from merge-order — a build needs only the agreed contract, not a merged upstream; depends_on is still honored at Merge, upstream→downstream. The one exception is a declared SUBMODULE PIN, which orders the build too: a vendored harness only sees commits its pointer can reach, so a pinned upstream builds and pushes in an earlier wave): the build role implements (developer TDD / qa-runner POM). No pre-PR gate — guardian/perf review on the OPEN PR/MR (Review). The test-suite repo AUTHORS its specs and runs static checks only — suite execution belongs to the Test-suite phase, against the reviewed candidate (gate-only verification). A partial or blocked handoff is CONTINUED from the branch as it stands, up to build.max_continuation_passes, rather than ending the repo (docs/adr/0032).', model: 'sonnet/opus' },
    { title: 'Open PR', detail: 'build role opens the PR/MR right AFTER build, BEFORE review, via scripts/vcs/open-pr.sh, so every reviewer comments on the open PR/MR. Open only, never merge.', model: 'sonnet' },
    { title: 'Review', detail: 'on the OPEN PR/MR: code-reviewer (standards+spec, AND runs the repo suite — approval is gated on a green receipt; a suite that cannot run halts the repo rather than failing open) + guardian (quality gate) + performance ALL review, commenting via scripts/vcs/pr-comment.sh, FREEZE-once-passed; dev fixes the combined batch. A PR/MR that ALREADY carries an approval on the forge is frozen whole — its gates are not re-derived (docs/agents/review-ledger.md §5). First review is one COMPLETE pass per reviewer; every later round RE-VISITS only that reviewer\'s own findings (raise nothing new) — except a fix-CAUSED regression, which HALTS the repo loudly for human action; round cap. SKIPPED for the test-suite repo (no reviewers). When all repos pass, the WORKFLOW itself ticks the APPROVAL on every code repo\'s PR/MR (never a gate — NO_SELF_APPROVE) and moves the ticket to ready_to_merge (or ready_to_test). Ticket-wide: anything short of fully met ticks nothing anywhere.', model: 'sonnet' },
    { title: 'Test suite', detail: 'The ONLY place a suite executes. qa-runner: build the CANDIDATE (the ticket\'s work branches, PRE-merge) and run THIS ticket\'s scope — its spec(s) + regression scope (the dev\'s "⚠️ Regression request" recap), SCOPED via `scripts/dev.sh test <specs>`, NOT the full suite, then reports the per-TC results to the ticket WITH the run\'s own screenshots embedded — ONE durable comment per suite repo (marker `[test-report · <repo>]`), UPDATED in place on every re-run and stamped with the run + candidate shas, never a second comment. The cross-repo QA gate (E2E / API / load) that must pass BEFORE the merge. NEVER fails open: the verdict needs a receipt (real command + exit code + summary line) AND a second agent must find the result comment on the ticket — otherwise the gate is recorded as NOT RUN, not as a pass, and nothing merges. A repo declared `suite_kind: load` must additionally be equal-or-better than the same scenario on the ticket\'s base branch, judged against the environment\'s own measured noise floor, so its verdict is pass / fail / unavailable; a regression the developer ATTRIBUTES to the change loops back for a fix (attribute first, fix second) up to loadtest.max_fix_rounds. The WORKFLOW moves the ticket to testing, and ticks the APPROVAL on the suite repos\' own PR/MRs — they have no code reviewer, so this gate is their bar. Skipped when no test-suite gate applies.', model: 'sonnet' },
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
//   base        — branch a ticket targets: { feature, fix }                 ← branch_model, for EVERY
//                 kind; a repo on its own branch policy overrides with repos[].feature_base /
//                 repos[].fix_base. NEVER re-derived downstream — see docs/adr/0025.
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
// NOTIFY_DM — notify.dm_on_incomplete (a Slack MEMBER id, not a channel). Every run that ends
//   WITHOUT completing the ticket sends ONE direct message here instead of posting to NOTIFY_CHANNEL;
//   the channel digest is reserved for a run that finished. The shipped placeholder disables the DM.
// TEST_SUITE — test_suite.* (the cross-repo gate's own red-triage loop). maxFixRounds caps the
//   classify → fix → scoped quality check → re-run loop the gate runs itself before halting with
//   evidence, and doubles as the per-red attempt bound inside one round (docs/adr/0024).
// DEV_CYCLE — dev_cycle.* (the run's own spend ceiling). tokenBudget is compared against
//   budget.spent() — OUTPUT tokens across the run's agents, the one unit the engine's budget API
//   reports (dev-cycle.js's own spend[] table is this same unit) — checked at each phase boundary;
//   over it the run checkpoints and stops with status 'budget-stopped', fully resumable.
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
const TICKET_PREFIX = 'FM'
const AUTO_MERGE = false        // from workspace.config.yaml vcs.auto_merge; per-repo override via REPOS[id].autoMerge
const AUTO_APPROVE_PLAN = false // from workspace.config.yaml planning.auto_approve; false ⇒ halt after Kickoff (re-run with --approve-plan)
const PLAN_TO_HTML = false     // from workspace.config.yaml planning.to_html; true ⇒ planners also render the plan to interactive HTML
const NOTIFY = true        // from workspace.config.yaml notify.enabled; true + AUTO_MERGE false ⇒ Notify phase posts a review-request
const NOTIFY_PROVIDER = 'slack' // from workspace.config.yaml notify.provider (scripts/notify/ adapter)
const NOTIFY_CHANNEL = '#code-reviews'  // from workspace.config.yaml notify.channel; the chat channel the digest goes to
const NOTIFY_DM = 'U00000000000'  // from workspace.config.yaml notify.dm_on_incomplete; a Slack MEMBER id — every non-complete ending DMs it instead of posting to the channel
const DESIGN_ENABLED = false     // from workspace.config.yaml design.enabled; false ⇒ Figma OFF workspace-wide (dev/QA build from spec, not a Figma screenshot)
const QUALITY_GATE = 'none'     // from workspace.config.yaml quality_gate.provider; 'none' ⇒ guardian gate skips+passes (no SonarQube attempt)
const REVIEW_LEVEL = 'strict'     // from workspace.config.yaml review.level; 'strict' ⇒ Review gates report must-fixes ONLY (no fold-ins/Improvement tickets); 'thorough' ⇒ + nice-to-have
const LANGUAGE = 'en'     // from workspace.config.yaml language; 'th' ⇒ English spine, Thai prose (docs/agents/language.md; see LANGUAGE_DIRECTIVE below); 'en' ⇒ unchanged
const LOADTEST = {   // from workspace.config.yaml loadtest.*; read by the base-branch non-degradation gate (docs/agents/loadtest-gate.md)
  tolerancePct: 10,            // a metric may degrade this much before it counts as a regression
  noiseRuns: 2,                // base-vs-base runs used to measure the env's own run-to-run spread
  noiseCeilingMultiple: 2,     // noise floor above tolerancePct × this ⇒ verdict 'unavailable' (env too coarse to judge)
  maxFixRounds: 3,             // attributed-regression → developer fix → re-run loops
  baselineCache: '~/.cache/aiworks/loadtest-baselines',
}
const TEST_SUITE = {   // from workspace.config.yaml test_suite.*; read by the Test-suite phase red-gate triage loop
  maxFixRounds: 3,             // classified-red → fix → scoped quality check → re-run loops
  maxSuiteRepairAttempts: 3,   // a suite that COULD NOT RUN: repair attempts before it is RECORDED unverified (docs/adr/0027)
}
const REVIEW = {   // from workspace.config.yaml review.*; the review loop's bounds (docs/adr/0027)
  maxRounds: 14,               // reviewer pass + fix pass per repo — the ONE terminal bound
  maxRegressionFixes: 3,       // a fix that caused a new blocking problem, handed straight back
  maxStallReattempts: 3,       // same finding set + no new commit ⇒ ESCALATE the brief, then retry
  maxEscalationAttempts: 3,    // cross-repo fix + scoped re-gate, per (repo, finding)
}
const BUILD = {   // from workspace.config.yaml build.*; the build phase's own bound (docs/adr/0032)
  maxContinuationPasses: 3,    // a `partial`/`blocked` handoff is CONTINUED this many times before it is RECORDED
}
const DEV_CYCLE = {   // from workspace.config.yaml dev_cycle.*; the run's own spend ceiling
  tokenBudget: 2000000,        // budget.spent() above this at a phase boundary ⇒ graceful stop (status 'budget-stopped'), fully resumable
}
const STATUS = {
  to_do: 'To do',
  in_progress: 'In progress',
  code_review: 'Code review',
  ready_to_merge: 'Ready to merge',
  ready_to_test: 'Ready to test',
  testing: 'Testing',
  done: 'Done',
}
const REPOS = {
  'your-app': {
    path: 'your-app', kind: 'frontend',
    base: { feature: 'develop', fix: 'main' },
    plan: 'development-planner', build: 'developer', review: 'code-reviewer',
    guard: true, perf: true,
    green: '<keep-it-green check, e.g. lint + unit tests>',
    guardianFocus: 'secrets, data-protection',
    distribute: 'firebase',
  },
  'your-tests': {
    path: 'your-tests', kind: 'test-suite',
    base: { feature: 'develop', fix: 'main' },
    plan: 'qa-planner', build: 'qa-runner', review: null,
    guard: false, perf: false,
    green: 'E2E suite passed successfully',
    testSuite: true,
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
// C11 — the version of THIS script. Logged first (before even the resolver agent below, so a
// hung/failed resolver still leaves the version on record) so a run's own output says which copy
// is executing: the engine persists a copy per run, and a scratchpad hand-copy predating a change
// looks identical in the log otherwise (it cost one run a full 8-repo re-plan). Scheme: the date
// the change set landed plus a same-day counter — bump it in the SAME commit as any behaviour change.
// Version-only here: `dryRun`/`approvePlan` are declared further below, so referencing them THIS
// early throws (TDZ). `ticket` IS in scope now — argument parsing and its sanity checks were
// moved ABOVE this point, because they must cost zero agents and the resolver below is one
// (measured: a run with an unparseable base argument still paid for it).
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
// --feature-base-repos scopes --feature-base to a named subset: every repo NOT listed keeps its own
// REPOS[].base, exactly as if no override had been passed for it. Absent ⇒ --feature-base applies to
// every repo, unchanged. No business rule is encoded here — the caller names the repos.
const FEATURE_BASE_REPOS = String(flag('feature-base-repos') || opt.featureBaseRepos || '').split(',').map((s) => s.trim()).filter(Boolean)
// A recorded base is authoritative on resume (see BASE_ROWS below). This flag is the ONLY way to
// move it, and it re-plans + rebuilds the repos whose base changed. See docs/adr/0025.
const acceptBaseChange = /--accept-base-change\b/i.test(rawArg) || opt.acceptBaseChange === true
// ──────────────────────────────────────────────────────────────────────────
// ARGUMENT SANITY — throws HERE, where an error costs zero agents.
//
// Every check below used to be a log() firing after Scope, the tracker status move and every
// Kickoff planner had already been paid for. A warning that arrives after the expensive part is
// a warning nobody acts on: one measured run passed `--feature-base-repos a=x,b=y` — a shape
// that exists in no parser — and spent a full invocation (~20 agents) resolving every repo to
// its unchanged default, because the mismatch was only ever logged. The same run's opening words
// were "a fast-track for release/v7.10.3", free text that `flag()` cannot see and nothing
// complained about, and that dropped intent is what put four MRs on the wrong branch two days
// later. An argument the run cannot honour must stop the run before it costs anything.
const VALUED_FLAGS = ['base', 'feature-base', 'feature-base-repos', 'max-review-rounds', 'max-test-suite-fix-rounds', 'token-budget']
const BOOLEAN_FLAGS = ['dry-run', 'approve-plan', 'accept-base-change']
const argErr = (msg) => { throw new Error(`dev-cycle ${ticket}: ${msg}\nNo agent was spawned and nothing moved on the tracker.`) }
// What is left of the arg string once the ticket key and every recognised flag (with its value)
// are removed. Anything surviving is text the run silently discarded before.
const argResidue = rawArg
  .replace(TICKET_RE, ' ')
  .replace(new RegExp(`--(?:${VALUED_FLAGS.join('|')})(?:=|\\s+)\\S+`, 'gi'), ' ')
  .replace(new RegExp(`--(?:${BOOLEAN_FLAGS.join('|')})\\b`, 'gi'), ' ')
  .trim()
if (argResidue) {
  // A branch-shaped token in the residue is almost always a base the caller meant to pass. Name
  // the flag — and never adopt it: a run that infers its own base is the failure being fixed.
  const branchish = argResidue.match(/(?:^|\s)((?:release|hotfix|feature|fix|develop|main|master|staging)[\w./-]*|[\w.-]+\/[\w./-]+)(?:\s|$)/)?.[1]
  argErr([
    `unrecognised argument: "${argResidue}"`,
    branchish
      ? `  "${branchish}" looks like a branch. State it as a flag — the run will not infer a base:\n` +
        `    --feature-base ${branchish} --feature-base-repos <repo>,<repo>   (those repos only; every other repo keeps its own base)\n` +
        `    --base ${branchish}                                              (EVERY repo, both branch kinds — including test suites)`
      : `  recognised: ${VALUED_FLAGS.map((f) => `--${f} <value>`).join(', ')}, ${BOOLEAN_FLAGS.map((f) => `--${f}`).join(', ')}`,
  ].join('\n'))
}
if (FEATURE_BASE_REPOS.length && !FEATURE_BASE_OVERRIDE) {
  argErr(`--feature-base-repos was given (${FEATURE_BASE_REPOS.join(', ')}) without --feature-base — there is nothing to scope, so every repo would silently use its own base.\n  --feature-base-repos is a LIST OF REPO IDS that scopes ONE --feature-base value. There is no repo=value mapping form.`)
}
const unknownFbrIds = FEATURE_BASE_REPOS.filter((id) => !REPOS[id])
if (unknownFbrIds.length) {
  argErr(`--feature-base-repos names ${unknownFbrIds.length} unregistered repo id(s): ${unknownFbrIds.join(', ')}\n  registered: ${Object.keys(REPOS).join(', ')}\n  A "repo=value" token is not a repo id — --feature-base carries the one value, --feature-base-repos names the repos it applies to.`)
}
if (BASE_OVERRIDE && FEATURE_BASE_OVERRIDE) {
  argErr(`--base ${BASE_OVERRIDE} and --feature-base ${FEATURE_BASE_OVERRIDE} both given, and --base already covers the feature kind. Pass one.`)
}


const DEVCYCLE_VERSION = '2026-08-23.4'
// `meta` is metadata for the tool, not an in-scope runtime variable — the engine strips the
// `export const meta = {...}` block before executing the script body, so `meta.name` throws
// "meta is not defined" live even though it type-checks in the offline compile probe (a
// hand-rolled wrapper that keeps the literal source, meta included, in scope). Literal name.
log(`dev-cycle v${DEVCYCLE_VERSION}`)

// ── EVERY AGENT, EVERY PHASE: THE ATTEMPT CAN END FROM OUTSIDE ────────────────────────────────
// An interrupt, a timeout or a killed stream ends an agent MID-SENTENCE. Measured twice, on two
// repos in two different phases and roles: a build (115 messages, ~8.4M cache-read tokens) and a
// QA suite runner (172 messages, ~12.5M) — each cut off with no structured result, each replaced
// by a fresh attempt that re-read everything from an EMPTY context and paid for it again. The
// cut-off originates in the runtime and no cap in this script can prevent it. What this script
// does own is the brief, and the durability discipline lived in the BUILD prompt alone: every
// other phase and role was told nothing, so batching work to an ending that never comes was the
// reasonable reading everywhere else.
//
// It is applied HERE, around the engine's own agent(), and not around the safeAgent wrapper below,
// because the Kickoff planners and the code/guard/perf reviewers call agent() directly with their
// own try/catch — a fix at the wrapper would miss exactly the roles the second report named, and
// would miss whatever call site is added next.
const CUT_OFF_RE = /interrupted by user|request interrupted|stream ended without|timed out|timeout|deadline exceeded|SIGKILL|SIGTERM|killed/i
const CUTOFF_DISCIPLINE = ` DURABILITY (mandatory, whatever your phase): YOUR ATTEMPT CAN END FROM OUTSIDE WITHOUT WARNING. An interrupt, a timeout or a killed stream stops you mid-sentence — there is no last step to tidy up in, no chance to summarise, and whatever you have not already made durable is gone. What replaces you starts from an EMPTY context and re-reads everything you read, so work batched to the end costs the whole attempt when it is cut, and costs it again on the next. So make progress durable AS YOU GO, in whatever form your task produces it: land the FIRST slice as a commit early, before any exploration that slice does not need, and commit each slice the moment it is green rather than at the end; post a review comment when you find it, not in one block at the finish; write a plan, report or ticket record as soon as it says something true, then refine it in place. Persist first and polish second, and prefer the smaller step that leaves something behind to the larger one that leaves nothing. This never licenses skipping your structured result — ending without it is still a failure — but what you have already made durable survives you either way.`
// A step is (phase, repo): the two facts every label carries and every retry keeps. Labels are
// `<key>:<ticket>:<repo>[#<round>]`, so the repo is the third segment with any round suffix cut;
// phase comes from opts. Keying on the pair rather than the label means a phase's SECOND attempt
// inherits the truth even when it is spawned under a different key (a gate and its audit, a review
// and its next round), which is the whole point — no call site has to remember to pass it on.
const cutOffs = []
const stepKey = (opts) => `${opts?.phase || '-'}|${(String(opts?.label || '').split(':')[2] || '-').split('#')[0]}`
const rawAgent = agent
agent = async (prompt, opts) => {
  const prior = cutOffs.filter((c) => c.key === stepKey(opts)).pop()
  // The Build phase writes its own, richer version of this notice; do not say it twice.
  const notice = prior && !/ENDED FROM OUTSIDE/.test(prompt)
    ? ` ⚠️ AN EARLIER AGENT IN THIS PHASE FOR THIS REPO WAS ENDED FROM OUTSIDE mid-work (the engine reported: ${prior.reason}) — not by anything it did wrong, and usually before it wrote a line. Nothing it had not already made durable survived. So do NOT assume any work it may have started is on disk: check what is actually there — commits on the branch, files it would have written, threads it would have posted — before you build on it, and do not redo what IS there.`
    : ''
  try { return await rawAgent(prompt + notice + CUTOFF_DISCIPLINE, opts) }
  catch (e) {
    const reason = String(e?.stdout || e?.message || e).trim().slice(-300)
    if (CUT_OFF_RE.test(reason)) cutOffs.push({ key: stepKey(opts), label: opts?.label || '(unlabelled)', phase: opts?.phase || null, reason })
    throw e
  }
}
// C14 — MECHANICAL STEPS run on haiku, explicitly, so it never depends on an agent file staying
// haiku: this resolver, the status mover, the ws-root/plan-guard/publish-request kickoff steps, the
// run-state loader, and the Summary phase's incomplete-run DM. Every judgment agent (planner,
// developer, reviewer, guardian, performance, qa-runner/qa-planner) is untouched.
try {
  const cfgCheck = await agent(
    'Resolve three workspace config values, local-first. Read `workspace.config.local.yaml` in the repo root if it exists; else read `workspace.config.yaml`. (1) language: if the local file exists AND has a `language:` line, that value wins, source="workspace.config.local.yaml"; otherwise use `workspace.config.yaml`\'s `language:` line (default "en" if absent), source="workspace.config.yaml". (2) plan_to_html: if the local file exists AND has a `planning:` block, read `to_html` from THAT block ONLY — the merge is shallow per top-level key, so a local `planning:` block replaces the shared one whole and a `to_html` absent from it means false, NOT the shared file\'s value; otherwise use `workspace.config.yaml`\'s `planning.to_html` (default false if absent). (3) auto_approve: report this key ONLY when the local file exists AND has a `planning:` block — then read `auto_approve` from THAT block ONLY, and an `auto_approve` absent from that block means false, NOT the shared file value. If there is no local file, or it has no `planning:` block, OMIT auto_approve from your answer entirely so the workflow keeps its committed default. (4) artifacts_enabled: read `artifacts.enabled` the same shallow-merge way — a local `artifacts:` block replaces the shared one whole, so `enabled` absent from a local `artifacts:` block means false; with no local `artifacts:` block use `workspace.config.yaml`\'s `artifacts.enabled` (false if absent). Return ONLY the resolved language ("en" or "th"), plan_to_html (boolean), auto_approve (boolean — omitted entirely unless a local `planning:` block exists), artifacts_enabled (boolean), and the source file — nothing else, no other files, no other analysis.',
    { agentType: 'documentor', model: 'haiku', label: 'resolve-runtime-config', schema: RUNTIME_SCHEMA },
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

// REVIEW LEDGER (docs/agents/review-ledger.md). A gate's own outcome, checkpointed per repo per
// gate — because the review<->fix loop's memory used to live only in this process's local
// variables. A run that died before the merge phase left NOTHING behind, so the next invocation
// re-ran every gate in FIRST-REVIEW mode and posted a fresh finding set the developer had never
// been given a chance to fix. One row carries the two facts that stop that: FIRST PASS DONE (=>
// re-visit, never a second first review) and PASSED (=> frozen, not re-reviewed at all). One file
// per gate, not one per repo: the three gates write concurrently and would race a shared file.
// RUN-LEVEL MARKER (docs/adr/0018) — a checkpoint with no repo/branch to anchor to: whether a
// human-facing notification for this run has already gone out, so a resumed invocation that
// reaches the same outcome again does not re-send it. Never degraded (same third-proof-class
// treatment as the review ledger and test_suite — see the run-state loader above): its proof is
// the send itself, not a branch head. Write ONLY on a confirmed successful send; a failed send
// must leave no row, so the next invocation retries it rather than remembering a send that never
// happened. A fresh notify despite an existing row is a human call: delete the file.
const runMarkerWrite = (milestone, extra = '') => ` RUN-STATE CHECKPOINT (mandatory, as your LAST action before the structured result, with the Write tool — the directory already exists, created at Kickoff, so no mkdir needed): ONLY IF you sent successfully (the adapter exited 0, printed ok=1), Write \`agent_logs/${ticket}-dev-cycle-state/all-${milestone}.json\` at the WORKSPACE ROOT — the dir holding .claude/. Content exactly: {"repo":"all","milestone":"${milestone}","status":"done","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"${extra}}. This is a RUN-LEVEL marker, not tied to any repo's branch — do not invent a work_branch or head_sha for it. On ANY failure, write NOTHING — a missing row is what tells the next invocation to actually retry the send.`
const gateRow = (repo, key) => ` REVIEW-LEDGER CHECKPOINT (mandatory, as your LAST action before the structured result, with the Write tool — the directory already exists, created at Kickoff, so no mkdir needed): Write \`agent_logs/${ticket}-dev-cycle-state/${repo}-gate_${key}.json\` at the WORKSPACE ROOT — the dir holding .claude/, NOT this repo's agent_logs/ — overwriting your own file from an earlier round or an earlier invocation. Content exactly: {"repo":"${repo}","milestone":"gate_${key}","status":"<done|in-progress>","first_pass":true,"head_sha":"<git rev-parse HEAD, the full sha>","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}. Use "status":"done" ONLY when your verdict is a genuine pass AND every review thread you own is resolved; "in-progress" for anything else. WRITE THE ROW EITHER WAY — first_pass:true is what tells the next invocation you already did your ONE complete review, so skipping the row on an open verdict is precisely what makes a later run re-derive a whole new finding set instead of re-visiting yours. Never write "done" for a gate that could not run (gate_unavailable): an un-run gate must not read as proven.`

// review↔fix loops, per repo. Generous ON PURPOSE: at review.level strict the gates report
// must-fixes only, a reviewer that passes is FROZEN (never re-run), and a re-visit may raise
// nothing new — so extra rounds cannot widen scope. They only let a repo finish its own
// finding list inside ONE invocation instead of stranding a nearly-done PR at the cap. The
// loop still exits the moment no findings remain, so the cap costs nothing when unused.
const MAX_REVIEW_ROUNDS = Number(flag('max-review-rounds')) || opt.maxReviewRounds || REVIEW.maxRounds
// Attributed load-test regression → developer fix → re-run, per repo. Small by contrast: a
// load run costs wall clock, not tokens (workspace.config.yaml loadtest.max_fix_rounds).
const MAX_LOADTEST_FIX_ROUNDS = opt.maxLoadtestFixRounds || LOADTEST.maxFixRounds
const MAX_BUILD_TRIAGE = opt.maxBuildTriage || 3   // fix attempts per failing test before a build agent must hand off
// C4 — the cross-repo test-suite gate's own bounded red-triage loop (workspace.config.yaml test_suite.max_fix_rounds).
const MAX_TEST_SUITE_FIX_ROUNDS = opt.maxTestSuiteFixRounds || Number(flag('max-test-suite-fix-rounds')) || TEST_SUITE.maxFixRounds
// Attempts at ONE red's fix inside a SINGLE triage round (docs/adr/0024). Deliberately its own
// counter, not a slice of the round budget above: a round stays coarse — one classify → fix every
// red → re-run cycle — while a scoped quality check that rejects a fix sends that same red back to
// the developer before the suite is re-run at all. Same number, different meaning; bounded, because
// nothing in this file loops without a ceiling.
const MAX_GATE_FIX_ATTEMPTS = opt.maxGateFixAttempts || MAX_TEST_SUITE_FIX_ROUNDS
// C9 — the run's own token-spend ceiling (workspace.config.yaml dev_cycle.token_budget; --token-budget
// overrides). UNIT: OUTPUT tokens, per INVOCATION — the one unit the engine's budget API exposes.
// Measured on a four-repo ticket: 232k output against 6.7M total run tokens in a single invocation,
// a ~29x ratio, so a reader who takes `token_budget: 2000000` for a 2M-token ceiling is out by more
// than an order of magnitude. Per-ticket spend across invocations is reported in the run summary.
const TOKEN_BUDGET = Number(flag('token-budget')) || opt.tokenBudget || DEV_CYCLE.tokenBudget
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
// C11 — the ticket-scoped half of the version line (the version-only half already logged above,
// before `ticket` existed): now that it does, restate it WITH the ticket + run flags.
log(`dev-cycle v${DEVCYCLE_VERSION} — ${ticket}${dryRun ? ' (dry run)' : ''}${approvePlan ? ' (plan approved)' : ''}`)

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

// Shared BUILD-AGENT DISCIPLINE — appended to EVERY build prompt (code + test-suite)
// and the convergence retry. Three hard rules that stop an open-ended build loop from running
// away (a build aborted 3× without ever handing off): always hand off, never
// a repo-wide formatter, and a bounded red-test triage that tells a flaky harness from a real bug.
const BUILD_DISCIPLINE = ` BUILD DISCIPLINE (mandatory):
• ALWAYS HAND OFF. Ending WITHOUT calling StructuredOutput is a FAILURE. Even if the work is incomplete or the suite is red, you MUST end by returning the DEV_SCHEMA result with "status" set: "complete" (Definition of Done met — for the test-suite repo a red caused only by reported app bugs / expected pre-merge reds still counts as complete), "partial" (some slices landed, work OF YOUR OWN remains), "deferred" (see below), "already-satisfied" (see below), or "blocked" (cannot proceed). For "partial"/"blocked" put exactly WHAT REMAINS and WHY in "remaining". Never withhold the handoff to keep investigating.
• "ALREADY-SATISFIED" — THIS REPO NEEDS NO CHANGE, because the code that meets the ticket here SHIPPED ALREADY, under earlier work. Not "the work is small", not "the work is elsewhere" (that is deferred) — the behaviour the ticket asks of THIS repo is in this repo's source right now, and the honest diff is empty. A generic, flag-driven design that absorbs a new case without new code is the intended outcome of that design, not a corner to be argued into, and manufacturing a no-op commit to have "a diff" is the wrong answer: say so instead. The bar is a CITATION, not a claim. Fill \`satisfied_by[]\` with ONE ENTRY PER acceptance criterion this repo owns — the criterion quoted, the \`commit\` that shipped it (find it: \`git log -S'<the mechanism>' --oneline\`), the \`path_line\` where the behaviour lives now, and the \`quote\` — the actual source line(s), copied. A verifier re-opens every citation and checks the list COVERS every criterion assigned here; a criterion you leave uncited is one nobody checked, and it sinks the whole claim to "partial", which stops your repo. What the verifier will NOT do is count your commits — an empty branch is the expected shape of this answer, and it is the one status where that is true. Do NOT branch, do NOT commit, do NOT open a PR/MR.
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
• RUN A WRITER BARE. A mutating adapter call (scripts/{vcs,tracker,notify}/…) must be the WHOLE Bash command — no \`cd X && …\`, no pipe, no redirect, no \`env -C\`, no \`$( )\`, no heredoc. A compound form is DENIED SILENTLY: no permission prompt reaches you, so it reads as a broken adapter when it is not.
• SO ROUTE IT, DO NOT NAVIGATE TO IT. A \`scripts/vcs/*.sh\` writer takes its target from \`VCS_REPO\` when you set one, and from the cwd's git remote when you do not — and cwd is the half you cannot rely on: a standalone \`cd\` does NOT carry into your next tool call, and several repos of this run share one Bash session. Put \`VCS_REPO=<owner/repo>\` on the writer's own bare line (a plain env-var prefix is not a compound form, so the guard allows it) and the call lands where you meant regardless of where the shell happens to be. The tracker and notify writers take no repo at all — run them bare, from wherever you are.
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
const basePresentClause = (base, repoPath) => ` BASE-BRANCH PRECONDITION: \`${base}\` must exist on the REMOTE before this ticket's change can be raised for review. Check it with \`git -C ${repoPath} ls-remote --exit-code --heads origin ${base}\` — anchored with \`-C\` because a standalone \`cd\` does not carry into the next tool call, so a bare \`git ls-remote\` answers for whatever repo the shell is in — and report what it returned. If it exits non-zero the base exists only locally (or not at all): do NOT create or push it yourself, and do NOT retarget to another branch. Record it in \`unverified_claims\` — claim "base branch ${base} is present on origin", why_blocked "git ls-remote found no such head", unblock_command \`git -C ${repoPath} push origin ${base}\` — and say it in your summary, so it is fixed once, by a person, before any build is paid for.`

// THE BASE IS A FACT OF THIS RUN, NOT A QUESTION. It is resolved ONCE per invocation, in planMeta,
// as a pure function of the CLI args, and handed to each repo's build/PR agent already decided. A
// multi-repo run nonetheless briefs several agents with DIFFERENT bases inside the same window, and
// one build agent — holding the correct base in its own prompt — still handed back "does the other
// repos' base apply here?" as a decision_needed, stopping a repo over a question nobody asked it.
// Cross-contamination from a sibling's base is the whole failure, so the anti-re-derivation
// sentence gets its counterpart: do not re-derive it, and do not hand it back either.
// ──────────────────────────────────────────────────────────────────────────
// DURABLE TICKET RECORDS (docs/adr/0026)
//
// A ticket is a RECORD, not a transcript. Everything this run writes onto a ticket is one durable
// record per (kind, repo), identified by a visible marker line and REWRITTEN on every later run —
// never appended. The measured alternative: a hard ticket run seven times accumulated a stack of
// near-identical dev notes, regression requests and test plans, nobody could tell which was
// current, and the run's own comment count climbed so fast it had to be dropped from the ticket
// fingerprint (ADR-0018) because the run kept invalidating the plan it had just written.
//
// The record kinds, and who owns each:
//   [dev · <KEY>]           the build role — ONE ticket-wide record, one `### <repo>` SECTION per
//                           repo inside it, each holding that repo's Status, Regression scope and
//                           History ledger. Two markers (dev-status + regression) per repo made a
//                           four-repo ticket carry eight comments for what is one story per repo.
//   [qa-plan · <repo>]      the QA planner — the BDD plan, latest revision
//   [test-report · <repo>]  /report-test-results — the run's verdict + evidence
//   [plans · <KEY>]         plan Artifact links, ticket-wide, written by the main session
//
// What is deliberately NOT here: a "dev done" or "build finished" note. The PR/MR is the code
// story — its diff, its title, its body — and a comment restating it is noise on a ticket a human
// is trying to read.
const RECORD_MARKER = (kind, scope) => `[${kind} · ${scope}]`
const durableRecord = (kind, scope, what) => ` DURABLE TICKET RECORD (docs/adr/0026) — post this as ONE record on ${ticket}, not a new comment each run: \`scripts/tracker/upsert-ticket-comment.sh ${ticket} --marker "${RECORD_MARKER(kind, scope)}" < <file>\` (a WRITER: run it BARE — no pipe, no \`&&\`, no \`$( )\`, no heredoc, or it is denied silently). The body's FIRST LINE must be exactly \`**${RECORD_MARKER(kind, scope)}**\` — that line is what the next run finds this record by, so do not translate it, reword it, or merge two scopes into one marker. Second line: \`run r${RUN_SEQ} · <date -u +%Y-%m-%dT%H:%MZ>\`. Then ${what} Keep it short: this is a record a human reads, not a log. Do NOT also post it with add-ticket-comment.sh, and do NOT post a separate "done"/"build finished" note — the PR/MR is the code story.`

// A record several agents CO-WRITE: one comment for the whole ticket, one `### <repo>` section
// inside it. The repos build in PARALLEL, so a writer must never see — let alone have to preserve
// — a sibling's text: --section splices its own block in and leaves every other byte untouched,
// under a lock. Without --section the writer would replace the whole record with its own section.
const sectionRecord = (kind, scope, what) => ` DURABLE TICKET RECORD (docs/adr/0026) — ${ticket} carries ONE \`${RECORD_MARKER(kind, ticket)}\` record shared by every repo in this run, and \`### ${scope}\` is YOUR section of it. Write it with \`scripts/tracker/upsert-ticket-comment.sh ${ticket} --marker "${RECORD_MARKER(kind, ticket)}" --section "### ${scope}" < <file>\` (a WRITER: run it BARE — no pipe, no \`&&\`, no \`$( )\`, no heredoc, or it is denied silently). The file's FIRST LINE must be exactly \`### ${scope}\` and it carries NO marker line — the script owns that. NEVER run this without \`--section\`, and never rewrite another repo's section: they are building in parallel and yours is the only block you know anything about. Inside your section use the \`####\` sub-blocks named below and nothing else. Then ${what} Keep it short: this is a record a human reads, not a log. Do NOT also post it with add-ticket-comment.sh, and do NOT post a separate "done"/"build finished" note — the PR/MR is the code story.`

const baseIsSettled = (base) => ` AND IT IS NOT A QUESTION TO HAND BACK. Other repos in this run may legitimately target a different base; seeing one is not evidence about yours. Do not raise the base as a \`decision_needed\`, do not ask which base applies to this repo, and do not stop to have it confirmed. If \`origin/${base}\` genuinely does not exist, the base-branch precondition at the open-PR step is what reports that — it is never a build-time judgment call. RE-DERIVING IT IS THE FAILURE MODE: answering "where does a branch of this shape usually go" silently discards a base this run overrode, and that is how a ticket's PR/MRs end up on branches nobody asked for. The run now ASSERTS the forge's own target_branch against ${base} right after the PR/MR is opened and again before approval (docs/adr/0025), so a re-derivation does not slip through — it costs a repair or a halt.`

const candidateStackClause = (appPlans) => appPlans.length
  ? `
CANDIDATE STACK (YOURS to do, before any spec runs): every app/service repo this suite exercises must be RUNNING, built from its ticket work branch — ${appPlans.map((p) => `${REPOS[p.repo].path}@${p.work_branch}`).join(', ')}. For each, NAME THE REPO IN THE COMMAND — a standalone \`cd\` does not carry into your next tool call, so nothing may lean on being "in" a repo: \`git -C <that repo's path> switch <its work branch>\`, then bring it up with \`cd <that repo's path> && scripts/dev.sh run\` as ONE call (its own harness — never a raw toolchain). Same for any datastore/migration repo the suite reads. Then PROVE the stack answers BEFORE you run a single spec: probe each port the suite targets and report what replied. ⚠️ A harness \`run\` that probes and then TEARS ITS SERVER DOWN has not given you a stack — it prints an UP verdict while nothing listens; start that server yourself in the background and re-probe. Point the suite at THAT stack EXPLICITLY via the local base-URL env its config reads — never rely on the config default, which commonly falls back to a deployed environment where the bug under test does not reproduce. If a service genuinely cannot come up, name the command and its failure; do NOT hand back a suite result obtained without it.`
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
    // C12 — the fingerprint inputs. Deliberately NOT the comment count: this run posts comments
    // itself, so a count-based fingerprint invalidated every plan it had just written (docs/adr/0018
    // addendum). Scope is the ONE stage that reads the live ticket, and it already walks the
    // acceptance criteria one by one (out_of_reach), so this list is free here.
    acceptance: { type: 'array', items: { type: 'string' } }, // the ticket's criteria, VERBATIM
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
    reused: { type: 'boolean' }, // C10 — true when this repo's Kickoff was SKIPPED (plan rehydrated from run state)
    base_branch: { type: 'string' }, work_branch: { type: 'string' },
    figma_url: { type: ['string', 'null'] }, plan_path: { type: 'string' },
    // ADR-0025 — the fingerprint of the plan file as this Kickoff left it. The Build phase compares
    // it against the `built` row's plan_sha: equal ⇒ the existing build really was made from THIS
    // plan and may be resumed; different ⇒ a re-plan has superseded it and the build is re-run.
    plan_sha: { type: ['string', 'null'] },
    // Which OTHER scoped repos this one vendors as a git submodule, read off `.gitmodules` — not
    // guessed, and not the same thing as depends_on. A declared dependency is a contract between
    // two repos; a submodule pin is a build-time fact about THIS repo's harness, and it is the one
    // dependency a parallel build genuinely cannot ignore: a suite that rebuilds its schema from a
    // vendored checkout can only see commits the pin can reach.
    submodule_pins: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['repo', 'path'],
        properties: {
          repo: { type: 'string' },  // the scoped repo id this one vendors
          path: { type: 'string' },  // the submodule path inside THIS repo, exactly as .gitmodules spells it
        },
      },
    },
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
    // Convergence contract: a build/fix handoff ALWAYS classifies its end state, so the
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
    status: { type: 'string', enum: ['complete', 'partial', 'blocked', 'deferred', 'already-satisfied'] },
    // ADR-0027 — the sanctioned way to say "this particular condition cannot be fixed here", so an
    // immovable one stops consuming attempts instead of being ground at until a budget runs out.
    // It ends that condition's attempts ONLY; the loop carries on with every other finding, and the
    // condition is recorded so the repo cannot reach 'ready'. Because this is the one field an
    // agent could reach for to escape hard work, it is refused without `evidence` AND `tried`:
    // a command with its exit code, or a measurement — never "it looks like infra".
    cannot_fix: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['kind', 'why', 'evidence', 'tried'],
        properties: {
          kind: { type: 'string' },      // which condition: 'suite-unverified' | 'loadtest-regression' | …
          why: { type: 'string' },       // the class or reason, in one line
          evidence: { type: 'string' },  // the command + exit code, or the number, that proves it
          tried: { type: 'string' },     // what you ruled out first — the cheap classes before the expensive claim
        },
      },
    },
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
    // REQUIRED when status === 'already-satisfied'. One entry per acceptance criterion this repo
    // owns, each pointing at the code that ALREADY meets it — shipped by earlier work, not by this
    // ticket. The citation is the whole claim: a verifier re-opens every one of them, and a
    // criterion with no entry is a criterion nobody checked, which sinks the claim outright.
    satisfied_by: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['criterion', 'commit', 'path_line', 'quote'],
        properties: {
          criterion: { type: 'string' },  // the acceptance criterion, quoted from the ticket
          commit: { type: 'string' },     // the sha that shipped it — `git log` it, do not guess
          path_line: { type: 'string' },  // file:line, or file:start-end, where the behaviour lives NOW
          quote: { type: 'string' },      // the source line(s) themselves, copied — the verifier matches on this
        },
      },
    },
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
    // REVIEW-FIX PASS ONLY. A reviewer finding whose ROOT fix must land in ANOTHER repo of this
    // run — e.g. a missing index only the migration repo can add, vendored here as a read-only
    // submodule the guard forbids editing. Declaring it here is what stops the loop from
    // re-confirming the same gap round after round: the workflow routes a scoped fix pass to that
    // repo instead. Same evidence standard as a deferral — an entry without OBSERVED evidence
    // (the fetch/grep that proves the fix exists neither here nor upstream) is ignored.
    upstream_fix_needed: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['repo', 'finding', 'evidence'],
        properties: {
          repo: { type: 'string' },     // the workspace repo id that owns the fix
          finding: { type: 'string' },  // the finding restated as WHAT must change in that repo
          evidence: { type: 'string' }, // what you OBSERVED: commands + results proving it is absent both here and upstream
        },
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
    // THREAD RESOLUTION (docs/agents/review-ledger.md) — the review threads this gate ticked
    // Resolve on, and the ones it deliberately left open. A pass carrying a non-empty still_open
    // is the one contradiction the gate's brief forbids it to return.
    resolved_threads: { type: 'array', items: { type: 'string' } },
    still_open: { type: 'array', items: { type: 'string' } },
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
// The forge's own record of whether a PR/MR already carries a review approval, read back from
// `scripts/vcs/pr-view.sh <n> --approved`. THREE values, and the third is load-bearing:
// "unknown" means the forge would not answer (approvals disabled on the instance, an API
// refusal), which is NOT "no" and emphatically not "yes" — a gate is never skipped on an
// unanswered question, and never re-run as if it had been answered no.
const APPROVAL_PROBE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['approved'],
  properties: {
    approved: { type: 'string', enum: ['yes', 'no', 'unknown'] },
    command: { type: 'string' }, note: { type: 'string' },
  },
}
// UNRESOLVED `Human:` DIRECTIVES on a PR/MR (docs/agents/human-review.md). Read from
// `scripts/vcs/pr-threads.sh <n>`, and the shape is deliberately narrow: a directive is a thread
// that is BOTH still unresolved AND opened by a person. A `Human:` REPLY on a thread an agent
// opened is a DISPOSITION — it CLEARS that finding rather than opening work — so it is not one of
// these, and neither is a thread a human resolved and said nothing on. An empty array is the
// normal answer; `blind:true` is the third value, and it is load-bearing for the same reason
// APPROVAL_PROBE_SCHEMA's "unknown" is: a probe that could not read the forge has not established
// that there is nothing there, and must never be the reason a review is skipped.
const HUMAN_DIRECTIVE_PROBE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['directives'],
  properties: {
    directives: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['thread_id', 'body'],
        properties: { thread_id: { type: 'string' }, location: { type: 'string' }, body: { type: 'string' } },
      },
    },
    blind: { type: 'boolean' },
    command: { type: 'string' }, note: { type: 'string' },
  },
}
// What the orchestrator's approval step did, per repo. Reported so the run summary can say the
// tick landed rather than assuming it: pr-approve.sh degrades to a verdict NOTE on a forge with
// approvals disabled, and a refused permission would otherwise pass silently.
const APPROVAL_POST_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['posted'],
  properties: {
    posted: { type: 'array', items: { type: 'object', additionalProperties: true } },
    failed: { type: 'array', items: { type: 'string' } },
    note: { type: 'string' },
  },
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
    // THREAD RESOLUTION (docs/agents/review-ledger.md) — the review threads this gate ticked
    // Resolve on, and the ones it deliberately left open. A pass carrying a non-empty still_open
    // is the one contradiction the gate's brief forbids it to return.
    resolved_threads: { type: 'array', items: { type: 'string' } },
    still_open: { type: 'array', items: { type: 'string' } },
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
    // C4 — the gate's own classification of each red, which decides who fixes it. The gate is the
    // only agent that has just watched the failure, so classifying is cheap here and nowhere else.
    triage: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['case', 'kind', 'evidence'],
        properties: {
          case: { type: 'string' },                                     // the failing spec/scenario id
          kind: { type: 'string', enum: ['automation', 'app', 'prereq'] },
          repo: { type: 'string' },                                     // REQUIRED for kind 'app': the scoped repo that carries the cause
          spec: { type: 'string' },                                     // the scoped re-run args for just this case
          evidence: { type: 'string' },                                 // what you OBSERVED: the assertion, the response, the screenshot path
          // true ⇒ a control run showed it red on the BASE branch too. NOT a synonym for "not
          // ours": a control that fails IDENTICALLY confirms a SHARED cause, and reading it as
          // out-of-scope is the single inference error that produced a two-round wrong diagnosis —
          // both specs were failing on one fixture value neither of them owned. Set it only when
          // the control's failure is genuinely a DIFFERENT failure that happens to also be red.
          pre_existing_on_base: { type: 'boolean' },
          // Set when the fix is claimed to lie outside this gate's bounds (a dependency bump, a
          // repo-wide change). This is the one conclusion that permanently ENDS investigation — no
          // later round has a reason to reopen it — so it is the most expensive to assert: name the
          // second, independent read that reached the same answer, or do not set it. Measured, the
          // conclusion was wrong, and acting on it would have shipped a repo-wide version bump that
          // did not fix the bug (the newer versions enforce the same restriction).
          out_of_gate_bounds_second_read: { type: ['string', 'null'] },
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

// Appended to every gate prompt. A gate still runs against the harness's own finite turn ceiling
// (no per-role maxTurns override anymore), and the structured verdict is the LAST thing it does — so a gate that investigates
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
// C9 — set when the run stops itself on its own token budget (see budgetStop below). writeSummary
// reads this to put a prominent banner at the top of the summary before it is ever assigned.
let budgetStopped = null
// Declared HERE, not at the Scope stage where it is first set: writeSummary reads it, and the
// scope stage can now END the run gracefully instead of throwing — a return that reached
// writeSummary before this line hit the temporal dead zone and threw anyway, which is the exact
// failure the graceful ending exists to replace.
let testSuiteGateUnavailable = null
const tick = (label) => { const now = budget.spent(); spend.push({ label, out: now - mark }); mark = now }
// C9 — the run's own ceiling. Checked only at PHASE BOUNDARIES: mid-phase there is nothing to
// stop cleanly, and every milestone is already checkpointed, so stopping here loses no work.
const overBudget = () => TOKEN_BUDGET > 0 && budget.spent() > TOKEN_BUDGET

// agent() THROWS when a subagent never returns StructuredOutput (after the engine's
// retries/nudges) — an uncaught throw aborts the ENTIRE run. safeAgent swallows that to
// null so the caller can degrade gracefully (re-loop, or halt THIS repo with a clean
// status) instead of killing the whole run. Generalizes the build-agent null-guard to
// every fix/review/merge/etc. agent() call. (Finding ⑥, 2026-06-07.)
//
// EVERY NON-CONVERGENCE IS RECORDED, NOT ONLY LOGGED. The `log()` line below is the only trace a
// swallowed agent has ever left, and it scrolls past: it reaches no run result, no summary file and
// no ticket record. So an invocation could spend hours on agents that returned nothing, and the
// artifacts a person actually reads afterwards — the summary, its token table — showed the tokens
// with no way to attribute them. A measured audit had to count repeated task ids in the harness's
// own journal to discover that a single step had been attempted six times, and even then the
// journal's `failed` rows carried no reason, because the reason is here and was thrown away.
//
// `agent()` retries and nudges internally before it throws, so ONE row here can stand for several
// attempts inside the harness — which is exactly why the diagnostic it carries is the only account
// of them this workflow can give. The rows ride the run result beside `spend`, and the summary
// renders them beside the token table, because "what did this cost" and "what did it buy" are the
// same question.
const nonConvergences = []
const safeAgent = async (prompt, opts) => {
  try { return await agent(prompt, opts) }
  catch (e) {
    const diagnostic = String(e?.stdout || e?.message || e).trim().slice(-1200)
    nonConvergences.push({ label: opts?.label || '(unlabelled)', phase: opts?.phase || null, agent_type: opts?.agentType || null, reason: diagnostic || '(the engine reported no reason)' })
    log(`⚠️ agent did not converge${opts?.label ? ` (${opts.label})` : ''} — treated as null: ${diagnostic}`)
    return null
  }
}
// A swallowed agent leaves exactly one piece of evidence: the engine's own words, filed above under
// the label it was called with. Callers need them BACK, because "returned nothing" has two causes
// that need opposite handling. An agent that ran away triaging a red still has work in flight worth
// parking; an agent ENDED FROM OUTSIDE — an interrupt, a timeout, a killed stream — did nothing
// wrong and was simply stopped, usually before it wrote a line. Told apart, the first gets "stop
// working and hand off", the second gets the truth plus a human action that says re-run rather than
// go read the branch. Conflated, a person is sent to audit a branch nobody ever touched.
const reasonFor = (label) => nonConvergences.filter((n) => n.label === label).map((n) => n.reason).pop() || ''

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
  // A submodule pin is an edge whether or not Scope declared one. `depends_on` is a judgement call
  // the scoping agent makes about contracts; a pin is a fact about the downstream's own harness, and
  // it binds harder — the downstream cannot even compile against code the pin cannot reach. Folding
  // pins in here means the waves order them correctly without a second graph to keep in step.
  plans.forEach((p) => {
    const declared = (p.depends_on || []).filter((d) => ids.has(d) && d !== p.repo)
    const pinned = (p.submodule_pins || []).map((s) => s?.repo).filter((d) => d && ids.has(d) && d !== p.repo)
    deps[p.repo] = [...new Set([...declared, ...pinned])]
  })
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
// Keyed on WHERE the findings sit (file_line / scope), never on the reviewer's PHRASING of them:
// `issue` and `title` are free text a re-visit re-words every round ("Round-3 re-visit …"), so a
// fingerprint that includes them never matches and the detector never trips — measured: five
// consecutive no-commit rounds re-confirming one unchanged finding, each round restated afresh.
// Two different findings at the same location collide into one key; with no new commit between
// rounds that collision still reads "stuck at the same place", which is the condition being tested.
const stallFp = (rows) => JSON.stringify(rows.map(([key, v]) => [
  key,
  (v?.comments || []).map((c) => String(c?.file_line ?? '?')).sort(),
  (v?.blocking || []).map((b) => String(b?.scope ?? '?')).sort(),
]).sort())

// Required closing step — runs the per-repo/role usage parser over the run's
// transcripts and writes the run-summary file. This agent's prompt intentionally
// OMITS the [dev-cycle …] marker so the parser does NOT count the recorder itself.
//
// C10 — WHICH ENDING EARNS THE CHANNEL. Only a run that took the ticket as far as a run can:
// every scoped repo reviewed-ready, the gate green (or legitimately skipped), and the merge/
// distribute left as the human `!` steps this workflow never performs itself. Everything else —
// blocked, halted, stalled, unverified, budget-stopped, plan-missing, dry-run, awaiting approval —
// is a private matter for the person who started it, and gets a DM instead of team-wide noise.
const COMPLETE_ENDINGS = ['merge-skipped', 'awaiting-human-ship']
// ADR-0027/0028 loudness, in ONE place because there are now two producers of blocking items (the
// review loop, per code repo; the test-suite gate, per suite repo) and a banner improved for one
// and not the other is exactly the drift these records exist to prevent.
const bannerBlocking = (rows, worked) => {
  if (!rows.length) return
  log(`⛔⛔ ${rows.reduce((n, b) => n + b.items.length, 0)} BLOCKING ITEM(S) the ${worked} worked and could NOT close — these are why the run did not finish, and each needs a person:`)
  rows.forEach((b) => b.items.forEach((it) => log(`   [${b.id}] ${it.kind}: ${it.detail}${it.human_action ? ` → ${it.human_action}` : ''}`)))
}
const DM_PLACEHOLDER = /^U0{6,}/
const dmTarget = NOTIFY && NOTIFY_DM && !DM_PLACEHOLDER.test(NOTIFY_DM) ? NOTIFY_DM : null
// ADR-0027 §Across invocations — a recorded blocking item has to OUTLIVE its run, or "a recorded
// item keeps its repo out of ready" is true for one invocation and false for the next: the gates it
// coexists with are ledgered PASSED, so the resumed run skips review, returns `ready`, and merges
// the very thing that was recorded. The workflow has no filesystem, so the row rides the closing
// agent that already writes files. Written for EVERY repo the run touched — with items, or cleared —
// because a row nobody rewrites is a blocker nobody can ever clear.
const blockedRowClause = (runResult) => {
  const rows = runResult?.blockingByRepo || []
  const ids = [...new Set([
    ...Object.keys(runResult?.repoResults || {}),
    ...(runResult?.testSuite?.suites || []).map((s) => s?.suite).filter(Boolean),
    ...rows.map((r) => r.id),
  ])]
  if (!ids.length) return ''
  const byId = new Map(rows.map((r) => [r.id, r.items]))
  return `
6. CARRY THE BLOCKING ITEMS FORWARD — with the Write tool, one file per repo, into \`agent_logs/${ticket}-dev-cycle-state/\` at the WORKSPACE ROOT, named \`<repo>-blocked.json\`. This is not bookkeeping: it is what stops the NEXT invocation from skipping a review whose gates all passed and merging what this run recorded as unclosable. Write ALL of these, exactly as given — a repo with nothing is written CLEARED, because a row nobody rewrites is a blocker nobody can clear:
${ids.map((id) => {
    const items = byId.get(id)
    return items && items.length
      ? `   • \`${id}-blocked.json\` ⇒ {"repo":"${id}","milestone":"blocked","status":"done","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>","blocking":${JSON.stringify(items)}}`
      : `   • \`${id}-blocked.json\` ⇒ {"repo":"${id}","milestone":"blocked","status":"in-progress","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>","blocking":[]}`
  }).join('\n')}
   Copy the \`blocking\` arrays VERBATIM — do not summarise, re-word or drop a field. The next run reads \`detail\` back to the developer as the must-fix, so a paraphrase is a changed instruction.`
}
async function writeSummary(runStatus, runResult, deferredScopeRun = [], satisfiedRun = []) {
  phase('Summary')
  const s = await safeAgent(
    `Run-recorder for the development-cycle workflow on ${ticket} (final status: ${runStatus}). You HAVE the Write tool + a narrow Bash perm for the usage parser — actually PRODUCE the file, do not just describe it.
1. Compose a short narrative: repos touched, per-repo gate/review rounds, the cross-repo test-suite gate result, distribution links, then merge order + SHAs (merge is the FINAL step) — from this run result: ${JSON.stringify(runResult).slice(0, 3000)}.${['repo-unresolved', 'review-unresolved', 'target-branch-halt', 'review-blocked-on'].includes(runStatus) ? ' Also state plainly, near the top, whether the cross-repo test-suite gate ran: on a stopped run it did NOT, so the change set is UNVALIDATED end-to-end and the run summary must not read as though it were.' : ''}
${(runResult?.blockingByRepo || []).length ? `1a. ⛔ BLOCKING ITEMS — this run WORKED these and could not close them (the review loop per code repo, or the cross-repo test-suite gate per suite repo), which is why it did not finish. Give them their own "## Blocking — needs a person" section ABOVE the narrative, one row per item: the repo, the kind, what it says, and the human action named. Do NOT soften them into "minor issues" and do NOT bury them in the per-repo narrative: each one is the reason a repo could not reach ready — or the reason a GREEN suite is still not a pass — and a reader who misses them will think the run merely ran out of rounds. Items: ${JSON.stringify(runResult.blockingByRepo).slice(0, 2000)}\n` : ''}${deferredScopeRun.length ? `1b. ⚠️ DEFERRED SCOPE — this run did NOT meet every acceptance criterion, by design, and NO follow-up ticket was filed for the gap: it is recorded here for a human to decide what happens to it. Give it its own "## Deferred scope — your decision" section near the TOP (above the narrative), one row per item: the criterion, the repo that deferred it, the owner who can do it, and the evidence given. Then one line naming the decision waiting: file a ticket for these, route them to those owners, or accept the ticket as-is. Items: ${JSON.stringify(deferredScopeRun)}\n` : ''}${satisfiedRun.length ? `1c. ✅ ALREADY SATISFIED — ${satisfiedRun.length} acceptance criterion/criteria needed NO code change: they are met by code that shipped before this ticket, and each citation was independently re-opened and confirmed. Give this its own "## Already satisfied — no change needed" section, one row per item: the criterion, the repo, the commit that shipped it and the file:line. Write it as a FINDING, not an apology: an empty diff here is the correct answer, and the repos involved opened no branch and no PR/MR by design — say that explicitly so nobody reads a missing MR as a missing step. Items: ${JSON.stringify(satisfiedRun).slice(0, 2000)}\n` : ''}
${trackerReachable ? '' : '2. ⚠️ The tracker was UNREACHABLE this run — put a prominent note at the TOP that ticket Status moves, comments, and /clarifying-ticket improvement tickets did NOT persist (best-effort only).\n'}${testSuiteGateUnavailable ? `2b. ⚠️ The cross-repo test-suite (QA) gate was REQUESTED for this ticket but did NOT run — put a prominent banner at the TOP (same treatment as the tracker-unreachable note): "${testSuiteGateUnavailable}" The ticket shipped WITHOUT its end-to-end validation, so do NOT describe this run as test-suite-validated.\n` : ''}${qualityGateUnavailable ? `2c. ⚠️ The configured quality/performance gate did NOT run this run — put a prominent banner at the TOP (same treatment as the tracker/test-suite notes): "${qualityGateUnavailable}" Do NOT describe this run as quality-gate-validated.\n` : ''}${loadtestGateUnavailable ? `2d. ⚠️ The load-test BASELINE comparison produced no verdict this run — put a prominent banner at the TOP (same treatment as the notes above): "${loadtestGateUnavailable}" The suite was green, but "no slower than the base branch" is UNPROVEN — do NOT describe this run as performance-validated, and state what would settle it (a run at the planned rate against a scaled environment).\n` : ''}${budgetStopped ? `2e. 🛑 BUDGET STOP — put this as the FIRST line of the file, as a prominent banner: "${budgetStopped}" Say plainly which phases did NOT run, so nobody reads this summary as a completed cycle.\n` : ''}3. WRITE that narrative with the Write tool TWICE, to two paths at the WORKSPACE (org) ROOT: agent_logs/${ticket}-DEV-CYCLE-SUMMARY-r${RUN_SEQ}.md (this invocation's own record, which NOTHING may overwrite — it is how a later reader reconstructs what each round of a hard ticket actually did, and its absence is why one postmortem had to be rebuilt from a chat log) and agent_logs/${ticket}-DEV-CYCLE-SUMMARY.md (the LATEST pointer every other tool reads) — the workspace (org) ROOT — the workflow's launch directory, the dir that holds .claude/ — NEVER inside a product repo's agent_logs/. Do NOT cd into any repo first; if your cwd is not the workspace root, return there before writing (the root agent_logs dir already exists).
4. RUN:  python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py ${ticket}  — then Write BOTH files AGAIN as the narrative PLUS the parser's Markdown output appended VERBATIM under a "## Token & time usage" heading. Under that heading also state, in one line each: this invocation is r${RUN_SEQ} of ${ticket}; it spent ${budget.spent()} OUTPUT tokens against a ceiling of ${TOKEN_BUDGET} (dev_cycle.token_budget counts OUTPUT tokens only — total run tokens have measured roughly 29x that, so do not present the ceiling as a total-token budget); and the per-ticket running total, which you get by adding this invocation's output tokens to the same figure in the newest agent_logs/${ticket}-DEV-CYCLE-SUMMARY-r*.md that already exists (grep it out with \`grep -h 'output tokens this invocation' agent_logs/${ticket}-DEV-CYCLE-SUMMARY-r*.md\`), so a reader can see what the WHOLE ticket has cost across every round rather than just the last one. Write the line as: "<n> output tokens this invocation · <total> across r1..r${RUN_SEQ}". If nothing earlier exists, this invocation IS the total. If the parser exits non-zero (no transcripts), write that fact under the heading — never a placeholder.${nonConvergences.length ? `
4a. AGENTS THAT RETURNED NOTHING — under that SAME "## Token & time usage" heading, and after the table, add a "### Agents that did not converge" sub-section listing all ${nonConvergences.length} of them, one row each: the label, the phase, and the reason VERBATIM (do not paraphrase an error string, and do not tidy a stack trace into prose). Open the sub-section with one line: these agents were spawned, spent tokens and returned no structured result, so their cost is inside the totals above while their work is not — and the engine retries each of them internally before giving up, so one row can stand for several attempts. This is the only account of that spend anyone gets; a reader comparing hours against output is reading it to find exactly this. Rows: ${JSON.stringify(nonConvergences).slice(0, 2500)}` : ''}
5. ARM THE ORCHESTRATOR GUARD — the run is over, so this session's job from here is to orchestrate, not to implement (docs/adr/0019). Read the session id with \`printf '%s\\n' "$CLAUDE_CODE_SESSION_ID"\`, then with the Write tool REPLACE \`agent_logs/${ticket}-dev-cycle-state/orchestrator-guard.json\` with exactly {"session_id":"<what that printed>","ticket":"${ticket}","armed":true,"run_state":"ended","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}. Write it whatever the run's status is. If the env var printed nothing, write "session_id":"" — the guard stays inert rather than arming against an unknown session.
${blockedRowClause(runResult)}
Return summary_path (the file you actually wrote + confirmed exists via Read), token_table_appended:true ONLY if you ran the parser and appended its real table, and a one-line note.` + LANGUAGE_DIRECTIVE,
    { agentType: 'documentor', phase: 'Summary', label: `summary:${ticket}`, schema: SUMMARY_SCHEMA },
  )
  tick('summary')
  if (s && s.token_table_appended === false) log('⚠️ Summary file written but the token/time table was NOT appended (parser empty/failed) — run parse_workflow_usage.py manually.')
  log(`Run summary: ${s?.summary_path ?? '(summary agent did not converge)'}`)
  const result = s ?? { summary_path: null, token_table_appended: false, note: 'summary agent did not converge' }
  // Every terminal return in this workflow carries writeSummary's return as `summary`, so attaching
  // the non-convergences here puts them on the run result by construction — the same reason the
  // incomplete-run DM lives in this function rather than at nineteen return sites. A reader of the
  // raw run result sees the reasons even when the summary file itself is what failed to be written.
  if (nonConvergences.length) result.non_convergences = nonConvergences
  // C10 — every ending EXCEPT the two COMPLETE ones DMs the configured member instead of posting
  // to the channel; folded into writeSummary so every return path is covered by construction.
  // RESUME (docs/adr/0018) — keyed by run_status, not just "any DM ever sent": a run that ends the
  // SAME way again on a resumed invocation must not re-DM, but a NEW ending (e.g. repo-unresolved →
  // budget-stopped) is a genuinely different thing to tell the human and still gets its own DM.
  // Never degraded, same as the notify checkpoint — a human forces a fresh one by deleting the row.
  const dmAlreadySent = stateRows.some((r) => r.repo === 'all' && r.milestone === 'dm_sent' && r.status === 'done' && r.degraded !== true && r.run_status === runStatus)
  if (!COMPLETE_ENDINGS.includes(runStatus) && dmTarget) {
    if (dmAlreadySent) {
      log(`[notify] DM SKIPPED — run state says a "${runStatus}" DM for ${ticket} already went out; delete agent_logs/${ticket}-dev-cycle-state/all-dm_sent.json to force a fresh one.`)
    } else {
      await safeAgent(
        `${tag('all', 'notifier', 'dm')} Send ONE Slack DIRECT MESSAGE about an INCOMPLETE dev-cycle run. Run it from the WORKSPACE (org) ROOT; do NOT cd, do NOT touch git or the tracker, do NOT post to any channel. The command is a mutating adapter call, so it must be the WHOLE Bash command — no pipe, no &&, no $( ), no heredoc:

scripts/notify/send.sh --channel ${dmTarget} ${JSON.stringify(`${ticket} dev-cycle ended: ${runStatus}.${(runResult?.blockingByRepo || []).length ? ` ${runResult.blockingByRepo.reduce((n, b) => n + b.items.length, 0)} blocking item(s) the loop could not close: ${runResult.blockingByRepo.map((b) => `${b.id} (${b.items.map((i) => i.kind).join(', ')})`).join('; ')}.` : ''} Summary: ${result.summary_path || '(none written)'}. Resume: /dev-cycle ${ticket}`)}

On success it prints \`ok=1\`. Return sent:true ONLY if it exited 0, with the permalink when printed; on ANY failure return sent:false with the command's stderr in note. Do NOT retry more than once and send nothing else.` + runMarkerWrite('dm_sent', `,"run_status":${JSON.stringify(runStatus)}`),
        { agentType: 'documentor', model: 'haiku', phase: 'Summary', label: `dm:${ticket}:${runStatus}`, schema: NOTIFY_SCHEMA },
      )
    }
  }
  return result
}

// C9 — the run's own budget-stop checkpoint. Called at each phase boundary; writes the same
// summary + returns the same result shape every other terminal path does, so a budget stop is
// just another handoff — resumable, never a crash.
const budgetStop = async (nextPhase, payload, deferredScopeRun = [], satisfiedRun = []) => {
  budgetStopped = `Run stopped on its own token budget before the ${nextPhase} phase: ${budget.spent()} > ${TOKEN_BUDGET} OUTPUT tokens (workspace.config.yaml dev_cycle.token_budget — it counts OUTPUT tokens only, and total run tokens have measured roughly 29x that, so this ceiling is far smaller than it looks). Nothing failed — the run ran out of the budget it was given. Re-run \`/dev-cycle ${ticket}\` (run state resumes every milestone already proven) or raise the ceiling with \`--token-budget <n>\`.`
  log(`⛔ BUDGET STOP — ${budgetStopped}`)
  const summary = await writeSummary('budget-stopped', { ticket, stopped_before: nextPhase, spent: budget.spent(), token_budget: TOKEN_BUDGET, ...payload }, deferredScopeRun, satisfiedRun)
  return { ticket, status: 'budget-stopped', stopped_before: nextPhase, spent: budget.spent(), token_budget: TOKEN_BUDGET, budgetStopped, summary, spend, ...payload }
}

// ── Notify (review request) — OPTIONAL phase, runs LAST (after Summary) ──
// Called ONLY from the auto-merge-OFF (merge-skipped) path: every repo is built + reviewed
// and the cross-repo test-suite gate is green, but the validated PR/MR are left OPEN for a
// human to merge — so we ping the team to review them. Gated on notify.enabled (NOTIFY). With
// auto-merge ON the run hands the merge/distribute off to a human (nothing to review), so this is never
// reached. Best-effort: a send failure NEVER changes the run's outcome — the PRs are already
// open + validated. The /notify skill owns the digest: `scripts/notify/send.sh --review <KEY>`
// GATHERS the ticket's open PR/MR across every workspace repo, composes the message, and sends —
// one source of truth for format + gather (no repo missed, nothing hand-assembled here). This
// phase only decides WHETHER to notify: repoResults gives a cheap "is there any open PR?" check
// so we don't spawn an agent for nothing. `reposInOrder` = repo ids in dependency order.
async function notifyReview(reposInOrder) {
  if (!NOTIFY) return null
  phase('Notify')
  // RESUME (docs/adr/0018) — a prior invocation already sent this ticket's review-request digest
  // and nothing here re-derives whether the digest content would differ, so a resumed run that
  // lands on the same merge-skipped outcome again must not re-announce it. Never degraded (see the
  // run-state loader): the proof is the send itself. A genuinely fresh digest is a human call —
  // delete agent_logs/${ticket}-dev-cycle-state/all-notified.json.
  if (doneAt('all', 'notified')) {
    log(`[notify] SKIPPED — run state says the review-request digest for ${ticket} already went out; delete agent_logs/${ticket}-dev-cycle-state/all-notified.json to force a fresh one.`)
    return { sent: true, note: 'already notified this run — skipped (docs/adr/0018)' }
  }
  const title = scope?.title || plans.find((p) => p?.title)?.title || ''
  if (!reposInOrder.some((id) => repoResults[id]?.pr?.pr_url)) {
    log('[notify] no open PR/MR to announce — Notify skipped.'); return null
  }
  const channelArg = NOTIFY_CHANNEL ? ` --channel ${JSON.stringify(NOTIFY_CHANNEL)}` : ''
  const titleArg = title ? ` --title ${JSON.stringify(title)}` : ''
  const r = await safeAgent(
    `${tag('all', 'notifier', 'notify')} Post the review-request notification for ${ticket} via the /notify skill. ONE command does it all — it gathers the ticket's open PR/MR across every workspace repo, composes the digest, and sends. Run it from the WORKSPACE (org) ROOT (the dir holding .claude/); do NOT cd into a repo, touch git, or the tracker.

scripts/notify/send.sh --review ${ticket}${titleArg}${channelArg}

On success it prints \`ok=1\` and a \`permalink=\` line. Return sent:true ONLY if it exited 0 (printed ok=1), with the permalink + channel="${NOTIFY_CHANNEL}" when printed; on ANY failure (including "no open PR/MR found … nothing to announce") return sent:false with the command's stderr in note. Do NOT retry more than once.` + runMarkerWrite('notified'),
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
// Returns { repo, status:'ready'|'build-unresolved'|'pr-unresolved'|'target-branch-halt'|'review-unresolved'|'review-blocked-on', blocking:[…], … }.
// ADR-0027 — the review loop no longer RETURNS a per-condition halt. A regression, a stall, an
// unrunnable suite or a cross-repo gap it could not close comes back as a `blocking[]` entry on a
// 'review-unresolved' repo, which is what keeps it out of 'ready'.
// NOTE: never calls phase() — multiple of these run in parallel within a wave, so
// every agent() sets opts.phase explicitly to avoid racing the global phase state.
// ──────────────────────────────────────────────────────────────────────────
// The absolute path of one repo's clone — the anchor every command needs, because a standalone
// `cd` does NOT survive into an agent's next tool call (measured directly: `cd <dir>` in one call,
// `pwd` in the next, and the second answers with the old directory). Falls back to the
// workspace-relative path when the root could not be resolved, which is the same fallback every
// other path in this file uses.
const absOf = (id) => (haveAbs ? `${WORKSPACE_ROOT}/${REPOS[id].path}` : REPOS[id].path)

// The shell contract handed to every agent that works inside a repo. Three routings, because a
// persisted cwd is not one of them: `git -C <abs>` for plain git, ONE `cd <abs> && <cmd>` compound
// for anything else that must run in the repo, and `VCS_REPO=` for the vcs adapter — which has no
// `-C` of its own and may not be compounded (the guard denies that silently, which is the gap the
// two side-door incidents fell through). Parameterized by repo id, not fixed to one, because a
// cross-repo escalation and the test-suite repair loop brief agents that work in ANOTHER repo of
// this run — same contract, different path.
const shellClauseFor = (id) => {
  const abs = absOf(id)
  return `Work in the ${id} repo — its path is ${abs}. Your shell starts at the workspace root, and a standalone \`cd\` does NOT carry into your NEXT tool call, so never assume you are still "in" a repo: name it in the command instead. PLAIN GIT — anchor it with \`-C\`: \`git -C ${abs} fetch origin\`, \`git -C ${abs} switch <branch>\`, \`git -C ${abs} rev-parse HEAD\`, \`git -C ${abs} status --porcelain\`, \`git -C ${abs} ls-remote …\`. ANYTHING ELSE THAT MUST RUN INSIDE THE REPO (this repo's harness, \`scripts/dev.sh …\`, a build step) goes as ONE call: \`cd ${abs} && <the command>\` — that compound is fine for every command EXCEPT an adapter writer. VCS ADAPTER CALLS: \`scripts/vcs/*.sh\` takes no \`-C\` and may not be compounded, so it is ROUTED, not navigated to. Resolve VCS_REPO ONCE, in its own command: \`git -C ${abs} remote get-url origin\`. From what it prints, strip the leading \`git@<host>:\` or \`https://<host>/\` and any trailing \`.git\` — what remains (\`owner/repo\` on GitHub, \`group/subgroup/project\` on GitLab) is this repo's VCS_REPO. Prefix EVERY \`scripts/vcs/*.sh\` call for the rest of this task with it, as a plain env-var on the SAME bare line as the writer — \`VCS_REPO=<that value> scripts/vcs/<script>.sh …\` — never inside \`$( )\`, a pipe, or \`&&\` (any of those denies the call silently, same as wrapping the writer itself). That prefix is what pins the target: several repos of this run share ONE Bash session, so cwd could never have told the adapter which repo you meant.`
}

// C4 — shared "verify green" instruction. The code reviewer's own gate (inside
// runRepoPipeline, below) and the test-suite gate's app-red triage loop (Test suite phase)
// both need a reviewer to PROVE a repo's suite is green before approving a fix — one
// function, one wording, called from both places instead of two copies drifting apart.
const greenGateFor = (repoId, branch) => {
  const gDesc = REPOS[repoId]
  const gBase = plans.find((p) => p.repo === repoId)?.base_branch || gDesc.base?.feature
  return `🛑 MUST DO before you approve — RUN THE SUITE yourself on ${branch} (workflow step 5, "Verify green"): \`cd ${absOf(repoId)} && scripts/dev.sh test\` as ONE call (a standalone \`cd\` does not carry into your next tool call, so a bare \`scripts/dev.sh test\` runs whatever repo the shell is in), plus \`scripts/dev.sh analyze\`/\`gen\` the same way when this repo's definition of green names them — green here means "${gDesc.green ?? 'the repo suite passes'}". Run the WHOLE suite, never the raw toolchain (cargo/npm/pnpm), and drill a failure with \`scripts/dev.sh why test\` rather than dumping the log. The developer built on this same clone, so HEAD should already be ${branch} — confirm with \`git -C ${absOf(repoId)} rev-parse HEAD\` before trusting the run. Return tests_green + tests_receipt (the invocation and its result). A RED suite is a must-fix: comment it inline (failing test + shortest decisive output line + the change you believe caused it) and return approved:false — but first rule out a KNOWN FALSE-RED by re-running it in isolation against ${gBase}${gDesc.knownFalseReds ? `. This repo declares its own: ${gDesc.knownFalseReds}` : ' — this repo declares none, so judge the red on its own evidence'}. If the suite needs a local stack, bring it up via that repo's own harness (\`cd <dep-repo's absolute path> && scripts/dev.sh run\`, one call) and re-run — "the environment was down" is not an answer. If it STILL genuinely cannot run, set tests_green:false + gate_unavailable:true + unavailable_reason (what you tried, why each attempt failed, the exact unblocking command), post ONE loud PR/MR comment that the test gate could not run, and do NOT approve — never fabricate a green.
BUDGET A RED, DO NOT CHASE IT. Classifying a red is bounded work: ONE isolated re-run of that test decides it, and a diff of the files on its path against ${gBase} settles whose red it is. That is enough to call it pre-existing and move on — say so in one line and keep going. Two dead ends specifically, both already paid for: a throwaway \`git worktree\` cannot reproduce anything that needs credentials, because a new worktree has NO \`.env\` and copying one there is forbidden, so every test in it dies at "environment variable not found"; and re-triaging a red you already classified in an earlier round buys nothing. If a red resists that bounded check, report it as unattributed with what you tried — an unattributed red is a legitimate finding, and spending the rest of your turns on it is not.`
}
// ──────────────────────────────────────────────────────────────────────────
// TARGET-BRANCH GATE (docs/adr/0025)
//
// The pipeline was thorough about the base right up to the moment the PR/MR was created, and
// blind afterwards: three separate prompts warn an agent not to re-derive it, and nothing ever
// asked the forge what the thing actually targets. Measured consequence — a run reported its
// designed clean finish (`merge-skipped`, "reviewed + validated") with every MR of a four-repo
// ticket pointed at a branch nobody had asked for, one of them at a branch that repo's own
// documented policy forbids. A human caught it after the pipeline called itself done. Three
// warnings for one rule is evidence that prose does not hold; this is the mechanical version.
//
// It runs TWICE. At open-PR, so a mis-targeted MR is repaired before three reviewers pay to
// review it — and because that is where the run still holds the base as a live fact. Again before
// Approve, because a resumed invocation skips open-PR entirely and because a human can retarget
// an MR mid-run. Read-only both times unless it has a repair to make.
const TARGET_GATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repo', 'open_prs', 'target_branch', 'matches'],
  properties: {
    repo: { type: 'string' },
    // Every OPEN PR/MR carrying this ticket key, so an ACCUMULATED second one is visible. A
    // `pr_open` row proves a head sha, not an MR identity, so a resume could open another.
    open_prs: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['number', 'target_branch'],
        properties: {
          number: { type: ['number', 'string'] },
          target_branch: { type: 'string' },
          source_branch: { type: ['string', 'null'] },
          url: { type: ['string', 'null'] },
        },
      },
    },
    target_branch: { type: 'string' },   // what THE PR/MR under test targets, after any repair
    matches: { type: 'boolean' },        // target_branch === the base this run recorded
    retargeted: { type: ['boolean', 'null'] },   // a repair was made and re-read back
    detail: { type: ['string', 'null'] },        // the adapter's own words on any failure
  },
}
// Returns { ok, why } — ok:false HALTS the repo. `repair` arms the retarget; the assert is
// read-only without it.
async function assertTargetBranch(repoId, rp, pr, { repair, phaseName }) {
  const absR = absOf(repoId)
  const num = pr?.pr_number ?? null
  if (num === null || num === undefined) return { ok: true, why: 'no PR/MR number on record — nothing to assert' }
  const v = await safeAgent(
    `${tag(repoId, 'general-purpose', 'target-branch-gate')} ASSERT ONLY — change no code, run no tests, review nothing. ${shellClauseFor(repoId)}
THE BASE THIS RUN RECORDED FOR ${repoId} IS \`${rp.base_branch}\`. It is a fact of the run, not something to re-derive: do NOT consult origin/HEAD, default-branch.sh, the branch prefix or the repo's usual default, and do not form an opinion about whether it is the right base. Your job is to compare and report.
1. List every OPEN PR/MR carrying this ticket: \`VCS_REPO=${repoId} scripts/vcs/find-prs.sh ${ticket}\`. It prints one web URL per line; the number is the URL's last path segment. Report EVERY one you find in open_prs — a second open PR/MR for one repo is itself the finding, even if the first one is correct.
2. For PR/MR ${num}, read what it actually targets: \`VCS_REPO=${repoId} scripts/vcs/pr-view.sh ${num}\`. It prints \`target_branch=\` and \`source_branch=\` — use those lines verbatim, and never reach past the adapter to glab/gh/curl for them.
3. Compare: matches=true only when target_branch is EXACTLY \`${rp.base_branch}\`.${repair ? `
4. IF IT DOES NOT MATCH, REPAIR IT — but prove the base exists on the remote first: \`git -C ${absR} ls-remote --exit-code --heads origin ${rp.base_branch}\`. If that fails, STOP: do NOT push the base, do NOT retarget, and return matches:false with the command and its exit code in detail. If it succeeds, run \`VCS_REPO=${repoId} scripts/vcs/retarget-pr.sh ${num} --base ${rp.base_branch}\` (BARE — no pipe, no &&), then re-read \`VCS_REPO=${repoId} scripts/vcs/pr-view.sh ${num}\` and report the target_branch THAT SECOND READ printed. Set retargeted:true only when the re-read confirms it. A retarget keeps existing approvals; closing and reopening does not, so never do that instead.
5. Do NOT close, merge, approve or comment on anything. Repointing the one PR/MR at the run's own base is the ONLY write you are authorised to make.` : `
4. Do NOT repair anything and do NOT write: this is the pre-approval assert. Report what you found.`}
Return the structured result with repo=${repoId}.` + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
    { agentType: 'general-purpose', model: 'haiku', phase: phaseName, label: `target-gate:${ticket}:${repoId}`, schema: TARGET_GATE_SCHEMA },
  )
  // NEVER FAIL OPEN: an assert that could not run is not a pass. Same rule as the test-suite
  // audit — the whole point of this gate is that "nobody checked" was the previous state.
  if (!v) return { ok: false, why: `the target-branch assert did not converge for ${repoId} — the PR/MR's target is unknown, so it is not verified. Check by hand: VCS_REPO=${repoId} scripts/vcs/pr-view.sh ${num}` }
  const others = (v.open_prs || []).filter((p) => String(p.number) !== String(num))
  if (others.length) {
    // `multipleOpen` matters to the caller: this run's own PR/MR still has a computable diff, so
    // the review is worth doing (ADR-0027) — unlike a base that is missing from the remote, where
    // there is nothing to diff against at all.
    return {
      ok: false, multipleOpen: true,
      why: `${repoId} has ${others.length + 1} OPEN PR/MR(s) for ${ticket}; exactly one is expected. This run owns #${num} (→ ${v.target_branch}); also open: ${others.map((p) => `#${p.number} → ${p.target_branch}`).join(', ')}. Close the ones that should not land — \`VCS_REPO=${repoId} scripts/vcs/close-pr.sh <number> --body "<why>"\` — then re-run. Closing an MR is a human call, so the run will not do it.`,
    }
  }
  if (!v.matches) {
    return {
      ok: false,
      why: `${repoId} PR/MR #${num} targets ${v.target_branch || '(unknown)'}, and this run's base is ${rp.base_branch}.${v.detail ? ` ${v.detail}` : ''} Repair it: \`VCS_REPO=${repoId} scripts/vcs/retarget-pr.sh ${num} --base ${rp.base_branch}\``,
    }
  }
  if (v.retargeted) log(`[${repoId}] target branch REPAIRED — PR/MR #${num} now targets ${v.target_branch} (this run's base); approvals are unaffected by a retarget.`)
  else log(`[${repoId}] target branch OK — PR/MR #${num} → ${v.target_branch}.`)
  return { ok: true, why: '' }
}

// ──────────────────────────────────────────────────────────────────────────
// A BASE REPAIR IS ITS OWN STEP, NOT THE ROUND'S FIRST SLICE
//
// ADR-0025 made the run's base a FACT of the run. ADR-0032 gave the build a continuation budget for
// work OF ITS OWN that did not finish. Nothing connected the two, and the gap has a shape: the base
// is authoritative, the work BRANCH is not checked against it, and the first thing that reads both
// is the build agent — after the round has already been paid for.
//
// A branch can stand on the wrong base for reasons that have nothing to do with the build: it was
// cut from whatever was checked out rather than from `origin/<base>`, or `--accept-base-change`
// moved the base underneath a branch that already existed. Either way the build agent opens the
// repo, finds a history that is not the one the plan assumed, and does the git surgery — as its
// first slice, out of the same budget and the same continuation passes ADR-0032 sized for feature
// work. A measured round did exactly that: the round ended with two commits, both of them the
// repair, no source file touched, and a handoff whose own `root_cause` was that the round had gone
// on the base correction. Nothing in the result said "this round did base repair" — it had to be
// inferred from a git log, because the accounting has no word for it.
//
// So the reconciliation happens BEFORE the build agent is dispatched, and it is accounted like any
// other step: its own agent, its own label, its own `tick`. Three outcomes:
//
//   ok           — the branch carries nothing the base does not, or only this ticket's own commits.
//                  The overwhelmingly common case, and NOTHING changes for it: no repair, no note
//                  in the build brief, the round's budget is exactly what it was before.
//   repaired     — the branch carried commits that are not this ticket's, and none of this ticket's
//                  own work was at stake, so it was re-pointed at the base. The build brief says so
//                  (do not do it twice), and the round's own budget goes to slices.
//   unrepairable — the branch carries foreign commits AND this ticket's commits, so re-pointing
//                  would delete work and rebasing could conflict half-way. That is the ADR-0032
//                  terminal case verbatim — "a target branch that cannot be made right (no
//                  computable diff)" — and it ends the repo the way the other one does, with the
//                  rebase command a person can run.
//
// WHAT DECIDES "FOREIGN". Every commit this workflow asks for carries `Refs <ticket>`, so a commit
// in `origin/<base>..<branch>` that does not name the ticket is one the branch inherited rather
// than earned. That is a signal the framework itself creates, which is why it can be trusted here.
const BASE_GATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repo', 'branch_exists', 'state', 'ticket_commits', 'foreign_commits', 'detail'],
  properties: {
    repo: { type: 'string' },
    branch_exists: { type: 'boolean' },      // false ⇒ the build creates it from the base; nothing to check
    state: { enum: ['ok', 'repaired', 'unrepairable'] },
    ticket_commits: { type: 'integer' },     // commits in base..branch that DO name this ticket
    foreign_commits: { type: 'integer' },    // commits in base..branch that do NOT — the drift itself
    head_sha: { type: ['string', 'null'] },
    parked_at: { type: ['string', 'null'] }, // the stash ref uncommitted work went to, if any
    rebase_command: { type: ['string', 'null'] }, // unrepairable only — what a person runs
    detail: { type: 'string' },
  },
}
// Returns the verdict, or null when the probe did not converge. A null does NOT halt: today this
// step does not exist at all, so a flaky probe must leave the normal case exactly where it was.
async function reconcileBranchBase(repoId, rp, phaseName) {
  const absR = absOf(repoId)
  return await safeAgent(
    `${tag(repoId, 'general-purpose', 'base-reconcile')} GIT ONLY — assert, and repair only what rule 3 below allows. Write no feature code, run no tests, touch no PR/MR and no tracker. ${shellClauseFor(repoId)}
THE BASE THIS RUN RECORDED FOR ${repoId} IS \`${rp.base_branch}\` and the work branch is \`${rp.work_branch}\`. The base is a fact of the run, not something to re-derive: do NOT consult origin/HEAD, default-branch.sh, the branch prefix or the repo's usual default, and do not form an opinion about whether it is the right base.${baseIsSettled(rp.base_branch)}
1. \`git -C ${absR} fetch origin\`. If \`git -C ${absR} rev-parse --verify --quiet refs/remotes/origin/${rp.base_branch}\` prints nothing, the base is not on the remote: return state:"ok" saying so and change NOTHING — the open-PR step reports a missing base, and it is not this step's job to duplicate that. Then \`git -C ${absR} rev-parse --verify --quiet refs/heads/${rp.work_branch}\`; if THAT prints nothing the branch does not exist yet and the build creates it from the base, so return branch_exists:false, state:"ok", both counts 0.
2. COUNT THE DRIFT — \`git -C ${absR} log --oneline --no-decorate origin/${rp.base_branch}..${rp.work_branch}\` lists every commit the branch carries that the base does not. Split that list in two. A commit whose message mentions \`${ticket}\` is THIS TICKET'S OWN WORK — count it in ticket_commits. Every other commit is FOREIGN: it is on this branch because the branch was cut from something other than \`origin/${rp.base_branch}\` — count it in foreign_commits and name them (sha + subject) in detail.
3. DECIDE, and do only what your case says:
   • foreign_commits == 0 ⇒ state:"ok". The branch stands on this run's base. Change NOTHING — a branch that already carries this ticket's own commits is a build in progress, which is correct and is not drift.
   • foreign_commits > 0 AND ticket_commits == 0 ⇒ REPAIR IT with step 4. Nothing of this ticket's own is on the branch, so re-pointing loses no work.
   • foreign_commits > 0 AND ticket_commits > 0 ⇒ state:"unrepairable". Do NOT re-point (it would delete this ticket's own commits) and do NOT rebase (a conflict half-way through leaves the tree worse than you found it, with nobody watching). Change nothing, and return in rebase_command the command a PERSON can run: \`git -C ${absR} rebase --onto origin/${rp.base_branch} <the oldest foreign commit>^ ${rp.work_branch}\`, with that sha filled in.
4. THE REPAIR, in this order, every command anchored with \`-C\` (a standalone \`cd\` does not carry into your next tool call):
   a. \`git -C ${absR} status --porcelain\`. If ANYTHING is uncommitted — tracked or untracked — park it FIRST: \`git -C ${absR} stash push -u -m "${ticket} base-repair"\`, and put the stash ref in parked_at. A clean tree leaves parked_at null.
   b. \`git -C ${absR} checkout --detach origin/${rp.base_branch}\` — \`git branch -f\` refuses to move a branch that is checked out, so detach before you move it.
   c. \`git -C ${absR} branch -f ${rp.work_branch} origin/${rp.base_branch}\`
   d. \`git -C ${absR} switch ${rp.work_branch}\`
   e. Only if you parked something in (a): \`git -C ${absR} stash pop\`. If the pop CONFLICTS, stop and leave the conflict exactly as it is — return state:"unrepairable" with parked_at naming the stash and the conflicting paths in detail, because resolving someone's uncommitted work against a different base is a person's call, not yours.
   f. PROVE IT with a SECOND read: \`git -C ${absR} rev-parse HEAD\` and \`git -C ${absR} log --oneline origin/${rp.base_branch}..${rp.work_branch}\`. state:"repaired" ONLY when that log prints nothing but this ticket's own commits (here, none). Report the sha in head_sha and both readings in detail.
⚠️ NEVER \`git reset --hard\`, \`git checkout .\`, \`git restore .\`, \`git clean\`, or a force-push. Uncommitted work is parked, never discarded: the ONE thing this step must not do is destroy work it was sent to protect. If you cannot complete the repair, saying so in state:"unrepairable" is the right answer and costs nothing.
Return the structured result with repo=${repoId}.` + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
    { agentType: 'general-purpose', model: 'sonnet', phase: phaseName, label: `base-reconcile:${ticket}:${repoId}`, schema: BASE_GATE_SCHEMA },
  )
}

// ──────────────────────────────────────────────────────────────────────────
// A DECLARED FALSE RED IS SCREENED ONCE, NOT RETRIED UNTIL THE BUDGET IS GONE
//
// A repo declares its own `known_false_reds` because they are facts about ONE repo's harness — the
// environment failures it produces that look like a real red. Every prose surface in this framework
// already tells a reader what to do with them: rule one out before calling a failure real, and
// re-run the scoped check in isolation against the base branch. The reviewers' brief says it, the
// suite-repair brief says it, the continuation brief says it. The RETRY LOOP ITSELF never did it.
//
// So a round that hit a declared flake was continued the only way the loop knows: from scratch, by
// an agent with no memory of the last attempt, which rebuilt the whole project, re-ran the same
// check, and crashed the same way. A measured ticket did that six times back to back — 61 minutes,
// one test, one declared entry that said in advance the suite shares a database and an unrelated
// test can fail on ordering. Every pass was charged to `build.max_continuation_passes`, so a budget
// ADR-0032 sized for FEATURE WORK went entirely on a failure the repo had already written down.
//
// The screen is therefore its own step, before the failure is charged: its own agent, its own
// label, its own `tick`, exactly like the base reconcile above. Four outcomes:
//
//   no-match     — no declared entry plausibly covers this failure, or the round reported no failing
//                  check at all. Nothing runs, nothing changes. A repo that declares none never
//                  reaches this step, so the common path costs exactly what it costs today.
//   pre-existing — it was re-run on the base, in isolation, and failed there TOO. The base does not
//                  carry this ticket's change, so the failure is not this round's: it is recorded on
//                  its own row, and it does not buy itself continuation passes.
//   genuine      — it PASSES on the base. Today's behaviour, unchanged: charge the budget, continue.
//   inconclusive — it could not be run on the base at all. Also today's behaviour, unchanged — a
//                  screen with no receipt has not screened anything, and the safe direction is to
//                  charge a red to the round rather than excuse one on a guess.
//
// WHY ONE GREEN ON THE BASE IS ENOUGH TO SAY "genuine". A non-deterministic test can pass on the
// base by luck, so this is not proof. It does not need to be: `genuine` is the DEFAULT the workflow
// already has, and the screen only ever moves a failure OFF the retry budget on positive evidence —
// a failure watched happening on a tree that predates the change.
const FALSE_RED_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repo', 'state', 'sole_obstacle', 'detail'],
  properties: {
    repo: { type: 'string' },
    state: { enum: ['no-match', 'pre-existing', 'genuine', 'inconclusive'] },
    failing: { type: 'array', items: { type: 'string' } },  // the check(s) screened, as the runner names them
    matched: { type: ['string', 'null'] },                  // the declared entry it matched, quoted
    base_command: { type: ['string', 'null'] },             // what was run on the base — half the receipt
    base_exit_code: { type: ['integer', 'null'] },          // and the other half
    sole_obstacle: { type: 'boolean' },                     // true ⇒ the round owes nothing beyond this failure
    detail: { type: 'string' },
  },
}
// The cheapest possible filter, and it runs before the agent does: a repo with nothing declared gets
// no screen, and neither does a round that never mentions a check that ran. A false positive here
// costs one scoped probe; a false negative costs what it costs today, which is the thing being fixed.
const reportsAFailedCheck = (h) =>
  (h.commands_run || []).some((c) => c && Number(c.exit_code) !== 0)
  || /\b(test|spec|suite|assert\w*|panic\w*|abort\w*|sigabrt|segfault|flak\w+)\b/i.test(`${h.remaining || ''} ${h.root_cause || ''} ${h.summary || ''}`)
// Returns the verdict, or null when the screen did not converge. A null neither halts nor excuses:
// without this step the round was charged for the failure, so that is where a non-convergence leaves it.
// `labelSuffix` only distinguishes the two call sites in the journal — the build round's continuation
// loop and the review round's suite gate can both screen the same repo in one run, and two agents
// sharing a label would leave one `tick` row and one prompt for two different questions.
async function screenKnownFalseRed(repoId, rp, desc, dev, phaseName, labelSuffix = '') {
  const absR = absOf(repoId)
  const wt = `/tmp/${ticket}-${repoId}-false-red-screen`
  return await safeAgent(
    `${tag(repoId, 'general-purpose', 'false-red-screen')} ONE QUESTION, and nothing else: does the check that failed this round fail on the BASE BRANCH too? Write no feature code, fix nothing, run no formatter, touch no PR/MR and no tracker. You may READ the round's checkout at ${absR}; you may never write to it, switch its branch, stash it, or clean it. ${shellClauseFor(repoId)}
THIS REPO DECLARES ITS OWN KNOWN FALSE REDS — the environment failures its harness produces that look like a real red: ${desc.knownFalseReds}
WHAT THE ROUND REPORTED: ${String(dev.remaining || dev.summary || '(nothing)').slice(0, 700)}${dev.root_cause ? ` · the cause it measured: ${String(dev.root_cause).slice(0, 300)}` : ''}${(dev.commands_run || []).length ? ` · what it ran: ${JSON.stringify(dev.commands_run).slice(0, 500)}` : ''}
1. NAME THE FAILING CHECK. From the report above, identify the specific test(s) that failed, as this repo's own runner names them, and list them in \`failing\`. If the round reported no failing check at all — it stopped for some other reason — return state:"no-match", run nothing, and say so: this step is about a red, not about unfinished work.
2. MATCH IT, OR DO NOT. Hold that failure against the declared entries above: the same suite, the same shared fixture or database, the same failure class (an order-dependent test, a process abort or crash rather than an assertion, a port or lock already taken). If nothing plausibly matches, return state:"no-match" with your reasoning in detail and RUN NOTHING — a declared list is the whole benefit of the doubt on offer, and a failure outside it is judged on its own evidence.
3. ONLY ON A MATCH, RE-RUN IT ON THE BASE, IN ISOLATION. \`git -C ${absR} fetch origin\`, then \`git -C ${absR} worktree add --detach ${wt} origin/${rp.base_branch}\` — a throwaway checkout of the base, so this round's branch, its build output and anything uncommitted on it are never touched.${baseIsSettled(rp.base_branch)} In ${wt}, run ONLY the failing test(s), scoped: this repo's own harness with whatever filter it takes (\`scripts/dev.sh test <name>\`), else the runner underneath it filtered to those tests. NOT the whole suite — the whole suite is what already cost this round its time.
4. REPORT THE RECEIPT, THEN CLEAN UP. \`base_command\` gets the command verbatim and \`base_exit_code\` its exit code; then \`git -C ${absR} worktree remove --force ${wt}\` whatever the outcome was. Then decide:
   • it FAILED or crashed on the base as well ⇒ state:"pre-existing" — quote in detail how it failed there. The base predates every line this ticket wrote, so the failure is not this round's to fix.
   • it PASSED on the base ⇒ state:"genuine". A pass is not proof against a flaky test and does not need to be: "genuine" is this workflow's default, so it changes nothing.
   • you could not run it there at all ⇒ state:"inconclusive", naming in detail what you tried and what refused. NEVER guess an exit code and never return "pre-existing" without having watched the failure happen on the base: an unscreened red charged to the round is today's behaviour, and it is the safe direction to fail in.
5. SET \`sole_obstacle\`: true ONLY when the round's report names nothing it still owes beyond this one failure; false when other work remains. It decides whether the round is continued for the rest of its work or ends here, so read the report — do not assume either way.
Return the structured result with repo=${repoId}.` + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
    { agentType: 'general-purpose', model: 'sonnet', phase: phaseName, label: `false-red-screen:${ticket}:${repoId}${labelSuffix}`, schema: FALSE_RED_SCHEMA },
  )
}

async function runRepoPipeline(rp, desc, branchKind) {
  const R = rp.repo
  const absR = absOf(R)
  const inRepo = shellClauseFor(R)

  // ──────────────────────────────────────────────────────────────────────────
  // THE LOOP DOES NOT HALT ON A FINDING (docs/adr/0027)
  //
  // Every condition that used to stop this repo mid-review — a fix-caused regression, a stall, a
  // cross-repo escalation that did not settle, a suite that could not run, a mis-targeted PR/MR —
  // is now a MUST-FIX with its own attempt budget. When a budget runs out the condition is
  // RECORDED here and the loop carries on with everything else, so one immovable finding no longer
  // costs a whole invocation's worth of other work.
  //
  // What this must NEVER become is a pass. `blocking` is the load-bearing half: a repo carrying any
  // entry cannot return 'ready', so nothing is approved and nothing merges. "Does not halt" means
  // the loop keeps working — it does not mean an un-run gate reads as green
  // (docs/agents/loadtest-gate.md: no receipt ⇒ not run, never fail open).
  //
  // MAX_REVIEW_ROUNDS is the one terminal bound left. A repo that reaches it ends
  // 'review-unresolved' carrying this list.
  const blocking = []
  const record = (kind, detail, human) => {
    if (blocking.some((b) => b.kind === kind && b.detail === detail)) return
    blocking.push({ kind, detail, human_action: human || null })
    log(`⚠️ [${R}] BLOCKING RECORDED (${kind}) — ${String(detail).slice(0, 200)}. The loop continues on this repo's other findings; it cannot reach 'ready'.`)
  }
  // Per-condition attempt budgets. Deliberately separate from the round budget: a repo that meets
  // a regression AND a stall AND an escalation would otherwise spend its rounds on whichever came
  // first and never reach the others.
  const attempts = {}
  const spend = (k) => (attempts[k] = (attempts[k] || 0) + 1)
  const left = (k, cap) => cap - (attempts[k] || 0)
  // Must-fix directives appended to the NEXT developer pass. This is how a former halt reaches the
  // developer as work rather than as a stop.
  let extraMustFix = []

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
  // The pins Kickoff actually READ off .gitmodules come first; a bare `depends_on` is still honored
  // so a repo whose planner did not answer keeps the old, conservative behaviour.
  const declaredPins = (rp.submodule_pins || []).filter((s) => s?.repo && s?.path && REPOS[s.repo])
  const pinUpstreams = [...new Set([...declaredPins.map((s) => s.repo), ...(rp.depends_on || []).filter((u) => REPOS[u])])]
  const pinTargets = pinUpstreams.map((u) => {
    // Built EARLIER IN THIS RUN: a declared pin puts its upstream in an earlier build wave, and that
    // upstream's last act was to push. So the target is a commit that EXISTS ON THE REMOTE and is
    // not merged — which is all a submodule pointer has ever needed, and the difference between
    // this repo starting now and starting a whole invocation later.
    // An earlier wave having RUN is not the same as it having pushed anything. A `build-unresolved`
    // upstream handed back no complete state, so its branch may hold nothing or may never have
    // reached the remote; an `already-satisfied` one has no branch at all. Pinning to either would
    // aim the pointer at a commit that does not exist — worse than the conservative target, because
    // it fails deep inside the downstream's harness instead of here. Both fall back to the merged
    // base, which is exactly what this repo would have got before any of this.
    const upstream = repoResults[u]
    const upstreamPushed = upstream && upstream.status !== 'build-unresolved' && upstream.status !== 'already-satisfied'
    const pushedBranch = upstreamPushed ? upstream.plan?.work_branch : null
    return {
      repo: u,
      path: declaredPins.find((s) => s.repo === u)?.path || REPOS[u].path,
      target: pushedBranch
        ? `origin/${pushedBranch} — ${u}'s branch for THIS ticket, built and PUSHED earlier in this run. It is not merged, and does not need to be: fetch it (\`git -C <path> fetch origin\`) and pin to that tip. The workflow re-points this pin at the merged sha as a ship step before anything lands, so an unmerged pin here is correct, not a loose end`
        : doneAt(u, 'built')
          ? `the tip of ${rowAt(u, 'built')?.work_branch || `${branchKind}/${ticket}`} on origin (run state: already built for this ticket)`
          : `origin/${REPOS[u].base[branchKind]} (not built this run — its merged base is as far as you may go)`,
    }
  })
  // The other end of the same edge: if somebody pins THIS repo, its commits have to reach the remote
  // or the wave ordering bought nothing.
  const pinnedBy = plans.filter((p) => (p.submodule_pins || []).some((s) => s?.repo === R)).map((p) => p.repo)
  const pushForPinClause = pinnedBy.length
    ? ` PUSH BEFORE YOU HAND OFF — ${pinnedBy.join(', ')} vendor${pinnedBy.length === 1 ? 's' : ''} this repo as a git submodule and will pin to whatever commit of yours is on the remote. They are being built AFTER you for exactly that reason, so your last act is \`git -C ${absR} push -u origin ${rp.work_branch}\`. An unpushed commit is invisible to them, and a wave spent waiting on nothing is the round this ordering exists to save.`
    : ''
  const submodulePinClause = pinTargets.length
    ? ` SUBMODULE PIN (check before you run the suite): this repo declares ${pinTargets.map((p) => `${p.repo} (path "${p.path}")`).join(', ')} as an upstream for ${ticket}. ⚠️ If your harness builds its schema, migrations or fixtures from a vendored checkout of one of those, a stale pin makes your suite prove nothing. For EACH of them: (1) detect, do not guess — \`git -C ${absR} config -f .gitmodules --get-regexp path\`. If .gitmodules does not declare that path, do NOTHING and say so; that is the normal answer. (2) If it IS declared, bring the pin forward to: ${pinTargets.map((p) => `${p.repo} (at "${p.path}") → ${p.target}`).join('; ')}. Commit the pointer move on its own, every command anchored (a standalone \`cd\` does not carry into your next call): \`git -C ${absR}/<path> fetch origin && git -C ${absR}/<path> checkout <the sha> && git -C ${absR} add <path> && git -C ${absR} commit -m "chore(<path>): bump submodule pin for ${ticket}"\`. (3) NEVER edit files INSIDE the submodule checkout — a guard blocks it, and that repo's primary clone is at the workspace root. If the pin is already at or ahead of the target, leave it and say so.`
    : ''
  const buildPrompt = desc.kind === 'test-suite'
    ? `${tag(R, desc.build, 'build', 0)} Build the test-suite automation for ${ticket} in the ${R} repo from the plan at ${rp.plan_path} (behaviour reference: agent_logs/${ticket}-testcases.md). ${inRepo}
1. BRANCH ONLY — create it with EXPLICIT git, never a skill that resolves its own base: \`git -C ${absR} fetch origin && git -C ${absR} switch -c ${rp.work_branch} origin/${rp.base_branch}\`. The base is ${rp.base_branch} because THIS RUN says so — do not re-derive it from \`origin/HEAD\`, \`default-branch.sh\`, or the repo's usual default.${baseIsSettled(rp.base_branch)} PROVE it before step 2: \`git -C ${absR} rev-parse HEAD\` == \`git -C ${absR} rev-parse origin/${rp.base_branch}\` and \`git -C ${absR} log --oneline origin/${rp.base_branch}..HEAD\` prints nothing; report both. If the branch already exists on the wrong base, recreate it. Do NOT finish/merge (the workflow opens + merges the PR later, in order).
2. IMPLEMENT — strictly POM via /coding-automate ${ticket}, in THIS repo's own layout and idiom (read its CLAUDE.md + .claude/rules/ — never assume a directory or a framework). Each test's title MUST open with its TC id from agent_logs/${ticket}-testcases.md, and each scenario MUST end by capturing a screenshot: the runner names artifacts after the test title, so that id is what ties the evidence to the results row. Commit each slice conventionally (Refs ${ticket}).
3. NO SUITE EXECUTION AT BUILD — this phase AUTHORS the automation; it does not run it. Do NOT run \`scripts/dev.sh test\` (scoped or full), do not stand any app repo up, and do not chase a red: the suite runs ONCE, in the Test-suite phase, against the REVIEWED candidate. A run here exercises a half-built candidate and goes red for reasons that are not automation, which is exactly the cost this split removes.
4. STATIC CHECK instead — run this repo's own static/compile step and get it clean: \`scripts/dev.sh analyze\` (plus \`scripts/dev.sh gen\` when this repo's layout needs a codegen/format pass). A spec that does not compile, an unresolved import, an unused Page Object — those are caught here, cheaply. Never a raw toolchain, never \`npm test\`.
5. WIRING PROOF before handoff — the specs you added must be REACHABLE by the runner the gate will invoke. Show how you know: the runner config/spec-glob you edited, and the runner's own list/dry-run mode if this repo has one. A spec the runner cannot see makes the gate green while proving nothing. "${desc.green}" is the GATE's bar, not this phase's: it is judged in the Test-suite phase against the reviewed candidate. Your bar here is: specs authored per the plan, static check clean, runner wiring proven.${submodulePinClause}
6. PUSH — ${pinnedBy.length ? 'REQUIRED: ' : 'not needed here (nobody vendors this repo as a submodule); the PR/MR step pushes for you. '}${pushForPinClause || ''}
7. RETURN CONTRACT (mandatory) — /handoff, then END by calling StructuredOutput with the DEV_SCHEMA result: work_branch=${rp.work_branch}, a one-line summary of what you authored, commit count, status="complete" when the specs are authored, the static check is clean and the wiring is proven (NO suite was run — that is by design, not an omission) else "partial"/"blocked" with what's left in "remaining", and in "fixed" the spec/Page Object files you touched. Do NOT move the ticket status — the workflow does that. Never withhold the structured result to investigate further.`
    : `${tag(R, desc.build, 'build', 0)} Implement ${ticket} in the ${R} repo on branch ${rp.work_branch} from the plan at ${rp.plan_path}. ${inRepo} THIS REPO'S BASE IS ${rp.base_branch}, resolved once by this run from its own arguments.${baseIsSettled(rp.base_branch)} Treat this repo's docs/adr/* and CONTEXT.md as AUTHORITATIVE context the plan defers to: read them FIRST, and where the plan text and an ADR disagree, the ADR wins. ${rp.reused ? `BRANCH FIRST — this repo's Kickoff was SKIPPED this invocation (its plan was reused from run state), so nothing has checked out your branch yet: run \`git -C ${absR} fetch origin\` then \`git -C ${absR} switch ${rp.work_branch}\` before anything else, and report the sha \`git -C ${absR} rev-parse HEAD\` prints. If that branch does not exist, create it from the run's base — \`git -C ${absR} switch -c ${rp.work_branch} origin/${rp.base_branch}\` — and say so in your summary.${baseIsSettled(rp.base_branch)} ` : ''}If ${rp.work_branch} ALREADY exists with prior work (an approved re-run over an existing branch), RECONCILE existing code that contradicts the updated ADRs/plan — reshape it to the canonical schema/shape (e.g. a stale snake_case seed → the canonical kebab/Section schema) rather than only appending new code on top of the old shape. Run /coding-feature (it loads this repo's CLAUDE.md + coding_standards AND the workspace coding-style — storytelling code, NO body comments — "read before your first edit", and its Step 4 drives the build test-first through /tdd's red-green-refactor loop) and /karpathy-guidelines, committing each slice conventionally (Refs ${ticket}), keep ${desc.green}. When the Definition of Done is met, /handoff. Do NOT move the ticket status — the workflow owns it.${outOfReachBrief}${submodulePinClause}${pushForPinClause}${sectionRecord('dev', R, 'fill exactly three sub-blocks. `#### Status`: ONE line naming the work branch and the PR/MR, then — only if you are handing back a `deferred` criterion — one line per criterion naming it and its owner, because the ticket should record what this run did not deliver and no separate ticket is filed for it. If instead this repo needed NO change (`already-satisfied`), that ONE line says so and there is no branch or PR/MR to name: follow it with one line per criterion giving the commit and file:line that already meets it. Nothing else: not what you built, not which tests you ran, not a commit list. `#### Regression`: the regression scope, as a bullet list — which EXISTING features QA must re-test and one line on why each (shared components/modules, touched shared code, repository/API-contract or migration changes, altered routing or state). You changed the code, so you are the only one who knows this — QA does NOT guess it, and this block is the SOLE source of its regression scope. If genuinely nothing existing is touched, say so in one line with the reason. `#### History`: append ONE line to agent_logs/' + ticket + '-dev-history.tsv (`run r' + RUN_SEQ + '<TAB><date -u +%Y-%m-%dT%H:%MZ><TAB><what changed this round, one clause>`, real TAB characters), then render the WHOLE file as a small Markdown table. The two blocks above are always rewritten to CURRENT truth and the ledger is the only place earlier rounds survive — never copy old lines out of the previous body by hand, which is how a record ends up contradicting its own runs.')}`
  // RESUME: a 'built' row whose recorded head still matches the live branch means this repo's
  // build already landed on an earlier invocation — skip re-paying for it (docs/adr/0018).
  // C2 + ADR-0025 — a `built` row is proof only while BOTH its inputs still hold: the branch head
  // it recorded, and the PLAN it was built from. The head alone was the original rule, and it
  // deadlocks: a fresh planning pass that correctly re-diagnoses the problem does not move the
  // head — nobody has built the new plan yet — so `built` stayed non-degraded, Build was skipped
  // as "already done", and the corrected plan was never built. Twice, on one ticket, each time
  // needing a human to delete checkpoint files that no document mentioned. plan_sha closes it.
  const builtRowRaw = rowAt(R, 'built')
  const planStale = !!(builtRowRaw && rp.plan_sha && builtRowRaw.plan_sha && builtRowRaw.plan_sha !== rp.plan_sha)
  if (planStale) log(`[${R}] build row IGNORED — it was built from plan ${builtRowRaw.plan_sha}, and the plan is now ${rp.plan_sha}. A re-plan has superseded that build, so this repo builds again.`)
  if (planStale) degradeRows(R, `it was built from a plan that has since been re-written (${builtRowRaw.plan_sha} → ${rp.plan_sha})`, ['pr_open', 'reviewed', 'gate_review', 'gate_guard', 'gate_perf'])
  const builtRow = planStale ? null : builtRowRaw
  // RECONCILE THE BRANCH BASE BEFORE THE ROUND, NOT INSIDE IT (see reconcileBranchBase). Skipped
  // when the build itself is skipped: a `built` row whose head still matches was already reconciled
  // by the invocation that wrote it, and re-probing it would spend an agent to learn nothing.
  let baseRepair = null
  let priorWork = 0
  if (!builtRow) {
    const bs = await reconcileBranchBase(R, rp, 'Build')
    tick(`${R}:base-reconcile`)
    if (!bs) {
      // Never halt on a probe that flaked: without this step the round simply carried the drift, so
      // a non-converging probe leaves the repo exactly where it stood before this check existed.
      log(`⚠️ [${R}] the branch-base reconcile did not converge — continuing to the build UNCHECKED, as this run would have before. Check by hand: \`git -C ${absR} log --oneline origin/${rp.base_branch}..${rp.work_branch}\`.`)
    } else if (bs.state === 'unrepairable') {
      const why = `${R}'s branch ${rp.work_branch} carries ${bs.foreign_commits} commit(s) that are not ${ticket}'s AND ${bs.ticket_commits} that are, so it cannot be re-pointed at ${rp.base_branch} without deleting this ticket's own work. ${bs.detail}`
      record('branch-base', why, bs.rebase_command ? `rebase it yourself, then re-run: ${bs.rebase_command}` : `re-cut ${rp.work_branch} from origin/${rp.base_branch}, replay ${ticket}'s commits onto it, then re-run`)
      log(`⛔ [${R}] BRANCH BASE UNREPAIRABLE — ${why} Nothing is built on it: \`git diff ${rp.base_branch}...${rp.work_branch}\` would show ${bs.foreign_commits} foreign commit(s), so every reviewer and every gate downstream would be judging the wrong comparison (docs/adr/0025).`)
      return { repo: R, status: 'target-branch-halt', plan: rp, blocking, base_repair: bs, handoff: { status: 'blocked', summary: `the work branch does not stand on this run's base (${rp.base_branch})`, remaining: why, decision_needed: 'rebase this ticket\'s commits onto the run\'s base by hand, or change the run\'s base, then re-run' } }
    } else if (bs.state === 'repaired') {
      baseRepair = bs
      log(`🔧 [${R}] BRANCH BASE REPAIRED as its own accounted step — ${rp.work_branch} carried ${bs.foreign_commits} commit(s) that were not ${ticket}'s and has been re-pointed at origin/${rp.base_branch}${bs.parked_at ? ` (uncommitted work parked at ${bs.parked_at} and restored)` : ''}. ${bs.detail} The build round below therefore starts on the right base and spends its WHOLE slice budget on ${ticket}'s own work — it is not one of the ${BUILD.maxContinuationPasses} continuation passes.`)
    } else if (bs.branch_exists && bs.ticket_commits) {
      log(`[${R}] branch base OK — ${rp.work_branch} stands on ${rp.base_branch} and already carries ${bs.ticket_commits} of ${ticket}'s own commit(s).`)
    } else {
      log(`[${R}] branch base OK — ${bs.branch_exists ? `${rp.work_branch} stands on ${rp.base_branch} with nothing on top` : `${rp.work_branch} does not exist yet; the build cuts it from ${rp.base_branch}`}.`)
    }
    // The reconcile has just COUNTED this ticket's own commits on the branch, and every caller threw
    // that number away. It is the one fact a relaunched build needs: no `built` row means no build
    // ever checkpointed, so commits sitting there are an attempt that ended before it could hand off.
    if (bs && (bs.state === 'ok' || bs.state === 'repaired') && bs.ticket_commits > 0) priorWork = bs.ticket_commits
  }
  // The repair is REPORTED to the round it protected, so the agent neither redoes the surgery nor
  // mistakes a history it did not write for something it has to reconcile.
  const baseRepairClause = baseRepair
    ? ` ⚠️ THE BRANCH BASE WAS ALREADY REPAIRED FOR YOU, before this round and as its own step: ${rp.work_branch} carried ${baseRepair.foreign_commits} commit(s) that were not ${ticket}'s, and it has been re-pointed at origin/${rp.base_branch}${baseRepair.parked_at ? `, with the uncommitted work parked at ${baseRepair.parked_at} and restored` : ''}. That is why the branch's history is shorter than you may remember it. Do NOT redo that surgery, do not re-point anything, and do not spend a slice on it — it is done, and it was not paid for out of your budget. Say in your handoff summary that this round began on a repaired base, so the next reader knows why the history moved.`
    : ''
  // An attempt that is ended from outside never writes a run-state row, so the relaunch that follows
  // is handed the SAME brief into an empty context and re-derives everything — including work already
  // sitting on the branch. Naming it turns a rebuild into a continuation, and stops the agent reading
  // its own predecessor's commits as a stale prior run to reshape.
  const priorWorkClause = priorWork
    ? ` ⚠️ WORK IS ALREADY ON THIS BRANCH — ${rp.work_branch} carries ${priorWork} commit(s) of ${ticket}'s own, and no run state records a finished build, so they are an earlier attempt that ended before it could hand off. READ THEM FIRST: \`git -C ${absR} log --oneline ${rp.base_branch}..${rp.work_branch}\`, then \`git -C ${absR} show --stat\` on each. CONTINUE from where they stop: do NOT rebuild what they already implement, and do NOT treat them as a stale prior run to reshape — they were built from the plan you are holding. Name in your handoff which of them you inherited and which slices you added.`
    : ''
  let dev = builtRow
    ? { work_branch: builtRow.work_branch || rp.work_branch, summary: `resumed from run state (head ${String(builtRow.head_sha).slice(0, 8)} unchanged)`, status: 'complete', fixed: [] }
    : await safeAgent(
        buildPrompt + baseRepairClause + priorWorkClause + BUILD_DISCIPLINE + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + FIGMA_DIRECTIVE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE
          + stateWrite(R, 'built', `,"plan_sha":"<run 'shasum -a 256 ${rp.plan_path} | cut -c1-16' and put its output here — the fingerprint of the plan you BUILT FROM, so a later re-plan can tell this build is stale>"`) + ` If your handoff status is "deferred" or "already-satisfied", write that RUN-STATE file with "status":"in-progress" instead of "done" — neither is checkpointed as built, because what makes the claim (deferred[]/met_acceptance[], or satisfied_by[]) does not fit in a state row and must be re-derived and re-audited by the next invocation.`,
        { agentType: desc.build, phase: 'Build', label: `build:${ticket}:${R}`, schema: DEV_SCHEMA },
      )
  if (builtRow) log(`[${R}] build SKIPPED — run state says built at ${String(builtRow.head_sha).slice(0, 8)} and the branch has not moved.`)
  // CONVERGENCE RETRY — a null build means the agent never produced a structured
  // handoff (it ran away triaging a red / reformatting instead of returning). Don't abort the
  // wave: retry ONCE with a bounded "stop working, hand off NOW" continuation, bumped to opus +
  // high so the wrap-up is reliable. It must emit DEV_SCHEMA with whatever state it reached
  // (status partial/blocked is fine) — no new work.
  const buildCutOff = !dev && CUT_OFF_RE.test(reasonFor(`build:${ticket}:${R}`))
  if (!dev) {
    if (buildCutOff) log(`⚠️ [${R}] build was ENDED FROM OUTSIDE mid-work, not by anything it did — ${reasonFor(`build:${ticket}:${R}`).slice(-200)}`)
    log(`⚠️ [${R}] build returned no structured handoff — retrying once (bounded: emit handoff now, no more work).`)
    dev = await safeAgent(
      `${tag(R, desc.build, 'build', 1)} Your build of ${ticket} in the ${R} repo (branch ${rp.work_branch}, plan ${rp.plan_path}) did NOT return a structured handoff last time — ${buildCutOff ? `your attempt was ENDED FROM OUTSIDE mid-work (the engine reported: ${reasonFor(`build:${ticket}:${R}`).slice(-300)}), not by anything you did wrong. Do not go looking for a mistake you made and do not re-audit the plan; assume only that whatever you had not committed is gone.` : 'you likely ran away triaging a red or reformatting.'} ${inRepo} STOP doing work now: run NO more tests, fixes, or formatters. Two things only, in ONE step. FIRST, leave no dirty tree: \`git -C ${absR} status --porcelain\` — if anything is uncommitted, PARK it (a \`wip(<scope>): … Refs ${ticket}\` commit on ${rp.work_branch}, or \`git -C ${absR} stash push -u -m "${ticket} …"\`) and record where it went; NEVER \`git checkout .\`/\`git restore .\`/\`git reset --hard\`. SECOND, END by calling StructuredOutput with the DEV_SCHEMA result — work_branch=${rp.work_branch}, a one-line summary, commit count, the files you touched in "fixed", status="complete" ONLY if the Definition of Done is genuinely met else "partial" (slices landed, work remains) or "blocked" (cannot proceed). For partial/blocked also fill "remaining" (what is left and why), "root_cause" (the MEASURED cause at file:line — never "unknown"), "commands_run" (each command you ran + its exit code), "decision_needed" if a human must settle a fork, and "parked_at" (the WIP commit sha or stash ref). Returning this handoff IS the task — emit it immediately.`,
      { agentType: desc.build, model: 'opus', effort: 'high', phase: 'Build', label: `build-handoff:${ticket}:${R}`, schema: DEV_SCHEMA },
    )
  }
  // BOTH ATTEMPTS GONE — ADR-0027 §what a budget cannot close is RECORDED. This return used to
  // carry no `blocking` at all, so a repo whose build agent never handed off reached
  // `blockingByRepo` empty: no banner, no "needs a person" section in the summary, no detail in the
  // incomplete-run DM, and nothing in the blocked run-state row that outlives the invocation. The
  // status word `build-unresolved` was the whole account, and it does not say WHY — so a person
  // read it as "it ran out of time", re-ran the same repo, and paid two more full-context attempts
  // for the same external cut-off. The reason is the only thing that changes what they should do,
  // so it is recorded verbatim rather than paraphrased.
  if (!dev) {
    const why = reasonFor(`build-handoff:${ticket}:${R}`) || reasonFor(`build:${ticket}:${R}`)
    const cutOff = buildCutOff || CUT_OFF_RE.test(why)
    record('build-no-handoff',
      cutOff
        ? `${R}'s build agent was ENDED FROM OUTSIDE mid-work on both attempts — it never reached a structured handoff, and nothing it had not already committed survives. The engine's own words: ${why || '(it reported no reason)'}. Each attempt is a fresh full-context run of the same brief, so a blind re-run pays the same price again for the same cut-off.`
        : `${R}'s build agent returned no structured handoff on either attempt, and the engine did not report an external interruption: ${why || '(it reported no reason)'}. Nothing is known about what landed.`,
      cutOff
        ? `re-run this repo alone (\`/dev-cycle ${ticket}\` resumes from run state, so nothing already checkpointed is re-paid) and give the attempt more room — a longer per-attempt ceiling, or a smaller plan slice. First check what survived: \`git -C ${desc.path} log --oneline ${rp.base_branch}..${rp.work_branch}\`. Do NOT re-plan; the plan was never the problem.`
        : `read the branch before re-running, in ${desc.path}: \`git log --oneline ${rp.base_branch}..${rp.work_branch}\` for what was committed, \`git status --porcelain\` for work left uncommitted, \`git stash list\` for anything parked — then decide whether to keep it and continue or reset and build again from the plan.`)
    log(`⚠️ [${R}] build did not converge to a structured handoff even after the bounded retry — left mid-flight; downstream skipped.`)
    return { repo: R, status: 'build-unresolved', plan: rp, blocking, handoff: { status: 'blocked', summary: `build agent never returned a structured handoff (2 attempts)${cutOff ? ', both ENDED FROM OUTSIDE mid-work' : ''}`, root_cause: why || null, remaining: `no handoff was produced, so nothing is known about what landed. Recover the state from the branch itself, in ${desc.path}: \`git log --oneline ${rp.base_branch}..${rp.work_branch}\` for what was committed, \`git status --porcelain\` for work left uncommitted, and \`git stash list\` for anything parked.`, decision_needed: cutOff ? 'whether to re-run this repo with more room per attempt, or to cut the plan into smaller slices so a single attempt can finish one' : 'whether to keep whatever is on the work branch and continue, or reset it and re-run the build from the plan' } }
  }
  // DEFERRED — the repo's own work is green and what remains belongs to another owner. The run
  // continues (docs/adr/0011), but the claim is audited first, because `deferred` is the one status
  // an agent could reach for to escape work it actually owns:
  //   1. structurally — deferred[] entries with an owner AND observed evidence, or it is not a claim;
  //   2. against the SETTLED list — a criterion scope already declared out of reach needs no further
  //      adjudication, so a run pays for a verifier only on a deferral nobody foresaw;
  //   3. by a verifier — one agent reads the diff, the branch state and the evidence, and downgrades
  //      an unevidenced deferral to `partial`, which stops the repo exactly as before.
  // ALREADY-SATISFIED — this repo's acceptance criteria are met by code that shipped before this
  // ticket, so the honest diff is empty and there is nothing here to review or merge.
  //
  // The run had no terminal state for this, and the gap cost a whole repo on a measured run. Its
  // build agent verified, with file:line citations, that every ticket-visible requirement was
  // already live in generic flag-driven code; it declined to manufacture a no-op commit and said so.
  // The claim was rejected on ONE mechanical rule — "the branch has zero commits" — applied on top
  // of evidence the same verifier had just confirmed true. Commit count is a proxy for "was work
  // done", not for "is the criterion met", and those two diverge in exactly this case. Worse, this
  // case is the DESIGNED outcome of a registry/flag architecture: a new provider needing no UI
  // change is the goal, not an edge.
  //
  // So the empty branch stops being the test and the CITATIONS become it — but the bar goes UP, not
  // down, because "it's all already done" is the cheapest sentence an agent can write to avoid work:
  //   1. structurally — every entry needs a commit, a file:line and the source quoted;
  //   2. by coverage — the entries must cover EVERY criterion this repo owns, or the uncited ones
  //      are simply work nobody looked at;
  //   3. by a verifier that re-opens each citation and greps for the mechanism itself, and whose
  //      one forbidden move is rejecting on commit count.
  // Anything short of all three downgrades to `partial`, which stops the repo exactly as before.
  if (dev.status === 'already-satisfied') {
    const cited = (dev.satisfied_by || []).filter((s) =>
      s?.criterion && /^[0-9a-f]{7,40}$/i.test((s.commit || '').trim()) && (s.path_line || '').includes(':') && (s.quote || '').trim().length >= 20)
    if (!cited.length) {
      log(`⚠️ [${R}] handoff claimed status=already-satisfied but carried no usable citation — treating it as PARTIAL (the repo stops). Every criterion needs a commit, a file:line and the source quoted.`)
      dev.status = 'partial'
      dev.remaining = `${dev.remaining || ''} [workflow: an 'already-satisfied' handoff was downgraded to 'partial' because ${(dev.satisfied_by || []).length ? 'its citations were unusable (a commit sha, a file:line and the quoted source are all required)' : 'it cited nothing'}.]`.trim()
    } else {
      const verdict = await safeAgent(
        `${tag(R, 'general-purpose', 'verify-satisfied')} ADJUDICATE an "already satisfied" claim for ${ticket} in the ${R} repo — read-only, no edits, no commits, no branch, no tracker or PR writes. ${inRepo}
The build agent reports that this repo needs NO CHANGE for ${ticket}: the behaviour the ticket asks of it shipped under EARLIER work, so the correct diff is empty. Your job is to decide whether that is true of the CODE — and whether it is true of ALL of it.
THE CITATIONS: ${cited.map((s, i) => `(${i + 1}) criterion "${s.criterion}" — satisfied by commit ${s.commit} at ${s.path_line} — quoted source: ${JSON.stringify(s.quote).slice(0, 400)}`).join(' ')}
CHECK, in this order, and quote what you find:
1. EVERY CITATION IS REAL. For each: \`git -C ${absR} show --stat --oneline <commit> | head\` proves the commit exists and is an ancestor of ${rp.base_branch} (\`git -C ${absR} merge-base --is-ancestor <commit> origin/${rp.base_branch}\`), and the file at the cited line CONTAINS the quoted source today. A citation you cannot open, a sha that is not on the base, or a quote that is not there fails the claim.
2. THE CITED CODE ACTUALLY SATISFIES THE CRITERION. Read around the line, not just at it. Code that merely mentions the right words is not code that meets the criterion — follow it far enough to see the behaviour the criterion describes, and say what you followed.
3. THE LIST IS COMPLETE. Read the ticket (\`scripts/tracker/get-ticket-details.sh ${ticket}\`) and the plan at ${rp.plan_path}, and list every acceptance criterion assigned to THIS repo. Any criterion with no citation is work nobody has checked — the claim fails. This is the check that separates "the design already covers it" from "I would rather not do this".
4. NOTHING TICKET-SPECIFIC IS MISSING. The claim rests on existing code being general enough to cover this ticket's new case. Grep this repo for the ticket's own distinguishing identifiers (the new provider/flag/entity name the ticket introduces). If they appear nowhere AND the generic path genuinely covers the case, that supports the claim; if the generic path has a gap the new case falls through, the claim is false and you must name the file where the change belongs.
⚠️ DO NOT REJECT ON COMMIT COUNT. An empty branch, no new commits and no PR/MR are the EXPECTED shape of a true claim here — that is the whole reason this status exists, and rejecting on it re-creates the bug this check replaced. Judge the citations, the coverage and the code. A dirty working tree IS still a problem: \`git -C ${absR} status --porcelain\` must be clean, because uncommitted work contradicts "nothing was needed".
Return upheld:true only when all four hold. Otherwise upheld:false naming the criterion that is not in fact satisfied and the file where the work belongs.`,
        { agentType: 'general-purpose', model: 'sonnet', phase: 'Build', label: `verify-satisfied:${ticket}:${R}`, schema: DEFERRAL_VERDICT_SCHEMA },
      )
      if (!verdict || verdict.upheld === false) {
        const why = !verdict ? 'the verifier did not converge, and an unaudited "nothing to do" is not trusted' : (verdict.reason || 'the verifier rejected the citations')
        log(`⚠️ [${R}] ALREADY-SATISFIED REJECTED — ${why}. Treating as PARTIAL: the repo stops rather than skipping work it owns.`)
        dev.status = 'partial'
        dev.remaining = `${dev.remaining || ''} [workflow: an 'already-satisfied' handoff was downgraded to 'partial' — ${why}.]`.trim()
      } else {
        log(`[] ALREADY SATISFIED — verified: ${cited.length} acceptance criterion/criteria are already met by shipped code, so this repo leaves the run with no branch, no PR/MR and nothing to merge.`)
        return { repo: R, status: 'already-satisfied', plan: rp, satisfied_by: cited, met_acceptance: cited.map((s) => `${s.criterion} (already shipped: ${s.commit} ${s.path_line})`), build: { summary: dev.summary } }
      }
    }
  }

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
3. The rest really is done: \`git -C ${absR} status --porcelain\` is clean and \`git -C ${absR} log --oneline origin/${rp.base_branch}..${rp.work_branch}\` lists real commits. A "deferred" claim over an empty or dirty branch is false by definition.
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
  // THE BUILD DOES NOT STOP AT THE FIRST `partial` (docs/adr/0032).
  //
  // ADR-0027 converted every halt in the REVIEW loop into a must-fix with a budget, and named what it
  // deliberately left alone — including "the build returned no structured handoff". But that is the
  // `!dev` case above, which already retries. What actually stopped repos was the line below: a
  // handoff of `partial` — whose own definition is "some slices landed, work OF MY OWN remains" —
  // ended the repo on attempt one. That is the most continuable condition in the whole run being
  // treated as the least, and it is what a measured round-1 audit hit: a repo that finished its prep
  // slice, reported eleven remaining, and was stopped there. The next invocation then paid for Scope,
  // Kickoff and a resume to reach the state this one was already standing in.
  //
  // So it is a budget, like every other condition since ADR-0027: continue from the branch as it
  // stands, up to `build.max_continuation_passes`, and RECORD what the budget cannot close. `blocked`
  // gets the same ladder with a different brief — most "blocked" is a named obstacle worth one honest
  // attempt, and the ones that are not can say so through `cannot_fix`.
  //
  // A pass that does not move the work is not spent again on the same words: the same `remaining` twice
  // escalates the brief exactly as a review stall does, because repeating an identical attempt is not
  // progress and five no-commit rounds were measured ending in the same human call.
  //
  // BUT A FAILURE THE REPO ALREADY DECLARED IS SCREENED BEFORE IT IS CHARGED (see
  // screenKnownFalseRed). This is the one thing a continuation pass cannot discover for itself: each
  // pass is a fresh agent with no memory of the last one, so it re-derives the same wrong conclusion
  // from the same red and pays a full rebuild to do it.
  let falseRed = null
  let falseRedClause = ''
  if (desc.knownFalseReds && dev && (dev.status === 'partial' || dev.status === 'blocked') && reportsAFailedCheck(dev)) {
    falseRed = await screenKnownFalseRed(R, rp, desc, dev, 'Build')
    tick(`${R}:false-red-screen`)
  }
  const screenedFailing = (falseRed?.failing || []).join(', ') || 'the failing check'
  if (falseRed && falseRed.state === 'pre-existing') {
    const why = `${R}'s round hit ${screenedFailing}, which this repo DECLARES as a known false red and which fails on ${rp.base_branch} too: \`${falseRed.base_command || '(no command reported)'}\` exit ${falseRed.base_exit_code ?? '(none reported)'} on a throwaway checkout of the base, which carries none of ${ticket}'s change. ${falseRed.detail}`
    record('known-false-red', why, `stabilise ${screenedFailing} in ${R} — it is already red on ${rp.base_branch}, before this ticket touches anything — then re-run. Nothing in this run can prove the suite green over a check that fails without it.`)
    log(`🟡 [${R}] KNOWN FALSE RED, CONFIRMED ON THE BASE — this is not this round's failure, so it does not buy itself any of the ${BUILD.maxContinuationPasses} continuation passes. ${why}`)
    falseRedClause = ` ⚠️ DO NOT CHASE ${screenedFailing.toUpperCase()} — it was screened BEFORE this pass, as its own step, and it fails on ${rp.base_branch} in an isolated checkout that carries none of ${ticket}'s change (\`${falseRed.base_command || 'see the run log'}\` exit ${falseRed.base_exit_code ?? '?'}). ${falseRed.matched ? `It matches this repo's own declared known false red: ${falseRed.matched}. ` : ''}It is NOT evidence about your diff and it is NOT yours to fix in this ticket. Do not rebuild to reproduce it, do not wipe or recreate a local data directory to chase it, and do not re-run it hoping for a different answer. Work the REST of what you owe, and if there is nothing else, say so and hand off.`
  } else if (falseRed && falseRed.state === 'genuine') {
    log(`[${R}] known-false-red screen: ${screenedFailing} PASSES on ${rp.base_branch} (\`${falseRed.base_command || '(no command reported)'}\` exit ${falseRed.base_exit_code ?? '(none reported)'}), so it is this change's own regression and the round is charged for it exactly as before.`)
    falseRedClause = ` ⚠️ ${screenedFailing} IS YOURS. It was re-run on ${rp.base_branch} in an isolated checkout before this pass — \`${falseRed.base_command || 'see the run log'}\` exit ${falseRed.base_exit_code ?? '?'} — and it PASSES there. So it is not the environment, not a flaky shared fixture, and not this repo's declared false red: it is a regression your diff introduced. Fix the code, not the harness.`
  } else if (falseRed && falseRed.state === 'inconclusive') {
    log(`⚠️ [${R}] known-false-red screen could not run ${screenedFailing} on ${rp.base_branch} at all — no receipt, so nothing is screened and the failure is charged to this round exactly as it would have been. ${falseRed.detail}`)
  } else if (falseRed) {
    log(`[${R}] known-false-red screen: nothing this repo declares covers this failure — judged on its own evidence, as before. ${falseRed.detail}`)
  } else if (desc.knownFalseReds && dev && (dev.status === 'partial' || dev.status === 'blocked') && reportsAFailedCheck(dev)) {
    log(`⚠️ [${R}] the known-false-red screen did not converge — the failure is charged to this round exactly as it would have been before this step existed. Check by hand against ${rp.base_branch}.`)
  }
  // A confirmed pre-existing failure that is ALL the round still owes gets no continuation pass. The
  // pass would spawn a fresh agent, rebuild from scratch, re-run the declared flake and hand back the
  // same answer; six of those were measured on one ticket. The repo does not reach 'ready' either —
  // `record` above is what keeps it honest — but it stops paying to learn what it already knows.
  const flakeIsTheWholeRound = falseRed?.state === 'pre-existing' && falseRed.sole_obstacle === true
  if (flakeIsTheWholeRound) log(`⏭️ [${R}] the round's ONLY remaining obstacle is that pre-existing failure, so it is not continued: a fresh pass would rebuild, re-run the same declared flake and return the same handoff.`)
  let buildPass = 0
  let lastRemaining = null
  while (!flakeIsTheWholeRound && dev && (dev.status === 'partial' || dev.status === 'blocked') && buildPass < BUILD.maxContinuationPasses) {
    buildPass++
    const wasBlocked = dev.status === 'blocked'
    const fingerprint = String(dev.remaining || dev.summary || '').toLowerCase().replace(/\s+/g, ' ').trim().slice(0, 300)
    const stalled = fingerprint && fingerprint === lastRemaining
    lastRemaining = fingerprint
    log(`▶️ [${R}] build handoff status=${dev.status} — CONTINUING it (pass ${buildPass}/${BUILD.maxContinuationPasses}${stalled ? ', and the last pass moved nothing' : ''}): ${String(dev.remaining || dev.summary || '(no detail)').slice(0, 120)}`)
    const cont = await safeAgent(
      `${tag(R, desc.build, 'build-continue', buildPass)} CONTINUE your build of ${ticket} in the ${R} repo — this is pass ${buildPass} of at most ${BUILD.maxContinuationPasses}, and it is not a restart. ${inRepo} The branch is ${rp.work_branch} and the plan is at ${rp.plan_path}; THIS REPO'S BASE IS ${rp.base_branch}.${baseIsSettled(rp.base_branch)}
WHAT YOU ALREADY DID, in your own words: ${String(dev.summary || '(no summary)').slice(0, 400)}
WHAT YOU SAID REMAINS: ${String(dev.remaining || '(you named nothing)').slice(0, 700)}
${dev.root_cause ? `THE CAUSE YOU MEASURED: ${String(dev.root_cause).slice(0, 400)}\n` : ''}${(dev.commands_run || []).length ? `WHAT YOU RAN: ${JSON.stringify(dev.commands_run).slice(0, 500)}\n` : ''}${dev.parked_at ? `WHERE YOU PARKED WORK: ${dev.parked_at} — recover it before you write anything new, so you do not implement it twice.\n` : ''}
FIRST, RE-READ THE GROUND, not your memory of it: \`git -C ${absR} log --oneline origin/${rp.base_branch}..${rp.work_branch}\` for what actually landed, and \`git -C ${absR} status --porcelain\` for anything uncommitted. What is already committed is DONE — do not redo it, do not re-litigate it, and do not reshape it unless the plan says it is wrong.
THEN FINISH THE REST. Same bar as before: /coding-feature test-first through /tdd, commit each slice conventionally (Refs ${ticket}), keep ${desc.green}.${wasBlocked ? ` YOU REPORTED BLOCKED, so the first question is whether the obstacle is real. Rule out the cheap classes before you accept it: the harness or toolchain itself · a dependency or service not standing up · a missing data precondition or fixture · a contract another repo owes that you can stub behind an interface for now and name in your handoff. Read this repo's declared known_false_reds before you call anything an environment problem. If it survives all of that, it is a real blocker and saying so IS the answer — but say it in \`cannot_fix\`, with the command and its exit code that proves it and what you ruled out first, because an unevidenced "blocked" is indistinguishable from not having tried.` : ''}${stalled ? ` ⚠️ YOUR LAST PASS MOVED NOTHING — the same "remaining" came back unchanged. Repeating it is not an option: treat your previous reading of the problem as a HYPOTHESIS TO DISPROVE, not as context. Re-derive it from the code and the commands, not from what you concluded last time, and if you still believe there is nothing to change then that is a claim about the WORK, so put it in \`cannot_fix\` with the evidence rather than returning the same sentence a third time.` : ''}
RETURN CONTRACT: end by calling StructuredOutput with the DEV_SCHEMA handoff. "complete" when the Definition of Done is genuinely met; otherwise "partial"/"blocked" with what is LEFT in "remaining" — and make "remaining" describe the state as it is NOW, not as it was, because the next pass and a human both read it as the current truth.` + falseRedClause + BUILD_DISCIPLINE + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE,
      { agentType: desc.build, phase: 'Build', label: `build-continue:${ticket}:${R}#${buildPass}`, schema: DEV_SCHEMA },
    )
    if (!cont) {
      log(`⚠️ [${R}] build continuation pass ${buildPass} returned no handoff — keeping the last real one and stopping the continuation here.`)
      break
    }
    // An accepted `cannot_fix` ends the attempts on THIS condition, the same way it does in the review
    // loop: refused without both the evidence and the cheaper classes ruled out first.
    const declined = (cont.cannot_fix || []).filter((c) => c?.reason && String(c.evidence || '').trim().length >= 12 && String(c.tried || '').trim().length >= 12)
    dev = cont
    if (declined.length && cont.status !== 'complete') {
      log(`⚠️ [${R}] build continuation stopped by an EVIDENCED cannot_fix: ${declined.map((c) => String(c.reason).slice(0, 90)).join(' | ')} — no further passes on this condition.`)
      dev.remaining = `${dev.remaining || ''} [workflow: the build declined this with evidence after ${buildPass} continuation pass(es) — ${declined.map((c) => `${c.reason} (evidence: ${c.evidence})`).join('; ')}]`.trim()
      break
    }
  }
  if (buildPass > 0 && dev && dev.status === 'complete') {
    log(`✅ [${R}] build COMPLETED on continuation pass ${buildPass} — a stop that used to cost a whole invocation.`)
  }
  if (buildPass >= BUILD.maxContinuationPasses && dev && dev.status !== 'complete' && dev.status !== 'deferred' && dev.status !== 'already-satisfied') {
    log(`⚠️ [${R}] build still ${dev.status} after ${buildPass} continuation pass(es) (build.max_continuation_passes) — RECORDING it; the repo cannot reach ready.`)
    dev.remaining = `${dev.remaining || ''} [workflow: ${buildPass} continuation pass(es) ran and could not finish it — the bound, not the first attempt, is what stopped this.]`.trim()
  }
  if (dev.status && dev.status !== 'complete' && dev.status !== 'deferred') {
    log(`⚠️ [${R}] build handoff status=${dev.status}: ${(dev.remaining || dev.summary || '(no detail)').slice(0, 140)} — repo not build-complete; downstream skipped.`)
    // `blocking` rides the return because a recorded item that never reaches `blockingByRepo` is a
    // silent degradation — the run summary, the ticket record and the incomplete-run DM all read it
    // from there, and a known false red is precisely the thing a reader must not mistake for a
    // broken diff.
    return { repo: R, status: 'build-unresolved', plan: rp, blocking, base_repair: baseRepair, false_red: falseRed, handoff: { status: dev.status, summary: dev.summary, remaining: dev.remaining, root_cause: dev.root_cause, commands_run: dev.commands_run, decision_needed: dev.decision_needed, parked_at: dev.parked_at, base_repair: baseRepair ? `this round began with a branch-base repair, done as its OWN step before the build: ${baseRepair.foreign_commits} commit(s) that were not ${ticket}'s were dropped by re-pointing ${rp.work_branch} at ${rp.base_branch}. It did NOT come out of the round's slice budget or its ${BUILD.maxContinuationPasses} continuation passes, so what "remaining" names is genuinely what the feature work did not reach.` : null, false_red: falseRed?.state === 'pre-existing' ? `NOT THIS ROUND'S FAILURE: ${screenedFailing} is a known false red this repo declares, and it was re-run in isolation on ${rp.base_branch} — which carries none of ${ticket}'s change — where it failed too (\`${falseRed.base_command || '(no command reported)'}\` exit ${falseRed.base_exit_code ?? '(none reported)'}). It was screened BEFORE the round could be charged for it, so it consumed none of the ${BUILD.maxContinuationPasses} continuation passes, and it is not evidence that this ticket's code is broken. What it does mean is that no run can prove this repo's suite green until that check is stable.` : null } }
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
    ? `${tag(R, desc.build, 'open-pr')} The ticket scope (spec(s) + regression specs) for ${ticket} is green in ${R}. ${inRepo} Ensure the tree is clean (\`git -C ${absR} status --porcelain\`), then open the PR/MR with the VCS adapter (it pushes ${rp.work_branch} for you): \`scripts/vcs/open-pr.sh --base ${rp.base_branch} --head ${rp.work_branch} --title "${prTitle(rp)}" --body "<what was automated + the scoped (ticket spec(s) + regression) green evidence>${deferredNote ? ' PLUS the Deferred scope block below, verbatim' : ''}"\`.${deferredNote} The title is Conventional Commits (\`<type>(${ticket}): <title>\`) — keep it exactly as given. Do NOT merge it — the workflow squash-merges in dependency order. Return the PR/MR URL (pr_url) + number (the adapter prints \`number=<n>\`).`
    : `${tag(R, desc.build, 'open-pr')} ${ticket} is built in ${R} — open the PR/MR now so the reviewers (code-reviewer + guardian + performance) can review it on the host. ${inRepo} PRECONDITION — before you run /open-pr, confirm the base exists on the remote: \`git -C ${absR} ls-remote --exit-code --heads origin ${rp.base_branch}\`. If it does not, STOP: do not push the base yourself and do not retarget. Return the failure as the result for this step — the exact command, its exit code, and \`git -C ${absR} push origin ${rp.base_branch}\` as the unblocking command. Otherwise: ensure the tree is clean (\`git -C ${absR} status --porcelain\`; commit any stray artifact), then run /open-pr ${ticket} to open the PR/MR for ${rp.work_branch} → ${rp.base_branch}, titled per Conventional Commits "${prTitle(rp)}". THE BASE IS ${rp.base_branch}, stated by this run: pass it to the skill and do NOT let the branch model re-derive it from the branch prefix.${baseIsSettled(rp.base_branch)}${deferredNote ? ' The PR/MR body MUST carry the Deferred scope block below verbatim — a reviewer must not have to guess which criteria this branch leaves unmet.' : ''} Do NOT merge it. Return the PR/MR URL + number.${deferredNote}`
  // RESUME: a 'pr_open' row is only usable when it actually carries a number/url — a row with
  // neither is unusable, and every downstream prompt interpolates pr.pr_number ?? '<number>', so
  // falling through to the live call beats letting a placeholder reach a real adapter call.
  const prRow = rowAt(R, 'pr_open')
  const prRowUsable = !!(prRow && (prRow.pr_number || prRow.pr_url))
  const prFirst = prRowUsable
    ? { pr_url: prRow.pr_url || null, pr_number: prRow.pr_number ?? null }
    : await safeAgent(
        openPrPrompt + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + stateWrite(R, 'pr_open', ',"pr_number":<the PR/MR number>,"pr_url":"<the PR/MR url>"'),
        { agentType: desc.build, phase: 'Open PR', label: `open-pr:${ticket}:${R}`, schema: PR_SCHEMA },
      )
  // ONE BOUNDED RETRY. This step had none, so a single non-converging agent ended the repo — and
  // with it the change set — on a branch that was already built and pushed. That is the cheapest
  // stop in the run to remove: everything the retry needs is settled (branch, base, title), and the
  // audited run lost three rounds on this step for a cause that was never the agent's fault.
  let prResult = prFirst
  if (!prResult) {
    log(`⚠️ [${R}] open-PR did not converge — retrying ONCE, bounded: one adapter call, no investigation.`)
    prResult = await safeAgent(
      `${tag(R, desc.build, 'open-pr', 1)} Your last attempt to open the PR/MR for ${ticket} in ${R} returned no structured result. ${inRepo} Everything is already decided — do not re-derive any of it, do not investigate, do not touch the code: branch ${rp.work_branch}, base ${rp.base_branch}, title "${prTitle(rp)}".${baseIsSettled(rp.base_branch)} ONE command, run BARE (no \`cd X &&\`, no pipe — a compound form is denied silently by the workspace guard, which reads exactly like a broken adapter): first \`git -C ${absR} remote get-url origin\` to read the owner/repo, then \`VCS_REPO=<owner/repo from that URL, without the host prefix or a trailing .git> scripts/vcs/open-pr.sh --base ${rp.base_branch} --head ${rp.work_branch} --title "${prTitle(rp)}" --body "<what landed + the green evidence>"\`. If an open PR/MR for ${rp.work_branch} ALREADY exists, the adapter prints it and that is your answer — it is idempotent, so this is safe to run again. Return pr_url and pr_number (the adapter prints \`number=<n>\`). If the adapter itself fails, that IS the answer for this step: return the exact command, its exit code and its stderr rather than routing around it.${deferredNote}` + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + stateWrite(R, 'pr_open', ',"pr_number":<the PR/MR number>,"pr_url":"<the PR/MR url>"'),
      { agentType: desc.build, model: 'opus', effort: 'high', phase: 'Open PR', label: `open-pr-retry:${ticket}:${R}`, schema: PR_SCHEMA },
    )
  }
  if (!prResult) {
    log(`⚠️ [${R}] open-PR did not converge after 2 attempts — the branch is built and pushed but has no PR/MR, so no reviewer prompt can be formed; left for human review.`)
    return { repo: R, status: 'pr-unresolved', plan: rp, handoff: { status: 'blocked', summary: 'the branch is built but no PR/MR was opened (2 attempts)', remaining: `open it by hand: \`git -C ${absR} remote get-url origin\`, then \`VCS_REPO=<owner/repo> scripts/vcs/open-pr.sh --base ${rp.base_branch} --head ${rp.work_branch} --title "${prTitle(rp)}" --body "<…>"\` — run the writer BARE.`, decision_needed: 'whether the adapter is failing for this repo (check the VCS_REPO the command resolves) or the agent simply did not converge' } }
  }
  const pr = prResult
  if (prRowUsable) log(`[${R}] open-PR SKIPPED — run state says pr_open at ${pr.pr_url || pr.pr_number}.`)
  log(`[${R}] opened PR: ${pr.pr_url}`)
  tick(`${R}:open-pr`)

  // ADR-0025 — assert (and repair) the target branch BEFORE the reviewers are paid for. A repo
  // whose PR/MR cannot be made to point at this run's base halts here: reviewing a diff against
  // the wrong base is work spent on a question nobody asked.
  const tgtOpen = await assertTargetBranch(R, rp, pr, { repair: true, phaseName: 'Open PR' })
  // ADR-0027 splits this in two, because the two failures are not the same kind of thing.
  //
  // MORE THAN ONE OPEN PR/MR: this run's own MR exists and its diff is computable, so review is
  // still real work. Closing the other one is a human call, so it becomes a MUST-FIX carried into
  // the loop and a recorded blocking item — the repo works, and it cannot merge with two MRs open.
  //
  // A TARGET THAT CANNOT BE MADE RIGHT (the base does not exist on the remote) STILL STOPS THE REPO,
  // and deliberately so: `git diff <base>...<head>` cannot be computed without that ref, so there
  // is no diff to review. Sending three reviewers at it would produce findings about the wrong
  // comparison — garbage in, and expensive garbage. This is not a halt the loop can absorb.
  if (!tgtOpen.ok && tgtOpen.multipleOpen) {
    log(`⚠️ [${R}] TARGET BRANCH — ${tgtOpen.why} Recording it and continuing into review: this run's own PR/MR is computable, so the review is still worth doing.`)
    record('multiple-open-prs', tgtOpen.why, `close the PR/MR(s) that should not land, then re-run — the run will not close one for you`)
    extraMustFix.push(`⚠️ THIS REPO HAS MORE THAN ONE OPEN PR/MR FOR ${ticket}. ${tgtOpen.why} Do NOT close one yourself unless you are certain which is abandoned — say in your summary which number you believe should land and why, so a person can close the other in one step.`)
  } else if (!tgtOpen.ok) {
    log(`⛔ [${R}] TARGET BRANCH — ${tgtOpen.why} Stopping this repo: without that base ref on the remote there is no diff to review.`)
    return { repo: R, status: 'target-branch-halt', plan: rp, pr, blocking, handoff: { status: 'blocked', summary: `the PR/MR does not target this run's base (${rp.base_branch})`, remaining: tgtOpen.why, decision_needed: 'retarget or close the PR/MR so exactly one open PR/MR targets this run\'s base, then re-run' } }
  }

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
  // HONOR THE LIVE PROVIDER: when quality_gate.provider is 'none' the guardian
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
  // Which gates arrived already-settled from the LEDGER rather than from this process. Used to
  // tell a resumed re-visit that it holds no memory of its own first pass (docs/adr/0021).
  const resumedFirstPass = {}
  // Gates (guard/perf) that reported gate_unavailable — frozen as UNAVAILABLE (not a pass,
  // not a dev-fixable finding). key → reason. Surfaced loudly by the workflow (fail-open).
  const gatesUnavail = {}
  // REVIEW LEDGER — rehydrate BEFORE the loop opens (docs/agents/review-ledger.md). A gate whose
  // row says done is FROZEN: not re-reviewed, not even re-visited. A gate that merely completed a
  // pass resumes in RE-VISIT mode, so its first review stays the closed finding set ACROSS
  // invocations, instead of being re-derived as a second "first review" that surfaces findings the
  // developer was never given the chance to fix — the failure this ledger exists to end.
  reviewers.forEach((rv) => {
    const m = `gate_${rv.key}`
    if (doneAt(R, m)) { done[rv.key] = true; didFirstReview[rv.key] = true; resumedFirstPass[rv.key] = true }
    else if (stateRows.some((r) => r.repo === R && r.milestone === m && r.first_pass === true)) { didFirstReview[rv.key] = true; resumedFirstPass[rv.key] = true }
  })
  if (reviewers.some((rv) => resumedFirstPass[rv.key])) log(`[${R}] review ledger: ${reviewers.filter((rv) => resumedFirstPass[rv.key]).map((rv) => `${rv.key} ${done[rv.key] ? 'PASSED (frozen, never re-reviewed)' : 'first pass done → re-visit only'}`).join(', ')}.`)
  // ADR-0027 §Across invocations — what a previous invocation RECORDED and could not close. Two
  // separate jobs here, and they are not interchangeable:
  //   (1) the gates it coexisted with are ledgered PASSED, which is what let the resumed run skip
  //       review entirely and return `ready`. Demoted FROZEN → re-visit, so the loop actually runs.
  //       This is not re-deriving a finding set (ADR-0021 still holds): a re-visit is the gate
  //       re-checking, never a second first review.
  //   (2) the item itself goes to the first fix pass as a must-fix. THAT is what re-works it — a
  //       re-visiting reviewer may only raise a fix-caused regression, so the reviewer is not the
  //       one who re-derives a carried cross-repo gap or an unrunnable suite.
  // Deliberately NOT re-recorded on sight: a human may have fixed the thing between runs, and an
  // item this run merely repeats would make the repo permanently unready.
  const carried = carriedBlocking(R)
  if (carried.length) {
    log(`⚠️ [${R}] ${carried.length} blocking item(s) CARRIED from a previous invocation (${carried.map((b) => b.kind).join(', ')}) — every ledgered gate is demoted to re-visit and each item goes to the first fix pass. Not re-recorded on sight: this run derives whether they still stand.`)
    reviewers.forEach((rv) => { if (done[rv.key] === true) { done[rv.key] = false; didFirstReview[rv.key] = true; resumedFirstPass[rv.key] = true } })
    extraMustFix.push(...carried.map((b) => `⛔ CARRIED FROM AN EARLIER RUN OF ${ticket} — a previous invocation worked this to its budget, could not close it, and RECORDED it. It comes first in this batch. Kind "${b.kind}": ${b.detail}${b.human_action ? ` · what it was waiting on a person for: ${b.human_action}` : ''}
FIRST, CHECK WHETHER IT STILL STANDS — a person may have fixed it between runs, or another repo's change may have removed it. If it is already gone, say so in your summary with the evidence you read (the command and its exit code, the resolved thread, the closed PR/MR) and do NOT invent work for it.
IF IT STILL STANDS, fix it. If it genuinely cannot be fixed here, \`cannot_fix\` with kind "${b.kind}", the evidence and what you ruled out first — same bar as any other condition. Repeating "still blocked" with nothing read is not an answer: that is how a recorded item becomes permanent.`))
  }
  // FORGE APPROVAL — the third record of the same "this review is settled" fact, and the only
  // one a HUMAN can write. A tick on the PR/MR says the review passed; re-deriving a review
  // above it is the wasted round this reads to prevent (docs/agents/review-ledger.md §5).
  //
  // Probed ONLY when the PR/MR predates this invocation. A PR this run just opened cannot
  // already carry an approval, so probing it would spend an agent per repo per run to learn
  // nothing — the price of that laziness is a human who approves in the seconds between Open PR
  // and Review in the SAME invocation and still gets reviewed, which is a rounding error.
  //
  // "unknown" is NOT "yes". A forge that will not answer leaves the gates to run: a review that
  // ran needlessly costs tokens, a review skipped on a fiction costs a shipped bug.
  if (prRowUsable && pr.pr_number && !reviewers.every((rv) => done[rv.key] === true)) {
    const probe = await safeAgent(
      `${tag(R, 'tracker', 'approval-probe')} READ THE FORGE, WRITE THE LEDGER — no review, no code, no comments. ${inRepo} The ${ticket} PR/MR ${pr.pr_number} in ${R} predates this invocation, so it may already carry a review approval. Run \`scripts/vcs/pr-view.sh ${pr.pr_number} --approved\` (bare, no pipe) and return its single word as \`approved\`: "yes", "no" or "unknown". Return the exact command you ran in \`command\`. Do NOT infer the answer from comments, from the MR description, or from anything else you read — one word from one command, and \`unknown\` if the command itself would not answer. ONLY IF the answer is exactly "yes", write ONE ledger row per gate for this repo — ${reviewers.map((rv) => `\`agent_logs/${ticket}-dev-cycle-state/${R}-gate_${rv.key}.json\``).join(', ')} — at the WORKSPACE ROOT (the dir holding .claude/), each containing exactly: {"repo":"${R}","milestone":"gate_<key>","status":"done","first_pass":true,"source":"forge-approval","head_sha":"<git rev-parse HEAD, full sha>","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}. The \`source\` field is not decoration: it says this freeze was INHERITED from an approval on the forge rather than earned by a gate that ran here, so a later reader is never told a review happened that did not (docs/adr/0021). On "no" or "unknown", write NOTHING.` +
        ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
      { agentType: 'developer', model: 'haiku', phase: 'Review', label: `approval-probe:${ticket}:${R}`, schema: APPROVAL_PROBE_SCHEMA },
    )
    if (probe?.approved === 'yes') {
      reviewers.forEach((rv) => { done[rv.key] = true; didFirstReview[rv.key] = true; resumedFirstPass[rv.key] = true })
      log(`[${R}] review SKIPPED — PR/MR ${pr.pr_number} is ALREADY APPROVED on the forge; every gate frozen (source: forge-approval, not a gate that ran here).`)
    } else if (probe?.approved === 'unknown') {
      log(`[${R}] approval state UNKNOWN on PR/MR ${pr.pr_number} (${probe?.note || 'the forge would not answer'}) — treating as unapproved and reviewing, never skipping on an unanswered question.`)
    }
  }

  // A `Human:` DIRECTIVE ON AN ALREADY-SETTLED PR/MR (docs/agents/human-review.md).
  //
  // Everything above this line can freeze a repo whole — a `reviewed` row, three ledgered gates, a
  // tick on the forge — and every one of those proofs is a statement about a COMMIT. A comment is
  // not a commit. It moves no branch head, so the run-state proof (docs/adr/0018) cannot see it;
  // and the ticket-change fingerprint is title + acceptance criteria ONLY, with comment text
  // excluded on purpose (0018's own addendum — including it made the run's status comments
  // invalidate the fingerprint on every invocation). Two proofs, both structurally blind to the
  // same thing, which is why the skip below returned `ready` with a person's directive unread —
  // twice in a row on one measured run — and the only way to act on it was to invoke
  // /apply-human-review by hand and know that you had to.
  //
  // A human's directive is the one input that outranks every gate (human-review.md §Authority: it
  // jumps the queue, it is always a must-fix, and the merge/Done gate never passes through one),
  // and the forge's own record of one being open is the UNRESOLVED thread. So it gets the
  // narrowest exception to "a passed gate stays passed": ONE read-only haiku probe, and only for a
  // repo that was about to skip its review entirely. It re-derives no finding — ADR-0021 still
  // holds, because what follows is a RE-VISIT, never a second first review — it demotes the frozen
  // gates to re-visit and hands the directives to the first fix pass, exactly as a carried
  // blocking item does. `!carried.length` guards the probe because a carried item already forces
  // the loop: the veto is the same, so paying for the read twice buys nothing.
  let humanDirectives = [], humanProbeBlind = false
  const wouldSkipReview = (doneAt(R, 'reviewed') || (reviewers.length > 0 && reviewers.every((rv) => done[rv.key] === true))) && pr
  if (!carried.length && wouldSkipReview && pr.pr_number) {
    const hp = await safeAgent(
      `${tag(R, 'tracker', 'human-probe')} READ THE FORGE, WRITE NOTHING — no review, no code, no comment, no thread resolution, no commit. ${inRepo} ${ticket}'s PR/MR ${pr.pr_number} in ${R} is already settled in this run's ledger, so its review is about to be SKIPPED. Before that happens, answer one question: does it carry an unresolved \`Human:\` DIRECTIVE? Run \`scripts/vcs/pr-threads.sh ${pr.pr_number}\` (bare, no pipe) and return that exact command in \`command\`.
A DIRECTIVE is a thread that is BOTH still \`[unresolved]\` AND whose FIRST comment's first line starts with \`Human:\` — i.e. a person OPENED the thread to ask for something. Return one entry per such thread in \`directives\`: { thread_id, location as "<path>:<line>", body = the directive text VERBATIM (first 400 characters, do not summarize or translate it — a developer acts on these words).
NOT a directive, and NOT to be returned: (1) a \`Human:\` REPLY on a thread an AGENT opened — that is a DISPOSITION, and it CLEARS that finding rather than opening work; (2) any thread already \`[resolved]\`, whoever resolved it — a thread a human closed is never re-opened; (3) an agent's own comment that quotes, answers or restates a directive. Read \`docs/agents/human-review.md\` §"Two kinds of \`Human:\` comment" and §"Where they live" FIRST and apply them literally rather than from memory.
An EMPTY \`directives\` array is the normal, healthy answer — return it rather than stretching to find something, because every entry you return costs this repo a full re-visit round. But if the command itself would not answer — the adapter failed, the number is wrong, the forge refused — set \`blind: true\` and say what happened in \`note\`. \`blind\` is not the same as none: an unanswered question must not be reported as a clean bill of health.` +
        ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
      { agentType: 'developer', model: 'haiku', phase: 'Review', label: `human-probe:${ticket}:${R}`, schema: HUMAN_DIRECTIVE_PROBE_SCHEMA },
    )
    // A probe that did not converge is as blind as one that says so. Same rule as the approval
    // probe's "unknown": the cheap read is the FAST path, not the only one — when it cannot answer,
    // the gates re-visit and read the threads themselves. A re-visit that finds nothing costs a
    // round; a directive skipped on a fiction costs the person who wrote it.
    humanProbeBlind = !hp || hp.blind === true
    humanDirectives = (hp?.directives || []).filter((d) => d && d.body && d.thread_id)
    if (!humanProbeBlind && !humanDirectives.length) log(`[${R}] no unresolved \`Human:\` directive on PR/MR ${pr.pr_number} — the settled review stands.`)
  }
  // DEMOTE, NEVER THAW. A vetoed skip must produce a RE-VISIT, not a second first review — that is
  // the whole of ADR-0021 and it survives this exception intact. Two states reach here and both
  // have to be demoted, which is why this is not just the `done === true` line `carried` uses:
  // gates ledgered PASSED individually, and a repo whose only proof is a `reviewed` row (the merge
  // phase writes that one, and a run that got that far completed the loop for every gate). Treating
  // the second as "no first pass on record" would send all three gates back to a full first review
  // and re-derive a closed finding set — the exact cost the ledger exists to avoid.
  if (humanDirectives.length || humanProbeBlind) {
    reviewers.forEach((rv) => {
      if (done[rv.key] === true || doneAt(R, 'reviewed')) { done[rv.key] = false; didFirstReview[rv.key] = true; resumedFirstPass[rv.key] = true }
    })
  }
  if (humanProbeBlind && !humanDirectives.length) {
    log(`⚠️ [${R}] could NOT read the \`Human:\` threads on PR/MR ${pr.pr_number} — so the settled review is not skipped on an unanswered question. Every ledgered gate is demoted to re-visit; the gates read the threads themselves (docs/agents/human-review.md).`)
  }
  if (humanDirectives.length) {
    log(`⚠️ [${R}] ${humanDirectives.length} unresolved \`Human:\` directive(s) on PR/MR ${pr.pr_number} — the settled review is NOT skipped. Every ledgered gate is demoted to re-visit and each directive goes FIRST to the fix pass (docs/agents/human-review.md §Authority).`)
    extraMustFix.push(...humanDirectives.map((d) => `⛔ \`Human:\` DIRECTIVE — A PERSON WROTE THIS ON PR/MR ${pr.pr_number}, and it OUTRANKS every agent-reviewer comment in this batch: drain it FIRST, and it is a must-fix whatever this run's review.level says (docs/agents/human-review.md §Authority). Thread \`${d.thread_id}\`${d.location ? ` at ${d.location}` : ''}:
${String(d.body).slice(0, 800)}
Fix it (a genuine defect via /diagnosing-bugs first, code via /tdd — the same defect-vs-style split as any review comment), reply anchored on that thread, and then RESOLVE thread \`${d.thread_id}\` yourself once the fix is PUSHED: the agent resolves, not the human. If you cannot fix it, or the directive is unclear, reply on the thread asking and LEAVE IT UNRESOLVED, then return it in \`cannot_fix\` with kind "human-review", the thread id, and what you tried. An open directive keeps this repo out of \`ready\` by design — and resolving a thread to make the loop end is the one thing this contract forbids.`))
  }

  // RESUME: skip the whole review↔fix loop rather than re-paying for it (docs/adr/0018) — either
  // because this repo already reached 'reviewed', or because every individual gate is ledgered
  // green and only the merge phase never got far enough to write that row. Deliberately
  // head-agnostic: a passed gate stays passed (docs/adr/0021), so a commit landing afterwards does
  // not reopen a settled review. That is the trade-off the ADR records, not an oversight.
  // `!carried.length` is the veto that closes ADR-0027's cross-invocation fail-open: this early
  // `ready` is the exact return that used to un-know a recorded item. A repo carrying one must go
  // through the loop, whatever the ledger says about the gates it passed. The two `human*` vetoes
  // are the same shape for the same reason — an unresolved `Human:` directive, or a forge this run
  // could not ask about one, is not a state this return may report as settled.
  if (!carried.length && !humanDirectives.length && !humanProbeBlind && wouldSkipReview) {
    log(`[${R}] review SKIPPED — ${doneAt(R, 'reviewed') ? "run state says reviewed" : "every gate is ledgered PASSED"}. PR ${pr.pr_number ?? '?'}.`)
    return { repo: R, status: 'ready', plan: rp, pr, reviewRound: 0, verdict: {}, gatesUnavailable: {}, deferred: deferredScope, met_acceptance: dev.met_acceptance || [], build: { summary: dev.summary, fixed: [] } }
  }
  let reviewRound = 0, fixPasses = 0, lastFixed = []
  // The review gate's own known-false-red screen (below): its verdict, and the fact that it has run.
  // Once per repo, never once per round — the answer is about the base branch, which does not move.
  let reviewFalseRed = null, falseRedScreened = false
  let lastFp = null, stalled = 0
  // Cross-repo escalation bookkeeping. xrepoDone: one attempt per (repo, finding) — a repeat means
  // the routed fix did not settle it, which is a human call, not a ping-pong. pendingSync: an
  // escalated fix that landed upstream last round; the NEXT fix pass here must sync it forward
  // (pin bump / re-vendor) — carried explicitly so the sync never depends on a reviewer happening
  // to re-name the upstream this round.
  const xrepoDone = new Map()   // (repo::finding) -> attempts spent, capped at REVIEW.maxEscalationAttempts
  let pendingSync = []


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
    const greenGate = greenGateFor(R, rp.work_branch)
    // RE-VISIT — uniform across all three reviewers, with a per-role "what to re-check" line. The
    // first review is the COMPLETE, CLOSED finding set: confirm your OWN prior findings are addressed,
    // add nothing new. The ONE exception is a fix-CAUSED regression → fix_regression + a loud comment;
    // the workflow halts the repo for human action rather than looping the dev.
    // A first pass that happened in an EARLIER invocation left nothing in this process — only its
    // tagged threads on the PR/MR. Say so explicitly, or the gate reads "your first review" as
    // something it never did, finds no memory of it, and quietly reviews afresh.
    const resumedNote = (rv) => (resumedFirstPass[rv.key] && verdict[rv.key] == null)
      ? ` YOUR FIRST REVIEW HAPPENED IN AN EARLIER INVOCATION of this workflow, not in this process — you hold no memory of it, and that is expected, not a gap. Its findings ARE the \`[gate:${rv.key}]\`-tagged threads already on this PR/MR: that thread list is the authoritative and COMPLETE record of your closed finding set. Read it and work from it. The absence of your own recollection is NOT licence to review afresh.`
      : ''
    // THREAD OWNERSHIP. All three gates post through the same adapter token, so the forge shows one
    // author for every comment — nothing in the thread itself says which gate raised it. The tag is
    // what survives a process boundary, and it is how a re-visit finds its OWN closed finding set.
    const ownTag = (rv) => ` THREAD OWNERSHIP — prefix EVERY comment you post on this PR/MR with \`[gate:${rv.key}]\`, before any other prefix (so a fold-in reads "[gate:${rv.key}] [minor / fold-in] …"). Every gate posts as the SAME forge user, so this tag is the only thing that lets a later round — or a later invocation of this workflow, which holds none of your context — tell your threads from another gate's. An untagged comment is an orphan no re-visit will ever pick up.`
    // THREAD RESOLUTION. GitLab's "Resolve thread" / GitHub's "Resolve conversation" is not
    // decoration: an unresolved thread is the forge's own record that a finding is still open. The
    // fixer ticks the ones it fixed, but the gate OWNS the judgement, so the invariant lives here —
    // a gate may not pass while a thread it opened is unresolved.
    const resolveRule = (rv) => ` THREAD RESOLUTION — you OWN every thread you opened, and ${rv.key === 'review' ? 'approved:true' : 'passed:true'} asserts you have none of them left open. List them with \`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\` (yours are the ones tagged \`[gate:${rv.key}]\`) and settle EACH one: where the developer's fix genuinely resolves it, tick Resolve yourself — \`scripts/vcs/pr-resolve-thread.sh ${pr.pr_number ?? '<number>'} <thread-id>\` — and where it does not, leave it unresolved (or reopen one the developer closed prematurely, \`--unresolve\`, with a comment saying why) and do NOT pass. Return the ids you resolved in resolved_threads and the ones you left in still_open. A pass sitting above an unresolved thread you own is the one outcome this contract forbids; so is resolving a thread to make the loop end.
ONE THREAD YOU DO NOT OWN STILL BLOCKS YOU: a \`Human:\` DIRECTIVE — an unresolved thread a PERSON opened whose first line starts with \`Human:\`. It outranks every finding of yours, it is a must-fix whatever this run's review level says, and no gate passes through one (docs/agents/human-review.md §Authority). You do NOT fix it and you do NOT resolve it — the developer does both. Name each one you see in still_open and withhold your pass until it is gone. The mirror image is NOT a blocker and must not be treated as one: a \`Human:\` REPLY inside a thread YOU opened is a DISPOSITION — it CLEARS that finding, so stop counting it, do not re-argue it, and never re-open a thread a person resolved.`
    const revisitTask = (rv) => {
      const recheck = rv.key === 'review'
        ? `Do NOT run /review again — that re-derives a full review from scratch and surfaces new findings, exactly what re-visit forbids. Instead list the review threads YOU opened (\`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\`) and, for each must-fix you raised in your first review, confirm the developer's fix + reply genuinely resolve it. The green gate is NOT scoped down by a re-visit: the developer changed code, so RE-RUN the suite (\`scripts/dev.sh test\` from inside ${R}, plus analyze/gen where this repo's green needs them) and return a FRESH tests_green + tests_receipt — last round's green proves nothing about this commit, and a fix that resolves your thread while breaking a test is exactly what this catches. Return approved:true ONLY when EVERY one of your first-review must-fixes is resolved AND tests_green is true; else approved:false listing which of YOUR threads remain open (a newly-red suite counts as one).${NO_SELF_APPROVE}`
        : `Do NOT re-scan or re-profile broadly. Re-check ONLY the blocking + fold_in items YOU raised in your first review (\`scripts/vcs/pr-comments.sh ${pr.pr_number ?? '<number>'}\` / \`pr-threads.sh\`): confirm each is resolved on the PR/MR. Return passed:true ONLY when EVERY one of your first-review items is resolved; else passed:false listing which of YOUR items remain. File NO new Improvement tickets and add NO new blocking/fold_in items.`
      return `RE-VISIT (round ${reviewRound}) of ${prRef}.${resumedNote(rv)} ${inRepo} Your first review is the COMPLETE, CLOSED finding set — you are ONLY confirming your OWN prior findings are addressed, NOT reviewing afresh. Raise, comment on, or file NOTHING new.${changed} ${recheck}
THE ONE EXCEPTION — a fix-caused regression: if the developer's fix DIRECTLY caused a NEW blocking problem (a regression the fix introduced — NOT a pre-existing issue your first review missed), do NOT fold it into the loop. Post ONE loud PR/MR comment via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "⚠️ REGRESSION: <what the fix broke + evidence it was this fix>"\`, then return ${rv.key === 'review' ? 'approved:false' : 'passed:false'} with fix_regression:true and regression_detail (what broke, file:line, why it is the fix). The workflow then HALTS this repo loudly for human action — it is not yours to fix in-loop.`
    }
    const scopeNote = `First review (round ${reviewRound}): this is your ONE complete pass — review the whole change set and report EVERY must-fix together in a single batch, because later rounds only RE-VISIT these findings and add nothing new. This holds across INVOCATIONS, not just rounds: if this workflow is re-run later, your finding set is read back from the threads you leave here, and nothing outside it is ever raised again. So sweep the whole change set NOW rather than triaging the obvious first and expecting a later pass to catch the rest — there is no later pass. Before you return, ask yourself once what part of the diff you have not actually looked at, and look at it. If you nonetheless notice something outside this closed set on a later round, do NOT post it: name it in your verdict's conclusion as out-of-scope-for-this-PR so a human can decide, ${STRICT ? 'which under review.level=strict is the only place it belongs' : 'or file it as an Improvement'}.`
    // THE BAR, INLINE. A reviewer is asked to judge the diff against the ticket's requirements, but
    // no reviewer holds a tracker grant — so a brief that says "read the ticket" points at a door
    // it cannot open, and the agent falls back to inferring the bar from commit messages. The
    // planner already returned the acceptance criteria, so they travel WITH the prompt: deterministic,
    // one network call fewer, and identical on every round.
    // A pin at an UNMERGED upstream commit is the intended state of this diff, not an oversight —
    // it is what let this repo be built at all this round. Say so, or every reviewer raises it, and
    // the honest fix for it ("wait for the merge") is the round the ordering exists to remove.
    const pinBar = pinTargets.some((p) => p.target.startsWith('origin/') && p.target.includes('PUSHED earlier in this run'))
      ? ` SUBMODULE PIN, already decided — this diff moves a submodule pointer to an UPSTREAM BRANCH COMMIT that is not merged yet (${pinTargets.filter((p) => p.target.includes('PUSHED earlier in this run')).map((p) => `${p.path} → ${p.repo}`).join(', ')}). That is deliberate and it is how this repo could be built in the same round as its upstream: a pointer needs a commit on the remote, not a merged one, and the workflow re-points it at the merged sha as a ship step before anything lands. Do NOT raise it as a must-fix and do NOT ask for the merge first. What you MAY check is that the pin points at THIS ticket's upstream branch and not at some unrelated commit.`
      : ''
    const deferredBar = deferredScope.length
      ? ` DEFERRED, already decided — do NOT raise these as must-fixes and do NOT ask for them in this PR/MR: ${deferredScope.map((d) => `"${d.criterion}" (owned by ${d.owner})`).join(', ')}. They are recorded on the MR and in the run summary. What you MAY do is check the diff does not silently half-implement one; say so if it does.`
      : ''
    const theBar = rp.acceptance?.length
      ? ` THE BAR for this repo's slice — the acceptance criteria to judge the diff against, as the planner recorded them (you have NO tracker access; this list is authoritative, do not go looking for the ticket): ${rp.acceptance.map((a, i) => `(${i + 1}) ${a}`).join(' ')} Where a criterion is NOT met by the diff, that is a must-fix. Where one is deliberately out of scope for this repo, say so in your verdict rather than silently dropping it.`
      : ` THE BAR: the planner recorded no acceptance criteria for this repo's slice, and you have NO tracker access to fetch them — so judge STANDARDS and internal consistency only, and say plainly in your verdict that the spec axis could not be judged for want of a bar.`
    const onPr = `the OPEN PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}; ${rp.work_branch} → ${rp.base_branch}). ${inRepo} ${scopeNote} Post each must-fix as a comment ON THE PR/MR at the specific file:line via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "<comment>"\` — NEVER on the tracker.`
    const firstReviewPrompt = (rv) =>
      rv.key === 'review'
        ? `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} Review ${onPr}${theBar}${deferredBar}${pinBar} Run /review (standards + spec) against the target — for its "identify the spec source" step, the bar above IS the spec source, already resolved for you. ${greenGate} Return approved:true ONLY when the diff meets the bar, tests_green is true, and every ${STRICT ? 'must-fix' : 'must-fix AND nice-to-have'} comment is resolved; otherwise approved:false with the open comments.${NO_SELF_APPROVE}`
        : rv.key === 'guard'
          ? `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} You are the REPORTER for this repo's configured static-analysis tool on ${ticket} in ${R}, on ${onPr} You do not audit the code yourself and you do not write a security assessment: you run the configured scanner, relay what IT reported, and triage those findings. Every judgement below belongs to the tool; your job is to fetch it, classify it and post it. The workspace's configured quality-gate provider is quality_gate.provider="${QUALITY_GATE}" (mirrored from workspace.config.yaml — do NOT re-read the file). If it is 'none', skip the scan and pass cleanly. Otherwise (SonarQube) run the gate by whichever channel is LIVE in THIS run-context: FIRST try the SonarQube MCP — if the mcp__sonarqube tools are not already in your toolset, load them with ToolSearch (e.g. \`select:mcp__sonarqube__get_project_quality_gate_status,mcp__sonarqube__search_sonar_issues_in_projects,mcp__sonarqube__search_security_hotspots\`) and read the quality-gate status, the issue list and the hotspot list the tool reports for the PR SHA; if the MCP is NOT reachable, FALL BACK to the installed \`sonar\` CLI over Bash (\`sonar analyze\` / \`sonar verify --file <changed-file>\`). GATE-UNAVAILABLE: if NEITHER channel can actually run the scan (no MCP AND no working CLI/auth), you MUST NOT pass — set passed:false AND gate_unavailable:true with unavailable_reason naming both channels you tried and why each failed, and post ONE loud PR/MR comment via scripts/vcs/pr-comment.sh that the configured SonarQube gate could NOT run in this run-context; never fabricate a green status. For each finding the tool marks BLOCKING, post a PR/MR comment carrying the tool's own rule id, file:line and suggested remediation, and list it under "blocking" — quote the tool, do not restate it as your own conclusion. As a light secondary pass, check whether its output happens to touch this repo's declared sensitive areas (${desc.guardianFocus}) and say so if it does; finding nothing there is the normal result, not a gap in your work. Triage every NON-blocking finding into ONE of two tiers — do NOT file a ticket for every finding: (a) MINOR fix (small, local, low-risk — a few lines, mechanical, no new design/contract/QA scope) → post a PR/MR comment at file:line prefixed "[minor / fold-in]" with the exact remediation and list it under "fold_in"; the developer applies it in THIS PR, NO ticket. (b) MAJOR, nice-to-have hardening (needs its own design, touches multiple layers, changes a contract/permission model, or carries a documented trade-off — AND is genuinely optional for this ticket, not must-have) → file ONE Improvement ticket YOURSELF by invoking /clarifying-ticket (Mode A — pass the finding + "source ${ticket}"), and put the REAL <KEY> it returns (with the title) into improvements_filed — NEVER a placeholder like "<PREFIX>-pending". /clarifying-ticket DEDUPS against the board first (scripts/tracker/find-tickets.sh): if the finding (same scope + root cause) is already tracked it returns that EXISTING <KEY> — record that one instead and NEVER file a second ticket for it; also don't re-file findings you already filed earlier in this same run, and never file a ticket for a MINOR fold-in. If a "minor" fold-in turns out non-trivial mid-loop, reclassify it as (b) rather than looping on it. Whoever reports the topic owns the ticket; do not defer it to a human. If the tracker is unreachable, note that in the entry instead of a fake number. Filing tickets and posting fold-ins are both non-blocking for the gate — neither holds up the merge, and an empty improvements_filed is the normal, healthy outcome. Return passed:false while ANY blocking OR unresolved fold_in item remains (so the developer folds the minor ones into this PR); passed:true ONLY when you ACTUALLY obtained a green quality-gate result (or the provider is 'none') AND no fold_in item is left unresolved — NEVER passed:true for a scan you could not run (use gate_unavailable for that). Return the structured gate result.`
          : `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} Performance review of ${ticket} in ${R} on ${onPr} Profile the changed flows with this repo's profiling tooling (e.g. for a Flutter app every profiling command goes through scripts/perf.sh, never raw flutter/dart: perf.sh build --profile, perf.sh run --profile + perf.sh devtools); measure jank, startup, memory, rebuild storms, unbounded lists, costly/unindexed queries; mandatory animations stay 60fps. For each CRITICAL regression post a PR/MR comment WITH the measurement as evidence and list it under "blocking". Triage every NON-blocking optimization into ONE of two tiers — do NOT file a ticket for every finding: (a) MINOR optimization (small, local, low-risk — a few lines, mechanical, no new design/contract/QA scope; e.g. MediaQuery.of(context).size → MediaQuery.sizeOf(context), or an O(n²) lookup → a Set) → post a PR/MR comment at file:line prefixed "[minor / fold-in]" with the measurement/mechanism + exact fix direction and list it under "fold_in"; the developer applies it in THIS PR, NO ticket. (b) MAJOR, nice-to-have optimization (needs its own design, touches multiple layers, changes a query/index/schema, or carries a documented trade-off — AND is genuinely optional for this ticket, not must-have; e.g. a composite (status, createdAt) index) → file ONE Improvement ticket YOURSELF by invoking /clarifying-ticket (Mode A — pass the finding + "source ${ticket}"), and put the REAL <KEY> it returns (with the title) into improvements_filed — NEVER a placeholder like "<PREFIX>-pending". /clarifying-ticket DEDUPS against the board first (scripts/tracker/find-tickets.sh): if the finding (same scope + root cause) is already tracked it returns that EXISTING <KEY> — record that one instead and NEVER file a second ticket for it; also don't re-file findings you already filed earlier in this same run, and never file a ticket for a MINOR fold-in. If a "minor" fold-in turns out non-trivial mid-loop, reclassify it as (b) rather than looping on it. Whoever reports the topic owns the ticket; do not defer it to a human. If the tracker is unreachable, note that in the entry instead of a fake number. Filing tickets and posting fold-ins are both non-blocking for the gate — neither holds up the merge, and an empty improvements_filed is the normal, healthy outcome. GATE-UNAVAILABLE: if your profiling tooling cannot actually run in this run-context (e.g. scripts/perf.sh / the profiler is unavailable so you could measure nothing), you MUST NOT pass — set passed:false AND gate_unavailable:true with unavailable_reason explaining what you tried and why it couldn't run, and post ONE loud PR/MR comment via scripts/vcs/pr-comment.sh that the performance gate could NOT run; never fabricate a clean profile. Return passed:false while ANY blocking regression OR unresolved fold_in item remains (so the developer folds the minor ones into this PR); passed:true ONLY when you ACTUALLY profiled the changed flows AND found zero blocking regressions AND no fold_in item is left unresolved — NEVER passed:true for a profile you could not run (use gate_unavailable for that). Return the structured gate result.`

    // Ownership + resolution ride on BOTH modes: the first review must tag what it posts, the
    // re-visit must resolve what it tagged. Appending once here beats threading them through five
    // prompt variants.
    const promptFor = (rv) =>
      (modeThisRound[rv.key] === 'revisit'
        ? `${tag(R, rv.role, 'review', reviewRound)} ${revisitTask(rv)}`
        : firstReviewPrompt(rv)) + ownTag(rv) + resolveRule(rv)

    const openReviewers = reviewers.filter((rv) => !done[rv.key])
    reviewers.filter((rv) => done[rv.key]).forEach((rv) => log(`[${R}] review round ${reviewRound}: ${rv.key} ${done[rv.key] === 'unavailable' ? 'UNAVAILABLE (gate could not run)' : 'already PASSED'} — frozen, not re-reviewed.`))
    // A guard/perf gate that DIES — e.g. an Anthropic usage-policy safeguard tripping on the
    // security-review phrasing, or a transient API error — must NOT read as a hard run failure.
    // Guard: Layer 2 backstop (neutral general-purpose checklist over the diff). Perf: map to
    // gate_unavailable so the run continues (fail-open). A code reviewer that DIES stays null
    // (inconclusive, re-run next round) — distinct from the code reviewer REPORTING
    // gate_unavailable, which means its test gate could not run and HALTS the repo (never
    // fail-open: an unverified suite must not reach a merge).
    // No gateRow here, deliberately: the backstop is a neutral checklist standing in for a gate
    // that died, not the configured gate itself. Freezing the real guard gate for every future
    // invocation on the strength of a substitute pass would be a stronger claim than it earned.
    const guardBackstop = async (msg) => {
      log(`⚠️  [${R}] guardian subagent could not complete (${msg}) — running checklist inline via neutral agent (backstop).`)
      try {
        const bk = await agent(
          `${tag(R, 'general-purpose', 'guard-backstop', reviewRound)} Static code-quality pass over the diff of ${prRef}. ${inRepo} Read the diff (\`git -C ${absR} diff ${rp.base_branch}...${rp.work_branch}\`) and check the CHANGED lines for: ${desc.guardianFocus}. Post each concrete file:line issue via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "<issue + fix>"\` and list under "blocking" (no generic advice). Return passed:true when clean, else passed:false with the blocking list.` + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
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
        return await agent(promptFor(rv) + VERDICT_BEFORE_BUDGET + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + codegraphClause(desc.path) + gateRow(R, rv.key), { agentType: rv.role, phase: 'Review', label: `${rv.key}:${ticket}:${R}#${reviewRound}`, schema: rv.schema })
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

    // BLOCKED-ON (C3). A reviewer that says "this needs the change in <upstream>" is describing a
    // dependency, not a defect this repo can fix — but only a FINISHED, NON-READY upstream is a
    // reason to stop. Builds run in PARALLEL, so an upstream still in flight has no repoResults
    // entry yet; treating that as "not ready" halted repos whose upstream went on to pass.
    const upstreams = (rp.depends_on || []).filter((id) => REPOS[id])
    const upstreamState = (id) => repoResults[id] ? repoResults[id].status
      : (doneAt(id, 'reviewed') ? 'ready' : 'pending')
    const named = upstreams.filter((id) => {
      const hay = JSON.stringify(openReviewers.map((rv) => verdict[rv.key] ?? null))
      return new RegExp(`(^|[^\\w-])(${id}|${REPOS[id].path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})([^\\w-]|$)`).test(hay)
    })
    // An `already-satisfied` upstream is FINISHED. Reading it as "did not reach ready" would record a
    // blocking item and keep this repo out of `ready` over a repo that has nothing wrong with it —
    // turning the new terminal state into a way to fail a run. It is not a repair target either: it
    // has no branch, no PR/MR and no diff, so there is nothing there for a fix to land on. Its own
    // bucket, named to the fix pass so the finding is worked HERE.
    const finishedElsewhere = named.filter((id) => upstreamState(id) === 'already-satisfied')
    const hardBlockers = named.filter((id) => !['ready', 'pending', 'already-satisfied'].includes(upstreamState(id)))
    if (finishedElsewhere.length) {
      log(`[${R}] a review finding names ${finishedElsewhere.join(', ')}, which needed NO change for ${ticket} — already on the base branch, no branch or PR/MR in this run. Not a blocker and not an escalation target; handed to the fix pass as this repo's own.`)
      extraMustFix.push(`⚠️ A FINDING HERE NAMES ${finishedElsewhere.join(' + ')}, which needed NO change for ${ticket}: verified already satisfied, so that repo has no branch, no PR/MR and no diff in this run — its code is what is already on its base branch. There is nothing there to land a fix on, so do NOT ask for one and do NOT return it in \`upstream_fix_needed\`. Either resolve the finding inside ${R} on its own terms, or — if you believe that repo's SHIPPED code is genuinely wrong — say so explicitly with the file:line, because that is a separate defect in released code and a person has to decide whether this ticket absorbs it.`)
    }
    // BLOCKED-ON a FINISHED, non-ready upstream. This used to halt. It does not any more
    // (ADR-0027): the finding goes to the fix pass as a must-fix that may ESCALATE into that
    // upstream through the cross-repo route below — the mechanism built for exactly this. Recorded
    // either way, because the honest position is unchanged: the upstream's own pipeline failed, the
    // ticket is ship-coupled, and nothing merges until it recovers. What changes is that this repo
    // now spends its remaining rounds working instead of stopping on a fact about another repo.
    if (hardBlockers.length) {
      log(`⚠️ [${R}] BLOCKED ON ${hardBlockers.join(', ')} — a reviewer finding names a declared upstream whose own pipeline FINISHED without reaching 'ready' (${hardBlockers.map((id) => `${id}=${upstreamState(id)}`).join(', ')}). Recording it and continuing; the fix pass may escalate into it.`)
      record('blocked-on', `a reviewer finding names upstream ${hardBlockers.join(', ')}, whose own pipeline finished without reaching ready`, `whether to land ${hardBlockers.join(' + ')} first, or re-scope the finding onto this repo`)
      extraMustFix.push(`⚠️ A FINDING HERE NAMES ${hardBlockers.join(' + ')}, whose own pipeline in this run FINISHED WITHOUT REACHING READY. Do NOT re-implement that repo's work inside this one. Pick one of two, explicitly: (1) if the ROOT fix genuinely lives there and this run holds that repo, return it in \`upstream_fix_needed\` with evidence — the workflow routes a scoped fix + re-gate into it; (2) if the finding can be resolved inside ${R} on its own terms (a guard, a fallback, a narrower contract), do that and say why it is a real fix rather than paper over the upstream gap.`)
    }
    // REPAIRABLE-ON — the named upstream is ready (or still building and expected to be): the
    // finding is a SYNC, not a defect. Hand the fix agent the upstream's own merge-ready head so
    // it can bump a submodule pin / re-sync a vendored contract, inside the existing round budget.
    const repairOn = named.filter((id) => upstreamState(id) === 'ready' || upstreamState(id) === 'pending')
    const upstreamRepairClause = repairOn.length
      ? ` UPSTREAM SYNC (a reviewer finding names a declared upstream of this repo — it is a SYNC, not a defect you must re-implement): ${repairOn.map((id) => {
          const up = repoResults[id]?.plan || plans.find((p) => p.repo === id)
          const br = up?.work_branch || `${branchKind}/${ticket}`
          return `${id} (path "${REPOS[id].path}", branch ${br}, state ${upstreamState(id)})`
        }).join('; ')}. For EACH: (1) detect, do not guess — \`git -C ${absR} config -f .gitmodules --get-regexp path\`; if that path is declared, bring the pin forward to the tip of that branch on origin and commit the pointer move on its own, every command anchored (\`git -C ${absR}/<path> fetch origin && git -C ${absR}/<path> checkout origin/<branch> && git -C ${absR} add <path> && git -C ${absR} commit -m "chore(<path>): sync ${ticket} upstream pin"\`); NEVER edit files inside the submodule checkout — a guard blocks it. (2) If it is NOT a submodule, the sync is in code you own: re-generate or re-copy the vendored contract/schema from the upstream repo's tree at that branch and reconcile the callers here. (3) If neither applies — the pin is already at the upstream tip and the fix does not EXIST there to sync forward — then the finding needs NEW work in that repo, which you cannot do from here: declare it in "upstream_fix_needed" (the repo id, the finding restated as what must change THERE, and evidence — the exact fetch/grep results proving it is absent both here and upstream), reply on the thread with what you checked, and do NOT invent a change here or edit the submodule checkout. The workflow routes a scoped fix pass to that repo on the strength of your evidence — an undeclared gap just re-confirms itself next round.`
      : ''
    if (repairOn.length) log(`[${R}] review finding names declared upstream ${repairOn.join(', ')} (state: ${repairOn.map((id) => upstreamState(id)).join(', ')}) — routing to the fix pass with the upstream head, not halting.`)

    // TEST GATE COULD NOT RUN — a must-fix, not a halt (docs/adr/0027), and never a pass either.
    //
    // A suite that could not RUN is a different thing from a red suite: there is no verdict at all,
    // so nothing here can say the PR/MR does not break the tests. This used to end the repo on the
    // spot. Most of the time it is genuinely fixable — an unresolved dependency, a candidate stack
    // that is not up, a migration nobody applied — so it now goes to the developer as work, with
    // the evidence the gate actually got and the failure classes worth checking IN ORDER. Only the
    // last class is unfixable, and an agent that names it with evidence closes these attempts early
    // rather than grinding the budget on a machine that has no container runtime.
    //
    // Whatever happens, `review` never enters `done` as a pass while unverified: either the repair
    // lands a green receipt, or the condition is recorded and the repo cannot reach 'ready'.
    const testGateDown = openReviewers.find((rv) => rv.key === 'review' && verdict[rv.key]?.gate_unavailable === true)
    if (testGateDown) {
      const why = verdict.review?.unavailable_reason || 'the repo test suite could not run in this run-context (no reason given)'
      const rc = verdict.review?.receipt
      if (left('suite_repair', TEST_SUITE.maxSuiteRepairAttempts) <= 0) {
        record('suite-unverified', `the repo suite could not be made to run in ${attempts.suite_repair} attempt(s): ${why}`,
          `unblock the suite in ${R} (last reported reason: ${why}), then re-run the dev-cycle — no green receipt exists for this change set`)
        done.review = 'unverified'   // stop re-running a gate that cannot answer; `blocking` holds the repo
      } else {
        spend('suite_repair')
        log(`[${R}] test gate could not run (attempt ${attempts.suite_repair}/${TEST_SUITE.maxSuiteRepairAttempts}) — routing it to the developer as a must-fix: ${why}`)
        extraMustFix.push(`⛔ THE SUITE DID NOT RUN — fix that first, it outranks every other finding in this batch. This is NOT a red suite: there is no verdict at all, so nothing in this run can say your change does not break the tests, and no amount of reading the diff substitutes for a receipt.
WHAT THE GATE GOT, verbatim: ${why}${rc?.command ? ` · command: \`${rc.command}\`${Number.isInteger(rc.exit_code) ? ` · exit ${rc.exit_code}` : ''}` : ' · (it reported no command)'}
GREEN FOR THIS REPO MEANS: ${desc.green}
THIS REPO'S DECLARED KNOWN FALSE REDS: ${desc.knownFalseReds || '(none declared)'} — check these FIRST: if the failure matches one, it is an environment failure, so re-run that check in isolation against ${rp.base_branch} before treating it as real.
CLASSIFY IT, then fix that class — in this order, because each is cheaper to rule out than the next:
  (a) THE HARNESS ITSELF — scripts/dev.sh missing, or dependencies unresolved after a manifest change. Run \`scripts/dev.sh clean\` (its install/resolve step), then re-run the check.
  (b) THE CANDIDATE STACK IS NOT UP — the suite needs a service that is not listening. Bring each one up FROM ITS OWN TICKET WORK BRANCH and PROVE it answers by probing the port. ⚠️ a harness \`run\` that probes and then tears its server down has not given you a stack: it prints an UP verdict while nothing listens — start it in the background and re-probe.
  (c) A DATA PRECONDITION — a migration or seed the suite assumes and nobody applied to the local store.
  (d) GENUINELY ABSENT FROM THIS ENVIRONMENT — no container runtime, no credential, no such service. THE ONLY CLASS NOTHING CAN FIX.
YOU MUST END WITH A RECEIPT: the exact command, its exit code, and the runner's own summary line quoted verbatim. No receipt means the gate still did not run, whatever you changed.
IF IT IS CLASS (d): say so explicitly in your handoff — name the class, the command and exit code that proves it, and what you already tried. That is a RESULT, and it stops these attempts; it is not a failure to try. Do NOT claim (d) to avoid (a)–(c): the classes above are ordered by how cheap they are to rule out, so rule them out.`)
      }
    }

    // A reviewer that COMPLETED a pass in first-review mode has now done its one full review, so
    // every later pass for it is a re-visit. A crash (null verdict) leaves it in first-review mode.
    openReviewers.forEach((rv) => { if (verdict[rv.key] != null && modeThisRound[rv.key] === 'first') didFirstReview[rv.key] = true })

    // FIX-CAUSED REGRESSION (re-visit only) — the ONE thing a re-visit may raise, and the most
    // natural must-fix of the lot (ADR-0027): the developer who broke it is right here, holding the
    // context. It used to halt for LOUDNESS, not because it was unfixable. Its own counter, because
    // fix → regression → fix can oscillate and would otherwise eat rounds that other findings need.
    const regressed = openReviewers.filter((rv) => modeThisRound[rv.key] === 'revisit' && verdict[rv.key]?.fix_regression === true)
    if (regressed.length) {
      const detail = regressed.map((rv) => `${rv.key}: ${verdict[rv.key]?.regression_detail || 'fix-caused regression (no detail)'}`).join(' | ')
      if (left('regression_fix', REVIEW.maxRegressionFixes) <= 0) {
        record('regression', `a fix in this repo caused a new blocking problem and ${attempts.regression_fix} repair attempt(s) did not settle it: ${detail}`,
          `review the last commits on ${rp.work_branch} by hand — the loop caused a regression it could not undo`)
      } else {
        spend('regression_fix')
        log(`⚠️ [${R}] FIX-CAUSED REGRESSION on re-visit round ${reviewRound} (repair ${attempts.regression_fix}/${REVIEW.maxRegressionFixes}) — handing it straight back: ${detail}`)
        extraMustFix.push(`⛔ YOUR OWN LAST FIX CAUSED THIS — it outranks every other finding in this batch, because the branch is now worse than before that fix. Reported by ${regressed.map((rv) => rv.key).join(' + ')} on re-visit: ${detail}
This is a REGRESSION, not a pre-existing defect: it was not there before your last push, so start from the diff of that push${lastFixed.length ? ` — you touched: ${lastFixed.join('; ')}` : ''} rather than re-reading the whole change. Reproduce it FIRST (a failing test if the shape allows), then fix, then confirm the ORIGINAL finding that fix was for is still resolved — undoing your fix to clear the regression puts the original must-fix back and does not count.
Keep ${desc.green}. If the regression and the original finding are genuinely in tension — the only fix for one re-breaks the other — say so in \`cannot_fix\` with kind "regression", the evidence for both sides, and what you tried.`)
      }
    }

    const crashed = openReviewers.filter((rv) => verdict[rv.key] == null).map((rv) => rv.key)
    const openFindings = openReviewers.reduce((n, rv) => n + (done[rv.key] || verdict[rv.key] == null ? 0 : rv.open(verdict[rv.key])), 0)
    log(`[${R}] review round ${reviewRound}${isRetest ? ' (re-visit)' : ' (first review)'}: ${reviewers.map((rv) => `${rv.key} ${done[rv.key] === 'unavailable' ? 'UNAVAILABLE' : done[rv.key] ? 'PASS' : crashed.includes(rv.key) ? 'ERRORED' : `${rv.open(verdict[rv.key])} open`}`).join(', ')}`)
    tick(`${R}:review#${reviewRound}`)

    // A DECLARED FALSE RED EMPTIES THIS LOOP TOO — the same screen, at the other end of the run.
    //
    // The build round screens one before it is charged for it (screenKnownFalseRed above). That was
    // never the only loop a declared flake can drain, and this one is worse. The review gate RUNS
    // this repo's whole suite on the PR/MR head every round, and its pass predicate is
    // `approved && tests_green` — so while a declared flake reds that suite, the reviewer CANNOT
    // pass, whatever the developer does. Round after round: full suite, a fix pass chasing a red the
    // repo wrote down in advance, another full suite. The stall detector does not catch it either,
    // because a pass that touches code and commits is not a stall. Every repo in a run has a review
    // and the round budget here is the largest in the workflow, so this is the biggest single way a
    // run spends its budget without moving the ticket. Same screen, same four outcomes, same rule:
    // it only ever moves a red OFF the loop on positive evidence — the failure watched happening on
    // a tree that predates the change.
    const suiteRed = openReviewers.find((rv) => rv.key === 'review'
      && verdict[rv.key] && verdict[rv.key].gate_unavailable !== true && verdict[rv.key].tests_green === false)
    if (suiteRed && desc.knownFalseReds && !falseRedScreened) {
      falseRedScreened = true
      const rv = verdict.review
      reviewFalseRed = await screenKnownFalseRed(R, rp, desc, {
        summary: `the ${R} repo suite is RED at review, on ${rp.work_branch}`,
        remaining: `the reviewer ran this repo's own suite on the PR/MR head and it failed. Its receipt: ${rv.tests_receipt || '(it reported none)'}${rv.conclusion ? ` · what it concluded: ${rv.conclusion}` : ''}`,
        root_cause: (rv.comments || []).map((c) => `${c?.file_line || ''} ${c?.issue || ''}`.trim()).filter(Boolean).join(' | '),
        commands_run: [],
      }, 'Review', '#review')
      tick(`${R}:false-red-screen#review`)
      const screenedFailing = (reviewFalseRed?.failing || []).join(', ') || 'the failing check'
      if (reviewFalseRed?.state === 'pre-existing') {
        // `done.review = 'unverified'` is the same mechanism the un-runnable suite above already
        // uses, and for the same reason: a gate that cannot answer must stop being asked. The
        // recorded item is what holds the line — the repo cannot reach 'ready' over it, and no run
        // can call this suite green while the check that decides it is red without this ticket.
        record('known-false-red', `${R}'s review gate is red on ${screenedFailing}, which this repo DECLARES as a known false red and which fails on ${rp.base_branch} too: \`${reviewFalseRed.base_command || '(no command reported)'}\` exit ${reviewFalseRed.base_exit_code ?? '(none reported)'} on a throwaway checkout of the base, which carries none of ${ticket}'s change. ${reviewFalseRed.detail}`,
          `stabilise ${screenedFailing} in ${R} — it is already red on ${rp.base_branch}, before this ticket touches anything — then re-run. Nothing in this run can prove this repo's suite green over a check that fails without it.`)
        done.review = 'unverified'
        log(`🟡 [${R}] KNOWN FALSE RED AT REVIEW, CONFIRMED ON THE BASE — ${screenedFailing} fails on ${rp.base_branch} in an isolated checkout, so re-running this repo's suite cannot turn it green and the review gate is not asked again. Recorded; the repo does not reach 'ready'. ${reviewFalseRed.detail}`)
        if (openFindings || extraMustFix.length) {
          extraMustFix.push(`⚠️ DO NOT CHASE ${screenedFailing.toUpperCase()} — the suite red the reviewer reported was screened as its own step before this batch, and it fails on ${rp.base_branch} in an isolated checkout that carries none of ${ticket}'s change (\`${reviewFalseRed.base_command || 'see the run log'}\` exit ${reviewFalseRed.base_exit_code ?? '?'}).${reviewFalseRed.matched ? ` It matches this repo's own declared known false red: ${reviewFalseRed.matched}.` : ''} It is NOT evidence about your diff and NOT yours to fix in this ticket: do not rebuild to reproduce it, do not wipe or recreate a local data directory to chase it, and do not re-run it hoping for a different answer. Fix the findings below and nothing else.`)
        }
      } else if (reviewFalseRed?.state === 'genuine') {
        log(`[${R}] known-false-red screen at review: ${screenedFailing} PASSES on ${rp.base_branch} (\`${reviewFalseRed.base_command || '(no command reported)'}\` exit ${reviewFalseRed.base_exit_code ?? '(none reported)'}), so the red is this change's own regression and the loop works it exactly as before.`)
        extraMustFix.push(`⛔ THE RED SUITE IS YOURS — ${screenedFailing} was re-run on ${rp.base_branch} in an isolated checkout before this batch, \`${reviewFalseRed.base_command || 'see the run log'}\` exit ${reviewFalseRed.base_exit_code ?? '?'}, and it PASSES there. So it is not the environment, not a flaky shared fixture and not this repo's declared false red: it is a regression your diff introduced. Fix the code, not the harness, and it outranks every other finding in this batch.`)
      } else if (reviewFalseRed?.state === 'inconclusive') {
        log(`⚠️ [${R}] known-false-red screen at review could not run ${screenedFailing} on ${rp.base_branch} at all — no receipt, so nothing is screened and the red is worked by this loop exactly as it would have been. ${reviewFalseRed.detail}`)
      } else if (reviewFalseRed) {
        log(`[${R}] known-false-red screen at review: nothing this repo declares covers this red — judged on its own evidence, as before. ${reviewFalseRed.detail}`)
      } else {
        log(`⚠️ [${R}] the known-false-red screen at review did not converge — the red is worked by this loop exactly as it would have been before this step existed. Check by hand against ${rp.base_branch}.`)
      }
    }

    // Converge ONLY when EVERY reviewer has an explicit pass/approve (freeze-once-passed).
    // A recorded blocking item is NOT a pass, and the final return below is what enforces that —
    // converging here with `blocking` non-empty still ends the repo unresolved.
    // `&& !extraMustFix.length` — never converge with must-fixes still undelivered. Every other
    // producer of one keeps its reviewer open, so this only ever fires for a carried item
    // (ADR-0027 §Across invocations): all three gates ledgered PASSED, one recorded condition, and
    // this break used to end the round before the fix pass below could hand it over — the carried
    // item evaporating one layer under the veto that was meant to save it. `extraMustFix` is
    // cleared by that pass, so the next round converges normally.
    if (reviewers.every((rv) => done[rv.key]) && !extraMustFix.length) break
    if (reviewRound >= MAX_REVIEW_ROUNDS) {
      const why = crashed.length ? `${crashed.join('+')} reviewer ERRORED (inconclusive)` : 'open findings'
      log(`⚠️ [${R}] hit MAX_REVIEW_ROUNDS (${MAX_REVIEW_ROUNDS}) with ${why}${blocking.length ? ` + ${blocking.length} recorded blocking item(s)` : ''} — NOT merge-ready; PR left open for human review.`)
      return { repo: R, status: 'review-unresolved', plan: rp, pr, reviewRound, verdict, crashed, blocking }
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
    // A converted must-fix (ADR-0027) counts as something to fix even when no reviewer raised a
    // finding this round: a suite that could not run produces zero findings BY DEFINITION, and
    // skipping the fix pass on that basis is exactly how it never got fixed.
    if (openFindings === 0 && salvaged === 0 && extraMustFix.length === 0) {
      log(`[${R}] no findings to fix — re-running inconclusive reviewer(s) next round: ${crashed.join(', ') || 'none'}.`)
      continue
    }

    // An escalated fix that landed upstream LAST round gets synced forward THIS round — named
    // explicitly, because upstreamRepairClause only fires when a reviewer verdict happens to
    // re-name the upstream, and the sync must not hang on that.
    const pendingSyncClause = pendingSync.length
      ? ` ESCALATED FIX LANDED UPSTREAM: ${pendingSync.map((s) => `${s.repo} (branch ${s.branch})`).join('; ')} now carries the fix this repo's review was blocked on. Bring THIS repo forward FIRST, exactly as the UPSTREAM SYNC steps describe (pin bump to the tip of that branch on origin when .gitmodules declares the path, else re-generate the vendored contract), commit the sync on its own, then reply on and resolve the thread(s) that finding held open.`
      : ''
    // Developer fixes the WHOLE combined batch (every open reviewer's PR comments) in ONE pass, pushing to the PR.
    const fix = await safeAgent(
      `${tag(R, desc.build, 'pr-fix', reviewRound)}${extraMustFix.length ? `\n\n${extraMustFix.join('\n\n')}\n\nTHE ABOVE IS PART OF THIS BATCH, and it comes FIRST. If any of it turns out to be genuinely unfixable here, return it in \`cannot_fix\` with its \`kind\`, the class or reason, the command + exit code (or the number) that PROVES it, and what you ruled out first — that ends the attempts on that one condition and is a legitimate result. Without evidence and \`tried\` it is refused and the attempts continue.\n\n` : ''} PR/MR review-fix batch for ${ticket} in ${R} (round ${reviewRound}) on ${rp.work_branch}, PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}). ${inRepo} Read ALL open review comments on the PR/MR (code-reviewer + guardian + performance) via \`scripts/vcs/pr-comments.sh ${pr.pr_number ?? '<number>'}\`. ${STRICT ? 'The batch is must-fixes only (review.level=strict) — there are no "[minor / fold-in]" comments to apply.' : 'The batch includes both must-fixes AND any comment prefixed "[minor / fold-in]" — those are small guardian/perf improvements to apply in THIS PR (no separate ticket); fold them in too.'} Fix the WHOLE batch in this single pass: reproduce with a failing test first where applicable (/tdd) — a mechanical fold-in may not need one — fix to green, commit (fix(…) Refs ${ticket}), and push (\`git -C ${absR} push\`). Reply on each resolved comment via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --body "<reply>"\` so the reviewers can re-check, THEN check its "Resolve thread" box: list the thread ids with \`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\`, match each unresolved thread by its file:line AND its \`[gate:review|guard|perf]\` tag to the comment you fixed, and resolve it via \`scripts/vcs/pr-resolve-thread.sh ${pr.pr_number ?? '<number>'} <thread-id>\` — resolve ONLY threads you actually addressed in this pass (leave anything still open unresolved). Ticking Resolve is part of the fix, not paperwork after it: an unresolved thread is the forge's own record that the finding is still open, the gates re-check exactly that list, and a fix you never resolved reads to every later reader — and to the next invocation of this workflow — as never done. Count the threads you resolved against the comments you fixed before you return; if the two numbers differ, you are not finished. Keep ${desc.green}.${upstreamRepairClause}${pendingSyncClause} In the returned "fixed" array, list the files/areas you changed — the reviewers use this to locate your fixes and to judge whether the fix itself introduced any regression. Set status="complete" when you resolved the whole batch, else "partial" (what's still open in "remaining"); never end without the structured handoff.` + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE,
      { agentType: desc.build, phase: 'Review', label: `pr-fix:${ticket}:${R}#${reviewRound}`, schema: DEV_SCHEMA },
    )
    // STALL DETECTOR — the same unresolved finding set, with no new commit, surviving two
    // consecutive rounds means this repo is not converging, it is repeating. Fingerprint the
    // still-open reviewers' verdicts BEFORE the fix (what this round actually had to resolve).
    const fpThisRound = stallFp(openReviewers.filter((rv) => !done[rv.key]).map((rv) => [rv.key, verdict[rv.key]]))
    if (fix) fixPasses++
    // A DECLARED "CANNOT" (ADR-0027). Accepted only with evidence AND what was ruled out first —
    // this is the one field an agent could reach for to escape hard work, so an unevidenced claim
    // is dropped and the attempts continue. Accepted, it records the condition and closes ITS
    // attempts; every other finding in this repo keeps being worked.
    for (const cf of (Array.isArray(fix?.cannot_fix) ? fix.cannot_fix : [])) {
      if (!cf?.kind || String(cf.evidence || '').trim().length < 12 || String(cf.tried || '').trim().length < 12) {
        log(`[${R}] a cannot_fix claim for "${cf?.kind ?? '?'}" was DROPPED — it carried no usable evidence/tried. Attempts on it continue.`)
        continue
      }
      record(String(cf.kind), `${cf.why} — evidence: ${cf.evidence}; already ruled out: ${cf.tried}`,
        `decide what happens to this: ${cf.why}`)
      if (cf.kind === 'suite-unverified') { attempts.suite_repair = TEST_SUITE.maxSuiteRepairAttempts; done.review = 'unverified' }
      if (cf.kind === 'regression') attempts.regression_fix = REVIEW.maxRegressionFixes
    }
    extraMustFix = []
    pendingSync = []
    lastFixed = Array.isArray(fix?.fixed) ? fix.fixed : []
    const noNewCommit = !(fix?.commits > 0)
    if (fpThisRound === lastFp && noNewCommit) stalled++; else stalled = 0
    lastFp = fpThisRound
    log(`[${R}] review-fix round ${reviewRound}: ${fix?.summary?.slice(0, 60) ?? 'done'}${lastFixed.length ? ` (scope: ${lastFixed.length})` : ''}`)
    tick(`${R}:pr-fix#${reviewRound}`)

    // CROSS-REPO ESCALATION — the fix pass proved (with evidence) that a finding's root fix lives
    // in ANOTHER repo of this run: e.g. a missing index only the migration repo can add, vendored
    // here as a guard-blocked read-only submodule. Without this route the loop can only re-confirm
    // the same gap round after round — measured: five no-commit rounds ending in the same human
    // call this block now makes explicit. TIERED: a repo of this run gets a scoped fix pass and a
    // scoped re-gate there (never-fail-open holds — un-reviewed upstream code must not ride the
    // merge train); a repo outside the run is scope the ticket never authorized, so it halts for a
    // human. ONE level deep and ONE attempt per (repo, finding): a chained or repeated escalation
    // halts too. Runs BEFORE the stall halt on purpose — an escalation round legitimately makes no
    // commit in THIS repo, and a successful escalation resets the stall counter (the loop is moving
    // again, just not here). The sync-forward happens on the NEXT fix pass via pendingSync.
    const escalations = (Array.isArray(fix?.upstream_fix_needed) ? fix.upstream_fix_needed : [])
      .filter((e) => e?.repo && e?.finding && String(e?.evidence || '').trim().length > 20)
    let escalatedOk = 0
    for (const esc of escalations) {
      const T = esc.repo
      const escKey = `${T}::${String(esc.finding).toLowerCase().replace(/\s+/g, ' ').trim().slice(0, 160)}`
      const tPlan = repoResults[T]?.plan || plans.find((p) => p.repo === T)
      // ADR-0027 — an escalation that does not land no longer ends the repo. It is RECORDED and the
      // loop carries on with this repo's other findings. `escRecord` replaces the old escHalt: same
      // information, no early return. Kept as a closure so every exit below reads the same.
      const escRecord = (summary, remaining, decision) => record('cross-repo', `${summary} — ${remaining}`, decision)
      // NOT FIXABLE BY ANY AMOUNT OF LOOPING: there is no clone, no plan and no agent that can
      // touch that repo, so this one is not a must-fix in any honest sense (ADR-0027). It stops
      // being a HALT — recorded, and the loop carries on with this repo's other findings — but the
      // repo cannot reach 'ready' while it stands, because the finding is real and unfixed.
      if (!REPOS[T] || !tPlan) {
        log(`⚠️ [${R}] CROSS-REPO FIX NEEDED IN ${T}, which is ${REPOS[T] ? 'not part of this run' : 'not a declared workspace repo'} — scope the ticket never authorized, and nothing in this run can touch it. Recording it; the loop continues here. Finding: ${String(esc.finding).slice(0, 160)}`)
        escRecord(`review finding needs new work in ${T}, outside this run's scope`, `${esc.finding} — evidence: ${esc.evidence}`, `whether to widen ${ticket} to include ${T}, ship the gap as a follow-up there, or waive the finding`)
        continue
      }
      if (left(`esc:${escKey}`, REVIEW.maxEscalationAttempts) <= 0) {
        log(`⚠️ [${R}] cross-repo escalation to ${T} EXHAUSTED (${REVIEW.maxEscalationAttempts} attempt(s)) for the same finding — recording it rather than ping-ponging; the loop continues here.`)
        escRecord(`escalated fix in ${T} did not settle the finding after ${REVIEW.maxEscalationAttempts} attempt(s)`, `${esc.finding} — a scoped fix pass ran in ${T} this run and the finding is still open here`, `whether the ${T} fix actually addresses the finding, or the finding should be waived / re-scoped`)
        continue
      }
      if (!repoResults[T] && !doneAt(T, 'reviewed')) {
        log(`[${R}] cross-repo escalation to ${T} deferred — its own pipeline is still in flight this run; re-checking next round rather than racing its build agent on the same clone.`)
        continue
      }
      // Never route a fix into a repo that LEFT the run. An `already-satisfied` target has no branch
      // and no PR/MR, so a fix pass there would create both — commits and an open PR/MR in a repo
      // every ship phase has already filtered out, which merges nothing and tells nobody.
      if (repoResults[T]?.status === 'already-satisfied') {
        log(`⚠️ [${R}] cross-repo escalation to ${T} REFUSED — ${T} needed no change for ${ticket} (verified already satisfied) and has left the run with no branch and no PR/MR. Recording it: a fix there is work on shipped code, which is a person's call, not this run's.`)
        escRecord(`the escalation target ${T} needed no change for ${ticket} and left the run`, `${esc.finding} — ${T} has no branch or PR/MR this run, so there is nothing here to land the fix on`, `whether ${T}'s already-shipped code is genuinely wrong, and whether this ticket absorbs that fix or a new one does`)
        continue
      }
      spend(`esc:${escKey}`)
      const tDesc = REPOS[T]
      const tBranch = tPlan.work_branch || `${branchKind}/${ticket}`
      const tBase = tPlan.base_branch || tDesc.base[branchKind]
      const tRow = rowAt(T, 'pr_open')
      const tPr = repoResults[T]?.pr || (tRow ? { pr_number: tRow.pr_number, pr_url: tRow.pr_url } : null)
      log(`[${R}] CROSS-REPO ESCALATION → ${T} (round ${reviewRound} budget): ${String(esc.finding).slice(0, 140)}`)
      const tFix = await safeAgent(
        `${tag(T, tDesc.build, 'xrepo-fix', reviewRound)} Scoped cross-repo fix for ${ticket} in ${T}, escalated from the ${R} review with evidence. THE ONE FINDING to implement — nothing else, no drive-by cleanups, no other threads: ${esc.finding} Evidence from the escalating repo: ${esc.evidence} ${shellClauseFor(T)} Get on the ticket branch first: \`git -C ${absOf(T)} fetch origin\`; if ${tBranch} exists on origin, switch to it (tracking origin) with \`git -C ${absOf(T)} switch ${tBranch}\`, else \`git -C ${absOf(T)} switch -c ${tBranch} origin/${tBase}\`. Implement ONLY this finding in this repo's own idiom (read its CLAUDE.md and docs/adr/ first), commit conventionally (\`fix(${ticket}): <what> Refs ${ticket}\`), keep ${tDesc.green}, and push. THE PR/MR: ${tPr ? `this run opened ${tPr.pr_url} (number ${tPr.pr_number ?? '?'}) for this repo — if it is still OPEN, your push lands on it and you are done; if it already MERGED, open a follow-up PR/MR for ${tBranch} → ${tBase} via \`scripts/vcs/open-pr.sh\`` : `no PR/MR is recorded for this repo this run — open one for ${tBranch} → ${tBase} via \`scripts/vcs/open-pr.sh\``}. ONE LEVEL ONLY: if this fix itself turns out to need work in yet ANOTHER repo, do NOT recurse and do NOT declare upstream_fix_needed — return status="blocked" with that repo and your evidence in "remaining"; a chained escalation is a human call. Return the DEV_SCHEMA handoff: status="complete" ONLY when the finding is implemented and this repo is green.` + BUILD_DISCIPLINE + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + stateWrite(T, 'built'),
        { agentType: tDesc.build, phase: 'Review', label: `xrepo-fix:${ticket}:${T}#${reviewRound}`, schema: DEV_SCHEMA },
      )
      if (!tFix || tFix.status !== 'complete') {
        log(`⚠️ [${R}] escalated fix pass in ${T} did not complete (${tFix?.status ?? 'no handoff'}) — attempt ${attempts[`esc:${escKey}`]}/${REVIEW.maxEscalationAttempts}; the loop continues here and retries next round if budget remains. ${String(tFix?.remaining || '').slice(0, 200)}`)
        escRecord(`escalated fix in ${T} did not complete`, tFix?.remaining || 'the routed fix pass returned no structured handoff', tFix?.decision_needed || `whether ${T} can actually absorb this fix for ${ticket}, and who lands it`)
        continue
      }
      // SCOPED RE-GATE — the escalated commits are new, un-reviewed code on a branch this run
      // already reviewed once, so they get their own gate before anything syncs them forward:
      // code gate only, scoped to the fix diff, suite green required (never fail open). Approval
      // refreshes the repo's 'reviewed' checkpoint so a resume does not degrade it.
      if (tDesc.review) {
        const tGate = await safeAgent(
          `${tag(T, tDesc.review, 'xrepo-regate', reviewRound)} ${levelDirective} SCOPED re-gate of a cross-repo fix for ${ticket} in ${T} — NOT a fresh full review; this run already reviewed this repo once. Since then exactly one escalated fix landed on ${tBranch}, for this finding from the ${R} review: ${esc.finding} ${shellClauseFor(T)} Judge ONLY the new commits (\`git -C ${absOf(T)} fetch origin\` then read the fix commits on ${tBranch}; the fix agent reports its files as: ${(Array.isArray(tFix.fixed) ? tFix.fixed : []).join(', ') || `unreported — locate them from the latest fix(${ticket}) commits`}): does the diff genuinely implement the finding, in this repo's idiom, with no collateral change beyond it? Post any must-fix inline on the PR/MR as usual. ${greenGateFor(T, tBranch)} Return approved:true ONLY when the fix meets the finding AND tests_green is true.${NO_SELF_APPROVE}` + VERDICT_BEFORE_BUDGET + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE + stateWrite(T, 'reviewed') + ` Write that RUN-STATE file ONLY if your verdict is approved:true with tests_green:true — an unapproved re-gate must NOT refresh the reviewed checkpoint.`,
          { agentType: tDesc.review, phase: 'Review', label: `xrepo-regate:${ticket}:${T}#${reviewRound}`, schema: REVIEW_SCHEMA },
        )
        if (!(tGate?.approved === true && tGate?.tests_green === true)) {
          log(`⛔ [${R}] scoped re-gate in ${T} did not approve the escalated fix (approved=${tGate?.approved ?? 'no verdict'}, tests_green=${tGate?.tests_green ?? '?'}) — halting for a human; nothing syncs forward un-reviewed.`)
          escRecord(`escalated fix in ${T} failed its scoped re-gate`, tGate?.conclusion || tGate?.unavailable_reason || 'the re-gate returned no verdict', `whether the ${T} fix is genuinely wrong, or the gate needs a human re-run there`)
          continue
        }
      } else {
        log(`[${R}] ${T} declares no code reviewer — the escalated fix rides to the cross-repo test-suite gate, same as that repo's own pipeline.`)
      }
      pendingSync.push({ repo: T, branch: tBranch })
      escalatedOk++
      log(`✅ [${R}] escalated fix landed and re-gated in ${T} (${tBranch}) — next fix pass here syncs it forward and resolves the blocked thread(s).`)
    }
    if (escalatedOk) stalled = 0

    // REVIEW STALL — the same unresolved finding set survived a fix round that produced no commit.
    // This used to halt, and the reason was sound: repeating an identical attempt is not progress,
    // and five no-commit rounds were measured ending in the same human call. So it does not halt
    // (ADR-0027) and it does not simply repeat either — it ESCALATES THE ATTEMPT. The next brief
    // names what did not move and treats the previous read as a hypothesis to disprove. Same
    // posture change the test-suite gate makes on a repeated failure signature, for the same
    // reason: change the attempt, not just the count.
    if (stalled >= 1) {
      if (left('stall_reattempt', REVIEW.maxStallReattempts) <= 0) {
        record('stalled', `the same unresolved finding set survived ${REVIEW.maxStallReattempts} escalated re-attempt(s) with no new commit on ${rp.work_branch}: ${openReviewers.filter((rv) => !done[rv.key]).map((rv) => rv.key).join('+') || 'unknown'}`,
          `read the open threads on ${pr.pr_url} — the loop could not move this finding set, so a person has to judge whether the finding or the approach is the thing that is wrong`)
        stalled = 0   // recorded once; do not re-enter this branch every remaining round
      } else {
        spend('stall_reattempt')
        stalled = 0
        log(`⚠️ [${R}] REVIEW STALLED at round ${reviewRound} — escalating the next attempt (${attempts.stall_reattempt}/${REVIEW.maxStallReattempts}) rather than repeating it.`)
        extraMustFix.push(`⛔ THE LAST ROUND MOVED NOTHING — the same finding set is still open and your last pass produced no commit. Repeating it is not an option: do something DIFFERENT this round.
STILL OPEN: ${openReviewers.filter((rv) => !done[rv.key]).map((rv) => rv.key).join(', ') || '(see the threads)'} on ${pr.pr_url}.
Treat your own previous reading of these findings as a HYPOTHESIS TO DISPROVE, not as settled. Re-read the actual threads on the PR/MR rather than your memory of them, and say in your summary which ones you re-read and what you had misread.
If you produced no commit because you believe there is nothing to change, that is a claim about the FINDING, not about the code: reply ON ITS THREAD saying which finding you dispute and why. An answered thread is a real outcome; silence reads as a stall to this loop and always will.`)
      }
    }
  }

  // A `Human:` DIRECTIVE IS SETTLED ONLY WHEN ITS THREAD IS. The reviewers' pass asserts nothing
  // about it — no gate OWNS a thread a person opened, and the developer's word for "fixed" is not
  // the forge's record. So when this repo entered the loop because of a directive (or because the
  // probe went blind), read the threads back ONCE at the end and RECORD whatever is still open:
  // `blocking` non-empty is what the guard below turns into `review-unresolved`, which is the only
  // honest ending for a PR/MR still carrying a person's unanswered instruction. Recording rather
  // than halting is ADR-0027's shape, so the rest of this run's work is not thrown away.
  if ((humanDirectives.length || humanProbeBlind) && pr?.pr_number) {
    const hv = await safeAgent(
      `${tag(R, 'tracker', 'human-verify')} READ THE FORGE, WRITE NOTHING — no code, no comment, no thread resolution. ${inRepo} This run worked ${ticket}'s PR/MR ${pr.pr_number} in ${R} because it carried unresolved \`Human:\` directive(s)${humanDirectives.length ? ` (thread ids: ${humanDirectives.map((d) => d.thread_id).join(', ')})` : ' — or because the earlier probe could not read them'}. The reviewers have now converged, so confirm the ONE thing their pass does not: is every \`Human:\` directive thread actually RESOLVED on the forge now? Run \`scripts/vcs/pr-threads.sh ${pr.pr_number}\` (bare, no pipe) and return the command in \`command\`. Apply the SAME definition as before — a directive is a thread still \`[unresolved]\` whose FIRST comment's first line starts with \`Human:\`; a \`Human:\` reply inside an agent's own thread is a disposition and is not one; a resolved thread is done whoever resolved it. Return the ones STILL open in \`directives\` (thread_id, location, body verbatim, first 400 chars) — an empty array meaning every directive is settled, which is the outcome this run was working toward. If you cannot read the threads, \`blind: true\` + \`note\`.` +
        ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
      { agentType: 'developer', model: 'haiku', phase: 'Review', label: `human-verify:${ticket}:${R}`, schema: HUMAN_DIRECTIVE_PROBE_SCHEMA },
    )
    const stillOpen = (hv?.directives || []).filter((d) => d && d.thread_id)
    if (!hv || hv.blind === true) {
      record('human-review', `PR/MR ${pr.pr_number} was worked for \`Human:\` review comment(s) and this run could NOT read the threads back, so it cannot say whether they are resolved${hv?.note ? ` (${String(hv.note).slice(0, 160)})` : ''}`, `read the \`Human:\` threads on PR/MR ${pr.pr_number} yourself and either resolve them or say what is still needed — the run will not claim a directive is settled it could not see`)
    } else if (stillOpen.length) {
      stillOpen.forEach((d) => record('human-review', `an unresolved \`Human:\` directive is still open on PR/MR ${pr.pr_number} — thread ${d.thread_id}${d.location ? ` at ${d.location}` : ''}: ${String(d.body).slice(0, 240)}`, `answer or narrow the directive on thread ${d.thread_id} (a reply from you resolves it), or resolve the thread if the fix already landed`))
    } else {
      log(`[${R}] every \`Human:\` directive on PR/MR ${pr.pr_number} is resolved on the forge — the repo may proceed.`)
    }
  }

  // THE FAIL-OPEN GUARD (docs/adr/0027). Every reviewer converged — but a recorded blocking item
  // means something this run could not verify or could not fix, and a repo in that state must not
  // read as merge-ready. This one line is what keeps "the loop does not halt" from turning into
  // "the loop passes anything".
  if (blocking.length) {
    log(`⚠️ [${R}] every reviewer converged, but ${blocking.length} blocking item(s) stand — NOT merge-ready: ${blocking.map((b) => b.kind).join(', ')}. PR/MR left open.`)
    return { repo: R, status: 'review-unresolved', plan: rp, pr, reviewRound, verdict, crashed: [], blocking, handoff: { status: 'blocked', summary: `${blocking.length} blocking item(s) the review loop could not close`, remaining: blocking.map((b) => `${b.kind}: ${b.detail}`).join(' | '), decision_needed: blocking.map((b) => b.human_action).filter(Boolean).join(' | ') || 'whether to accept these as-is, fix them by hand, or widen the ticket' } }
  }
  return { repo: R, status: 'ready', plan: rp, pr, reviewRound, verdict, blocking, gatesUnavailable: gatesUnavail, deferred: deferredScope, met_acceptance: dev.met_acceptance || [], build: { summary:dev.summary, fixed: Array.isArray(dev.fixed) ? dev.fixed : [] } }
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
    // How many times this ticket has been run through dev-cycle, THIS invocation included. Counted
    // from the per-invocation summaries on disk, so it survives a resume and needs no state of its
    // own. It exists because "r<n>" was previously left for each agent to invent: the test-report's
    // run stamp is the only thing separating this run's result from the last one's, and the audit
    // records a gate as NOT RUN when it does not match — which it did, repeatedly.
    invocations_before: { type: ['number', 'null'] },
    rows: {
      type: 'array', items: {
        type: 'object', additionalProperties: false,
        required: ['repo', 'milestone', 'status'],
        properties: {
          repo: { type: 'string' },                // a REPOS key, or "all" for a run-level row
          // gate_review | gate_guard | gate_perf are the REVIEW LEDGER rows (docs/adr/0021):
          // one per repo per gate, carrying first_pass and whether that gate passed.
          // `blocked` is the ONE row that is not a proof of progress but a proof of the opposite:
          // what a previous invocation recorded and could not close (ADR-0027 §Across invocations).
          milestone: { type: 'string', enum: ['planned', 'built', 'pr_open', 'gate_review', 'gate_guard', 'gate_perf', 'reviewed', 'test_suite', 'blocked', 'merged', 'distributed', 'artifact_published', 'notified', 'dm_sent'] },
          status: { type: 'string', enum: ['done', 'in-progress'] },
          work_branch: { type: ['string', 'null'] },
          head_sha: { type: ['string', 'null'] },   // the sha recorded WHEN the milestone landed
          live_sha: { type: ['string', 'null'] },   // what the branch points at NOW
          pr_number: { type: ['number', 'string', 'null'] },
          pr_url: { type: ['string', 'null'] },
          recorded_at: { type: ['string', 'null'] },
          ticket_fp: { type: ['string', 'null'] },  // C10 — the ticket fingerprint AT PLAN TIME
          plan_path: { type: ['string', 'null'] },  // C10 — the plan markdown this row points at
          plan_bytes: { type: ['number', 'null'] }, // C10 — filled by the LOADER: wc -c of plan_path (0/null ⇒ gone)
          // ADR-0025 — the base this repo was PLANNED against. Authoritative on resume: an
          // invocation that omits the override flag adopts this rather than reverting to a default.
          base_branch: { type: ['string', 'null'] },
          // ADR-0025 — on a `built` row, the sha256 of the plan the build was made FROM. `built`'s
          // only other proof is the branch head, and a re-plan does not move the head, so a build
          // stayed "proven" against a plan nobody had ever built. This is TICKET_FP one link down.
          plan_sha: { type: ['string', 'null'] },
          title: { type: ['string', 'null'] },      // C10 — rehydrates prTitle() on a skip
          acceptance: { type: 'array', items: { type: 'string' } }, // C10 — rehydrates the reviewers' BAR
          // C10 — rehydrates the BUILD ORDER. A pin a later invocation cannot see is a pin that
          // orders nothing, and the downstream quietly goes back to the merged base it could not
          // test against.
          submodule_pins: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['repo', 'path'], properties: { repo: { type: 'string' }, path: { type: 'string' } } } },
          artifact_url: { type: ['string', 'null'] }, // C11 — the published plan page for this repo
          degraded: { type: 'boolean' },            // proof no longer holds → NOT skippable
          first_pass: { type: ['boolean', 'null'] }, // gate_* rows — this gate completed its ONE full review
          run_status: { type: ['string', 'null'] }, // dm_sent rows — the runStatus this DM already covered
          // `blocked` rows — the items a previous invocation recorded. A row with items and
          // status 'done' is what makes a blocking item OUTLIVE its run; the same file rewritten
          // with status 'in-progress' and an empty list is how a later clean run clears it, since
          // a workflow script cannot delete a file.
          blocking: {
            type: 'array', items: {
              type: 'object', additionalProperties: false,
              properties: { kind: { type: 'string' }, detail: { type: 'string' }, human_action: { type: ['string', 'null'] } },
            },
          },
        },
      },
    },
  },
}
const runState = await safeAgent(
  `${tag('all', 'general-purpose', 'run-state')} READ ONLY — write nothing, touch no git branch, run no tests. Load this run's checkpoint for ${ticket} and validate it against the live branches.
1. \`ls agent_logs/${ticket}-dev-cycle-state/*.json\` from your cwd (the workspace root). ONE FILE PER CHECKPOINT (not one shared file), named \`<repo>-<milestone>.json\`. If the directory does not exist or is empty, return found:false with rows:[] — that is the normal first-invocation answer, not an error.
2. \`cat\` each file and parse it as one JSON object. A file that fails to parse is DISCARDED with no attempt to repair it. There is no duplicate-row question here — each (repo, milestone) has its own path, so nothing to dedupe.
3. For every row carrying a work_branch AND a milestone OTHER than "planned", resolve what that branch points at NOW, using the repo dir from this map (do NOT cd; use git -C): ${Object.entries(REPOS).map(([id, d]) => `${id}=${d.path}`).join(', ')}. Run \`git -C <that dir> rev-parse --verify <work_branch>\` and put the result in live_sha (null when the branch does not exist). For a "planned" row, ALSO measure the plan markdown it points at: \`wc -c < "<plan_path>"\` and put the byte count in plan_bytes (0 when the file is missing or unreadable — never guess a size, and never create the file).
4. DEGRADE mechanically, by what each milestone's proof actually IS. For every milestone EXCEPT "planned": set degraded:true AND status:"in-progress" on any row whose live_sha is null or differs from its recorded head_sha — a moved head means the milestone is no longer proven, full stop. For a "planned" row the proof is the PLAN FILE, not the branch head (commits landing on a work branch are the build doing its job and do not invalidate the plan that produced them): set degraded:true AND status:"in-progress" when plan_bytes is 0/absent or the row carries no plan_path, and otherwise leave degraded:false — do NOT compare its head_sha to live_sha at all. ALSO on a "planned" row whose plan_path exists, fill plan_sha with \`shasum -a 256 <plan_path> | cut -c1-16\` — the LIVE plan's fingerprint, so the run can tell a build made from THIS plan from one made before it was rewritten. Leave plan_sha untouched on every other row: on a "built" row it is what the build agent recorded, and overwriting it destroys the comparison. The gate_* rows (the review ledger), the test_suite row, and the notified/dm_sent rows are a THIRD proof class and are NEVER degraded: their proof is the gate's own recorded verdict (or, for notified/dm_sent, the fact that the send already happened) plus whatever the gate left on the PR/MR — not a branch head. Leave them degraded:false even when live_sha is null (notified/dm_sent rows carry no work_branch at all — do not expect one), and never compare their head_sha (it is an audit trail, not a claim about the branch NOW) — a passed gate stays passed, which is deliberate (docs/adr/0021), not an oversight for you to correct. Do not reason about whether a difference matters; apply exactly these two rules.
5. COUNT THE PRIOR INVOCATIONS: \`ls agent_logs/${ticket}-DEV-CYCLE-SUMMARY-r*.md 2>/dev/null | wc -l\` and return that number as invocations_before (0 when the glob matches nothing — do not report the literal unexpanded pattern as a file). It is how this run learns its own ordinal.
6. Return every row you parsed, degraded flags applied, plus found and the directory path. Add nothing, invent nothing, and never fabricate a head_sha you did not read from a file.` + CAVEMAN_DIRECTIVE,
  { agentType: 'general-purpose', model: 'haiku', phase: 'Scope', label: `run-state:${ticket}`, schema: RUN_STATE_SCHEMA },
)
const stateRows = runState?.rows || []
// This invocation's ordinal, computed ONCE and threaded everywhere an agent used to guess it
// (the test-report run stamp, the per-invocation summary filename, the durable-record ledgers).
const RUN_SEQ = Math.max(1, Number(runState?.invocations_before || 0) + 1)
// The ONE predicate every gate below reads. A degraded row is not done.
const doneAt = (repo, milestone) => stateRows.some((r) => r.repo === repo && r.milestone === milestone && r.status === 'done' && r.degraded !== true)
const rowAt = (repo, milestone) => stateRows.find((r) => r.repo === repo && r.milestone === milestone && r.status === 'done' && r.degraded !== true)
// ADR-0027 §Across invocations. A `blocked` row rewritten with status 'in-progress' and an empty
// list is how a clean run CLEARS one — `rowAt` already ignores it, which is the whole reason the
// clear is a rewrite rather than a delete a workflow script could not perform.
const carriedBlocking = (repo) => (rowAt(repo, 'blocked')?.blocking || []).filter((b) => b && b.kind)
if (stateRows.length) log(`[run-state] ${stateRows.length} row(s) loaded${runState?.found === false ? '' : ` from ${runState?.path || `agent_logs/${ticket}-dev-cycle-state.json`}`}; skippable: ${stateRows.filter((r) => r.status === 'done' && r.degraded !== true).map((r) => `${r.repo}:${r.milestone}`).join(', ') || 'none'}; degraded: ${stateRows.filter((r) => r.degraded).map((r) => `${r.repo}:${r.milestone}`).join(', ') || 'none'}.`)

// 1. SCOPE — which repos does this ticket touch, and in what dependency order?
phase('Scope')
// The repo(s) that PROVIDE the cross-repo test-suite (QA) gate — injected into the scope
// prompt so the cto knows which repo must be scoped for the gate to run at all.
const testSuiteRepoIds = Object.keys(REPOS).filter((id) => REPOS[id].testSuite)
let scope = await safeAgent(
  `${tag('all', 'cto', 'scope')} You are the scoping stage for ${ticket}. Read the ticket via the tracker adapter (\`scripts/tracker/get-ticket-details.sh ${ticket}\`, + \`get-ticket-comments.sh\`) and decide which of the workspace's repos it requires changes in: ${Object.keys(REPOS).join(', ')} (only these are registered). For each touched repo return { repo, depends_on (other touched repo ids that must be built/merged first — typically a backend → app → test-suite order), summary (what that repo must change) }. The registered cross-repo test-suite (QA) repo(s) are: ${testSuiteRepoIds.length ? testSuiteRepoIds.join(', ') : 'none'}. When this change should be validated end-to-end by the cross-repo test suite (E2E / API / load) against the candidate build, set test_suite.needed:true AND include that test-suite repo in \`repos\`, with depends_on listing the app/service repos it validates (so it builds + merges LAST). The gate CANNOT run unless the test-suite repo is in \`repos\` — needed:true on its own does nothing. If no test-suite repo is registered, leave needed:false. Most tickets touch only the app repo; when they also need end-to-end validation, return the app repo PLUS the test-suite repo. Also set tracker_reachable: true ONLY if the adapter actually returned the live ticket this call — set it false if the tracker was unreachable and you proceeded from inline/contextual info (the run then loudly flags that Status moves, comments, and improvement tickets did NOT persist).
OUT OF REACH — read the ticket's acceptance criteria one by one and ask of each: can ANY repo registered above satisfy it? List in \`out_of_reach\` only those that cannot be satisfied here BY CONSTRUCTION — the owner is a repo this workspace does not hold (gateway/infra config, a third party's system), or the work needs an access only a person has (a dashboard, a certificate, a production credential). Quote the criterion, say concretely why, and name who CAN do it. Judge reachability, NOT difficulty: a criterion that is merely hard, or whose real obstacle only appears once someone reads the code, is NOT out of reach — the build will discover those and hand back \`deferred\`, which gets adjudicated then. An empty list is the normal, healthy answer, and a criterion you are unsure about belongs OUT of the list. Then set \`deliverable_now\`: true if at least ONE acceptance criterion remains reachable here, false ONLY if the ticket asks for nothing this workspace can deliver — false STOPS the run immediately, before any branch or plan exists, so do not use it to express that a ticket is partly blocked. Also return, for the run's ticket-change fingerprint: \`title\` (the ticket's title verbatim) and \`acceptance\` (every acceptance criterion of the ticket, copied VERBATIM, one array element per criterion, in the order they appear — this is the same list you just walked for out_of_reach, so copy it rather than re-deriving it). Copy, do not paraphrase, summarize, re-order or renumber: a later invocation compares this text to decide whether the ticket changed, so a rewording you invent reads as a human edit and costs a full re-plan. Return the structured scope.`,
  { agentType: 'cto', phase: 'Scope', label: `scope:${ticket}`, schema: SCOPE_SCHEMA },
)
// A THROW is the worst ending this workflow has: no summary, no run-state, no record, no DM — the
// operator gets a stack trace and the next invocation starts from nothing. And the cause is usually
// one non-converging agent, which is the cheapest thing in the run to ask twice. So: one bounded
// retry that says what went wrong, then a graceful, reported stop.
let scopeAttempt = scope
if (!scopeAttempt) {
  log('⚠️ [scope] the scoping stage did not return a structured result — retrying ONCE, bounded (decide from the ticket, do not investigate).')
  scopeAttempt = await safeAgent(
    `${tag('all', 'cto', 'scope', 1)} Your scoping pass for ${ticket} did not return a structured result — you likely kept investigating instead of answering. STOP investigating now. Read the ticket ONCE via \`scripts/tracker/get-ticket-details.sh ${ticket}\` and answer from it. The registered repos are: ${Object.keys(REPOS).join(', ')} — only these, and the registered cross-repo test-suite repo(s) are ${testSuiteRepoIds.length ? testSuiteRepoIds.join(', ') : 'none'}. Returning the structured scope IS the task: for each touched repo { repo, depends_on, summary }, plus test_suite.needed, tracker_reachable, out_of_reach (\`[]\` is the normal answer), deliverable_now, and \`title\` + \`acceptance\` copied VERBATIM from the ticket. If you genuinely cannot tell which repos a criterion touches, put the ticket's single most obvious repo in \`repos\` and say so in its \`summary\` — a scope that is roughly right is worth infinitely more to this run than no scope at all. Emit it immediately.`,
    { agentType: 'cto', model: 'opus', effort: 'high', phase: 'Scope', label: `scope-retry:${ticket}`, schema: SCOPE_SCHEMA },
  )
}
if (!scopeAttempt) {
  log(`⛔ [scope] the scoping stage did not converge for ${ticket} after 2 attempts — nothing is known about which repos this ticket touches, so no branch, plan or build can be started. Stopping with a report rather than a stack trace.`)
  const summary = await writeSummary('scope-unresolved', { ticket, attempts: 2, decision_needed: `which repos ${ticket} touches — the scoping stage returned no structured result twice. Name them (or narrow the ticket) and re-run; nothing was branched, planned or written.` })
  return { ticket, status: 'scope-unresolved', decision_needed: `${ticket} could not be scoped: the scoping stage returned no structured result in 2 attempts, so the run does not know which repos it touches. Nothing was branched, planned, opened or written. Say which repos it touches — or split the ticket — and re-run.`, summary, spend }
}
scope = scopeAttempt
trackerReachable = scope.tracker_reachable !== false
if (!trackerReachable) log('⚠️ TRACKER UNREACHABLE — ticket Status moves, comments, and /clarifying-ticket improvement tickets will NOT persist this run; all ticket-tracking is best-effort. Flagged in the run result + summary.')
const scoped = (scope.repos || []).filter((r) => REPOS[r.repo])
if (!scoped.length) {
  // Same reasoning as the retry above: a report beats a stack trace. This one is not worth a second
  // agent, though — the scope CONVERGED, it just named repos this workspace does not register, which
  // is a fact about the registry or the ticket that no re-ask changes.
  log(`⛔ [scope] the scoping stage named no REGISTERED repo for ${ticket} (it returned: ${JSON.stringify(scope.repos)}; registered: ${Object.keys(REPOS).join(', ')}). Nothing can be branched or planned.`)
  const summary = await writeSummary('scope-unresolved', { ticket, returned: scope.repos, registered: Object.keys(REPOS), decision_needed: 'whether the ticket belongs to a repo this workspace does not hold, or the repo registry is missing one' })
  return { ticket, status: 'scope-unresolved', decision_needed: `${ticket} was scoped to repos this workspace does not register (${JSON.stringify(scope.repos)}); the registered set is ${Object.keys(REPOS).join(', ')}. Either the ticket belongs elsewhere, or a repo is missing from products[].repos[] in workspace.config.yaml. Nothing was branched, planned or written.`, summary, spend }
}
// OUT-OF-REACH criteria, settled once for the whole run. Every later phase reads THIS list rather
// than re-deciding what is reachable: a build deferral that matches an entry here is already
// adjudicated, and only a deferral scope did not foresee pays for a verifier.
const outOfReach = (scope.out_of_reach || []).filter((o) => o?.criterion)
const outOfReachBrief = outOfReach.length
  ? ` OUT OF REACH, already settled for this run — do NOT re-argue these and do NOT try to satisfy them: ${outOfReach.map((o, i) => `(${i + 1}) "${o.criterion}" — ${o.why} [owner: ${o.owner}]`).join(' ')} A criterion on this list that your slice cannot meet is EXPECTED; report it in \`deferred\` and move on.`
  : ''
if (outOfReach.length) log(`[scope] ${outOfReach.length} acceptance criterion/criteria declared OUT OF REACH for this workspace: ${outOfReach.map((o) => o.owner).join(', ')} — the run proceeds on what IS reachable.`)

// C2 — UPSTREAM DEGRADE. A repo's `built`/`reviewed` proof is about its OWN head, so the
// existing rule keeps a downstream row 'done' while the upstream it was built against has
// moved — the measured failure: the DB repo's head moved, the service repo's build (which
// carries the submodule-pin clause) was skipped, and the reviewer read a stale vendored
// schema. Applied to a FIXPOINT so a chain (db → svc → e2e) propagates in one pass. What it
// degrades — and why the gate rows are in that list while `pr_open` is not — is on degradeRows().
const declaredUpstreams = {}
scoped.forEach((r) => { declaredUpstreams[r.repo] = (r.depends_on || []).filter((u) => REPOS[u] && u !== r.repo) })
const rowMoved = (repo, milestone) => stateRows.some((r) =>
  r.repo === repo && r.milestone === milestone && (r.degraded === true || r.status !== 'done'))
// `milestones` is a parameter rather than a constant because a base change invalidates the PLAN
// too, not just what was built from it (docs/adr/0025) — the default is the moved-upstream case.
//
// The gate_* rows are in the DEFAULT, not just the base-change list, and that is the whole point
// of C2: degrading `built`+`reviewed` alone bought nothing. The review skip at the top of
// reviewRepo() is an OR — `doneAt(R,'reviewed') || reviewers.every(done)` — so a downstream repo
// whose upstream moved re-BUILT (re-pinned the submodule, re-vendored the generated client) and
// then took the second arm, logging "every gate is ledgered PASSED" over a diff nobody read. That
// re-pin diff is exactly where upstream contract drift becomes a downstream bug, and the earlier
// invocation's approve tick still stood on the PR/MR, so it merged looking reviewed.
// This does NOT re-derive a finding set (docs/adr/0021 holds): the row on disk keeps
// `first_pass:true`, and the ledger check reads that field alone — no status/degraded test — so the
// gate comes back as RE-VISIT, scoped to the new commits, never a second first review.
// `pr_open` is deliberately NOT here. A moved upstream head does not change this repo's base, the
// work branch is unchanged and its PR/MR is still open — the push lands on it. A `pr_open` row
// proves a head sha rather than an MR identity, so degrading it would let a resume open a SECOND
// MR for the same branch. Only a base change (docs/adr/0025) genuinely mis-targets the PR/MR.
const degradeRows = (repo, why, milestones = ['built', 'reviewed', 'gate_review', 'gate_guard', 'gate_perf']) => {
  let hit = 0
  stateRows.forEach((r) => {
    if (r.repo !== repo) return
    if (!milestones.includes(r.milestone)) return
    if (r.degraded === true || r.status !== 'done') return
    r.degraded = true; r.status = 'in-progress'; hit++
  })
  if (hit) log(`[run-state] ${repo}: ${hit} row(s) DEGRADED — ${why}. This repo re-does that work rather than resuming against a proof that no longer holds.`)
  return hit
}
let degradePass = 0
while (degradePass++ < Object.keys(declaredUpstreams).length + 1) {
  let changed = 0
  for (const id of Object.keys(declaredUpstreams)) {
    const moved = declaredUpstreams[id].filter((u) => rowMoved(u, 'built') || rowMoved(u, 'reviewed'))
    if (moved.length) changed += degradeRows(id, `declared upstream ${moved.join(' + ')} is no longer proven at its recorded head`)
  }
  if (!changed) break
}

// TICKET FINGERPRINT (C10) — "did anything a human would call a real edit happen since this repo
// was last planned", from what Scope ALREADY read. Normalize first (whitespace collapsed, cased
// down) so a transcription wobble is not an edit, then hash with djb2 — a workflow has no crypto
// and no filesystem, so this is a stable string reduction, not a checksum of the ticket.
// ponytail: a transcription hash, not byte equality. The tracker adapter exposes NO `updated`
// timestamp on any provider (checked: scripts/tracker/{jira,notion,linear}/impl.sh + jira.jq's
// issue_details_text emit none), so there is nothing cheaper and more correct to prefer. The day
// get-ticket-details.sh prints one, replace the whole hash with that field.
const fpNorm = (s) => String(s ?? '').replace(/\s+/g, ' ').trim().toLowerCase()
const fpHash = (s) => { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; return h.toString(16) }
const TICKET_FP = fpHash([fpNorm(scope.title), ...(scope.acceptance || []).map(fpNorm)].join('|'))
log(`[scope] ticket fingerprint fp=${TICKET_FP} (title + ${(scope.acceptance || []).length} acceptance criterion/criteria; comments deliberately excluded — this run posts its own) — a Kickoff already recorded under this fp is skippable.`)
const testSuiteRequested = scope.test_suite?.needed === true
// A flagged test-suite gate is only RUNNABLE if the test-suite repo is in the built set
// (its qa-planner/qa-runner author + build the specs the gate runs). The scope agent can
// flag needed without listing the repo — reconcile here so the gate can never be silently
// requested-but-skipped.
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
if (overBudget()) return await budgetStop('Kickoff', { ticket, repos: scoped.map((r) => r.repo), testSuiteRequested })
phase('Kickoff')
await moveTicket(['in_progress'], 'kickoff started', 'Kickoff')
const branchKind = scope.type === 'bug' ? 'fix' : 'feature' // polish rides the feature flow

// ── Per-repo plan artifacts MUST land under their repo clone, NOT the workspace root ──
// The workflow engine runs every agent with cwd = the workspace (org) root and agent() exposes
// NO cwd override, so we cannot rely on a planner voluntarily cd-ing into its repo before it
// writes a bare `agent_logs/...` path — some do, some don't (seen in practice: two planners dumped their
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
3. Record the RUN MARKER for the orchestrator guard. First read your own session id: run \`printf '%s\\n' "$CLAUDE_CODE_SESSION_ID"\` (a plain env read — it is not a secret and not a .env file) and use EXACTLY what it prints. Then, with the Write tool, write \`agent_logs/${ticket}-dev-cycle-state/orchestrator-guard.json\` containing exactly {"session_id":"<what that printed>","ticket":"${ticket}","armed":true,"run_state":"running","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"} — replacing any file already there. armed:true from the start is deliberate: this file scopes an existing Write/Edit restriction to the ONE session that launched the run, for as long as the run lasts, so that session keeps orchestrating instead of implementing (docs/adr/0019) rather than only being held to that after the run ends. It grants nothing to anyone and changes no other session's permissions. Return workspace_root as your result; if the env var printed nothing, write the file with "session_id":"" and say so in your result — the guard then stays inert rather than blocking the wrong session.
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
const plannedRow = (id) => rowAt(id, 'planned')
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
    baseBranch: BASE_OVERRIDE || (branchKind === 'feature' && (!FEATURE_BASE_REPOS.length || FEATURE_BASE_REPOS.includes(r.repo)) ? FEATURE_BASE_OVERRIDE : null) || desc.base[branchKind],
    workBranch: `${branchKind}/${ticket}`,
    planPath: repoRoot ? `${repoRoot}/${planRel}` : planRel,
    planHtmlPath: repoRoot ? `${repoRoot}/${planHtmlRel}` : planHtmlRel,
  }
}

// ──────────────────────────────────────────────────────────────────────────
// THE RUN'S BASE IS STATE (docs/adr/0025)
//
// Resolution above is per-INVOCATION: it reads this invocation's flags. That made a base an
// argument rather than a fact of the run, so a resume that omitted the flag silently reverted
// every repo to its default — measured across seven invocations of one ticket, which never once
// got all four repos right, and ended with four MRs on branches nobody had asked for. The base
// each repo was planned against is therefore recorded on its `planned` row and is AUTHORITATIVE
// on resume: forgetting the flag can no longer move it, and an explicit flag that disagrees stops
// the run instead of quietly re-basing half a ticket.
//
// Runs before this change have `planned` rows with no base_branch. Nothing is asserted for those —
// there is no recorded intent to honour — and the row is rewritten with one at the next re-plan.
const overrodeBase = (id) => !!(BASE_OVERRIDE || (branchKind === 'feature' && FEATURE_BASE_OVERRIDE && (!FEATURE_BASE_REPOS.length || FEATURE_BASE_REPOS.includes(id))))
const baseConflicts = []
for (const r of scoped) {
  const recorded = plannedRow(r.repo)?.base_branch
  const resolved = planMeta[r.repo].baseBranch
  if (!recorded || recorded === resolved) continue
  if (!overrodeBase(r.repo)) {
    // No flag was passed for this repo, so this invocation's value is a DEFAULT, not an intent.
    // The recorded intent wins — this is the line that kills the silent revert.
    planMeta[r.repo].baseBranch = recorded
    planMeta[r.repo].baseFromState = true
    log(`[base] ${r.repo} → ${recorded} (RECORDED by an earlier invocation of this run; this invocation would have resolved ${resolved} from defaults). Pass --base/--feature-base with --accept-base-change to move it.`)
  } else if (acceptBaseChange) {
    log(`[base] ${r.repo} RE-BASED ${recorded} → ${resolved} (--accept-base-change).`)
    degradeRows(r.repo, `its base changed ${recorded} → ${resolved}`, ['planned', 'built', 'pr_open', 'reviewed', 'gate_review', 'gate_guard', 'gate_perf'])
  } else {
    baseConflicts.push(`${r.repo}: run state says ${recorded}, this invocation says ${resolved}`)
  }
}
if (baseConflicts.length) {
  throw new Error(
    `dev-cycle ${ticket}: base conflict in ${baseConflicts.length} repo(s) — a run keeps the base it started with.\n` +
    baseConflicts.map((c) => `  ${c}`).join('\n') +
    `\n  Re-base this run in place (re-plans, rebuilds and re-reviews the affected repos):\n` +
    `    /dev-cycle ${ticket} ${BASE_OVERRIDE ? `--base ${BASE_OVERRIDE}` : `--feature-base ${FEATURE_BASE_OVERRIDE}${FEATURE_BASE_REPOS.length ? ` --feature-base-repos ${FEATURE_BASE_REPOS.join(',')}` : ''}`} --accept-base-change\n` +
    `  Or drop the flag to keep the recorded base.\nNo agent was spawned beyond scope + run-state.`,
  )
}
// §3.9 — this table is the line that would have caught every wrong-base round on that ticket, and
// it used to print at the far end of Kickoff, after every planner had been paid for. It prints
// here, before the first planner spawns, whether or not an override is in play: the interesting
// case is the run that thinks it overrode something and did not.
log(`Resolved bases (${branchKind}): ${scoped.map((r) => `${r.repo}→${planMeta[r.repo].baseBranch}${planMeta[r.repo].baseFromState ? ' [run state]' : overrodeBase(r.repo) ? ' [flag]' : ' [repo default]'}`).join(', ')}`)

// C10 — the Kickoff skip gate. A repo skips its planner ONLY when all three hold:
//   (a) a non-degraded `planned` row exists for it (so the loader saw its plan file, non-empty),
//   (b) that row's ticket_fp equals THIS run's TICKET_FP, and
//   (c) no OTHER scoped repo's planned row disagrees with TICKET_FP.
// (c) is why a changed ticket re-plans EVERYWHERE: a partial re-plan leaves sibling repos planned
// against a different reading of the ticket, and cross-repo drift is the failure the plans exist
// to prevent. --approve-plan does not bypass this: an approved re-run whose ticket is untouched is
// precisely the case worth skipping (the planner's own --approve-plan branch already only re-READS
// the plan), and one whose ticket changed re-plans like any other.
const fpStale = scoped.some((r) => { const w = plannedRow(r.repo); return w && w.ticket_fp !== TICKET_FP })
if (fpStale) log(`⚠️ [kickoff] ${ticket} CHANGED since it was last planned (now fp=${TICKET_FP}) — INVALIDATING every 'planned' row for this run: all ${scoped.length} repo(s) re-plan from the live ticket. A partial re-plan would leave a sibling repo planned against the older reading.`)
const kickoffSkippable = (id) => {
  const w = plannedRow(id)
  return !fpStale && !!w && w.ticket_fp === TICKET_FP && Number(w.plan_bytes) > 0
}
const plans = (await parallel(scoped.map((r) => () => {
  const desc = REPOS[r.repo]
  const planner = desc.plan
  const slice = r.summary || 'see ticket'
  const m = planMeta[r.repo]
  // baseBranch/workBranch come from planMeta (resolved once, override-aware, C1) — never
  // recomputed here, so this prompt and the recorded plan can't disagree on either.
  const { repoDir, repoRoot, planRel, planPath, planHtmlPath, testcasesRel, baseBranch, workBranch } = m
  // C10 — reuse instead of re-planning. Rehydrated from the row + planMeta ONLY: the workflow has
  // no filesystem access, so nothing here reads the plan file — the build agent reads it, at
  // plan_path, exactly as it would after a live Kickoff, and the plan-guard below re-asserts on
  // disk that the file is really under this repo.
  const reuse = kickoffSkippable(r.repo) ? plannedRow(r.repo) : null
  if (reuse) {
    log(`[${r.repo}] Kickoff SKIPPED — already planned this run (fp=${TICKET_FP}, plan ${reuse.plan_bytes} bytes at ${planPath}, recorded ${reuse.recorded_at || 'earlier'}); plan rehydrated from run state, NO ${planner} spawned.`)
    return {
      repo: r.repo, reused: true, type: scope.type,
      title: reuse.title || scope.title, acceptance: (reuse.acceptance?.length ? reuse.acceptance : (scope.acceptance || [])),
      base_branch: baseBranch, work_branch: workBranch, plan_path: planPath,
      // The LOADER read this off the plan file on disk, so it is the live plan's fingerprint —
      // exactly what the Build skip needs to compare against what was actually built.
      plan_sha: reuse.plan_sha || null,
      plan_html: RESOLVED_PLAN_TO_HTML ? planHtmlPath : null, figma_url: null, needs_artifact_publish: null,
      // Without this the pin evaporates on every resumed invocation and the wave ordering never fires
      // again — the mechanism would have worked exactly once per ticket, on run 1, which is the one
      // run least likely to need it.
      submodule_pins: Array.isArray(reuse.submodule_pins) ? reuse.submodule_pins : [],
      summary: `plan reused from run state (planned ${reuse.recorded_at || 'in an earlier invocation'}; no re-plan — ticket unchanged, fp=${TICKET_FP})`,
      unverified_claims: [],
    }
  }
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
  // --approve-plan PRESERVE: on an approved re-run a human may have hand-edited the
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
  // SUBMODULE PIN DETECTION. Cheap here (the planner already has the checkout open) and expensive
  // anywhere else: it decides the BUILD ORDER. A repo whose harness rebuilds its schema or fixtures
  // from a vendored checkout of another scoped repo can only see commits its pin can reach, so
  // building it beside that repo instead of after it costs the ticket a whole extra round — the
  // downstream stalls, and no in-round reordering after the fact can save it.
  const otherScoped = scoped.map((s) => s.repo).filter((id) => id !== r.repo)
  const pinDetectClause = otherScoped.length
    ? ` SUBMODULE PINS (read-only, and REQUIRED in your answer): run \`git -C ${repoRoot || repoDir} config -f .gitmodules --get-regexp path\`. No .gitmodules, or no output, means \`submodule_pins: []\` — the normal answer, and a perfectly good one. For each path it DOES print, decide whether that checkout is one of the other repos this ticket touches (${otherScoped.join(', ')}) by comparing \`git -C ${repoRoot || repoDir}/<path> remote get-url origin\` with that repo's own origin — match on the REMOTE, never on the directory name. Return one entry per match: the repo id, and the path spelled exactly as .gitmodules spells it. Do not add a submodule, do not move a pin, do not commit.`
    : ''
  const prompt = desc.kind === 'test-suite'
    ? `${tag(r.repo, planner, 'kickoff')} Kickoff ${ticket} for the ${r.repo} repo (cwd ${desc.path}/) — the test-suite (QA) repo.${anchor}${preserveTest} Run your planning chain: /plan-testcases ${ticket} (user-voice BDD Given/When/Then for this ticket), publish it as this repo's DURABLE QA-PLAN RECORD (below) — the BDD plan ONLY, and do NOT move the ticket status; the workflow owns it — then /plan-automate ${ticket} (map it to this repo's Page Object Model — Page Objects/specs to add or reuse, selectors, automatable vs manual). The AUTOMATION plan is NOT published: it stays in agent_logs/ for the runner.${durableRecord('qa-plan', r.repo, 'the BDD plan from agent_logs/' + ticket + '-testcases.md verbatim — the scenarios a human reads to know what will be tested. It REPLACES the previous revision rather than adding a round below it. Then, as the last section, a `_Plan revisions_` list rendered MECHANICALLY from this repo\'s ledger, never re-typed from the old record: append one line first — `printf \'r%s\\t%s\\t%s\\n\' \'' + RUN_SEQ + '\' "$(date -u +%Y-%m-%dT%H:%MZ)" \'<n cases, or what changed this revision>\' >> agent_logs/' + ticket + '-qa-plan-history.tsv` — then render the whole file with `awk -F\'\\t\' \'{printf "- %s · %s · %s\\n", $1, $2, $3}\' agent_logs/' + ticket + '-qa-plan-history.tsv`. Carrying revision history by hand is what made an earlier report contradict its own run three times; the ledger file is the history, and you only ever append one line to it.')} Do NOT create a git branch — the qa-runner branches at build time. Return the structured repo plan with repo=${r.repo}, type=${scope.type}, base_branch=${baseBranch}, work_branch=${workBranch} (the branch the runner will create), plan_path=${planPath}, and the acceptance/summary for this slice (${slice}).${pinDetectClause}${htmlClause}`
    : `${tag(r.repo, planner, 'kickoff')} Kickoff ${ticket} for the ${r.repo} repo (cwd ${desc.path}/).${anchor}${preserveCode} Run /ticket-kickoff ${ticket} to fetch + classify the ticket and create the work branch IN THIS REPO from base ${baseBranch} — THIS RUN says so: pass it to /ticket-kickoff and do NOT let the branch model re-derive it from the branch prefix or origin/HEAD.${baseIsSettled(baseBranch)}${basePresentClause(baseBranch, repoRoot || repoDir)} The workflow has already moved the ticket to in_progress, so you don't need to. Comprehend the ticket for this repo's slice (${slice}), verify the design screen if any, and write the implementation plan to ${planPath} (git-ignored). Return the structured repo plan with plan_path=${planPath}.${pinDetectClause}${htmlClause}`
  const plannedExtra = `,"ticket_fp":"${TICKET_FP}","plan_path":"${planPath}","base_branch":"${baseBranch}","plan_sha":"<the plan_sha you return, identical>","title":"<the ticket title, verbatim, JSON-escaped>","acceptance":["<one acceptance criterion for THIS repo's slice per element, JSON-escaped>"],"submodule_pins":<the submodule_pins array you return, as JSON — [] when .gitmodules declares none. It decides the BUILD ORDER, so an invocation that cannot read it back loses the ordering entirely>`
  return agent(prompt + groundingClause + PONYTAIL_DIRECTIVE + FIGMA_DIRECTIVE + LANGUAGE_DIRECTIVE + codegraphClause(desc.path) + stateWrite(r.repo, 'planned', plannedExtra)
    + ` Those four extra fields are what lets the NEXT invocation reuse this plan instead of paying for it again: ticket_fp and plan_path exactly as given above, and title/acceptance identical to what you return in your structured result (a reviewer later judges the diff against that acceptance list and has no other source for it). Write valid JSON — escape any quote or backslash inside a criterion, and if you have no acceptance criteria for this slice write \`"acceptance":[]\`. ALSO return plan_sha in your structured result and write the SAME value into the row: run \`shasum -a 256 ${planPath} | cut -c1-16\` after the plan file is final. It is what tells the Build phase whether an existing build was made from THIS plan or from one you have just superseded — a re-plan that leaves it stale is how a corrected plan gets written and then never built.`,
    { agentType: planner, phase: 'Kickoff', label: `kickoff:${ticket}:${r.repo}`, schema: REPO_PLAN_SCHEMA })
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
// A missing plan file used to end the RUN — every repo, including the ones whose plans are fine.
// But "the planner did not write its file" is a question with an obvious next move: ask it again.
// The plan is the one artifact a re-ask reliably reproduces (the ticket has not changed, the branch
// exists, the path is already decided), and stopping instead spent a whole invocation to get back
// here. One bounded re-plan per missing repo, in parallel, then the guard's finding is re-asserted.
let stillMissing = missingPlans
if (stillMissing.length) {
  log(`⚠️ [plan-guard] source-of-truth plan markdown missing for ${stillMissing.join(', ')} — RE-PLANNING those repos once (bounded: write the file, nothing else) rather than ending the run.`)
  const repaired = await parallel(stillMissing.map((id) => async () => {
    const m = planMeta[id]
    const r = await safeAgent(
      `${tag(id, REPOS[id].plan, 'replan')} The implementation plan for ${ticket} in the ${id} repo is MISSING from disk — a placement guard looked for ${m.planRel} under ${m.repoRoot || m.repoDir} and in the workspace root and found it in neither, so the build has nothing to read. ${scoped.find((s) => s.repo === id)?.summary ? `THIS REPO'S SLICE: ${scoped.find((s) => s.repo === id).summary}` : ''} Write it now with the Write tool, to the ABSOLUTE path ${m.planPath} — not a bare relative \`agent_logs/…\`, and NEVER to the workspace-root agent_logs/, which is what the guard is looking for a misfile of. Read the ticket (\`scripts/tracker/get-ticket-details.sh ${ticket}\`) and this repo's docs/adr/* and CONTEXT.md first, and where the ticket and an ADR disagree the ADR wins. THE BASE IS ${m.baseBranch} and the work branch is ${m.workBranch}, both settled by this run — do not re-derive either. Do NOT create or switch a branch, do NOT touch git, do NOT write code, do NOT move the ticket. Writing the plan file IS the task. Return the structured repo plan with plan_path=${m.planPath}, and confirm with Read that the file exists at that exact path before you return.` + PONYTAIL_DIRECTIVE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
      { agentType: REPOS[id].plan, phase: 'Kickoff', label: `replan:${ticket}:${id}`, schema: REPO_PLAN_SCHEMA },
    )
    return r ? id : null
  }))
  const rewritten = repaired.filter(Boolean)
  if (rewritten.length) log(`[plan-guard] re-planned ${rewritten.join(', ')} — their plan files were rewritten at the recorded paths.`)
  stillMissing = stillMissing.filter((id) => !rewritten.includes(id))
}
if (stillMissing.length) {
  log(`⛔ [plan-guard] plan markdown STILL missing for ${stillMissing.join(', ')} after a re-plan — these repos have no plan to build from; stopping for human attention.`)
  const summary = await writeSummary('plan-missing', { ticket, repos: plans.map((p) => p.repo), plans, missingPlans: stillMissing, replanned: missingPlans.filter((id) => !stillMissing.includes(id)), guard, testSuiteRequested, testSuiteGateUnavailable })
  return { ticket, status: 'plan-missing', missingPlans: stillMissing, plans, guard, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
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
// C11 — a reused plan (C10 skipped its Kickoff) rendered NO new HTML this invocation, so there is
// nothing to publish or republish for it: `plans.forEach` above stamps plan_html onto every plan
// unconditionally, which is exactly how the previous run minted a second artifact per repo.
const htmlPlans = RESOLVED_PLAN_TO_HTML ? plans.filter((p) => p.plan_html && !p.reused) : []
if (RESOLVED_PLAN_TO_HTML && plans.some((p) => p.reused)) log(`[kickoff] ${plans.filter((p) => p.reused).length} repo(s) reused their plan — excluded from the Artifact publish request (no new page was rendered for them).`)
// C11 — the URL of the page already published for this repo, if any. The workflow itself cannot
// publish (no agent in a workflow holds the Artifact tool — only the main session does), so this
// is threaded THROUGH the request: publish to the same address instead of minting a new page.
const priorArtifact = (id) => rowAt(id, 'artifact_published')?.artifact_url || null
if (htmlPlans.length && RESOLVED_ARTIFACTS) {
  await safeAgent(
    `${tag('all', 'general-purpose', 'publish-request')} Ask the MAIN SESSION to publish this run's plan page(s) as an Artifact. You are not publishing anything yourself — you do not have the Artifact tool, and neither does any other agent in this run.
1. Load the messaging tool: ToolSearch with query "select:SendMessage".
2. Send ONE message with to: "main". It must stand on its own, because the reader has none of your context and will act on it as a teammate's request:
   • name the ticket (${ticket}) and the repo(s) whose plan is ready;
   • give the ABSOLUTE path of each page to publish, and for any page ALREADY published for this ticket, the URL it must be published back to: ${htmlPlans.map((p) => `${p.repo} → ${p.plan_html}${priorArtifact(p.repo) ? ` (UPDATE IN PLACE: pass url=${priorArtifact(p.repo)} to the Artifact tool, per .claude/skills/write-interactive-docs/SKILL.md step 2 — publishing without that url mints a SECOND page for the same plan, which is how one ticket ended up with 18 artifacts. If the tool rejects a url argument, publish NOTHING for this repo and say so in your reply rather than creating a duplicate.)` : ' (not published before — a fresh publish)'}`).join(' ; ')};
   • say that a CSP-safe copy may sit beside it as \`<same-name>.artifact.html\` and that THAT is the one to publish when it exists;
   • state plainly that the reader must READ each file in full before publishing it, since publishing distributes content they did not write;
   • tell them that AFTER each successful publish they must also refresh the ticket's ONE plan-link record (docs/adr/0026), which is nothing but links: run \`scripts/tracker/upsert-ticket-comment.sh ${ticket} --marker "${RECORD_MARKER('plans', ticket)}" < <file>\` BARE, with a body whose first line is exactly \`**${RECORD_MARKER('plans', ticket)}**\` and whose remaining lines are one \`- \`<repo>\` — <url>\` per repo, read from every \`agent_logs/${ticket}-dev-cycle-state/*-artifact_published.json\` that exists by then — so the record always reflects every page published so far and never has to be merged by hand. The plan BODY never goes on the ticket: a plan is a working artifact superseded by the next planning pass, so the link is the whole record, and if no page was published there is no record to post at all;
   • ask them to publish nothing if the page looks like anything other than an implementation plan;
   • ask them, AFTER each successful publish, to record the URL for this run so a later invocation updates instead of duplicating: write \`agent_logs/${ticket}-dev-cycle-state/<repo>-artifact_published.json\` (relative to the workspace root — the directory already exists) containing exactly {"repo":"<repo>","milestone":"artifact_published","status":"done","artifact_url":"<the URL the Artifact tool returned>","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"} — one file per repo, replacing any file already at that path;
3. Report whether the send succeeded, verbatim. Do NOT wait for a reply, do NOT retry more than once, and do NOT do any other work — the run is already moving on to Build.` + LANGUAGE_DIRECTIVE,
    { agentType: 'general-purpose', model: 'haiku', phase: 'Kickoff', label: `publish-request:${ticket}` },
  )
} else if (htmlPlans.length) {
  log(`[kickoff] ${htmlPlans.length} plan HTML rendered but artifacts.enabled is false — no publish requested; the files on disk are the deliverable.`)
}

const waveList = toWaves(plans)
if (BASE_OVERRIDE || FEATURE_BASE_OVERRIDE) log(`Base override in effect: ${BASE_OVERRIDE ? `--base ${BASE_OVERRIDE} (all repos)` : `--feature-base ${FEATURE_BASE_OVERRIDE}${FEATURE_BASE_REPOS.length ? ` scoped to ${FEATURE_BASE_REPOS.join(', ')} — every other repo kept its own REPOS[].base` : ' (all repos)'}`} — resolved bases: ${plans.map((p) => `${p.repo}→${p.base_branch}`).join(', ')}.`)
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
if (overBudget()) return await budgetStop('Build', { ticket, repos: plans.map((p) => p.repo), plans, testSuiteRequested, testSuiteGateUnavailable })
phase('Build')
const repoResults = {}
const buildIds = waveList.flat() // every scoped repo, in dependency (merge) order
// FULL PARALLELISM IS THE DEFAULT, and stays the default: a build needs the agreed contract, not a
// merged upstream, so `depends_on` alone never serializes anything.
//
// A SUBMODULE PIN is the one exception, and it is not a preference — it is arithmetic. A repo whose
// harness rebuilds its schema or fixtures from a vendored checkout can only see commits its pin can
// reach. Build it beside its upstream and the upstream's commits do not exist yet, so the pin can
// only point at the merged base, so the downstream cannot write a single test against the change it
// is supposed to prove. That is a guaranteed extra round, and no reordering AFTER the fact recovers
// it: a measured run built the upstream first, approved its MR, and the downstream still could not
// start, because "built" was not what the pin needed — a PUSHED COMMIT was.
//
// Which is the whole fix. A submodule pointer needs a commit that exists on the remote; it does not
// need a merge. So the upstream builds and pushes in an earlier wave, the downstream pins to that
// branch tip, and the ticket's merge boundary is untouched — the run still merges nothing, and the
// existing `submodule-bump` ship step already re-points the pin at the merged sha before the
// downstream lands, which is what keeps a squashed-and-deleted branch from stranding the pointer.
const pinEdges = plans.flatMap((p) => (p.submodule_pins || [])
  .filter((s) => s?.repo && s?.path && REPOS[s.repo] && buildIds.includes(s.repo) && s.repo !== p.repo)
  .map((s) => ({ downstream: p.repo, upstream: s.repo, path: s.path })))
// Layered on the PIN graph alone — never on `depends_on`, which still orders nothing at build time.
// Reusing the merge waves here would have serialized a whole four-repo `depends_on` chain because
// one unrelated pair shares a submodule, paying three sequential waves for one real edge. With no
// pins this loop emits exactly one wave holding every repo, which is the old fully-parallel build
// with no special case to maintain.
const buildWaves = []
{
  const pinnedOn = {}
  buildIds.forEach((id) => { pinnedOn[id] = pinEdges.filter((e) => e.downstream === id).map((e) => e.upstream) })
  const placed = new Set()
  while (placed.size < buildIds.length) {
    const wave = buildIds.filter((id) => !placed.has(id) && pinnedOn[id].every((u) => placed.has(u)))
    if (!wave.length) { buildWaves.push(buildIds.filter((id) => !placed.has(id))); break }
    wave.forEach((id) => placed.add(id)); buildWaves.push(wave)
  }
}
// toWaves emits everything it could not order as ONE final wave, so a dependency cycle puts a pin's
// two ends in the same wave and the ordering silently buys nothing. It still degrades safely — the
// downstream finds no result for its upstream and falls back to the merged base — but "safely" and
// "silently" are different things, and a silent version of this is what took an audit to find.
const unorderedPins = pinEdges.filter((e) => buildWaves.some((w) => w.includes(e.upstream) && w.includes(e.downstream)))
if (unorderedPins.length) {
  log(`⚠️ SUBMODULE PIN NOT ORDERED — ${unorderedPins.map((e) => `${e.downstream} → ${e.upstream}`).join(', ')} share a build wave, which means the dependency graph has a cycle. Those pins stay at the merged base, so the downstream may not be able to test this ticket's upstream change: break the cycle in the repos' depends_on, or expect the usual extra round for them.`)
}
if (pinEdges.length) {
  log(`🔗 SUBMODULE PIN — ${pinEdges.map((e) => `${e.downstream} vendors ${e.upstream} at ${e.path}`).join('; ')}. Building in ${buildWaves.length} wave(s) (${buildWaves.map((w) => w.join('+')).join(' → ')}) so each pinned upstream has PUSHED before the repo that vendors it starts; the downstream pins to that branch tip, unmerged, which is all a submodule pointer needs.`)
}
const repoOf = (id) => runRepoPipeline(plans.find((p) => p.repo === id), REPOS[id], branchKind)
for (const [n, wave] of buildWaves.entries()) {
  // The ceiling is checked BETWEEN waves as well as before the phase. One check before a single
  // parallel fan-out was the whole story while Build was one wave; with more than one, a wave that
  // blows the budget would otherwise be followed by every remaining wave at full width — the
  // ceiling silently overrun by a multiple, in the one phase that spends the most.
  if (n > 0 && overBudget()) {
    log(`🛑 BUDGET — the ceiling was reached during build wave ${n}; waves ${n + 1}..${buildWaves.length} (${buildWaves.slice(n).flat().join(', ')}) are NOT started.`)
    return await budgetStop('Build', { ticket, repos: buildIds, built: Object.keys(repoResults), not_started: buildWaves.slice(n).flat(), plans, testSuiteRequested, testSuiteGateUnavailable })
  }
  const res = await parallel(wave.map((id) => () => repoOf(id)))
  res.forEach((r, i) => { if (r) repoResults[wave[i]] = r })
}
// A repo whose acceptance criteria were ALREADY satisfied by shipped code is FINISHED, not stalled:
// it has no branch, no PR/MR and nothing to merge. It leaves the run's live set right here, so no
// downstream phase — the approval tick, the gate's candidate list, the merge order, the per-repo
// narrative — has to learn a status meaning "not applicable". One filter instead of a new case in
// each of them.
const satisfiedIds = buildIds.filter((id) => repoResults[id]?.status === 'already-satisfied')
const satisfiedRows = satisfiedIds.flatMap((id) => (repoResults[id].satisfied_by || []).map((s) => ({ repo: id, ...s })))
if (satisfiedIds.length) {
  log(`✅ ALREADY SATISFIED — ${satisfiedIds.join(', ')} need no change for ${ticket}: ${satisfiedRows.length} criterion/criteria are met by code that shipped earlier, verified citation by citation. No branch, no PR/MR, nothing to merge — they leave the run here.`)
}
const liveIds = buildIds.filter((id) => !satisfiedIds.includes(id))
// EVERY scoped repo already satisfied is a real, clean ending — the ticket is done and was done
// before the run started. It is NOT `nothing-delivered` (docs/adr/0011), which is the opposite
// finding: that one means nobody met anything. Saying so plainly is the point, because the answer a
// person needs here is "close the ticket", not "re-scope it".
//
// The condition is NO LIVE CODE REPO, not "no live repo at all". A cross-repo gate validates a
// CANDIDATE — the code repos' work branches — so with every code repo satisfied there is no
// candidate, and letting the run continue took the gate down the normal path with an EMPTY candidate
// list and returned a green pass over nothing. A suite that validated nothing must never read as a
// suite that passed, so the run ends here and says which it was.
const liveCodeIds = liveIds.filter((id) => !REPOS[id].testSuite)
if (!liveCodeIds.length) {
  const liveSuites = liveIds.filter((id) => REPOS[id].testSuite)
  if (liveSuites.length) {
    testSuiteGateUnavailable = `The cross-repo test-suite gate did NOT run for ${ticket}: every code repo it would have validated (${satisfiedIds.filter((id) => !REPOS[id].testSuite).join(', ')}) needed no change, so there is no candidate build to run against. ${liveSuites.join(', ')} may have authored specs — they are unvalidated by this run and their PR/MR is left open.`
    log(`⚠️  ${testSuiteGateUnavailable}`)
  }
  const summary = await writeSummary('already-satisfied', { ticket, satisfied: satisfiedRows, repos: buildIds, live_suites: liveSuites, repoResults, testSuiteRequested, testSuiteGateUnavailable }, [], satisfiedRows)
  return { ticket, status: 'already-satisfied', satisfied: satisfiedRows, decision_needed: `${ticket} required no code change: every acceptance criterion in every scoped CODE repo (${satisfiedIds.join(', ')}) is already met by shipped code, each verified against its commit and file:line. Nothing was branched, opened or merged${liveSuites.length ? `, and the test-suite gate had no candidate to validate — ${liveSuites.join(', ')} is left with an open, unvalidated PR/MR` : ''}. Close the ticket, or say what the citations miss.`, repoResults, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}
const aborted = liveIds.filter((id) => !repoResults[id] || repoResults[id].status !== 'ready')
// ADR-0029 — a repo short of `ready` used to end the run BEFORE the cross-repo gate, so a run with
// two ready repos and one carrying a recorded blocking item never learned whether the change set
// breaks the suite. That answer arrived a whole invocation later, which is the round-trip ADR-0027
// exists to remove.
//
// `review-unresolved` is the ONE status where running the gate anyway is honest work: that repo is
// built, its PR/MR is open, its review ran and its fixes landed to their budgets — the branch is in
// the final state THIS run can put it in. Every other status leaves the candidate unfit to measure:
// `build-unresolved` has no complete handoff (the branch may be half-implemented), `pr-unresolved`
// has no PR/MR number for the gate to post its result on, `review-blocked-on` never reached review
// at all, and `target-branch-halt` cannot even compute its own diff (ADR-0025). A repo with NO
// result is in that second group too, which is also what keeps `runSuiteGate` from reading a plan
// off `undefined`.
//
// ADVISORY means full work, no authority: the gate triages, routes fixes and records what it cannot
// close — but it does not move the ticket, does not tick an approval, writes no run-state row (the
// candidate it measured is about to change), and cannot make the run proceed. The run still ends on
// the repos that were not ready.
const advisoryGate = aborted.length > 0 && aborted.every((id) => repoResults[id]?.status === 'review-unresolved')
let abortPayload = null
// EVERY return between the abort point and the advisory ending has to carry these. Removing an early
// `return` promotes whatever sits below it into a new reachable state, and the returns down there
// were written when "a repo was not ready" could not be true — so each one would otherwise end the
// run having dropped the recorded blocking items, and dropping them means no `blocked` rows, which
// re-opens the cross-invocation fail-open ADR-0027 §Across invocations closed. `runStatus` is
// deliberately NOT spread: those endings keep their own, more specific status.
const abortFields = () => abortPayload
  ? { aborted: abortPayload.aborted, handoffs: abortPayload.handoffs, blockingByRepo: abortPayload.blockingByRepo, targetHalts: abortPayload.targetHalts, blocked: abortPayload.blocked }
  : {}
if (aborted.length) {
  // Surface each unresolved repo's partial/blocked HANDOFF (status + what remains) instead of a
  // bare "aborted" — the run stops at the merge gate (the whole change set must be ready before any
  // merge), but the human/summary sees what landed and what's missing per repo.
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
  // ADR-0027 — `review-regression-halt`, `review-tests-unverified` and `review-stalled` used to be
  // filtered and bannered here, one branch each. None of them can be RETURNED any more: the loop
  // converts each into a must-fix and, when a budget runs out, into a blocking item on a
  // `review-unresolved` repo. The banner they used to get is the blockingByRepo one below, which
  // carries the same information for every kind at once instead of three near-identical branches
  // that can no longer fire.
  // ADR-0025 — the PR/MR does not point where this run said, and the run could not repair it (the
  // base is missing on the remote, or the repo carries more than one open PR/MR for this ticket).
  // Loud and distinct: on the run this gate was written for, the SILENT version of this state was
  // handed to a human as "reviewed + validated".
  const targetHalts = aborted.filter((id) => repoResults[id]?.status === 'target-branch-halt')
  if (targetHalts.length) log(`⛔⛔ TARGET BRANCH — nothing was approved or merged: ${targetHalts.map((id) => `${id} (${repoResults[id]?.handoff?.remaining ?? 'see PR/MR'})`).join(' | ')}`)
  // ADR-0027 — the loudness the converted halts gave up. A halt used to be a banner mid-run; a
  // recorded blocking item is a line in a data structure, and if it never reaches a person the
  // change has traded a visible stop for a silent degradation. So it is bannered here, threaded
  // into writeSummary (which puts it in the run summary AND the incomplete-run DM), and carried on
  // the run result. THIS IS PART OF THE FEATURE, not decoration.
  const blockingByRepo = buildIds
    .map((id) => ({ id, items: repoResults[id]?.blocking || [] }))
    .filter((b) => b.items.length)
  bannerBlocking(blockingByRepo, 'review loop')
  const blocked = aborted.filter((id) => repoResults[id]?.status === 'review-blocked-on')
  if (blocked.length) log(`⛔⛔ BLOCKED ON ANOTHER REPO — ${blocked.map((id) => `${id} → ${(repoResults[id]?.blockedOn || []).join('+')}`).join(' | ')}. Land the upstream, then re-run; the run state resumes each repo from its own milestone.`)
  const runStatus = targetHalts.length ? 'target-branch-halt' : blocked.length ? 'review-blocked-on' : 'repo-unresolved'
  // C10 — this is NOT a complete ending (the change set is not merge-ready), so the channel
  // Notify digest is superseded by writeSummary's own incomplete-run DM: no separate review
  // request here. The Summary written below is what a human needs to pick this back up.
  abortPayload = { runStatus, aborted, handoffs, blockingByRepo, targetHalts, blocked }
  if (!advisoryGate) {
    const summary = await writeSummary(runStatus, { ticket, aborted, handoffs, blockingByRepo, targetHalts, blocked, repoResults, testSuiteRequested, testSuiteGateUnavailable }, [], satisfiedRows)
    return { ticket, status: runStatus, aborted, handoffs, blockingByRepo, targetHalts, blocked, repoResults, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
  }
  log(`▶️ ADVISORY GATE — ${aborted.join(', ')} did not reach 'ready', but every one of them is 'review-unresolved': built, PR/MR open, reviewed, fixed to budget. So the cross-repo gate RUNS against this candidate rather than deferring the answer to the next invocation — it will triage and fix what it can. It cannot advance the run: this invocation still ends '${runStatus}', nothing is approved and nothing merges.`)
}

// Every scoped repo is built, reviewed and approved — the WHOLE change set is ready. The one
// exception is an ADVISORY run (`abortPayload` set): repos are built and reviewed but at least one
// carries a recorded blocking item, so everything below runs up to and including the gate and then
// stops at `abortPayload`'s ending. Nothing past the gate is reachable in that mode.
// Repo order (upstream → downstream) for the test-suite, distribute, and final merge phases.
const mergeOrder = waveList.flat().filter((id) => !satisfiedIds.includes(id))
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
const runMet = [...mergeOrder.flatMap((id) => repoResults[id]?.met_acceptance || []), ...satisfiedRows.map((s) => s.criterion)]
if (runDeferred.length) log(`⚠️  DEFERRED SCOPE — ${runDeferred.length} acceptance criterion/criteria are NOT met by this change set, owned elsewhere: ${runDeferred.map((d) => `${d.repo}: ${d.owner}`).join(' | ')}. The run continues; the deferral rides the MR, the ticket and the summary.`)
// THE FLOOR (docs/adr/0011): every repo deferred and not one acceptance criterion met means the
// change set delivers nothing the ticket asked for. Reviewed, green and pointless is still pointless
// — stop and let a human re-scope rather than hand over a merge command for it.
if (runDeferred.length && !runMet.length) {
  log(`⛔ NOTHING DELIVERED — every scoped repo deferred its criteria and none reported one met for ${ticket}. NOT advancing the ticket, NOT running the gate, NOTHING merged; PR/MR left OPEN for human decision.`)
  const summary = await writeSummary('nothing-delivered', { ticket, deferred: runDeferred, repos: mergeOrder, repoResults, testSuiteRequested, testSuiteGateUnavailable, ...abortFields() }, runDeferred, satisfiedRows)
  return { ticket, status: 'nothing-delivered', deferred: runDeferred, decision_needed: `${ticket}'s change set meets none of its acceptance criteria — every one is owned elsewhere (${[...new Set(runDeferred.map((d) => d.owner))].join(', ')}). The branches and their PR/MR are open and reviewed; decide whether to re-scope the ticket, route it to those owners, or merge the groundwork deliberately.`, repoResults, ...abortFields(), summary, spend }
}
// THE APPROVAL TICK — orchestrator-owned, and the review phase's last act.
//
// The gates never do this (NO_SELF_APPROVE): a gate that reports is an instrument, a gate that
// approves is an authority, and the gate reviewing this branch belongs to the same run that
// wrote it. So the workflow ticks, at a bar the workflow computed — which is also the only way
// the tick is DETERMINISTIC: a gate that ran out of turns or lost its shell would silently
// leave the PR/MR unapproved while reporting a pass.
//
// THE BAR IS TICKET-WIDE, and it is already enforced above: any repo short of 'ready' returns
// early, so control only reaches here when every gate on every repo passed with a green
// receipt. That is deliberate — a ticket's repos are ship-order-coupled, and approving the
// clean repo of a partially-met ticket reads as "this MR is mergeable on its own", which the
// coupling makes false. Anything less than fully met posts NO tick anywhere; the absence of a
// tick IS the changes-requested signal.
//
// STILL NOT A MERGE. `pr-approve.sh` registers the host approval plus one verdict line and
// stops there — `vcs.auto_merge` and the Merge phase are untouched, and with auto_merge off the
// PR/MR is simply left open, approved, for a human. A dry run DOES tick, for the same reason it
// still moves the ticket: an approval is revocable and inward-facing, not one of the outward
// irreversible steps a dry run exists to withhold.
const approvalTick = async (ids, phaseName, receipt) => {
  const targets = ids.filter((id) => repoResults[id]?.pr?.pr_number).map((id) => ({ id, pr: repoResults[id].pr.pr_number, path: haveAbs ? `${WORKSPACE_ROOT}/${REPOS[id].path}` : REPOS[id].path }))
  if (!targets.length) { log(`[approve] no PR/MR number on record for ${ids.join(', ')} — nothing to tick.`); return null }
  // ADR-0025 — the LAST thing checked before the tick, because the tick is what makes the run's
  // verdict readable as "mergeable". The open-PR checkpoint already asserted and repaired this,
  // and it is asserted again here for the two cases that checkpoint cannot cover: an invocation
  // that resumed straight past open-PR on a `pr_open` row, and a human moving the target mid-run.
  // Read-only: a mismatch surviving to here is not something to repair silently under an approval.
  const tgtChecks = await parallel(targets.map((t) => () => assertTargetBranch(t.id, repoResults[t.id].plan, repoResults[t.id].pr, { repair: false, phaseName })))
  const tgtBad = tgtChecks.filter((c) => c && c.ok === false)
  if (tgtBad.length) {
    log(`⛔ [approve] NOT TICKING — ${tgtBad.length} PR/MR(s) do not target this run's base:\n${tgtBad.map((c) => `   ${c.why}`).join('\n')}`)
    return null
  }
  const r = await safeAgent(
    `${tag('all', 'tracker', 'approve')} POST THE APPROVAL — no review, no code, no merge. ${ticket} passed every gate on every repo, so tick the approval on each PR/MR below. One call per repo, each BARE (a writer in a pipe or after \`&&\` is denied silently):\n${targets.map((t) => `• ${t.id} — PR/MR ${t.pr}, repo dir ${t.path}`).join('\n')}\nFor EACH one, in this order: (1) resolve this repo's VCS_REPO in its own command — \`git -C <that repo dir> remote get-url origin\`, then strip the leading \`git@<host>:\`/\`https://<host>/\` and any trailing \`.git\`; (2) \`VCS_REPO=<that> scripts/vcs/pr-approve.sh <that number> --body "<the verdict line>"\`. STEP 1 IS NOT OPTIONAL: PR/MR numbers COLLIDE across repos in this workspace (the same ticket routinely has !806 in two unrelated repos), the adapter resolves its target from cwd unless VCS_REPO says otherwise, and several agents share this Bash session — so a tick sent on cwd alone lands on a stranger's MR. Verify per repo before you write.\nThe verdict line, in the resolved output language, names WHAT CLEARED THE BAR — it is the durable record a human reads next to the diff: requirements met, standards clean, 0 must-fix, and the suite that proved it (${receipt}). An approval that cannot point at a test result is the failure the green gate exists to prevent, so if you cannot name the suite for a repo, say so in \`note\` and skip that repo rather than inventing one.\nThe adapter is IDEMPOTENT — an already-approved PR/MR prints "already approved — nothing to do" and posts nothing, which is a SUCCESS, not a failure: report it in \`posted\` with that note. Report in \`failed\` only a repo whose tick genuinely did not land (a refused permission, an adapter error) — quote the error. Do NOT merge anything, whatever the config says.` +
      ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
    { agentType: 'developer', model: 'haiku', phase: phaseName, label: `approve:${ticket}:${ids.join('+')}`, schema: APPROVAL_POST_SCHEMA },
  )
  const failed = Array.isArray(r?.failed) ? r.failed : []
  log(`[approve] ${(r?.posted || []).length}/${targets.length} PR/MR ticked${failed.length ? ` — ⚠️ NOT ticked: ${failed.join(' | ')}` : ''}${r?.note ? ` (${r.note})` : ''}`)
  if (!r) log(`⚠️ [approve] the approval step did not converge — the PR/MR(s) may be unapproved. Tick by hand: scripts/vcs/pr-approve.sh <number> --body "…"`)
  return r
}

// Code repos are ticked HERE, at the end of Review — that is the gate whose bar they cleared.
// The test-suite repos are not: they have no reviewers at all, so their verdict is the
// cross-repo suite gate below, and they are ticked when it passes (§4).
const codeRepos = mergeOrder.filter((id) => !REPOS[id].testSuite)
// NEITHER of these happens on an advisory run (ADR-0029). Both were unreachable while a non-ready
// repo returned above, and letting them fire would have been the worst bug in that change: the tick
// is ticket-wide (ADR-0022), so it would announce the whole ticket approved while a repo carries a
// recorded blocking item, and the move would land it on ready_to_merge AND write a `reviewed` row
// for that repo — which the NEXT invocation would read as "review already done".
// The ready repos lose nothing they need: their reviewers wrote their own `gate_*` ledger rows, so
// the resumed run still skips their review on "every gate is ledgered PASSED".
if (!abortPayload) await approvalTick(codeRepos, 'Review',
  'each repo\'s own code gate ran the repo suite on the PR/MR head and returned a green receipt — quote that repo\'s receipt')

// The workflow advances the ticket ONCE here (decoupled from the per-repo agents): a rich
// board lands on ready_to_merge; the minimal board on ready_to_test.
if (abortPayload) log(`[approve] SKIPPED and the ticket is NOT advanced — advisory run: ${abortPayload.aborted.join(', ')} did not reach 'ready'. The approval tick is ticket-wide, so it is all or nothing.`)
else await moveTicket(['ready_to_merge', 'ready_to_test'], runDeferred.length ? `all repos built & reviewed; ${runDeferred.length} criterion/criteria deferred to other owners` : 'all repos built, reviewed & approved', 'Review',
  mergeOrder.map((id) => stateWrite(id, 'reviewed')).join(' '))

// 4. TEST-SUITE GATE — the cross-repo QA suite (E2E / API / load) against the CANDIDATE
// (the ticket's work branches, PRE-merge): the join check that the repos work together,
// run BEFORE the final merge so we validate the candidate, not after committing it. Runs
// when a test-suite gate is needed, a test-suite repo is in scope, and at least one
// non-test-suite (app/service) repo is present for the suite to run against.
if (overBudget()) return await budgetStop('Test suite', { ticket, mergeOrder, repoResults, testSuiteRequested, testSuiteGateUnavailable, ...abortFields() }, runDeferred, satisfiedRows)
const testSuiteRepos = mergeOrder.filter((id) => REPOS[id].testSuite)
let testSuite = null
// RESUME, per suite (C5): the gate never fails open (docs/agents/loadtest-gate.md), so a skip is
// only legitimate when the artifact it judged is byte-identical — i.e. THIS suite already passed
// AND no work branch has moved (degraded) since. A pre-existing 'all-test_suite.json' row (from a
// run before this per-suite split) matches no suite repo, so the first resume after this change
// simply runs each gate once more — the safe direction, never a false skip.
// `!carriedBlocking(id).length` — the same veto as the review skip (ADR-0027 §Across invocations).
// The gate brief already tells the agent not to write a `test_suite` row while a blocking item
// stands, but an instruction is not a mechanism: this is the code that holds if one gets written.
// `!abortPayload` (ADR-0029): on an advisory run the review loop just pushed fixes onto a repo that
// still did not reach `ready`, so the candidate has moved since any earlier pass and a `test_suite`
// row from that pass describes a candidate that no longer exists.
const tsSkippable = (id) => doneAt(id, 'test_suite') && !abortPayload && !carriedBlocking(id).length && !stateRows.some((r) => r.milestone === 'built' && r.degraded === true)

// One suite's gate: initial run → receipt/ticket audit → C4's bounded red-triage loop → (load
// suites only) the base-branch comparison. Returns { suite, verdict, blocking, unverified?, why? }.
// ADR-0028: nothing in here returns early on a finding any more. `blocking` is what keeps a suite
// out of a pass, so a red it could not close never reads as green and never stops it working the
// rest — and a suite whose own verdict is `passed` still fails the gate while it carries one.
// Never calls phase() (this runs inside the fan-out below, alongside its siblings).
async function runSuiteGate(testSuiteRepo) {
  // ADR-0028 — the same spine ADR-0027 gave the review loop, for the gate. A red, an un-cleared
  // fix, an unrunnable gate or a load regression is a must-fix with a budget; what a budget cannot
  // close is RECORDED and the gate keeps working its other reds. `blocking` is what blocks the
  // merge, and it is the ONLY thing that does — no early return decides that any more.
  const blocking = []
  const record = (kind, detail, human, key) => {
    if (blocking.some((b) => b.kind === kind && (key ? b.key === key : b.detail === detail))) return
    blocking.push({ kind, detail, human_action: human || null, key: key || null })
    log(`⚠️ [test-suite/${testSuiteRepo}] BLOCKING RECORDED (${kind}) — ${String(detail).slice(0, 200)}. The gate continues on its other reds; this suite cannot read as passed.`)
  }
  // The ONE retraction, and it is narrow on purpose: a per-case `gate-fix-unchecked` record is a
  // statement that THIS gate rejected THIS case's fix diff, and the same gate clearing the same
  // case in a later round is a fresher statement of the same judgement — by the same reviewer, over
  // a superset of the same diff. Nothing else is retractable: every other record is a budget that
  // ran out, and a budget does not un-run.
  const unrecord = (kind, key) => {
    const i = blocking.findIndex((b) => b.kind === kind && b.key === key)
    if (i < 0) return
    blocking.splice(i, 1)
    log(`↩️ [test-suite/${testSuiteRepo}] blocking item RETRACTED (${kind} · ${key}) — the same scoped check has now cleared this case's fix.`)
  }
  const suiteResult = (extra = {}) => ({ suite: testSuiteRepo, verdict: ts, blocking, ...extra })
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
4. LOAD SUITE — ${testSuiteRepo} is declared suite_kind: load, so a green run is NOT a pass on its own. Invoke \`/loadtest-baseline-gate ${ticket}\` and run the SAME scenario against the ticket's base branch as well, so the candidate has a number to beat. The base is the branch this ticket's PR/MR actually TARGETS (${mergeOrder.filter((id) => !REPOS[id].testSuite).map((id) => `${id} → ${repoResults[id]?.plan?.base_branch}`).join(', ')}), not the repo default. The skill measures the environment's own noise floor from ${LOADTEST.noiseRuns} base runs, sets each metric's threshold to max(${LOADTEST.tolerancePct}%, that floor), and returns pass / fail / unavailable — fill the "loadtest" object from its output verbatim, including base_sha, candidate_sha and its markdown table. Do NOT compute the comparison yourself and do NOT relax a k6 threshold to make a run green: moving the bar is not passing the gate. If the noise floor is too wide to judge, "unavailable" is the correct, expected answer — report it rather than picking a side.`
    : ''
  // C4 — the gate CLASSIFIES its own red instead of just reporting it, so the workflow knows who
  // fixes it: the suite repo itself (automation/prereq) or the named app repo (app), and can hand
  // it to a bounded fix→re-review→re-run loop below rather than halting on the first red.
  const gatePrompt = (extra) => `${tag(testSuiteRepo, 'qa-runner', 'test-suite')} CROSS-REPO TEST-SUITE gate for ${ticket} — SCOPED to THIS ticket, NOT the full suite.${advisoryClause} ${extra ? `${extra} ` : ''}Validate the CANDIDATE (the ticket's work branches, NOT yet merged — ${candidates.join(', ')}).${candidateStackClause(mergeOrder.filter((id) => !REPOS[id].testSuite).map((id) => repoResults[id].plan))} Work in the ${testSuiteRepo} repo (cwd ${REPOS[testSuiteRepo].path}/, already on its work branch ${repoResults[testSuiteRepo].plan.work_branch}).${runDeferred.length ? ` COVERAGE BOUNDARY — this change set deliberately does NOT meet every acceptance criterion: ${runDeferred.map((d) => `"${d.criterion}" (owned by ${d.owner})`).join(', ')}. No spec can cover those, and their absence is NOT a failure. State the boundary in your verdict — which criteria you covered, and which you could not because they are deferred — so your pass reads as scoped to what you actually exercised. Do NOT fail the gate over a deferred criterion, and do NOT quietly report a clean pass as though the whole ticket were validated.` : ''} Then run ONLY this ticket's scope:
1. SCOPE = (a) the ticket's own spec(s) automated for ${ticket} + (b) the ticket's regression spec(s). Derive (a) from the spec map in agent_logs/${ticket}-automation-plan.md${specHint} Derive (b) from the "**Regressions**" block at the bottom of agent_logs/${ticket}-testcases.md (the dev's "⚠️ Regression request" recap — the SOLE source of regression scope; if that block is absent there is NO regression scope, so run just the ticket's spec(s)).
2. RUN SCOPED — \`scripts/dev.sh test <this repo's own spec-scoping args>\` covering exactly the ticket + regression spec(s). Never \`npm test\` (a stub that exits 1 in several repos here), and never \`scripts/dev.sh test\` with no scoping args: the FULL-suite run is ON-DEMAND (the user triggers it separately) and is NOT part of this gate.
3. REPORT WITH EVIDENCE — /report-test-results ${ticket}. THIS RUN IS r${RUN_SEQ}: use that ordinal in the report's run stamp verbatim — do not count rounds yourself and do not guess. The stamp is the only thing separating this run's result from the last one's, and step 4's audit records the gate as NOT RUN when it does not match. It reads \`scripts/dev.sh why test\` + \`scripts/dev.sh artifacts\` and posts the per-TC results table to the ticket with the run's OWN screenshots embedded in the comment (failures full-width, passes as a thumbnail strip). A green run that captured no artifacts is reported as unevidenced — say so, never dress it up as proven. THE REPORT IS ONE DURABLE COMMENT PER SUITE REPO, UPDATED IN PLACE: it carries the marker line \`[test-report · ${testSuiteRepo}]\` and goes up via \`scripts/tracker/upsert-ticket-comment.sh ${ticket} --marker "[test-report · ${testSuiteRepo}]"\`, never \`add-ticket-comment.sh\` — this ticket is re-run (fix rounds, resumed invocations, a second dev-cycle) and a fresh report each time buries which numbers are current. Stamp it \`run r<n> · <UTC> · candidate ${candidates.join(', ')}\` and append this run's line to its Run history, carrying every earlier line forward: with the body rewritten in place, that stamp is the ONLY thing that identifies this run's result, and step 4's audit reads it.
On a red — CLASSIFY, do not guess and do not fix app code yourself. Re-run just the broken case once (the same scoped \`scripts/dev.sh test <args>\` + one \`scripts/dev.sh why test\`) and put every failure in "triage" as exactly one of:
• "automation" — the spec/Page Object/selector/wait is wrong, or the runner wiring is. You OWN this: fix it in this repo, re-run that one case, and report it fixed.
• "app" — the automation is correct and the candidate's observable behaviour contradicts the spec's Then. Name the scoped repo that carries the cause in "repo" (it MUST be one of the repos in this run), quote the assertion and the actual value in "evidence", and give the scoped re-run args in "spec". Do NOT read or edit that repo's source — naming it is the whole job.
• "prereq" — the case cannot run because required seed/fixture data is absent (no matching entity, an unreachable transition). You own this too: prepare it through this repo's own sanctioned seeding path, then re-run that case.
CONTROL RUN before you blame the candidate: for any "app" red, run the same case against the ticket's BASE branch build once. If it is red there too, COMPARE THE TWO FAILURES before you conclude anything: a control that fails IDENTICALLY — same error, same frame — confirms a SHARED cause, which is a reason to go find that shared cause, NOT evidence the red is out of scope. Set pre_existing_on_base:true only when the control's failure is genuinely a DIFFERENT one that happens to also be red, and say which two failures you compared. Getting this backwards is what let one fixture value masquerade as a pre-existing defect for two rounds. A genuinely pre-existing red is recorded and handed off, never fixed inside this gate. And if you conclude the fix lies outside this gate's bounds at all — a dependency bump, a repo-wide change — that conclusion permanently ends investigation, so fill out_of_gate_bounds_second_read with the SECOND, independent read that reached the same answer, or do not draw it.
Return passed:true only if the scoped run (ticket + regression spec(s)) is green; otherwise passed:false with the failures and triage.${loadClause}${RECEIPT_CLAUSE}
RUN-STATE (only on a GREEN verdict — a red/unavailable gate must leave no row, or a later resume would treat a gate that never passed as already proven): if and ONLY IF you are returning passed:true${isLoadSuite ? ' AND loadtest.verdict is exactly "pass"' : ''}${abortPayload ? ' — WHICH YOU MUST NOT DO IN THIS RUN: this is an ADVISORY gate. Another repo in this ticket is still carrying a recorded blocking item, so the candidate you are measuring is about to change when that item is fixed, and a row saying this gate is proven would make the next invocation skip a gate that never saw the final candidate. Write NO row, whatever your verdict' : ''}${blocking.length ? ' — WHICH YOU MUST NOT DO IN THIS ATTEMPT: this run already carries ' + blocking.length + ' recorded blocking item(s) for this suite (' + blocking.map((b) => b.kind).join(', ') + '), so this gate cannot be a proven pass whatever your verdict is. Write NO row' : ''}, as your LAST action before the structured result, with the Write tool (the directory already exists, created at Kickoff): Write \`agent_logs/${ticket}-dev-cycle-state/${testSuiteRepo}-test_suite.json\` at the WORKSPACE ROOT (the dir holding .claude/, NOT this repo) — ONE FILE for this checkpoint, so nothing else you write can collide with it — content exactly {"repo":"${testSuiteRepo}","milestone":"test_suite","status":"done","recorded_at":"<date -u +%Y-%m-%dT%H:%M:%SZ>"}. If your verdict is passed:false or the gate could not run, write NOTHING there.${isLoadSuite ? ' ⚠️ A LOAD SUITE THAT MET ITS OWN THRESHOLDS BUT LOST TO ITS BASE IS NOT GREEN — a row written there tells the next invocation this gate is already proven, so it skips the whole comparison and merges a candidate nobody measured. passed:true + loadtest.verdict "fail" or "unavailable" ⇒ no row.' : ''}`
  const gateOpts = (round) => ({ agentType: 'qa-runner', phase: 'Test suite', label: round ? `test-suite:${ticket}:${testSuiteRepo}#r${round}` : `test-suite:${ticket}:${testSuiteRepo}`, schema: TEST_SUITE_SCHEMA })
  // ADR-0029 — the qa-runner is told it is advisory, and WHICH repo is unresolved, because that is
  // real triage information: a red on a flow that repo owns is more likely explained by the item it
  // could not close than by anything new. It changes nothing about the bar — run the scope, report
  // honestly, receipt included.
  const advisoryClause = abortPayload
    ? ` ⚠️ ADVISORY RUN: ${abortPayload.aborted.join(', ')} did not reach 'ready' — reviewed, but carrying blocking item(s) a person has to settle: ${(abortPayload.blockingByRepo || []).flatMap((b) => b.items.map((i) => `${b.id}/${i.kind}: ${i.detail}`)).join(' | ') || 'see the run summary'}. Nothing merges out of this run whatever you find, and your verdict approves nothing. Run the scope anyway and report it exactly as you would otherwise: the point is that the answer exists NOW instead of an invocation later. If a red lands on a flow one of those repos owns, weigh its recorded item as a candidate cause before anything new.`
    : ''

  // A DECLARED "CANNOT" (ADR-0027, now here too). Accepted only with evidence AND what was ruled
  // out first: this is the one field an agent could reach for to escape hard work. Accepted, it
  // records the condition and ends ITS attempts; the gate keeps working its other reds.
  const cannotFix = (res, what, human) => {
    const kinds = []
    for (const cf of (Array.isArray(res?.cannot_fix) ? res.cannot_fix : [])) {
      if (!cf?.kind || String(cf.evidence || '').trim().length < 12 || String(cf.tried || '').trim().length < 12) {
        log(`[test-suite/${testSuiteRepo}] a cannot_fix claim for "${cf?.kind ?? '?'}" was DROPPED — it carried no usable evidence/tried. Attempts on it continue.`)
        continue
      }
      record(String(cf.kind), `${what} — ${cf.why}; evidence: ${cf.evidence}; already ruled out: ${cf.tried}`, human)
      kinds.push(String(cf.kind))
    }
    return kinds
  }
  // THE GATE COULD NOT RUN is not a red, and re-briefing the qa-runner a third time does not make a
  // stack listen or a migration exist. The only agent that can fix the harness, the candidate stack
  // or a missing precondition is a developer — so an unrunnable gate routes to one, on the same
  // four-class ladder ADR-0027 gave the review loop, and with the same demand for a receipt.
  const firstCodeRepo = mergeOrder.find((id) => !REPOS[id].testSuite)
  let unrunnableDeclined = false
  const unblockGate = async (why, rc, target, label) => {
    const T = REPOS[target] && mergeOrder.includes(target) ? target : firstCodeRepo
    if (!T) return null
    const tPlan = repoResults[T]?.plan
    const dev = await safeAgent(
      `${tag(T, REPOS[T].build, 'gate-unblock', label)} ⛔ THE CROSS-REPO TEST-SUITE GATE DID NOT RUN for ${ticket}, and that outranks every other piece of work right now: there is no verdict at all, so nothing in this run can say this change set does not break the suite, and no amount of reading the diff substitutes for a receipt. ${shellClauseFor(T)} Work on ${tPlan?.work_branch}.
WHAT THE GATE GOT, verbatim: ${why}${rc?.command ? ` · command: \`${rc.command}\`${Number.isInteger(rc.exit_code) ? ` · exit ${rc.exit_code}` : ''}` : ' · (it reported no command)'}${rc?.summary_line ? ` · summary: "${String(rc.summary_line).slice(0, 200)}"` : ''}
THE CANDIDATE IS UNMERGED, so it is the ticket's OWN work branches that have to be up and answering, not the default branches: ${candidates.join(', ')}.
THIS REPO'S DECLARED KNOWN FALSE REDS: ${REPOS[T].knownFalseReds || '(none declared)'} — check these FIRST: if what the gate hit matches one, it is an environment failure, so reproduce it in isolation against ${tPlan?.base_branch || 'the base branch'} before treating it as real.
CLASSIFY IT, then fix that class — in this order, because each is cheaper to rule out than the next:
  (a) THE HARNESS ITSELF — the runner missing, or dependencies unresolved after a manifest change. Run the repo's install/resolve step, then re-run the check.
  (b) THE CANDIDATE STACK IS NOT UP — the suite needs a service that is not listening. Bring each one up FROM ITS OWN TICKET WORK BRANCH and PROVE it answers by probing the port. ⚠️ a harness \`run\` that probes and then tears its server down has not given you a stack: it prints an UP verdict while nothing listens — start it in the background and re-probe.
  (c) A DATA PRECONDITION — a migration or seed the suite assumes and nobody applied to the local store.
  (d) GENUINELY ABSENT FROM THIS ENVIRONMENT — no container runtime, no credential, no such service. THE ONLY CLASS NOTHING CAN FIX.
Keep ${REPOS[T].green}. Commit (fix(…) Refs ${ticket}) and push anything you changed — the gate re-runs against what is pushed, so an unpushed repair is not a repair.
YOU MUST END WITH A RECEIPT: the exact command you ran to prove the gate can now run, its exit code, and the runner's own summary line quoted verbatim. No receipt means the gate still cannot run, whatever you changed.
IF IT IS CLASS (d): say so in \`cannot_fix\` with kind "gate-unrunnable", the command + exit code that proves it, and what you ruled out first. That ends these attempts and is a legitimate result for a person to decide. Do NOT claim (d) to avoid (a)–(c) — the classes above are ordered by how cheap they are to rule out, so rule them out.`
        + BUILD_DISCIPLINE + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE,
      { agentType: REPOS[T].build, phase: 'Test suite', label: `gate-unblock:${ticket}:${T}#${label}`, schema: DEV_SCHEMA },
    )
    log(`[test-suite/${testSuiteRepo}] unblock pass ${label} in ${T}: ${dev?.summary?.slice(0, 100) ?? 'no summary'}`)
    if (cannotFix(dev, `the cross-repo gate could not be made to run in ${T}`,
      `unblock the gate by hand (or accept that this environment cannot run it), then re-run the dev-cycle — no receipt exists for this change set`).includes('gate-unrunnable')) unrunnableDeclined = true
    return dev
  }

  let ts = await safeAgent(gatePrompt(), gateOpts())
  log(`Test-suite gate [${testSuiteRepo}] (scoped: ticket + regression): ${ts?.passed ? 'PASS' : `${ts?.failures?.length ?? '?'} failure(s)`}`)
  tick(`test-suite:${testSuiteRepo}`)

  // 4a. NEVER FAIL OPEN. A gate result is only worth what its evidence is worth, so the
  // verdict is checked twice before it counts: the receipt must describe a real command, and
  // a SECOND agent must find the result on the ticket. Mirrors the code reviewer's green-gate
  // rule at review time: a gate that could not run HALTS rather than passing.
  const rc = ts?.receipt
  // `let`, not `const`: the repair loop below re-runs the gate and re-audits, so both are reassigned.
  let receiptOk = !!(rc?.command && Number.isInteger(rc.exit_code) && rc.summary_line)
  let audit = await safeAgent(
    `${tag(testSuiteRepo, 'qa-runner', 'test-suite-audit')} AUDIT ONLY — run no tests, fix nothing. The ${ticket} test-suite gate (${testSuiteRepo}) claims: exit_code=${rc?.exit_code ?? '(none)'}, summary="${(rc?.summary_line || '(none)').slice(0, 160)}". THIS RUN IS r${RUN_SEQ}, so the stamp you are looking for begins \`run r${RUN_SEQ}\`. Read the marked report comment for THIS suite repo — \`scripts/tracker/find-ticket-comment.sh ${ticket} --marker "[test-report · ${testSuiteRepo}]"\` — and decide ONE thing: does it report THIS run? The report is UPDATED IN PLACE on every run, so its mere existence proves nothing: match its \`run r<n> · <UTC> · candidate …\` stamp and its summary against the claim above. An older stamp, a candidate sha that is not this run's (${candidates.join(', ')}), or a summary that contradicts the claim ⇒ posted:false with what you saw in \`detail\` — that is a gate recorded as NOT RUN, which is the correct answer, not a technicality. No comment at all ⇒ posted:false. Never re-run a test and never edit the comment; read and judge.`,
    { agentType: 'qa-runner', phase: 'Test suite', label: `audit:${ticket}:${testSuiteRepo}`, schema: RESULT_AUDIT_SCHEMA },
  )
  // ADR-0027 — an unverifiable gate gets bounded REPAIR attempts before it is recorded, instead of
  // ending the phase on the first miss. The two causes have different repairs and the agent is told
  // which one it is: a missing receipt means the run itself has to be re-done and quoted properly;
  // a report that cannot be found on the ticket means the RESULT never landed, which is a reporting
  // fix, not a re-run. What does not change is the verdict: no receipt and no findable result means
  // NOT RUN, and not run can never read as a pass however many attempts it took.
  let repair = 0
  let verifyFail = null
  while (!receiptOk || !audit?.posted) {
    verifyFail = !receiptOk
      ? 'the gate returned no usable receipt (command + exit code + summary line)'
      : `an independent read of the ticket found no result comment for this run (${audit?.detail || 'no detail'})`
    if (repair >= TEST_SUITE.maxSuiteRepairAttempts) {
      log(`⛔ TEST-SUITE GATE UNVERIFIED [${testSuiteRepo}] after ${repair} repair attempt(s) — ${verifyFail}. Treating the verdict as NOT RUN, never as a pass.`)
      // Not when a developer already declared the environment cannot run it: that record carries
      // the class and the proof, and this one would be a second row for the same condition.
      if (!unrunnableDeclined) record('gate-unverified', `the cross-repo gate could not be made to report a verifiable result in ${repair} attempt(s): ${verifyFail}`,
        `run this suite's scope by hand against the candidate branches and post the receipt, then re-run the dev-cycle — no verified result exists for this change set`)
      return suiteResult({ unverified: true, why: verifyFail })
    }
    repair++
    log(`⚠️ [test-suite] ${testSuiteRepo} verdict UNVERIFIABLE (${verifyFail}) — repair attempt ${repair}/${TEST_SUITE.maxSuiteRepairAttempts}.`)
    // A MISSING RECEIPT after one honest attempt is rarely a reporting problem: the qa-runner is
    // usually telling us the suite would not run. So every attempt after the first sends a
    // developer at the stack FIRST, and the qa-runner then re-runs against a repaired one. A
    // missing REPORT is different — that is genuinely the runner's own to re-post, no dev needed.
    if (!receiptOk && repair > 1 && !unrunnableDeclined) await unblockGate(verifyFail, ts?.receipt, firstCodeRepo, `verify${repair}`)
    const redo = await safeAgent(
      gatePrompt(`⛔ YOUR PREVIOUS VERDICT COULD NOT BE VERIFIED, so it does not count — ${verifyFail}. ${receiptOk
        ? `The RUN is not the problem: your result never reached the ticket where an independent reader can find it. Re-post it with /report-test-results ${ticket}, as r${RUN_SEQ}, and make sure the marker line \`[test-report · ${testSuiteRepo}]\` is the body's FIRST line and the stamp begins \`run r${RUN_SEQ}\` — a stamp that does not match is exactly what made this unverifiable. Then re-state the same receipt; do NOT re-run the suite just to satisfy this.`
        : `You must ACTUALLY RUN the scoped suite and quote its own output: the exact command line, its integer exit code, and the runner's own summary line verbatim. A verdict with no receipt is indistinguishable from a suite that never ran, and is treated as such.`}`),
      gateOpts(`verify${repair}`),
    )
    if (!redo) {
      record('gate-agent-crashed', `the gate agent returned no structured verdict on repair attempt ${repair} — the last thing known is: ${verifyFail}`,
        `re-run the dev-cycle; if the gate agent dies again, run this suite's scope by hand and post the receipt`)
      break
    }
    ts = redo
    const rc2 = ts?.receipt
    receiptOk = !!(rc2?.command && Number.isInteger(rc2.exit_code) && rc2.summary_line)
    audit = await safeAgent(
      `${tag(testSuiteRepo, 'qa-runner', 'test-suite-audit')} AUDIT ONLY — run no tests, fix nothing. Re-check after repair attempt ${repair}. THIS RUN IS r${RUN_SEQ}, so the stamp you are looking for begins \`run r${RUN_SEQ}\`. Read the marked report comment for THIS suite repo — \`scripts/tracker/find-ticket-comment.sh ${ticket} --marker "[test-report · ${testSuiteRepo}]"\` — and decide ONE thing: does it report THIS run? Answer posted:true only if the stamp matches this run and the summary matches the claim exit_code=${ts?.receipt?.exit_code ?? '(none)'}.` + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE,
      { agentType: 'qa-runner', phase: 'Test suite', label: `audit:${ticket}:${testSuiteRepo}#verify${repair}`, schema: RESULT_AUDIT_SCHEMA },
    )
  }
  if (!receiptOk || !audit?.posted) {
    log(`⛔ TEST-SUITE GATE UNVERIFIED [${testSuiteRepo}] — ${verifyFail || 'the verdict could not be verified'}. Treating the verdict as NOT RUN, never as a pass.`)
    if (!blocking.length) record('gate-unverified', `the gate's verdict could not be verified: ${verifyFail || 'no reason reported'}`,
      `run this suite's scope by hand against the candidate branches and post the receipt, then re-run the dev-cycle`)
    return suiteResult({ unverified: true, why: verifyFail || 'the verdict could not be verified' })
  }
  if (repair) log(`✅ [test-suite] ${testSuiteRepo} verdict verified after ${repair} repair attempt(s).`)

  // C4 — bounded red-triage loop. Every ending is RECORDED with its evidence and never fails open
  // (ADR-0028): rounds exhausted, an unclassified red, every red pre_existing_on_base, a fix whose
  // scoped quality check (docs/adr/0024) never clears inside its own attempt bound, or a developer's
  // evidenced `cannot_fix` on one red. None of them stops the loop — a recorded item stops the
  // MERGE, which is the only thing a halt here was ever load-bearing for.
  // A ROUND BOUNDS ATTEMPTS, NOT HYPOTHESES — and that is how a wrong diagnosis survives one.
  // Measured: a spec-aborting error was diagnosed as a defect in the test runner, "fixable only by
  // a repo-wide version bump". The next round re-ran the same spec, got a byte-identical failure,
  // and recorded it as CONFIRMATION — verbatim, "No new fix attempted". Two rounds gone. The real
  // cause was one line in a fixture, and it was derivable from screenshots the FIRST round had
  // already captured: the error being reported was the mask, not the fault. So when a round meets
  // the same failure signature as the last one, its brief stops asking for a re-run and starts
  // asking for a re-derivation.
  const tsSignature = (v) => (v?.triage || []).map((t) => `${t?.repo || '?'}:${t?.case || '?'}:${t?.kind || '?'}`).sort().join('|')
  let prevSignature = null
  let tsRound = 0
  while (!ts?.passed && tsRound < MAX_TEST_SUITE_FIX_ROUNDS) {
    const triage = (ts?.triage || []).filter((t) => t?.case && t?.kind)
    const preExisting = triage.filter((t) => t.pre_existing_on_base === true)
    if (!triage.length) {
      record('gate-red-unclassified', `the gate reported ${ts?.failures?.length ?? 'some'} failure(s) and classified none of them, so no red names an owner and none can be routed: ${(ts?.failures || []).map((f) => f?.case).filter(Boolean).join(', ') || ts?.conclusion || 'no detail returned'}`,
        `triage these red(s) by hand — an unclassified red names no repo, so there is no agent to send at it`)
      break
    }
    if (preExisting.length === triage.length) {
      record('reds-pre-existing-on-base', `every red in this run is ALREADY red on the base branch, so this ticket's change set is not what broke them — and a candidate cannot be validated against a base that is red: ${preExisting.map((t) => `${t.case} (${t.evidence || 'no evidence reported'})`).join(' | ')}`,
        `fix the base branch, or waive these cases for this ticket — nothing ${ticket} does can turn this gate green`)
      break
    }
    // ADR-0028 — ALL THREE RED KINDS route now. Only `app` ever did, so a `prereq` or an
    // `automation` red got no agent at all: the round counter ticked, the suite re-ran
    // byte-identically, and the gate "did not converge" having never once been asked to fix what it
    // found. Converting the halt to a record without routing these would be the worst of both — a
    // loop that does not halt and does not work either.
    const reds = triage.filter((t) => t.pre_existing_on_base !== true && ['app', 'prereq', 'automation'].includes(t.kind))
    tsRound++
    // Reds this round actually landed a fix for. A round that routed NOTHING — every red unowned,
    // or every one declined with evidence — must not re-run the gate: nothing on any branch moved,
    // so the verdict would be byte-identical, and paying for a re-run to learn that is the exact
    // "you already know it reproduces" waste the re-derive brief below exists to stop.
    let workedThisRound = 0
    for (const t of reds) {
      // WHO OWNS THIS RED. `app` lands in the repo the gate attributed it to. `automation` is the
      // suite's own spec, so it lands in the suite repo. `prereq` is a stack or data failure that
      // usually names no repo at all — it lands in the attributed one if there is one, else the
      // first code repo, the same fallback the load-test attribution uses.
      // The fallback is for `prereq` ONLY. An `app` red names a repo because the gate could see
      // which one it was, so a name this run cannot resolve is a finding about SCOPE — sending its
      // fix to an unrelated repo would be a confident wrong answer, which is worse than a record.
      const owner = t.kind === 'automation' ? testSuiteRepo
        : (REPOS[t.repo] && mergeOrder.includes(t.repo)) ? t.repo
        : t.kind === 'prereq' ? firstCodeRepo
        : null
      if (!owner) {
        record('gate-red-unowned', `the gate attributed the red "${t.case}" to ${t.repo || '(no repo named)'}, which is not in this run's scope, so no agent here owns it: ${t.evidence || 'no evidence reported'}`,
          `widen ${ticket} to the repo that carries this red, or fix it there by hand`)
        continue
      }
      // Normalized so every reference below reads `red.repo` whatever the kind resolved to.
      const red = { ...t, repo: owner }
      const rDesc = REPOS[red.repo]
      const rBranch = repoResults[red.repo]?.plan?.work_branch
      const rPr = repoResults[red.repo]?.pr
      // SCOPED QUALITY CHECK (docs/adr/0024). No code reviewer here: this repo's functional
      // correctness was already cleared at Review, and re-running that gate over a QA-attributed
      // fix re-derives a judgement the run already holds. What a fix made under gate pressure can
      // still cost is the ground the ORIGINAL review held — smells, debt, a slower path — so only
      // the gates this repo actually DECLARES judge it, over the fix diff and nothing else. A repo
      // declaring neither gets no agent check at all: the suite re-run is the check it always had.
      const checks = [
        rDesc.guard && { key: 'guard', role: 'guardian-engineer', axis: `a code smell or tech-debt regression this repo's guardian bar rejects (its declared sensitive areas: ${rDesc.guardianFocus || 'none declared — judge the diff on this repo\'s own standards'})` },
        rDesc.perf && { key: 'perf', role: 'performance-engineer', axis: 'a performance regression on the flow this fix touched — a new query per iteration, an unindexed lookup, an added round-trip, a rebuild storm' },
      ].filter(Boolean)
      // The inner bound is its OWN counter, not a slice of the round budget: a ROUND still means
      // one classify → fix every red → re-run cycle, and a rejected check sends THAT red's fix back
      // to the developer inside the current cycle, BEFORE the suite is re-run. That ordering is the
      // point — a fix whose QA-visible symptom happens to go green must never ship un-checked.
      // One brief per red KIND. The three failures look nothing alike — a product defect, a stack
      // or data precondition, and the suite's own spec being wrong — and the fix for each is in a
      // different place, so a single brief would have to be vague about all three.
      const redBrief = red.kind === 'automation'
        ? `A cross-repo test-suite red for ${ticket} is the SUITE'S OWN: the gate classified "${red.case}" as an automation failure, so the spec, its Page Object or its fixture is what is wrong, not the product. EVIDENCE (what the gate observed): ${red.evidence}. ${shellClauseFor(red.repo)} Work on ${rBranch}. Fix the spec/fixture so it asserts the behaviour ${ticket} actually specifies — and be sure of that before you touch it: a spec bent to match whatever the app currently does is exactly how a real defect ships green. If what you find is that the APP is wrong after all, do NOT change the spec: say so in your summary and name the repo that carries it, and the gate re-classifies it on the next round.`
        : red.kind === 'prereq'
          ? `A cross-repo test-suite red for ${ticket} is a PRECONDITION failure: the gate never got "${red.case}" as far as an assertion, because something the suite assumes was not there. EVIDENCE (what the gate observed): ${red.evidence}. ${shellClauseFor(red.repo)} Work on ${rBranch}. THE CANDIDATE IS UNMERGED, so it is the ticket's own work branches that have to be up and answering, not the default branches: ${candidates.join(', ')}. CLASSIFY IT, then fix that class, cheapest to rule out first: (a) the harness itself — the runner missing or dependencies unresolved after a manifest change · (b) a service in the candidate stack not listening (⚠️ a harness \`run\` that probes and then tears its server down has not given you a stack: it prints an UP verdict while nothing listens — start it in the background and re-probe) · (c) a migration or seed nobody applied to the local store · (d) genuinely absent from this environment — no container runtime, no credential, no such service — THE ONLY CLASS NOTHING CAN FIX. Do NOT touch the test-suite repo or its specs: a precondition is not a spec bug.`
          : `A cross-repo test-suite red for ${ticket} was attributed to ${red.repo} by the gate. FAILING CASE: ${red.case}. EVIDENCE (what the gate observed): ${red.evidence}. ${shellClauseFor(red.repo)} Work on ${rBranch}. The failing spec IS the acceptance criterion: reproduce it with a failing test of THIS repo's own suite first (/tdd), then fix the cause. Do NOT touch the test-suite repo, its specs or its thresholds: changing the spec to match the behaviour is not fixing the bug.`
      // ADR-0028's sanctioned exit for ONE red, so an immovable one stops eating attempts instead
      // of being ground at until the round budget is gone. Priced to be expensive: no evidence and
      // no `tried`, no claim.
      const cannotClause = ` IF THIS RED GENUINELY CANNOT BE FIXED HERE — this environment cannot provide what it needs, or the behaviour the spec demands is not what ${ticket} asks for — say so in \`cannot_fix\` with kind "${red.kind === 'prereq' ? 'gate-unrunnable' : red.kind === 'automation' ? 'gate-red-automation' : 'gate-red'}", the command + exit code (or the assertion) that PROVES it, and what you ruled out first. That ends the attempts on THIS red only: every other red in this run keeps being worked, and the condition goes to a person. It is NOT a pass, and without evidence and \`tried\` it is refused and the attempts continue.`
      let cleared = false
      let declined = false
      let attempt = 0
      let rejection = ''
      while (attempt < MAX_GATE_FIX_ATTEMPTS) {
        attempt++
        const fx = await safeAgent(
          `${tag(red.repo, rDesc.build, 'gate-fix', tsRound)} ${redBrief} Keep ${rDesc.green}, commit (fix(…) Refs ${ticket}) and PUSH (\`git -C ${absOf(red.repo)} push\`) — the gate re-runs against the pushed candidate, so an unpushed fix cannot be measured.${checks.length ? ` YOUR FIX IS CHECKED ON ${checks.map((c) => c.key.toUpperCase()).join(' + ')}, over the diff you leave behind — green is necessary, not sufficient: no smell, no debt, no slower path introduced to get there.` : ''}${cannotClause}${rejection}`
            + BUILD_DISCIPLINE + PONYTAIL_DIRECTIVE + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE,
          { agentType: rDesc.build, phase: 'Test suite', label: `gate-fix:${ticket}:${red.repo}#${tsRound}.${attempt}`, schema: DEV_SCHEMA },
        )
        log(`[test-suite] round ${tsRound}, attempt ${attempt}: ${red.repo} fix for ${red.case} — ${fx?.summary?.slice(0, 80) ?? 'no summary'}`)
        if (cannotFix(fx, `the red "${red.case}" (${red.kind}, ${red.repo}) cannot be fixed inside this gate`,
          `decide whether ${ticket} can ship with this case red, or the ticket/the environment has to change — the gate worked it and it did not move`).length) {
          declined = true
          break
        }
        if (!checks.length) { cleared = true; break }
        const fixedFiles = (Array.isArray(fx?.fixed) ? fx.fixed : []).join(', ') || `unreported — locate them from the latest fix(${ticket}) commits on ${rBranch}`
        const verdicts = await parallel(checks.map((chk) => () => safeAgent(
          `${tag(red.repo, chk.role, `gate-${chk.key}`, tsRound)} ${levelDirective} SCOPED QUALITY CHECK of a QA-attributed fix for ${ticket} in ${red.repo} — NOT a fresh review and NOT a new audit of this repo. Its code review already passed in this run's Review phase; since then exactly ONE fix landed on ${rBranch}, for the cross-repo test-suite red "${red.case}". ${shellClauseFor(red.repo)} Judge ONLY that fix's diff (\`git -C ${absOf(red.repo)} fetch origin\`, then read the fix commits on ${rBranch}; the fix agent reports its files as: ${fixedFiles}). ONE QUESTION: does THIS diff introduce ${chk.axis} that your gate would have held the merge for at first review? Raise NOTHING else — a finding outside this diff, however real, is out of scope and belongs in your \`conclusion\` for a human, never in \`blocking\`. Do not re-scan the repo, do not re-profile broadly, and file no Improvement ticket. Post each blocking finding inline on the open PR/MR (${rPr?.pr_url || 'see the repo'}) at file:line via \`scripts/vcs/pr-comment.sh ${rPr?.pr_number ?? '<number>'} --path <file> --line <n> --body "<finding + the fix>"\`, prefixed \`[gate:${chk.key}]\`. Return passed:true when this diff is clean on your axis, passed:false with the blocking list when it is not — and if you genuinely could not judge it, passed:false + gate_unavailable:true + unavailable_reason (what you tried, why it failed): an un-run check is never a pass here, it sends the fix back.`
            + VERDICT_BEFORE_BUDGET + ADAPTER_DISCIPLINE + LANGUAGE_DIRECTIVE + CAVEMAN_DIRECTIVE + HEADROOM_DIRECTIVE,
          { agentType: chk.role, phase: 'Test suite', label: `gate-${chk.key}:${ticket}:${red.repo}#${tsRound}.${attempt}`, schema: GATE_SCHEMA },
        )))
        const rejected = checks.filter((chk, i) => !(verdicts[i]?.passed === true && verdicts[i]?.gate_unavailable !== true))
        if (!rejected.length) {
          cleared = true
          log(`✅ [test-suite] ${red.repo} fix for ${red.case} cleared its scoped ${checks.map((c) => c.key).join('+')} check on attempt ${attempt}.`)
          unrecord('gate-fix-unchecked', red.case)
          break
        }
        const detail = rejected.map((chk, i) => {
          const v = verdicts[checks.indexOf(chk)]
          const items = (v?.blocking || []).map((b) => `${b?.title || 'unnamed finding'}${b?.scope ? ` at ${b.scope}` : ''}${b?.evidence ? ` (${b.evidence})` : ''}`).join('; ')
          return `${chk.key}: ${v?.gate_unavailable ? `could not run — ${v.unavailable_reason || 'no reason given'}` : (items || v?.conclusion || 'no detail')}`
        }).join(' | ')
        rejection = ` PRIOR ATTEMPT REJECTED (attempt ${attempt} of ${MAX_GATE_FIX_ATTEMPTS}) — the scoped quality check on your last fix did not clear: ${detail}. Address exactly that, on the same failing case, without widening the change.`
        log(`⚠️ [test-suite] scoped ${rejected.map((c) => c.key).join('+')} check REJECTED the ${red.repo} fix for ${red.case} (attempt ${attempt}/${MAX_GATE_FIX_ATTEMPTS}) — ${detail.slice(0, 200)}. ${attempt < MAX_GATE_FIX_ATTEMPTS ? 'Back to the developer, inside this round; the suite is NOT re-run yet.' : 'No attempts left.'}`)
      }
      // AN UNCHECKED FIX MUST NEVER READ AS A PASS: the suite going green afterwards would
      // otherwise be the whole verdict, and the un-cleared diff would ride the merge train. What
      // changed in ADR-0028 is only WHICH mechanism holds that line. It used to be this early
      // return, which also threw away every red after this one in the same round — measured, one
      // repo's un-cleared fix abandoned two sibling reds that were closable. Now the RECORD holds
      // it: this suite cannot read as passed while it stands, and the loop keeps working the rest.
      if (!declined) workedThisRound++
      if (!cleared && !declined) {
        log(`⛔ [test-suite] quality check for ${red.case} (${red.repo}) did not clear within ${MAX_GATE_FIX_ATTEMPTS} attempt(s) — recorded; this suite cannot read as passed, and the gate continues on its other reds.`)
        record('gate-fix-unchecked', `the fix for the red "${red.case}" in ${red.repo} was rejected by its own scoped ${checks.map((c) => c.key).join('+')} check ${MAX_GATE_FIX_ATTEMPTS} time(s) (round ${tsRound}) and is still on ${rBranch} un-cleared`,
          `read the [gate:*] thread(s) on ${rPr?.pr_url || `the ${red.repo} PR/MR`} and either land an acceptable fix by hand or accept the one that is there`,
          red.case)
      }
    }
    if (!workedThisRound) {
      log(`[test-suite] round ${tsRound} routed no fix at all (${reds.length} red(s), all unowned or declined) — not re-running a gate whose inputs did not change.`)
      break
    }
    const sigBefore = tsSignature(ts)
    const repeated = prevSignature !== null && sigBefore === prevSignature
    const rederive = repeated
      ? ` ⛔ SAME FAILURE SIGNATURE AS THE PREVIOUS ROUND (${sigBefore || 'unclassified'}). Reproducing it again proves nothing — you already know it reproduces. Treat the previous round's causal claim as a HYPOTHESIS TO DISPROVE, not a finding: re-derive the cause from the ARTIFACTS this run and the last one already captured (screenshots, the runner's own command log and any guidance it printed, the failing frame, the fixture and config values the failing path actually reads), and state in your triage WHICH prior evidence you re-read and what it says. An identical re-run recorded as "confirmed, no new fix attempted" is not an acceptable outcome for this round. And be suspicious of the error you can see: an error thrown while REPORTING a failure is a mask, not the fault.`
      : ''
    prevSignature = sigBefore
    const again = await safeAgent(gatePrompt(`RE-RUN after round ${tsRound}: run ONLY the previously failing case(s) plus the ticket's own spec scope.${rederive}`), gateOpts(tsRound))
    if (!again) {
      record('gate-agent-crashed', `the gate agent returned no structured verdict on the round-${tsRound} re-run, so this run holds no verdict for the fixes it just landed`,
        `re-run the dev-cycle; if the gate agent dies again, run this suite's scope by hand and post the receipt`)
      break
    }
    if (repeated) log(`[test-suite] round ${tsRound + 1} briefed to RE-DERIVE, not re-confirm — the failure signature did not change (${sigBefore || 'unclassified'}).`)
    ts = again
    tick(`test-suite:${testSuiteRepo}:round-${tsRound}`)
  }

  // The generic record is for the ROUND BUDGET running out. Every early break above already
  // recorded its own, more specific reason, and adding this on top would give the reader two rows
  // for one condition — with a round count that never happened. `|| !blocking.length` is the
  // never-fail-open backstop: a red suite always leaves at least one record behind.
  if (!ts?.passed && (tsRound >= MAX_TEST_SUITE_FIX_ROUNDS || !blocking.length)) {
    log(`⚠️ Test-suite gate [${testSuiteRepo}] still red after ${tsRound} triage round(s) of ${MAX_TEST_SUITE_FIX_ROUNDS} — recorded. Nothing merges.`)
    record('gate-red', `the suite did not go green within ${tsRound} triage round(s) (budget ${MAX_TEST_SUITE_FIX_ROUNDS}): ${(ts?.triage || []).map((t) => `${t?.case} (${t?.kind}${t?.repo ? ` · ${t.repo}` : ''})`).join(' | ') || ts?.conclusion || 'no triage returned'}`,
      `triage the remaining red(s) by hand — every routed fix this run could attempt has been attempted`)
  }

  // 4b. LOAD SUITE — green is only half the bar. A load suite exists to measure NUMBERS, so
  // the candidate must also be equal-or-better than the same scenario on the ticket's base
  // branch. Three verdicts, and `unavailable` is a real one: when the environment's own
  // run-to-run noise floor is wider than the effect, no honest call exists, so the gate
  // loud-skips instead of inventing one in either direction.
  // ADR-0028 — gated on the FUNCTIONAL verdict, which used to be implicit in the early return above.
  // A comparison measured on a candidate whose own specs are red is not a measurement of anything,
  // and attribution + a fix + a re-run against it is the "expensive garbage is still garbage" case
  // ADR-0027 named: the red is already recorded, so nothing is lost by not paying for it.
  if (isLoadSuite && ts?.passed) {
    let lt = ts?.loadtest
    let ltRound = 0
    // Set when the developer's own evidenced `cannot_fix` already recorded this regression: its
    // record carries the number AND what was ruled out, so the generic one below would be a second
    // row for one condition — and a reader counting blocking items would double-count it.
    let ltDeclared = false
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
        `${tag(fixRepo, 'developer', 'loadtest-fix', ltRound)} Fix the ATTRIBUTED load-test regression for ${ticket} in ${fixRepo}, on ${repoResults[fixRepo]?.plan?.work_branch}. Cause (your own attribution): ${attribution.reasoning}${attribution.evidence ? ` — evidence: ${attribution.evidence}` : ''}. Measured: ${(lt.regressed || []).join('; ') || 'see the comparison table on the PR/MR'}. Fix the cause, keep ${REPOS[fixRepo]?.green}, commit (fix(…) Refs ${ticket}) and push — the gate re-runs the candidate against the SAME cached baseline, so the next measurement is comparable only if you push. Do not touch the load-test repo or its thresholds: moving the bar is not fixing the regression.
THE NUMBERS, so you can tell a small avoidable cost from a structural one: candidate ${lt.candidate_sha || '(sha not reported)'} vs base ${lt.base_sha || '(sha not reported)'}, and the effective threshold per metric is max(${LOADTEST.tolerancePct}%, the environment's own noise floor measured from ${LOADTEST.noiseRuns} base runs). Just over the line is usually one avoidable unit of work per request; a multiple of it is structural, and the two want different fixes.${lt.table ? ` The gate's own comparison table: ${String(lt.table).slice(0, 900)}` : ''}
WHERE REQUEST-PATH TIME ACTUALLY GOES — check in this order, cheapest to rule out first: a query per iteration where one would do (N+1) · a predicate this change introduced with no index behind it · the same value resolved, deserialized or hashed twice per request · a lookup added to a hot path that could be resolved once per batch · work newly done synchronously that the response does not depend on.
FORBIDDEN, and every one of them tempting: do NOT relax a threshold · do NOT re-baseline · do NOT re-run hoping for a friendlier sample · do NOT move the work behind a flag the scenario does not exercise · do NOT cache in a way that changes what a caller observes. Each of those makes the number go green without making the system faster, which is the single outcome this gate exists to prevent.
IF THE COST IS INHERENT to the behaviour ${ticket} requires — the change adds a lookup that genuinely cannot be avoided, batched, or moved off the request path — say so in \`cannot_fix\` with kind "loadtest-regression", the number, and what you tried. That is a legitimate result and a decision for a person. It is NOT a pass, and it is not a way out of looking.`,
        { agentType: 'developer', phase: 'Test suite', label: `lt-fix:${ticket}:${ltRound}`, schema: DEV_SCHEMA },
      )
      log(`[loadtest] round ${ltRound} fix: ${fix?.summary?.slice(0, 80) ?? 'no summary'}`)
      // The brief has ALWAYS ended with "if the cost is inherent, say so in cannot_fix" — and until
      // ADR-0028 nothing read the field, so an honest, evidenced answer bought another round of the
      // same work. Read it: an accepted claim ends the load rounds and records the number.
      if (cannotFix(fix, `the measured load regression in ${fixRepo} is inherent to what ${ticket} requires`,
        `decide whether ${ticket} is worth this cost — the number is real and no cheaper implementation was found`).length) {
        log(`[loadtest] round ${ltRound}: developer declared the cost inherent, with evidence — no further rounds.`)
        ltDeclared = true
        break
      }
      const reRun = await safeAgent(
        `${tag(testSuiteRepo, 'qa-runner', 'test-suite', ltRound)} RE-RUN the load-test gate for ${ticket} after a fix in ${fixRepo} (round ${ltRound}). Rebuild the candidate from the ticket work branches — ${candidates.join(', ')} — then invoke /loadtest-baseline-gate ${ticket} again. The baseline is UNCHANGED (same base SHA), so reuse the cached base runs and measure the candidate only. Post the fresh comparison to the ticket and the PR/MR, and return the same structured result as before — receipt included.${RECEIPT_CLAUSE}`,
        { agentType: 'qa-runner', phase: 'Test suite', label: `test-suite:${ticket}:${testSuiteRepo}:r${ltRound}`, schema: TEST_SUITE_SCHEMA },
      )
      if (reRun) { ts = reRun; lt = reRun.loadtest }
      tick(`loadtest-round-${testSuiteRepo}-${ltRound}`)
    }
    ts = { ...ts, loadtest: lt }
    if (lt?.verdict === 'fail') {
      log(`⛔ LOAD-TEST REGRESSION stands after ${ltRound} fix round(s) [${testSuiteRepo}] — ${(lt.regressed || []).join('; ')}. The candidate is slower than ${lt.base_sha || 'base'} by more than the environment's own noise. Recorded; nothing merges.`)
      if (!ltDeclared) record('loadtest-regression', `the candidate is measurably slower than ${lt.base_sha || 'base'} after ${ltRound} fix round(s), by more than this environment's own noise floor: ${(lt.regressed || []).join('; ') || 'see the comparison table on the PR/MR'}`,
        `decide whether ${ticket} ships at this cost, or the regression is fixed by hand first — the suite is GREEN, so nothing but this number is holding it`)
    // `else if`, not `if`: the 'fail' branch above no longer returns, so a plain `if` would fall
    // through to the ✅ line below and log a passed baseline for a measured regression.
    } else if (lt?.verdict === 'unavailable' || !lt?.verdict) {
      loadtestGateUnavailable = `The load-test gate could not judge ${ticket} (${testSuiteRepo}) against its base branch: ${(lt?.too_noisy || []).join('; ') || 'no baseline comparison was returned'}. The suite is GREEN, but "equal-or-better than base" is UNPROVEN — do NOT describe this run as performance-validated.`
      log(`⚠️  LOAD-TEST BASELINE UNAVAILABLE [${testSuiteRepo}] — ${loadtestGateUnavailable}`)
    } else {
      log(`✅ Load-test baseline [${testSuiteRepo}]: no tracked metric degraded past its threshold vs ${lt.base_sha || 'base'}${lt.baseline_cached ? ' (cached baseline)' : ''}.`)
    }
  }

  return suiteResult()
}

if (scope.test_suite?.needed && testSuiteRepos.length && mergeOrder.some((id) => !REPOS[id].testSuite)) {
  phase('Test suite')
  // No status move on an advisory run: "Testing" tells the team the change set is ready to be
  // tested, and it is not — a repo is carrying a recorded blocking item. The gate still runs.
  if (!abortPayload) await moveTicket(['testing'], 'cross-repo test-suite gate running', 'Test suite')
  const tsRunNow = testSuiteRepos.filter((id) => !tsSkippable(id))
  const tsResumed = testSuiteRepos.filter((id) => tsSkippable(id))
  tsResumed.forEach((id) => log(`[test-suite] ${id} SKIPPED — run state says this suite already passed and no work branch has moved since.`))
  // C5 — every scoped test-suite repo's gate fans out in parallel; never calls phase() inside
  // (same rule as runRepoPipeline) — phase('Test suite') above is set once, outside the fan-out.
  const suiteVerdicts = [
    ...tsResumed.map((id) => ({ suite: id, verdict: { passed: true } })),
    ...(await parallel(tsRunNow.map((id) => () => runSuiteGate(id)))),
  ]
  // ADR-0028's fail-open guard, and the one line that makes the whole conversion safe: a suite that
  // returned passed:true but RECORDED something the gate could not close is not a pass. Without
  // `s.blocking?.length` here, an un-cleared fix or a standing load regression would ride the merge
  // train the moment the next re-run happened to go green — the exact silent degradation trading a
  // halt for a record risks.
  const suiteFailed = suiteVerdicts.filter((s) => s && (s.unverified || s.blocking?.length || !s.verdict?.passed))
  testSuite = { suites: suiteVerdicts.map((s) => ({ suite: s.suite, passed: !!s.verdict?.passed && !s.blocking?.length, receipt: s.verdict?.receipt, loadtest: s.verdict?.loadtest, blocking: s.blocking || [] })), passed: !suiteFailed.length }
  if (suiteFailed.length) {
    // Same shape the review loop's aggregation produces, on purpose: writeSummary's blocking
    // section, the incomplete-run DM and the banner all read `blockingByRepo`, and a suite repo is
    // a repo. One mechanism, one "Blocking — needs a person" section for the reader.
    const blockingByRepo = suiteVerdicts.filter((s) => s?.blocking?.length).map((s) => ({ id: s.suite, items: s.blocking }))
    bannerBlocking(blockingByRepo, 'test-suite gate')
    const anyUnverified = suiteFailed.some((s) => s.unverified)
    const anyRed = suiteFailed.some((s) => !s.unverified && !s.verdict?.passed)
    const runStatus = anyUnverified ? 'test-suite-unverified' : anyRed ? 'test-suite-failed' : 'test-suite-unresolved'
    const why = suiteFailed.map((s) => `${s.suite}: ${s.unverified ? (s.why || 'unverified') : s.verdict?.passed ? `green, but ${s.blocking.length} recorded blocking item(s): ${s.blocking.map((b) => b.kind).join(', ')}` : `gate red${s.blocking?.length ? ` + ${s.blocking.length} recorded blocking item(s)` : ''}`}`).join(' | ')
    log(`⛔ TEST-SUITE GATE — ${why}. NOTHING merged; PR/MR left OPEN.`)
    // ADR-0029 — on an advisory run this is NOT the ending. The repos were already unresolved before
    // the gate ran, so `repo-unresolved` is the honest headline and `test-suite-*` would bury it.
    // Carry the gate's records into the abort payload and let it return below.
    if (abortPayload) {
      abortPayload.suiteBlocking = blockingByRepo
      abortPayload.suiteWhy = why
    } else {
      const summary = await writeSummary(runStatus, { ticket, mergeOrder, repoResults, testSuite, testSuiteRequested, blockingByRepo, why }, runDeferred, satisfiedRows)
      return { ticket, status: runStatus, mergeOrder, repoResults, testSuite, testSuiteRequested, blockingByRepo, why, summary, spend }
    }
  }
  log(`Test-suite gate: ALL ${testSuiteRepos.length} suite(s) PASS (${testSuiteRepos.join(', ')}).${abortPayload ? ' ADVISORY — this says the candidate does not break the suite; it does NOT approve anything, because a repo in this run is still carrying a recorded blocking item.' : ''}`)
  // The suite repos' own approval tick. They have no code reviewer — `review: null` by kind — so
  // the Review phase never judged their PR/MR at all, and nothing above would ever tick it.
  // Their gate is THIS one, with a receipt, so this is the moment their bar is cleared. Leaving
  // them permanently unapproved beside their ticked siblings would read as "these were rejected".
  //
  // NOT on an advisory run (ADR-0029): the tick is ticket-wide (ADR-0022), so ticking it here would
  // announce the whole ticket approved while another repo is carrying a recorded blocking item —
  // the precise thing that tick's ticket-wide scope exists to prevent.
  if (!abortPayload) await approvalTick(testSuiteRepos, 'Test suite',
    'the cross-repo test-suite gate ran this ticket\'s scope (its own spec(s) + the regression scope) against the pre-merge candidate and passed — quote that suite\'s receipt: command, exit code, summary line')
} else if (scope.test_suite?.needed && !testSuiteRepos.length) {
  testSuiteGateUnavailable = testSuiteGateUnavailable
    || `test-suite gate was requested but no test-suite repo reached the build set — gate did NOT run.`
  log(`⚠️  ${testSuiteGateUnavailable} The ticket is shipping WITHOUT the requested E2E validation.`)
}

// ADR-0029 — the advisory ending. The gate has done everything it could against this candidate;
// the run now ends on the repos that were never ready. Both producers' records go out in ONE list,
// so the reader gets a single "Blocking — needs a person" section covering the review loop AND the
// gate, and the next invocation carries every one of them (ADR-0027 §Across invocations).
if (abortPayload) {
  const merged = [...abortPayload.blockingByRepo]
  for (const row of (abortPayload.suiteBlocking || [])) {
    const hit = merged.find((m) => m.id === row.id)
    if (hit) hit.items = [...hit.items, ...row.items]
    else merged.push(row)
  }
  const advisoryNote = testSuite
    ? `the cross-repo test-suite gate RAN against this candidate (advisory — it approved nothing and moved nothing): ${testSuite.passed ? 'it passed, so the change set does not break the suite as it stands' : abortPayload.suiteWhy || 'it did not pass'}`
    : `the cross-repo test-suite gate did not run (not in this ticket's scope, or no suite repo reached the build set)`
  log(`⚠️ ADVISORY RUN ENDS '${abortPayload.runStatus}' — ${advisoryNote}. ${merged.reduce((n, b) => n + b.items.length, 0)} blocking item(s) carried forward.`)
  const summary = await writeSummary(abortPayload.runStatus, { ticket, ...abortPayload, blockingByRepo: merged, advisory_gate: advisoryNote, repoResults, testSuite, testSuiteRequested, testSuiteGateUnavailable }, runDeferred, satisfiedRows)
  return { ticket, status: abortPayload.runStatus, ...abortPayload, blockingByRepo: merged, advisory_gate: advisoryNote, repoResults, testSuite, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}

// DRY RUN stop — repos built/reviewed and the test-suite gate passed. Stop BEFORE the
// outward/irreversible steps (Merge, then Distribute): no squash-merge, no distribution.
if (dryRun) {
  log(`🧪 DRY RUN — all repos 'ready'${testSuite ? ` + test-suite ${testSuite.passed ? 'PASS' : 'n/a'}` : ''}; stopping before Merge + Distribute (no merge, no distribution). Per-repo: ${mergeOrder.map((id) => `${id}=${repoResults[id]?.status}`).join(', ')}.`)
  const summary = await writeSummary('dry-run', { ticket, repos: mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable }, runDeferred, satisfiedRows)
  return { ticket, status: 'dry-run', dryRun: true, repoResults, testSuite, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}

// 5. MERGE — the commit gate. After review + the test-suite gate have validated the candidate
// (PRE-merge), squash-merge UPSTREAM → DOWNSTREAM (sequential), record each SHA. Gated by
// auto-merge (workspace.config.yaml vcs.auto_merge, per-repo override via REPOS[id].autoMerge):
// when a repo opts OUT, its reviewed + validated PR/MR is left OPEN for a human and the run stops
// here — NOTHING is merged or distributed (review + the test-suite gate still ran, so the human
// merges a fully-validated candidate). Exactly like a dry-run, but with real, reviewed PRs.
if (overBudget()) return await budgetStop('Merge', { ticket, mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable }, runDeferred, satisfiedRows)
phase('Merge')
// The `!` hand-off (auto-merge ON). The squash-merge — and everything downstream (distribute,
// close) — is outward + irreversible. Under auto-mode the permission classifier clears these ONLY
// for a HUMAN running them in-session (the `!` prefix); a background Workflow agent is always
// denied ([Merge Without Review] / self-approval / [Production Deploy]). So the workflow no longer
// dispatches doomed merge/distribute agents (they burned tokens + tripped a SECURITY WARNING every
// run) — it emits the exact `!` commands, upstream->downstream, for the main session to present.
const merges = {}
const shipSteps = [] // ordered human `!` hand-off: merges (upstream->downstream), then distributes
// A DECLARED submodule pin now ships a gitlink aimed at an UNMERGED branch tip (ADR 0031), and the
// reviewer is explicitly told not to raise it. So something has to re-aim it, and the pointer-bump
// step further down could not: with `auto_merge` off — the shipped default — the loop below returns
// on its FIRST repo, so every step it would have emitted, bump included, was unreachable. That made
// the honest reading of the default configuration "commit a pointer at a branch commit, then squash
// the branch away and delete it", which strands the pointer.
//
// These are computed from the pins Kickoff actually READ, so unlike the speculative all-pairs loop
// below they name a real edge, and they are pushed BEFORE the loop so both paths carry them.
if (pinEdges.length && haveAbs) {
  pinEdges.filter((e) => mergeOrder.includes(e.downstream) && mergeOrder.includes(e.upstream)).forEach((e) => {
    const dsAbs = `${WORKSPACE_ROOT}/${REPOS[e.downstream].path}`
    const cmd = `! git -C ${dsAbs}/${e.path} fetch origin && git -C ${dsAbs}/${e.path} checkout <the ${e.upstream} merge sha> && git -C ${dsAbs} add ${e.path} && git -C ${dsAbs} commit -m ${JSON.stringify(`chore(${e.path}): re-aim the pin at the merged ${ticket} commit\n\nRefs ${ticket}`)} && git -C ${dsAbs} push`
    shipSteps.push({ repo: e.downstream, kind: 'submodule-repin', upstream: e.upstream, submodule_path: e.path, after: `merge:${e.upstream}`, command_template: cmd, resolve: `REQUIRED, not optional: ${e.downstream} currently pins ${e.path} at ${e.upstream}'s unmerged branch tip. Run this AFTER ${e.upstream} merges and BEFORE ${e.downstream} does; the main session fills <the ${e.upstream} merge sha> from that merge's output.` })
    log(`🔗 REQUIRED RE-PIN — ${e.downstream} pins ${e.path} at ${e.upstream}'s UNMERGED branch tip (that is how it was built this round). After ${e.upstream} merges, and BEFORE ${e.downstream} merges:\n    ${cmd.split(' && ').join('\n      && ')}\n    Skipping it lands a pointer at a commit the squash-merge replaced and the branch delete removed.`)
  })
}
for (const id of mergeOrder) {
  const rr = repoResults[id], desc = REPOS[id], rp = rr.plan
  if ((desc.autoMerge ?? AUTO_MERGE) === false) {
    merges[id] = { merged: false, base: rp.base_branch, note: 'auto-merge disabled — PR/MR left open for a human', pr: rr.pr?.pr_url }
    log(`⏸️ [${id}] auto-merge disabled — reviewed + validated PR/MR left OPEN for human merge: ${rr.pr?.pr_url ?? '(see run)'}. Nothing merged or distributed this run.`)
    const summary = await writeSummary('merge-skipped', { ticket, mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable, merges, shipSteps }, runDeferred, satisfiedRows)
    // NOTIFY (final phase) — auto-merge is off, so the validated PR/MR are awaiting a human:
    // ping the configured chat channel to review them. No-op unless notify.enabled.
    const notify = await notifyReview(mergeOrder)
    return { ticket, status: 'merge-skipped', haltedAt: id, repoResults, merges, shipSteps, testSuite, testSuiteRequested, testSuiteGateUnavailable, qualityGateUnavailable, loadtestGateUnavailable, summary, notify, spend }
  }
  // AUTO-MERGE ON → emit the `!` merge command (never dispatch the doomed agent; see above).
  // TWO commands, not `cd X && writer`: merge-pr.sh is a mutating adapter, and the compound form
  // is denied by the workspace guard — so the one-liner this phase used to emit could never run.
  // The pair is NOT "cd, then rely on it": each `!` line is its own shell, and PR/MR numbers
  // COLLIDE across this workspace's repos, so the writer is ROUTED with VCS_REPO exactly as
  // approvalTick routes its own — the first line only prints the value the second one needs.
  const absRepo = absOf(id)
  const mergeCmd = `! git -C ${absRepo} remote get-url origin\n! VCS_REPO=<owner/repo from that URL — strip the leading git@host:/https://host/ and any trailing .git> scripts/vcs/merge-pr.sh ${rr.pr?.pr_number ?? '<pr-number>'} --subject ${JSON.stringify(prTitle(rp))}`
  const repoDeferred = rr.deferred || []
  merges[id] = { merged: false, handoff: true, base: rp.base_branch, pr: rr.pr?.pr_url, command: mergeCmd, deferred: repoDeferred }
  shipSteps.push({ repo: id, kind: 'merge', pr_number: rr.pr?.pr_number ?? null, pr_url: rr.pr?.pr_url ?? null, base: rp.base_branch, command: mergeCmd, resolve: `the main session fills VCS_REPO from what the first line printed — the writer must not be left to guess its repo from a cwd`, deferred: repoDeferred })
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
    const bump = `! git -C ${dsAbs} submodule status ${desc.path} 2>/dev/null && git -C ${dsAbs}/${desc.path} fetch origin && git -C ${dsAbs}/${desc.path} checkout <the ${id} merge sha> && git -C ${dsAbs} add ${desc.path} && git -C ${dsAbs} commit -m ${JSON.stringify(`chore(${desc.path}): bump to the merged ${ticket} commit\n\nRefs ${ticket}`)} && git -C ${dsAbs} push`
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
const summary = await writeSummary('awaiting-human-ship', { ticket, mergeOrder, repoResults, merges, shipSteps, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable }, runDeferred, satisfiedRows)

return {
  ticket, status: 'awaiting-human-ship',
  repos: mergeOrder, repoResults, merges, shipSteps,
  testSuite, testSuiteRequested, testSuiteGateUnavailable, qualityGateUnavailable, loadtestGateUnavailable,
  summary, trackerReachable,
  spend, // per-phase output-token deltas; the per-repo/role table lives in summary.summary_path
}
