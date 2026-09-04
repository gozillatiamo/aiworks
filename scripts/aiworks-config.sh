#!/usr/bin/env bash
#
# aiworks-config.sh  (run it as: aiworks config) — regenerate the dev-cycle workflow's
# CONFIG block FROM workspace.config.yaml.
#
# WHY THIS EXISTS
#   Workflow scripts (.claude/workflows/src/dev-cycle.js) run in an engine sandbox with NO
#   filesystem access — they cannot read workspace.config.yaml at runtime. So the workflow
#   carries its own in-source MIRROR of the config (TICKET_PREFIX, the status map, the
#   auto-merge / planning flags, and the REPOS registry) in an AIWORKS-MANAGED block.
#
#   This script is the bridge: it reads workspace.config.yaml (the source of truth) and
#   REWRITES that managed block so the two never drift. `aiworks add`, `aiworks remove`, and
#   `aiworks sync` all call it automatically after they touch the config, so the workflow
#   tracks workspace.config.yaml with zero hand-editing.
#
#   PERSONAL OVERRIDES: a git-ignored workspace.config.local.yaml overrides the shared config at
#   RUNTIME (chat / agents / interactive skills), but is deliberately NOT read here — this
#   committed mirror always reflects workspace.config.yaml (shared) ONLY, so no personal pref
#   ever leaks into a tracked file. (The personal OUTPUT preferences still reach a headless run at
#   RUNTIME, not through this mirror: dev-cycle.js's resolve-runtime-config sub-agent reads the local
#   file local-first and resolves `language`, `planning.to_html` + `planning.auto_approve` into
#   RESOLVED_LANGUAGE / RESOLVED_PLAN_TO_HTML / RESOLVED_AUTO_APPROVE, making the consts it generates
#   here the FALLBACK DEFAULTS for those three — see docs/agents/language.md + docs/adr/0003. The
#   IRREVERSIBLE control-flow consts (auto_merge, statuses, REPOS) are shared-only, with no runtime
#   override at all.)
#
# WHAT IT DERIVES (workspace.config.yaml → dev-cycle.js CONFIG)
#   tracker.ticket_prefix            → const TICKET_PREFIX
#   tracker.statuses.*               → const STATUS
#   vcs.auto_merge                   → const AUTO_MERGE
#   quality_gate.provider            → const QUALITY_GATE            (dev-cycle.js; 'none' ⇒ guardian gate skips+passes)
#   review.level                     → const REVIEW_LEVEL            (dev-cycle.js; 'strict' ⇒ must-fixes only, no nice-to-have)
#   loadtest.*                       → const LOADTEST                (dev-cycle.js; the base-branch non-degradation gate)
#   test_suite.max_fix_rounds        → const TEST_SUITE              (dev-cycle.js; the cross-repo gate's own repair loop)
#   dev_cycle.token_budget           → const DEV_CYCLE               (dev-cycle.js; the run's own spend ceiling)
#   notify.dm_on_incomplete          → const NOTIFY_DM                (dev-cycle.js; a Slack member id DMed on a non-complete ending)
#   language                         → const LANGUAGE                (dev-cycle.js AND prd.js; 'en' default | 'th' ⇒ English spine, Thai prose)
#   planning.auto_approve            → const AUTO_APPROVE_PLAN
#   planning.to_html                 → const PLAN_TO_HTML
#   notify.enabled                   → const NOTIFY
#   notify.provider                  → const NOTIFY_PROVIDER
#   notify.channel                   → const NOTIFY_CHANNEL
#   design.enabled                   → const DESIGN_ENABLED          (dev-cycle.js AND prd.js)
#   design.figma_file_key            → const DESIGN_FIGMA_FILE_KEY   (prd.js only)
#   design.page_naming               → const DESIGN_PAGE_NAMING      (prd.js only)
#   image_generation.enabled         → const IMAGE_GEN_ENABLED          (prd.js only)
#   image_generation.quality         → const IMAGE_GEN_QUALITY          (prd.js only)
#   image_generation.max_per_request → const IMAGE_GEN_MAX_PER_REQUEST  (prd.js only)
#   branch_model.{feature,fix}_base  → each repo's base.{feature,fix}, for EVERY kind
#   products[].repos[]               → const REPOS  (one entry per repo)
#       url               → the REPOS key (repo name) + path default
#       kind              → the role/gate DEFAULTS below (plan/build/review/guard/perf/
#                           testSuite/green/guardianFocus) — the single source of truth
#                           for what each kind means in the workflow
#       suite_kind        → which flavour of test-suite ('load' arms the base-branch
#                           non-degradation gate — docs/agents/loadtest-gate.md)
#       feature_base / fix_base → this repo's OWN branch policy, overriding branch_model.
#                           The only way a repo on `develop → staging → main` states that
#                           without editing generated code (docs/adr/0025).
#       path / distribute / auto_merge / green / guardian_focus → optional per-repo overrides
#
# ALSO GENERATES — the multi-root <workspace>.code-workspace file (one folder root per repo)
#   products[].repos[]               → the `folders` array of <workspace-basename>.code-workspace
#       url               → the folder NAME (repo name = last URL segment, minus .git)
#       path              → the folder PATH (the clone dir; the `path:` override, else the name)
#   plus the meta-repo itself as the FIRST root ({ name:"🗂 <workspace> (meta)", path:"." }).
#   WHY: opening the workspace FOLDER in VS Code/Cursor auto-detects nested git repos but SKIPS
#   any subfolder the parent .gitignore hides (the product clones ARE gitignored) — so only the
#   meta-repo shows in Source Control. Listing each repo as an explicit folder ROOT makes every
#   repo its own Source Control provider (own staged/unstaged diff). Open it with:
#       cursor <workspace>.code-workspace        (or: code <workspace>.code-workspace)
#   File name = the workspace-root basename (deterministic). It is COMMITTED with the meta-repo,
#   exactly like the other generated artifacts (mani.d/, .vscode/settings.json) — NOT gitignored —
#   so a teammate who clones the meta-repo + runs `aiworks sync` gets it ready to open.
#   NON-DESTRUCTIVE: only the `folders` array is regenerated each run (deterministic, declared
#   order ⇒ no spurious diff); any user-added top-level keys (esp. `settings`) are PRESERVED. A
#   `settings` block is seeded ONLY on first create, never overwritten on regen.
#
# ALSO CHECKS — that workspace.config.example.yaml still documents every key of
#   workspace.config.yaml (section 0). That template is what `aiworks add` copies for a NEW org,
#   so a key only ever added HERE is a key no other org can discover. Advisory (a warning, never
#   a failure) and one-directional: keys the example documents but this workspace omits are fine.
#
# Idempotent and safe: it replaces only the region between the AIWORKS:CONFIG markers in
# dev-cycle.js, validates that the result still LOADS AS A WORKFLOW (when node is present), and
# restores the file untouched on a genuine syntax error. A node KILLED BY A SIGNAL (exit >=128,
# e.g. SIGSEGV=139 / SIGTRAP=133 / SIGABRT=134 under memory pressure or an EDR/security agent)
# is a transient, machine-side CRASH — NOT a CONFIG defect: validation is skipped with a clear
# warning and the regenerated block is still installed (so the mirror can't silently drift).
#
# Usage:
#   aiworks config [options]
#
#   --config <file>     workspace.config.yaml to read   (default: <workspace>/workspace.config.yaml)
#   --config-local <f>  the personal override to CHECK   (default: <workspace>/workspace.config.local.yaml)
#                       Read by the advisory guards only — never baked into the generated mirror.
#   --target <file>     dev-cycle.js to rewrite          (default: <workspace>/.claude/workflows/src/dev-cycle.js)
#   --prd-target <file> prd.js to rewrite (its design CONFIG) (default: <workspace>/.claude/workflows/src/prd.js)
#   --workspace <file>  <name>.code-workspace to (re)generate (default: <workspace>/<basename>.code-workspace)
#   -n, --dry-run      print the generated block(s) + the .code-workspace to stdout; write nothing.
#   -q, --quiet        only print on change/error (suppress the "in sync" line).
#   -h, --help         show this help.
#
set -uo pipefail

