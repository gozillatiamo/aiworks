#!/usr/bin/env bash
#
# aiworks-config selftest — the ADVISORY guards in aiworks-config.sh, which are the surface a
# person actually reads after editing a config.
#
#   ./scripts/aiworks-config-selftest.sh
#
# WHY THIS SUITE EXISTS: `stagehand.enabled: ture` sat in a personal config for weeks. Every
# `*_cfg_bool` reader in scripts/ resolves "not truthy" to false, so the typo and a deliberate
# opt-out were the same thing to every surface that reports state — the status line said "off",
# which was true, and no line anywhere said why. The reader now logs it, but a reader's log needs
# VERBOSE=1; the guard tested here is the one that speaks unprompted.
#
# RUNS ANYWHERE. Every fixture is written from scratch rather than copied from this workspace's
# `workspace.config.yaml`, for two reasons: a clone of this framework may carry no live config at
# all (only the two `*.example.yaml` templates), and a fixture derived from whatever an org happens
# to have configured is a fixture that changes meaning when someone edits their config. The one
# case that does read the live file skips itself when there isn't one.
#
# Writes nothing: every path the script would rewrite is pointed at a temp copy, under --dry-run.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$DIR/aiworks-config.sh"
pass=0 fail=0 skip=0
T="$(mktemp -d "${TMPDIR:-/tmp}/aiworks-config-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n        %s\n' "$1" "${2:-}"; }
skipc(){ skip=$((skip+1)); printf '  skip %s\n' "$1"; }
ck()   { # ck <label> <expect-substring|ABSENT:substring> <actual>
  case "$2" in
    ABSENT:*) case "$3" in *"${2#ABSENT:}"*) bad "$1" "did not expect '${2#ABSENT:}', got: $3" ;;
                                         *) ok "$1" ;; esac ;;
    *)        case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "want ⊃ $2 — got: $3" ;; esac ;;
  esac
}

# Writable stand-ins for the files the script REWRITES, or a passing suite would be quietly editing
# the workspace it is testing.
cp "$ROOT/.claude/workflows/dev-cycle.js" "$T/dc.js"
cp "$ROOT/.claude/workflows/prd.js"       "$T/prd.js"
: > "$T/no-local.yaml"

run() { # run <config> <config-local> → the guards' output, generated blocks dropped
  bash "$SCRIPT" --config "$1" --config-local "$2" \
       --target "$T/dc.js" --prd-target "$T/prd.js" --workspace "$T/ws.code-workspace" \
       --dry-run 2>&1 | sed -n '1,/^\/\/ ──/p'
}
full() { # full <config> <config-local> → everything, guards AND the generated blocks
  bash "$SCRIPT" --config "$1" --config-local "$2" \
       --target "$T/dc.js" --prd-target "$T/prd.js" --workspace "$T/ws.code-workspace" \
       --dry-run 2>&1
}

printf '\nBOOLEAN VALUE GUARD\n'

# 1. The shared config. `ture` is the real typo; `yeah` proves this is a set-membership test and
# not a hardcoded misspelling list.
cat > "$T/shared-typo.yaml" <<'YAML'
language: en
notify:
  enabled: ture
triage:
  enabled: yeah
products: []
YAML
out="$(run "$T/shared-typo.yaml" "$T/no-local.yaml")"
ck "a typo'd boolean in the shared config is reported"       "notify.enabled: ture" "$out"
ck "…and so is a second one, by set membership not spelling" "triage.enabled: yeah" "$out"
ck "the report says what the consequence is"                 "reads as OFF"         "$out"

# 2. The PERSONAL config — the file the real typo lived in, and the one a teammate hand-edits with
# no review. A guard that only checked the shared file would have missed the incident it exists for.
cat > "$T/only-notify.yaml" <<'YAML'
language: en
notify:
  enabled: true
products: []
YAML
cat > "$T/local-typo.yaml" <<'YAML'
language: th
stagehand:
  enabled: ture
voice:
  enabled: true
YAML
out="$(run "$T/only-notify.yaml" "$T/local-typo.yaml")"
ck "a typo'd boolean in the PERSONAL override is reported too" "stagehand.enabled: ture" "$out"
ck "the report names which FILE it is in"                      "local-typo.yaml"         "$out"
ck "a correct flag beside it is not dragged in"                "ABSENT:voice.enabled"    "$out"

