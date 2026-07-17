#!/bin/bash
# caveman-statusline — a Claude Code statusline with a caveman token-savings
# monitor built in.
#
# Renders three lines:
#   1. [model  effort:level] dir | branch
#   2. context progress bar + used/total tokens
#   3. caveman savings monitor — lifetime output-token savings from the caveman
#      plugin (only while caveman is armed)
#
# The savings figures come from the caveman plugin's own log,
# $CLAUDE_CONFIG_DIR/.caveman-history.jsonl (usually ~/.claude), which is
# refreshed whenever /caveman-stats runs — or on every turn end if you wire the
# companion refresh-savings.sh Stop hook (see README.md). The statusline cannot
# run node itself, so the numbers are only as fresh as the last refresh.
#
# Requires: jq (savings line only). Falls back gracefully if node/jq/caveman are
# absent — the first two lines always render.
#
# Install: point settings.json → statusLine.command at this file, OR copy just
# the "Caveman savings monitor" block into your existing statusline. See
# README.md in this directory.
#
# Opt out of the savings line without removing it: export CAVEMAN_STATUSLINE_SAVINGS=0

input=$(cat)

# ── Session fields ──────────────────────────────────────────────────────────
SESSION_MODEL=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
SESSION_EFFORT=$(echo "$input" | jq -r '.effort.level // ""')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "."')
PCT_RAW=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
PCT=$(printf '%.0f' "$PCT_RAW")
TOTAL_INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
CONTEXT_WINDOW_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
ORANGE='\033[38;5;172m'; RESET='\033[0m'

# Context-usage bar color
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

# 10-block progress bar
FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED)); BAR=""
i=0; while [ $i -lt $FILLED ]; do BAR="${BAR}█"; i=$((i+1)); done
i=0; while [ $i -lt $EMPTY ]; do BAR="${BAR}░"; i=$((i+1)); done

BRANCH=""
git -c gc.auto=0 rev-parse --git-dir > /dev/null 2>&1 && BRANCH=" | $(git -c gc.auto=0 branch --show-current 2>/dev/null)"

# Human token count (K/M). awk keeps this portable — no bc dependency.
format_tokens() {
  awk -v n="$1" 'BEGIN{
    if (n>=1000000) printf "%.1fM", n/1000000;
    else if (n>=1000)  printf "%.1fK", n/1000;
    else               printf "%d",   n;
  }'
}

TOKENS_USED=$(format_tokens "$TOTAL_INPUT_TOKENS")
TOKENS_TOTAL=$(format_tokens "$CONTEXT_WINDOW_SIZE")

# Line 1
EFFORT_STR=""
if [ -n "$SESSION_EFFORT" ] && [ "$SESSION_EFFORT" != "null" ]; then
  EFFORT_STR="  effort:${SESSION_EFFORT}"
fi
printf "${CYAN}[${SESSION_MODEL}${EFFORT_STR}]${RESET} ${DIR##*/}${BRANCH}\n"

# Line 2
printf "${BAR_COLOR}${BAR}${RESET} ${PCT}%% (${TOKENS_USED}/${TOKENS_TOTAL} tokens)\n"

# ── Caveman savings monitor ─────────────────────────────────────────────────
# Line 3: lifetime output-token savings from the caveman plugin. Figures come
# from $CLAUDE_CONFIG_DIR/.caveman-history.jsonl (refreshed by /caveman-stats or
# the refresh-savings.sh Stop hook). Only rendered while caveman is armed;
# refuses symlinks and whitelists the mode (matches the caveman plugin's own
# statusline hardening). Opt out with CAVEMAN_STATUSLINE_SAVINGS=0.
if [ "${CAVEMAN_STATUSLINE_SAVINGS:-1}" != "0" ]; then
  CAVE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  CAVE_FLAG="$CAVE_DIR/.caveman-active"
  CAVE_HIST="$CAVE_DIR/.caveman-history.jsonl"
  if [ -f "$CAVE_FLAG" ] && [ ! -L "$CAVE_FLAG" ]; then
    CAVE_MODE=$(head -c 64 "$CAVE_FLAG" 2>/dev/null | tr -d '\n\r' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    case "$CAVE_MODE" in
      off|lite|full|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra|commit|review|compress) ;;
      *) CAVE_MODE="" ;;
    esac
    if [ -n "$CAVE_MODE" ] && [ "$CAVE_MODE" != "off" ]; then
      BADGE="[CAVEMAN]"
      [ "$CAVE_MODE" != "full" ] && BADGE="[CAVEMAN:$(printf '%s' "$CAVE_MODE" | tr '[:lower:]' '[:upper:]')]"
      SAV_TOK=0; SAV_USD=0; SAV_SESS=0
      if [ -f "$CAVE_HIST" ] && [ ! -L "$CAVE_HIST" ] && command -v jq >/dev/null 2>&1; then
        CAVE_AGG=$(jq -s 'group_by(.session_id)|map(max_by(.ts))|{s:length,t:(map(.est_saved_tokens)|add // 0),u:(map(.est_saved_usd)|add // 0)}' "$CAVE_HIST" 2>/dev/null)
        if [ -n "$CAVE_AGG" ]; then
          SAV_TOK=$(printf '%s' "$CAVE_AGG" | jq -r '.t // 0'); SAV_TOK=${SAV_TOK%.*}
          SAV_USD=$(printf '%s' "$CAVE_AGG" | jq -r '.u // 0')
          SAV_SESS=$(printf '%s' "$CAVE_AGG" | jq -r '.s // 0')
        fi
      fi
      if [ "${SAV_TOK:-0}" -gt 0 ] 2>/dev/null; then
        SAV_TOKH=$(format_tokens "$SAV_TOK")
        SAV_USDH=$(printf '%.2f' "${SAV_USD:-0}" 2>/dev/null || echo 0)
        printf "${ORANGE}⛏ ${BADGE}${RESET} saved ${SAV_TOKH} tok (~\$${SAV_USDH}) · ${SAV_SESS} sess\n"
      else
        printf "${ORANGE}⛏ ${BADGE}${RESET} no savings logged yet — run /caveman-stats\n"
      fi
    fi
  fi
fi