# ── logging (same surface as the sibling scripts) ────────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────
WC="" WC_LOCAL="" TARGET="" PRD_TARGET="" WS_TARGET="" DRY=0 QUIET=0
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)       WC="${2:-}"; shift 2 ;;
    --config-local) WC_LOCAL="${2:-}"; shift 2 ;;
    --target)     TARGET="${2:-}"; shift 2 ;;
    --prd-target) PRD_TARGET="${2:-}"; shift 2 ;;
    --workspace)  WS_TARGET="${2:-}"; shift 2 ;;
    -n|--dry-run) DRY=1; shift ;;
    -q|--quiet)  QUIET=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "unknown option: $1   (see -h)" ;;
    *)           die "unexpected argument: $1   (see -h)" ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
[[ -n "$WC" ]]         || WC="$ROOT/workspace.config.yaml"
[[ -n "$TARGET" ]]     || TARGET="$ROOT/.claude/workflows/src/dev-cycle.js"
[[ -n "$PRD_TARGET" ]] || PRD_TARGET="$ROOT/.claude/workflows/src/prd.js"
# The multi-root workspace file is named after the workspace-root basename (deterministic),
# e.g. <root>/aiworks.code-workspace. Override the whole path with --workspace.
WS_NAME="$(basename "$ROOT")"
[[ -n "$WS_TARGET" ]]  || WS_TARGET="$ROOT/$WS_NAME.code-workspace"
[[ -f "$WC" ]]     || die "no workspace.config.yaml at $WC — declare your repos under products: first"
[[ -f "$TARGET" ]] || die "no dev-cycle workflow at $TARGET"

# Personal, git-ignored override — read at RUNTIME by chat/agents/skills, NOT baked into this
# committed mirror (so no personal pref leaks into a tracked file). Just surface that it exists.
# --config-local exists so the checks that read this file are TESTABLE against a fixture. It is
# not a way to point a real run at another machine's overrides: nothing here is baked into the
# generated mirror either way.
[[ -n "$WC_LOCAL" ]] || WC_LOCAL="$ROOT/workspace.config.local.yaml"
if [[ -f "$WC_LOCAL" && "$QUIET" -ne 1 ]]; then
  warn "workspace.config.local.yaml present — a RUNTIME-only personal override (chat/agents/skills); this committed mirror is regenerated from workspace.config.yaml (shared) only."
fi

# ── 0. drift guard: every key here must be DOCUMENTED in workspace.config.example.yaml ──
# WHY: `aiworks add` bootstraps a NEW org by COPYING workspace.config.example.yaml
# (aiworks-add.sh), and every doc points a newcomer at that file — so a key that only ever
# landed in THIS workspace's config is a key no other org can discover. Six whole blocks had
# drifted that way before this check existed (observability, review, diagrams, artifacts,
# voice, triage): each feature was configured here and shipped, and the template still
# described a workspace without them.
#
# ADVISORY, never fatal — a missing example entry breaks nothing that runs; it only costs the
# next org the knowledge. And ONE-DIRECTIONAL on purpose: the example may document keys this
# workspace omits (`design`, `image_generation` here) — an omitted optional block just takes
# its default, which is not drift.
CONFIG_EXAMPLE="$ROOT/workspace.config.example.yaml"

# Dotted key paths of the nested maps, one per line. Follows the same 2-space indent contract
# aiworks-sync.sh relies on; comment lines and list items (`- url:`) are skipped, so the
# products[] subtree contributes only the `products` key itself.
config_key_paths() {   # <yaml-file>
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    !/^[ ]*[A-Za-z_][A-Za-z0-9_]*[ ]*:/ { next }
    {
      ind = match($0, /[^ ]/) - 1
      key = $0; sub(/^ */, "", key); sub(/[ ]*:.*$/, "", key)
      d = int(ind / 2); stack[d] = key
      path = stack[0]
      for (i = 1; i <= d; i++) path = path "." stack[i]
      print path
    }' "$1"
}

