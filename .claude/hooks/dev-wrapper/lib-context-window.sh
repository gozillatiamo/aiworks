# Sourced by the hooks that read a context window off a transcript. No shebang: a library.
#
# A hook payload names the MAIN session transcript even when a SUBAGENT issued the tool call
# (scripts/hook-signal-probe.sh, measured 2026-08-18); the subagent's own transcript lives
# beside it, keyed by the payload's agent_id:
#
#   <proj>/<sid>.jsonl                                    main session
#   <proj>/<sid>/subagents/agent-<agent_id>.jsonl         Agent-tool child
#   <proj>/<sid>/subagents/workflows/<run>/agent-<id>.jsonl   Workflow-tool child
#
# Measuring the main transcript for a subagent reports the PARENT's window — the wrong agent,
# and usually a smaller number — so a hook that wants "how full am I" must resolve its own file.

# own_transcript <transcript_path> <agent_id> — prints the transcript that belongs to the
# caller, or nothing when a subagent's file cannot be found (never the parent's as a fallback:
# a wrong window is worse than no window).
own_transcript() {
  local tp="$1" aid="$2" base f
  [ -n "$tp" ] || return 0
  if [ -z "$aid" ]; then [ -f "$tp" ] && printf '%s' "$tp"; return 0; fi
  base="${tp%.jsonl}"
  for f in "$base/subagents/agent-$aid.jsonl" "$base"/subagents/workflows/*/"agent-$aid.jsonl"; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  # The file name can carry a label before the id (agent-<label>-<id>.jsonl); newest wins.
  f="$(ls -t "$base"/subagents/agent-*"$aid".jsonl "$base"/subagents/workflows/*/agent-*"$aid".jsonl 2>/dev/null | head -n 1)"
  [ -n "$f" ] && printf '%s' "$f"
  return 0
}

# handoff_key_of <transcript> — the `HANDOFF_KEY: <key>` a workflow wrapper appended to the brief,
# read off the first user message(s) of the agent's own transcript, sanitised to a file name
# (anything outside [A-Za-z0-9_.-] becomes `_`). Empty when the brief carries none. Keying the
# document by the STEP rather than the agent is what lets a replacement — spawned for the same step
# after a partial, or after the runtime killed its predecessor — find it without knowing any id.
handoff_key_of() {
  local tp="$1" k
  [ -n "$tp" ] && [ -f "$tp" ] || return 0
  k="$(head -n 5 "$tp" 2>/dev/null | jq -Rr '
        try fromjson catch empty | select(.type == "user") | .message.content
        | if type == "string" then . elif type == "array" then map(.text? // "") | join(" ") else "" end' 2>/dev/null \
      | grep -o 'HANDOFF_KEY: [^ ,;]*' | head -n 1 | cut -d' ' -f2 | sed 's/\.$//')"
  [ -n "$k" ] && printf '%s' "${k//[^A-Za-z0-9_.-]/_}"
  return 0
}

# window_of <transcript> — the input size of the newest request that actually billed something:
# cache read + cache creation + uncached input. Reads only the tail (a transcript is routinely
# hundreds of MB); a severed first line is dropped by `try fromjson`. A cancelled or synthetic
# turn writes an all-zero row after the real one, so the last row is not always the newest real
# one — take the last that billed. Prints 0 when nothing can be read.
window_of() {
  local tp="$1" w
  [ -n "$tp" ] && [ -f "$tp" ] || { printf '0'; return 0; }
  w="$(tail -c 400000 "$tp" 2>/dev/null | jq -Rn '
    [ inputs | try fromjson catch empty | .message.usage? // empty
      | ( (.cache_read_input_tokens // 0)
        + (.cache_creation_input_tokens // 0)
        + (.input_tokens // 0) )
      | select(. > 0) ] | last // 0' 2>/dev/null)"
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  printf '%s' "$w"
}
