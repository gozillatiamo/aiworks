#!/bin/bash
# refresh-savings — Stop-hook helper that keeps the statusline's caveman savings
# line current WITHOUT the user manually running /caveman-stats.
#
# On each turn end Claude Code invokes this with the Stop-hook JSON on stdin
# (carries .transcript_path). We run the caveman plugin's caveman-stats.js
# against that transcript purely for its side effects — it appends a lifetime
# snapshot to .caveman-history.jsonl and rewrites .caveman-statusline-suffix —
# and discard its stdout. statusline.sh then reads those updated figures.
#
# Design notes:
#   * Plugin path is resolved by glob, newest first: the plugin cache dir carries
#     a content hash that changes on every plugin update, so hardcoding it would
#     silently break. ${CLAUDE_PLUGIN_ROOT} is NOT set for user-level hooks.
#   * Throttled to at most once per 60s (suffix-file mtime): caveman-stats.js
#     appends a history line every run, so firing it on literally every turn
#     would bloat .caveman-history.jsonl. Correctness is unaffected either way
#     (the plugin keeps only the latest row per session_id); this just bounds
#     file growth.
#   * Cross-platform mtime: BSD/macOS `stat -f %m`, GNU/Linux `stat -c %Y`.
#   * Always exits 0 and never prints to stdout/stderr — a Stop hook must not
#     block the turn or inject text.
#
# Install: add this file to hooks.Stop in settings.json. See README.md.

input=$(cat)
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Throttle: skip if the suffix was refreshed within the last 60s.
SUF="$CFG/.caveman-statusline-suffix"
if [ -f "$SUF" ] && [ ! -L "$SUF" ]; then
  NOW=$(date +%s)
  MT=$(file_mtime "$SUF")
  [ $((NOW - MT)) -lt 60 ] && exit 0
fi

# Resolve the plugin's stats script (newest hashed cache dir wins).
SCRIPT=$(ls -t "$CFG"/plugins/cache/caveman/caveman/*/src/hooks/caveman-stats.js 2>/dev/null | head -1)
[ -z "$SCRIPT" ] && exit 0

command -v node >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

TP=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$TP" ] && exit 0
[ -f "$TP" ] || exit 0

node "$SCRIPT" --session-file "$TP" >/dev/null 2>&1
exit 0