config_drift_check() {
  [[ -f "$CONFIG_EXAMPLE" ]] || return 0
  local ex_paths; ex_paths="$(config_key_paths "$CONFIG_EXAMPLE")"
  local missing=() p leaf ancestor covered
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # An ancestor is already reported ⇒ its whole subtree goes with it. Reporting the children
    # too would bury the one line that matters ("`voice` is undocumented") under 20 of its keys.
    covered=
    for ancestor in ${missing[@]+"${missing[@]}"}; do
      case "$p" in "$ancestor".*) covered=1; break ;; esac
    done
    [[ -n "$covered" ]] && continue
    printf '%s\n' "$ex_paths" | grep -qxF "$p" && continue
    # A key the example only COMMENTS OUT — or names in its prose, like the optional
    # tracker.statuses.* — IS documented: the example's job is to explain a key, not to set it.
    # Hence the leaf name matched anywhere in the file, which is deliberately lenient: a guard
    # that cries wolf gets ignored, and the block-level miss above is the one that actually hurts.
    leaf="${p##*.}"
    grep -qE "(^|[^A-Za-z0-9_])${leaf}([^A-Za-z0-9_]|\$)" "$CONFIG_EXAMPLE" && continue
    missing+=("$p")
  done < <(config_key_paths "$WC" | grep -v '^products')
  if [[ ${#missing[@]} -eq 0 ]]; then
    [[ "$QUIET" -eq 1 ]] || ok "workspace.config.example.yaml documents every key in $(basename "$WC")"
    return 0
  fi
  # STDERR on purpose: `aiworks sync` runs this script with stdout to /dev/null unless -v, so a
  # warning printed like the other lines would be silently dropped in the one flow most likely
  # to run right after someone edits the config.
  warn "workspace.config.example.yaml does NOT document: ${missing[*]}" >&2
  warn "  a new org bootstraps its config by COPYING that file, so an undocumented key is one nobody else can find — add each one there too (default OFF / neutral value, with the comment that explains it)." >&2
}
config_drift_check

# ── 0b. comment guard: the LIVE config files carry NO comments ──────────────────────────
# The counterpart of the drift guard above: the example TEMPLATE is where an explanation
# belongs, and the live file is data. `.claude/hooks/dev-wrapper/pretool-config-comment-guard.sh`
# blocks an agent from writing one; this catches the other way in — a hand edit in an editor,
# or a config copied wholesale from the template before the copy path learned to strip.
# ADVISORY like the drift guard: nothing about a comment breaks a run, and `aiworks sync` must
# not fail over a formatting rule. It prints the one command that fixes it.
# Rationale: docs/adr/0006-config-carries-no-comments.md
config_comment_check() {
  local scanner="$ROOT/scripts/lib/yaml_comments.py" f hits dirty=0
  [[ -f "$scanner" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  for f in "$WC" "$WC_LOCAL"; do
    [[ -f "$f" ]] || continue
    hits="$(python3 "$scanner" --check "$f" 2>&1)" && continue
    dirty=1
    warn "$(basename "$f") carries $(printf '%s\n' "$hits" | grep -c .) YAML comment line(s) — the live config is data, not documentation:" >&2
    printf '%s\n' "$hits" | head -5 >&2
    warn "  move the explanation to $(basename "${f%.yaml}").example.yaml (or docs/) and strip the file: python3 scripts/lib/yaml_comments.py --write $(basename "$f")" >&2
  done
  [[ "$dirty" -eq 1 || "$QUIET" -eq 1 ]] || ok "the live config files carry no comments"
}
config_comment_check

# ── 0c. value guard: a key documented as a BOOLEAN carries a boolean ────────────────────
# The drift guard checks that every key is DOCUMENTED; the comment guard, that the file is data.
# Neither has ever looked at a VALUE — and a value held the quietest failure this workspace has
# had: `stagehand.enabled: ture` in a personal config read as OFF for weeks. Every `*_cfg_bool`
# reader resolves "not truthy" to false, so a typo and a deliberate opt-out are the same thing to
# every surface that reports state. The readers now log it (voice_cfg_bool / stage_cfg_bool), but
# a reader's log needs VERBOSE=1 to be seen; THIS is the surface someone actually reads.
#
# Which keys are boolean is LEARNED from the templates, not listed here, so a new flag is covered
# the day it is documented — which the drift guard above already requires. Learning uses the
# STRICT literals true/false only: `narrate_gap: 0` is a count, and admitting 0/1 as boolean would
# flag every number in the file. Validation is lenient (yes/on/off/1/0 all pass) because those are
# legal YAML booleans a teammate may well write; only a value in NEITHER set is reported.
# ADVISORY like both siblings — a typo'd flag breaks no run, it just silently means "off".
config_key_values() {   # <yaml-file> → "path<TAB>value", one per line
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*-/ { next }
    !/^[ ]*[A-Za-z_][A-Za-z0-9_]*[ ]*:/ { next }
    {
      ind  = match($0, /[^ ]/) - 1
      line = $0; sub(/^ */, "", line)
      key  = line; sub(/[ ]*:.*$/, "", key)
      val  = line; sub(/^[^:]*:[ \t]*/, "", val)
      sub(/[ \t]+#.*$/, "", val); gsub(/^[ \t]+|[ \t]+$/, "", val)
      gsub(/^["'\'']|["'\'']$/, "", val)
      d = int(ind / 2); stack[d] = key
      for (i = d + 1; i <= 20; i++) stack[i] = ""
      path = stack[0]
      for (i = 1; i <= d; i++) path = path "." stack[i]
      printf "%s\t%s\n", path, val
    }' "$1"
}

config_bool_check() {
  local tmpl bools f path val lower bad=()
  bools="$(
    for tmpl in "$CONFIG_EXAMPLE" "$ROOT/workspace.config.local.example.yaml"; do
      [[ -f "$tmpl" ]] && config_key_values "$tmpl"
    done | awk -F'\t' 'tolower($2) == "true" || tolower($2) == "false" { print $1 }' | sort -u
  )"
  [[ -n "$bools" ]] || return 0
  for f in "$WC" "$WC_LOCAL"; do
    [[ -f "$f" ]] || continue
    while IFS=$'\t' read -r path val; do
      [[ -n "$val" ]] || continue
      printf '%s\n' "$bools" | grep -qxF "$path" || continue
      lower="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
      case "$lower" in true|yes|1|on|false|no|0|off) continue ;; esac
      bad+=("$(basename "$f")  $path: $val")
    done < <(config_key_values "$f")
  done
  if [[ ${#bad[@]} -eq 0 ]]; then
    [[ "$QUIET" -eq 1 ]] || ok "every boolean flag in the live config carries a boolean"
    return 0
  fi
  # STDERR for the same reason as the two guards above: `aiworks sync` drops this script's stdout.
  warn "a flag documented as a boolean carries a value that is neither — it reads as OFF:" >&2
  printf '      %s\n' "${bad[@]}" >&2
  warn "  every *_cfg_bool reader resolves anything but true/yes/1/on to false, so a typo here is indistinguishable from opting out. Fix the value." >&2
}
config_bool_check

START_RE='>>> AIWORKS:CONFIG START'
END_RE='<<< AIWORKS:CONFIG END'
if ! grep -qF "$START_RE" "$TARGET" || ! grep -qF "$END_RE" "$TARGET"; then
  warn "no AIWORKS:CONFIG markers in $(basename "$TARGET") — skipping (add the two marker comments once to enable auto-config)"
  exit 0
fi
# prd.js carries its OWN (design-only) AIWORKS:CONFIG block. Optional: regenerate it when
# present, else skip just prd.js (dev-cycle still gets rewritten).
PRD_OK=1
if [[ ! -f "$PRD_TARGET" ]] || ! grep -qF "$START_RE" "$PRD_TARGET" || ! grep -qF "$END_RE" "$PRD_TARGET"; then
  PRD_OK=
  [[ -f "$PRD_TARGET" ]] && warn "no AIWORKS:CONFIG markers in $(basename "$PRD_TARGET") — skipping its design CONFIG (add the marker comments once to enable)"
fi

# ── escape a value for a JS single-quoted string ─────────────────────────────────
# backslash → \\, single-quote → \'. (Backticks are literal inside '…' so left as-is.)
# → a JS single-quoted string literal. Escaped CHARACTER BY CHARACTER, through variables
# holding the two characters, on purpose. The obvious one-liner
#
#     s="${s//\'/\\\'}"
#
# is BASH-VERSION-DEPENDENT: bash 4+ substitutes the intended `\'`, bash 3.2 substitutes
# `\\'` — two backslashes, which closes the JS string early. macOS ships 3.2 as /bin/bash,
# so on any machine without a newer bash this generator silently wrote a dev-cycle.js that
# the workflow engine cannot load, from a config file that was perfectly fine. Nothing in
# `${var//…}` with a backslash in the replacement is safe to trust across versions.
jsq() {
  local s="$1" out='' c n i
  local bs='\' q="'"                          # exactly one backslash · exactly one quote
  n="${#s}"
  for (( i=0; i<n; i++ )); do
    c="${s:i:1}"
    case "$c" in
      "$bs")  out="$out$bs$bs"   ;;
      "$q")   out="$out$bs$q"    ;;
      $'\n')  out="${out}${bs}n" ;;           # a raw newline would break the literal too
      $'\r')  out="${out}${bs}r" ;;
      $'\t')  out="${out}${bs}t" ;;
      *)      out="$out$c"       ;;
    esac
  done
  printf '%s%s%s' "$q" "$out" "$q"
}
# normalize a yaml scalar to a JS boolean literal (default given by $2). tr, not ${,,} (bash 3.2).
jsbool() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) printf 'true' ;; false|no|0) printf 'false' ;; *) printf '%s' "$2" ;; esac; }

