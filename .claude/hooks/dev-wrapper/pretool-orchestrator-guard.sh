#!/usr/bin/env bash
#
# PreToolUse(Bash|Write|Edit|NotebookEdit) hook — once a dev-cycle run has FINISHED in
# this session, the session's job is to ORCHESTRATE (spawn the agent that owns the
# work, or resume the run) — not to hand-implement inside a product repo itself.
#
# WHY THIS EXISTS (root-caused; see docs/adr/0019)
#   A run that ended blocked/halted saw the ORCHESTRATOR SESSION itself go on to make
#   17 Edits inside product repos and hand-write 8 dev-cycle run-state rows — all of it
#   invisible to the run's own state, review and gates. None of that work was ever
#   reviewed, tested through the pipeline, or checkpointed the way the run's own agents
#   checkpoint. The fix is not "don't do that" in prose (this workspace already tried
#   prose once and it did not hold — docs/adr/0019) — it is a mechanical deny.
#
# THE DISCRIMINATOR (settled; see the DEVCYCLE-RESILIENCE plan + docs/adr/0019 for the
# measurement). Per the official hooks reference, a PreToolUse payload carries
# `agent_id` and `agent_type` ONLY when a SUBAGENT issues the tool call. This guard is
# triple-redundant toward ALLOW, so its failure direction is inert, never a pipeline
# break:
#   ALLOW — `.agent_id` present and non-empty (the documented subagent signal).
#   ALLOW — `.transcript_path` contains the substring `/subagents/` (covers both
#           `subagents/agent-*.jsonl` AND a workflow agent's
#           `subagents/workflows/wf_*/agent-*.jsonl` — a case-glob on the LEAF alone is
#           too narrow to catch the workflow shape, so this is a substring test).
#   ALLOW — `.transcript_path` is EMPTY/unknown (inconclusive ⇒ never deny on a guess).
#   ⚠️ `CLAUDE_CODE_CHILD_SESSION` is deliberately NOT a signal: measured with
#   scripts/hook-signal-probe.sh, the hook process sees child=1 on EVERY call — main
#   and subagent alike (the hook process is itself a Claude-spawned child) — so an
#   allow on it made this guard permanently inert. `agent_id` is the one signal the
#   same probe confirmed to discriminate; `transcript_path` pointed at the MAIN
#   session transcript for both callers, so its allow is kept only as belt-and-braces.
#   Only when NONE of the above fire (i.e. a non-empty transcript_path that does NOT
#   name a subagent transcript) does this guard treat the caller as MAIN and apply the
#   deny set below.
#
# ARMED WINDOW. A marker file, written by the run itself (Kickoff: armed:true from the
# very start — the run's OWN agents pass on the payload's agent_id, probe-confirmed;
# Summary rewrites it with run_state:"ended" — see docs/adr/0019) gates the whole
# guard: no marker, or armed:false, or a session mismatch ⇒ exit 0 immediately. The
# MAIN session is held to orchestration for the whole run and for the rest of the
# session after it.
#
# DENY SET (only once armed + session-matched + caller identified as MAIN):
#   • Write|Edit|NotebookEdit landing inside a PRODUCT REPO (a first-level directory of
#     the workspace root that is itself a git checkout — `pretool-repo-context.sh`'s own
#     "nested repo" test, mirrored here) or under any `agent_logs/*-dev-cycle-state/`
#     (a hand-written run-state row).
#   • A Bash `git` invocation whose resolved directory (honouring an explicit
#     `git -C <dir>`, else the payload cwd) is inside a product repo AND whose verb
#     mutates history: commit|apply|am|rebase|cherry-pick|revert|reset|stash.
#     ⚠️ merge|push are deliberately NOT denied: they are the sanctioned HUMAN ship
#     verbs (the run emits Merge/Distribute as `!` command templates), and the probe
#     measured that hooks fire main-shaped on a user's own `!` input too — denying
#     them would block the ship flow itself. The measured leak (edits, commits, a
#     destructive rebase, forged state rows) stays fully covered.
#     Read verbs (status|log|diff|show|rev-parse|ls-remote|branch|checkout|switch|
#     fetch|worktree|config|…) stay free — `checkout`/`switch` are how a human inspects
#     a branch, and the submodule/plan-guard hooks already cover their own concerns.
# Everything OUTSIDE the workspace root (the scratchpad), `.claude/`, `docs/`,
# `scripts/`, and the root `agent_logs/` (run summaries) stays writable.
#
# Exit 0 = no opinion · exit 2 = block, stderr goes to the model. Fails OPEN on
# anything it cannot determine — an inert guard beats one that blocks the pipeline.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$root" ] || exit 0

