#!/usr/bin/env bash
#
# Superset lifecycle selftest — the readiness hook, the setup lock, and the setup helpers.
#
#   ./scripts/aiworks-superset-selftest.sh
#
# WHY THIS SUITE EXISTS. A fresh Superset worktree starts its agent session BEFORE setup has
# cloned the declared repos, and the readiness hook (.claude/hooks/repo-health-check.sh) is the
# only thing standing between the agent and "that repo does not exist". It has to see the expected
# repo set before `aiworks sync` generates mani.d/, tell a running setup from a crashed one from
# one that never ran, and say so once rather than every turn. Each of those is a silent failure
# when it breaks, so each is pinned here.
#
# HERMETIC. Every fixture is a temp dir with its own workspace.config.yaml, its own git repos
# (git init + one empty commit, so HEAD resolves) and its own TMPDIR, so the hook's de-dup
# markers never touch the real /tmp. No network, no `mani`, no `aiworks sync`.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
HOOK="$ROOT/.claude/hooks/repo-health-check.sh"
LIB="$ROOT/.superset/lib.sh"
pass=0 fail=0
T="$(mktemp -d "${TMPDIR:-/tmp}/aiworks-superset-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n        %s\n' "$1" "${2:-}"; }
ck() {  # ck <label> <expect-substring|ABSENT:substring> <actual>
  case "$2" in
    ABSENT:*) case "$3" in *"${2#ABSENT:}"*) bad "$1" "did not expect '${2#ABSENT:}', got: $3" ;;
                                          *) ok "$1" ;; esac ;;
    *)        case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "want ⊃ $2 — got: $3" ;; esac ;;
  esac
}
ck_exit() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want exit $2, got $3"; }

