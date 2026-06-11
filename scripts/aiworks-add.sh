#!/usr/bin/env bash
#
# aiworks-add.sh  (run it as: aiworks add) — onboard ONE new repo into the workspace.
#
# Runs the per-repo setup so the workspace agents (dev-cycle planner → developer →
# QA → reviewers → guardian/perf) can work the repo: registers it with mani, clones
# it, builds the codegraph index, installs the agent skill packs, seeds a hardcoded
# (sonar-free) hook + permission baseline, and — best-effort, via Claude — scaffolds a
# language-appropriate CLAUDE.md and scripts/dev.sh shaped by the repo's own anatomy.
#
# It is provider/stack-agnostic and IDEMPOTENT: anything already done/installed is
# SKIPPED and just reported. Steps that shell out to external tools (mani, codegraph,
# claude, npx) are BEST-EFFORT — a missing/erroring tool is logged as SKIPPED and the run
# continues, with a summary + manual follow-ups printed at the end.
#
# Usage:
#   aiworks add --url <git-url> [--product <id>] [options]
#
#   --url  <git-url>       Clone URL (git@github.com:org/feeedme-app.git). Its REPO name
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
#   --desc <text>          mani entry description (default: "The <repo-name> repo.").
#   --kind <kind>          repo kind — a free-form, tech-agnostic dev-context label (frontend,
#                          backend, web-app, service, migration, generic, …; the tech goes in
#                          --lang). Only 'test-suite' is special (QA archetype); any other kind
#                          is a code repo (plan→build→review + guard/perf). Default: generic.
#                          (default: generic) — drives the plan/build/review/guard/perf/test-suite defaults.
#   --distribute <how>     workspace.config.yaml distribute: none | firebase | custom (default: none).
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
#   -h, --help             Show this help.
#
set -uo pipefail   # NOT -e: this script is best-effort and summarizes failures itself.

