**[test-report · {{ suite repo name, e.g. e2e-suite }}]**

<!-- THE LINE ABOVE IS THE COMMENT'S IDENTITY — do not reword it, do not translate it, do not
     drop the brackets. `upsert-ticket-comment.sh --marker '[test-report · <repo>]'` finds this
     comment by that exact text and rewrites it, which is what stops a re-run from posting a
     second report. It has to be VISIBLE text: an HTML comment does not survive the
     Markdown → tracker → text round trip, so it could never be found again. One such comment
     per suite repo per ticket — four suite repos on a ticket means four comments, each with
     its own repo in the marker. -->

Test results — {{ Ticket Number }} · {{ PASS | FAIL }} · {{ per-tool marks from the harness SUMMARY, e.g. cypress ✓ · newman ✗ }}

`run {{ r<n> }} · {{ UTC timestamp, e.g. 2026-08-20T09:14Z }} · candidate {{ repo@sha, comma-separated for a multi-repo candidate }}`

<!-- THE RUN STAMP, and it is not decoration. dev-cycle proves its test-suite gate actually ran
     by having a second agent find THIS run's result on the ticket; with the report updated in
     place, the stamp is the only thing that distinguishes this run's report from last run's.
     A missing or stale stamp makes the gate read as NOT RUN. -->

{{ One-line verdict: X of Y planned scenarios automated; the outcome; bug count if any. }}

## Results

<!-- One row per TC in agent_logs/<KEY>-testcases.md. Keep cells terse:
     ✅ pass · ❌ fail · — not automated. Evidence = ✅ when a screenshot for this TC was
     attached, — when none was captured. Add one Result column per tool the harness's
     SUMMARY reported; a single-tool run has a single column. -->

| TC | Scenario | {{ Result-column per tool }} | Evidence | Notes |
|---|---|---|---|---|
| TC001 | {{ scenario title from the test plan }} | {{ ✅ \| ❌ \| — }} | {{ ✅ \| — }} | {{ short note / bug ref / "manual-only" }} |
| TC002 | {{ scenario title }} | {{ ✅ \| ❌ \| — }} | {{ ✅ \| — }} | {{ … }} |

Legend: ✅ pass · ❌ fail · — not automated (manual-only / partial)

<!-- Pass screenshots go here, ALL ON ONE LINE, so they render as a thumbnail strip.
     Delete this line if the run captured none. -->
![TC001](attachment:{{ id }}) ![TC002](attachment:{{ id }})

## Failures

<!-- Keep this section ONLY if a row is ❌. One block per failing TC; concise, no raw logs.
     The screenshot goes ALONE on its own line so it renders full-width. -->

### {{ TC00n }} — {{ failing scenario title }}
- **Expected:** {{ the test plan's `Then` }}
- **Actual:** {{ what the app did — from agent_logs/<KEY>-bugs.md }}
- **Why:** {{ the `scripts/dev.sh why test` line — error + frame }} (log: `{{ path }}`)

<!-- Backtick every path and identifier. A bare snake_case path in prose is read as
     Markdown emphasis by some trackers and loses its underscores silently. -->


![{{ TC00n }} failure](attachment:{{ id }})

## Coverage

- **Automated:** {{ n }}/{{ total }} planned scenarios.
- **Not automated:** {{ TC id(s) marked Manual-only/Partial in the automation plan + one-line reason, or "none" }}.
- **Regressions:** {{ status of the test plan's regression checks, or "none requested" }}.
- **Run report:** {{ the rendered report image, or the report path, or "none produced" }}.

![run report](attachment:{{ id }})

## Run history

<!-- One line per EARLIER run of this suite on this ticket, oldest first, carried forward
     verbatim from the comment being replaced — then this run's line appended. This is the
     whole audit trail that survives an in-place update: the body above is only ever the
     latest run. Never rewrite an older line, and never drop one to keep the comment short.
     On the FIRST run this section holds only that run's own line. -->

- `r1` · {{ UTC }} · {{ PASS | FAIL }} {{ n/total }} · candidate {{ repo@sha }}
- `r2` · {{ UTC }} · {{ PASS | FAIL }} {{ n/total }} · candidate {{ repo@sha }}
