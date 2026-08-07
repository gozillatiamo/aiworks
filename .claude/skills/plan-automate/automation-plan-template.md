Automation plan — {{ Ticket Number }}

{{ One-line summary: what this automates, and the test plan it builds on (agent_logs/<KEY>-testcases.md) }}

**Suite:** {{ the repo's own stack + how it runs, e.g. "Cypress — scripts/dev.sh test" }}

## Page Objects

<!-- Reuse existing Page Objects where possible; add new ones per screen. Copy the idiom
     THIS repo already uses (its directory, base class, selector convention) — read its
     CLAUDE.md / .claude/rules/ rather than assuming one. No assertions in a Page Object. -->

| Screen (as the user sees it) | Page Object | New / Reuse | Elements to expose | Action methods to add |
|---|---|---|---|---|
| {{ screen }} | `{{ repo's page-object path }}` | {{ New \| Reuse }} | {{ element(s) }} | {{ method(intent) }} |

## Specs

<!-- Specs hold the flow + assertions only — no raw selectors. The test title MUST open
     with the plan's TC id: that id is what ends up in every screenshot filename, and it
     is how the results report attaches the right evidence to the right row. -->

| Spec | Test title (opens with the TC id) | Covers | Page Objects used |
|---|---|---|---|
| `{{ repo's spec path }}` | `{{ TC001 - Success : … }}` | {{ TC001, TC002 }} | {{ … }} |

## Scenario → automation

<!-- One block per TC in the test plan. -->

### {{ TC001 }} — {{ Automatable | Partial | Manual-only }}
- **Steps:** {{ page-object calls in order }}
- **Assert:** {{ what the spec verifies }}
- **Evidence:** {{ the capture call that ends the scenario, and where its output lands }}
- **Notes:** {{ data setup, blockers, why Partial/Manual }}

## Selectors to confirm

<!-- We do not invent locators. List what must be verified against the app, in the
     repo's own preferred form (data-cy, accessibility id, role, …). -->

- {{ element }} — proposed `{{ locator }}` {{ / fallback strategy }}

## Project wiring & prerequisites

- **Runner:** {{ how `scripts/dev.sh test` picks the new spec up, or the change needed so it does }}
- **Target:** {{ which environment and how it is selected — local by default; staging only on an explicit QA opt-in }}
- **Evidence:** {{ confirm `scripts/dev.sh artifacts` will list this run's captures }}
- **Test data:** {{ any seed/reset needed, grounded in the real schema }}

## Implementation checklist (in order)

1. {{ step }}
2. {{ step }}
3. {{ step }}
