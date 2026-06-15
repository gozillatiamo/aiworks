Bug log — {{ Ticket Number }} ({{ run date }})

{{ One-line summary: which run surfaced these, and the plan they were tested against (agent_logs/<FM>-automation-plan.md). }}

<!-- One entry per reproducible APP bug — the automation is correct but the app's observable
     behaviour contradicts the test plan's `Then`. Automation/selector issues are NOT bugs:
     fix those in the Page Object/spec and re-run. Append a new ## Bug N block per finding. -->

## Bug 1 — {{ short descriptive title }}
- **Scenario:** {{ which BDD scenario from agent_logs/<FM>-testcases.md / which spec }}
- **Platform:** {{ android | ios | both }}
- **Steps:** {{ user actions / page-object calls in order }}
- **Expected:** {{ what the test plan's `Then` says should happen }}
- **Actual:** {{ what the app actually did }}
- **Evidence:** {{ `npm run why` line — error + file:frame — and logs/test-<platform>.log path }}
