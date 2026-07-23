#!/usr/bin/env bash
# Stop-hook for the Slack dispatcher (scripts/slack-dispatch/). Two jobs when a
# dispatched Claude session ends inside a worktree the dispatcher created:
#
#   1. ALWAYS free the thread — clear its Redis busy flag so the next mention in
#      the thread isn't rejected as "still working" (runs whether or not the agent
#      posted its own summary).
#   2. BACKSTOP the reply — if the agent did NOT post its own summary
#      (.aiworks/slack-posted absent), post the last assistant message to the thread
#      so it's never left silent.
#
# GATED + IDEMPOTENT, so it is inert for every normal session: it does nothing
# unless  .aiworks/slack-context.json  exists in the session cwd (a normal dev
# session has none). Reads the Stop-hook JSON on stdin (cwd, transcript_path).
# Best-effort throughout — any failure exits 0 so the session can end.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

ctx="$cwd/.aiworks/slack-context.json"
posted="$cwd/.aiworks/slack-posted"
[[ -f "$ctx" ]] || exit 0        # not a dispatcher worktree

channel="$(jq -r '.slack_channel // empty' "$ctx" 2>/dev/null || true)"
thread_ts="$(jq -r '.slack_thread_ts // empty' "$ctx" 2>/dev/null || true)"
corr="$(jq -r '.correlation_id // empty' "$ctx" 2>/dev/null || true)"
root="$(jq -r '.workspace_root // empty' "$ctx" 2>/dev/null || true)"
redis_url="$(jq -r '.redis_url // empty' "$ctx" 2>/dev/null || true)"
thread_key="$(jq -r '.thread_key // empty' "$ctx" 2>/dev/null || true)"

# 1) Always free the thread (session has ended), via the service's venv + package.
py="$root/scripts/slack-dispatch/.venv/bin/python"
if [[ -n "$redis_url" && -n "$thread_key" && -x "$py" ]]; then
  ( cd "$root/scripts/slack-dispatch" && "$py" -m aiworks_dispatch.clear_busy --url "$redis_url" --key "$thread_key" ) >/dev/null 2>&1 || true
fi

# 2) Backstop the reply only if the agent didn't already post its own summary.
[[ -f "$posted" ]] && exit 0

send="$root/scripts/notify/send.sh"
[[ -n "$channel" && -n "$thread_ts" && -x "$send" ]] || exit 0

snippet=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
  snippet="$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' "$transcript" 2>/dev/null | head -c 1200 || true)"
fi
[[ -n "$snippet" ]] || snippet="(no final message captured)"

msg=":warning: Session ended (backstop — the agent did not post its own summary). ref: ${corr}

${snippet}"

"$send" --channel "$channel" --thread-ts "$thread_ts" "$msg" >/dev/null 2>&1 || true
touch "$posted" 2>/dev/null || true
exit 0