# --- 1. armed? a marker written by the run, for THIS session -----------------------
marker=""
for m in "$root"/agent_logs/*-dev-cycle-state/orchestrator-guard.json; do
  [ -f "$m" ] && marker="$m"
done
[ -n "$marker" ] || exit 0
armed=$(jq -r '.armed // false' "$marker" 2>/dev/null)
[ "$armed" = "true" ] || exit 0
msession=$(jq -r '.session_id // ""' "$marker" 2>/dev/null)
psession=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$msession" ] && [ "$msession" = "${psession:-${CLAUDE_CODE_SESSION_ID:-}}" ] || exit 0

# --- 2. who is calling? redundant toward ALLOW --------------------------------------
# (no CLAUDE_CODE_CHILD_SESSION check: the hook env carries child=1 for EVERY caller —
#  measured via scripts/hook-signal-probe.sh — so that allow made the guard inert)
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)
[ -n "$agent_id" ] && exit 0
tp=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
case "$tp" in *"/subagents/"*) exit 0 ;; esac
[ -n "$tp" ] || exit 0   # unknown/empty transcript_path ⇒ inconclusive ⇒ allow

# --- helpers -------------------------------------------------------------------------

deny() { # <what was refused>
  printf '⛔ The dev-cycle for this session has run and ended, so this session ORCHESTRATES — it does not implement.\n' >&2
  printf 'Refused: %s\n\n' "$1" >&2
  cat >&2 <<'EOF'
Do it the way the pipeline can see: spawn the agent that owns the work, or resume the run —
  /dev-cycle <KEY>            (run state scopes it to what is unfinished)
  /dev-cycle <KEY> --approve-plan
A hand-edit here is invisible to the run's own state, review and gates: docs/adr/0019.
Read-only diagnosis is untouched (git status/log/diff/show, Read, Grep, codegraph).
EOF
  exit 2
}

is_product_repo() { # <first-level dir name under $root>
  [ -n "$1" ] && [ -e "$root/$1/.git" ]
}

# --- 3. Write / Edit / NotebookEdit --------------------------------------------------
case "$tool" in
  Write|Edit|NotebookEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    [ -n "$path" ] || exit 0
    cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
    case "$path" in
      /*) abspath="$path" ;;
      *) abspath="${cwd:-$root}/$path" ;;
    esac
    case "$abspath" in
      "$root"/*) rel="${abspath#"$root"/}" ;;
      *) exit 0 ;;   # outside the workspace root (e.g. the scratchpad) — allowed
    esac
    case "$rel" in
      */agent_logs/*-dev-cycle-state/*|agent_logs/*-dev-cycle-state/*)
        deny "a hand-written run-state row (\"$rel\")" ;;
    esac
    firstseg="${rel%%/*}"
    if is_product_repo "$firstseg"; then
      deny "an ${tool} inside product repo \"$firstseg\""
    fi
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

# --- 4. Bash git -----------------------------------------------------------------------
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0
pcwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
cwd="${pcwd:-$root}"

# Same normalization as the sibling guards: fd-duplication redirects split badly.
cmd_norm=$(printf '%s' "$cmd" | sed -E 's/[0-9]*>&[0-9-]+//g; s/&>>?/>/g')
segments=$(printf '%s' "$cmd_norm" | sed -E 's/(\|\||&&|[;|&])/\n/g')

MUT_GIT='commit|apply|am|rebase|cherry-pick|revert|reset|stash'

while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')
  [ -z "$seg" ] && continue

  case "$seg" in
    cd\ *)
      d=$(printf '%s' "$seg" | awk '{print $2}' | tr -d '"'\''')
      case "$d" in /*) cwd="$d" ;; *) [ -n "$d" ] && cwd="$cwd/$d" ;; esac
      continue ;;
  esac

  word=$(printf '%s' "$seg" | awk '{print $1}'); word=${word##*/}
  [ "$word" = "git" ] || continue

  # Honour an explicit `git -C <dir>` — awk, not sed (BSD sed's empty-group backref on
  # an optional quote is broken; see pretool-git-guard.sh / pretool-submodule-guard.sh).
  gdir=$(printf '%s' "$seg" | awk '{for(i=1;i<NF;i++) if($i=="-C"){v=$(i+1); gsub(/^["\x27]|["\x27]$/,"",v); print v; exit}}')
  case "$gdir" in
    "") tdir="$cwd" ;;
    /*) tdir="$gdir" ;;
    *) tdir="$cwd/$gdir" ;;
  esac

  # First non-flag token after `git` (and past -C/-c/--git-dir/--work-tree + their value).
  sub=$(printf '%s' "$seg" | awk '{
    for(i=2;i<=NF;i++){
      if($i=="-C"||$i=="-c"||$i=="--git-dir"||$i=="--work-tree"){i++; continue}
      if(substr($i,1,1)=="-") continue
      print $i; exit
    }}')
  printf '%s' "$sub" | grep -qE "^($MUT_GIT)$" || continue

  case "$tdir" in
    "$root"/*) rel="${tdir#"$root"/}" ;;
    "$root") rel="" ;;
    *) continue ;;   # outside the workspace root — allowed
  esac
  firstseg="${rel%%/*}"
  [ -n "$firstseg" ] || continue
  if is_product_repo "$firstseg"; then
    deny "a mutating git verb \"$sub\" in \"$firstseg\""
  fi
done <<EOF
$segments
EOF

exit 0
