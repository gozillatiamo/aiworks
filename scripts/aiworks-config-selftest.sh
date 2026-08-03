#!/usr/bin/env bash
#
# aiworks-config selftest — the ADVISORY guards in aiworks-config.sh, which are the surface a
# person actually reads after editing a config.
#
#   ./scripts/aiworks-config-selftest.sh
#
# WHY THIS SUITE EXISTS: `stagehand.enabled: ture` sat in a personal config for weeks. Every
# `*_cfg_bool` reader in scripts/ resolves "not truthy" to false, so the typo and a deliberate
# opt-out were the same thing to every surface that reports state — `aiworks voice status` said
# "off", which was true, and no line anywhere said why. The reader now logs it, but a reader's log
# needs VERBOSE=1; the guard tested here is the one that speaks unprompted.
#
# Runs the real script against FIXTURES and --dry-run, so nothing in the workspace is written:
# every path it would touch (dev-cycle.js, prd.js, the .code-workspace, both config files) is
# pointed at a temp copy.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$DIR/aiworks-config.sh"
pass=0 fail=0
T="$(mktemp -d "${TMPDIR:-/tmp}/aiworks-config-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n        %s\n' "$1" "${2:-}"; }
ck()  { # ck <label> <expect-substring|ABSENT:substring> <actual>
  case "$2" in
    ABSENT:*) case "$3" in *"${2#ABSENT:}"*) bad "$1" "did not expect '${2#ABSENT:}', got: $3" ;;
                                         *) ok "$1" ;; esac ;;
    *)        case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "want ⊃ $2 — got: $3" ;; esac ;;
  esac
}

# Every run needs writable stand-ins for the four files the script would REWRITE, or a passing
# suite would be quietly editing the workspace it is testing.
cp "$ROOT/.claude/workflows/dev-cycle.js" "$T/dc.js"
cp "$ROOT/.claude/workflows/prd.js"       "$T/prd.js"

run() { # run <config> <config-local> → the guards' output (stdout+stderr, generated blocks dropped)
  bash "$SCRIPT" --config "$1" --config-local "$2" \
       --target "$T/dc.js" --prd-target "$T/prd.js" --workspace "$T/ws.code-workspace" \
       --dry-run 2>&1 | sed -n '1,/^\/\/ ──/p'
}

printf '\nBOOLEAN VALUE GUARD\n'

# 1. The shared config. `ture` is the real typo; `yeah` proves it is not a hardcoded misspelling
# list but a set membership test.
sed -e 's/^\(notify:\)$/\1/' "$ROOT/workspace.config.yaml" > "$T/shared-typo.yaml"
perl -0pi -e 's/^(notify:\n  enabled: )true$/${1}ture/m; s/^(triage:\n  enabled: )true$/${1}yeah/m' "$T/shared-typo.yaml"
: > "$T/empty-local.yaml"
out="$(run "$T/shared-typo.yaml" "$T/empty-local.yaml")"
ck "a typo'd boolean in the shared config is reported"      "notify.enabled: ture" "$out"
ck "…and so is a second one, by set membership not spelling" "triage.enabled: yeah" "$out"
ck "the report says what the consequence is"                "reads as OFF"         "$out"

# 2. The PERSONAL config — the file the real typo lived in, and the one a teammate edits by hand
# with no review. A guard that only checked the shared file would have missed the incident it
# exists for.
cat > "$T/local-typo.yaml" <<'YAML'
language: th
stagehand:
  enabled: ture
voice:
  enabled: true
YAML
out="$(run "$ROOT/workspace.config.yaml" "$T/local-typo.yaml")"
ck "a typo'd boolean in the PERSONAL override is reported too" "stagehand.enabled: ture" "$out"
ck "the report names which FILE it is in"                      "local-typo.yaml"         "$out"
ck "a correct flag beside it is not dragged in"  "ABSENT:voice.enabled"                   "$out"

# 3. No false positives. Every one of these is a legal YAML boolean a teammate may reasonably
# write; a guard that flags them is noise, and noise gets ignored — which is how the original
# typo would survive a second time.
cp "$ROOT/workspace.config.yaml" "$T/spellings.yaml"
perl -0pi -e 's/^(notify:\n  enabled: )true$/${1}yes/m;
              s/^(triage:\n  enabled: )true$/${1}ON/m;
              s/^(  auto_merge: )false$/${1}off/m;
              s/^(artifacts:\n  enabled: )false$/${1}0/m' "$T/spellings.yaml"
out="$(run "$T/spellings.yaml" "$T/empty-local.yaml")"
ck "yes / ON / off / 0 all pass as booleans" "every boolean flag in the live config carries a boolean" "$out"

# 4. The learning set must stay STRICT. Which keys are boolean is learned from the templates by
# their literal true/false — admit 0 and 1 and every count in the file becomes a "boolean", so
# `narrate_gap: 0` would be legal and `narrate_gap: 12` a violation. This case fails loudly if
# anyone widens that set for symmetry with the lenient validation side.
cp "$ROOT/workspace.config.yaml" "$T/counts.yaml"
perl -0pi -e 's/^(    narrate_gap: )0$/${1}12/m; s/^(    long_turn_seconds: )\d+$/${1}45/m' "$T/counts.yaml"
out="$(run "$T/counts.yaml" "$T/empty-local.yaml")"
ck "a COUNT is never learned as a boolean (narrate_gap)"   "ABSENT:narrate_gap"       "$out"
ck "…nor a seconds value"                                  "ABSENT:long_turn_seconds" "$out"

# 5. The live workspace itself must be clean, or the guard is being ignored rather than heeded.
out="$(run "$ROOT/workspace.config.yaml" "${AIWORKS_LOCAL:-$ROOT/workspace.config.local.yaml}")"
ck "this workspace's own config passes the guard" "every boolean flag in the live config carries a boolean" "$out"

# 6. Nothing was written. The whole suite runs --dry-run against copies; if the script ever grew a
# write that ignores DRY, this is the case that notices.
if git -C "$ROOT" diff --quiet -- .claude/workflows/dev-cycle.js .claude/workflows/prd.js 2>/dev/null; then
  ok "the suite wrote nothing into the workspace"
else
  bad "the suite wrote nothing into the workspace" "dev-cycle.js or prd.js changed"
fi

printf '\npass=%s fail=%s\n\n' "$pass" "$fail"
exit $(( fail > 0 ))
