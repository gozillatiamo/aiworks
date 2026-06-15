Test results — {{ Ticket Number }} · {{ PASS | FAIL }} · Android {{ ✓ | ✗ }} · iOS {{ ✓ | ✗ }}

{{ One-line verdict: X of Y planned scenarios automated; the result on Android/iOS; bug count if any. }}

## Results

<!-- One row per scenario in agent_logs/<FM>-testcases.md. Keep cells terse:
     ✅ pass · ❌ fail · — not automated. Put the bug ref / one-line reason in Notes. -->

| # | Scenario | Android | iOS | Notes |
|---|---|---|---|---|
| 1 | {{ scenario title from the test plan }} | {{ ✅ | ❌ | — }} | {{ ✅ | ❌ | — }} | {{ short note / bug ref / "manual-only" }} |
| 2 | {{ scenario title }} | {{ ✅ | ❌ | — }} | {{ ✅ | ❌ | — }} | {{ … }} |

Legend: ✅ pass · ❌ fail · — not automated (manual-only / partial)

## Failures

<!-- Keep this section ONLY if a row is ❌. One block per failing scenario; concise, no raw logs. -->

### {{ failing scenario title }} — {{ android | ios | both }}
- **Expected:** {{ the test plan's `Then` }}
- **Actual:** {{ what the app did — from agent_logs/<FM>-bugs.md }}
- **Why:** {{ `npm run why` line — error + file:frame }} (log: logs/test-{{ platform }}.log)

## Coverage

- **Automated:** {{ n }}/{{ total }} planned scenarios.
- **Not automated:** {{ scenario(s) marked Manual-only/Partial in the automation plan + one-line reason, or "none" }}.
- **Regressions:** {{ status of the test plan's regression checks, or "none requested" }}.
