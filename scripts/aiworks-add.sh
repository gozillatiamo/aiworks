#!/usr/bin/env bash
#
# aiworks-add.sh  (run it as: aiworks add) — onboard ONE new repo into the workspace.
#
# Runs the per-repo setup so the workspace agents (dev-cycle planner → developer →
# QA → reviewers → guardian/perf) can work the repo: registers it with mani, clones
# it, installs codegraph (https://github.com/colbymchenry/codegraph) if it's missing —
# machine-wide, once — then builds the codegraph index, installs the agent skill packs, seeds a hardcoded
# (sonar-free) hook + permission baseline, seeds a default coding-standards rule set
# (.claude/rules/coding_standards/ — backend or frontend flavor by the repo's stack), and —
# best-effort, via Claude — scaffolds a language-appropriate CLAUDE.md and scripts/dev.sh shaped
# by the repo's own anatomy.
#
# It is provider/stack-agnostic and IDEMPOTENT: anything already done/installed is
# SKIPPED and just reported. Steps that shell out to external tools (mani, codegraph,
# claude, npx) are BEST-EFFORT — a missing/erroring tool is logged as SKIPPED and the run
# continues, with a summary + manual follow-ups printed at the end.
#
# Usage:
#   aiworks add --url <git-url> [--product <id>] [options]
#
#   --url  <git-url>       Clone URL (git@github.com:org/your-app.git). Its REPO name
#                          (last URL segment, minus .git) is the clone dir + mani key, and
#                          identifies the repo's entry under products[].repos[].  [required]
#   --product <id>         Product this repo belongs to = its group under `products:` in
#                          workspace.config.yaml AND the mani.d/<product>.yaml file (repos
#                          of one product share both). Default: the repo name.
#   --lang <language>      Repo language (e.g. flutter, go, node). Becomes the 2nd tag and
#                          steers the scripts/dev.sh scaffold. Default: auto-detected from
#                          the repo's anatomy once cloned.
#   --tags <a,b,…>         EXTRA tags, appended after [product, language] in the mani entry
#                          (e.g. "ui,offline"). Default: none.
#   --desc <text>          one-line repo responsibility — explains the repo's anatomy/role. Written
#                          to the mani entry (desc:) AND, when given, back into workspace.config.yaml
#                          (desc:) for round-tripping. Default (mani only): "The <repo-name> repo.".
#   --kind <kind>          repo kind — a free-form, tech-agnostic dev-context label (frontend,
#                          backend, web-app, service, migration, generic, …; the tech goes in
#                          --lang). Only 'test-suite' is special (QA archetype); any other kind
#                          is a code repo (plan→build→review + guard/perf). Default: generic.
#                          (default: generic) — drives the plan/build/review/guard/perf/test-suite defaults.
#   --distribute <how>     workspace.config.yaml distribute: none | firebase | custom (default: none).
#   --app-id <id>          MOBILE APP REPOS ONLY — application/bundle id (e.g. com.acme.app), written
#                          to workspace.config.yaml app_id:. The QA/automation skills read it as the
#                          app-under-test id. (optional; omit for non-mobile repos)
#   --path <dir>           Clone dir under the workspace root (default: the repo name from --url).
#   --skill-cmd <slash>    Skill-generator command to run in the repo (default: /run-skill-generator).
#                          It's told to make the generated run skill a thin wrapper over
#                          `scripts/dev.sh run` (step 10) rather than re-derive how to run.
#   --claude-timeout <s>   Per-step timeout (seconds) for each headless `claude` call so a hung
#                          step can't stall the run (default: 900; 0 disables; needs timeout/gtimeout).
#   --safe-perms           Run the headless `claude` steps with --permission-mode acceptEdits
#                          instead of the default --dangerously-skip-permissions.
#   --force                Re-clone / re-seed hooks / regenerate dev.sh + CLAUDE.md if present.
#   -y, --yes              Don't prompt; assume yes (and, for an existing CLAUDE.md, skip).
#   -v, --verbose          Show the full step-by-step log. Output is QUIET by default — only
#                          warnings and the closing onboarding summary print.
#   -h, --help             Show this help.
#
set -uo pipefail   # NOT -e: this script is best-effort and summarizes failures itself.