# ── 1. read the top-level scalars (ticket_prefix, flags, branch bases, statuses) ──
# bash 3.2 (macOS default) has no associative arrays, so read KEY<TAB>VALUE into plain
# vars via a case. Defaults below match the workflow's historical fallbacks.
PREFIX='FM'; AM_RAW='true'; AA_RAW='true'; TH_RAW='false'
FEATURE_BASE='develop'; FIX_BASE='main'
NT_RAW='false'; NOTIFY_PROVIDER='slack'; NOTIFY_CHANNEL=''
DESIGN_EN_RAW='false'; DESIGN_KEY=''; DESIGN_PAGE='{work_key} / {feature}'   # Figma OFF unless design.enabled: true
IMG_EN_RAW='false'; IMG_QUALITY='balanced'; IMG_MAX='2'   # image-gen OFF unless image_generation.enabled: true
QG_RAW='none'   # quality_gate.provider — 'none' (guardian gate skips+passes) unless the org declares sonarqube
RL_RAW='strict' # review.level — 'strict' (must-fixes only) unless the org declares thorough
# loadtest.* — the base-branch non-degradation gate for a `suite_kind: load` repo. Defaults
# match the workflow's fallbacks; every one is a number the gate reads at runtime.
LT_TOL='10'; LT_NOISE_RUNS='2'; LT_NOISE_CEIL='2'; LT_FIX_ROUNDS='2'
LT_CACHE='~/.cache/aiworks/loadtest-baselines'
# test_suite.max_fix_rounds — the cross-repo gate's own bounded red-triage loop (C4), and the
# per-red attempt bound its scoped quality check retries within one round (docs/adr/0024).
TS_FIX_ROUNDS='3'
# test_suite.max_suite_repair_attempts — a suite that COULD NOT RUN is a must-fix, not a halt
# (docs/adr/0027). Never a verdict: no receipt means the gate did not run.
TS_MAX_REPAIR='3'
# review.* — the review loop's own bounds. max_rounds is the ONE terminal bound; the rest are
# per-condition attempt budgets for the states that used to halt a repo mid-review.
RV_MAX_ROUNDS='14'; RV_MAX_REGRESSION='3'; RV_MAX_STALL='3'; RV_MAX_ESCALATION='3'
# dev_cycle.token_budget — the run's own spend ceiling (C9), and notify.dm_on_incomplete (C10).
BD_MAX_CONT='3'
DC_TOKEN_BUDGET='2000000'
NOTIFY_DM=''
STATUS_PAIRS=''   # accumulates "<canonical_key>\t<real name>\n" for EVERY status the org declares,
                  # in declared order. The workflow drives a monotonic subset (STATUS_ORDER); the
                  # rest are carried for humans/other tools — so a rich board isn't silently dropped.
while IFS=$'\t' read -r k v; do
  case "$k" in
    PREFIX)        PREFIX="$v" ;;
    LANGUAGE)      LANG_RAW="$v" ;;
    AUTO_MERGE)    AM_RAW="$v" ;;
    AUTO_APPROVE)  AA_RAW="$v" ;;
    TO_HTML)       TH_RAW="$v" ;;
    FEATURE_BASE)  FEATURE_BASE="$v" ;;
    FIX_BASE)      FIX_BASE="$v" ;;
    NOTIFY_ENABLED)  NT_RAW="$v" ;;
    NOTIFY_PROVIDER) NOTIFY_PROVIDER="$v" ;;
    NOTIFY_CHANNEL)  NOTIFY_CHANNEL="$v" ;;
    NOTIFY_DM)       NOTIFY_DM="$v" ;;
    DESIGN_ENABLED)     DESIGN_EN_RAW="$v" ;;
    DESIGN_FIGMA_KEY)   DESIGN_KEY="$v" ;;
    DESIGN_PAGE_NAMING) DESIGN_PAGE="$v" ;;
    IMG_ENABLED)        IMG_EN_RAW="$v" ;;
    IMG_QUALITY)        IMG_QUALITY="$v" ;;
    IMG_MAX)            IMG_MAX="$v" ;;
    QUALITY_GATE)       QG_RAW="$v" ;;
    REVIEW_LEVEL)       RL_RAW="$v" ;;
    LT_TOLERANCE)       LT_TOL="$v" ;;
    LT_NOISE_RUNS)      LT_NOISE_RUNS="$v" ;;
    LT_NOISE_CEILING)   LT_NOISE_CEIL="$v" ;;
    LT_MAX_FIX_ROUNDS)  LT_FIX_ROUNDS="$v" ;;
    LT_BASELINE_CACHE)  LT_CACHE="$v" ;;
    TS_MAX_FIX_ROUNDS)  TS_FIX_ROUNDS="$v" ;;
    TS_MAX_REPAIR)      TS_MAX_REPAIR="$v" ;;
    RV_MAX_ROUNDS)      RV_MAX_ROUNDS="$v" ;;
    RV_MAX_REGRESSION)  RV_MAX_REGRESSION="$v" ;;
    RV_MAX_STALL)       RV_MAX_STALL="$v" ;;
    RV_MAX_ESCALATION)  RV_MAX_ESCALATION="$v" ;;
    BD_MAX_CONT)        BD_MAX_CONT="$v" ;;
    DC_TOKEN_BUDGET)    DC_TOKEN_BUDGET="$v" ;;
    ST_*)          STATUS_PAIRS+="${k#ST_}"$'\t'"$v"$'\n' ;;   # pass through every declared status
  esac
