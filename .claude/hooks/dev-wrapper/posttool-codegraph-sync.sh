#!/usr/bin/env bash
#
# PostToolUse(Write|Edit) hook — keep the touched repo's codegraph index current.
#
# The index is only worth querying if it matches the working tree. Nothing kept it
# in step: the agent files claimed "the index stays fresh via the Write/Edit
# `codegraph sync` hook", but no such hook was ever wired — the index was as old as
# the last manual `codegraph init`. An agent that edits twenty files and then asks
# codegraph where something lives gets an answer describing the code as it was
# before its own work.
#
# The alternative was codegraph's file watcher, which exists only inside
# `codegraph serve --mcp` (`--no-watch` turns it off) — one long-lived MCP process
# per repo, twenty-one of them, for a workspace that deliberately drives codegraph
# from the CLI. A hook fires exactly when a file changes, holds no state, leaks no
# processes, and reaches subagents and Cursor the same way every other guard does.
#
# Cost: `codegraph sync -q` measured 40–100 ms including node startup, on repos up
# to a 37 MB index. It is still run DETACHED so the agent never waits on it, and
# debounced per repo so a burst of edits triggers one sync rather than twenty.
#
# Always exits 0. A sync failure must never fail the edit that triggered it.

set -uo pipefail

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -n "$path" ] || exit 0
command -v codegraph >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || exit 0
case "$path" in "$ROOT"/*) ;; *) exit 0 ;; esac

# Which repo does the edited file belong to? First path segment under the root.
rel="${path#"$ROOT"/}"
repo="${rel%%/*}"
[ -n "$repo" ] && [ "$repo" != "$rel" ] || exit 0     # a file at the root itself
# The DATABASE is the marker, not the directory — `~/.codegraph/` is codegraph's
# own install dir, so a bare directory test is not evidence of an index.
[ -f "$ROOT/$repo/.codegraph/codegraph.db" ] || exit 0

# Debounce: one sync per repo per DEBOUNCE seconds. An agent writing a slice of ten
# files would otherwise spawn ten syncs racing on the same SQLite index.
DEBOUNCE=3
state="${TMPDIR:-/tmp}/aiworks-codegraph-sync"
mkdir -p "$state" 2>/dev/null || exit 0
stamp="$state/$repo"
now=$(date +%s)
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt "$DEBOUNCE" ] && exit 0
fi
printf '%s' "$now" > "$stamp" 2>/dev/null

# Detached and silent. `sync` is incremental; a concurrent run is what the debounce
# above is for, and codegraph's own lock handles the rest.
( codegraph sync -q -p "$ROOT/$repo" >/dev/null 2>&1 & ) >/dev/null 2>&1

exit 0