# ── fixtures ──────────────────────────────────────────────────────────────────────
# mkfx <name> <with-mani.d 0|1> <repos-to-clone…>  → sets $fx; declares app-a + app-b.
mkfx() {
  fx="$T/$1"; local mani="$2"; shift 2
  mkdir -p "$fx"
  cat > "$fx/workspace.config.yaml" <<'EOF'
products:
  - id: acme
    repos:
      - url: git@example.invalid:acme/app-a.git
      - url: git@example.invalid:acme/app-b.git
EOF
  if [[ "$mani" == 1 ]]; then
    mkdir -p "$fx/mani.d"
    printf 'projects:\n  app-a:\n    path: ../app-a\n  app-b:\n    path: ../app-b\n' > "$fx/mani.d/acme.yaml"
  fi
  local r; for r in "$@"; do clone_repo "$fx/$r"; done
}
clone_repo() {  # <dir> — a finished clone: git repo with a resolvable HEAD
  git init -q "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit --allow-empty -qm x
}
hook() {  # hook <fx> <args…> — runs the hook with the fixture as the project dir; sets $out $rc
  local d="$1"; shift
  out="$(CLAUDE_PROJECT_DIR="$d" TMPDIR="$d" REPO_HEALTH_POLL_SECS=1 bash "$HOOK" "$@" 2>&1)"; rc=$?
}
hook_event() {  # hook_event <fx> <event> <sid> — hook mode; sets $out (stdout) $ctx
  local d="$1"
  out="$(printf '{"hook_event_name":"%s","session_id":"%s"}' "$2" "$3" \
        | CLAUDE_PROJECT_DIR="$d" TMPDIR="$d" bash "$HOOK" 2>/dev/null)"
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

# ── readiness hook ────────────────────────────────────────────────────────────────
echo "repo-health-check.sh"

mkfx h1 1 app-a app-b; hook "$fx" --status
ck_exit "H1 all cloned: exit 0" 0 "$rc"; ck "H1 all cloned: OK line" "OK: all 2" "$out"

mkfx h2 1 app-a; hook "$fx" --status
ck_exit "H2 one missing: exit 1" 1 "$rc"
ck "H2 one missing: count" "NOT READY: 1/2" "$out"
ck "H2 one missing: names it" "pending: app-b" "$out"
ck "H2 one missing: idle" "no setup running" "$out"

mkfx h3 1 app-a; git init -q "$fx/app-b"; hook "$fx" --status
ck_exit "H3 in-progress clone (no HEAD) is not ready" 1 "$rc"; ck "H3 names it" "pending: app-b" "$out"

mkfx h4 0; hook "$fx" --status
ck_exit "H4 no mani.d, config declares 2: exit 1" 1 "$rc"; ck "H4 counts from config" "0/2" "$out"

mkfx h5 0; rm "$fx/workspace.config.yaml"; hook "$fx" --status
ck_exit "H5 nothing declared: exit 0" 0 "$rc"; ck "H5 says so" "nothing to check" "$out"

mkfx h6 1 app-a; mkdir -p "$fx/.superset/run"
printf 'pid=%s\nstarted=now\n' "$$" > "$fx/.superset/run/setup.lock"; hook "$fx" --status
ck "H6 live lock pid: running" "setup is running" "$out"

mkfx h7 1 app-a; mkdir -p "$fx/.superset/run"
sleep 0 & dead=$!; wait "$dead"
printf 'pid=%s\nstarted=then\n' "$dead" > "$fx/.superset/run/setup.lock"; hook "$fx" --status
ck "H7 dead lock pid: interrupted" "setup looks interrupted" "$out"

mkfx h8 1 app-a app-b; hook_event "$fx" SessionStart s1
ck "H8 SessionStart healthy: announces" "All 2 product repos" "$ctx"

hook_event "$fx" UserPromptSubmit s1
[[ -z "$out" ]] && ok "H9 UserPromptSubmit healthy: silent" || bad "H9 UserPromptSubmit healthy: silent" "got: $out"

mkfx h10 1 app-a; hook_event "$fx" UserPromptSubmit s2; first="$ctx"
hook_event "$fx" UserPromptSubmit s2; second="$ctx"
ck "H10 first not-ready prompt: full guidance" "Only 1 of 2" "$first"
ck "H10 repeat: short line" "Unchanged" "$second"
[[ "${#second}" -lt "${#first}" ]] && ok "H10 repeat is shorter" || bad "H10 repeat is shorter" "${#second} vs ${#first}"
hook_event "$fx" SessionStart s2
ck "H10 SessionStart always full" "ABSENT:Unchanged" "$ctx"

mkfx h11 1 app-a; ( sleep 1; clone_repo "$fx/app-b" ) & bg=$!
hook "$fx" --wait 15; wait "$bg"
ck_exit "H11 --wait clears when the clone lands" 0 "$rc"; ck "H11 OK line" "OK:" "$out"

mkfx h12 1 app-a; hook "$fx" --wait 1
ck_exit "H12 --wait times out" 1 "$rc"; ck "H12 says TIMEOUT" "TIMEOUT" "$out"

# ── setup lock + helpers (.superset/lib.sh) ───────────────────────────────────────
echo ".superset/lib.sh"

hf="$T/hosts"; printf '127.0.0.1 localhost\n' > "$hf"
hosts() { ( cd "$T" && HOSTS_FILE="$hf" bash -c 'source "$1"; shift; ensure_hosts_entries "$@"' _ "$LIB" "$@" ); }
hosts 127.0.0.1 a.test b.test >/dev/null 2>&1
ck "S1 appends a.test" "127.0.0.1	a.test" "$(cat "$hf")"
ck "S1 appends b.test" "127.0.0.1	b.test" "$(cat "$hf")"
ck "S1 writes the marker" "aiworks" "$(cat "$hf")"
before="$(cat "$hf")"; hosts 127.0.0.1 a.test b.test >/dev/null 2>&1
[[ "$(cat "$hf")" == "$before" ]] && ok "S2 re-run is a no-op" || bad "S2 re-run is a no-op" "$(cat "$hf")"
printf '127.0.0.1 localhost a.test\n' > "$hf"; hosts 127.0.0.1 a.test c.test >/dev/null 2>&1
ck "S3 shared line counts as present" "ABSENT:127.0.0.1	a.test" "$(cat "$hf")"
ck "S3 only the missing host is added" "127.0.0.1	c.test" "$(cat "$hf")"

lock="$T/lock/setup.lock"
out="$(bash -c 'source "$1"; setup_lock_acquire "$2"; cat "$2"' _ "$LIB" "$lock" 2>&1)"
ck "S4 lock carries pid=" "pid=" "$out"
ck "S4 lock carries started_epoch=" "started_epoch=" "$out"
ck "S4 lock carries started=" "started=" "$out"
[[ ! -f "$lock" ]] && ok "S4 lock removed on normal exit" || bad "S4 lock removed on normal exit" "still present"
bash -c 'source "$1"; setup_lock_acquire "$2"; sleep 30 & wait' _ "$LIB" "$lock" & lp=$!
sleep 0.5; kill -TERM "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
[[ ! -f "$lock" ]] && ok "S4 lock removed on TERM" || bad "S4 lock removed on TERM" "still present"
bash -c 'source "$1"; setup_lock_acquire "$2"; sleep 30 & wait' _ "$LIB" "$lock" & lp=$!
sleep 0.5; kill -KILL "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
[[ -f "$lock" ]] && ok "S4 lock survives KILL" || bad "S4 lock survives KILL" "missing"
mkfx s4 1 app-a; mkdir -p "$fx/.superset/run"; cp "$lock" "$fx/.superset/run/setup.lock"; hook "$fx" --status
ck "S4 hook classifies the KILL leftover as interrupted" "setup looks interrupted" "$out"

fx="$T/s5"; mkdir -p "$fx/scripts"; cp -R "$ROOT/.superset" "$fx/.superset"; : > "$fx/mani.yaml"
cp "$ROOT/scripts/aiworks-superset.sh" "$fx/scripts/"
sum() { ( cd "$fx/.superset" && find . -type f -print0 | sort -z | xargs -0 cat | cksum ); }
s_before="$(sum)"; ( cd "$fx" && bash scripts/aiworks-superset.sh -n -q >/dev/null 2>&1 ); rc=$?
ck_exit "S5 superset.sh -n exits 0" 0 "$rc"
[[ "$(sum)" == "$s_before" ]] && ok "S5 -n writes nothing" || bad "S5 -n writes nothing" "checksum changed"
( cd "$fx" && bash scripts/aiworks-superset.sh -q >/dev/null 2>&1 ); s_after="$(sum)"
( cd "$fx" && bash scripts/aiworks-superset.sh -q >/dev/null 2>&1 )
[[ "$(sum)" == "$s_after" ]] && ok "S5 second real run is a no-op" || bad "S5 second real run is a no-op" "checksum changed"

fx="$T/s6"; mkdir -p "$fx/.superset/products"
printf 'setup_product() { touch "%s/ran"; }\n' "$fx" > "$fx/.superset/products/acme.sh"
printf 'setup_product() { touch "%s/example-ran"; }\n' "$fx" > "$fx/.superset/products/example.sh"
printf 'DB_REPOS=(x)\n' > "$fx/.superset/products/nohook.sh"
( cd "$fx" && bash -c 'source "$1"; run_product_setup_hooks' _ "$LIB" >/dev/null 2>&1 ); rc=$?
ck_exit "S6 dispatch exits 0" 0 "$rc"
[[ -f "$fx/ran" ]] && ok "S6 acme setup_product ran" || bad "S6 acme setup_product ran" "no marker"
[[ ! -f "$fx/example-ran" ]] && ok "S6 example.sh skipped" || bad "S6 example.sh skipped" "example-ran exists"
printf 'setup_product() { return 7; }\n' > "$fx/.superset/products/broken.sh"
out="$(cd "$fx" && bash -c 'set -e; source "$1"; run_product_setup_hooks; echo survived' _ "$LIB" 2>&1)"
ck "S6 a failing hook never aborts setup" "survived" "$out"
ck "S6 a failing hook warns" "broken: setup_product failed" "$out"

# S7 — a linked worktree is served by its MAIN checkout's plugin install (docs/adr/0042): Claude
# Code keys a worktree's project by the main checkout path, so a per-worktree `plugin install`
# only adds a stale registry row and rewrites the tracked settings.json. An independent clone
# inside the worktree is a project of its own and still installs. Physical paths throughout:
# $T sits under /var → /private/var on macOS.
fx="$T/s7"; mkdir -p "$fx/h/.claude/plugins" "$fx/bin"
settings='{"enabledPlugins":{"p@m":true}}'
clone_repo "$fx/main"; mkdir -p "$fx/main/.claude"; printf '%s\n' "$settings" > "$fx/main/.claude/settings.json"
git -C "$fx/main" -c user.email=t@t -c user.name=t add -A >/dev/null && git -C "$fx/main" -c user.email=t@t -c user.name=t commit -qm s
git -C "$fx/main" worktree add -q "$fx/wt" 2>/dev/null
clone_repo "$fx/wt/clone"; mkdir -p "$fx/wt/clone/.claude"; printf '%s\n' "$settings" > "$fx/wt/clone/.claude/settings.json"
mainp="$(cd "$fx/main" && pwd -P)"; wtp="$(cd "$fx/wt" && pwd -P)"
printf '{"version":1,"plugins":{"p@m":[{"scope":"project","projectPath":"%s","version":"1"}]}}\n' "$mainp" \
  > "$fx/h/.claude/plugins/installed_plugins.json"
printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$(pwd -P)" "$*" >> "%s/claude.log"\n[[ "$1 $2 $3" == "plugin marketplace list" ]] && echo m\nexit 0\n' "$fx" > "$fx/bin/claude"
chmod +x "$fx/bin/claude"
plugins() { ( cd "$fx/wt" && PATH="$fx/bin:$PATH" HOME="$fx/h" bash -c 'source "$1"; ensure_claude_plugins' _ "$LIB" >/dev/null 2>&1 ); }
: > "$fx/claude.log"; plugins; out="$(cat "$fx/claude.log")"
ck "S7 worktree root: no install"              "ABSENT:$wtp plugin install"               "$out"
ck "S7 independent clone still installs"       "$wtp/clone plugin install p@m -s project" "$out"
st="$(git -C "$fx/wt" status --short .claude/settings.json)"
[[ -z "$st" ]] && ok "S7 worktree's tracked settings untouched" || bad "S7 worktree's tracked settings untouched" "$st"
printf '{"enabledPlugins":{"p@m":true,"q@m":true}}\n' > "$fx/wt/.claude/settings.json"
: > "$fx/claude.log"; plugins; out="$(cat "$fx/claude.log")"
ck "S7 branch-only plugin installs in the MAIN checkout" "$mainp plugin install q@m -s project" "$out"
ck "S7 branch-only plugin: still no worktree install"    "ABSENT:$wtp plugin install"           "$out"

echo "provision_tf_local"
fx="$T/tf"
rootp="$fx/root"; wtp="$fx/wt"; w2="$fx/wt-copy"
mkdir -p "$rootp/app-a/infra/terraform/.terraform" "$rootp/app-b/infra/terraform" \
         "$wtp/app-a/infra/terraform" "$wtp/app-b/infra/terraform" \
         "$w2/app-a/infra/terraform"
printf 'root-state\n' > "$rootp/app-a/infra/terraform/.terraform/terraform.tfstate"
printf 'project_id = "p"\n' > "$rootp/app-a/infra/terraform/terraform.tfvars"
printf 'lock-root\n' > "$rootp/app-a/infra/terraform/.terraform.lock.hcl"
printf 'lock-root\n' > "$rootp/app-b/infra/terraform/.terraform.lock.hcl"
printf '.terraform/\nterraform.tfvars\n.terraform.lock.hcl\n' > "$wtp/app-a/.gitignore"
printf 'lock-wt\n' > "$wtp/app-b/infra/terraform/.terraform.lock.hcl"
git init -q "$wtp/app-a"
git -C "$wtp/app-a" -c user.email=t@t -c user.name=t add .gitignore
git -C "$wtp/app-a" -c user.email=t@t -c user.name=t commit -qm gi
git init -q "$wtp/app-b"
git -C "$wtp/app-b" -c user.email=t@t -c user.name=t add -A
git -C "$wtp/app-b" -c user.email=t@t -c user.name=t commit -qm lock
cp -a "$wtp/app-a/.git" "$w2/app-a/.git"
cp "$wtp/app-a/.gitignore" "$w2/app-a/.gitignore"
( cd "$wtp" && bash -c 'source "$1"; provision_tf_local "$2" symlink' _ "$LIB" "$rootp" >/dev/null )
( cd "$wtp" && bash -c 'source "$1"; provision_tf_local "$2" symlink' _ "$LIB" "$rootp" >/dev/null )
[[ -L "$wtp/app-a/infra/terraform/.terraform" && "$(readlink "$wtp/app-a/infra/terraform/.terraform")" == "$rootp/app-a/infra/terraform/.terraform" ]] \
  && ok "TF symlink .terraform → root" || bad "TF symlink .terraform → root" "$(readlink "$wtp/app-a/infra/terraform/.terraform" 2>/dev/null)"
[[ "$(cat "$wtp/app-a/infra/terraform/.terraform/terraform.tfstate")" == "root-state" ]] \
  && ok "TF state readable through the link" || bad "TF state readable through the link"
[[ -L "$wtp/app-a/infra/terraform/terraform.tfvars" && -L "$wtp/app-a/infra/terraform/.terraform.lock.hcl" ]] \
  && ok "TF tfvars and lock linked" || bad "TF tfvars and lock linked"
[[ "$(grep -cxF '.terraform' "$wtp/app-a/.git/info/exclude")" == 1 ]] \
  && ok "TF exclude lists .terraform once" || bad "TF exclude lists .terraform once" "$(grep -c terraform "$wtp/app-a/.git/info/exclude")"
[[ ! -L "$wtp/app-b/infra/terraform/.terraform.lock.hcl" && "$(cat "$wtp/app-b/infra/terraform/.terraform.lock.hcl")" == "lock-wt" ]] \
  && ok "TF committed lock left in place" || bad "TF committed lock left in place"
( cd "$w2" && bash -c 'source "$1"; provision_tf_local "$2" copy' _ "$LIB" "$rootp" >/dev/null )
[[ ! -L "$w2/app-a/infra/terraform/.terraform" && "$(cat "$w2/app-a/infra/terraform/.terraform/terraform.tfstate")" == "root-state" ]] \
  && ok "TF copy is a real directory" || bad "TF copy is a real directory"

echo
echo "superset selftest: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
