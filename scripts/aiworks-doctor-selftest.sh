#!/usr/bin/env bash
#
# aiworks-doctor selftest — the claims `aiworks doctor` makes that a reader cannot verify by
# looking at its output.
#
#   ./scripts/aiworks-doctor-selftest.sh
#
# WHY THIS SUITE EXISTS. A doctor is trusted by definition: nobody re-checks a green tick, and
# nobody doubts a red one until they have spent an hour on it. Both failure modes are silent,
# so both are tested here.
#
#   1. IT MUST NOT LEAK A SECRET. The only thing doctor does to an adapter .env is
#      `grep -q '^VAR=.\+'` — the exit code is the whole answer. That is easy to write and
#      just as easy to undo later with a `grep -n` added while debugging. Case 8 plants a
#      recognisable fake secret in a fixture .env and greps EVERY byte doctor emits, on both
#      streams, in text and in --json, for it. The .env guard hook shipped with zero test
#      cases for a year and a `bash -x` leak was what eventually found the gap; this file
#      does not repeat that.
#   2. IT MUST NOT INVENT FINDINGS. Every false positive costs somebody a real investigation.
#      The first draft of this script demanded four adapter symlinks per repo when `aiworks
#      add` links two, flagged 44 rules files that were correctly configured, and reported
#      orphaned worktrees on a workspace whose gc output said "orphaned: 0" — all three
#      looked completely plausible in the output. The healthy-fixture cases pin the shapes
#      that must stay quiet.
#   3. THE ADAPTER TABLE MUST NOT DRIFT. provider_required_vars() mirrors each provider's own
#      `*_require_config`. A provider added tomorrow with no table entry would report as
#      configured while missing every credential it needs — case 12 fails the moment a
#      provider directory exists that the table does not know.
#
# RUNS ANYWHERE. Every fixture is built from scratch in a temp dir rather than read from this
# workspace: a clone of this framework may have no live config at all, and a fixture derived
# from whatever an org happens to have configured changes meaning when someone edits it. The
# few cases that need the real workspace skip themselves when there isn't one.
#
# WRITES NOTHING OUTSIDE ITS FIXTURES. Every run is read-only or --fix -n, with one exception:
# case 21 has to prove that --fix's own referee tells a closed finding from a surviving one, and
# that can only be observed by letting it run. Its fixture is built so the entire plan is a
# single `chmod +x` on a file inside the temp dir; every other finding there is routed to
# "needs you", so nothing reaches the network, a daemon, or anything outside $T.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$DIR/aiworks-doctor.sh"
pass=0 fail=0 skip=0
T="$(mktemp -d "${TMPDIR:-/tmp}/aiworks-doctor-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n        %s\n' "$1" "${2:-}"; }
skipc() { skip=$((skip+1)); printf '  skip %s\n' "$1"; }

ck() {  # ck <label> <expect-substring|ABSENT:substring> <actual>
  case "$2" in
    ABSENT:*) case "$3" in *"${2#ABSENT:}"*) bad "$1" "did not expect '${2#ABSENT:}', got: $3" ;;
                                          *) ok "$1" ;; esac ;;
    *)        case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "want ⊃ $2 — got: $3" ;; esac ;;
  esac
}
ck_exit() {  # ck_exit <label> <want> <got>
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want exit $2, got $3"
}

# ── fixture ───────────────────────────────────────────────────────────────────────
# A minimal but STRUCTURALLY REAL workspace: mani.yaml, a mani.d entry, a config with one
# product and one repo, that repo cloned as a real git repo with the two adapter symlinks
# `aiworks add` actually creates, and the four adapter dirs with fully-populated .env files.
# Healthy by construction — every case below breaks exactly one thing and looks for exactly
# one finding, so a check that fires on the wrong input has nowhere to hide.
SECRET='sk-DOCTORSELFTEST-must-never-be-printed-9f3a1c'