# ── pretty logging ────────────────────────────────────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
DONE=(); SKIPPED=(); FOLLOWUP=(); SUMMARY_DONE=0
TOK_IN=0; TOK_OUT=0; TOK_CR=0; TOK_CW=0; TOK_COST=0   # accumulated Claude usage across the run
CLAUDE_RC=0; CLAUDE_UNDER_TIMEOUT=0                    # last claude_run's exit status + whether it ran under `timeout`
# QUIET by default: step/ok/skip/glance print only with -v/--verbose (VERBOSE=1, set in arg
# parsing below). They STILL record into DONE/SKIPPED so print_summary — which always prints —
# carries the full picture. warn/die ALWAYS print. So a quiet run shows only warnings + the
# closing onboarding summary (the conclusion); -v restores the full step-by-step log.
VERBOSE=0
step()  { [[ "$VERBOSE" -eq 1 ]] && printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; return 0; }
ok()    { [[ "$VERBOSE" -eq 1 ]] && printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; DONE+=("$*"); return 0; }
warn()  { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
skip()  { [[ "$VERBOSE" -eq 1 ]] && printf '    %s⤼ SKIP: %s%s\n' "$c_warn" "$*" "$c_off"; SKIPPED+=("$*"); return 0; }
glance(){ [[ "$VERBOSE" -eq 1 ]] && printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; return 0; }
die()   { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
# A repo is codegraph-"initialized" only when the graph DB exists — a bare .codegraph/ dir
# (just its .gitignore, e.g. from an interrupted init) is NOT initialized and `codegraph sync`
# rejects it. Both the init (step 4) and sync (step 10.6) steps gate on THIS, so they agree.
cg_indexed() { local f; for f in "$1"/.codegraph/*.db; do [[ -e "$f" ]] && return 0; done; return 1; }

# ── codegraph: install it once if missing ───────────────────────────────────────
# codegraph (https://github.com/colbymchenry/codegraph) builds the per-repo index the
# build/review agents grep through. It's a MACHINE-WIDE CLI — installed once, not per repo —
# so this is a no-op whenever it's already on PATH (and after the first repo in a sync).
# Prefer npm (any Node, all platforms); fall back to the bundled installer (curl … | sh —
# vendored runtime, no Node needed), which drops the binary in ~/.local/bin WITHOUT editing
# PATH, so we surface that dir on PATH for the in-session re-check + the init/sync steps that
# follow. Best-effort: a failed install just leaves `have codegraph` false and the caller
# SKIPs the index step. Prints nothing when codegraph is already present; otherwise emits its
# glance/ok/skip lines nested under whatever step() called it (no header of its own). Sets
# CG_INSTALL_TRIED so the two codegraph touchpoints (step 4 + 10.6) don't double-install.
CG_INSTALL_TRIED=0
ensure_codegraph() {
  have codegraph && return 0
  [[ "$CG_INSTALL_TRIED" -eq 1 ]] && return 1
  CG_INSTALL_TRIED=1
  if have npm; then
    glance "codegraph not on PATH — installing (npm i -g @colbymchenry/codegraph)"
    npm i -g @colbymchenry/codegraph >/dev/null 2>&1 || true
  fi
  if ! have codegraph && have curl; then
    glance "codegraph not on PATH — installing (bundled installer: curl … | sh)"
    curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh >/dev/null 2>&1 || true
  fi
  # The bundled installer symlinks the binary into ~/.local/bin (or $CODEGRAPH_BIN_DIR) but
  # does NOT edit PATH — surface it for THIS process so the re-check + init/sync below find it.
  local cg_bin="${CODEGRAPH_BIN_DIR:-$HOME/.local/bin}"
  if [[ -x "$cg_bin/codegraph" ]]; then case ":$PATH:" in *":$cg_bin:"*) ;; *) export PATH="$cg_bin:$PATH" ;; esac; fi
  if have codegraph; then ok "codegraph installed ($(command -v codegraph))"; return 0
  else skip "could not install codegraph automatically (need npm or curl + network) — install it by hand: https://github.com/colbymchenry/codegraph"; return 1; fi
}

# ── classify a spawned child's exit status: a SIGNAL-kill ≠ a genuine failure ───
# On some machines (memory pressure, an EDR/security agent) a freshly-spawned binary (node,
# codegraph, npx, claude) is KILLED BY A SIGNAL on launch — SIGSEGV=139, SIGTRAP=133,
# SIGABRT=134, i.e. ANY exit status >=128 (sig = status-128). That's a transient, machine-side
# CRASH — NOT a config/auth/input problem on our side — so every spawn site reports it as a
# crash via these helpers instead of a misleading SKIP/auth hint. `timeout` muddies this (it
# wraps claude_run's child): it returns 124 on timeout and 128+sig (137 KILL / 143 TERM) when
# its own grace-kill fires — so pass a 2nd arg of 1 for a child run under `timeout`, and those
# count as a timeout, not a machine crash.
classify_rc() {   # <rc> [under_timeout] → echoes: ok | timeout | signal | fail
  local rc="$1" under_to="${2:-0}"
  if   [[ "$rc" -eq 0   ]]; then echo ok
  elif [[ "$rc" -eq 124 ]]; then echo timeout
  elif [[ "$under_to" -eq 1 && ( "$rc" -eq 137 || "$rc" -eq 143 ) ]]; then echo timeout
  elif [[ "$rc" -ge 128 ]]; then echo signal
  else echo fail
  fi
}
describe_rc() {   # <rc> [under_timeout] → a short human phrase for a SKIP/retry message
  local rc="$1" under_to="${2:-0}"
  case "$(classify_rc "$rc" "$under_to")" in
    signal)  printf 'CRASHED (killed by signal %d — likely memory pressure or a security agent on this machine, not a config problem)' "$((rc - 128))" ;;
    timeout) printf 'timed out' ;;
    *)       printf 'failed (exit %d)' "$rc" ;;
  esac
}
# claude-step specialization: a failed claude_run reads CLAUDE_RC / CLAUDE_UNDER_TIMEOUT (set
# by the last claude_run) so callers stay one-liners. The optional arg is the hint shown only
# for a GENUINE non-zero exit (1..127) — a signal-kill or timeout never implies auth/config.
CLAUDE_AUTH_HINT="auth? run 'claude' once interactively to log in"
claude_fail_hint() {   # [genuine-failure-hint]
  local fail_hint="${1:-$CLAUDE_AUTH_HINT}"
  case "$(classify_rc "${CLAUDE_RC:-1}" "${CLAUDE_UNDER_TIMEOUT:-0}")" in
    signal)  printf 'CRASHED — killed by signal %d (likely memory pressure or a security agent on this machine, not an auth/config problem); re-run to retry' "$((CLAUDE_RC - 128))" ;;
    timeout) printf 'timed out after %ss — re-run, or raise --claude-timeout' "${CLAUDE_TIMEOUT:-?}" ;;
    *)       printf 'failed (exit %d) — %s' "${CLAUDE_RC:-1}" "$fail_hint" ;;
  esac
}

# Ask on the CONTROLLING TERMINAL (/dev/tty), not stdin — so a prompt still works even when
# stdin is a pipe or has been consumed by a child. Sets REPLY. Returns 0 if it asked, 1 if
# there's no tty or --yes was given (caller then uses its own default). This is why step 7's
# choice survives the headless `claude` steps that run before it.
ask() {
  REPLY=""
  [[ "${YES:-0}" -eq 1 ]] && return 1
  { : > /dev/tty; } 2>/dev/null || return 1          # no controlling terminal → caller defaults
  printf '%s' "$1" > /dev/tty 2>/dev/null
  IFS= read -r REPLY < /dev/tty 2>/dev/null || return 1
  return 0
}

# Per-repo idempotency sentinels in the gitignored .aiworks/ state dir, for steps whose
# "already done" can't be reliably detected from the repo itself (the interactive Claude skills).
state_dir() { printf '%s/.aiworks' "$REPO_DIR"; }
is_done()   { [[ -f "$(state_dir)/$1.done" ]]; }
mark_done() { mkdir -p "$(state_dir)" 2>/dev/null && : > "$(state_dir)/$1.done"; }

# Ctrl+C / kill must stop the WHOLE run (not just abort the current step and continue). The
# claude pipeline runs inside `if …; then`, where a SIGINT-killed child is otherwise swallowed
# by bash, so we trap it explicitly and exit (the EXIT trap then prints the summary).
on_interrupt() { trap - INT TERM; printf '\n%s✗ interrupted — stopping%s\n' "$c_warn" "$c_off" >&2; exit 130; }
trap on_interrupt INT TERM

# Print the end-of-run summary. Armed as an EXIT trap (before step 1) so it ALWAYS runs —
# even if a later step aborts the script (a set -u unbound var exits immediately, ignoring
# the lack of set -e). Guarded so it prints at most once. Reads only top-level state.
print_summary() {
  [[ "${SUMMARY_DONE:-0}" -eq 1 ]] && return; SUMMARY_DONE=1
  # QUIET (default): a one-line conclusion + any follow-ups (the action items). The full Done/
  # Skipped breakdown + token usage + Next pointer are detail, shown only with -v/--verbose.
  if [[ "$VERBOSE" -ne 1 ]]; then
    printf '\n%s✓ %s onboarded%s (product %s) — done %d, skipped %d%s\n' \
      "$c_ok" "${REPO_NAME:-?}" "$c_off" "${PRODUCT:-?}" "${#DONE[@]}" "${#SKIPPED[@]}" \
      "$([[ "${#FOLLOWUP[@]}" -gt 0 ]] && printf ', %d follow-up(s)' "${#FOLLOWUP[@]}")"
    if [[ "${#FOLLOWUP[@]}" -gt 0 ]]; then
      printf '%sFollow-ups:%s\n' "$c_warn" "$c_off"
      for f in "${FOLLOWUP[@]}"; do printf '  • %s\n' "$f"; done
    fi
    return
  fi
  printf '\n%s──────── onboarding summary: %s (product %s) ────────%s\n' "$c_step" "${REPO_NAME:-?}" "${PRODUCT:-?}" "$c_off"
  printf '%sDone (%d):%s\n' "$c_ok" "${#DONE[@]}" "$c_off"; for d in "${DONE[@]:-}"; do [[ -n "$d" ]] && printf '  ✓ %s\n' "$d"; done
  if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
    printf '%sSkipped (%d) — already done or finish manually:%s\n' "$c_warn" "${#SKIPPED[@]}" "$c_off"
    for s in "${SKIPPED[@]}"; do printf '  ⤼ %s\n' "$s"; done
  fi
  if [[ "${#FOLLOWUP[@]}" -gt 0 ]]; then
    printf '%sFollow-ups:%s\n' "$c_warn" "$c_off"
    for f in "${FOLLOWUP[@]}"; do printf '  • %s\n' "$f"; done
  fi
  [[ $((TOK_IN + TOK_OUT + TOK_CR + TOK_CW)) -gt 0 ]] && printf '%sClaude usage this run:%s in=%d out=%d cache(r=%d w=%d)  total cost=$%s\n' "$c_step" "$c_off" "$TOK_IN" "$TOK_OUT" "$TOK_CR" "$TOK_CW" "$TOK_COST"
  # The dev-cycle.js CONFIG mirror is regenerated FROM workspace.config.yaml by step 2.6
  # (scripts/aiworks-config.sh) — there is nothing to paste by hand anymore.
  printf '%sNext:%s the .claude/workflows/dev-cycle.js CONFIG is auto-generated from workspace.config.yaml (regenerated at step 2.6; re-run `aiworks config` any time). Then `mani list projects`.\n' "$c_step" "$c_off"
}
# Append a literal line to a file iff absent. Returns 0 if it added it, 1 if already
# present. Guarantees the file ends in a newline first so lines never merge.
ensure_line() {
  local f="$1" line="$2"; touch "$f"
  grep -qxF "$line" "$f" && return 1
  [[ -s "$f" && -n "$(tail -c1 "$f")" ]] && printf '\n' >> "$f"
  printf '%s\n' "$line" >> "$f"
}

# Detect a repo's language from its anatomy (manifest files). Echoes a short token
# (flutter|node|go|rust|python|jvm) or '' if unknown. Used for the 2nd tag and dev.sh.
detect_lang() {
  local d="$1"
  if   [[ -f "$d/pubspec.yaml" ]]; then echo 'flutter'
  elif [[ -f "$d/package.json" ]]; then echo 'node'
  elif [[ -f "$d/go.mod" ]]; then echo 'go'
  elif [[ -f "$d/Cargo.toml" ]]; then echo 'rust'
  elif [[ -f "$d/pyproject.toml" || -f "$d/requirements.txt" || -f "$d/setup.py" ]]; then echo 'python'
  elif [[ -f "$d/pom.xml" || -f "$d/build.gradle" || -f "$d/build.gradle.kts" ]]; then echo 'jvm'
  else echo ''; fi
}

# Pick the default coding-standards FLAVOR for a repo from its kind + language: backend |
# frontend | "" (empty = no obvious flavor → seed nothing). The `kind` decides when it's
# explicit; otherwise the language does (so a `package`/`generic` repo still classifies by its
# stack — a Rust lib → backend, a Next.js lib → frontend). QA suites (cypress/newman/k6) and
# doc repos (markdown/json) match neither and get no standards. The templates these map to live
# in scripts/templates/coding-standards/<flavor>/ — backend ← the backend flavor,
# frontend ← the frontend flavor.
standards_flavor() {
  local kind lang
  kind="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  lang="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  case "$kind" in
    backend|service|api|migration) echo backend; return ;;
    web-app|webapp|frontend|ui)    echo frontend; return ;;
  esac
  case "$lang" in
    *rust*|go|*golang*|*jvm*|*java*|*kotlin*|*scala*|*postgres*|*sql*|*python*|py|*ruby*|*php*|*elixir*|*dotnet*|c#) echo backend ;;
    *next*|*nuxt*|*node*|*react*|*vue*|*svelte*|*angular*|*astro*|*solid*|*typescript*|ts|*javascript*|js) echo frontend ;;
    *) echo '' ;;
  esac
}

# Render a stream of glance lines as a fixed N-line "running log" window (like a docker
# build): keep only the last GLANCE_MAX lines, redrawn in place via cursor-up + clear-line.
# On a non-TTY there's no cursor control, so just stream the lines through.
GLANCE_MAX=5
render_glance() {
  if ! [[ -t 1 ]]; then cat; return; fi
  local cols; cols="$(tput cols 2>/dev/null || echo 120)"; [[ "$cols" =~ ^[0-9]+$ ]] || cols=120
  local -a buf=(); local printed=0 line x
  while IFS= read -r line; do
    line="${line:0:$((cols-1))}"                       # clip to terminal width (no wrap)
    buf+=("$line"); (( ${#buf[@]} > GLANCE_MAX )) && buf=("${buf[@]: -GLANCE_MAX}")
    (( printed > 0 )) && printf '\033[%dA' "$printed"   # move cursor to window top
    printed=0
    for x in "${buf[@]}"; do printf '\033[2K%s%s%s\n' "$c_dim" "$x" "$c_off"; printed=$((printed+1)); done
  done
}

# Run a headless `claude -p` with live "glance" logs (docker-build style, capped at a rolling
# GLANCE_MAX-line window) and a token-usage report. Streams NDJSON via --output-format
# stream-json --verbose; `fromjson? // empty` makes the jq renderer tolerant so a stray line
# never aborts it (and never SIGPIPEs claude). The claude call is wrapped in `timeout` (when
# available) so a hung step can't stall the whole run — on timeout it returns non-zero and the
# caller just SKIPs and continues. Falls back to a plain buffered run when jq is missing.
# Accumulates TOK_*. Returns claude's (or timeout's) rc.
claude_run() {
  local prompt="$1"; shift
  # `env` is a harmless no-op prefix so the array is never empty (set -u safe); swap in
  # timeout/gtimeout when present and a positive CLAUDE_TIMEOUT is set. CLAUDE_UNDER_TIMEOUT
  # records whether the child runs under `timeout` so the caller's classify_rc can tell a
  # timeout grace-kill (124 / 137 / 143) apart from a real machine crash (other 128+sig).
  local -a TO=(env)
  CLAUDE_UNDER_TIMEOUT=0
  if [[ "${CLAUDE_TIMEOUT:-0}" -gt 0 ]]; then
    if   have timeout;  then TO=(timeout  -k 10 "$CLAUDE_TIMEOUT"); CLAUDE_UNDER_TIMEOUT=1
    elif have gtimeout; then TO=(gtimeout -k 10 "$CLAUDE_TIMEOUT"); CLAUDE_UNDER_TIMEOUT=1; fi
  fi
  # stdin ← /dev/null: a headless `claude -p` must never read the terminal, or it eats the
  # keystrokes meant for our own prompts (step 7) and muddies Ctrl+C handling.
  if ! have jq; then
    "${TO[@]}" claude -p "$prompt" $PERM_FLAG "$@" </dev/null; CLAUDE_RC=$?; return "$CLAUDE_RC"
  fi
  local raw rc; raw="$(mktemp -t aiworks-claude.XXXXXX)"
  "${TO[@]}" claude -p "$prompt" --output-format stream-json --verbose $PERM_FLAG "$@" </dev/null 2>/dev/null \
    | tee "$raw" \
    | jq -rR --unbuffered '
        fromjson? // empty
        | if .type=="assistant" then
            ( [ .message.content[]?
                | if .type=="tool_use" then
                    ( "· " + .name
                      + ( (.input.command // .input.file_path // .input.path // .input.description // "")
                          | if (type=="string" and (.|length)>0) then " — " + (gsub("\n";" ")|.[0:60]) else "" end ) )
                  elif .type=="text" then
                    ( (.text|gsub("\n";" ")) | if (length>0) then "· " + .[0:78] else empty end )
                  else empty end ]
              | if (length>0) then ( map("      "+.) | join("\n") ) else empty end )
          else empty end' \
    | render_glance
  rc=${PIPESTATUS[0]}
  # Token usage = the run's own `result` event (what Claude Code itself reports for this
  # headless run): input/output + cache read/write + cost. The bulk is usually cache.
  local result_line; result_line="$(grep '"type":"result"' "$raw" 2>/dev/null | tail -1)"
  if [[ -n "$result_line" ]]; then
    local fields tin tout tcr tcw cost
    fields="$(printf '%s' "$result_line" | jq -r '[
        (.usage.input_tokens // 0), (.usage.output_tokens // 0),
        (.usage.cache_read_input_tokens // 0), (.usage.cache_creation_input_tokens // 0),
        (.total_cost_usd // 0)] | @tsv' 2>/dev/null)"
    IFS=$'\t' read -r tin tout tcr tcw cost <<<"$fields"
    [[ "$tin" =~ ^[0-9]+$ ]] || tin=0; [[ "$tout" =~ ^[0-9]+$ ]] || tout=0
    [[ "$tcr" =~ ^[0-9]+$ ]] || tcr=0; [[ "$tcw"  =~ ^[0-9]+$ ]] || tcw=0; [[ -n "$cost" ]] || cost=0
    printf '    %s↻ tokens: in=%s out=%s cache(r=%s w=%s)  cost=$%s%s\n' "$c_step" "$tin" "$tout" "$tcr" "$tcw" "$cost" "$c_off"
    TOK_IN=$((TOK_IN+tin)); TOK_OUT=$((TOK_OUT+tout)); TOK_CR=$((TOK_CR+tcr)); TOK_CW=$((TOK_CW+tcw))
    TOK_COST="$(awk -v a="$TOK_COST" -v b="$cost" 'BEGIN{printf "%.4f", a+b}')"
  fi
  rm -f "$raw"
  CLAUDE_RC="$rc"
  return "$rc"
}

# ── args ────────────────────────────────────────────────────────────────────
PRODUCT="" URL="" TAGS="" DESC="" PATH_REL="" LANG="" SKILL_CMD="/run-skill-generator"
KIND="generic" DISTRIBUTE="none" APP_ID="" CLAUDE_TIMEOUT=900
FORCE=0 YES=0 PERM_FLAG="--dangerously-skip-permissions"
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --product)         PRODUCT="${2:-}"; shift 2 ;;
    --url)             URL="${2:-}"; shift 2 ;;
    --lang)            LANG="${2:-}"; shift 2 ;;
    --tags)            TAGS="${2:-}"; shift 2 ;;
    --desc)            DESC="${2:-}"; shift 2 ;;
    --kind)            KIND="${2:-}"; shift 2 ;;
    --distribute)      DISTRIBUTE="${2:-}"; shift 2 ;;
    --app-id)          APP_ID="${2:-}"; shift 2 ;;
    --path)            PATH_REL="${2:-}"; shift 2 ;;
    --skill-cmd)       SKILL_CMD="${2:-}"; shift 2 ;;
    --claude-timeout)  CLAUDE_TIMEOUT="${2:-}"; shift 2 ;;
    --safe-perms)      PERM_FLAG="--permission-mode acceptEdits"; shift ;;
    --force)           FORCE=1; shift ;;
    -y|--yes)          YES=1; shift ;;
    -v|--verbose)      VERBOSE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown argument: $1   (see -h)" ;;
  esac
done
[[ -n "$URL" ]] || die "--url is required (the clone URL)"
# The clone DIR + mani KEY + workspace.config id all come from the repo's own name (last
# URL path segment, minus .git). Handles scp form (git@host:org/repo.git) and https URLs.
REPO_NAME="${URL%.git}"; REPO_NAME="${REPO_NAME##*/}"; REPO_NAME="${REPO_NAME##*:}"
[[ -n "$REPO_NAME" ]] || die "could not derive a repo name from --url '$URL'"

# Defaults derived from the repo name.
[[ -n "$PRODUCT" ]]  || PRODUCT="$REPO_NAME"          # product = repo name unless --product given
[[ -n "$PATH_REL" ]] || PATH_REL="$REPO_NAME"          # clone DIR = repo name (override with --path)
if [[ -n "$DESC" ]]; then DESC_GIVEN=1                  # an explicit --desc is written back to the config
else DESC="The $REPO_NAME repo."; DESC_GIVEN=0; fi      # default desc = repo-name short description (mani only)

# ── locate the workspace root (where mani.yaml lives) ──────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || die "cannot cd to workspace root"
[[ -f "$ROOT/mani.yaml" ]] || die "no mani.yaml in $ROOT — run this from a workspace (next to mani.yaml)"
REPO_DIR="$ROOT/$PATH_REL"
MANI_FILE="$ROOT/mani.d/$PRODUCT.yaml"
WC="$ROOT/workspace.config.yaml"

# Language: --lang wins; otherwise detect from the repo's anatomy if it's already cloned
# (first run won't have it yet — then it's left blank here and re-detected for dev.sh).
[[ -n "$LANG" ]] || { [[ -d "$REPO_DIR" ]] && LANG="$(detect_lang "$REPO_DIR")"; }

# Tags written to the mani entry = [PRODUCT, LANGUAGE, …extra --tags] (in that order).
# --tags is purely supplemental now; product/language lead the list.
IFS=',' read -r -a _extra <<<"$TAGS"
tags_list=("$PRODUCT"); [[ -n "$LANG" ]] && tags_list+=("$LANG")
for t in "${_extra[@]:-}"; do
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"   # trim
  [[ -n "$t" ]] && tags_list+=("$t")
done
tags_yaml=""; for t in "${tags_list[@]}"; do tags_yaml+="${tags_yaml:+, }$t"; done

[[ "$PRODUCT" =~ ^[A-Za-z0-9._-]+$ ]]   || die "product name '$PRODUCT' (--product) must be a simple id"
[[ "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "repo name '$REPO_NAME' from the URL is not a simple id"
[[ "$PATH_REL" =~ ^[A-Za-z0-9._/-]+$ ]] || die "repo/dir name '$PATH_REL' is not a simple dir path — pass --path"
[[ "$CLAUDE_TIMEOUT" =~ ^[0-9]+$ ]]     || CLAUDE_TIMEOUT=900

# `kind` is a FREE-FORM, tech-agnostic dev-context label (frontend, backend, web-app, service,
# migration, generic, …) — the tech is captured by --lang. Behaviour is by ARCHETYPE: 'test-suite'
# selects the QA pipeline (qa-planner/qa-runner, no code review, provides the cross-repo test-suite
# gate); EVERY other kind is a "code" repo (plan→build→review + guard/perf). The kind→defaults
# mapping lives in ONE place — scripts/aiworks-config.sh — applied when the dev-cycle.js CONFIG is
# regenerated at the end of this run (step 2.6). Here we only note which archetype the kind selects.
case "$KIND" in
  test-suite)  glance "kind \"$KIND\" → QA archetype (qa-runner builds the suite; no code review)" ;;
  ''|generic)  ;;
  *)           glance "kind \"$KIND\" → code repo (plan→build→review + guard/perf); tune via green/guardian_focus" ;;
esac

# Intro banner — verbose-only chatter (the closing summary restates repo + product).
if [[ "$VERBOSE" -eq 1 ]]; then
  printf '%sOnboarding repo "%s" → product "%s"  (dir: %s/, lang: %s)%s\n' "$c_step" "$REPO_NAME" "$PRODUCT" "$PATH_REL" "${LANG:-auto}" "$c_off"
  printf '  url=%s  tags=[%s]\n  workspace root=%s\n' "$URL" "$tags_yaml" "$ROOT"
fi
if [[ "$YES" -ne 1 && -t 0 ]]; then
  read -r -p "Proceed? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"
fi

# From here on, always print the summary on the way out — even if a later step aborts the
# script (set -u errors exit immediately; this guarantees the user still sees what got done).
trap print_summary EXIT

# ── 1. mani.d/<product>.yaml — one file per PRODUCT; entry keyed by REPO name ────
# Multiple repos of the same product share one mani.d file, so a new repo APPENDS its
# entry block (keyed by the repo name) rather than overwriting.
step "1. Register project '$REPO_NAME' in mani.d/$PRODUCT.yaml"
mkdir -p "$ROOT/mani.d"
printf -v mani_entry '  %s:\n    desc: %s\n    url: %s\n    path: ../%s\n    tags: [%s]\n' \
  "$REPO_NAME" "$DESC" "$URL" "$PATH_REL" "$tags_yaml"
if [[ -f "$MANI_FILE" ]] && grep -qE "^[[:space:]][[:space:]]$REPO_NAME:[[:space:]]*$" "$MANI_FILE"; then
  skip "1. mani.d/$PRODUCT.yaml already lists project '$REPO_NAME'"
elif [[ -f "$MANI_FILE" ]] && grep -qE '^projects:' "$MANI_FILE"; then
  if MANI_ENTRY="$mani_entry" awk '{print} /^projects:[[:space:]]*$/ && !d {printf "%s", ENVIRON["MANI_ENTRY"]; d=1}' "$MANI_FILE" > "$MANI_FILE.tmp" && mv "$MANI_FILE.tmp" "$MANI_FILE"; then
    ok "added project '$REPO_NAME' to existing mani.d/$PRODUCT.yaml"
  else skip "1. could not edit mani.d/$PRODUCT.yaml — add the '$REPO_NAME' project block by hand"; fi
elif [[ -f "$MANI_FILE" ]]; then
  printf 'projects:\n%s' "$mani_entry" >> "$MANI_FILE" && ok "added projects: + '$REPO_NAME' to mani.d/$PRODUCT.yaml"
else
  printf '# %s — mani projects. path is relative to THIS file dir (mani.d/), so ../%s resolves under the workspace root.\nprojects:\n%s' \
    "$PRODUCT" "$PATH_REL" "$mani_entry" > "$MANI_FILE" && ok "wrote mani.d/$PRODUCT.yaml (project '$REPO_NAME')"
fi

# ── 2. import into mani.yaml ──────────────────────────────────────────────────
step "2. Import mani.d/$PRODUCT.yaml from mani.yaml"
import_line="  - mani.d/$PRODUCT.yaml"
if grep -qE "^[[:space:]]*-[[:space:]]*mani\.d/$PRODUCT\.yaml[[:space:]]*$" mani.yaml; then
  skip "2. import already present in mani.yaml"
elif grep -qE '^import:' mani.yaml; then
  awk -v ins="$import_line" '{print} /^import:[[:space:]]*$/ && !d {print ins; d=1}' mani.yaml > mani.yaml.tmp \
    && mv mani.yaml.tmp mani.yaml && ok "added import to mani.yaml" || skip "2. could not edit mani.yaml — add '$import_line' by hand"
else
  printf 'import:\n%s\n\n%s\n' "$import_line" "$(cat mani.yaml)" > mani.yaml.tmp \
    && mv mani.yaml.tmp mani.yaml && ok "created import: block in mani.yaml"
fi

# ── 2.5. register in workspace.config.yaml under products[<product>].repos[] ───
# The config is the SOURCE OF TRUTH: a repo is one entry (url + kind, plus optional
# lang/distribute/path) nested under its product. `aiworks sync` reads exactly this.
# kind drives the role/gate defaults (derived in the dev-cycle.js mirror, not stored here),
# so the entry stays minimal — add green/guardian_focus only to OVERRIDE the kind default.
step "2.5. Register the repo in workspace.config.yaml (products[$PRODUCT].repos[])"
if [[ ! -f "$WC" ]]; then
  if [[ -f "$ROOT/workspace.config.example.yaml" ]]; then
    cp "$ROOT/workspace.config.example.yaml" "$WC" && ok "created workspace.config.yaml from workspace.config.example.yaml"
    FOLLOWUP+=("fill in workspace.config.yaml (org/product, vcs/tracker providers, ticket_prefix, statuses) — it was seeded from the example; the placeholder product block can be deleted")
  else
    printf '# workspace.config.yaml — the source of truth for this workspace.\nproducts:\n' > "$WC" && ok "created a minimal workspace.config.yaml (products: only)"
    FOLLOWUP+=("flesh out workspace.config.yaml (org/product, vcs/tracker providers, ticket_prefix, statuses) — only a products: block was created")
  fi
fi
# Build the minimal repo block (6/8-space indented). Optional fields only when meaningful.
repo_block="      - url: $URL"$'\n'"        kind: $KIND"$'\n'
[[ "$DESC_GIVEN" -eq 1 ]]                     && repo_block+="        desc: $DESC"$'\n'
[[ -n "$LANG" ]]                              && repo_block+="        lang: $LANG"$'\n'
[[ -n "$APP_ID" ]]                            && repo_block+="        app_id: $APP_ID"$'\n'
[[ -n "$DISTRIBUTE" && "$DISTRIBUTE" != none ]] && repo_block+="        distribute: $DISTRIBUTE"$'\n'
[[ "$PATH_REL" != "$REPO_NAME" ]]             && repo_block+="        path: $PATH_REL"$'\n'
if grep -qF "url: $URL" "$WC"; then
  skip "2.5. workspace.config.yaml already declares $URL"
elif grep -qE "^  - id:[[:space:]]*$PRODUCT[[:space:]]*$" "$WC"; then
  # Product block exists → insert the repo as the first item under its repos: line.
  if REPO_BLOCK="$repo_block" awk -v P="$PRODUCT" '
        {print}
        $0 ~ ("^  - id:[ \t]*" P "[ \t]*$") { intgt=1; next }
        intgt && /^  - id:/ { intgt=0 }
        intgt && /^    repos:[ \t]*$/ && !ins { printf "%s", ENVIRON["REPO_BLOCK"]; ins=1 }
        END{ exit (ins?0:3) }' "$WC" > "$WC.tmp" && mv "$WC.tmp" "$WC"; then
    ok "added repo '$REPO_NAME' (kind $KIND) under products[$PRODUCT] in workspace.config.yaml"
  else
    rm -f "$WC.tmp"
    skip "2.5. product '$PRODUCT' has no repos: line — add this block under it by hand:"; printf '%s' "$repo_block"
  fi
elif grep -qE '^products:[[:space:]]*$' "$WC"; then
  # products: exists but this product doesn't → append a new product block at EOF.
  [[ -s "$WC" && -n "$(tail -c1 "$WC")" ]] && printf '\n' >> "$WC"
  printf '  - id: %s\n    repos:\n%s' "$PRODUCT" "$repo_block" >> "$WC" \
    && ok "added new product '$PRODUCT' (+ repo '$REPO_NAME') to workspace.config.yaml"
else
  # no products: block at all → create it at EOF.
  [[ -s "$WC" && -n "$(tail -c1 "$WC")" ]] && printf '\n' >> "$WC"
  printf 'products:\n  - id: %s\n    repos:\n%s' "$PRODUCT" "$repo_block" >> "$WC" \
    && ok "created products: block in workspace.config.yaml (product '$PRODUCT', repo '$REPO_NAME')"
fi

# ── 2.6. regenerate the dev-cycle workflow CONFIG from workspace.config.yaml ────
# The workflow can't read the FS at runtime, so it carries an in-source mirror of the config.
# Now that the repo is in workspace.config.yaml, regenerate that mirror — no hand-paste needed.
step "2.6. Regenerate the dev-cycle.js CONFIG from workspace.config.yaml"
GEN="$(cd "$(dirname "$0")" && pwd)/aiworks-config.sh"
if [[ -x "$GEN" ]]; then
  if out="$("$GEN" -q 2>&1)"; then ok "dev-cycle.js CONFIG mirrors workspace.config.yaml (no manual paste needed)"
  else skip "2.6. could not regenerate dev-cycle.js CONFIG — run 'aiworks config' by hand. Detail: ${out}"; fi
else
  skip "2.6. aiworks-config.sh not found next to aiworks-add.sh — mirror dev-cycle.js by hand"
fi

# ── 2.7. ensure the workspace lifecycle hooks (.superset/{setup,run,teardown}) cover this repo ─
# The hooks are workspace-level and DYNAMIC — each loops over every cloned repo — so the new repo
# is picked up with no per-repo edit. This just makes sure the trio EXISTS and config.json
# registers all three (it creates .superset/run.sh on workspaces that predate the run hook). See
# scripts/aiworks-superset.sh.
step "2.7. Ensure .superset lifecycle hooks (setup/run/teardown) cover every repo"
SUPGEN="$(cd "$(dirname "$0")" && pwd)/aiworks-superset.sh"
if [[ -x "$SUPGEN" ]]; then
  if out="$("$SUPGEN" -q 2>&1)"; then ok "lifecycle hooks present; config.json registers setup/run/teardown${out:+ — $out}"
  else skip "2.7. could not ensure .superset hooks — run 'aiworks-superset.sh' by hand. Detail: ${out}"; fi
else
  skip "2.7. aiworks-superset.sh not found next to aiworks-add.sh — ensure .superset/{setup,run,teardown}.sh by hand"
fi

# ── 3. clone via mani + 3.1 gitignore ─────────────────────────────────────────
step "3. Clone the repo (mani sync)"
if ! have mani; then
  skip "3. 'mani' not installed (brew install mani) — clone $URL → $PATH_REL/ yourself, then re-run"
elif [[ -e "$REPO_DIR/.git" && "$FORCE" -ne 1 ]]; then
  skip "3. $PATH_REL/ already cloned"
else
  if mani sync; then ok "mani sync done"; else skip "3. 'mani sync' failed — check the URL / your SSH access"; fi
fi

step "3.1. Ignore $PATH_REL/ in the workspace .gitignore"
if ensure_line "$ROOT/.gitignore" "$PATH_REL/"; then ok "added $PATH_REL/ to the workspace .gitignore"
else skip "3.1. workspace .gitignore already ignores $PATH_REL/"; fi

# ── 3.1.1. Cursor IDE indexing — re-include $PATH_REL/ so Cursor can search it ─────
#   The clone is gitignored at the workspace root (step 3.1) so it never dirties the
#   meta-repo — but Cursor honours .gitignore as a HARD baseline and would skip the whole
#   clone, leaving it unsearchable. A workspace-root .cursorindexingignore with a NEGATED
#   entry (`!$PATH_REL/`) is the one layer that re-includes a gitignored path for indexing
#   while keeping it git-ignored. (.cursorignore can't — its negations don't override
#   .gitignore.) Best-effort: Cursor's support for this has varied across versions. The
#   .cursorindexingignore is committed with the meta-repo, exactly like the .gitignore above.
step "3.1.1. Re-include $PATH_REL/ for Cursor indexing (.cursorindexingignore)"
ensure_line "$ROOT/.cursorindexingignore" "# Re-include repos the root .gitignore hides, so Cursor can index + search them." || true
if ensure_line "$ROOT/.cursorindexingignore" "!$PATH_REL/"; then ok "added !$PATH_REL/ to the workspace .cursorindexingignore"
else skip "3.1.1. workspace .cursorindexingignore already re-includes $PATH_REL/"; fi

# Re-detect the language now that the repo is (hopefully) cloned, so later steps + tags-in-
# hand have it even on a first run. (mani.d was already written; the tag is informational.)
[[ -n "$LANG" ]] || { [[ -d "$REPO_DIR" ]] && LANG="$(detect_lang "$REPO_DIR")"; }

# ── 3.1.2. VS Code search — make $PATH_REL/ searchable in VS Code (.vscode/settings.json) ─
#   Unlike Cursor, VS Code has no per-folder "un-gitignore". Its search honours .gitignore
#   (search.useIgnoreFiles defaults to true), so the gitignored clone is skipped in
#   project-wide search. We flip that off workspace-wide (so the clones ARE searchable) and
#   re-exclude the noise .gitignore used to hide: a small set of workspace-global **/ keys
#   plus this repo's LANGUAGE-DERIVED, repo-scoped build/output dirs (so `aiworks remove` can
#   strip exactly this repo's keys later). jq-merged so any hand-added settings are kept; the
#   .vscode/settings.json is committed with the meta-repo, like the .gitignore/.cursor* above.
step "3.1.2. Make $PATH_REL/ searchable in VS Code (.vscode/settings.json)"
if ! have jq; then
  skip "3.1.2. 'jq' missing — set \"search.useIgnoreFiles\":false + $PATH_REL/ build-dir excludes in .vscode/settings.json by hand"
  FOLLOWUP+=("add VS Code search settings for $PATH_REL/ to .vscode/settings.json (install jq to let aiworks do it)")
else
  vs_ex=()   # repo-scoped build/output dirs to keep out of search, by detected language
  case "$LANG" in
    flutter) vs_ex=( "$PATH_REL/build" "$PATH_REL/.dart_tool" "$PATH_REL/ios/Pods" "$PATH_REL/android/.gradle" ) ;;
    node)    vs_ex=( "$PATH_REL/dist" "$PATH_REL/coverage" "$PATH_REL/.expo" ) ;;
    go)      vs_ex=( "$PATH_REL/vendor" "$PATH_REL/bin" ) ;;
    rust)    vs_ex=( "$PATH_REL/target" ) ;;
    python)  vs_ex=( "$PATH_REL/.venv" "$PATH_REL/__pycache__" "$PATH_REL/.mypy_cache" "$PATH_REL/.pytest_cache" ) ;;
    jvm)     vs_ex=( "$PATH_REL/build" "$PATH_REL/.gradle" "$PATH_REL/target" ) ;;
  esac
  VS="$ROOT/.vscode/settings.json"; mkdir -p "$ROOT/.vscode"; [[ -f "$VS" ]] || printf '{}\n' > "$VS"
  if jq '
        .["search.useIgnoreFiles"] = false                       # VS Code search ignores .gitignore now…
        | .["search.exclude"] = ( (.["search.exclude"] // {})     # …so re-exclude the noise it used to hide
            + { "**/node_modules": true, "**/agent_logs": true, "**/.codegraph": true,
                "**/.aiworks": true, "**/.git": true }
            + (reduce $ARGS.positional[] as $g ({}; .[$g] = true)) )
      ' --args ${vs_ex[@]+"${vs_ex[@]}"} < "$VS" > "$VS.tmp" 2>/dev/null && mv "$VS.tmp" "$VS"; then
    ok "updated .vscode/settings.json (search.useIgnoreFiles=false + $PATH_REL/ build excludes)"
  else rm -f "$VS.tmp"; skip "3.1.2. could not merge .vscode/settings.json — add the search settings by hand"; fi
fi

# Everything below operates INSIDE the repo. Bail out of the per-repo steps cleanly
# (back to root) if the clone isn't actually there.
if [[ ! -d "$REPO_DIR" ]]; then
  skip "4-10.6. repo dir $PATH_REL/ not present — per-repo steps skipped (clone it, then re-run)"
  cd "$ROOT"
else
cd "$REPO_DIR" || die "cannot cd into $REPO_DIR"

# ── 3.1.5. git submodules — FIRST thing we do inside the freshly cloned repo. `mani sync`
#          does a plain clone, so any submodules land as empty dirs; pull them in BEFORE
#          codegraph (step 4) or the skill steps read the tree, so nested repos are present.
#          Gated on a tracked .gitmodules — a no-op for repos that declare no submodules. ──
step "3.1.5. Initialize git submodules (if any) in $PATH_REL/"
if [[ ! -f "$REPO_DIR/.gitmodules" ]]; then
  skip "3.1.5. $PATH_REL/ has no .gitmodules — no submodules to initialize"
elif ! have git; then
  skip "3.1.5. 'git' not installed — run 'git submodule update --init --recursive' in $PATH_REL/ later"
elif git submodule update --init --recursive; then
  ok "git submodules initialized (--init --recursive)"
else
  skip "3.1.5. 'git submodule update --init --recursive' failed — check submodule URLs / your SSH access"
fi

# ── 3.2. repo .gitignore — ignore agent_logs/ (agent plans / run summaries / bug logs,
#         incl. the dev.sh verbose logs in agent_logs/executed_verbose/) + .aiworks/ (this
#         tool's per-repo idempotency sentinels) + the codegraph daemon runtime files
#         (.codegraph/daemon.pid + .codegraph/codegraph.lock — machine-local, never committed) ──────────
step "3.2. Ignore agent_logs/ + .aiworks/ + codegraph runtime in $PATH_REL/.gitignore"
if ensure_line "$REPO_DIR/.gitignore" "agent_logs/"; then ok "added agent_logs/ to $PATH_REL/.gitignore"
else skip "3.2. $PATH_REL/.gitignore already ignores agent_logs/"; fi
if ensure_line "$REPO_DIR/.gitignore" ".aiworks/"; then ok "added .aiworks/ to $PATH_REL/.gitignore"
else skip "3.2. $PATH_REL/.gitignore already ignores .aiworks/"; fi
ensure_line "$REPO_DIR/.gitignore" "# codegraph" || true   # group header for the two runtime files below
if ensure_line "$REPO_DIR/.gitignore" ".codegraph/daemon.pid"; then ok "added .codegraph/daemon.pid to $PATH_REL/.gitignore"
else skip "3.2. $PATH_REL/.gitignore already ignores .codegraph/daemon.pid"; fi
if ensure_line "$REPO_DIR/.gitignore" ".codegraph/codegraph.lock"; then ok "added .codegraph/codegraph.lock to $PATH_REL/.gitignore"
else skip "3.2. $PATH_REL/.gitignore already ignores .codegraph/codegraph.lock"; fi

# ── 3.3. link the workspace adapters INTO this repo + hide the links from its git ──
#   Agents/skills run with cwd inside a repo and call the adapters by RELATIVE path
#   (scripts/tracker/… , scripts/vcs/…), but the real adapters live ONLY at the workspace
#   root — so we symlink them in (scripts/<a> → ../../scripts/<a>). Those links are
#   workspace-local plumbing that must NEVER dirty (or get committed to) the product repo,
#   so we also add them to THIS repo's .git/info/exclude — a LOCAL-ONLY ignore (per-clone,
#   never travels with the repo), NOT its tracked .gitignore. We exclude the two link names
#   exactly (no trailing slash — git treats a symlink-to-dir as a file, so `scripts/tracker/`
#   would NOT match it) and never `scripts/` as a whole (the repo's own scripts/dev.sh is
#   tracked). Idempotent: existing links and exclude lines are kept.
step "3.3. Link adapters (scripts/{tracker,vcs}) + hide them in $PATH_REL/.git/info/exclude"
mkdir -p scripts
exclude="$(git rev-parse --git-path info/exclude 2>/dev/null || echo .git/info/exclude)"
mkdir -p "$(dirname "$exclude")" 2>/dev/null || true
for a in tracker vcs; do
  if [[ -e "scripts/$a" || -L "scripts/$a" ]]; then skip "3.3. scripts/$a already present"
  elif ln -s "../../scripts/$a" "scripts/$a" 2>/dev/null; then ok "linked scripts/$a → ../../scripts/$a"
  else warn "could not link scripts/$a — link it by hand: (cd $PATH_REL && ln -s ../../scripts/$a scripts/$a)"; fi
  if ensure_line "$exclude" "scripts/$a"; then ok "git-excluded scripts/$a (local-only, never committed)"
  else skip "3.3. scripts/$a already in .git/info/exclude"; fi
done

# ── 4. codegraph index ────────────────────────────────────────────────────────
step "4. Initialize the codegraph index (in $PATH_REL/)"
ensure_codegraph || true   # install codegraph once if it's missing (no-op when already on PATH)
if ! have codegraph; then skip "4. 'codegraph' not installed — run 'codegraph init' in $PATH_REL/ later"
elif cg_indexed "$REPO_DIR" && [[ "$FORCE" -ne 1 ]]; then skip "4. .codegraph index already built"
else
  # quiet by default — swallow codegraph's own progress UI (keep stderr); -v shows it.
  if [[ "$VERBOSE" -eq 1 ]]; then codegraph init "$REPO_DIR"; else codegraph init "$REPO_DIR" >/dev/null; fi; cg_rc=$?   # recovers a bare/partial .codegraph/ too
  if [[ "$cg_rc" -eq 0 ]]; then ok "codegraph index built"
  else skip "4. 'codegraph init' $(describe_rc "$cg_rc") — re-run 'codegraph init $PATH_REL' to retry"; fi
fi

# ── 5. karpathy skills plugin — INSTALL **and ENABLE** at project scope ─────────
# `claude plugin install` only caches/registers the plugin; it does NOT write
# enabledPlugins to the project's .claude/settings.json — that needs `plugin enable`. And we
# must NOT guard on `claude plugin list` (it shows the plugin if it's installed at ANY scope,
# e.g. user scope, and would wrongly skip the project install). So: guard on THIS repo's
# settings.json, ensure the marketplace is registered, install + enable, then verify it landed.
kp_plugin="andrej-karpathy-skills@karpathy-skills"; kp_market="karpathy-skills"; kp_src="forrestchang/andrej-karpathy-skills"
step "5. Install + enable plugin $kp_plugin (project scope)"
kp_in_settings() { for f in "$REPO_DIR/.claude/settings.json" "$REPO_DIR/.claude/settings.local.json"; do [[ -f "$f" ]] && grep -q "$kp_plugin" "$f" && return 0; done; return 1; }
if ! have claude; then skip "5. 'claude' CLI not found — install+enable the karpathy plugin later"
elif kp_in_settings && [[ "$FORCE" -ne 1 ]]; then skip "5. $kp_plugin already enabled in this repo's settings"
else
  mkdir -p "$REPO_DIR/.claude"
  # Register the marketplace if it's missing (needed on a fresh machine/org).
  if ! claude plugin marketplace list 2>/dev/null | grep -q "$kp_market"; then
    claude plugin marketplace add "$kp_src" >/dev/null 2>&1 && glance "added marketplace $kp_market ($kp_src)" \
      || warn "could not add marketplace $kp_market — run: claude plugin marketplace add $kp_src"
  fi
  claude plugin install "$kp_plugin" --scope project >/dev/null 2>&1   # cache/register (no-op if already)
  claude plugin enable  "$kp_plugin" --scope project >/dev/null 2>&1   # writes enabledPlugins → settings.json
  if kp_in_settings; then ok "$kp_plugin installed + enabled (project scope; in settings.json)"
  else skip "5. install ran but $kp_plugin isn't in this repo's settings — enable by hand: (cd $PATH_REL && claude plugin enable $kp_plugin --scope project)"; fi
fi

# ── 6. mattpocock skills — PROJECT scope, one --skill per call ──────────────────
# The `skills` CLI selects a skill with a single `--skill <name>` (NOT a comma list — a CSV
# is taken as one bogus skill name), so install each skill in its own invocation. Already-
# present skills are skipped. Project scope is guaranteed by being inside the repo with a
# .claude/ marker + -y (no --global).
step "6. Install mattpocock skills — project scope (one per skill)"
mp_skills=(caveman grill-me grill-with-docs diagnose setup-matt-pocock-skills)
if ! have npx; then
  skip "6. 'npx' (Node) not found — run later, one per skill: npx skills@latest add mattpocock/skills --skill <name> -y"
else
  mkdir -p "$REPO_DIR/.claude"   # project marker so the CLI's scope auto-detect picks "project", not "global"
  installed=(); already=(); failed=(); crashed=()
  for s in "${mp_skills[@]}"; do
    if [[ -d "$REPO_DIR/.claude/skills/$s" && "$FORCE" -ne 1 ]]; then already+=("$s"); continue; fi
    npx -y skills@latest add mattpocock/skills --skill "$s" --agent '*' -y >/dev/null 2>&1; npx_rc=$?
    if   [[ "$npx_rc" -eq 0 ]]; then installed+=("$s")
    elif [[ "$(classify_rc "$npx_rc")" == signal ]]; then crashed+=("$s (signal $((npx_rc - 128)))")   # npx/node killed on launch, NOT an install failure
    else failed+=("$s"); fi
  done
  [[ "${#already[@]}"   -gt 0 ]] && skip "6. already present: ${already[*]}"
  [[ "${#installed[@]}" -gt 0 ]] && ok "installed mattpocock skills (project scope): ${installed[*]}"
  [[ "${#crashed[@]}"   -gt 0 ]] && skip "6. npx CRASHED (killed by a signal — likely memory pressure or a security agent on this machine, not an install problem): ${crashed[*]} — re-run 'aiworks add' to retry"
  [[ "${#failed[@]}"    -gt 0 ]] && skip "6. failed to install: ${failed[*]} — retry: npx skills@latest add mattpocock/skills --skill <name> -y"
fi

# ── 7. project knowledge (CLAUDE.md) — anatomy-driven, ≤60 lines + .claude/rules/ ─
# Keep CLAUDE.md lean; overflow goes into .claude/rules/<topic>.md with frontmatter. If a
# CLAUDE.md already exists, ask whether to regenerate / combine / skip (default: skip).
step "7. Scaffold project knowledge (CLAUDE.md)"
md_guidance="Constraint: keep CLAUDE.md to 60 lines MAX. If the project needs more guidance than fits, move details into .claude/rules/<topic>.md files — each starting with YAML frontmatter that has a 'description:' line (and, when the rule is path-specific, a 'paths:' list of glob patterns scoping it to matching files) — and keep CLAUDE.md a concise index that points to them."
init_prompt="Analyze THIS repository's anatomy (languages, build/test tooling, directory layout, conventions) and write a CLAUDE.md giving a future Claude Code session the essential working context: what the project is, the stack, how to build/test/run, key directories, and the conventions to follow. $md_guidance"
if ! have claude; then
  skip "7. 'claude' CLI not found — run /init in $PATH_REL/ later"
else
  do_init="fresh"
  if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then do_init="regenerate"
    elif ask "    CLAUDE.md already exists — [1] regenerate  [2] combine  [3] skip (default 3): "; then
      case "$REPLY" in 1) do_init="regenerate" ;; 2) do_init="combine" ;; *) do_init="skip" ;; esac
    else do_init="skip"; fi   # --yes or no controlling terminal → keep the existing file
  fi
  case "$do_init" in
    skip)        skip "7. CLAUDE.md already present — kept (chose skip)" ;;
    fresh)       glance "generating CLAUDE.md from the repo anatomy ..."
                 if claude_run "$init_prompt"; then ok "CLAUDE.md created"; else skip "7. /init $(claude_fail_hint)"; fi ;;
    regenerate)  glance "regenerating CLAUDE.md from scratch ..."
                 if claude_run "$init_prompt Overwrite the existing CLAUDE.md."; then ok "CLAUDE.md regenerated"; else skip "7. regenerate $(claude_fail_hint)"; fi ;;
    combine)     glance "merging into the existing CLAUDE.md ..."
                 if claude_run "Update the existing CLAUDE.md IN PLACE: keep all still-accurate content, fill gaps, fix staleness — do NOT discard the author's notes. $md_guidance"; then ok "CLAUDE.md combined"; else skip "7. combine $(claude_fail_hint)"; fi ;;
  esac
  # 60-line guard: if CLAUDE.md overflowed, nudge toward the .claude/rules/ split.
  if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    cm_lines="$(grep -c '' "$REPO_DIR/CLAUDE.md" 2>/dev/null || echo 0)"
    if [[ "$cm_lines" -gt 60 ]]; then
      warn "CLAUDE.md is $cm_lines lines (>60) — move detail into .claude/rules/<topic>.md (frontmatter: description/paths)"
      FOLLOWUP+=("trim $PATH_REL/CLAUDE.md ($cm_lines lines) to ≤60 and split detail into .claude/rules/")
    fi
  fi
