#!/usr/bin/env bash
#
# aiworks-gc-selftest.sh — prove `aiworks gc` cannot break a running build.
#
# The GC's whole contract is that worktrees stay PARALLEL: it never introduces shared build
# state, and it never deletes from a worktree that is in use. That contract is only worth
# something if the liveness checks actually fire, so this exercises them against real
# processes and real open file descriptors rather than trusting the code by inspection.
#
# Hermetic: builds a fake ~/.superset tree, stubs the `superset` CLI on PATH, and never
# touches the real one.
#
# Usage: aiworks-gc-selftest.sh [-v]
#
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GC="$DIR/aiworks-gc.sh"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_err=; c_off=; }
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$c_err" "$c_off" "$1"; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1  (want '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; kill %1 2>/dev/null' EXIT

# ── source the predicates under test ─────────────────────────────────────────────
# shellcheck disable=SC1090
source <(sed -n '/^busy_cargo_lock/,/^}/p; /^busy_process_cwd/,/^}/p; /^busy_recent_mtime/,/^}/p' "$GC")

echo "── liveness predicates"

mkdir -p "$TMP/idle" "$TMP/cwd" "$TMP/lock/target/debug"

# 1. a process cwd'd inside the tree
( cd "$TMP/cwd" && sleep 60 ) &
sleep 1
busy_process_cwd "$TMP/cwd" && r=busy || r=idle
check "process cwd inside is BUSY" "$r" "busy"
busy_process_cwd "$TMP/idle" && r=busy || r=idle
check "unrelated dir is IDLE (no false positive)" "$r" "idle"
# a prefix collision must NOT read as busy: /cwd-other is not inside /cwd
mkdir -p "$TMP/cwd-other"
busy_process_cwd "$TMP/cwd-other" && r=busy || r=idle
check "sibling sharing a name prefix is IDLE" "$r" "idle"

# 2. a held cargo lock — what a live `cargo build` leaves open
touch "$TMP/lock/target/debug/.cargo-lock"
exec 9<>"$TMP/lock/target/debug/.cargo-lock"
busy_cargo_lock "$TMP/lock" && r=busy || r=idle
check "held .cargo-lock is BUSY" "$r" "busy"
exec 9>&-
busy_cargo_lock "$TMP/lock" && r=busy || r=idle
check "released .cargo-lock is IDLE" "$r" "idle"

# 3. mtime freshness
busy_recent_mtime "$TMP/idle" 3 && r=busy || r=idle
check "just-created tree is BUSY at 3d" "$r" "busy"
touch -t 202001010000 "$TMP/idle"
busy_recent_mtime "$TMP/idle" 3 && r=busy || r=idle
check "back-dated tree is IDLE at 3d" "$r" "idle"

# ── the I3 invariant, end to end: --force must not reach past liveness ───────────
echo "── --force does not override liveness"

WT="$TMP/home/.superset/worktrees/proj-1"
mkdir -p "$WT/live" "$WT/orphan-busy" "$TMP/bin"
# Stub the CLI: only `live` is a known workspace, so `orphan-busy` classifies as an orphan.
cat > "$TMP/bin/superset" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "ws" && "\$2" == "list" ]] && printf '[{"worktreePath":"%s","id":"w1"}]\n' "$WT/live"
exit 0
EOF
chmod +x "$TMP/bin/superset"

# Make the orphan BUSY by parking a process in it, then ask for the most aggressive run
# the CLI allows. A correct GC still refuses.
( cd "$WT/orphan-busy" && sleep 60 ) &
sleep 1
out="$(PATH="$TMP/bin:$PATH" SUPERSET_HOME="$TMP/home/.superset" bash "$GC" --orphans --force 2>&1)"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'

grep -q 'skip.*orphan-busy.*in use' <<<"$out" && r=skipped || r=removed
check "busy orphan is SKIPPED even with --force" "$r" "skipped"
[[ -d "$WT/orphan-busy" ]] && r=present || r=gone
check "busy orphan still on disk after --force" "$r" "present"
[[ -d "$WT/live" ]] && r=present || r=gone
check "live workspace never touched" "$r" "present"

# ── an empty live list must abort, not classify everything as garbage ────────────
echo "── refuses to guess"
cat > "$TMP/bin/superset" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ws" && "$2" == "list" ]] && printf '[]\n'
exit 0
EOF
chmod +x "$TMP/bin/superset"
PATH="$TMP/bin:$PATH" SUPERSET_HOME="$TMP/home/.superset" bash "$GC" --orphans >/dev/null 2>&1
check "empty workspace list exits non-zero" "$?" "1"
[[ -d "$WT/live" ]] && r=present || r=gone
check "nothing deleted on an empty list" "$r" "present"

# ── the scheduled job's plist must be valid and carry the safe defaults ─────────
echo "── weekly schedule"

# shellcheck disable=SC1090
source <(sed -n '/^SCHED_LABEL=/,/^SCHED_IDLE_DEFAULT=/p; /^write_plist/,/^}/p; /^cron_line/,/^}/p' "$GC")
SCHED_LOG="$TMP/gc.log"
write_plist "$TMP/test.plist" 7

if [[ "$(uname -s)" == "Darwin" ]]; then
  plutil -lint "$TMP/test.plist" >/dev/null 2>&1 && r=valid || r=malformed
  check "generated plist parses" "$r" "valid"
fi
grep -q '<string>--orphans</string>' "$TMP/test.plist" && r=yes || r=no
check "scheduled job reaps orphans" "$r" "yes"
# --dispatch must NOT be in there: slack-dispatch sweeps its own, and doing it twice would
# race two GCs over the same worktrees.
grep -q -- '--dispatch' "$TMP/test.plist" && r=present || r=absent
check "scheduled job does NOT duplicate the dispatch sweep" "$r" "absent"
# An unattended run must never inherit the interactive 3-day default.
grep -A1 -- '--idle-days' "$TMP/test.plist" | grep -q '<string>7</string>' && r=7 || r=other
check "unattended idle threshold is the conservative 7d" "$r" "7"
grep -q 'homebrew' "$TMP/test.plist" && r=yes || r=no
check "plist sets a PATH launchd can find the CLIs on" "$r" "yes"
cron_line 7 | grep -q -- '--orphans --artifacts --idle-days 7' && r=ok || r=bad
check "non-Darwin cron fallback line is well-formed" "$r" "ok"

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