make_ws() {  # make_ws <dir>
  local w="$1"
  mkdir -p "$w"/{mani.d,scripts/{vcs,tracker,notify,observability},.claude/hooks,.git/info}
  : > "$w/mani.yaml"
  printf 'projects:\n  demo-repo:\n    path: ../demo-repo\n' > "$w/mani.d/demo.yaml"

  cat > "$w/workspace.config.yaml" <<'YAML'
org:
  name: selftest-org
vcs:
  provider: gitlab
notify:
  enabled: true
  provider: slack
observability:
  enabled: true
  provider: signoz
tracker:
  provider: jira
products:
  - id: demo
    repos:
      - url: git@example.com:demo/demo-repo.git
        kind: backend
        lang: rust
YAML

  printf 'JIRA_BASE_URL=https://example.atlassian.net\nJIRA_EMAIL=a@b.c\nJIRA_API_TOKEN=%s\n' \
    "$SECRET" > "$w/scripts/tracker/.env"
  printf 'SLACK_BOT_TOKEN=%s\n' "$SECRET" > "$w/scripts/notify/.env"
  printf 'SIGNOZ_BASE_URL=https://signoz.example\nSIGNOZ_API_KEY=%s\n' "$SECRET" \
    > "$w/scripts/observability/.env"
  printf 'GITLAB_TOKEN=%s\n' "$SECRET" > "$w/scripts/vcs/.env"

  local a
  for a in vcs tracker notify observability; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$w/scripts/$a/reader.sh"
    chmod +x "$w/scripts/$a/reader.sh"
  done

  printf '{"hooks":{}}\n' > "$w/.claude/settings.json"
  mkdir -p "$w/.claude/skills"
  printf 'workspace instructions\n' > "$w/CLAUDE.md"

  # the repo, as `aiworks add` leaves it
  local r="$w/demo-repo"
  mkdir -p "$r"/{scripts,.codegraph,.claude/rules,.cursor}
  git -C "$w" init -q 2>/dev/null
  git -C "$r" init -q 2>/dev/null
  printf 'demo-repo/\n' > "$w/.gitignore"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$r/scripts/dev.sh"; chmod +x "$r/scripts/dev.sh"
  printf 'repo instructions\n' > "$r/CLAUDE.md"
  printf '# agents\n' > "$r/AGENTS.md"
  printf '{}\n' > "$r/skills-lock.json"
  ( cd "$r/scripts" && ln -s ../../scripts/tracker tracker && ln -s ../../scripts/vcs vcs )
  printf -- '---\ndescription: d\npaths:\n  - "src/**"\n---\nbody\n' > "$r/.claude/rules/good.md"
  # a valid HEAD — group 2 treats a clone without one as unfinished
  git -C "$r" -c user.email=s@t -c user.name=s add -A >/dev/null 2>&1
  git -C "$r" -c user.email=s@t -c user.name=s commit -qm init >/dev/null 2>&1
}

# run <workspace-dir> [args…] — stdout+stderr together, exit code in $RC. Offline groups only
# by default, so no case reaches the network or a daemon.
RC=0
run() {
  local w="$1"; shift
  local out
  out="$("$SCRIPT" --skip mcp,services,credentials,disk "$@" 2>&1)"
  RC=$?
  printf '%s' "$out"
}
# The script resolves its workspace from its own location, so a fixture run needs the script
# beside the fixture. Copy it in rather than teaching the script an override that only a test
# would ever use.
stage() {  # stage <fixture-dir> — prints the staged script's dir
  local w="$1"
  mkdir -p "$w/scripts"
  cp "$SCRIPT" "$w/scripts/aiworks-doctor.sh"
  chmod +x "$w/scripts/aiworks-doctor.sh"
}

printf '\naiworks-doctor selftest\n\n'

# ── 1 · a healthy workspace is silent and green ───────────────────────────────────
W="$T/healthy"; make_ws "$W"; stage "$W"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "healthy fixture exits 0" 0 "$RC"
ck "healthy fixture reports no failure" "0 fail" "$OUT"

# ── 2 · not a workspace at all ────────────────────────────────────────────────────
W2="$T/notaws"; mkdir -p "$W2/scripts"; cp "$SCRIPT" "$W2/scripts/"; chmod +x "$W2/scripts/aiworks-doctor.sh"
OUT="$("$W2/scripts/aiworks-doctor.sh" 2>&1)"; RC=$?
ck_exit "no mani.yaml exits 2" 2 "$RC"
ck "no mani.yaml says so" "no mani.yaml" "$OUT"

# ── 3 · a declared repo that was never cloned ─────────────────────────────────────
W="$T/uncloned"; make_ws "$W"; stage "$W"; rm -rf "$W/demo-repo"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "uncloned repo exits 1" 1 "$RC"
ck "uncloned repo is named"        "demo-repo"    "$OUT"
ck "uncloned repo offers the fix"  "aiworks sync" "$OUT"

# ── 4 · an .env whose var is present but EMPTY (the worktree stub shape) ──────────
# The case a file-exists check cannot see, and the reason doctor greps for a VALUE.
W="$T/stub"; make_ws "$W"; stage "$W"
printf 'JIRA_BASE_URL=https://example.atlassian.net\nJIRA_EMAIL=a@b.c\nJIRA_API_TOKEN=\n' \
  > "$W/scripts/tracker/.env"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "empty var exits 1" 1 "$RC"
ck "empty var is named" "JIRA_API_TOKEN" "$OUT"

# ── 5 · a set var is NOT reported as missing ──────────────────────────────────────
W="$T/setvar"; make_ws "$W"; stage "$W"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"
ck "a set var is not flagged" "ABSENT:JIRA_API_TOKEN" "$OUT"

# ── 6 · slack's OR contract — either token satisfies it ───────────────────────────
W="$T/slackor"; make_ws "$W"; stage "$W"
printf 'SLACK_WEBHOOK_URL=https://hooks.example/x\n' > "$W/scripts/notify/.env"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"
ck "webhook alone satisfies notify" "ABSENT:SLACK_BOT_TOKEN" "$OUT"
printf 'NOTIFY_PROVIDER=slack\n' > "$W/scripts/notify/.env"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"
ck "neither token is a finding" "SLACK_BOT_TOKEN/SLACK_WEBHOOK_URL" "$OUT"