# 3. No false positives. Each of these is a legal YAML boolean a teammate may reasonably write; a
# guard that flags them is noise, and noise gets ignored — which is how the original typo would
# survive a second time.
cat > "$T/spellings.yaml" <<'YAML'
language: en
notify:
  enabled: yes
triage:
  enabled: ON
  prod: off
vcs:
  auto_merge: 0
artifacts:
  enabled: FALSE
products: []
YAML
out="$(run "$T/spellings.yaml" "$T/no-local.yaml")"
ck "yes / ON / off / 0 / FALSE all pass as booleans" \
   "every boolean flag in the live config carries a boolean" "$out"

# 4. The learning set must stay STRICT. Which keys are boolean is learned from the templates by
# their literal true/false — admit 0 and 1 and every count becomes a "boolean", so `narrate_gap: 0`
# would be legal and `narrate_gap: 12` a violation. This fails loudly if anyone widens that set for
# symmetry with the lenient validation side.
cat > "$T/counts.yaml" <<'YAML'
language: en
voice:
  autoplay:
    narrate_gap: 12
    narrate_max_per_turn: 3
    long_turn_seconds: 45
stagehand:
  max_tabs: 1
  debounce_seconds: 0
products: []
YAML
out="$(run "$T/counts.yaml" "$T/no-local.yaml")"
ck "a COUNT is never learned as a boolean (narrate_gap)" "ABSENT:narrate_gap"          "$out"
ck "…nor a per-turn cap"                                 "ABSENT:narrate_max_per_turn" "$out"
ck "…nor a seconds value"                                "ABSENT:long_turn_seconds"    "$out"
ck "…and a 0/1 count is not read as false/true"          "ABSENT:debounce_seconds"     "$out"

# 5. The live workspace, when there is one. A framework clone carries only the templates, so this is
# the one case that can legitimately have nothing to check.
if [[ -f "$ROOT/workspace.config.yaml" ]]; then
  out="$(run "$ROOT/workspace.config.yaml" "${AIWORKS_LOCAL:-$ROOT/workspace.config.local.yaml}")"
  ck "this workspace's own config passes the guard" \
     "every boolean flag in the live config carries a boolean" "$out"
else
  skipc "no live workspace.config.yaml here (a framework clone) — the fixtures cover the logic"
fi

printf '\nMIRROR STAYS SHARED-ONLY\n'

# 6. planning.auto_approve is the ONE control-flow key a personal config may override (ADR 0003) —
# but only at RUNTIME, where dev-cycle.js re-resolves it local-first. The COMMITTED mirror must keep
# carrying the SHARED value, or a git-ignored personal preference rides into a tracked file the whole
# team runs, which is exactly what ADR 0001 exists to prevent. Every other case here reads the
# guards; this one reads the generated const, and it is the only test of that boundary.
cat > "$T/shared-gate-on.yaml" <<'YAML'
language: en
planning:
  auto_approve: false
  to_html: false
products: []
YAML
cat > "$T/local-gate-off.yaml" <<'YAML'
planning:
  auto_approve: true
YAML
out="$(full "$T/shared-gate-on.yaml" "$T/local-gate-off.yaml")"
ck "a local auto_approve:true never reaches the committed mirror" \
   "const AUTO_APPROVE_PLAN = false" "$out"
ck "…and the run says why the local file was not used for it" \
   "regenerated from workspace.config.yaml (shared) only" "$out"

printf '\nBASE PROJECTION (docs/adr/0025)\n'

# The regression this section exists for: a `test-suite` repo used to be projected with
# base.feature = fix_base, so a ticket's suite branch was cut off the FIX trunk while every app
# repo branched off the feature one. Measured, that trunk was 99 and 157 commits behind, and one
# was a 16-file scaffold — a whole round went into discovering it, twice.
cat > "$T/bases.yaml" <<'YAML'
language: en
branch_model:
  feature_base: develop
  fix_base: main
products:
  - id: p1
    repos:
      - url: git@github.com:acme/svc.git
        kind: backend
      - url: git@github.com:acme/e2e-suite.git
        kind: test-suite
      - url: git@github.com:acme/odd-svc.git
        kind: backend
        feature_base: release/7.10
        fix_base: staging
YAML
out="$(full "$T/bases.yaml" "$T/no-local.yaml")"

