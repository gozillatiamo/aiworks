#!/usr/bin/env bash
# The branch-base reconcile in .claude/workflows/src/dev-cycle.js decides, from a reading of one
# branch, whether to leave it alone, re-point it (which DELETES commits), or hand a person a
# rebase. dev-cycle-gate-selftest.sh §G54 asserts the workflow emits the right command; this
# asserts that the command is right — that git actually behaves the way §G54 assumes.
#
# It replays, in a throwaway repo, the topology of the ticket where all four assumptions were
# measured wrong at once: a branch cut from an old base tip, three commits carrying `Refs
# <ticket>` in the TRAILER, and an index wedged by a park that failed half-way. Roughly one
# second, no network, no fixtures. If an edit to the reconcile ever makes one of these red, the
# edit is wrong about git, not about the workflow.
set -u
T="${TMPDIR:-/tmp}/base-gate-repro.$$"; rm -rf "$T"; mkdir -p "$T"
G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c advice.detachedHead=false "$@"; }
pass=0; fail=0
ok()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 — want [$3] got [$2]"; fi }

G init -q --bare "$T/origin.git"
G clone -q "$T/origin.git" "$T/w" 2>/dev/null
cd "$T/w" || exit 1
echo base > f.txt; G add f.txt; G commit -qm "feat(FM-11): merged into develop"
G branch -M develop; G push -q origin develop
G switch -qc release/1.4 develop; G push -q origin release/1.4   # cut from the same tip
G switch -q develop
echo mirror > mirror.txt; G add mirror.txt; G commit -qm "chore: regenerate the generated mirror"
FOREIGN=$(G rev-parse HEAD); G push -q origin develop
# the ticket branch was cut from develop AFTER the foreign commit landed
G switch -qc feature/FM-12 develop
for n in 1 2 3; do echo "t$n" >> f.txt; G add f.txt
  G commit -qm "$(printf 'feat(app): ticket slice %s\n\nWhat this slice does.\n\nRefs FM-12\n' "$n")"; done
G push -q origin feature/FM-12
G fetch -q origin

echo "── the evidence the brief hands the probe"
ok "subject-only log sees no ticket commit"      "$(G log --oneline --no-decorate origin/release/1.4..feature/FM-12 | grep -c FM-12)" 0
ok "full-message search sees all three"          "$(G log --format=%H --grep=FM-12 origin/release/1.4..feature/FM-12 | grep -c .)" 3
ok "the drift really is 1 foreign + 3 ticket"    "$(G log --format=%H origin/release/1.4..feature/FM-12 | grep -c .)" 4

echo "── the rebase command the brief tells the probe to hand a person"
G branch -q keep feature/FM-12
G rebase -q --onto origin/release/1.4 "${FOREIGN}^" feature/FM-12 >/dev/null 2>&1
ok "with the caret, the foreign commit survives" "$(G log --format=%s origin/release/1.4..feature/FM-12 | grep -c 'regenerate the generated mirror')" 1
G switch -q feature/FM-12 2>/dev/null; G reset -q --hard keep
G rebase -q --onto origin/release/1.4 "${FOREIGN}" feature/FM-12 >/dev/null 2>&1
ok "without it, the foreign commit is dropped"   "$(G log --format=%s origin/release/1.4..feature/FM-12 | grep -c 'regenerate the generated mirror')" 0
ok "and all three ticket commits are replayed"   "$(G log --format=%H --grep=FM-12 origin/release/1.4..feature/FM-12 | grep -c .)" 3

echo "── what a 0-ticket-commit verdict authorises"
G switch -q feature/FM-12 2>/dev/null; G reset -q --hard keep
G branch -q backup/FM-12-pre-repair feature/FM-12
G checkout -q --detach origin/release/1.4; G branch -qf feature/FM-12 origin/release/1.4
ok "the re-point leaves nothing on the branch"   "$(G log --format=%H origin/release/1.4..feature/FM-12 | grep -c .)" 0
ok "the backup ref still holds the ticket work"  "$(G log --format=%H --grep=FM-12 origin/release/1.4..backup/FM-12-pre-repair | grep -c .)" 3

echo "── an index wedged by a failed park"
G switch -q feature/FM-12
BLOB=$(G rev-parse HEAD:f.txt)
printf '100644 %s 1\tf.txt\n100644 %s 2\tf.txt\n' "$BLOB" "$BLOB" | G update-index --index-info
ok "stages are unmerged"                         "$(G ls-files -u | grep -c .)" 2
ok "no operation is in progress"                 "$(G rev-parse --verify --quiet MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD | grep -c .)" 0
echo dirty >> f.txt
G stash push -u -m "FM-12 base-repair" >/dev/null 2>&1
ok "a park cannot succeed against it"            "$([ "$(G ls-files -u | grep -c .)" -gt 0 ] && echo wedged || echo parked)" wedged
G reset -q -- f.txt
ok "reset -- <path> clears the debris"           "$(G ls-files -u | grep -c .)" 0
G stash push -u -q -m "FM-12 base-repair"
ok "and the park then succeeds"                  "$(G stash list | grep -c 'FM-12 base-repair')" 1

cd /; rm -rf "$T"
echo "── $pass passed, $fail FAILED"
[ "$fail" -eq 0 ]
