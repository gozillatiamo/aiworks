#!/usr/bin/env bash
#
# python-sources-selftest.sh — fail loudly when a tracked Python source does not parse or
# references a name that is never defined.
#
# A bad merge can leave a file that still LOOKS like Python (a dropped `def` header, a name
# from the other side of the merge) and dies only when it is imported. For an MCP server that
# shows up as a silent CONNECTION_CLOSED in every session, not as a red check. Two passes:
#   1. `ast.parse` (stdlib, offline)          — SyntaxError ⇒ FAIL
#   2. pyflakes, `undefined name` lines only   — unused imports/redefinitions are noise, not breakage
# A canary runs first so a pass that has gone blind cannot report green.
#
# Usage: python-sources-selftest.sh [file.py …]     (default: every `git ls-files '*.py'`)
# Exit:  0 clean · 1 failures · 2 NOT RUN (tool missing/unfetchable — never fails open)
#
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PYFLAKES=pyflakes==4.0.0

for t in python3 uvx; do
  command -v "$t" >/dev/null 2>&1 || { echo "NOT RUN: $t not on PATH"; exit 2; }
done

parse_check() {  # parse_check <file…> — prints "FAIL file:line msg" per SyntaxError
  python3 - "$@" <<'PY'
import ast, sys, warnings
warnings.simplefilter("ignore", SyntaxWarning)
for f in sys.argv[1:]:
    try:
        with open(f, "rb") as fh:
            ast.parse(fh.read(), f)
    except SyntaxError as e:
        print(f"FAIL {f}:{e.lineno} {e.msg}")
PY
}
undefined_check() {  # undefined_check <file…> — prints "FAIL <pyflakes line>" per undefined name
  local out rc
  out="$(uvx --quiet "$PYFLAKES" "$@" 2>&1)"; rc=$?
  if [[ $rc -gt 1 ]]; then echo "NOT RUN: $PYFLAKES could not run (exit $rc)"; return 2; fi
  printf '%s\n' "$out" | grep "undefined name '" | sed 's/^/FAIL /'
  return 0
}

# ── canary: each pass must still catch a planted break ──────────────────────────
C="$(mktemp -d)"; trap 'rm -rf "$C"' EXIT
printf 'x = "\n' > "$C/syntax.py"
printf 'def f():\n    return missing_name\n' > "$C/undef.py"
parse_check "$C/syntax.py" | grep -q '^FAIL ' || { echo "guard is blind: ast pass missed a SyntaxError"; exit 1; }
u="$(undefined_check "$C/undef.py")" || { echo "$u"; exit 2; }
grep -q "missing_name" <<<"$u" || { echo "guard is blind: pyflakes pass missed an undefined name"; exit 1; }

# ── scan ────────────────────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then files=("$@"); else
  mapfile -t files < <(git -C "$ROOT" ls-files '*.py' | sed "s|^|$ROOT/|")
fi
[[ ${#files[@]} -gt 0 ]] || { echo "0 files · 0 failures"; exit 0; }

fails="$(parse_check "${files[@]}")"
u="$(undefined_check "${files[@]}")" || { echo "$u"; exit 2; }
fails="$(printf '%s\n%s\n' "$fails" "$u" | sed '/^$/d')"
[[ -n "$fails" ]] && printf '%s\n' "$fails"
n=$(printf '%s' "$fails" | grep -c '^FAIL ' || true)
echo "${#files[@]} files · ${n:-0} failures"
[[ "${n:-0}" -eq 0 ]]