done < <(
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec); instat=0 }   # new top-level section
    /^language:[ \t]*[^ \t#]/  { print "LANGUAGE\t" val($0); next }      # top-level scalar (workspace output language)
    sec=="vcs"          && /^  auto_merge:/      { print "AUTO_MERGE\t"    val($0); next }
    sec=="tracker"      && /^  ticket_prefix:/   { print "PREFIX\t"        val($0); next }
    sec=="tracker"      && /^  statuses:/        { instat=1; next }
    sec=="tracker" && instat && /^    [A-Za-z_]/ { k=$0; sub(/^[ \t]+/,"",k); sub(/:.*/,"",k);
                                                   print "ST_" k "\t" val($0); next }
    sec=="tracker" && instat && /^  [A-Za-z_]/   { instat=0 }            # dedent out of statuses
    sec=="branch_model" && /^  feature_base:/    { print "FEATURE_BASE\t" val($0); next }
    sec=="branch_model" && /^  fix_base:/        { print "FIX_BASE\t"     val($0); next }
    sec=="planning"     && /^  auto_approve:/    { print "AUTO_APPROVE\t"  val($0); next }
    sec=="planning"     && /^  to_html:/         { print "TO_HTML\t"       val($0); next }
    sec=="notify"       && /^  enabled:/         { print "NOTIFY_ENABLED\t"  val($0); next }
    sec=="notify"       && /^  provider:/        { print "NOTIFY_PROVIDER\t" val($0); next }
    sec=="notify"       && /^  channel:/         { print "NOTIFY_CHANNEL\t"  val($0); next }
    sec=="notify"       && /^  dm_on_incomplete:/ { print "NOTIFY_DM\t"      val($0); next }
    sec=="design"       && /^  enabled:/         { print "DESIGN_ENABLED\t"     val($0); next }
    sec=="design"       && /^  figma_file_key:/  { print "DESIGN_FIGMA_KEY\t"   val($0); next }
    sec=="design"       && /^  page_naming:/     { print "DESIGN_PAGE_NAMING\t" val($0); next }
    sec=="image_generation" && /^  enabled:/         { print "IMG_ENABLED\t" val($0); next }
    sec=="image_generation" && /^  quality:/         { print "IMG_QUALITY\t" val($0); next }
    sec=="image_generation" && /^  max_per_request:/ { print "IMG_MAX\t"     val($0); next }
    sec=="quality_gate" && /^  provider:/            { print "QUALITY_GATE\t" val($0); next }
    sec=="review"       && /^  level:/               { print "REVIEW_LEVEL\t" val($0); next }
    sec=="review"       && /^  max_rounds:/          { print "RV_MAX_ROUNDS\t"  val($0); next }
    sec=="review"       && /^  max_regression_fixes:/    { print "RV_MAX_REGRESSION\t" val($0); next }
    sec=="review"       && /^  max_stall_reattempts:/    { print "RV_MAX_STALL\t"      val($0); next }
    sec=="review"       && /^  max_escalation_attempts:/ { print "RV_MAX_ESCALATION\t" val($0); next }
    sec=="test_suite"   && /^  max_suite_repair_attempts:/ { print "TS_MAX_REPAIR\t"   val($0); next }
    sec=="build"        && /^  max_continuation_passes:/ { print "BD_MAX_CONT\t"     val($0); next }
    sec=="loadtest"     && /^  tolerance_pct:/        { print "LT_TOLERANCE\t"      val($0); next }
    sec=="loadtest"     && /^  noise_runs:/           { print "LT_NOISE_RUNS\t"     val($0); next }
    sec=="loadtest"     && /^  noise_ceiling_multiple:/ { print "LT_NOISE_CEILING\t" val($0); next }
    sec=="loadtest"     && /^  max_fix_rounds:/       { print "LT_MAX_FIX_ROUNDS\t" val($0); next }
    sec=="loadtest"     && /^  baseline_cache:/       { print "LT_BASELINE_CACHE\t" val($0); next }
    sec=="test_suite"   && /^  max_fix_rounds:/       { print "TS_MAX_FIX_ROUNDS\t" val($0); next }
    sec=="dev_cycle"    && /^  token_budget:/         { print "DC_TOKEN_BUDGET\t"   val($0); next }
  ' "$WC"
)
AUTO_MERGE="$(jsbool "$AM_RAW" true)"
AUTO_APPROVE="$(jsbool "$AA_RAW" true)"
TO_HTML="$(jsbool "$TH_RAW" false)"
NOTIFY="$(jsbool "$NT_RAW" false)"
DESIGN_ENABLED="$(jsbool "$DESIGN_EN_RAW" false)"   # Figma OFF by default — opt in with design.enabled: true
IMAGE_GEN_ENABLED="$(jsbool "$IMG_EN_RAW" false)"   # image-gen OFF by default — opt in with image_generation.enabled: true
case "$IMG_QUALITY" in fast|balanced|quality) ;; *) IMG_QUALITY='balanced' ;; esac   # clamp to the valid presets
[[ "$IMG_MAX" =~ ^[0-9]+$ ]] || IMG_MAX='2'         # numeric budget cap; fall back to 2
QUALITY_GATE="${QG_RAW:-none}"
case "$QUALITY_GATE" in sonarqube|none) ;; *) QUALITY_GATE='none' ;; esac   # clamp to the supported providers
# loadtest.* — clamp to sane numbers; a garbage value falls back rather than reaching the gate.
[[ "$LT_TOL" =~ ^[0-9]+$ ]]         || LT_TOL='10'
[[ "$LT_NOISE_RUNS" =~ ^[0-9]+$ ]] && [[ "$LT_NOISE_RUNS" -ge 2 ]] || LT_NOISE_RUNS='2'  # <2 cannot measure a floor
[[ "$LT_NOISE_CEIL" =~ ^[0-9]+$ ]] && [[ "$LT_NOISE_CEIL" -ge 1 ]] || LT_NOISE_CEIL='2'
[[ "$LT_FIX_ROUNDS" =~ ^[0-9]+$ ]]  || LT_FIX_ROUNDS='2'
LT_CACHE="${LT_CACHE:-~/.cache/aiworks/loadtest-baselines}"
[[ "$TS_FIX_ROUNDS" =~ ^[0-9]+$ ]]    || TS_FIX_ROUNDS='3'
[[ "$TS_MAX_REPAIR" =~ ^[0-9]+$ ]]    || TS_MAX_REPAIR='3'
# max_rounds is the run's ONLY terminal review bound now, so a 0 or a typo must not disarm it.
[[ "$RV_MAX_ROUNDS" =~ ^[0-9]+$ ]] && [[ "$RV_MAX_ROUNDS" -ge 1 ]] || RV_MAX_ROUNDS='14'
[[ "$RV_MAX_REGRESSION" =~ ^[0-9]+$ ]] || RV_MAX_REGRESSION='3'
[[ "$RV_MAX_STALL" =~ ^[0-9]+$ ]]      || RV_MAX_STALL='3'
[[ "$RV_MAX_ESCALATION" =~ ^[0-9]+$ ]] || RV_MAX_ESCALATION='3'
[[ "$BD_MAX_CONT" =~ ^[0-9]+$ ]]      || BD_MAX_CONT='3'
[[ "$DC_TOKEN_BUDGET" =~ ^[0-9]+$ ]]  || DC_TOKEN_BUDGET='2000000'
REVIEW_LEVEL="$(printf '%s' "${RL_RAW:-strict}" | tr '[:upper:]' '[:lower:]')"
case "$REVIEW_LEVEL" in strict|thorough) ;; *) REVIEW_LEVEL='strict' ;; esac   # clamp to the two levels (default strict)
LANGUAGE="$(printf '%s' "${LANG_RAW:-en}" | tr '[:upper:]' '[:lower:]')"
case "$LANGUAGE" in en|th) ;; *) LANGUAGE='en' ;; esac   # workspace output language; default en (see docs/agents/language.md)
# Fall back to the historical 5-phase lifecycle when the org declared no statuses.
if [[ -z "$STATUS_PAIRS" ]]; then
  STATUS_PAIRS=$'not_started\tNot started\nin_progress\tIn progress\nready_to_test\tReady to test\ntesting\tTesting\ndone\tDone\n'
fi

# ── 2. kind → role/gate DEFAULTS (the one authoritative table) ────────────────────
# `kind` is a FREE-FORM, tech-agnostic development-context label (frontend, backend,
# web-app, service, migration, generic, …) — the tech is captured by `lang`, NOT the kind.
#
# EVERY archetype takes its bases from `branch_model` — feature/* → feature_base, fix/* →
# fix_base. A test-suite repo used to be the exception, given fix_base for BOTH kinds on the
# reasoning that a suite repo has no develop flow. Measured, that was simply false: suite repos
# had `origin/HEAD` on the feature base with the fix base 99 and 157 commits behind, one of them
# a 16-file scaffold last touched a year earlier. A ticket's suite branch was therefore cut off a
# dead trunk, and since `workspace.config.yaml` carried no per-repo base at all, the only way to
# say otherwise was to edit generated code. The exception is gone; a repo that genuinely differs
# says so with `feature_base:` / `fix_base:` on its own `repos[]` entry (docs/adr/0025).
#
# Behaviour is decided by ARCHETYPE, and there are exactly three:
#   test-suite → QA pipeline: qa-planner/qa-runner build the suite, no code review, and this
#                repo PROVIDES the cross-repo test-suite gate. The ONE behaviourally-special kind.
#   document/  → a SOURCELESS repo: its deliverable is prose, fixtures or mock responses, so a
#   fixture/     static-analysis scanner has nothing to scan and a profiler has nothing to
#   mock         profile. Plan→build→review still applies (a human reviews the change); the
#                guard + perf gates do not. Leaving them on is not caution, it is a gate that
#                cannot pass on its own terms — and the guardian's scanner-relay prompt reads
#                as a security review of, say, a mock's fault-injection fixtures, which has
#                twice been enough to kill the agent mid-gate.
#   * (any     → a "code" repo: plan→build→review (development-planner + developer + code-reviewer)
#   other kind)  with the guard + perf gates on. Refine per repo via green / guardian_focus.
# Echoes TAB-separated: plan build review guard perf testSuite base_feature base_fix
# green guardianFocus   — `review`/`base_*` are bare; green/guardianFocus are free text.
kind_defaults() {
  local kind="$1"
  case "$kind" in
    test-suite)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        qa-planner qa-runner null false false true "$FEATURE_BASE" "$FIX_BASE" \
        'the ticket + regression specs (scoped `npm test -- <specs>`, POM) green on every target platform the suite covers — the full-suite run is on-demand' \
        '' ;;
    document|documentation|fixture|mock|mocks)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        development-planner developer code-reviewer false false false "$FEATURE_BASE" "$FIX_BASE" \
        'the change is reviewable and whatever check the repo does have passes' \
        '' ;;
    *)  # any code repo: frontend, backend, web-app, service, migration, generic, …
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        development-planner developer code-reviewer true true false "$FEATURE_BASE" "$FIX_BASE" \
        '<unit + integration tests>' \
        'authz, secrets, input validation, event-schema compat, PII at rest/in transit' ;;
  esac
}