# ── pretty logging ────────────────────────────────────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
DONE=(); SKIPPED=(); FOLLOWUP=(); SUMMARY_DONE=0
TOK_IN=0; TOK_OUT=0; TOK_CR=0; TOK_CW=0; TOK_COST=0   # accumulated Claude usage across the run
step()  { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()    { printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; DONE+=("$*"); }
warn()  { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
skip()  { printf '    %s⤼ SKIP: %s%s\n' "$c_warn" "$*" "$c_off"; SKIPPED+=("$*"); }
glance(){ printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()   { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
# A repo is codegraph-"initialized" only when the graph DB exists — a bare .codegraph/ dir
# (just its .gitignore, e.g. from an interrupted init) is NOT initialized and `codegraph sync`
# rejects it. Both the init (step 4) and sync (step 10.6) steps gate on THIS, so they agree.
cg_indexed() { local f; for f in "$1"/.codegraph/*.db; do [[ -e "$f" ]] && return 0; done; return 1; }

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
  # timeout/gtimeout when present and a positive CLAUDE_TIMEOUT is set.
  local -a TO=(env)
  if [[ "${CLAUDE_TIMEOUT:-0}" -gt 0 ]]; then
    if   have timeout;  then TO=(timeout  -k 10 "$CLAUDE_TIMEOUT")
    elif have gtimeout; then TO=(gtimeout -k 10 "$CLAUDE_TIMEOUT"); fi
  fi
  # stdin ← /dev/null: a headless `claude -p` must never read the terminal, or it eats the
  # keystrokes meant for our own prompts (step 7) and muddies Ctrl+C handling.
  if ! have jq; then
    "${TO[@]}" claude -p "$prompt" $PERM_FLAG "$@" </dev/null; return $?
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
  return "$rc"
}

# ── args ────────────────────────────────────────────────────────────────────
PRODUCT="" URL="" TAGS="" DESC="" PATH_REL="" LANG="" SKILL_CMD="/run-skill-generator"
KIND="generic" DISTRIBUTE="none" CLAUDE_TIMEOUT=900
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
    --path)            PATH_REL="${2:-}"; shift 2 ;;
    --skill-cmd)       SKILL_CMD="${2:-}"; shift 2 ;;
    --claude-timeout)  CLAUDE_TIMEOUT="${2:-}"; shift 2 ;;
    --safe-perms)      PERM_FLAG="--permission-mode acceptEdits"; shift ;;
    --force)           FORCE=1; shift ;;
    -y|--yes)          YES=1; shift ;;
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
[[ -n "$DESC" ]]     || DESC="The $REPO_NAME repo."    # default desc = repo-name short description

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
  test-suite)  printf '%s  kind "%s" → QA archetype (qa-runner builds the suite; no code review)%s\n' "$c_dim" "$KIND" "$c_off" ;;
  ''|generic)  ;;
  *)           printf '%s  kind "%s" → code repo (plan→build→review + guard/perf); tune via green/guardian_focus%s\n' "$c_dim" "$KIND" "$c_off" ;;
esac

printf '%sOnboarding repo "%s" → product "%s"  (dir: %s/, lang: %s)%s\n' "$c_step" "$REPO_NAME" "$PRODUCT" "$PATH_REL" "${LANG:-auto}" "$c_off"
printf '  url=%s  tags=[%s]\n  workspace root=%s\n' "$URL" "$tags_yaml" "$ROOT"
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
[[ -n "$LANG" ]]                              && repo_block+="        lang: $LANG"$'\n'
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

# Re-detect the language now that the repo is (hopefully) cloned, so later steps + tags-in-
# hand have it even on a first run. (mani.d was already written; the tag is informational.)
[[ -n "$LANG" ]] || { [[ -d "$REPO_DIR" ]] && LANG="$(detect_lang "$REPO_DIR")"; }

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
if ! have codegraph; then skip "4. 'codegraph' not installed — run 'codegraph init' in $PATH_REL/ later"
elif cg_indexed "$REPO_DIR" && [[ "$FORCE" -ne 1 ]]; then skip "4. .codegraph index already built"
elif codegraph init "$REPO_DIR"; then ok "codegraph index built"   # recovers a bare/partial .codegraph/ too
else skip "4. 'codegraph init' failed"; fi

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
  installed=(); already=(); failed=()
  for s in "${mp_skills[@]}"; do
    if [[ -d "$REPO_DIR/.claude/skills/$s" && "$FORCE" -ne 1 ]]; then already+=("$s"); continue; fi
    if npx -y skills@latest add mattpocock/skills --skill "$s" --agent '*' -y >/dev/null 2>&1; then installed+=("$s")
    else failed+=("$s"); fi
  done
  [[ "${#already[@]}"   -gt 0 ]] && skip "6. already present: ${already[*]}"
  [[ "${#installed[@]}" -gt 0 ]] && ok "installed mattpocock skills (project scope): ${installed[*]}"
  [[ "${#failed[@]}"    -gt 0 ]] && skip "6. failed to install: ${failed[*]} — retry: npx skills@latest add mattpocock/skills --skill <name> -y"
fi

# ── 7. project knowledge (CLAUDE.md) — anatomy-driven, ≤60 lines + .claude/rules/ ─
# Keep CLAUDE.md lean; overflow goes into .claude/rules/<topic>.md with frontmatter. If a
# CLAUDE.md already exists, ask whether to regenerate / combine / skip (default: skip).
step "7. Scaffold project knowledge (CLAUDE.md)"
md_guidance="Constraint: keep CLAUDE.md to 60 lines MAX. If the project needs more guidance than fits, move details into .claude/rules/<topic>.md files — each starting with YAML frontmatter that has a 'description:' line (and a 'globs:' line scoping it to specific paths when the rule is path-specific) — and keep CLAUDE.md a concise index that points to them."
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
                 if claude_run "$init_prompt"; then ok "CLAUDE.md created"; else skip "7. /init failed (auth? run 'claude' once interactively to log in)"; fi ;;
    regenerate)  glance "regenerating CLAUDE.md from scratch ..."
                 if claude_run "$init_prompt Overwrite the existing CLAUDE.md."; then ok "CLAUDE.md regenerated"; else skip "7. regenerate failed"; fi ;;
    combine)     glance "merging into the existing CLAUDE.md ..."
                 if claude_run "Update the existing CLAUDE.md IN PLACE: keep all still-accurate content, fill gaps, fix staleness — do NOT discard the author's notes. $md_guidance"; then ok "CLAUDE.md combined"; else skip "7. combine failed"; fi ;;
  esac
  # 60-line guard: if CLAUDE.md overflowed, nudge toward the .claude/rules/ split.
  if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    cm_lines="$(grep -c '' "$REPO_DIR/CLAUDE.md" 2>/dev/null || echo 0)"
    if [[ "$cm_lines" -gt 60 ]]; then
      warn "CLAUDE.md is $cm_lines lines (>60) — move detail into .claude/rules/<topic>.md (frontmatter: description/globs)"
      FOLLOWUP+=("trim $PATH_REL/CLAUDE.md ($cm_lines lines) to ≤60 and split detail into .claude/rules/")
    fi
  fi
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
else skip "8. /setup-matt-pocock-skills failed (auth? was step 6 able to install it?)"; fi

# ── 9. hooks + permissions baseline (HARDCODED, sonar-free) ────────────────────
# No reference repo: the hooks come from the workspace's own .claude/hooks (the dev-wrapper,
# modeled on feeedme-app minus sonar) and settings.json is written from a hardcoded, stack-
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
# 9b. settings.json — hardcoded baseline (feeedme-app minus sonar), merged to keep plugins.
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
  gen_prompt="Inspect THIS repo's anatomy (its build/test/run tooling, package manager, and layout${LANG:+; language: $LANG}) and create scripts/dev.sh implementing this fixed contract with the repo's OWN toolchain: subcommands test | gen | analyze | clean | run | status | why <name>. Each verbose subcommand writes its full log to agent_logs/executed_verbose/<cmd>-<timestamp>.log and prints only a concise one-line summary to stdout; 'why <name>' tails/greps the matching log for failure detail; 'status' shows the latest results. 'run' is the SINGLE SOURCE OF TRUTH for how to launch this repo: it builds if needed then launches/drives the app the repo's OWN way as a NON-INTERACTIVE agent path that proves it works and EXITS with a verdict (a server → start, poll a readiness/health check, report up/down, then tear down; a web app → build or start the dev server and confirm it serves; a CLI → a smoke invocation; a DB/migration repo → apply + verify; ANYTHING long-running MUST be backgrounded, polled for a ready marker, then stopped — never block forever), and it obeys the same verbose-log + one-line-summary rules as the others. After writing each run's log, prune the older logs for that command so only the most-recent N are kept (N from the DEV_LOG_KEEP env var, default 5; treat 0 or a non-numeric value as keep-all). POSIX bash, 'set -euo pipefail', a usage(), executable. Write ONLY scripts/dev.sh and chmod +x it — change nothing else."
  glance "scaffolding scripts/dev.sh (${LANG:-language inferred}) ..."
  if claude_run "$gen_prompt"; then
    [[ -f "$REPO_DIR/scripts/dev.sh" ]] && chmod +x "$REPO_DIR/scripts/dev.sh" 2>/dev/null
    ok "scripts/dev.sh scaffolded (${LANG:-language inferred}) — REVIEW it before relying on it"
    FOLLOWUP+=("review + test $PATH_REL/scripts/dev.sh (Claude-generated)")
  else skip "10. dev.sh generation failed"; fi
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
  else skip "10.5. $SKILL_CMD failed (is the skill installed? override the name with --skill-cmd)"; fi
fi

# ── 10.6 sync the codegraph index (before leaving the repo) ─────────────────────
# Steps 6-10.5 generated files (CLAUDE.md, .claude/rules, settings.json, scripts/dev.sh,
# skills) AFTER the step-4 index build, so re-sync so the index reflects the final tree.
step "10.6. Sync the codegraph index (in $PATH_REL/)"
if ! have codegraph; then skip "10.6. 'codegraph' not installed — run 'codegraph sync $PATH_REL' later"
elif ! cg_indexed "$REPO_DIR"; then skip "10.6. no .codegraph index to sync (step 4 didn't build one) — run 'codegraph init $PATH_REL' first"
elif codegraph sync "$REPO_DIR"; then ok "codegraph index synced"
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
