#!/usr/bin/env bash
# Offline regression for ci.sh on both providers (stubbed glab/gh — no network, no credentials).
# Proves three things a live call cannot show on demand: every call is scoped to VCS_REPO from a
# cwd whose origin is a DIFFERENT project, the filters reach the wire, and a refused call exits
# non-zero instead of printing an empty list.
#
# Run:  scripts/vcs/ci-selftest.sh      Exit: 0 = all green
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
pass=0; fail=0
has() { case "$3" in *"$2"*) pass=$((pass+1)); echo "  ✓ $1" ;; *) fail=$((fail+1)); printf '  ✗ %s\n     want contains: %s\n     got: %s\n' "$1" "$2" "$3" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/cwd"
git -C "$TMP/cwd" init -q; git -C "$TMP/cwd" remote add origin "git@example.com:group/other-repo.git"

cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
[[ -n "${FAIL:-}" ]] && exit 1
case "$*" in
  *"/pipelines?"*) printf '[{"id":11,"status":"success","source":"schedule","ref":"main","created_at":"2026-01-02T20:00:00Z","web_url":"https://example.com/p/11"}]\n' ;;
  *"/pipelines/11/jobs"*) printf '[{"id":21,"status":"failed","stage":"test","name":"e2e","started_at":"2026-01-02T20:01:00Z","web_url":"https://example.com/j/21"}]\n' ;;
  *"/jobs/21/trace"*) printf 'line one\nline two\n' ;;
esac
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
[[ -n "${FAIL:-}" ]] && exit 1
case "$*" in
  *"/actions/runs?"*) printf '{"workflow_runs":[{"id":11,"status":"completed","conclusion":"success","event":"schedule","head_branch":"main","created_at":"2026-01-02T20:00:00Z","html_url":"https://example.com/r/11"}]}\n' ;;
  *"/actions/runs/11/jobs"*) printf '{"jobs":[{"id":21,"status":"completed","conclusion":"failure","name":"e2e","started_at":"2026-01-02T20:01:00Z","html_url":"https://example.com/j/21"}]}\n' ;;
  *"/actions/jobs/21/logs"*) printf 'line one\nline two\n' ;;
esac
STUB
chmod +x "$BIN/glab" "$BIN/gh"

# ci PROVIDER ARGS… -> stdout of ci.sh, then "rc=<n>", then the CLI invocation log.
ci() {
  local provider="$1"; shift
  export CALLS="$TMP/calls"; : > "$CALLS"
  ( cd "$TMP/cwd" && PATH="$BIN:$PATH" VCS_PROVIDER="$provider" VCS_REPO=group/sub/target-repo \
      CLAUDE_PROJECT_DIR="$TMP/no-workspace" "$DIR/ci.sh" "$@" 2>/dev/null; echo "rc=$?" )
  cat "$CALLS"
}

for p in gitlab github; do
  echo "$p"
  if [[ "$p" == gitlab ]]; then scope='projects/group%2Fsub%2Ftarget-repo/'; src='source=schedule'; since='updated_after=2026-01-01T00:00:00Z'; bad=failed
  else scope='repos/group/sub/target-repo/actions/'; src='event=schedule'; since='created=%3E%3D2026-01-01'; bad=failure; fi
  out="$(ci "$p" runs --source schedule --ref main --since 2026-01-01 --limit 5)"
  has "runs: scoped to VCS_REPO" "$scope" "$out"
  has "runs: --source on the wire" "$src" "$out"
  has "runs: --since on the wire" "$since" "$out"
  has "runs: --limit on the wire" "per_page=5" "$out"
  has "runs: TSV row" "11	success	schedule	main	2026-01-02T20:00:00Z" "$out"
  out="$(ci "$p" jobs 11)"
  has "jobs: scoped to VCS_REPO" "$scope" "$out"
  has "jobs: TSV row" "21	$bad" "$out"
  out="$(ci "$p" log 21)"
  has "log: scoped to VCS_REPO" "$scope" "$out"
  has "log: verbatim" "line two" "$out"
  has "runs: a refused call is not an empty list" "rc=1" "$(FAIL=1 ci "$p" runs)"
  has "log: non-numeric id refused" "rc=1" "$(ci "$p" log abc)"
done

echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
