#!/usr/bin/env bash
# Stop-hook BACKSTOP for the Slack dispatcher (scripts/slack-dispatch/).
#
# When a Claude session ends inside a worktree that the dispatcher created, this
# guarantees the Slack thread hears back even if the agent forgot to post or
# crashed. It is GATED and IDEMPOTENT, so it is inert for every normal session:
#
#   • Fires only when  .aiworks/slack-context.json  exists in the session cwd
#     (the dispatcher writes it; a normal dev session has no such file → exit 0).
#   • Skips if  .aiworks/slack-posted  exists (the agent's own post-back, done via
#     the preamble instruction, touches this marker → no double-post).
#
# Reads the Stop-hook JSON on stdin (cwd, transcript_path). Best-effort: any
# failure exits 0 so it never blocks the session from ending.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[[ -n "$cwd" ]] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

ctx="$cwd/.aiworks/slack-context.json"
posted="$cwd/.aiworks/slack-posted"
[[ -f "$ctx" ]] || exit 0        # not a dispatcher worktree
[[ -f "$posted" ]] && exit 0     # the agent already posted its own summary

channel="$(jq -r '.slack_channel // empty' "$ctx" 2>/dev/null || true)"
thread_ts="$(jq -r '.slack_thread_ts // empty' "$ctx" 2>/dev/null || true)"
corr="$(jq -r '.correlation_id // empty' "$ctx" 2>/dev/null || true)"
root="$(jq -r '.workspace_root // empty' "$ctx" 2>/dev/null || true)"
send="$root/scripts/notify/send.sh"

[[ -n "$channel" && -n "$thread_ts" && -x "$send" ]] || exit 0

# Last assistant text from the transcript (JSONL), as the summary snippet.
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
