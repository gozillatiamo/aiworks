Bug log — {{ Ticket Number }} ({{ run date }})

{{ One-line summary: which run surfaced these, and the plan they were tested against (agent_logs/<KEY>-automation-plan.md). }}

<!-- One entry per reproducible APP bug — the automation is correct but the app's observable
     behaviour contradicts the test plan's `Then`. Automation/selector issues are NOT bugs:
     fix those in the Page Object/spec and re-run. Append a new ## Bug N block per finding. -->

## Bug 1 — {{ short descriptive title }}
- **Scenario:** {{ the TC id from agent_logs/<KEY>-testcases.md, and the spec that covers it }}
- **Steps:** {{ user actions / page-object calls in order }}
- **Expected:** {{ what the test plan's `Then` says should happen }}
- **Actual:** {{ what the app actually did }}
- **Evidence:** {{ the `scripts/dev.sh why test` line — error + frame — and the run-log path }}
- **Screenshot:** {{ the fail-screenshot path from `scripts/dev.sh artifacts` for this TC id, or "none captured" }}