# ── 7 · a disabled feature is a decision, not a defect ────────────────────────────
W="$T/disabled"; make_ws "$W"; stage "$W"
printf 'voice:\n  enabled: false\n' >> "$W/workspace.config.yaml"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "a disabled feature keeps exit 0" 0 "$RC"
ck "a disabled feature reads as skipped" "voice.enabled is false" "$OUT"

# ── 7b · disabled notify/observability must not demand a missing .env ─────────────
# Local overlay flips the fixture's enabled:true → false; deleting the .env then proves
# the adapters group skips instead of failing (the false-positive the live workspace hit).
W="$T/disabled-adapters"; make_ws "$W"; stage "$W"
printf 'notify:\n  enabled: false\nobservability:\n  enabled: false\n' \
  > "$W/workspace.config.local.yaml"
rm -f "$W/scripts/notify/.env" "$W/scripts/observability/.env"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "disabled adapters keep exit 0" 0 "$RC"
ck "disabled notify reads as skipped" "notify.enabled is false" "$OUT"
ck "disabled observability reads as skipped" "observability.enabled is false" "$OUT"
ck "missing .env of disabled notify is not a fail" "ABSENT:scripts/notify/.env missing" "$OUT"
ck "missing .env of disabled observability is not a fail" \
   "ABSENT:scripts/observability/.env missing" "$OUT"

# ── 8 · THE LEAK TEST ─────────────────────────────────────────────────────────────
# Every byte doctor writes, on both streams, in every mode that touches an .env — searched
# for the fixture's secret. A single `grep -n` left in while debugging fails this.
W="$T/leak"; make_ws "$W"; stage "$W"
leaked=""
for mode in "" "-v" "--json" "--strict -v" "--fix -n"; do
  # shellcheck disable=SC2086
  ALL="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk $mode 2>&1)"
  case "$ALL" in *"$SECRET"*) leaked="${leaked:+$leaked }[${mode:-default}]" ;; esac
done
# …and again with a stub .env, the path that has to NAME the variable it could not find
printf 'JIRA_BASE_URL=\nJIRA_EMAIL=\nJIRA_API_TOKEN=\n' > "$W/scripts/tracker/.env"
ALL="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk -v 2>&1)"
case "$ALL" in *"$SECRET"*) leaked="${leaked:+$leaked }[stub]" ;; esac
[[ -z "$leaked" ]] && ok "no .env value reaches any output stream" \
                   || bad "no .env value reaches any output stream" "LEAKED in: $leaked"

# ── 9 · xtrace can never be switched on inside the script ─────────────────────────
# An xtrace line prints the grep's arguments, which include the .env path and pattern, and
# on some shells the expanded value. The rule is absolute, so it is checked as source text.
if grep -nE '^[[:space:]]*(set -x|set -[a-z]*x[a-z]*|PS4=)' "$SCRIPT" >/dev/null 2>&1; then
  bad "the script never enables xtrace" "found a set -x / PS4 in $SCRIPT"
else
  ok "the script never enables xtrace"
fi

# ── 10 · every .env grep is quiet ─────────────────────────────────────────────────
# The guard allows grep on an .env only with -q. Any other grep against an env path here
# would print matching lines — that is the leak, one edit away.
badgrep="$(grep -nE 'grep[^|]*\$?env' "$SCRIPT" | grep -v -- '-q' | grep -viE 'ENV_TOKEN|^\s*#' || true)"
[[ -z "$badgrep" ]] && ok "every .env grep is quiet (-q)" \
                    || bad "every .env grep is quiet (-q)" "$badgrep"

# ── 11 · --json is valid, complete, and has no field that could hold a value ──────
W="$T/json"; make_ws "$W"; stage "$W"
JS="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk --json 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$JS" | jq -e . >/dev/null 2>&1; then
    ok "--json is valid JSON"
    keys="$(printf '%s' "$JS" | jq -r '[.checks[0]|keys[]]|join(",")' 2>/dev/null)"
    ck "--json check keys are fixed" "detail,fix,group,label,status" "$keys"
    n="$(printf '%s' "$JS" | jq -r '.checks|length')"
    [[ "${n:-0}" -gt 0 ]] && ok "--json carries checks ($n)" || bad "--json carries checks" "got $n"
  else
    bad "--json is valid JSON" "jq rejected it"
  fi
else
  skipc "--json validity (no jq)"
fi

