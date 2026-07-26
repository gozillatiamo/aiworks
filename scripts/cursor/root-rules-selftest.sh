#!/usr/bin/env bash
#
# Regression suite for root-rule.awk — the transform that re-scopes one repo's
# rule so it can live at the workspace root without firing on every other repo.
#
# Run:  scripts/cursor/root-rules-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Fixtures are written into a THROWAWAY temp dir, never read from whatever repos
# this workspace happens to have cloned, so the result does not depend on one
# org's directory names. Same doctrine as guards-selftest.sh.
#
# The transform is the whole feature: get a glob prefix wrong and either the rule
# never fires (silent loss of every repo convention) or it fires everywhere
# (twenty repos' contradictory standards on one file). Neither failure is visible
# without a test — the generated file looks plausible either way.

set -uo pipefail

H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWKRULE="$H/root-rule.awk"
[ -f "$AWKRULE" ] || { echo "missing $AWKRULE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
run() { # run <fixture-file> [repo]
  awk -v repo="${2:-svc}" \
      -v origin="From \`${2:-svc}/.claude/rules/r.md\`." \
      -v desc="Fallback description." \
      -f "$AWKRULE" "$1"
}
has()   { if printf '%s' "$3" | grep -qF -- "$2"; then echo "  PASS  $1"; pass=$((pass+1));
          else echo "  FAIL  $1"; echo "        want line ~ $2"; fail=$((fail+1)); fi }
lacks() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "  FAIL  $1 (unexpected: $2)"; fail=$((fail+1));
          else echo "  PASS  $1"; pass=$((pass+1)); fi }

echo "== a repo-relative glob becomes repo-scoped =="
cat > "$TMP/list.md" <<'EOF'
---
description: Layout and conventions.
paths:
  - "src/**"
  - "tests/**"
globs:
  - "src/**"
  - "tests/**"
---

Body line one.
EOF
out=$(run "$TMP/list.md")
has   "first glob is prefixed"        '- "svc/src/**"'    "$out"
has   "second glob is prefixed"       '- "svc/tests/**"'  "$out"
lacks "the bare glob is gone"         '- "src/**"'        "$out"
has   "the description survives"      'description: Layout and conventions.' "$out"
has   "alwaysApply is pinned false"   'alwaysApply: false' "$out"
has   "the body survives"             'Body line one.'    "$out"
has   "provenance names the repo"     'From `svc/.claude/rules/r.md`.' "$out"
lacks "Claude's paths: key is dropped" 'paths:'           "$out"

echo "== the inline glob forms =="
printf -- '---\nglobs: src/**\n---\n\nB\n' > "$TMP/inline.md"
has "a single inline glob"    '- "svc/src/**"' "$(run "$TMP/inline.md")"
printf -- '---\nglobs: src/**, docs/**\n---\n\nB\n' > "$TMP/csv.md"
out=$(run "$TMP/csv.md")
has "comma-separated, first"  '- "svc/src/**"'  "$out"
has "comma-separated, second" '- "svc/docs/**"' "$out"

echo "== a rule with no glob is repo-wide, not dropped =="
printf -- '---\ndescription: Broad.\n---\n\nB\n' > "$TMP/noglob.md"
out=$(run "$TMP/noglob.md")
has "falls back to the whole repo" '- "svc/**"' "$out"
has "and keeps its description"    'description: Broad.' "$out"

echo "== a rule with no description gets the caller's fallback =="
printf -- '---\nglobs:\n  - "src/**"\n---\n\nB\n' > "$TMP/nodesc.md"
has "fallback description used" 'description: Fallback description.' "$(run "$TMP/nodesc.md")"

echo "== glob spellings that must normalise, not double up =="
printf -- '---\nglobs:\n  - ./src/**\n  - /lib/**\n  - "**/*.rs"\n---\n\nB\n' > "$TMP/odd.md"
out=$(run "$TMP/odd.md")
has   "leading ./ stripped"         '- "svc/src/**"'    "$out"
has   "leading / stripped"          '- "svc/lib/**"'    "$out"
has   "a recursive glob is scoped"  '- "svc/**/*.rs"'   "$out"
lacks "no doubled separator"        'svc//'             "$out"

echo "== the body is prose, not more frontmatter =="
# A horizontal rule inside the body must not be mistaken for a delimiter, or the
# rest of the rule is silently truncated.
printf -- '---\nglobs:\n  - "src/**"\n---\n\nBefore.\n\n---\n\nAfter.\n' > "$TMP/hr.md"
out=$(run "$TMP/hr.md")
has "text before the horizontal rule" 'Before.' "$out"
has "text after it survives too"      'After.'  "$out"

echo "== two repos never collide =="
printf -- '---\nglobs:\n  - "src/**"\n---\n\nB\n' > "$TMP/same.md"
a=$(run "$TMP/same.md" alpha); b=$(run "$TMP/same.md" bravo)
has   "repo alpha scopes to itself" '- "alpha/src/**"' "$a"
lacks "and not to bravo"            'bravo/'           "$a"
has   "repo bravo scopes to itself" '- "bravo/src/**"' "$b"
lacks "and not to alpha"            'alpha/'           "$b"

echo "== the output is a well-formed Cursor rule =="
out=$(run "$TMP/list.md")
[ "$(printf '%s\n' "$out" | head -1)" = "---" ] \
  && { echo "  PASS  starts with the frontmatter delimiter"; pass=$((pass+1)); } \
  || { echo "  FAIL  starts with the frontmatter delimiter"; fail=$((fail+1)); }
n=$(printf '%s\n' "$out" | grep -c '^---$')
[ "$n" -eq 2 ] \
  && { echo "  PASS  exactly one frontmatter block"; pass=$((pass+1)); } \
  || { echo "  FAIL  exactly one frontmatter block (found $n --- lines)"; fail=$((fail+1)); }

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
