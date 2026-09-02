#!/usr/bin/env bash
# aiworks-harnesses.sh — configure shared Harnesses, reconcile the active set, remove one on request.
#
# Usage:
#   aiworks harnesses list [--active]
#   aiworks harnesses configure [--harnesses claude,cursor,codex] [--reconfigure]
#   aiworks harnesses sync [<repo>…] [--check|-n]       # active set (local wins); adds/updates only
#   aiworks harnesses remove <id>[,<id>…] [<repo>…] [-n] # the ONLY path that deletes a projection
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
CONFIG="$ROOT/workspace.config.yaml"
CONFIG_LOCAL="$ROOT/workspace.config.local.yaml"
REGISTRY="$DIR/harnesses/registry.json"
HELPER="$DIR/harnesses/config.py"

die() { printf 'aiworks harnesses: %s\n' "$*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ -f "$HELPER" && -f "$REGISTRY" ]] || die "Harness registry/helper is missing"

shared_selected() { python3 "$HELPER" list --config "$CONFIG" --registry "$REGISTRY" "$@"; }
active_selected() { python3 "$HELPER" list --config "$CONFIG" --config-local "$CONFIG_LOCAL" --registry "$REGISTRY" "$@"; }

repo_dirs() {
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); gsub(/^['"'"']|['"'"']$/,"",s); return s }
    function flush(){ if(url!=""){ d=path; if(d==""){ d=url; sub(/\.git$/,"",d); sub(/^.*\//,"",d) } print d } url=""; path="" }
    /^products:[ \t]*$/ { inp=1; next }
    inp && /^  - id:/ { flush(); inrepos=0; next }
    inp && /^    repos:[ \t]*$/ { inrepos=1; next }
    inrepos && /^      - / { flush(); line=$0; sub(/^      - /,"",line); if(line~/^url:/)url=val(line); next }
    inrepos && /^        url:/ { url=val($0); next }
    inrepos && /^        path:/ { path=val($0); next }
    /^[A-Za-z_]/ { flush(); inp=0; inrepos=0 }
    END { flush() }
  ' "$CONFIG"
}

cleanup_agents_md() { # <targets-space> <mode-args-space>
  local targets="$1" modes="$2" base p failed=0
  [[ -n "$targets" ]] || { targets="."; while IFS= read -r p; do targets="$targets $p"; done < <(repo_dirs); }
  for p in $targets; do
    if [[ "$p" == . || "$p" == root ]]; then base="$ROOT"; else base="$ROOT/$p"; fi
    [[ -d "$base" ]] || continue
    [[ -L "$base/AGENTS.md" && "$(readlink "$base/AGENTS.md")" == CLAUDE.md ]] || continue
    case " $modes " in
      *" --dry-run "*) printf 'aiworks harnesses: would remove %s/AGENTS.md\n' "$p" ;;
      *" --check "*) printf 'aiworks harnesses: generator-owned %s/AGENTS.md remains\n' "$p" >&2; failed=1 ;;
      *) rm -f "$base/AGENTS.md" ;;
    esac
  done
  return "$failed"
}