# ── 3. build the REPOS entries from products[].repos[] ────────────────────────────
repos_body=""
repo_count=0
folders_tsv=""   # accumulates "<folder name>\t<folder path>\n" per repo, in declared order,
                 # for the multi-root <name>.code-workspace `folders` array (built in step 6).
while IFS=$'\037' read -r url kind path dist green gf am sk kfr bf bx; do   # \037 (US): empty fields preserved
  [[ -n "$url" ]] || continue
  name="${url%.git}"; name="${name##*/}"; name="${name##*:}"
  [[ -n "$name" ]] || { warn "could not derive a repo name from url '$url' — skipped"; continue; }
  kind="${kind:-generic}"
  path="${path:-$name}"

  # one folder root per repo for the .code-workspace: NAME = repo name, PATH = clone dir.
  folders_tsv+="$name"$'\t'"$path"$'\n'

  IFS=$'\t' read -r d_plan d_build d_review d_guard d_perf d_testsuite d_basef d_basex d_green d_gf \
    < <(kind_defaults "$kind")

  # per-repo overrides (else the kind default)
  [[ -n "$green" ]] && d_green="$green"
  [[ -n "$gf" ]]    && d_gf="$gf"
  # A repo whose branch policy is not the workspace's own says so here, and the config —
  # not generated code — is then the source of truth for it (docs/adr/0025).
  [[ -n "$bf" ]]    && d_basef="$bf"
  [[ -n "$bx" ]]    && d_basex="$bx"

  # distribute: none/empty → null, else 'value'
  local_dist='null'
  [[ -n "$dist" && "$dist" != none ]] && local_dist="$(jsq "$dist")"
  # review: literal null or a quoted agentType
  local_review='null'
  [[ "$d_review" != null ]] && local_review="$(jsq "$d_review")"

  entry="  $(jsq "$name"): {"$'\n'
  entry+="    path: $(jsq "$path"), kind: $(jsq "$kind"),"$'\n'
  entry+="    base: { feature: $(jsq "$d_basef"), fix: $(jsq "$d_basex") },"$'\n'
  entry+="    plan: $(jsq "$d_plan"), build: $(jsq "$d_build"), review: ${local_review},"$'\n'
  entry+="    guard: ${d_guard}, perf: ${d_perf},"$'\n'
  entry+="    green: $(jsq "$d_green"),"$'\n'
  [[ "$d_guard" == true ]] && entry+="    guardianFocus: $(jsq "$d_gf"),"$'\n'
  [[ "$d_testsuite" == true ]] && entry+="    testSuite: true,"$'\n'
  # suite_kind: which FLAVOUR of test-suite this is. 'load' arms the base-branch
  # non-degradation gate (docs/agents/loadtest-gate.md); absent ⇒ a plain pass/fail suite.
  [[ -n "$sk" ]] && entry+="    suiteKind: $(jsq "$sk"),"$'\n'
  # known_false_reds: the environment failures THIS repo produces that look like a real red.
  # Declared per repo because they are facts about one repo's harness, and they belong in the
  # org's config rather than in framework prose — a reviewer that has to re-derive them burns
  # a round per run, and a framework file that lists them is carrying org knowledge.
  [[ -n "$kfr" ]] && entry+="    knownFalseReds: $(jsq "$kfr"),"$'\n'
  entry+="    distribute: ${local_dist},"$'\n'
  [[ -n "$am" ]] && entry+="    autoMerge: $(jsbool "$am" true),"$'\n'
  entry+="  },"$'\n'

  repos_body+="$entry"
  repo_count=$((repo_count+1))
done < <(
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    function setkv(line){ k=line; sub(/^[ \t]*/,"",k)
      if(k~/^url:/) url=val(k); else if(k~/^kind:/) kind=val(k)
      else if(k~/^path:/) path=val(k); else if(k~/^distribute:/) dist=val(k)
      else if(k~/^green:/) green=val(k); else if(k~/^guardian_focus:/) gf=val(k)
      else if(k~/^auto_merge:/) am=val(k); else if(k~/^suite_kind:/) sk=val(k)
      else if(k~/^known_false_reds:/) kfr=val(k)
      else if(k~/^feature_base:/) bf=val(k); else if(k~/^fix_base:/) bx=val(k) }
    function flush(){ if(url!=""){ printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", url,kind,path,dist,green,gf,am,sk,kfr,bf,bx }
      url="";kind="";path="";dist="";green="";gf="";am="";sk="";kfr="";bf="";bx="" }
    /^products:[ \t]*$/ { inp=1; next }
    inp && /^  - id:/ { flush(); inrepos=0; next }
    inp && /^    repos:[ \t]*$/ { inrepos=1; next }
    inp && /^    [A-Za-z_]/ { inrepos=0; next }
    inrepos && /^      - / { flush(); l=$0; sub(/^      - /,"",l); setkv(l); next }
    inrepos && /^        [A-Za-z_]/ { setkv($0); next }
    /^[A-Za-z_]/ { flush(); inp=0; inrepos=0 }
    END{ flush() }
  ' "$WC"
)

[[ "$repo_count" -gt 0 ]] || warn "no products[].repos[] found in $(basename "$WC") — generating an EMPTY REPOS map (declare repos, then re-run)"

# ── 3.5. build the .code-workspace `folders` JSON (meta root FIRST, then declared order) ──
# Only needs jq (a documented dependency, like the .vscode/settings.json merge in `aiworks add`).
# The meta-repo root is the workspace itself ("."); the rest are the product-repo clones. jq
# builds the array from the TSV so repo names/paths are escaped correctly and the order is the
# declared order ⇒ deterministic output (no spurious diff on re-run).
META_NAME="🗂 $WS_NAME (meta)"
FOLDERS_JSON=''
# A sensible `settings` block seeded ONLY when the file is first created (never on regen):
# search.exclude trims build/VCS noise across all roots; the git.* keys document the multi-root
# intent (each listed root is its own repo — that is what surfaces a gitignored clone in SCM).
SEED_SETTINGS='{
  "git.autoRepositoryDetection": true,
  "git.repositoryScanMaxDepth": 1,
  "search.exclude": {
    "**/node_modules": true,
    "**/.git": true,
    "**/.codegraph": true,
    "**/.aiworks": true,
    "**/agent_logs": true
  }
}'
if command -v jq >/dev/null 2>&1; then
  FOLDERS_JSON="$(
    { printf '%s\t.\n' "$META_NAME"; printf '%s' "$folders_tsv"; } \
      | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {name: .[0], path: .[1]})'
  )" || { warn "could not build the .code-workspace folders array — skipping it"; FOLDERS_JSON=''; }
fi

# build the STATUS object from EVERY declared status (declared order), one key per line.
status_body=''
while IFS=$'\t' read -r sk sv; do
  [[ -n "$sk" ]] || continue
  status_body+="  $sk: $(jsq "$sv"),"$'\n'
done <<< "$STATUS_PAIRS"