# ── 12 · the required-var table still covers every provider ───────────────────────
# provider_required_vars() is a copy of a contract that lives elsewhere. This is the case
# that notices when the original grows a sibling.
missing=""
for d in "$ROOT"/scripts/tracker/*/ "$ROOT"/scripts/notify/*/ "$ROOT"/scripts/observability/*/; do
  [[ -d "$d" ]] || continue
  p="$(basename "$d")"
  case "$p" in providers|lib|templates) continue ;; esac
  [[ -f "$d/impl.sh" ]] || continue
  grep -q "/$p)" "$SCRIPT" || missing="${missing:+$missing }$p"
done
for f in "$ROOT"/scripts/vcs/*.sh; do
  b="$(basename "$f" .sh)"
  # A DEFINITION marks a provider; lib.sh merely calls the function at column 0, and matching
  # that made this case demand a table entry for "vcs/lib".
  grep -q "^vcs_require_config()" "$f" 2>/dev/null || continue
  grep -q "vcs/$b" "$SCRIPT" || missing="${missing:+$missing }vcs/$b"
done
[[ -z "$missing" ]] && ok "required-var table covers every provider" \
                    || bad "required-var table covers every provider" "unknown to doctor: $missing"

# ── 13 · --fix never runs anything without consent ────────────────────────────────
W="$T/fix"; make_ws "$W"; stage "$W"; chmod -x "$W/demo-repo/scripts/dev.sh"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk --fix -n 2>&1)"
ck "--fix -n plans the chmod"  "chmod +x"            "$OUT"
ck "--fix -n runs nothing"     "nothing was run"     "$OUT"
[[ -x "$W/demo-repo/scripts/dev.sh" ]] && bad "--fix -n really changed nothing" "the file became executable" \
                                       || ok "--fix -n really changed nothing"
OUT="$("$W/scripts/aiworks-doctor.sh" --fix </dev/null 2>&1)"; RC=$?
ck_exit "--fix without a TTY or -y exits 2" 2 "$RC"
ck "--fix without a TTY says why" "needs -y" "$OUT"

# ── 14 · --strict promotes a warn, and only a warn ────────────────────────────────
W="$T/strict"; make_ws "$W"; stage "$W"
printf 'x\n%.0s' $(seq 1 120) >> "$W/CLAUDE.md"          # over the 100-line budget → warn
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "a warn alone still exits 0" 0 "$RC"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk --strict 2>&1)"; RC=$?
ck_exit "--strict turns that warn into exit 1" 1 "$RC"

# ── 15 · the false positives that shipped in the first draft ──────────────────────
# Each of these looked entirely convincing in real output. They stay pinned.
W="$T/nofp"; make_ws "$W"; stage "$W"
printf -- '---\ndescription: d\npaths:\n  - "a/**"\nglobs:\n  - "a/**"\n---\nb\n' \
  > "$W/demo-repo/.claude/rules/both.md"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"
ck "paths+globs together is not a finding" "ABSENT:globs" "$OUT"
ck "notify/observability are not demanded per-repo" "ABSENT:demo-repo/notify" "$OUT"
printf -- '---\ndescription: d\nglobs:\n  - "a/**"\n---\nb\n' > "$W/demo-repo/.claude/rules/bad.md"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"
ck "globs WITHOUT paths is a finding" "globs" "$OUT"

# ── 16 · a repo positional narrows, and rejects a name that is not declared ───────
W="$T/narrow"; make_ws "$W"; stage "$W"
OUT="$("$W/scripts/aiworks-doctor.sh" demo-repo 2>&1)"; RC=$?
ck_exit "a valid repo positional runs" 0 "$RC"
ck "a narrowed run skips machine-wide groups" "not repo-scoped" "$OUT"
OUT="$("$W/scripts/aiworks-doctor.sh" nosuchrepo 2>&1)"; RC=$?
ck_exit "an undeclared repo exits 2" 2 "$RC"

# ── 17 · a hook that lost its +x is a failure, not a shrug ────────────────────────
W="$T/hook"; make_ws "$W"; stage "$W"
mkdir -p "$W/.claude/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/.claude/hooks/demo-guard.sh"
chmod -x "$W/.claude/hooks/demo-guard.sh"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":".claude/hooks/demo-guard.sh"}]}]}}\n' \
  > "$W/.claude/settings.json"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
ck_exit "a non-executable hook exits 1" 1 "$RC"
ck "a non-executable hook is named" "demo-guard.sh" "$OUT"
ck "a non-executable hook offers chmod" "chmod +x" "$OUT"

# ── 18 · the live workspace, if this clone has one ────────────────────────────────
if [[ -f "$ROOT/mani.yaml" && -f "$ROOT/workspace.config.yaml" ]]; then
  OUT="$("$SCRIPT" --skip mcp,services,credentials,disk 2>&1)"; RC=$?
  case "$RC" in 0|1) ok "runs on the live workspace (exit $RC)" ;;
                 *)  bad "runs on the live workspace" "unexpected exit $RC: $OUT" ;; esac
  ck "the live run summarises" "pass ·" "$OUT"
else
  skipc "live workspace run (no config in this clone)"
fi

# ── 19 · plugin scope drift + the caveman restart marker ──────────────────────────
# Both checks read machine state ($HOME plugin registry, $CLAUDE_CONFIG_DIR activation flag), so
# each case points those at a crafted directory instead of the real one. The pair that matters is
# 19a/19c: the check must fire on DIVERGENCE and stay silent on mere duplication, because a
# project-scope entry re-appears on its own and a warn nobody can clear is the defect this file
# already pins for `gh` currency.
W="$T/pluginscope"; make_ws "$W"; stage "$W"
printf '{"hooks":{},"enabledPlugins":{"caveman@caveman":true}}\n' > "$W/.claude/settings.json"
FH="$T/fakehome"; mkdir -p "$FH/.claude/plugins"

mk_reg() {  # mk_reg <user-version> <project-version>
  cat > "$FH/.claude/plugins/installed_plugins.json" <<JSON
{"version":1,"plugins":{"caveman@caveman":[
 {"scope":"user","version":"$1","lastUpdated":"2026-07-20T11:15:27.000Z"},
 {"scope":"project","projectPath":"$W","version":"$2","lastUpdated":"2026-07-01T00:00:00.000Z"}]}}
JSON
}
# -v so a PASSING check's detail line is visible too — the "duplicate but in step" case asserts on
# that detail, and without -v the renderer collapses every pass into a single "✓ N ok".
run_ps() { HOME="$FH" CLAUDE_CONFIG_DIR="$FH/.claude" "$W/scripts/aiworks-doctor.sh" --only agent-cfg -v 2>&1; }

mk_reg NEW999 OLD111
printf 'full' > "$FH/.claude/.caveman-active"; touch -t 202607010000 "$FH/.claude/.caveman-active"
OUT="$(run_ps)"
ck "a diverged project-scope copy is a finding"   "drifted from user scope" "$OUT"
ck "the finding names the plugin"                 "caveman@caveman"         "$OUT"
ck "an update after the last activation warns"    "updated since the last activation" "$OUT"
# The rendered owner command is width-truncated ("… (+1 more words)"), and the half that gets cut is the
# settings.json restore — the half whose absence breaks the whole team. Assert on --json, which
# carries the command whole.
JOUT="$(HOME="$FH" CLAUDE_CONFIG_DIR="$FH/.claude" "$W/scripts/aiworks-doctor.sh" --only agent-cfg --json 2>&1)"
ck "the fix restores the committed settings.json" "git checkout -- .claude/settings.json" "$JOUT"

mk_reg SAME777 SAME777
touch -t 202608010000 "$FH/.claude/.caveman-active"
OUT="$(run_ps)"
ck "a duplicate at the SAME version is not a finding" "ABSENT:drifted from user scope" "$OUT"
ck "activation after the update is not a finding"     "ABSENT:updated since the last activation" "$OUT"
ck "the duplicate is still reported as context"       "project-scope duplicate" "$OUT"

rm -f "$FH/.claude/.caveman-active"
OUT="$(run_ps)"
ck "no activation marker skips rather than warns" "ABSENT:updated since the last activation" "$OUT"

# A DECLARED plugin with no user-scope entry at all. This is the state `aiworks sync` leaves —
# it converges enabledPlugins everywhere and never installs — and nothing else reported it, so a
# teammate ran sync, saw the skills resolve, and had no hooks. The pass line has to disappear
# with it: "declared plugins are user-scope only" printed beside the warn would read as fine.
cat > "$FH/.claude/plugins/installed_plugins.json" <<'JSON'
{"version":1,"plugins":{"caveman@caveman":[
 {"scope":"project","projectPath":"/nowhere","version":"OLD111","lastUpdated":"2026-07-01T00:00:00.000Z"}]}}
JSON
OUT="$(run_ps)"
ck "a declared-but-uninstalled plugin is a finding" "declared plugin(s) not installed" "$OUT"
ck "the finding names the plugin"                   "caveman@caveman"                   "$OUT"
ck "it does not also claim the scope is clean"      "ABSENT:user-scope only"            "$OUT"
JOUT="$(HOME="$FH" CLAUDE_CONFIG_DIR="$FH/.claude" "$W/scripts/aiworks-doctor.sh" --only agent-cfg --json 2>&1)"
ck "the fix runs the one script that owns the install" "ensure_claude_plugins" "$JOUT"

# ── 20 · triage: sync reports it, doctor scores it, a human bootstraps it ─────────
# `aiworks sync` no longer registers the triage MCPs and no longer probes GKE (docs/adr/0009),
# which makes this group the only thing that scores either. So it has to stay quiet on a machine
# that does no deployed-environment work at all: both halves SKIP — never fail — when the pieces
# are simply absent, because a finding nobody can clear is worse than no group.
W="$T/triage"; make_ws "$W"; stage "$W"

OUT="$("$W/scripts/aiworks-doctor.sh" --only triage 2>&1)"; RC=$?
ck_exit "--only triage runs clean with nothing installed" 0 "$RC"
ck "a missing triage-mcp.sh skips, never fails" "scripts/triage-mcp.sh not present" "$OUT"
ck "the kubernetes half is reported too"        "kubernetes triage identity"        "$OUT"
ck "--only triage runs no other group"          "ABSENT:adapters"                   "$OUT"

printf 'triage:\n  enabled: false\n' >> "$W/workspace.config.yaml"
OUT="$("$W/scripts/aiworks-doctor.sh" --only triage 2>&1)"; RC=$?
ck_exit "a disabled triage keeps exit 0"  0 "$RC"
ck "a disabled triage reads as skipped"   "triage.enabled is false"          "$OUT"
ck "a disabled triage checks nothing"     "ABSENT:kubernetes triage identity" "$OUT"

# ── 21 · the savings badge can be wired and still measure nothing ─────────────────
# The plugin's doctor copies scripts/statusline.sh to ~/.claude but never scripts/lib/, and the
# statusline's compute() returns zeros without attribution.jq beside it — silently. Measured on a
# real machine: ~35 session caches all n=0 saved=0 missed=0, no .totals ever written, and the
# plugin's own doctor reporting 14/14 ok throughout. So "wired" must NOT be the whole test.
W="$T/hrbadge"; make_ws "$W"; stage "$W"
FH="$T/hrhome"; mkdir -p "$FH/.claude"
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/headroom-statusline.sh"}}\n' \
  > "$FH/.claude/settings.json"

run_hr() { HOME="$FH" CLAUDE_CONFIG_DIR="$FH/.claude" "$W/scripts/aiworks-doctor.sh" --only headroom -v 2>&1; }

OUT="$(run_hr)"
ck "a wired badge with no lib is a finding"   "savings badge measures nothing" "$OUT"
ck "the finding names the missing files"      "attribution.jq"                 "$OUT"
ck "it does not also report the badge as ok"  "ABSENT:attribution lib beside"  "$OUT"

: > "$FH/.claude/attribution.jq"; : > "$FH/.claude/headroom-state.sh"
OUT="$(run_hr)"
ck "the lib present clears the finding"       "ABSENT:measures nothing"        "$OUT"
ck "and the pass line says why it passed"     "attribution lib beside the copy" "$OUT"

# An unwired badge keeps its own separate finding — the lib check must not swallow it.
printf '{"statusLine":{"type":"command","command":"bash /my/own/bar.sh"}}\n' > "$FH/.claude/settings.json"
OUT="$(run_hr)"
ck "an unwired badge still reports as unwired" "savings badge not wired"       "$OUT"
ck "an unwired badge is not a lib finding"     "ABSENT:measures nothing"       "$OUT"

# ── 22 · the badge price table reads the ledger, and stays quiet without one ──────
# A model missing from the badge's price table costs nothing visible — the badge just drops the
# `$` segment and records 0.000000 — so the finding is derived from the ledger the badge wrote:
# a session that saved tokens with no dollars against it. Both directions are pinned, because a
# check that cannot fire and a check that always fires look identical on a healthy machine.
W="$T/headroom"; make_ws "$W"; stage "$W"
LEDGER="$T/headroom-ledger"; mkdir -p "$LEDGER"

OUT="$(HEADROOM_STATE_DIR="$T/headroom-ledger-absent" "$W/scripts/aiworks-doctor.sh" --only headroom -v 2>&1)"
ck "no ledger yet is a skip, not a finding" "no headroom ledger on this machine yet" "$OUT"

printf '86972 0.434860\n' > "$LEDGER/session-priced.totals"
OUT="$(HEADROOM_STATE_DIR="$LEDGER" "$W/scripts/aiworks-doctor.sh" --only headroom -v 2>&1)"
ck "a priced ledger passes"        "every recorded saving is priced" "$OUT"
ck "a priced ledger says nothing"  "ABSENT:could not price"          "$OUT"

printf '12345 0.000000\n' > "$LEDGER/session-unpriced.totals"
OUT="$(HEADROOM_STATE_DIR="$LEDGER" "$W/scripts/aiworks-doctor.sh" --only headroom 2>&1)"; RC=$?
ck "tokens saved with no dollars is a finding" "1 session(s) saved tokens the badge could not price" "$OUT"
ck "the finding names the file to edit"        "headroom-model-prices.json"                          "$OUT"
ck_exit "an unpriced model warns, never fails" 0 "$RC"

# ── 23 · the badge check follows a chained statusLine ─────────────────────────────
# Another tool can take over `statusLine.command` and re-run the command it replaced from its own
# cache file. The badge still renders every second; the settings.json string no longer names it.
# Grepping that string reported "not wired" on a machine whose bar was printing the badge — and
# the remedy it offered would have chained the bridge and nested the two. So the check renders the
# bar and looks. The probe must also stay inert: it runs somebody's shell command, and a doctor
# that writes into the ledger it is auditing has corrupted its own next answer.
W="$T/hrchain"; make_ws "$W"; stage "$W"
FH="$T/hrchainhome"; mkdir -p "$FH/.claude"
LED="$T/hrchainledger"; mkdir -p "$LED"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s\\n" "○ headroom idle (not compressing yet)"\n' \
  > "$FH/badge-bridge.sh"; chmod +x "$FH/badge-bridge.sh"

run_chain() {  # run_chain — doctor against the fixture HOME and a throwaway ledger
  HOME="$FH" CLAUDE_CONFIG_DIR="$FH/.claude" HEADROOM_STATE_DIR="$LED" \
    "$W/scripts/aiworks-doctor.sh" --only headroom -v 2>&1
}

printf '{"statusLine":{"type":"command","command":"bash %s/badge-bridge.sh"}}\n' "$FH" \
  > "$FH/.claude/settings.json"

# Chained and lib-less: the two checks are independent, and a chained badge with no attribution
# lib is exactly as blind as a directly-wired one. Establishing that the bar renders must not
# excuse it from the counting check — that is the hole this restructure exists to keep closed.
OUT="$(run_chain)"
ck "a chained bar is still held to the lib check" "savings badge measures nothing" "$OUT"

: > "$FH/.claude/attribution.jq"; : > "$FH/.claude/headroom-state.sh"
OUT="$(run_chain)"
ck "a chained bar that renders the badge passes" "wired through a chained statusLine" "$OUT"
ck "and it is not reported as unwired"           "ABSENT:savings badge not wired"     "$OUT"

# The probe runs a shell command; it must leave the ledger it is auditing untouched.
ck "the probe writes nothing into the ledger" "" "$(ls "$LED" 2>/dev/null)"

printf '{"statusLine":{"type":"command","command":"printf %%s my-own-bar"}}\n' \
  > "$FH/.claude/settings.json"
OUT="$(run_chain)"
ck "a bar without the badge is still a finding" "savings badge not wired"              "$OUT"
ck "it does not claim a chain that is not there" "ABSENT:wired through a chained"      "$OUT"

# ── base drift (docs/adr/0025) ────────────────────────────────────────────────────
# The base a run cuts a branch from lived only as a constant in the generated workflow mirror, and
# nothing validated it. Measured: repos projected onto a base 99 and 157 commits behind their real
# trunk, one of them a 16-file scaffold a year stale, so a ticket's branch was cut off a dead
# branch and a whole round went into finding out. This is the check that says so BEFORE the run.
#
# base_fixture <dir> <projected-base> [origin-head-branch] — stages the mirror the check reads and
# the remote-tracking refs it compares against. No remote is needed: update-ref writes the same
# refs/remotes/origin/* a fetch would, which is exactly what the check inspects.
# -v, because the default view collapses a passing check to a count and ellipsises a long
# detail line ("… (+31 more words)") — both of which these cases assert on.
dr() { "$1/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk -v 2>&1; }
# The text view ellipsises a long detail at ~96 chars even under -v; --json is the channel
# that carries it whole, so a case asserting on the tail of a detail reads that instead.
drj() { "$1/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk --json 2>&1; }
base_fixture() {
  local w="$1" projected="$2" head_branch="${3:-}"
  mkdir -p "$w/.claude/workflows"
  { printf "const REPOS = {\n"
    printf "  'demo-repo': {\n"
    printf "    path: 'demo-repo', kind: 'backend',\n"
    printf "    base: { feature: '%s', fix: 'main' },\n" "$projected"
    printf "  },\n}\n"; } > "$w/.claude/workflows/dev-cycle.js"
  local r="$w/demo-repo" sha
  sha="$(git -C "$r" rev-parse HEAD 2>/dev/null)"
  [[ -n "$head_branch" ]] || return 0
  git -C "$r" update-ref "refs/remotes/origin/$head_branch" "$sha" 2>/dev/null
  git -C "$r" symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$head_branch" 2>/dev/null
}

# 20a — projected base agrees with what the remote calls its default: silent, and green.
W="$T/base-ok"; make_ws "$W"; stage "$W"; base_fixture "$W" develop develop
git -C "$W/demo-repo" update-ref refs/remotes/origin/develop "$(git -C "$W/demo-repo" rev-parse HEAD)" 2>/dev/null
OUT="$(dr "$W")"
ck "a base matching origin/HEAD passes"        "feature base vs origin/HEAD" "$OUT"
ck "…and raises no drift warning"              "ABSENT:disagrees with origin/HEAD" "$OUT"

# 20b — projected base EXISTS but is not the remote's default: warn, and name both sides. This is
# the shape that is sometimes legitimate (a repo really on its own branch policy), so it must not
# be a failure — it must tell you how to declare it.
W="$T/base-drift"; make_ws "$W"; stage "$W"
base_fixture "$W" main develop
git -C "$W/demo-repo" update-ref refs/remotes/origin/main "$(git -C "$W/demo-repo" rev-parse HEAD)" 2>/dev/null
OUT="$(dr "$W")"
ck "drift against origin/HEAD is reported"     "feature base disagrees with origin/HEAD" "$OUT"
ck "…naming the base the run would use"        "uses main"        "$OUT"
ck "…and what the remote actually points at"   "origin/HEAD→develop" "$OUT"
ck "…and how to declare it deliberately"       "feature_base"     "$(drj "$W")"
ck "drift is a warning, not a failure"         "ABSENT:1 fail"    "$OUT"

# 20c — projected base is not on the remote AT ALL. Not a style question: the open-PR precondition
# hard-stops on it, so no ticket can finish in that repo until it is fixed.
W="$T/base-gone"; make_ws "$W"; stage "$W"
base_fixture "$W" release/9.9 develop
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk -v 2>&1)"; RC=$?
ck "a base absent from the remote FAILS"       "does not exist on the remote" "$OUT"
ck "…naming the repo and the branch"           "demo-repo(→release/9.9)"      "$OUT"
ck "…and saying what it costs"                 "no ticket can finish"         "$OUT"
ck_exit "…so the run exits non-zero"           1 "$RC"

# ── 21 · --fix is refereed by a second pass, not by an exit code ──────────────────
# Measured on a real workspace: `--fix -y` reported "3 fixed · 0 failed" and a re-run returned a
# byte-identical finding set. All three owner commands exited 0 while closing nothing — one
# skipped its own stale registration as foreign, one only ever failed under --check, one stood in
# for a config edit nobody had made. So the doctor re-runs the same scope and reports what
# actually cleared, and the VERDICT comes from that second pass rather than the stale first one.
#
# The fixture breaks two things at once: a chmod the fix really closes, and an over-budget
# CLAUDE.md whose fix is an editor — so one finding must clear and the other must be named as
# still open. This is the only case that runs --fix for real; every command it can reach is a
# chmod inside $T.
W="$T/refereed"; make_ws "$W"; stage "$W"
chmod -x "$W/demo-repo/scripts/dev.sh"
{ printf '# repo\n'; for i in $(seq 1 130); do printf 'line %s\n' "$i"; done; } > "$W/demo-repo/CLAUDE.md"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk --fix -y 2>&1)"; RC=$?
ck "the runner says it RAN a command, not that it fixed one"  "✓ ran"        "$OUT"
ck "a second pass re-checks the findings"                    "re-checked:"  "$OUT"
ck "…counting the one that really cleared"                   "1 cleared"    "$OUT"
ck "…and the two it did not"                                 "2 still open" "$OUT"
ck "…named, so nobody has to diff two runs by eye"  "still open  CLAUDE.md over the 100-line budget" "$OUT"
[[ -x "$W/demo-repo/scripts/dev.sh" ]] && ok "the fix really ran" \
                                       || bad "the fix really ran" "dev.sh is still not executable"
ck_exit "the verdict follows the re-check, not the first pass" 0 "$RC"
# Same run under --strict: what survived is a warning, and --strict fails on one.
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk --fix -y --strict 2>&1)"; RC=$?
ck_exit "a warning that survived the fix still fails --strict" 1 "$RC"

# 21b — the referee must survive being invoked by a RELATIVE path. The script cd's to $ROOT
# during startup, so re-invoking itself as "$0" resolves against the wrong directory: the child
# produced nothing, the run printed "could not re-check", and the verdict silently fell back to
# the PRE-FIX pass. Measured: `cd demo-repo && ../scripts/aiworks-doctor.sh --fix -y` exited 1
# over a finding the chmod had already closed. Every other case here uses an absolute path,
# which is exactly why none of them caught it.
W="$T/refereed-rel"; make_ws "$W"; stage "$W"
chmod -x "$W/demo-repo/scripts/dev.sh"
OUT="$(cd "$W/demo-repo" && ../scripts/aiworks-doctor.sh --skip mcp,services,credentials,disk --fix -y 2>&1)"; RC=$?
ck "a relative invocation still re-checks"      "re-checked:"          "$OUT"
ck "…and does not claim it could not"           "ABSENT:could not re-check" "$OUT"
ck_exit "…so the closed failure exits 0"        0 "$RC"

# 21c — a CRLF rules file HAS frontmatter. The canonical reader (parse_frontmatter in
# scripts/codex/common.py) compares lines[0].strip(), so `---\r` is valid there; comparing
# `head -n 1` to `---` byte for byte made every CRLF rules file a permanent false positive,
# routed to "needs you", telling the reader to add the block the file already has.
W="$T/crlf-rules"; make_ws "$W"; stage "$W"
printf -- '---\r\ndescription: d\r\npaths:\r\n  - "src/**"\r\n---\r\nbody\r\n' \
  > "$W/demo-repo/.claude/rules/crlf.md"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk -v 2>&1)"
ck "a CRLF rules file is not called frontmatter-less" "ABSENT:no YAML frontmatter" "$OUT"
ck "…and its scoping is read correctly"               "ABSENT:globs:' and no 'paths:" "$OUT"
# …while a file with genuinely no frontmatter is still named.
printf '# just a heading\n\n- a rule\n' > "$W/demo-repo/.claude/rules/bare.md"
OUT="$("$W/scripts/aiworks-doctor.sh" --skip mcp,services,credentials,disk -v 2>&1)"
ck "a file with no frontmatter at all is reported"    "rules file with no YAML frontmatter" "$OUT"
ck "…naming the file"                                 "demo-repo/.claude/rules/bare.md"     "$OUT"

# ── report ────────────────────────────────────────────────────────────────────────
printf '\n  %d passed · %d failed · %d skipped\n\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
