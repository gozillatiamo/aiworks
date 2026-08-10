#!/usr/bin/env bash
# PostToolUse(Write|Edit) — flag bash-4-only syntax in a touched shell script.
#
# WHY THIS EXISTS
#   `#!/usr/bin/env bash` resolves to the FIRST bash on PATH. On the machine these scripts
#   are written on that is Homebrew's bash 5; on a stock Mac it is /bin/bash — 3.2.57, from
#   2007, the last GPLv2 release Apple could ship. So every workspace script has to run on
#   3.2, and nothing in a normal edit-and-run loop reveals when one no longer does.
#
#   `aiworks sync` shipped exactly that defect. One line —
#
#       local -A repo_owner=()          <- associative array, bash 4+
#
#   — on 3.2 prints `local: -A: invalid option`, leaves the name a plain string, and then
#   the very next assignment `repo_owner[$key]=…` is parsed as an INDEXED subscript, i.e.
#   arithmetic: `turnover-commission-batch` becomes `turnover - commission - batch`, the
#   first identifier is unset, and `set -u` kills the run. A teammate saw
#   `turnover: unbound variable` from a script that mentions no such variable, on the very
#   first repo in the config, and `sync` did nothing at all.
#
#   The bans below are the constructs that break that way — silently on the author's box,
#   fatally on a stock Mac.
#
# Advisory, never blocking: it runs AFTER the write, and mid-edit breakage is normal. Prints
# to stderr so it lands in the transcript.
#
#   --scan   check every tracked shell script instead of a hook payload; exit 1 on any hit.
#            Use in CI or after a sweep:  .claude/hooks/dev-wrapper/posttool-bash-portability.sh --scan
set -uo pipefail

# construct → what to use on bash 3.2 instead
report() {  # $1=file
  local f="$1" hits
  # Full-line comments are dropped: this very file, and the notes left beside each fix, all
  # NAME the banned constructs in prose. Matching those would make the check cry wolf forever.
  hits="$(grep -nE \
    '(^|[^[:alnum:]_])(declare|local|typeset)[[:space:]]+-[A-Za-z]*A|(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|shopt[[:space:]]+-s[[:space:]]+globstar|;;&' \
    "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')" || return 0
  [[ -n "$hits" ]] || return 0
  printf '⚠️  bash 4+ syntax in %s — macOS /bin/bash is 3.2, this dies there\n' "${f#./}" >&2
  printf '%s\n' "$hits" | sed 's/^/    /' | head -8 >&2
  printf '    3.2 equivalents: associative array → lookup function or a flat "k\\037v" string ·\n' >&2
  printf '                     mapfile → while IFS= read -r · ${v,,} → tr · globstar → find\n' >&2
  return 1
}

if [[ "${1:-}" == "--scan" ]]; then
  root="$(cd "$(dirname "$0")/../../.." && pwd)"
  cd "$root" || exit 0
  rc=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    case "$f" in */node_modules/*|*/vendor/*) continue ;; esac
    report "$f" || rc=1
  done < <(git ls-files '*.sh' 'aiworks' 'scripts/aiworks' '.superset/*' 2>/dev/null)
  [[ $rc -eq 0 ]] && printf 'bash portability: every tracked script is 3.2-clean\n'
  exit "$rc"
fi

payload="$(cat)"
file="$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("tool_input",{}).get("file_path",""))
except Exception:
    print("")' 2>/dev/null || true)"

[[ -n "$file" && -f "$file" ]] || exit 0
case "$file" in
  *.sh|*/aiworks) ;;
  *) # no extension: only treat it as shell when the shebang says so
     head -1 "$file" 2>/dev/null | grep -qE '^#!.*\b(bash|sh)\b' || exit 0 ;;
esac

report "$file" || true
exit 0
