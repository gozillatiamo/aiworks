Test results — {{ Ticket Number }} · {{ PASS | FAIL }} · {{ per-tool marks from the harness SUMMARY, e.g. cypress ✓ · newman ✗ }}

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
