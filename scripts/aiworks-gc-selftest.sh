#!/usr/bin/env bash
#
# aiworks-gc-selftest.sh — prove `aiworks gc` cannot break a running build.
#
# The GC's whole contract is that worktrees stay PARALLEL: it never introduces shared build
# state, and it never deletes from a worktree that is in use. That contract is only worth
# something if the liveness checks actually fire, so this exercises them against real
# processes and real open file descriptors rather than trusting the code by inspection.
#
# Hermetic: builds a fake ~/.paradev tree, stubs the `paradev` CLI on PATH, and never
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

WT="$TMP/home/.paradev/worktrees/proj-1"
mkdir -p "$WT/live" "$WT/orphan-busy" "$TMP/bin"
# Stub the CLI: only `live` is a known workspace, so `orphan-busy` classifies as an orphan.
cat > "$TMP/bin/paradev" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "ws" && "\$2" == "list" && " \$* " == *" --local "* ]] && printf '[{"worktreePath":"%s","id":"w1"}]\n' "$WT/live"
exit 0
EOF
chmod +x "$TMP/bin/paradev"

# Make the orphan BUSY by parking a process in it, then ask for the most aggressive run
# the CLI allows. A correct GC still refuses.
( cd "$WT/orphan-busy" && sleep 60 ) &
sleep 1
out="$(PATH="$TMP/bin:$PATH" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --orphans --force 2>&1)"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'

grep -q 'skip.*orphan-busy.*in use' <<<"$out" && r=skipped || r=removed
check "busy orphan is SKIPPED even with --force" "$r" "skipped"
[[ -d "$WT/orphan-busy" ]] && r=present || r=gone
check "busy orphan still on disk after --force" "$r" "present"
[[ -d "$WT/live" ]] && r=present || r=gone
check "live workspace never touched" "$r" "present"

# ── --path: artifacts outside Paradev, judged per project ──────────────────────
echo "── --path sweeps non-worktree checkouts"

P="$TMP/proj"
mkdir -p "$P/idle/target" "$P/busy/target" "$P/notcargo/target" "$P/web/node_modules"
touch "$P/idle/Cargo.toml" "$P/busy/Cargo.toml" "$P/idle/target/x" "$P/busy/target/x" "$P/notcargo/target/x" "$P/web/node_modules/x"
# Back-date everything so only the cwd check can keep `busy`.
find "$P" -exec touch -t 202001010000 {} +
( cd "$P/busy" && sleep 60 ) &
sleep 1
out="$(PATH="$TMP/bin:$PATH" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --path "$P" 2>&1)"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'
[[ -d "$P/idle/target" ]] && r=present || r=gone
check "idle project's target/ is cleared" "$r" "gone"
[[ -d "$P/web/node_modules" ]] && r=present || r=gone
check "idle project's node_modules is cleared" "$r" "gone"
[[ -d "$P/busy/target" ]] && r=present || r=gone
check "target/ under a process cwd is KEPT" "$r" "present"
[[ -d "$P/notcargo/target" ]] && r=present || r=gone
check "a target/ with no Cargo.toml beside it is KEPT" "$r" "present"

# A root like ~/projects holds org/workspace/repo/target — 4 levels down, past the worktree depth.
D="$TMP/deep"; mkdir -p "$D/org/ws/repo/target" "$D/empty"
touch "$D/org/ws/repo/Cargo.toml" "$D/org/ws/repo/target/x"
find "$D" -exec touch -t 202001010000 {} +
out="$(PATH="$TMP/bin:$PATH" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --path "$D" 2>&1)"
[[ -d "$D/org/ws/repo/target" ]] && r=present || r=gone
check "target/ four levels below the root is found and cleared" "$r" "gone"
out="$(PATH="$TMP/bin:$PATH" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --path "$D/empty" 2>&1)"
grep -q "nothing to clear under $D/empty" <<<"$out" && r=said || r=silent
check "a root that yields nothing says so instead of staying silent" "$r" "said"

# ── --caches: host tool caches ───────────────────────────────────────────────────
echo "── --caches"

CALLS="$TMP/calls"; mkdir -p "$TMP/cache/uv" "$TMP/home/.cache/puppeteer"
echo x > "$TMP/cache/uv/blob"; echo x > "$TMP/home/.cache/puppeteer/blob"
for t in uv pnpm npm; do
  cat > "$TMP/bin/$t" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "cache dir")        echo "$TMP/cache/uv"; exit 0 ;;
  "store path")       echo "$TMP/cache/pnpm"; exit 0 ;;
  "config get cache") echo "$TMP/cache/npm"; exit 0 ;;
esac
echo "$t \$* UV_LOCK_TIMEOUT=\${UV_LOCK_TIMEOUT:-}" >> "$CALLS"
[[ "\${FAIL:-}" == "$t" ]] && exit 1
exit 0
EOF
  chmod +x "$TMP/bin/$t"
done
run_caches() { PATH="$TMP/bin:$PATH" HOME="$TMP/home" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --caches "$@" 2>&1; }

: > "$CALLS"
run_caches -n >/dev/null
[[ -s "$CALLS" ]] && r=ran || r=idle
check "--caches -n runs no clearing command" "$r" "idle"
[[ -d "$TMP/home/.cache/puppeteer" ]] && r=present || r=gone
check "--caches -n leaves puppeteer alone" "$r" "present"

