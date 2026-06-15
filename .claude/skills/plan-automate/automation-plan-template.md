Automation plan — {{ Ticket Number }}

{{ One-line summary: what this automates, and the test plan it builds on (agent_logs/<FM>-testcases.md) }}

## Page Objects

<!-- Reuse existing pages/*.js where possible; add new ones per screen. Follow the WelcomePage idiom:
     constructor(driver), selector getters returning this.driver.$('~accessibility-id'), isLoaded(),
     intent-named action methods, no assertions. -->

| Screen (as the user sees it) | Page Object | New / Reuse | Elements to expose | Action methods to add |
|---|---|---|---|---|
| {{ screen }} | `pages/{{ Name }}Page.js` | {{ New \| Reuse }} | {{ element(s) }} | {{ method(intent) }} |

## Specs

<!-- Specs hold the flow + assertions only — no raw selectors. -->

| Spec | Covers | Page Objects used |
|---|---|---|
| `tests/{{ name }}.spec.js` | {{ Scenario 1, 2 }} | {{ WelcomePage, … }} |

## Scenario → automation

<!-- One block per BDD scenario in the test plan. -->

### {{ Scenario 1 title }} — {{ Automatable | Partial | Manual-only }}
- **Steps:** {{ page-object calls in order }}
- **Assert:** {{ what the spec verifies }}
- **Notes:** {{ data setup, blockers, why Partial/Manual }}

## Selectors to confirm

<!-- We do not invent locators. List what must be verified against the app. Prefer the cross-platform
     accessibility-id (~); branch android/ios only when the labels actually differ. -->

- {{ element }} — proposed `~{{ accessibility-id }}` {{ / fallback strategy }}

## Project wiring & prerequisites

- **Runner:** {{ e.g. run-tests.js runs only test.js today → add tests/ discovery, or import the new spec }}
- **App under test:** build/install the app's `app_id` from `workspace.config.yaml` (the mobile app repo's `app_id` under `products[].repos[]`); caps already in `config/capabilities.js` (must match it).
- **Test data:** {{ e.g. clean reinstall precondition; any seed/reset needed }}

## Implementation checklist (in order)

1. {{ step }}
2. {{ step }}
3. {{ step }}
