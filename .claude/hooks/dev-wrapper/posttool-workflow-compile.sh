#!/usr/bin/env bash
# PostToolUse(Write|Edit) — compile a touched .claude/workflows/*.js the way the ENGINE
# loads it, and say so loudly when it no longer parses.
#
# WHY THIS EXISTS
#   A workflow is never `import`ed. The engine takes its source and builds a function
#   body from it, so the file is parsed in FUNCTION-BODY context — while `node --check`
#   parses the same file as an ES MODULE and passes it. The two disagree, and the gap is
#   not theoretical: an unescaped apostrophe inside a single-quoted string
#
#       detail: 'the cluster's own account'      <- closes the string early
#
#   sails through `node --check` and makes the whole workflow fail to load. That exact
#   defect has now shipped THREE times (`Noah's`, `cluster's`, `run's`), each time
#   breaking /prd or /dev-cycle entirely, each time invisible to every check we ran. It
#   is invisible to review too — the escaped `\'` a few words later looks like proof the
#   line is fine.
#
#   So the check has to BE the engine's parse, not a proxy for it. Wrapping the source in
#   an async function inside a .cjs file reproduces that context exactly AND gets a real
#   line number out of node, which `new AsyncFunction(...)` does not give.
#
# Advisory, never blocking: it runs AFTER the edit, and a half-finished workflow mid-edit
# is normal. It prints to stderr so the failure is visible in the transcript.
set -uo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("tool_input",{}).get("file_path",""))
except Exception:
    print("")' 2>/dev/null || true)"

case "$file" in
  */.claude/workflows/*.js) ;;
  *) exit 0 ;;
esac
[[ -f "$file" ]] || exit 0
command -v node >/dev/null 2>&1 || exit 0

probe="$(mktemp -t wfcompile).cjs"
trap 'rm -f "$probe"' EXIT

# Strip the leading `export` from `export const meta = …` (the engine does the same),
# then wrap in the async function body the engine builds.
python3 - "$file" "$probe" <<'PY' || exit 0
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'^export\s+', '', src, count=1, flags=re.M)
open(sys.argv[2], 'w').write(
    "(async function(args,budget,phase,agent,log,parallel,pipeline,workflow){\n" + src + "\n})();\n")
PY

if ! out="$(node --check "$probe" 2>&1)"; then
  # Report the WORKFLOW's own line numbering. The probe adds exactly one leading line, so
  # subtract 1. Match on the probe's BASENAME, not its full path: on macOS node prints the
  # /private-prefixed realpath of a mktemp file while $probe holds the /var symlink form,
  # so a full-path match silently never fires.
  echo "⚠️  workflow does not load: ${file##*/}" >&2
  printf '%s\n' "$out" \
    | awk -v pb="${probe##*/}" -v wf="${file##*/}" '
        { i=index($0, pb); if (i) { rest=substr($0, i+length(pb));
            if (match(rest, /^:[0-9]+/)) { n=substr(rest,2,RLENGTH-1)+0;
              print wf ":" (n-1) substr(rest, RLENGTH+1); next } }
          print }' \
    | head -6 >&2
  echo "   node --check on the .js itself PASSES this — the engine parses a function body, not a module." >&2
  echo "   Most likely an unescaped ' inside a single-quoted string." >&2
fi
exit 0