out="$(FAIL=uv run_caches)"; rc=$?
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'
check "a cache that is in use does not fail the run" "$rc" "0"
grep -q 'skip  uv cache' <<<"$out" && r=skipped || r=cleared
check "a failing uv is SKIPPED with a warning" "$r" "skipped"
grep -q '^uv cache clean UV_LOCK_TIMEOUT=10$' "$CALLS" && r=yes || r=no
check "uv runs with a bounded lock timeout" "$r" "yes"
grep -q '^pnpm store prune' "$CALLS" && r=yes || r=no
check "pnpm store is pruned" "$r" "yes"
grep -q '^npm cache clean --force' "$CALLS" && r=yes || r=no
check "npm cache is cleaned" "$r" "yes"
[[ -d "$TMP/home/.cache/puppeteer" ]] && r=present || r=gone
check "puppeteer browsers are removed" "$r" "gone"

# ── --docker: the safe subset only ───────────────────────────────────────────────
echo "── --docker"

cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == info ]] && { [[ -n "\${DOCKER_DOWN:-}" ]] && exit 1; exit 0; }
[[ "\$1 \$2" == "system df" ]] && { echo "TYPE TOTAL"; exit 0; }
echo "docker \$*" >> "$CALLS"
echo "Total:  0B"
exit 0
EOF
chmod +x "$TMP/bin/docker"
run_docker() { PATH="$TMP/bin:$PATH" HOME="$TMP/home" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --docker "$@" 2>&1; }

: > "$CALLS"
run_docker -n >/dev/null
[[ -s "$CALLS" ]] && r=ran || r=idle
check "--docker -n prunes nothing" "$r" "idle"

: > "$CALLS"
out="$(run_docker)"
[[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$out" | sed 's/^/      /'
grep -q '^docker builder prune -f$' "$CALLS" && r=yes || r=no
check "build cache is pruned" "$r" "yes"
grep -q '^docker image prune -f$' "$CALLS" && r=yes || r=no
check "dangling images are pruned" "$r" "yes"
# Safe subset: no volume prune, no -a (that would take tagged images with it).
grep -q -E 'volume|system prune| -a' "$CALLS" && r=reached || r=safe
check "volumes and tagged images are never touched" "$r" "safe"
grep -q 'docker volume prune' <<<"$out" && r=yes || r=no
check "the further-cleaning hints are printed" "$r" "yes"

: > "$CALLS"
out="$(DOCKER_DOWN=1 run_docker)"; rc=$?
check "a stopped daemon does not fail the run" "$rc" "0"
grep -q 'daemon is not running' <<<"$out" && r=yes || r=no
check "a stopped daemon is reported" "$r" "yes"
[[ -s "$CALLS" ]] && r=ran || r=idle
check "a stopped daemon runs no prune" "$r" "idle"

# ── an empty live list must abort, not classify everything as garbage ────────────
echo "── refuses to guess"
cat > "$TMP/bin/paradev" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ws" && "$2" == "list" ]] && printf '[]\n'
exit 0
EOF
chmod +x "$TMP/bin/paradev"
PATH="$TMP/bin:$PATH" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --orphans >/dev/null 2>&1
check "empty workspace list exits non-zero" "$?" "1"
[[ -d "$WT/live" ]] && r=present || r=gone
check "nothing deleted on an empty list" "$r" "present"
# A stale `superset` binary alone must not stand in for the paradev CLI.
mkdir -p "$TMP/only-superset"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/only-superset/superset"
chmod +x "$TMP/only-superset/superset"
out="$(PATH="$TMP/only-superset:/usr/bin:/bin" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --orphans 2>&1)"
check "a superset-only PATH makes gc die" "$?" "1"
grep -q "'paradev' CLI is not on PATH" <<<"$out" && r=yes || r=no
check "the die message names the paradev CLI" "$r" "yes"

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
grep -q '\.paradev/bin' "$TMP/test.plist" && r=yes || r=no
check "plist PATH reaches ~/.paradev/bin" "$r" "yes"
cron_line 7 | grep -q -- '--orphans --artifacts --idle-days 7' && r=ok || r=bad
check "non-Darwin cron fallback line is well-formed" "$r" "ok"

# ── the workspace CLI must be told --local: bare, it answers for cloud workspaces ──
echo "── --dispatch archives the workspace on this machine"
D="$TMP/home/.paradev/worktrees/proj-1/slack/req-1"
mkdir -p "$D"; touch -t 202001010000 "$D"
cat > "$TMP/bin/paradev" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/paradev.args"
[[ "\$1" == "ws" && "\$2" == "list" && " \$* " == *" --local "* ]] && printf '[{"worktreePath":"%s","id":"w9"}]\n' "$D"
exit 0
EOF
chmod +x "$TMP/bin/paradev"
PATH="$TMP/bin:$PATH" SUPERSET_HOME_DIR="$TMP/home/.paradev" bash "$GC" --dispatch --ttl-days 1 --force >/dev/null 2>&1
grep -q '^ws archive --local w9$' "$TMP/paradev.args" 2>/dev/null && r=local || r=missing
check "a live dispatch worktree past TTL is archived with --local" "$r" "local"

echo
if [[ "$FAIL" -gt 0 ]]; then printf '%s%d passed, %d FAILED%s\n' "$c_err" "$PASS" "$FAIL" "$c_off"; exit 1; fi
printf '%s%d passed%s\n' "$c_ok" "$PASS" "$c_off"