# ── 4. assemble the managed blocks ────────────────────────────────────────────────
# dev-cycle.js carries the full mirror (prefix, flags, statuses, REPOS) + DESIGN_ENABLED
# (the workspace-wide Figma kill-switch the dev/QA agents honor). prd.js carries ONLY the
# design block (its design pipeline is the one that authors Figma).
DEVCYCLE_BODY="const TICKET_PREFIX = $(jsq "$PREFIX")
const AUTO_MERGE = ${AUTO_MERGE}        // from workspace.config.yaml vcs.auto_merge; per-repo override via REPOS[id].autoMerge
const AUTO_APPROVE_PLAN = ${AUTO_APPROVE} // from workspace.config.yaml planning.auto_approve; false ⇒ halt after Kickoff (re-run with --approve-plan)
const PLAN_TO_HTML = ${TO_HTML}     // from workspace.config.yaml planning.to_html; true ⇒ planners also render the plan to interactive HTML
const NOTIFY = ${NOTIFY}        // from workspace.config.yaml notify.enabled; true + AUTO_MERGE false ⇒ Notify phase posts a review-request
const NOTIFY_PROVIDER = $(jsq "$NOTIFY_PROVIDER") // from workspace.config.yaml notify.provider (scripts/notify/ adapter)
const NOTIFY_CHANNEL = $(jsq "$NOTIFY_CHANNEL")  // from workspace.config.yaml notify.channel; the chat channel the digest goes to
const NOTIFY_DM = $(jsq "${NOTIFY_DM:-U00000000000}")  // from workspace.config.yaml notify.dm_on_incomplete; a Slack MEMBER id — every non-complete ending DMs it instead of posting to the channel
const DESIGN_ENABLED = ${DESIGN_ENABLED}     // from workspace.config.yaml design.enabled; false ⇒ Figma OFF workspace-wide (dev/QA build from spec, not a Figma screenshot)
const QUALITY_GATE = $(jsq "$QUALITY_GATE")     // from workspace.config.yaml quality_gate.provider; 'none' ⇒ guardian gate skips+passes (no SonarQube attempt)
const REVIEW_LEVEL = $(jsq "$REVIEW_LEVEL")     // from workspace.config.yaml review.level; 'strict' ⇒ Review gates report must-fixes ONLY (no fold-ins/Improvement tickets); 'thorough' ⇒ + nice-to-have
const LANGUAGE = $(jsq "$LANGUAGE")     // from workspace.config.yaml language; 'th' ⇒ English spine, Thai prose (docs/agents/language.md; see LANGUAGE_DIRECTIVE below); 'en' ⇒ unchanged
const LOADTEST = {   // from workspace.config.yaml loadtest.*; read by the base-branch non-degradation gate (docs/agents/loadtest-gate.md)
  tolerancePct: ${LT_TOL},            // a metric may degrade this much before it counts as a regression
  noiseRuns: ${LT_NOISE_RUNS},                // base-vs-base runs used to measure the env's own run-to-run spread
  noiseCeilingMultiple: ${LT_NOISE_CEIL},     // noise floor above tolerancePct × this ⇒ verdict 'unavailable' (env too coarse to judge)
  maxFixRounds: ${LT_FIX_ROUNDS},             // attributed-regression → developer fix → re-run loops before halting
  baselineCache: $(jsq "$LT_CACHE"),
}
const TEST_SUITE = {   // from workspace.config.yaml test_suite.*; read by the Test-suite phase red-gate triage loop
  maxFixRounds: ${TS_FIX_ROUNDS},             // classified-red → fix → scoped quality check → re-run loops
  maxSuiteRepairAttempts: ${TS_MAX_REPAIR},   // a suite that COULD NOT RUN: repair attempts before it is RECORDED unverified (docs/adr/0027)
}
const REVIEW = {   // from workspace.config.yaml review.*; the review loop's bounds (docs/adr/0027)
  maxRounds: ${RV_MAX_ROUNDS},                // reviewer pass + fix pass per repo — the ONE terminal bound
  maxRegressionFixes: ${RV_MAX_REGRESSION},   // a fix that caused a new blocking problem, handed straight back
  maxStallReattempts: ${RV_MAX_STALL},        // same finding set + no new commit ⇒ ESCALATE the brief, then retry
  maxEscalationAttempts: ${RV_MAX_ESCALATION},// cross-repo fix + scoped re-gate, per (repo, finding)
}
const BUILD = {   // from workspace.config.yaml build.*; the build phase's own bound (docs/adr/0032)
  maxContinuationPasses: ${BD_MAX_CONT},  // a \`partial\`/\`blocked\` handoff is CONTINUED this many times before it is RECORDED
}
const DEV_CYCLE = {   // from workspace.config.yaml dev_cycle.*; the run's own spend ceiling
  tokenBudget: ${DC_TOKEN_BUDGET},        // budget.spent() above this at a phase boundary ⇒ graceful stop (status 'budget-stopped'), fully resumable
}
const STATUS = {
${status_body}}
const REPOS = {
${repos_body}}
"

# prd.js design block (the canonical-file behavior the /prd-design design phase reads).
PRD_BODY="const LANGUAGE = $(jsq "$LANGUAGE")     // from workspace.config.yaml language; 'th' ⇒ English spine, Thai prose (docs/agents/language.md; see LANGUAGE_DIRECTIVE); 'en' ⇒ unchanged
const DESIGN_ENABLED = ${DESIGN_ENABLED}     // from workspace.config.yaml design.enabled; false ⇒ design phase skipped (no Figma)
const DESIGN_FIGMA_FILE_KEY = $(jsq "$DESIGN_KEY") // from workspace.config.yaml design.figma_file_key; set ⇒ build into THIS file (new page/feature), never create_new_file; empty ⇒ orphan file + WARN
const DESIGN_PAGE_NAMING = $(jsq "$DESIGN_PAGE")  // from workspace.config.yaml design.page_naming; tokens {work_key} {feature}
const IMAGE_GEN_ENABLED = ${IMAGE_GEN_ENABLED}     // from workspace.config.yaml image_generation.enabled; false ⇒ graphic-designer generates no images (assets 'unavailable')
const IMAGE_GEN_QUALITY = $(jsq "$IMG_QUALITY") // from workspace.config.yaml image_generation.quality (fast|balanced|quality)
const IMAGE_GEN_MAX_PER_REQUEST = ${IMG_MAX}        // from workspace.config.yaml image_generation.max_per_request; the graphic-designer's per-request budget cap
"

# ── render the would-be <name>.code-workspace JSON to stdout (jq required) ─────────
# CREATE path: seed { folders, settings }. MERGE path (file exists): replace ONLY `.folders`,
# preserving every other top-level key (esp. a user-edited `settings`). Both are deterministic.
render_workspace() {   # <target-file> → JSON on stdout; rc!=0 if jq missing / file unparseable
  local target="$1"
  command -v jq >/dev/null 2>&1 || return 2
  [[ -n "$FOLDERS_JSON" ]] || return 2
  if [[ -f "$target" ]]; then
    jq --argjson folders "$FOLDERS_JSON" '.folders = $folders' "$target"
  else
    jq -n --argjson folders "$FOLDERS_JSON" --argjson settings "$SEED_SETTINGS" \
      '{folders: $folders, settings: $settings}'
  fi
}

if [[ "$DRY" -eq 1 ]]; then
  printf '%s\n%s' "// ── dev-cycle.js ──" "$DEVCYCLE_BODY"
  [[ -n "$PRD_OK" ]] && printf '\n%s\n%s' "// ── prd.js (design) ──" "$PRD_BODY"
  printf '\n// ── %s ──\n' "$(basename "$WS_TARGET")"
  if ! render_workspace "$WS_TARGET"; then
    if command -v jq >/dev/null 2>&1; then
      printf '(existing %s is not valid JSON — it would be left untouched)\n' "$(basename "$WS_TARGET")"
    else
      printf "('jq' not found — %s would be skipped)\n" "$(basename "$WS_TARGET")"
    fi
  fi
  exit 0
fi