cmd="${1:-list}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
  list)
    active=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --active) active=1; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown list option: $1" ;;
      esac
    done
    if [[ "$active" -eq 1 ]]; then active_selected --fallback
    else shared_selected --fallback; fi
    ;;
  configure)
    [[ -f "$CONFIG" ]] || die "no workspace.config.yaml — author the organization config first"
    values=""; reconfigure=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --harnesses) values="${2:-}"; shift 2 ;;
        --reconfigure) reconfigure=1; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown configure option: $1" ;;
      esac
    done
    if [[ -z "$values" && "$reconfigure" -eq 0 ]]; then
      existing="$(shared_selected 2>/dev/null || true)"
      if [[ -n "$existing" ]]; then printf '%s\n' "$existing"; exit 0; fi
    fi
    if [[ -z "$values" ]]; then
      if [[ ! -t 0 ]] && ! { true </dev/tty; } 2>/dev/null; then
        printf 'aiworks harnesses: no interactive terminal; preserving legacy defaults (claude,cursor).\n' >&2
        shared_selected --fallback
        exit 0
      fi
      printf 'Select Agent harnesses (comma-separated numbers or ids):\n' >/dev/tty
      index=0; defaults=""; ids=""
      while IFS='|' read -r id display default _; do
        index=$((index + 1)); ids="${ids:+$ids }$id"
        [[ "$default" == yes ]] && defaults="${defaults:+$defaults,}$id"
        printf '  %d) %s [%s]%s\n' "$index" "$display" "$id" "$([[ "$default" == yes ]] && printf ' (default)' || true)" >/dev/tty
      done < <(python3 "$HELPER" catalog --registry "$REGISTRY")
      printf 'Selection [%s]: ' "$defaults" >/dev/tty
      IFS= read -r answer </dev/tty || answer=""
      [[ -n "$answer" ]] || answer="$defaults"
      values=""
      for choice in $(printf '%s' "$answer" | tr ',' ' '); do
        choice="$(printf '%s' "$choice" | tr -d ' ')"
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          n=1; for id in $ids; do [[ "$n" -eq "$choice" ]] && choice="$id"; n=$((n + 1)); done
        fi
        values="${values:+$values,}$choice"
      done
    fi
    python3 "$HELPER" set --config "$CONFIG" --registry "$REGISTRY" --harnesses "$values"
    ;;
  sync|check)
    # Reconciles the ACTIVE set — workspace.config.local.yaml wins over the shared file — and
    # only ever ADDS or UPDATES. A Harness absent from the set is left exactly as it is on disk:
    # dropping an id from either config file must never delete a projection a teammate committed,
    # and a teammate whose local file omits it must never see `aiworks sync` tear it out of a
    # shared checkout. Deletion is an explicit act — `aiworks harnesses remove <id>` (also reached
    # as `aiworks remove --harnesses <id>`).
    mode_args=""
    target_args=""
    [[ "$cmd" == check ]] && mode_args="--check"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -n|--dry-run) mode_args="${mode_args:+$mode_args }--dry-run"; shift ;;
        --check) mode_args="${mode_args:+$mode_args }--check"; shift ;;
        -*) die "unknown sync option: $1" ;;
        *) target_args="${target_args:+$target_args }$1"; shift ;;
      esac
    done
    chosen=" $(active_selected --fallback | tr '\n' ' ') "
    failed=0
    while IFS='|' read -r id _display _default _cli projector _adapter _guidance; do
      [[ -n "$projector" && "$chosen" == *" $id "* ]] || continue
      script="$ROOT/$projector"
      [[ -x "$script" ]] || { printf 'aiworks harnesses: missing projector %s\n' "$projector" >&2; failed=1; continue; }
      "$script" $target_args $mode_args || failed=1
    done < <(python3 "$HELPER" catalog --registry "$REGISTRY")
    exit "$failed"
    ;;
  remove)
    # The ONLY path that deletes a projection. Runs the projector's --remove (generator-owned
    # files only — its own contract), drops the id from BOTH config files so the next sync does
    # not project it straight back, and clears the generator-owned AGENTS.md once no remaining
    # active Harness reads it.
    mode_args=""
    target_args=""
    ids=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -n|--dry-run) mode_args="--dry-run"; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown remove option: $1" ;;
        *) if [[ -z "$ids" ]]; then ids="$(printf '%s' "$1" | tr ',' ' ')"
           else target_args="${target_args:+$target_args }$1"; fi; shift ;;
      esac
    done
    [[ -n "$ids" ]] || die "usage: aiworks harnesses remove <id>[,<id>…] [<repo>…] [--dry-run]"
    catalog="$(python3 "$HELPER" catalog --registry "$REGISTRY")"
    for id in $ids; do
      printf '%s\n' "$catalog" | grep -q "^$id|" || die "unknown Harness '$id'"
    done
    remaining=" $(active_selected --fallback 2>/dev/null | tr '\n' ' ') "
    failed=0
    for id in $ids; do
      # Config first: `drop` refuses to empty a set, and a refused drop must not delete files.
      if [[ "$mode_args" == --dry-run ]]; then
        printf 'aiworks harnesses: would drop %s from workspace.config.yaml / workspace.config.local.yaml\n' "$id"
      else
        dropped=1
        for f in "$CONFIG" "$CONFIG_LOCAL"; do
          python3 "$HELPER" drop --config "$f" --registry "$REGISTRY" --harnesses "$id" >/dev/null || dropped=0
        done
        [[ "$dropped" -eq 1 ]] || { failed=1; continue; }
      fi
      remaining="${remaining// $id / }"
      projector="$(printf '%s\n' "$catalog" | awk -F'|' -v id="$id" '$1==id{print $5}')"
      [[ -n "$projector" ]] || continue
      script="$ROOT/$projector"
      [[ -x "$script" ]] || { printf 'aiworks harnesses: missing projector %s\n' "$projector" >&2; failed=1; continue; }
      "$script" --remove $target_args $mode_args || failed=1
    done
    # The generator-owned AGENTS.md goes only once nothing left in the active set reads it.
    keep_agents=0
    while IFS='|' read -r id _display _default _cli _projector _adapter guidance; do
      [[ "$guidance" == agents-md && "$remaining" == *" $id "* ]] && keep_agents=1
    done <<< "$catalog"
    [[ "$keep_agents" -eq 1 ]] || cleanup_agents_md "$target_args" "$mode_args" || failed=1
    exit "$failed"
    ;;
  *) die "unknown command: $cmd" ;;
esac