fi

# ── 7.5. seed default coding-standards rules (.claude/rules/coding_standards/) ──
# Every new CODE repo starts with a lean, broadly-applicable standards baseline the team edits
# from — file-size cap, storytelling code (no in-body comments), deterministic date/time in
# tests. These are STATIC templates (no Claude call → deterministic, free), picked by the repo's
# FLAVOR: backend ← the backend flavor, frontend ← the frontend flavor. A repo with no
# flavor (QA suite, docs) is skipped. Idempotent like the other seeders: present → skip (keeps
# any team-authored rules), --force reseeds the two baseline files.
step "7.5. Seed default coding-standards rules (.claude/rules/coding_standards/)"
cs_flavor="$(standards_flavor "$KIND" "$LANG")"
cs_src="$ROOT/scripts/templates/coding-standards/$cs_flavor"
cs_dest="$REPO_DIR/.claude/rules/coding_standards"
if [[ -z "$cs_flavor" ]]; then
  skip "7.5. no backend/frontend flavor for kind '$KIND' / lang '${LANG:-?}' — no default standards seeded"
elif [[ ! -d "$cs_src" ]]; then
  skip "7.5. template store missing ($cs_src) — expected scripts/templates/coding-standards/$cs_flavor/*.md"
elif [[ -f "$cs_dest/standards.md" && "$FORCE" -ne 1 ]]; then
  skip "7.5. .claude/rules/coding_standards/ already present — kept (--force to reseed the baseline)"