# Read back the projected base for one repo out of the generated REPOS block — same shape the
# doctor check parses, so a drift in the generated layout fails here too.
proj() { # proj <repo> → its base.feature
  printf '%s' "$out" | awk -v want="  '$1':" '
    index($0, want)==1 { inr=1; next }
    inr && /base:[ \t]*\{/ { if (split($0, q, "\047") >= 2) printf "%s", q[2]; exit }
    inr && index($0, "\047")==3 { exit }'
}
projfix() { # projfix <repo> → its base.fix
  printf '%s' "$out" | awk -v want="  '$1':" '
    index($0, want)==1 { inr=1; next }
    inr && /base:[ \t]*\{/ { if (split($0, q, "\047") >= 4) printf "%s", q[4]; exit }
    inr && index($0, "\047")==3 { exit }'
}

ck "a code repo takes branch_model.feature_base"                 "develop"      "$(proj svc)"
ck "a TEST-SUITE repo takes it too — not fix_base"               "develop"      "$(proj e2e-suite)"
ck "…and its fix base is still fix_base"                         "main"         "$(projfix e2e-suite)"
ck "a repo's own feature_base overrides branch_model"            "release/7.10" "$(proj odd-svc)"
ck "…and so does its own fix_base"                              "staging"      "$(projfix odd-svc)"
ck "an overriding repo does not leak its base to its neighbours" "develop"      "$(proj svc)"

printf '\nREVIEW LOOP BOUNDS (docs/adr/0027)\n'

# max_rounds is the ONLY terminal bound on the review loop now that every other condition is a
# must-fix, so a 0 or a typo must not be able to disarm it.
cat > "$T/bounds.yaml" <<'YAML'
language: en
review:
  level: strict
  max_rounds: 9
  max_regression_fixes: 5
  max_stall_reattempts: 4
  max_escalation_attempts: 6
test_suite:
  max_fix_rounds: 2
  max_suite_repair_attempts: 7
products: []
YAML
out="$(full "$T/bounds.yaml" "$T/no-local.yaml")"
ck "review.max_rounds projects"                "maxRounds: 9"               "$out"
ck "max_regression_fixes projects"             "maxRegressionFixes: 5"      "$out"
ck "max_stall_reattempts projects"             "maxStallReattempts: 4"      "$out"
ck "max_escalation_attempts projects"          "maxEscalationAttempts: 6"   "$out"
ck "max_suite_repair_attempts projects"        "maxSuiteRepairAttempts: 7"  "$out"
ck "an explicit test_suite.max_fix_rounds wins" "maxFixRounds: 2"           "$out"

cat > "$T/bounds-bad.yaml" <<'YAML'
language: en
review:
  max_rounds: 0
  max_regression_fixes: lots
products: []
YAML
out="$(full "$T/bounds-bad.yaml" "$T/no-local.yaml")"
# 0 rounds would mean the loop never runs and every repo returns unresolved without doing anything.
ck "max_rounds: 0 is clamped, not honoured"    "maxRounds: 14"              "$out"
ck "a non-numeric budget falls back"           "maxRegressionFixes: 3"      "$out"

cat > "$T/bounds-absent.yaml" <<'YAML'
language: en
products: []
YAML
out="$(full "$T/bounds-absent.yaml" "$T/no-local.yaml")"
ck "an absent review block still projects defaults" "maxRounds: 14"         "$out"
ck "…including the suite-repair budget"             "maxSuiteRepairAttempts: 3" "$out"

# 7. Nothing was written. If the script ever grows a write that ignores DRY, this notices.
# `git diff` also exits non-zero when there is no repo AT ALL — an extracted tarball, which is how
# a person first meets this framework. That is a check that could not run, not a failed assertion,
# and reporting it as a failure made the suite red out of the box on a fresh clone.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  skipc "not a git checkout (an extracted tarball) — no baseline to diff the workspace against"
elif git -C "$ROOT" diff --quiet -- .claude/workflows/dev-cycle.js .claude/workflows/prd.js 2>/dev/null; then
  ok "the suite wrote nothing into the workspace"
else
  bad "the suite wrote nothing into the workspace" "dev-cycle.js or prd.js changed"
fi

printf '\npass=%s fail=%s' "$pass" "$fail"
[[ "$skip" -gt 0 ]] && printf ' skip=%s' "$skip"
printf '\n\n'
exit $(( fail > 0 ))