# ── 5. splice each BODY between its file's markers, validate, commit ───────────────
# Validation parses the spliced file in the engine's own context — a function BODY, `export`
# stripped — because that is how a workflow is loaded and it is NOT what `node --check` on the
# module checks. The two disagree in practice: a mis-escaped quote in a generated string exited
# `node --check` 0 on a file the engine could not load at all.
# node's EXIT STATUS is then CLASSIFIED, never just truthy-tested: 0 = valid; 1..127 =
# a genuine syntax error (show stderr + abort — the CONFIG really is broken); >=128 = node was
# KILLED BY A SIGNAL (sig = status-128) and CRASHED before it could judge the file (transient:
# memory pressure / a security agent), so we never blame the CONFIG, warn + skip validation,
# and still install the mechanically-generated block.
commit_block() {   # <target-file> <body> <in-sync-msg> <changed-msg>
  local target="$1" body="$2" insync_msg="$3" changed_msg="$4"
  local base; base="$(basename "$target")"
  local tmp; tmp="$(mktemp -t aiworks-config.XXXXXX)" && mv "$tmp" "$tmp.js" && tmp="$tmp.js" || die "mktemp failed"
  if ! BODY="$body" awk -v s="$START_RE" -v e="$END_RE" '
      index($0,s) { print; printf "%s", ENVIRON["BODY"]; inblk=1; next }
      index($0,e) { inblk=0 }
      inblk { next }
      { print }
    ' "$target" > "$tmp"; then
    rm -f "$tmp"; die "failed to rewrite $base"
  fi
  # Guard: the spliced file must still carry the END marker (otherwise markers were malformed).
  grep -qF "$END_RE" "$tmp" || { rm -f "$tmp"; die "lost the END marker while rewriting — left $base untouched"; }
  # Validate if node is around; refuse to install a workflow with a REAL syntax error — but
  # branch on node's EXIT STATUS, never a bare truthiness test (see the note above the function):
  #   exit 0     → valid; fall through and install.
  #   exit >=128 → node was KILLED BY A SIGNAL (sig = status-128); it CRASHED, it did NOT find a
  #                syntax error. Don't blame the CONFIG or this script: warn, skip validation,
  #                and still install the (mechanically-generated) block so the mirror can't drift.
  #   exit 1..127→ a genuine syntax error: show the captured stderr and abort, $base untouched.
  if command -v node >/dev/null 2>&1; then
    # Parse it the way the ENGINE loads a workflow, NOT the way node loads a module. The engine
    # never `import`s the file: it takes the source and builds a function BODY from it, so the
    # file has to parse in FUNCTION-BODY context. `node --check` parses the same file as a module
    # instead, and the two genuinely disagree — a mis-escaped quote in a generated string exited
    # `node --check` 0 while the workflow could not load at all. Same probe, and the same
    # reasoning, as .claude/hooks/dev-wrapper/posttool-workflow-compile.sh uses for hand edits.
    local nrc probe
    probe="$(mktemp -t aiworks-wfcheck.XXXXXX)" && mv "$probe" "$probe.cjs" && probe="$probe.cjs" \
      || { rm -f "$tmp"; die "mktemp failed while validating $base"; }
    { printf '(async function(args,budget,phase,agent,log,parallel,pipeline,workflow){\n'
      awk '!s && /^export /{ sub(/^export /,""); s=1 } { print }' "$tmp"
      printf '\n})();\n'
    } > "$probe"
    node --check "$probe" 2>/tmp/aiworks-nodecheck.$$; nrc=$?
    if [[ "$nrc" -ge 128 ]]; then
      warn "node was killed by signal $((nrc - 128)) (likely memory pressure or a security agent on this machine) — could not validate $base; proceeding without validation (the block is mechanically generated) — re-run 'aiworks config' to retry the check"
      rm -f "$probe" /tmp/aiworks-nodecheck.$$
    elif [[ "$nrc" -ne 0 ]]; then
      # Report the WORKFLOW's own line numbers: the probe adds exactly one leading line, and node
      # prints the probe's realpath, so match on its BASENAME rather than the full path.
      printf '%s' "$c_err" >&2
      awk -v pb="${probe##*/}" -v wf="$base" '
        { i=index($0, pb); if (i) { rest=substr($0, i+length(pb));
            if (match(rest, /^:[0-9]+/)) { n=substr(rest,2,RLENGTH-1)+0;
              print wf ":" (n-1) substr(rest, RLENGTH+1); next } }
          print }' /tmp/aiworks-nodecheck.$$ >&2
      printf '%s\n' "$c_off" >&2
      rm -f "$tmp" "$probe" /tmp/aiworks-nodecheck.$$
      die "the generated CONFIG does not load as a workflow — left $base untouched (this is a bug in aiworks-config.sh)"
    else
      rm -f "$probe" /tmp/aiworks-nodecheck.$$
    fi
  else
    # Say so. This is the ONE path that installs a workflow nobody has parsed, and it is the
    # path a brand-new machine takes: `aiworks sync` runs this generator before the node
    # toolchain is in place, so the check that exists silently does not happen.
    warn "node is not on PATH — installed $base WITHOUT validating it; run 'aiworks config' again once node is present"
  fi
  if cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    [[ "$QUIET" -eq 1 ]] || ok "$insync_msg"
  else
    mv "$tmp" "$target" && ok "$changed_msg"
  fi
}

commit_block "$TARGET" "$DEVCYCLE_BODY" \
  "dev-cycle.js CONFIG already in sync with workspace.config.yaml (${repo_count} repo(s))" \
  "regenerated dev-cycle.js CONFIG from workspace.config.yaml (${repo_count} repo(s), prefix ${PREFIX})"

if [[ -n "$PRD_OK" ]]; then
  commit_block "$PRD_TARGET" "$PRD_BODY" \
    "prd.js design/image-gen CONFIG already in sync with workspace.config.yaml (Figma ${DESIGN_ENABLED}, image-gen ${IMAGE_GEN_ENABLED})" \
    "regenerated prd.js design/image-gen CONFIG from workspace.config.yaml (design.enabled=${DESIGN_ENABLED}, image_generation.enabled=${IMAGE_GEN_ENABLED})"
fi

# ── 6. (re)generate the multi-root <name>.code-workspace from products[].repos[] ───
# A deterministic, config-derived artifact COMMITTED with the meta-repo, exactly like mani.d/.
# Folders = the meta-repo root first, then one root per declared repo (declared order). This is
# what makes VS Code/Cursor show each repo as its OWN Source Control provider — a gitignored
# nested clone is otherwise skipped by the folder-open git auto-detect, so only the meta-repo's
# diff would show. NON-DESTRUCTIVE: only the `folders` array is regenerated; any user-added
# top-level keys (esp. `settings`) survive. `settings` is seeded ONLY on first create.
commit_workspace() {   # <target-file>
  local target="$1" base; base="$(basename "$target")"
  if ! command -v jq >/dev/null 2>&1; then
    warn "'jq' not found — skipping $base (install jq to generate/maintain the multi-root workspace file)"
    return 0
  fi
  if [[ -z "$FOLDERS_JSON" ]]; then
    warn "no folders array built — skipping $base"
    return 0
  fi
  local tmp; tmp="$(mktemp -t aiworks-ws.XXXXXX)" || { warn "mktemp failed — skipping $base"; return 0; }
  if [[ -f "$target" ]]; then
    # MERGE: replace `.folders` in place, preserve every other top-level key (settings, …).
    if ! jq --argjson folders "$FOLDERS_JSON" '.folders = $folders' "$target" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"; warn "$base exists but is not valid JSON — left it untouched (fix or delete it, then re-run)"; return 0
    fi
  else
    # CREATE: seed folders + a sensible settings block (only here; never overwritten on regen).
    if ! jq -n --argjson folders "$FOLDERS_JSON" --argjson settings "$SEED_SETTINGS" \
           '{folders: $folders, settings: $settings}' > "$tmp" 2>/dev/null; then
      rm -f "$tmp"; warn "could not generate $base"; return 0
    fi
  fi
  if cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    [[ "$QUIET" -eq 1 ]] || ok "$base already in sync with workspace.config.yaml (${repo_count} repo root(s) + meta)"
  else
    mv "$tmp" "$target" && ok "regenerated $base (${repo_count} repo root(s) + meta) — open it with: cursor $base"
  fi
}

commit_workspace "$WS_TARGET"