elif mkdir -p "$cs_dest" && cp "$cs_src"/*.md "$cs_dest"/ 2>/dev/null; then
  ok "seeded $cs_flavor coding-standards baseline ($(cd "$cs_src" && printf '%s ' *.md)) into .claude/rules/coding_standards/"
else
  skip "7.5. could not copy $cs_flavor templates from $cs_src into $cs_dest"
fi

# ── 8. scaffold the matt-pocock per-repo config (NON-INTERACTIVE) ──────────────
# /setup-matt-pocock-skills (installed in step 6) is a PROMPT-DRIVEN skill whose default flow is
# explore → present findings → ASK THE USER → write. Run headless that "ask" step has no one to
# answer (stdin is /dev/null), so it exits 0 having written nothing — which is why a bare invocation
# always left step 8 asking for an interactive follow-up. So we DON'T invoke the bare slash command:
# we pass a self-contained NON-INTERACTIVE prompt that tells the headless run to skip the ask/confirm
# steps and write the artifacts directly with derived defaults (tracker ← git remote, canonical
# triage labels 1:1, single-context). Success is still judged by a real ARTIFACT (docs/agents/ or the
# '## Agent skills' block); the step is idempotent (once the artifact exists, later runs short-circuit)
# and a genuine miss simply RETRIES on the next sync — no manual step.
step "8. Scaffold matt-pocock per-repo config (/setup-matt-pocock-skills, non-interactive)"
# What proves the skill actually did its job:
mp_artifact() { [[ -d "$REPO_DIR/docs/agents" ]] || grep -qs '## Agent skills' "$REPO_DIR/CLAUDE.md" "$REPO_DIR/AGENTS.md"; }
# The headless override prompt. Quoted heredoc → no expansion/command-substitution (the backticks
# below are LITERAL); `read -d ''` returns non-zero at EOF but set -e is off, so it's safe (same
# pattern as BASE_SETTINGS in step 9).
read -r -d '' MP_PROMPT <<'EOF'
Run the /setup-matt-pocock-skills skill for THIS repository in NON-INTERACTIVE (headless) mode.
There is NO human available to answer questions and stdin is closed, so you MUST NOT ask for
confirmation or wait for input. SKIP the skill's "Present findings and ask" and "Confirm and edit"
steps entirely. Apply these defaults and WRITE the files directly:

- Issue tracker: inspect `git remote -v`. If the origin remote is GitLab, use the gitlab seed
  template; if GitHub, the github seed template; if there is no remote, the local-markdown seed
  template. Copy the matching template from the skill folder to docs/agents/issue-tracker.md.
- Triage labels: the five canonical roles mapped 1:1 to their default strings — write
  docs/agents/triage-labels.md from the seed template unchanged.
- Domain docs: single-context — write docs/agents/domain.md from the seed template.
- Add (or update in place) the "## Agent skills" block in CLAUDE.md if it exists, else AGENTS.md,
  else create CLAUDE.md. Never create the other file when one already exists.

Write all three docs/agents/*.md files and the "## Agent skills" block now. Do not ask — just write.
EOF
if ! have claude; then skip "8. 'claude' CLI not found"
elif [[ -d "$REPO_DIR/docs/agents" ]] && [[ "$FORCE" -ne 1 ]]; then
  skip "8. already done — docs/agents/ present"
elif grep -qs '## Agent skills' "$REPO_DIR/CLAUDE.md" "$REPO_DIR/AGENTS.md" && [[ "$FORCE" -ne 1 ]]; then
  skip "8. already done — '## Agent skills' block present in CLAUDE.md/AGENTS.md"
elif claude_run "$MP_PROMPT"; then
  if mp_artifact; then ok "/setup-matt-pocock-skills (non-interactive) scaffolded docs/agents/ + the '## Agent skills' block"
  else warn "8. /setup-matt-pocock-skills wrote no docs/agents/ or '## Agent skills' block — retries on the next sync (re-run with --force to retry now; was step 6 able to install it?)"; fi
else skip "8. /setup-matt-pocock-skills $(claude_fail_hint 'auth? was step 6 able to install it?')"; fi

# ── 9. hooks + permissions baseline (HARDCODED, sonar-free) ────────────────────
# No reference repo: the hooks come from the workspace's own .claude/hooks (the dev-wrapper,
# modeled on a Flutter app baseline minus sonar) and settings.json is written from a hardcoded, stack-
# agnostic, rtk-guarded baseline. We jq-MERGE settings so any plugin enablement added by
# steps 5/6 is preserved (never clobbered).
step "9. Seed Claude hooks + settings (hardcoded baseline, sonar-free)"
mkdir -p "$REPO_DIR/.claude"
# 9a. hooks/ — copy the workspace's hardcoded hooks (dev-wrapper).
if [[ -d "$REPO_DIR/.claude/hooks/dev-wrapper" && "$FORCE" -ne 1 ]]; then
  skip "9. .claude/hooks already present"
elif [[ -d "$ROOT/.claude/hooks" ]]; then
  cp -R "$ROOT/.claude/hooks" "$REPO_DIR/.claude/" \
    && find "$REPO_DIR/.claude/hooks" -name '*.sh' -exec chmod +x {} + 2>/dev/null
  ok "seeded .claude/hooks/ (dev-wrapper) from the workspace baseline"
else
  skip "9. no $ROOT/.claude/hooks to seed from — copy your hook scripts into $PATH_REL/.claude/hooks/ by hand"
fi
# 9b. settings.json — hardcoded baseline (modeled on a Flutter app, minus sonar), merged to keep plugins.
SETTINGS_FILE="$REPO_DIR/.claude/settings.json"
read -r -d '' BASE_SETTINGS <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "enabledMcpjsonServers": ["codegraph"],
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Read", "Grep", "Glob", "WebSearch", "WebFetch",
      "Bash(git *)", "Bash(scripts/dev.sh *)", "Bash(mkdir *)"
    ],
    "deny": [
      "Bash(rm -rf *)", "Bash(rm -fr *)",
      "Bash(git push --force *)", "Bash(git push -f *)",
      "Bash(git reset --hard *)", "Bash(git clean -fdx *)",
      "Bash(sudo *)", "Bash(curl * | sh)", "Bash(curl * | bash)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write", "hooks": [ { "type": "command", "command": "command -v rtk >/dev/null 2>&1 || exit 0; rtk codegraph sync" } ] },
      { "matcher": "Edit",  "hooks": [ { "type": "command", "command": "command -v rtk >/dev/null 2>&1 || exit 0; rtk codegraph sync" } ] },
      { "matcher": "Bash",  "hooks": [
          { "type": "command", "command": "command -v rtk >/dev/null 2>&1 || exit 0; rtk hook claude" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/dev-wrapper/pretool-steer-build.sh", "timeout": 30 }
      ] }
    ],
    "PostToolUse": [
      { "matcher": "Write", "hooks": [ { "type": "command", "command": "command -v rtk >/dev/null 2>&1 || exit 0; rtk codegraph sync" } ] },
      { "matcher": "Edit",  "hooks": [ { "type": "command", "command": "command -v rtk >/dev/null 2>&1 || exit 0; rtk codegraph sync" } ] },
      { "matcher": "Bash",  "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/dev-wrapper/posttool-output-warden.sh", "timeout": 30 } ] }
    ]
  }
}
JSON
if [[ -f "$SETTINGS_FILE" ]] && grep -q 'posttool-output-warden' "$SETTINGS_FILE" && [[ "$FORCE" -ne 1 ]]; then
  skip "9. .claude/settings.json already has the workspace hooks"
elif have jq; then
  # Merge base over existing (existing * base): base wins on hooks/permissions/env, while
  # any existing enabledPlugins (from steps 5/6) is preserved.
  existing="{}"; [[ -f "$SETTINGS_FILE" ]] && existing="$(cat "$SETTINGS_FILE")"
  if printf '%s\n%s\n' "$existing" "$BASE_SETTINGS" | jq -s '.[0] * .[1]' > "$SETTINGS_FILE.tmp" 2>/dev/null && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"; then
    ok "wrote .claude/settings.json (hardcoded sonar-free baseline; existing plugins preserved)"
  else rm -f "$SETTINGS_FILE.tmp"; skip "9. could not merge settings.json — add the hooks block by hand"; fi
elif [[ ! -f "$SETTINGS_FILE" ]]; then
  printf '%s\n' "$BASE_SETTINGS" > "$SETTINGS_FILE" && ok "wrote .claude/settings.json (hardcoded sonar-free baseline)"
else
  skip "9. settings.json exists and 'jq' is missing to merge safely — add the hooks block by hand (jq would preserve your plugin enablement)"
  FOLLOWUP+=("merge the workspace hook block into $PATH_REL/.claude/settings.json (install jq to let aiworks do it)")
fi

# ── 10. scaffold scripts/dev.sh from THIS repo's anatomy (best-effort, via Claude) ─
# No reference file: Claude inspects the repo's own structure/toolchain and implements the
# standard dev.sh contract for that stack.
step "10. Generate scripts/dev.sh from the repo's anatomy"
[[ -n "$LANG" ]] || LANG="$(detect_lang "$REPO_DIR")"
if ! have claude; then skip "10. 'claude' CLI not found — author scripts/dev.sh by hand"
elif [[ -f "$REPO_DIR/scripts/dev.sh" && "$FORCE" -ne 1 ]]; then skip "10. scripts/dev.sh already present"
else
  mkdir -p "$REPO_DIR/scripts"
  gen_prompt="Inspect THIS repo's anatomy (its build/test/run tooling, package manager, and layout${LANG:+; language: $LANG}) and create scripts/dev.sh implementing this fixed contract with the repo's OWN toolchain: subcommands test | gen | analyze | clean | run | restart | stop | status | why <name>. Each verbose subcommand writes its full log to agent_logs/executed_verbose/<cmd>-<timestamp>.log and prints only a concise one-line summary to stdout; 'why <name>' tails/greps the matching log for failure detail; 'status' shows the latest results. 'run' is the SINGLE SOURCE OF TRUTH for how to launch this repo: it builds if needed then launches/drives the app the repo's OWN way as a NON-INTERACTIVE agent path that proves it works and EXITS with a verdict (a server → start, poll a readiness/health check, report up/down, then tear down; a web app → build or start the dev server and confirm it serves; a CLI → a smoke invocation; a DB/migration repo → apply + verify; ANYTHING long-running MUST be backgrounded, polled for a ready marker, then stopped — never block forever), and it obeys the same verbose-log + one-line-summary rules as the others. When 'run' backgrounds a long-running instance it MUST record its PID (and port, if any) to a handle file under agent_logs/ (e.g. agent_logs/run.pid) so the instance can be found again. 'stop' reads that handle to tear down any instance 'run' left alive (kill the PID/process group, free the port, remove the handle), is idempotent, and reports stopped vs not-running. 'restart' = 'stop' then 'run' — a clean relaunch of the running instance — and obeys the same verbose-log + one-line-summary rules. After writing each run's log, prune the older logs for that command so only the most-recent N are kept (N from the DEV_LOG_KEEP env var, default 5; treat 0 or a non-numeric value as keep-all). POSIX bash, 'set -euo pipefail', a usage(), executable. Write ONLY scripts/dev.sh and chmod +x it — change nothing else."
  glance "scaffolding scripts/dev.sh (${LANG:-language inferred}) ..."
  if claude_run "$gen_prompt"; then
    [[ -f "$REPO_DIR/scripts/dev.sh" ]] && chmod +x "$REPO_DIR/scripts/dev.sh" 2>/dev/null
    ok "scripts/dev.sh scaffolded (${LANG:-language inferred}) — REVIEW it before relying on it"
    FOLLOWUP+=("review + test $PATH_REL/scripts/dev.sh (Claude-generated)")
  else skip "10. dev.sh generation $(claude_fail_hint)"; fi
fi

# ── 10.5 run the skill generator inside the repo ───────────────────────────────
# Idempotent: the generator writes a real skill dir under .claude/skills/ (the mattpocock
# skills there are SYMLINKS, so `-type d` matches only a generated skill). That, or our
# sentinel, means it already ran — SKIP (don't regenerate on every run).
#
# We FORCE the generated run skill to DELEGATE to `scripts/dev.sh run` (step 10) rather than
# re-derive how to build/launch the app — that derivation is the expensive part, dev.sh already
# owns it, and re-doing it burns tokens. The run skill stays a thin wrapper over dev.sh run.
step "10.5. Run the skill generator ($SKILL_CMD) in $PATH_REL/"
if ! have claude; then skip "10.5. 'claude' CLI not found — run $SKILL_CMD in $PATH_REL/ later"
elif { is_done step10_5-skillgen || [[ -n "$(find "$REPO_DIR/.claude/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)" ]]; } && [[ "$FORCE" -ne 1 ]]; then
  skip "10.5. a generated skill already exists in .claude/skills/ (or sentinel) — not re-running $SKILL_CMD"
else
  skill_prompt="$SKILL_CMD"
  if [[ -f "$REPO_DIR/scripts/dev.sh" ]]; then
    skill_prompt="$SKILL_CMD

This repo's scripts/dev.sh already has a 'run' subcommand that is the SINGLE SOURCE OF TRUTH for how to build, launch and drive this app (just generated for this exact stack). To stay lean on tokens, DO NOT re-derive how to run, and DO NOT build/launch the app yourself to discover it — trust scripts/dev.sh run. The generated run skill MUST be a THIN WRAPPER: its 'Run (agent path)' section simply invokes 'scripts/dev.sh run' (and points at 'scripts/dev.sh status' / 'scripts/dev.sh why run' for diagnosis). Do NOT write a separate driver script that duplicates dev.sh, and keep Prerequisites/Setup to the few lines dev.sh assumes."
  fi
  glance "running ${SKILL_CMD} ..."
  if claude_run "$skill_prompt"; then ok "$SKILL_CMD ran (delegates to scripts/dev.sh run)"; mark_done step10_5-skillgen
  else skip "10.5. $SKILL_CMD $(claude_fail_hint 'is the skill installed? override the name with --skill-cmd')"; fi
fi

# ── 10.6 sync the codegraph index (before leaving the repo) ─────────────────────
# Steps 6-10.5 generated files (CLAUDE.md, .claude/rules, settings.json, scripts/dev.sh,
# skills) AFTER the step-4 index build, so re-sync so the index reflects the final tree.
step "10.6. Sync the codegraph index (in $PATH_REL/)"
if ! have codegraph; then skip "10.6. 'codegraph' not installed — run 'codegraph sync $PATH_REL' later"
elif ! cg_indexed "$REPO_DIR"; then skip "10.6. no .codegraph index to sync (step 4 didn't build one) — run 'codegraph init $PATH_REL' first"
# quiet by default — swallow codegraph's own progress UI (keep stderr); -v shows it.
elif { [[ "$VERBOSE" -eq 1 ]] && codegraph sync "$REPO_DIR"; } || { [[ "$VERBOSE" -ne 1 ]] && codegraph sync "$REPO_DIR" >/dev/null; }; then ok "codegraph index synced"
else skip "10.6. 'codegraph sync' failed"; fi

# ── 11. back to the workspace root ─────────────────────────────────────────────
cd "$ROOT"
fi
step "11. Back at the workspace root ($ROOT)"

# ── summary ──────────────────────────────────────────────────────────────────────
# print_summary is defined near the top and armed as an EXIT trap before step 1, so the
# summary prints once at normal completion AND on any unexpected abort (e.g. a set -u error,
# which exits immediately regardless of set -e). Nothing more to do here.
print_summary
