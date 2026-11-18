#!/usr/bin/env bash
#
# Dispatcher prompt selftest — stdlib only, no venv, no network.
#
#   scripts/slack-dispatch/selftest.sh
#
# Pins the trusted-preamble block that points a dispatched session at a Night Watch Verdict.
# Exit: 0 = all green, 1 = at least one case regressed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHONPATH="$DIR" python3 - <<'EOF'
import sys
from aiworks_dispatch.correlation import CorrelationContext
from aiworks_dispatch.prompt import build_prompt

passed = failed = 0


def check(label, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"ok   {label}")
    else:
        failed += 1
        print(f"FAIL {label}")


def ctx(agent=""):
    return CorrelationContext(
        correlation_id="req-test", slack_channel="C1", slack_thread_ts="1.1",
        slack_user_id="U1", request_text="why was 10:00 suspicious?",
        created_at="2026-01-01T00:00:00Z", agent_name=agent,
    )


p = build_prompt(ctx(), "/ws", redis_url="redis://x", thread_context="[bot:B @ t] SUSPICIOUS 10:00")
check("D1 block and brief command present", "NIGHT WATCH FOLLOW-UP" in p and "/ws/scripts/night-watch/run.sh brief" in p)
at = p.index("NIGHT WATCH FOLLOW-UP")
check("D2 block sits before the untrusted blocks",
      at < p.index("--- BEGIN USER REQUEST ---") and at < p.index("--- BEGIN THREAD CONTEXT ---"))
check("D3 forbids tick and loop", "Never run `run.sh tick`" in p)
check("D4 follow-up and agent prompts carry it too",
      all("NIGHT WATCH FOLLOW-UP" in build_prompt(c, "/ws", redis_url="redis://x", is_followup=True)
          for c in (ctx(), ctx("oncall"))))
check("D5 resolve command present", "/ws/scripts/night-watch/run.sh resolve" in p)
check("D6 unresolve undo named", "unresolve" in p)
check("D7 unsure means do not resolve", "Do NOT resolve when you are unsure" in p)
check("D8 only resolve/unresolve may write; old read-only wording gone",
      "never hand-edit" in p and "READ-ONLY. Never run" not in p)
check("D9 --alert rule present, before the untrusted blocks",
      "--alert" in p and p.index("--alert") < p.index("--- BEGIN USER REQUEST ---"))

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
EOF
