#!/usr/bin/env bash
#
# Regression suite for the chattiness CLAMP: anything above `terse` belongs to the ROOT checkout,
# and a linked worktree speaks `terse` whatever the config resolves to (voice_chattiness, lib.sh).
#
# Run:  scripts/voice/chattiness-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# EVERYTHING RUNS AGAINST A REAL `git worktree` in a temp dir, never a faked VOICE_MAIN_CLONE. The
# whole point of the clamp is that the gate is mechanical — `git rev-parse --git-common-dir` — so a
# test that set the variable by hand would prove only that an `if` works, and would keep passing
# after the detection itself broke.
#
# The tree mirrors the real layout that causes the problem, which is why the "inherits" case below
# is the important one:
#
#   <main>/workspace.config.yaml          chattiness: terse   (shared, committed)
#   <main>/workspace.config.local.yaml    chattiness: max     (personal, GIT-IGNORED)
#   <worktree>/workspace.config.yaml      chattiness: terse
#   <worktree>/  …no local file, because a git-ignored file does not travel into a worktree —
#                so layer 2 of the config chain reads the MAIN clone's, and the worktree inherits
#                `max` rather than falling back to the shared `terse`.
#
# Costs nothing: no synthesis, no API call, no provider. It only ever resolves config.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d -t voice-chattiness-selftest)"
trap 'rm -rf "$T"' EXIT

command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }

MAIN="$T/main"; WT="$T/wt"
mkdir -p "$MAIN"
# `worktree add` needs a repo with one commit; the CONTENT is irrelevant — only where the
# worktree's --git-common-dir points. So the scripts and the configs go in afterwards as UNTRACKED
# files, which also keeps a real scripts/voice/.env out of a throwaway git object.
git -C "$MAIN" init -q >/dev/null 2>&1
printf 'x\n' > "$MAIN/.keep"
git -C "$MAIN" add .keep >/dev/null 2>&1
git -C "$MAIN" -c user.email=selftest@local -c user.name=selftest -c commit.gpgsign=false \
  commit -qm init >/dev/null 2>&1
git -C "$MAIN" worktree add -q -b wt-probe "$WT" >/dev/null 2>&1
[[ -e "$WT/.git" ]] || { echo "could not create a linked worktree — the clamp cannot be proved"; exit 1; }

for d in "$MAIN" "$WT"; do
  cp -R "$SRC/scripts" "$d/scripts"
  rm -f "$d/scripts/voice/.env"
  cat > "$d/workspace.config.yaml" <<'YAML'
language: th
voice:
  enabled: true
  autoplay:
    enabled: true
    chattiness: terse
YAML
done

# The personal file exists ONLY in the main clone. That is not a shortcut for the test — it is the
# situation itself: workspace.config.local.yaml is git-ignored, so it cannot be in the worktree.
setlocal() { # setlocal <level>
  cat > "$MAIN/workspace.config.local.yaml" <<YAML
voice:
  autoplay:
    chattiness: $1
YAML
}

# Each probe is its own bash, so nothing carries over between cases.
lvl()  { bash -c '. "$1/scripts/voice/lib.sh" 2>/dev/null; voice_chattiness' _ "$1" 2>/dev/null; }
rawv() { bash -c '. "$1/scripts/voice/lib.sh" 2>/dev/null; voice_cfg voice.autoplay.chattiness terse' _ "$1" 2>/dev/null; }
gaps() { bash -c '. "$1/scripts/voice/lib.sh" 2>/dev/null; voice_heartbeat_gaps' _ "$1" 2>/dev/null; }

pass=0; fail=0
ck() { # ck <label> <expected exactly> <actual>
  if [[ "$3" == "$2" ]]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1"; echo "        want $2"; echo "        got  $3"; fail=$((fail+1)); fi
}

echo "== the root checkout keeps whatever it set =="
setlocal max
ck "root reads max" max "$(lvl "$MAIN")"

echo "== …and the worktree INHERITS it, which is why the clamp has to exist =="
# If this case ever goes red the clamp has become untestable rather than unnecessary: it would mean
# the worktree stopped seeing the main clone's personal config, and the next case would pass for
# the wrong reason (an absent value, not a clamped one).
ck "the raw config value in the worktree is the root's max" max "$(rawv "$WT")"

echo "== the clamp: a linked worktree speaks terse =="
for want in max chatty balanced; do
  setlocal "$want"
  ck "root $want ⇒ worktree terse" terse "$(lvl "$WT")"
done
setlocal terse
ck "root terse ⇒ worktree terse (nothing to clamp)" terse "$(lvl "$WT")"

echo "== the heartbeat cadence follows, because it is keyed off the level =="
setlocal max
ck "root gets max's 10-beat schedule" "45 60 90 120 180 180 240 240 300 300" "$(gaps "$MAIN")"
ck "the worktree gets the ordinary 6-beat one" "90 180 300 300 300 300" "$(gaps "$WT")"

echo "== VOICE_CHATTINESS is NOT clamped =="
# One command a human typed (an audition, a test) is per-invocation intent — not a machine
# preference leaking in through the config chain, which is the thing being clamped.
setlocal terse
ck "an explicit override wins inside the worktree" max "$(VOICE_CHATTINESS=max lvl "$WT")"
ck "…and an invalid one still falls back to terse" terse "$(VOICE_CHATTINESS=loud lvl "$WT")"

echo; echo "pass=$pass fail=$fail"
exit $(( fail > 0 ))
