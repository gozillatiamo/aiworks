export const meta = {
  name: 'dev-cycle',
  description: 'Full development cycle for one ticket — MULTI-REPO. Scopes which repos a ticket touches, runs each through plan→build→PR/MR→review in dependency WAVES, validates the candidate with the cross-repo test-suite (QA) gate, MERGES upstream→downstream, then distributes the merged build, and summarizes. Provider-agnostic: VCS via scripts/vcs/ (github/gitlab), tracker via scripts/tracker/ (notion/jira). The WORKFLOW owns the ticket status (monotonic, decoupled from the per-repo agents). Pass the ticket number as args, e.g. "FM-12". A single-repo ticket collapses to a one-repo flow.',
  whenToUse: 'Run one <KEY> ticket end to end across every repo it touches — through review, the cross-repo test-suite gate, the merge, and distribution — with a single command.',
  phases: [
    { title: 'Scope', detail: 'cto: classify which repos the ticket touches + dependency order + whether the cross-repo test-suite (QA) gate applies', model: 'opus' },
    { title: 'Kickoff', detail: 'per repo: development-planner runs /ticket-kickoff (code) · qa-planner designs the test plan + automation plan (test-suite repo) → branch + plan. The WORKFLOW moves the ticket to in_progress (per-repo agents no longer touch status). If planning.to_html, each plan is also rendered to interactive HTML; if planning.auto_approve is off, the run STOPS here for human plan approval (re-run with --approve-plan).', model: 'opus' },
    { title: 'Build', detail: 'ALL scoped repos in parallel (build-order decoupled from merge-order — a build needs only the agreed contract, not a merged upstream; depends_on is still honored at Merge, upstream→downstream): the build role implements (developer TDD / qa-runner POM). No pre-PR gate — guardian/perf review on the OPEN PR/MR (Review). The test-suite repo iterates SCOPED (`npm test -- <spec>`) then runs the ticket scope — its spec(s) + regression scope — before the PR/MR.', model: 'sonnet/opus' },
    { title: 'Open PR', detail: 'build role opens the PR/MR right AFTER build, BEFORE review, via scripts/vcs/open-pr.sh, so every reviewer comments on the open PR/MR. Open only, never merge.', model: 'sonnet' },
    { title: 'Review', detail: 'on the OPEN PR/MR: code-reviewer (standards+spec) + guardian (quality gate) + performance ALL review, commenting via scripts/vcs/pr-comment.sh, FREEZE-once-passed; dev fixes the combined batch. First review is one COMPLETE pass per reviewer; every later round RE-VISITS only that reviewer\'s own findings (raise nothing new) — except a fix-CAUSED regression, which HALTS the repo loudly for human action; round cap. SKIPPED for the test-suite repo (no reviewers). When all repos pass, the WORKFLOW moves the ticket to ready_to_merge (or ready_to_test).', model: 'sonnet' },
    { title: 'Test suite', detail: 'qa-runner: build the CANDIDATE (the ticket\'s work branches, PRE-merge) and run THIS ticket\'s scope — its spec(s) + regression scope (the dev\'s "⚠️ Regression request" recap), SCOPED via `npm test -- <specs>`, NOT the full suite. The cross-repo QA gate (E2E / API / load) that must pass BEFORE the merge. The WORKFLOW moves the ticket to testing. Skipped when no test-suite gate applies.', model: 'sonnet' },
    { title: 'Merge', detail: 'the commit gate (after review + the test-suite gate validate the candidate). If vcs.auto_merge is on: each repo squash-merged UPSTREAM→DOWNSTREAM via scripts/vcs/merge-pr.sh so the web PR/MR is marked Merged, not Closed; each SHA recorded — by the code-reviewer (code repos) or the qa-runner (test-suite repo). If auto-merge is off (global or per-repo) the validated, reviewed PR/MR is left OPEN for a human and the run stops here (nothing merged or distributed).', model: 'sonnet' },
    { title: 'Distribute', detail: 'per-repo: build a release artifact from the MERGED base and ship it to the repo\'s distribution target (e.g. Firebase App Distribution); then the WORKFLOW moves the ticket to done.', model: 'sonnet' },
    { title: 'Summary', detail: 'documentor writes the run-summary + per-repo/role token table (summarize-workflow-performance)', model: 'haiku' },
    { title: 'Notify', detail: 'OPTIONAL — only when notify.enabled AND auto-merge is off: post a "please review" digest of the open PR/MR per repo to the configured chat channel via the /notify skill (scripts/notify/). With auto-merge on, the run merges + distributes itself, so nothing is left to review and this phase is skipped.', model: 'haiku' },
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
// AUTO_MERGE — vcs.auto_merge. true ⇒ the Merge phase squash-merges automatically (after review +
//   the test-suite gate validate the candidate), then the merged build is distributed. false ⇒ the
//   run reviews + runs the test-suite gate then STOPS, leaving the PR/MR OPEN for a human (nothing
//   merged or distributed).
// AUTO_APPROVE_PLAN — planning.auto_approve. false ⇒ after Kickoff the run STOPS for human plan
//   approval before build; re-run with --approve-plan to proceed.
// PLAN_TO_HTML — planning.to_html. true ⇒ planners ALSO render each plan to interactive HTML.
// NOTIFY / NOTIFY_PROVIDER / NOTIFY_CHANNEL — notify.{enabled,provider,channel}. When NOTIFY is
//   true AND AUTO_MERGE is false, the final Notify phase posts a "please review" digest (the open
//   PR/MR per repo) to NOTIFY_CHANNEL via the scripts/notify/ adapter. With auto-merge ON the run
//   merges + distributes itself, so there is nothing to review and the phase is skipped.
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
// >>> AIWORKS:CONFIG START — generated from workspace.config.yaml; do not edit by hand <<<
const TICKET_PREFIX = 'FM'
const AUTO_MERGE = false        // from workspace.config.yaml vcs.auto_merge; per-repo override via REPOS[id].autoMerge
const AUTO_APPROVE_PLAN = false // from workspace.config.yaml planning.auto_approve; false ⇒ halt after Kickoff (re-run with --approve-plan)
const PLAN_TO_HTML = false     // from workspace.config.yaml planning.to_html; true ⇒ planners also render the plan to interactive HTML
const NOTIFY = true        // from workspace.config.yaml notify.enabled; true + AUTO_MERGE false ⇒ Notify phase posts a review-request
const NOTIFY_PROVIDER = 'slack' // from workspace.config.yaml notify.provider (scripts/notify/ adapter)
const NOTIFY_CHANNEL = '#code-reviews'  // from workspace.config.yaml notify.channel; the chat channel the digest goes to
const DESIGN_ENABLED = false     // from workspace.config.yaml design.enabled; false ⇒ Figma OFF workspace-wide (dev/QA build from spec, not a Figma screenshot)
const QUALITY_GATE = 'none'     // from workspace.config.yaml quality_gate.provider; 'none' ⇒ guardian gate skips+passes (no SonarQube attempt)
const REVIEW_LEVEL = 'strict'     // from workspace.config.yaml review.level; 'strict' ⇒ Review gates report must-fixes ONLY (no fold-ins/Improvement tickets); 'thorough' ⇒ + nice-to-have
const LANGUAGE = 'en'     // from workspace.config.yaml language; 'th' ⇒ English spine, Thai prose (docs/agents/language.md; see LANGUAGE_DIRECTIVE below); 'en' ⇒ unchanged
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
    base: { feature: 'main', fix: 'main' },
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
  ? ' LANGUAGE_DIRECTIVE — OUTPUT LANGUAGE = th, already resolved for this run (docs/agents/language.md). This is AUTHORITATIVE: do NOT re-check any config file or override it with your own resolution — obey it verbatim. Write ALL prose — chat, ticket description & comments, PR/MR description & review discussion, and the .html render of a plan — in THAI, but keep the English SPINE English: titles + every section heading + labels/enum values, ALL code + code comments + git commit messages + branch names, and technical/transliterated/domain terms + proper nouns (Arabic numerals always). Code, checked-in repo docs (docs/, README, ADRs, committed PRD/BRD files), AND ANY file you author with a .md extension (plans, testcases, PRD/summary Markdown in agent_logs/) are NEVER Thai — the th prose rule applies to chat, tickets, PR/MR discussion, Slack, and .html docs only.'
  : ''

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
const MAX_GATE_ROUNDS = opt.maxGateRounds || 3     // build↔gates loops, per repo
const MAX_REVIEW_ROUNDS = opt.maxReviewRounds || 3 // review↔fix loops, per repo
const MAX_BUILD_TRIAGE = opt.maxBuildTriage || 3   // fix attempts per failing test before a build agent must hand off
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

// Shared BUILD-AGENT DISCIPLINE — appended to EVERY build prompt (code + test-suite)
// and the convergence retry. Three hard rules that stop an open-ended build loop from running
// away (a build aborted 3× without ever handing off): always hand off, never
// a repo-wide formatter, and a bounded red-test triage that tells a flaky harness from a real bug.
const BUILD_DISCIPLINE = ` BUILD DISCIPLINE (mandatory):
• ALWAYS HAND OFF. Ending WITHOUT calling StructuredOutput is a FAILURE. Even if the work is incomplete or the suite is red, you MUST end by returning the DEV_SCHEMA result with "status" set: "complete" (Definition of Done met — for the test-suite repo a red caused only by reported app bugs / expected pre-merge reds still counts as complete), "partial" (some slices landed, work remains), or "blocked" (cannot proceed). For "partial"/"blocked" put exactly WHAT REMAINS and WHY in "remaining". Never withhold the handoff to keep investigating.
• NEVER run a repo-wide formatter or autofix — no \`cargo fmt\`/\`clippy --fix\`, \`eslint .\`/\`prettier --write .\`, \`dart format .\`, \`gofmt -w .\`, or any whole-repo reformat. Format/lint ONLY the files you actually touched for this ticket; leave pre-existing drift in untouched files ALONE. A 50-file reformat diff that drowns the ticket change is itself a failure.
• BOUND RED-TEST TRIAGE. Cap fixes at ${MAX_BUILD_TRIAGE} attempts per failing test. Before chasing a red, decide whether it is a FLAKY HARNESS rather than a real code failure — symptoms: passes/fails non-deterministically on re-run, shared or dirty fixtures, a query like fetch_optional resolving against MORE than one matching row, missing FK/seed data, leaked testcontainer state between tests. If it is the harness: fix FIXTURE ISOLATION / seeding (make the query deterministic) — do NOT loop trying to green a non-deterministic suite. If you cannot isolate it within the cap, FLAG it (status:"partial"/"blocked", name the flaky suite + cause in "remaining") and hand off; do not thrash.`

// ──────────────────────────────────────────────────────────────────────────
// Schemas
// ──────────────────────────────────────────────────────────────────────────
const SCOPE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ticket', 'type', 'repos'],
  properties: {
    ticket: { type: 'string' }, title: { type: 'string' },
    type: { type: 'string', enum: ['feature', 'bug', 'polish'] },
    tracker_reachable: { type: 'boolean' }, // false → scope could NOT read the live ticket via the adapter (writes won't persist this run)
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
const REPO_PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repo', 'base_branch', 'work_branch', 'plan_path', 'summary'],
  properties: {
    repo: { type: 'string' }, title: { type: 'string' },
    type: { type: 'string', enum: ['feature', 'bug', 'polish'] },
    base_branch: { type: 'string' }, work_branch: { type: 'string' },
    figma_url: { type: ['string', 'null'] }, plan_path: { type: 'string' },
    plan_html: { type: ['string', 'null'] }, // set when PLAN_TO_HTML rendered the plan to interactive HTML
    summary: { type: 'string' }, acceptance: { type: 'array', items: { type: 'string' } },
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
    // partial = some slices landed, work remains; blocked = cannot proceed (flaky harness, missing
    // fixture/seed, env). For partial|blocked, `remaining` MUST say what is left and why.
    status: { type: 'string', enum: ['complete', 'partial', 'blocked'] },
    remaining: { type: 'string' }, // what remains / why — required reading when status != complete
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
const MERGE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['merged'],
  properties: {
    merged: { type: 'boolean' }, base: { type: 'string' },
    sha: { type: 'string' }, note: { type: 'string' },
  },
}
const TEST_SUITE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['passed'],
  properties: {
    passed: { type: 'boolean' }, conclusion: { type: 'string' },
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
const DIST_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['distributed'],
  properties: {
    distributed: { type: 'boolean' }, release_link: { type: ['string', 'null'] },
    build: { type: 'string' }, note: { type: 'string' },
  },
}
const CLOSE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['closed'],
  properties: {
    closed: { type: 'boolean' }, // true ONLY after Status → Done actually persisted
    note: { type: 'string' },
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
async function moveTicket(keys, why, phaseName) {
  if (!trackerReachable) { log(`[status] tracker unreachable — ${ticket} NOT moved (${keys.join('/')}); best-effort only.`); return false }
  const cand = keys.find((k) => STATUS[k] && rankOf(k) > statusRank)
  if (!cand) { log(`[status] no forward move for [${keys.join('/')}] (rank ${statusRank}) — skipped (none declared/forward).`); return false }
  const real = STATUS[cand]
  const r = await safeAgent(
    `${tag('all', 'tracker', 'status')} Move ticket ${ticket} Status → "${real}" (canonical "${cand}"; ${why}). Run /update-ticket ${ticket} --status "${real}" through the tracker adapter (scripts/tracker/upsert-ticket-details.sh). Return moved:true ONLY after the write actually persisted (re-read with get-ticket-details.sh to confirm); on a rejected status return moved:false with the adapter's available targets in note. Do NOT do anything else — no branching, no code, no comments.`,
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

// Required closing step — runs the per-repo/role usage parser over the run's
// transcripts and writes the run-summary file. This agent's prompt intentionally
// OMITS the [dev-cycle …] marker so the parser does NOT count the recorder itself.
async function writeSummary(runStatus, runResult) {
  phase('Summary')
  const s = await safeAgent(
    `Run-recorder for the development-cycle workflow on ${ticket} (final status: ${runStatus}). You HAVE the Write tool + a narrow Bash perm for the usage parser — actually PRODUCE the file, do not just describe it.
1. Compose a short narrative: repos touched, per-repo gate/review rounds, the cross-repo test-suite gate result, distribution links, then merge order + SHAs (merge is the FINAL step) — from this run result: ${JSON.stringify(runResult).slice(0, 3000)}.
${trackerReachable ? '' : '2. ⚠️ The tracker was UNREACHABLE this run — put a prominent note at the TOP that ticket Status moves, comments, and /clarifying-ticket improvement tickets did NOT persist (best-effort only).\n'}${testSuiteGateUnavailable ? `2b. ⚠️ The cross-repo test-suite (QA) gate was REQUESTED for this ticket but did NOT run — put a prominent banner at the TOP (same treatment as the tracker-unreachable note): "${testSuiteGateUnavailable}" The ticket shipped WITHOUT its end-to-end validation, so do NOT describe this run as test-suite-validated.\n` : ''}${qualityGateUnavailable ? `2c. ⚠️ The configured quality/performance gate did NOT run this run — put a prominent banner at the TOP (same treatment as the tracker/test-suite notes): "${qualityGateUnavailable}" Do NOT describe this run as quality-gate-validated.\n` : ''}3. WRITE that narrative with the Write tool to agent_logs/${ticket}-DEV-CYCLE-SUMMARY.md at the WORKSPACE (org) ROOT — the workflow's launch directory, the dir that holds .claude/ — NEVER inside a product repo's agent_logs/. Do NOT cd into any repo first; if your cwd is not the workspace root, return there before writing (the root agent_logs dir already exists).
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
// auto-merge ON the run merges + distributes itself (nothing to review), so this is never
// reached. Best-effort: a send failure NEVER changes the run's outcome — the PRs are already
// open + validated. The /notify skill owns the digest: `scripts/notify/send.sh --review <KEY>`
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

scripts/notify/send.sh --review ${ticket}${titleArg}${channelArg}

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
// Returns { repo, status:'ready'|'build-unresolved'|'pr-unresolved'|'review-unresolved', ... }.
// NOTE: never calls phase() — multiple of these run in parallel within a wave, so
// every agent() sets opts.phase explicitly to avoid racing the global phase state.
// ──────────────────────────────────────────────────────────────────────────
async function runRepoPipeline(rp, desc) {
  const R = rp.repo
  const inRepo = `Work in the ${R} repo (cwd ${desc.path}/).`

  // BUILD — initial implementation from the plan. Code repos: developer (TDD).
  // The test-suite repo: qa-runner branches, implements POM, iterates SCOPED, then
  // runs the ticket scope (spec(s) + regression specs) before handoff (full-suite run is
  // on-demand, not here) — and never opens/merges the PR here.
  // NOTE: build agents do NOT touch the ticket status — the workflow owns it (moveTicket).
  const buildPrompt = desc.kind === 'test-suite'
    ? `${tag(R, desc.build, 'build', 0)} Build the test-suite automation for ${ticket} in the ${R} repo from the plan at ${rp.plan_path} (behaviour reference: agent_logs/${ticket}-testcases.md). ${inRepo}
1. BRANCH ONLY — /self-control-gitflow start ${ticket} → create ${rp.work_branch} off ${rp.base_branch}. Do NOT finish/merge (the workflow opens + merges the PR later, in order).
2. IMPLEMENT — strictly POM via /coding-automate ${ticket} (Page Objects in pages/, specs in tests/). Commit each slice conventionally (Refs ${ticket}).
3. ITERATE SCOPED, not full — while building/fixing one feature run only its spec(s) on the SAME command: \`npm test -- <spec-token…>\`. Do NOT run the whole suite on every change.
4. BOUNDED TRIAGE on a break — re-run the broken case ONCE (\`PLATFORM=<failing-platform> npm test -- <spec-token>\` + ONE \`npm run why\`), classify it, then ACT and MOVE ON — do not keep digging:
   • automation/selector/flake → fix the spec/Page Object and re-run that one case until green.
   • genuine APP/feature bug → log it to agent_logs/${ticket}-bugs.md and comment it ON THE TICKET (scripts/tracker/add-ticket-comment.sh) with platform + repro, then move on. You are in the ${R} repo ONLY — NEVER read, reason about, or edit the app repo's source; root-causing app behaviour is the developer's job at the test-suite gate, not yours.
   • a brand-new feature spec red only because the app change is not built into this run yet is EXPECTED — note it and move on; it validates at the test-suite gate against the candidate build, not here.
5. SCOPED RUN before handoff — once your automation is correct, run THIS ticket's scope ONCE on iOS AND Android: \`npm test -- <spec-token…>\` covering (a) the ticket's own spec(s) you built + (b) the ticket's regression spec(s) from the "**Regressions**" block at the bottom of agent_logs/${ticket}-testcases.md (the dev's "⚠️ Regression request" — the SOLE source of regression scope; if that block is absent there is NO regression scope, so run just the ticket's spec(s)). Do NOT run the whole suite (\`npm test\` with no args): the full-suite run is ON-DEMAND only (the user triggers a full run separately), not part of this flow. ${desc.green} is the target — but a scoped red caused ONLY by reported app bugs or expected pre-merge reds is a VALID handoff state; record it, do not chase it.
6. RETURN CONTRACT (mandatory) — /handoff, then END by calling StructuredOutput with the DEV_SCHEMA result: work_branch=${rp.work_branch}, a one-line summary of the suite state (green, or red + the bug ids you reported), commit count, status="complete" (a green run, OR a red caused only by reported app bugs / expected pre-merge reds — both are a valid complete handoff for this phase) else "partial"/"blocked" with what's left in "remaining", and in "fixed" the spec/Page Object files you touched. Do NOT move the ticket status — the workflow does that. A red-but-reported suite is SUCCESS for this phase — never withhold the structured result to investigate further, and never exceed the step-4 triage budget.`
    : `${tag(R, desc.build, 'build', 0)} Implement ${ticket} in the ${R} repo on branch ${rp.work_branch} from the plan at ${rp.plan_path}. ${inRepo} Treat this repo's docs/adr/* and CONTEXT.md as AUTHORITATIVE context the plan defers to: read them FIRST, and where the plan text and an ADR disagree, the ADR wins. If ${rp.work_branch} ALREADY exists with prior work (an approved re-run over an existing branch), RECONCILE existing code that contradicts the updated ADRs/plan — reshape it to the canonical schema/shape (e.g. a stale snake_case seed → the canonical kebab/Section schema) rather than only appending new code on top of the old shape. Run /coding-feature (it loads this repo's CLAUDE.md + coding_standards AND the workspace coding-style — storytelling code, NO body comments — "read before your first edit", and its Step 4 drives the build test-first through /tdd's red-green-refactor loop) and /karpathy-guidelines, committing each slice conventionally (Refs ${ticket}), keep ${desc.green}. When the Definition of Done is met, /handoff. Do NOT move the ticket status — the workflow owns it.`
  let dev = await safeAgent(
    buildPrompt + BUILD_DISCIPLINE + FIGMA_DIRECTIVE + LANGUAGE_DIRECTIVE,
    { agentType: desc.build, phase: 'Build', label: `build:${ticket}:${R}`, schema: DEV_SCHEMA },
  )
  // CONVERGENCE RETRY — a null build means the agent never produced a structured
  // handoff (it ran away triaging a red / reformatting instead of returning). Don't abort the
  // wave: retry ONCE with a bounded "stop working, hand off NOW" continuation, bumped to opus +
  // high so the wrap-up is reliable. It must emit DEV_SCHEMA with whatever state it reached
  // (status partial/blocked is fine) — no new work.
  if (!dev) {
    log(`⚠️ [${R}] build returned no structured handoff — retrying once (bounded: emit handoff now, no more work).`)
    dev = await safeAgent(
      `${tag(R, desc.build, 'build', 1)} Your build of ${ticket} in the ${R} repo (branch ${rp.work_branch}, plan ${rp.plan_path}) did NOT return a structured handoff last time — you likely ran away triaging a red or reformatting. STOP doing work now: run NO more tests, fixes, or formatters. In ONE step, summarize the state you have ALREADY reached and END by calling StructuredOutput with the DEV_SCHEMA result — work_branch=${rp.work_branch}, a one-line summary, commit count, the files you touched in "fixed", status="complete" ONLY if the Definition of Done is genuinely met else "partial" (slices landed, work remains) or "blocked" (cannot proceed), and in "remaining" exactly what is left and why (name a flaky/non-deterministic suite or missing fixture/seed if that blocked you). Returning this handoff IS the task — emit it immediately.`,
      { agentType: desc.build, model: 'opus', effort: 'high', phase: 'Build', label: `build-handoff:${ticket}:${R}`, schema: DEV_SCHEMA },
    )
  }
  if (!dev) {
    log(`⚠️ [${R}] build did not converge to a structured handoff even after the bounded retry — left mid-flight; downstream skipped.`)
    return { repo: R, status: 'build-unresolved', plan: rp, handoff: { status: 'blocked', summary: 'build agent never returned a structured handoff (2 attempts)', remaining: 'unknown — agent did not converge; needs human triage' } }
  }
  // A converged-but-not-complete handoff (partial/blocked) is a CLEAN stop for THIS repo: the whole
  // change set must be ready before any merge, so we surface the handoff rather than pretend ready.
  if (dev.status && dev.status !== 'complete') {
    log(`⚠️ [${R}] build handoff status=${dev.status}: ${(dev.remaining || dev.summary || '(no detail)').slice(0, 140)} — repo not build-complete; downstream skipped.`)
    return { repo: R, status: 'build-unresolved', plan: rp, handoff: { status: dev.status, summary: dev.summary, remaining: dev.remaining } }
  }
  log(`[${R}] initial build: ${dev.summary?.slice(0, 70) ?? 'done'}`)
  tick(`${R}:build`)

  // OPEN PR — open the PR/MR right after build so EVERY reviewer comments on the OPEN
  // PR/MR via the VCS adapter. Code repos via /open-pr; the test-suite repo via the adapter
  // directly. Open ONLY — never merge (the final cross-repo Merge phase merges).
  const openPrPrompt = desc.kind === 'test-suite'
    ? `${tag(R, desc.build, 'open-pr')} The ticket scope (spec(s) + regression specs) for ${ticket} is green in ${R}. ${inRepo} Ensure git status is clean, then open the PR/MR with the VCS adapter (it pushes ${rp.work_branch} for you): \`scripts/vcs/open-pr.sh --base ${rp.base_branch} --head ${rp.work_branch} --title "${prTitle(rp)}" --body "<what was automated + the scoped (ticket spec(s) + regression) green evidence>"\`. The title is Conventional Commits (\`<type>(${ticket}): <title>\`) — keep it exactly as given. Do NOT merge it — the workflow squash-merges in dependency order. Return the PR/MR URL (pr_url) + number (the adapter prints \`number=<n>\`).`
    : `${tag(R, desc.build, 'open-pr')} ${ticket} is built in ${R} — open the PR/MR now so the reviewers (code-reviewer + guardian + performance) can review it on the host. ${inRepo} Ensure git status is clean (commit any stray artifact), then run /open-pr ${ticket} to open the PR/MR for ${rp.work_branch} → ${rp.base_branch}, titled per Conventional Commits "${prTitle(rp)}". Do NOT merge it. Return the PR/MR URL + number.`
  const pr = await safeAgent(
    openPrPrompt + LANGUAGE_DIRECTIVE,
    { agentType: desc.build, phase: 'Open PR', label: `open-pr:${ticket}:${R}`, schema: PR_SCHEMA },
  )
  if (!pr) {
    log(`⚠️ [${R}] open-PR did not converge — left for human review.`)
    return { repo: R, status: 'pr-unresolved', plan: rp }
  }
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
  // HONOR THE LIVE PROVIDER: when quality_gate.provider is 'none' the guardian
  // gate is skipped entirely (auto-pass) — it never spins up an agent and so never attempts
  // SonarQube nor risks tripping a usage-policy safeguard.
  if (desc.guard && QUALITY_GATE === 'none') log(`[${R}] quality_gate.provider=none — guardian gate skipped (auto-pass, no SonarQube attempt).`)
  const reviewers = [
    desc.review && { key: 'review', role: desc.review, schema: REVIEW_SCHEMA, passed: (r) => r?.approved === true, open: (r) => r?.comments?.length || 0 },
    desc.guard && QUALITY_GATE !== 'none' && { key: 'guard', role: 'guardian-engineer', schema: GATE_SCHEMA, passed: (r) => r?.passed === true, open: (r) => (r?.blocking?.length || 0) + (STRICT ? 0 : (r?.fold_in?.length || 0)) },
    desc.perf && { key: 'perf', role: 'performance-engineer', schema: GATE_SCHEMA, passed: (r) => r?.passed === true, open: (r) => (r?.blocking?.length || 0) + (STRICT ? 0 : (r?.fold_in?.length || 0)) },
  ].filter(Boolean)
  if (!reviewers.length) {
    log(`[${R}] no reviewers (QA repo) — ready to merge.`)
    return { repo: R, status: 'ready', plan: rp, pr, reviewRound: 0, verdict: {}, build: { summary: dev.summary, fixed: Array.isArray(dev.fixed) ? dev.fixed : [] } }
  }

  const verdict = {}, done = {}, didFirstReview = {}
  // Gates (guard/perf) that reported gate_unavailable — frozen as UNAVAILABLE (not a pass,
  // not a dev-fixable finding). key → reason. Surfaced loudly by the workflow (fail-open).
  const gatesUnavail = {}
  let reviewRound = 0, fixPasses = 0, lastFixed = []
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
    // RE-VISIT — uniform across all three reviewers, with a per-role "what to re-check" line. The
    // first review is the COMPLETE, CLOSED finding set: confirm your OWN prior findings are addressed,
    // add nothing new. The ONE exception is a fix-CAUSED regression → fix_regression + a loud comment;
    // the workflow halts the repo for human action rather than looping the dev.
    const revisitTask = (rv) => {
      const recheck = rv.key === 'review'
        ? `Do NOT run /review again — that re-derives a full review from scratch and surfaces new findings, exactly what re-visit forbids. Instead list the review threads YOU opened (\`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\`) and, for each must-fix you raised in your first review, confirm the developer's fix + reply genuinely resolve it. Return approved:true ONLY when EVERY one of your first-review must-fixes is resolved; else approved:false listing which of YOUR threads remain open.`
        : `Do NOT re-scan or re-profile broadly. Re-check ONLY the blocking + fold_in items YOU raised in your first review (\`scripts/vcs/pr-comments.sh ${pr.pr_number ?? '<number>'}\` / \`pr-threads.sh\`): confirm each is resolved on the PR/MR. Return passed:true ONLY when EVERY one of your first-review items is resolved; else passed:false listing which of YOUR items remain. File NO new Improvement tickets and add NO new blocking/fold_in items.`
      return `RE-VISIT (round ${reviewRound}) of ${prRef}. ${inRepo} Your first review is the COMPLETE, CLOSED finding set — you are ONLY confirming your OWN prior findings are addressed, NOT reviewing afresh. Raise, comment on, or file NOTHING new.${changed} ${recheck}
THE ONE EXCEPTION — a fix-caused regression: if the developer's fix DIRECTLY caused a NEW blocking problem (a regression the fix introduced — NOT a pre-existing issue your first review missed), do NOT fold it into the loop. Post ONE loud PR/MR comment via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "⚠️ REGRESSION: <what the fix broke + evidence it was this fix>"\`, then return ${rv.key === 'review' ? 'approved:false' : 'passed:false'} with fix_regression:true and regression_detail (what broke, file:line, why it is the fix). The workflow then HALTS this repo loudly for human action — it is not yours to fix in-loop.`
    }
    const scopeNote = `First review (round ${reviewRound}): this is your ONE complete pass — review the whole change set and report EVERY must-fix together in a single batch, because later rounds only RE-VISIT these findings and add nothing new.`
    const onPr = `the OPEN PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}; ${rp.work_branch} → ${rp.base_branch}). ${inRepo} ${scopeNote} Post each must-fix as a comment ON THE PR/MR at the specific file:line via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "<comment>"\` — NEVER on the tracker.`
    const firstReviewPrompt = (rv) =>
      rv.key === 'review'
        ? `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} Review ${onPr} Run /review (standards + spec) against the target. Return approved:true ONLY when the diff meets the bar and every ${STRICT ? 'must-fix' : 'must-fix AND nice-to-have'} comment is resolved; otherwise approved:false with the open comments.`
        : rv.key === 'guard'
          ? `${tag(R, rv.role, 'review', reviewRound)} ${levelDirective} Quality-gate (static-analysis) review of ${ticket} in ${R} on ${onPr} The workspace's configured quality-gate provider is quality_gate.provider="${QUALITY_GATE}" (mirrored from workspace.config.yaml — do NOT re-read the file). If it is 'none', skip the scan and pass cleanly. Otherwise (SonarQube) run the gate by whichever channel is LIVE in THIS run-context: FIRST try the SonarQube MCP — if the mcp__sonarqube tools are not already in your toolset, load them with ToolSearch (e.g. \`select:mcp__sonarqube__get_project_quality_gate_status,mcp__sonarqube__search_sonar_issues_in_projects,mcp__sonarqube__search_security_hotspots\`) and read the quality-gate status + issues + security hotspots for the PR SHA; if the MCP is NOT reachable, FALL BACK to the installed \`sonar\` CLI over Bash (\`sonar analyze\` / \`sonar verify --file <changed-file>\`). GATE-UNAVAILABLE: if NEITHER channel can actually run the scan (no MCP AND no working CLI/auth), you MUST NOT pass — set passed:false AND gate_unavailable:true with unavailable_reason naming both channels you tried and why each failed, and post ONE loud PR/MR comment via scripts/vcs/pr-comment.sh that the configured SonarQube gate could NOT run in this run-context; never fabricate a green status. You summarize the scanner's output, not author a security review. For each BLOCKING issue/hotspot post a PR/MR comment (rule + file:line + remediation) and list it under "blocking"; as a light secondary pass sanity-check this repo's sensitive spots against the scanner output: ${desc.guardianFocus}. Triage every NON-blocking finding into ONE of two tiers — do NOT file a ticket for every finding: (a) MINOR fix (small, local, low-risk — a few lines, mechanical, no new design/contract/QA scope) → post a PR/MR comment at file:line prefixed "[minor / fold-in]" with the exact remediation and list it under "fold_in"; the developer applies it in THIS PR, NO ticket. (b) MAJOR, nice-to-have hardening (needs its own design, touches multiple layers, changes a contract/permission model, or carries a documented trade-off — AND is genuinely optional for this ticket, not must-have) → file ONE Improvement ticket YOURSELF by invoking /clarifying-ticket (Mode A — pass the finding + "source ${ticket}"), and put the REAL <KEY> it returns (with the title) into improvements_filed — NEVER a placeholder like "<PREFIX>-pending". /clarifying-ticket DEDUPS against the board first (scripts/tracker/find-tickets.sh): if the finding (same scope + root cause) is already tracked it returns that EXISTING <KEY> — record that one instead and NEVER file a second ticket for it; also don't re-file findings you already filed earlier in this same run, and never file a ticket for a MINOR fold-in. If a "minor" fold-in turns out non-trivial mid-loop, reclassify it as (b) rather than looping on it. Whoever reports the topic owns the ticket; do not defer it to a human. If the tracker is unreachable, note that in the entry instead of a fake number. Filing tickets and posting fold-ins are both non-blocking for the gate — neither holds up the merge, and an empty improvements_filed is the normal, healthy outcome. Return passed:false while ANY blocking OR unresolved fold_in item remains (so the developer folds the minor ones into this PR); passed:true ONLY when you ACTUALLY obtained a green quality-gate result (or the provider is 'none') AND no fold_in item is left unresolved — NEVER passed:true for a scan you could not run (use gate_unavailable for that). Return the structured gate result.`
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
    // gate_unavailable so the run continues (fail-open). The code reviewer has no gate_unavailable
    // concept → stays null (inconclusive, re-run next round).
    const guardBackstop = async (msg) => {
      log(`⚠️  [${R}] guardian subagent could not complete (${msg}) — running checklist inline via neutral agent (backstop).`)
      try {
        const bk = await agent(
          `${tag(R, 'general-purpose', 'guard-backstop', reviewRound)} Static code-quality pass over the diff of ${prRef}. ${inRepo} Read the diff (\`git diff ${rp.base_branch}...${rp.work_branch}\`) and check the CHANGED lines for: ${desc.guardianFocus}. Post each concrete file:line issue via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --path <file> --line <n> --body "<issue + fix>"\` and list under "blocking" (no generic advice). Return passed:true when clean, else passed:false with the blocking list.` + LANGUAGE_DIRECTIVE,
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
        return await agent(promptFor(rv) + LANGUAGE_DIRECTIVE, { agentType: rv.role, phase: 'Review', label: `${rv.key}:${ticket}:${R}#${reviewRound}`, schema: rv.schema })
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
    // A gate that reports gate_unavailable is frozen as UNAVAILABLE — NOT a pass, but it
    // can't be "fixed" by the developer either, so we stop re-running it (fail-open: the
    // repo can still reach 'ready'; the workflow surfaces the unavailability loudly).
    openReviewers.forEach((rv) => {
      const v = verdict[rv.key]
      if (v && v.gate_unavailable === true) { done[rv.key] = 'unavailable'; gatesUnavail[rv.key] = v.unavailable_reason || 'configured gate could not run in this run-context' }
      else if (rv.passed(v)) done[rv.key] = true
    })

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
    // A crashed reviewer with no findings to fix → skip the dev pass, just re-run it next round.
    if (openFindings === 0) {
      log(`[${R}] no findings to fix — re-running inconclusive reviewer(s) next round: ${crashed.join(', ') || 'none'}.`)
      continue
    }

    // Developer fixes the WHOLE combined batch (every open reviewer's PR comments) in ONE pass, pushing to the PR.
    const fix = await safeAgent(
      `${tag(R, desc.build, 'pr-fix', reviewRound)} PR/MR review-fix batch for ${ticket} in ${R} (round ${reviewRound}) on ${rp.work_branch}, PR/MR ${pr.pr_url} (number ${pr.pr_number ?? '?'}). ${inRepo} Read ALL open review comments on the PR/MR (code-reviewer + guardian + performance) via \`scripts/vcs/pr-comments.sh ${pr.pr_number ?? '<number>'}\`. ${STRICT ? 'The batch is must-fixes only (review.level=strict) — there are no "[minor / fold-in]" comments to apply.' : 'The batch includes both must-fixes AND any comment prefixed "[minor / fold-in]" — those are small guardian/perf improvements to apply in THIS PR (no separate ticket); fold them in too.'} Fix the WHOLE batch in this single pass: reproduce with a failing test first where applicable (/tdd) — a mechanical fold-in may not need one — fix to green, commit (fix(…) Refs ${ticket}), and push (git push). Reply on each resolved comment via \`scripts/vcs/pr-comment.sh ${pr.pr_number ?? '<number>'} --body "<reply>"\` so the reviewers can re-check, THEN check its "Resolve thread" box: list the thread ids with \`scripts/vcs/pr-threads.sh ${pr.pr_number ?? '<number>'}\`, match each unresolved thread by its file:line to the comment you fixed, and resolve it via \`scripts/vcs/pr-resolve-thread.sh ${pr.pr_number ?? '<number>'} <thread-id>\` — resolve ONLY threads you actually addressed in this pass (leave anything still open unresolved). Keep ${desc.green}. In the returned "fixed" array, list the files/areas you changed — the reviewers use this to locate your fixes and to judge whether the fix itself introduced any regression. Set status="complete" when you resolved the whole batch, else "partial" (what's still open in "remaining"); never end without the structured handoff.` + LANGUAGE_DIRECTIVE,
      { agentType: desc.build, phase: 'Review', label: `pr-fix:${ticket}:${R}#${reviewRound}`, schema: DEV_SCHEMA },
    )
    if (fix) fixPasses++
    lastFixed = Array.isArray(fix?.fixed) ? fix.fixed : []
    log(`[${R}] review-fix round ${reviewRound}: ${fix?.summary?.slice(0, 60) ?? 'done'}${lastFixed.length ? ` (scope: ${lastFixed.length})` : ''}`)
    tick(`${R}:pr-fix#${reviewRound}`)
  }

  return { repo: R, status: 'ready', plan: rp, pr, reviewRound, verdict, gatesUnavailable: gatesUnavail, build: { summary: dev.summary, fixed: Array.isArray(dev.fixed) ? dev.fixed : [] } }
}

// ──────────────────────────────────────────────────────────────────────────
// DISPATCHER
// ──────────────────────────────────────────────────────────────────────────

// 1. SCOPE — which repos does this ticket touch, and in what dependency order?
phase('Scope')
// The repo(s) that PROVIDE the cross-repo test-suite (QA) gate — injected into the scope
// prompt so the cto knows which repo must be scoped for the gate to run at all.
const testSuiteRepoIds = Object.keys(REPOS).filter((id) => REPOS[id].testSuite)
const scope = await safeAgent(
  `${tag('all', 'cto', 'scope')} You are the scoping stage for ${ticket}. Read the ticket via the tracker adapter (\`scripts/tracker/get-ticket-details.sh ${ticket}\`, + \`get-ticket-comments.sh\`) and decide which of the workspace's repos it requires changes in: ${Object.keys(REPOS).join(', ')} (only these are registered). For each touched repo return { repo, depends_on (other touched repo ids that must be built/merged first — typically a backend → app → test-suite order), summary (what that repo must change) }. The registered cross-repo test-suite (QA) repo(s) are: ${testSuiteRepoIds.length ? testSuiteRepoIds.join(', ') : 'none'}. When this change should be validated end-to-end by the cross-repo test suite (E2E / API / load) against the candidate build, set test_suite.needed:true AND include that test-suite repo in \`repos\`, with depends_on listing the app/service repos it validates (so it builds + merges LAST). The gate CANNOT run unless the test-suite repo is in \`repos\` — needed:true on its own does nothing. If no test-suite repo is registered, leave needed:false. Most tickets touch only the app repo; when they also need end-to-end validation, return the app repo PLUS the test-suite repo. Also set tracker_reachable: true ONLY if the adapter actually returned the live ticket this call — set it false if the tracker was unreachable and you proceeded from inline/contextual info (the run then loudly flags that Status moves, comments, and improvement tickets did NOT persist). Return the structured scope.`,
  { agentType: 'cto', phase: 'Scope', label: `scope:${ticket}`, schema: SCOPE_SCHEMA },
)
if (!scope) throw new Error(`dev-cycle: scope stage did not converge for ${ticket}`)
trackerReachable = scope.tracker_reachable !== false
if (!trackerReachable) log('⚠️ TRACKER UNREACHABLE — ticket Status moves, comments, and /clarifying-ticket improvement tickets will NOT persist this run; all ticket-tracking is best-effort. Flagged in the run result + summary.')
const scoped = (scope.repos || []).filter((r) => REPOS[r.repo])
if (!scoped.length) throw new Error(`Scope returned no known repos for ${ticket} (got: ${JSON.stringify(scope.repos)})`)
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
2. Pre-create the plan-artifact dirs so later writes have a target UNDER each repo (paths are relative to your cwd — do NOT cd): \`mkdir -p ${repoDirs.map((d) => `"${d}/agent_logs" "${d}/agent_logs/development-planner"`).join(' ')}\`.
Return workspace_root = the absolute path from step 1.`,
  { agentType: 'general-purpose', model: 'haiku', phase: 'Kickoff', label: `ws-root:${ticket}`, schema: WS_ROOT_SCHEMA },
)
const WORKSPACE_ROOT = (wsRootRes?.workspace_root || '').trim().replace(/\/+$/, '')
const haveAbs = WORKSPACE_ROOT.startsWith('/')
if (!haveAbs) log(`⚠️ [kickoff] could NOT resolve an absolute workspace root (got ${JSON.stringify(wsRootRes?.workspace_root)}) — planners will anchor by cd-into-repo and the post-plan guard relocates any artifact still misfiled at the root.`)

// Per-repo path bookkeeping (computed in JS, NOT from the agent, so it's consistent for every
// repo). planRel/planHtmlRel are repo-ROOT-relative (the data-plan-md convention + what the
// build/gate phases read from inside the repo); planPath/planHtmlPath are the ABSOLUTE forms we
// hand the planner and record on the plan.
const planMeta = {}
for (const r of scoped) {
  const desc = REPOS[r.repo]
  const repoDir = desc.path.replace(/\/+$/, '')
  const repoRoot = haveAbs ? `${WORKSPACE_ROOT}/${repoDir}` : null
  const planRel = desc.kind === 'test-suite' ? `agent_logs/${ticket}-automation-plan.md` : `agent_logs/development-planner/${ticket}-${r.repo}-plan.md`
  const planHtmlRel = `agent_logs/${ticket}-${r.repo}-plan.html`
  const testcasesRel = `agent_logs/${ticket}-testcases.md`
  planMeta[r.repo] = {
    kind: desc.kind, repoDir, repoRoot, planRel, planHtmlRel, testcasesRel,
    planPath: repoRoot ? `${repoRoot}/${planRel}` : planRel,
    planHtmlPath: repoRoot ? `${repoRoot}/${planHtmlRel}` : planHtmlRel,
  }
}

const plans = (await parallel(scoped.map((r) => () => {
  const desc = REPOS[r.repo]
  const planner = desc.plan
  const baseBranch = desc.base[branchKind]
  const workBranch = `${branchKind}/${ticket}`
  const slice = r.summary || 'see ticket'
  const m = planMeta[r.repo]
  const { repoDir, repoRoot, planRel, planPath, planHtmlPath, testcasesRel } = m
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
  // PLAN_TO_HTML: after the plan markdown exists, render it to a shareable interactive HTML.
  // The markdown at planPath stays the SOURCE OF TRUTH this workflow reads at build — the HTML
  // is human-only. data-plan-md stays REPO-ROOT-RELATIVE (planRel) per the in-HTML convention;
  // the on-disk file is the absolute planPath. When auto_approve is OFF, turn on plan-approval mode.
  const approvalClause = !AUTO_APPROVE_PLAN
    ? ` Since planning.auto_approve is OFF, turn ON plan-approval mode in that HTML: set data-plan-approval="pending", data-plan-md="${planRel}" (the repo-root-relative path to the authoritative markdown this workflow reads at build — never replace it with the HTML), data-plan-cmd="/dev-cycle ${ticket} --approve-plan", and inline plan-approval.js. The human approves in the page; approving downloads the markdown to drop over the on-disk plan at ${planPath} before the re-run.`
    : ''
  const htmlClause = PLAN_TO_HTML
    ? (approvePlan
        ? ` PLAN-TO-HTML is ON but this is an APPROVED RE-RUN: the interactive HTML at ${planHtmlPath} was already rendered on the first run — do NOT re-render it (wasted cost). Run /write-interactive-docs to create it ONLY if ${planHtmlPath} is MISSING. Set plan_html=${planHtmlPath}.`
        : ` PLAN-TO-HTML is ON: before returning, ALSO run /write-interactive-docs to render the plan at ${planPath} into a self-contained interactive HTML at ${planHtmlPath} (write it to that ${repoRoot ? 'ABSOLUTE ' : ''}path UNDER the repo, NEVER the workspace root; it must read as a human-facing plan write-up; the markdown at ${planPath} stays the source of truth a later phase executes), and set plan_html to that path in your structured result.${approvalClause}`)
    : ''
  const prompt = desc.kind === 'test-suite'
    ? `${tag(r.repo, planner, 'kickoff')} Kickoff ${ticket} for the ${r.repo} repo (cwd ${desc.path}/) — the test-suite (QA) repo.${anchor}${preserveTest} Run your planning chain: /plan-testcases ${ticket} (user-voice BDD Given/When/Then for this ticket), /update-ticket (publish the plan ONLY — do NOT move the ticket status; the workflow owns it), then /plan-automate ${ticket} (map it to this repo's Page Object Model — Page Objects/specs to add or reuse, selectors, automatable vs manual). Do NOT create a git branch — the qa-runner branches at build time. Return the structured repo plan with repo=${r.repo}, type=${scope.type}, base_branch=${baseBranch}, work_branch=${workBranch} (the branch the runner will create), plan_path=${planPath}, and the acceptance/summary for this slice (${slice}).${htmlClause}`
    : `${tag(r.repo, planner, 'kickoff')} Kickoff ${ticket} for the ${r.repo} repo (cwd ${desc.path}/).${anchor}${preserveCode} Run /ticket-kickoff ${ticket} to fetch + classify the ticket and create the work branch IN THIS REPO (base: ${desc.base.feature} for features, ${desc.base.fix} for fixes) — the workflow has already moved the ticket to in_progress, so you don't need to. Comprehend the ticket for this repo's slice (${slice}), verify the design screen if any, and write the implementation plan to ${planPath} (git-ignored). Return the structured repo plan with plan_path=${planPath}.${htmlClause}`
  return agent(prompt + FIGMA_DIRECTIVE + LANGUAGE_DIRECTIVE, { agentType: planner, phase: 'Kickoff', label: `kickoff:${ticket}:${r.repo}`, schema: REPO_PLAN_SCHEMA })
}))).filter(Boolean)
// Normalize the recorded paths to the ABSOLUTE, repo-anchored forms — consistently for every
// repo, regardless of what the planner echoed back (a planner that returned a bare-relative or
// workspace-rooted path is overwritten with the canonical one) — and carry the dependency edges.
plans.forEach((p) => {
  const m = planMeta[p.repo]
  if (m) { p.plan_path = m.planPath; if (PLAN_TO_HTML) p.plan_html = m.planHtmlPath }
  p.depends_on = (scoped.find((s) => s.repo === p.repo)?.depends_on) || []
})

// (3) POST-PLAN GUARD — anchoring is the first line of defense; this is the guarantee. One agent
// asserts each expected artifact sits under its repo clone, relocates any a planner still misfiled
// at the workspace root, and reports anything missing. It never touches the workspace-level run
// summaries. A source-of-truth plan markdown that is missing everywhere is fatal (build can't run).
const guardRepos = plans.map((p) => {
  const m = planMeta[p.repo]
  const files = [m.planRel]
  if (PLAN_TO_HTML) files.push(m.planHtmlRel)
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
Use plain shell only (test -f, mkdir -p, mv). Touch NO git, NO tracker, and NO file other than the relocations above. Do NOT move or alter the workspace-root run summaries (e.g. ${ticket}-DEV-CYCLE-SUMMARY.md) or anything not listed. Return the per-repo { repo, ok, relocated, missing } report.`,
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

const waveList = toWaves(plans)
log(`Plan ${ticket}: ${plans.map((p) => `${p.repo}@${p.work_branch}→${p.base_branch}`).join(', ')}`)
log(`Plan artifacts: ${plans.map((p) => `${p.repo}=${p.plan_path}`).join(', ')}`)
if (PLAN_TO_HTML) log(`Plan HTML: ${plans.map((p) => `${p.repo}=${p.plan_html ?? '(not rendered)'}`).join(', ')}`)
log(`Build: all ${plans.length} repo(s) in parallel · merge order: ${waveList.map((w) => `[${w.join(', ')}]`).join(' → ')}`)
tick('kickoff')

// PLAN-APPROVAL GATE — when planning.auto_approve is off, STOP here with the plan(s) ready
// for a human to review/approve; the run does NOT proceed to build. Re-run with --approve-plan.
if (!AUTO_APPROVE_PLAN && !approvePlan) {
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
const buildRes = await parallel(buildIds.map((id) => () => runRepoPipeline(plans.find((p) => p.repo === id), REPOS[id])))
buildRes.forEach((r, i) => { if (r) repoResults[buildIds[i]] = r })
const aborted = buildIds.filter((id) => !repoResults[id] || repoResults[id].status !== 'ready')
if (aborted.length) {
  // Surface each unresolved repo's partial/blocked HANDOFF (status + what remains) instead of a
  // bare "aborted" — the run stops at the merge gate (the whole change set must be ready before any
  // merge), but the human/summary sees what landed and what's missing per repo.
  const handoffs = aborted.map((id) => {
    const r = repoResults[id]
    const h = r?.handoff
    log(`⚠️ [${id}] unresolved (${r?.status ?? 'no-result'})${h ? ` — handoff:${h.status}: ${h.remaining ?? h.summary ?? '(no detail)'}` : ''}`)
    return `${id}: ${r?.status ?? 'no-result'}${h ? ` — handoff:${h.status}${h.remaining ? ` — remaining: ${h.remaining}` : ''}` : ''}`
  })
  log(`⚠️ ${aborted.join(', ')} did not reach 'ready' — the whole change set must be ready before any merge; stopping. Handoffs: ${handoffs.join(' | ')}`)
  // A fix-caused regression flagged on re-visit is a LOUDER, distinct halt (human-action-required):
  // banner it and give the run a distinct status so the summary/caller treat it as a pause, not a
  // routine unresolved build. The PR is left OPEN — a human addresses it, then re-runs to resume.
  const regressionHalts = aborted.filter((id) => repoResults[id]?.status === 'review-regression-halt')
  if (regressionHalts.length) {
    log(`⛔⛔ FIX-CAUSED REGRESSION HALT — human action required before this run can finish: ${regressionHalts.map((id) => `${id} (${repoResults[id]?.handoff?.remaining ?? 'see PR'})`).join(' | ')}. Nothing merged or distributed; the PR(s) are left OPEN. Fix the regression, then re-run \`/dev-cycle ${ticket}\` to resume.`)
  }
  const runStatus = regressionHalts.length ? 'review-regression-halt' : 'repo-unresolved'
  const summary = await writeSummary(runStatus, { ticket, aborted, handoffs, regressionHalts, repoResults, testSuiteRequested, testSuiteGateUnavailable })
  return { ticket, status: runStatus, aborted, handoffs, regressionHalts, repoResults, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
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
// The workflow advances the ticket ONCE here (decoupled from the per-repo agents): a rich
// board lands on ready_to_merge; the minimal board on ready_to_test.
await moveTicket(['ready_to_merge', 'ready_to_test'], 'all repos built, reviewed & approved', 'Review')

// 4. TEST-SUITE GATE — the cross-repo QA suite (E2E / API / load) against the CANDIDATE
// (the ticket's work branches, PRE-merge): the join check that the repos work together,
// run BEFORE the final merge so we validate the candidate, not after committing it. Runs
// when a test-suite gate is needed, a test-suite repo is in scope, and at least one
// non-test-suite (app/service) repo is present for the suite to run against.
let testSuite = null
const testSuiteRepo = mergeOrder.find((id) => REPOS[id].testSuite)
if (scope.test_suite?.needed && testSuiteRepo && mergeOrder.some((id) => !REPOS[id].testSuite)) {
  phase('Test suite')
  await moveTicket(['testing'], 'cross-repo test-suite gate running', 'Test suite')
  const candidates = mergeOrder.filter((id) => !REPOS[id].testSuite).map((id) => `${id}@${repoResults[id].plan.work_branch}`)
  const testSuiteFixed = repoResults[testSuiteRepo]?.build?.fixed || []
  const specHint = testSuiteFixed.length
    ? ` The ${testSuiteRepo} build for this ticket touched these spec/Page-Object files — use them to pin the ticket's own spec scope: ${testSuiteFixed.join(', ')}.`
    : ''
  testSuite = await safeAgent(
    `${tag(testSuiteRepo, 'qa-runner', 'test-suite')} CROSS-REPO TEST-SUITE gate for ${ticket} — SCOPED to THIS ticket, NOT the full suite. Validate the CANDIDATE (the ticket's work branches, NOT yet merged): build the app/service repo(s) from their ticket work branch(es) — ${candidates.join(', ')} (checkout that branch in each repo before building). Work in the ${testSuiteRepo} repo (cwd ${REPOS[testSuiteRepo].path}/, already on its work branch ${repoResults[testSuiteRepo].plan.work_branch}). Then run ONLY this ticket's scope:
1. SCOPE = (a) the ticket's own spec(s) automated for ${ticket} + (b) the ticket's regression spec(s). Derive (a) from the spec map in agent_logs/${ticket}-automation-plan.md${specHint} Derive (b) from the "**Regressions**" block at the bottom of agent_logs/${ticket}-testcases.md (the dev's "⚠️ Regression request" recap — the SOLE source of regression scope; if that block is absent there is NO regression scope, so run just the ticket's spec(s)).
2. RUN SCOPED — \`npm test -- <spec-token…>\` covering exactly the ticket + regression spec(s) on each platform the suite targets. Do NOT run \`npm test\` with no args: the FULL-suite run is ON-DEMAND (the user triggers it separately) and is NOT part of this gate.
On a red: SINGLE-CASE triage — re-run just the broken case to rule out flake: \`PLATFORM=<failing-platform> npm test -- <spec-token>\` (+ \`npm run why\`). If it reproduces as a genuine APP/feature bug, report it as-is — comment a reproducible report ON THE TICKET (scripts/tracker/add-ticket-comment.sh) with platform + evidence, list it in failures, and fail the gate (you do NOT fix app code here — only re-run to triage).
Return passed:true only if the scoped run (ticket + regression spec(s)) is green; otherwise passed:false with the failures.`,
    { agentType: 'qa-runner', phase: 'Test suite', label: `test-suite:${ticket}`, schema: TEST_SUITE_SCHEMA },
  )
  log(`Test-suite gate (scoped: ticket + regression): ${testSuite?.passed ? 'PASS' : `${testSuite?.failures?.length ?? '?'} failure(s)`}`)
  tick('test-suite')
  if (!testSuite?.passed) {
    log('⚠️ Test-suite gate failed — stopping before Distribute + Merge. The candidate does not pass; NOTHING merged; left for human review.')
    const summary = await writeSummary('test-suite-failed', { ticket, mergeOrder, repoResults, testSuite, testSuiteRequested })
    return { ticket, status: 'test-suite-failed', mergeOrder, repoResults, testSuite, testSuiteRequested, summary, spend }
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
  const summary = await writeSummary('dry-run', { ticket, repos: mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable })
  return { ticket, status: 'dry-run', dryRun: true, repoResults, testSuite, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
}

// 5. MERGE — the commit gate. After review + the test-suite gate have validated the candidate
// (PRE-merge), squash-merge UPSTREAM → DOWNSTREAM (sequential), record each SHA. Gated by
// auto-merge (workspace.config.yaml vcs.auto_merge, per-repo override via REPOS[id].autoMerge):
// when a repo opts OUT, its reviewed + validated PR/MR is left OPEN for a human and the run stops
// here — NOTHING is merged or distributed (review + the test-suite gate still ran, so the human
// merges a fully-validated candidate). Exactly like a dry-run, but with real, reviewed PRs.
phase('Merge')
const merges = {}
for (const id of mergeOrder) {
  const rr = repoResults[id], desc = REPOS[id], rp = rr.plan
  if ((desc.autoMerge ?? AUTO_MERGE) === false) {
    merges[id] = { merged: false, base: rp.base_branch, note: 'auto-merge disabled — PR/MR left open for a human', pr: rr.pr?.pr_url }
    log(`⏸️ [${id}] auto-merge disabled — reviewed + validated PR/MR left OPEN for human merge: ${rr.pr?.pr_url ?? '(see run)'}. Nothing merged or distributed this run.`)
    const summary = await writeSummary('merge-skipped', { ticket, mergeOrder, repoResults, testSuite: testSuite ? { passed: testSuite.passed } : null, testSuiteRequested, testSuiteGateUnavailable, merges })
    // NOTIFY (final phase) — auto-merge is off, so the validated PR/MR are awaiting a human:
    // ping the configured chat channel to review them. No-op unless notify.enabled.
    const notify = await notifyReview(mergeOrder)
    return { ticket, status: 'merge-skipped', haltedAt: id, repoResults, merges, testSuite, testSuiteRequested, testSuiteGateUnavailable, qualityGateUnavailable, summary, notify, spend }
  }
  const merger = desc.review || desc.build // test-suite repo (no reviewer): the qa-runner merges its own PR
  const mergePreamble = desc.review
    ? `You approved the PR/MR for ${ticket} in ${id} (${rr.pr.pr_url}). The squash-merge is YOUR exclusive gate.`
    : `The ticket scope (spec(s) + regression specs) for ${ticket} is green and its PR/MR is open in ${id} (${rr.pr.pr_url}). It is now your turn in the dependency order to squash-merge it.`
  const m = await safeAgent(
    `${tag(id, merger, 'merge')} ${mergePreamble} Work in the ${id} repo (cwd ${desc.path}/). Squash-merge PR/MR number ${rr.pr?.pr_number ?? '(see ' + rr.pr?.pr_url + ')'} into ${rp.base_branch} THROUGH THE HOST (via the VCS adapter) so the web PR/MR is marked **Merged** — do NOT run a local "git merge --squash" + push: that advances the base but leaves the PR/MR showing **Closed**, the exact bug we avoid. Run:
\`scripts/vcs/merge-pr.sh ${rr.pr?.pr_number ?? '<number>'} --subject "${prTitle(rp)}"\` (the same Conventional Commits subject as the PR/MR title) — this squash-merges server-side, advances ${rp.base_branch}, marks the PR/MR Merged, and prints \`state=\` + \`merge_sha=\`.
VERIFY the printed \`state=MERGED\` before reporting (re-check with \`scripts/vcs/pr-view.sh ${rr.pr?.pr_number ?? '<number>'}\` if unsure). Return merged:true ONLY when state is MERGED (not Closed), base=${rp.base_branch}, and sha = the printed merge_sha on ${rp.base_branch}.`,
    { agentType: merger, phase: 'Merge', label: `merge:${ticket}:${id}`, schema: MERGE_SCHEMA },
  )
  merges[id] = m
  log(`[${id}] merged → ${rp.base_branch}${m?.sha ? ` (${m.sha.slice(0, 8)})` : ''}`)
  tick(`${id}:merge`)
  if (!m?.merged) {
    log(`⚠️ [${id}] merge did not complete — stopping before distribution; left for human review (review + test-suite already passed).`)
    const summary = await writeSummary('merge-failed', { ticket, mergeOrder, repoResults, merges, testSuiteRequested, testSuiteGateUnavailable })
    return { ticket, status: 'merge-failed', failedAt: id, repoResults, merges, testSuite, testSuiteRequested, testSuiteGateUnavailable, summary, spend }
  }
}

// 6. DISTRIBUTE — per-repo: build a release artifact from the MERGED base and ship it to the
// repo's target. distribute: 'firebase' | 'custom' | null/'none'.
phase('Distribute')
const dists = {}
for (const id of mergeOrder) {
  const desc = REPOS[id]
  if (desc.distribute && desc.distribute !== 'none') {
    const how = desc.distribute === 'firebase'
      ? 'distribute it to Firebase App Distribution for the tester group (firebase CLI "firebase appdistribution:distribute …" or the Firebase MCP)'
      : `distribute it via this repo's configured target ("${desc.distribute}" — see the repo's docs/scripts)`
    dists[id] = await safeAgent(
      `${tag(id, desc.build, 'distribute')} ${ticket} is squash-merged into ${repoResults[id].plan.base_branch}${merges[id]?.sha ? ` (${merges[id].sha})` : ''}. Work in the ${id} repo (cwd ${desc.path}/). Build a release artifact from the merged base and ${how}. Return distributed + the release link.`,
      { agentType: desc.build, phase: 'Distribute', label: `distribute:${ticket}:${id}`, schema: DIST_SCHEMA },
    )
    log(`[${id}] distributed: ${dists[id]?.release_link ?? '(see note)'}`)
    tick(`${id}:distribute`)
  }
}

// 6b. CLOSE → done — the WORKFLOW closes the ticket now that the whole change set is
// MERGED (the real ship). Gated on a reachable tracker (else the write won't persist) and
// a successful merge. The build role that shipped the app posts the closing comment.
let close = null
const closeId = mergeOrder.find((id) => merges[id]?.merged && REPOS[id].distribute && REPOS[id].distribute !== 'none')
  || mergeOrder.find((id) => merges[id]?.merged)
if (trackerReachable && closeId) {
  const cdesc = REPOS[closeId]
  const csha = merges[closeId]?.sha
  const clink = dists[closeId]?.release_link
  const cpr = repoResults[closeId].pr?.pr_url
  close = await safeAgent(
    `${tag(closeId, cdesc.build, 'close')} ${ticket} is squash-merged into ${repoResults[closeId].plan.base_branch}${csha ? ` (${csha})` : ''}${clink ? ` and distributed (${clink})` : ''}. You shipped it, so you CLOSE it: invoke /update-ticket ${ticket} to move Status → ${STATUS.done}, then post a one-line closing comment citing PR/MR ${cpr ?? '(see run)'}${csha ? `, merge ${csha}` : ''}${clink ? `, ${clink}` : ''}. Return { closed:true } ONLY after the ${STATUS.done} write actually persisted.`,
    { agentType: cdesc.build, phase: 'Merge', label: `close:${ticket}:${closeId}`, schema: CLOSE_SCHEMA },
  )
  if (close?.closed) statusRank = rankOf('done')
  log(`[${closeId}] ticket → ${STATUS.done}: ${close?.closed ? 'closed' : 'NOT confirmed (left for manual close)'}`)
  tick(`${closeId}:close`)
} else if (!trackerReachable) {
  log('⚠️ Tracker unreachable — ticket NOT moved to Done (write would not persist); left for manual close.')
} else {
  log('No merged repo — ticket Done-transition skipped; left for manual close.')
}

// 7. SUMMARY — required closing step.
const summary = await writeSummary('shipped', {
  ticket, repos: mergeOrder,
  per_repo: mergeOrder.map((id) => ({
    repo: id, base: repoResults[id].plan.base_branch, work: repoResults[id].plan.work_branch,
    reviewRounds: repoResults[id].reviewRound,
    pr: repoResults[id].pr?.pr_url, sha: merges[id]?.sha, distribution: dists[id]?.release_link,
  })),
  testSuite: testSuite ? { passed: testSuite.passed } : null,
  testSuiteRequested, testSuiteGateUnavailable,
})

return {
  ticket, status: 'shipped',
  repos: mergeOrder, repoResults, merges,
  testSuite, testSuiteRequested, testSuiteGateUnavailable, qualityGateUnavailable,
  distribution: dists, closed: close?.closed === true, summary, trackerReachable,
  spend, // per-phase output-token deltas; the per-repo/role table lives in summary.summary_path
}
