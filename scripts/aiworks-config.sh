#!/usr/bin/env bash
#
# aiworks-config.sh  (run it as: aiworks config) — regenerate the dev-cycle workflow's
# CONFIG block FROM workspace.config.yaml.
#
# WHY THIS EXISTS
#   Workflow scripts (.claude/workflows/dev-cycle.js) run in an engine sandbox with NO
#   filesystem access — they cannot read workspace.config.yaml at runtime. So the workflow
#   carries its own in-source MIRROR of the config (TICKET_PREFIX, the status map, the
#   auto-merge / planning flags, and the REPOS registry) in an AIWORKS-MANAGED block.
#
#   This script is the bridge: it reads workspace.config.yaml (the source of truth) and
#   REWRITES that managed block so the two never drift. `aiworks add`, `aiworks remove`, and
#   `aiworks sync` all call it automatically after they touch the config, so the workflow
#   tracks workspace.config.yaml with zero hand-editing.
#
# WHAT IT DERIVES (workspace.config.yaml → dev-cycle.js CONFIG)
#   tracker.ticket_prefix            → const TICKET_PREFIX
#   tracker.statuses.*               → const STATUS
#   vcs.auto_merge                   → const AUTO_MERGE
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
#   branch_model.{feature,fix}_base  → each repo's base.{feature,fix} (kind may override)
#   products[].repos[]               → const REPOS  (one entry per repo)
#       url               → the REPOS key (repo name) + path default
#       kind              → the role/gate DEFAULTS below (plan/build/review/guard/perf/
#                           testSuite/green/guardianFocus/base) — the single source of truth
#                           for what each kind means in the workflow
#       path / distribute / auto_merge / green / guardian_focus → optional per-repo overrides
#
# Idempotent and safe: it replaces only the region between the AIWORKS:CONFIG markers in
# dev-cycle.js, validates the result with `node --check` (when node is present), and restores
# the file untouched if anything goes wrong.
#
# Usage:
#   aiworks config [options]
#
#   --config <file>     workspace.config.yaml to read   (default: <workspace>/workspace.config.yaml)
#   --target <file>     dev-cycle.js to rewrite          (default: <workspace>/.claude/workflows/dev-cycle.js)
#   --prd-target <file> prd.js to rewrite (its design CONFIG) (default: <workspace>/.claude/workflows/prd.js)
#   -n, --dry-run      print the generated block(s) to stdout; do NOT write the target(s).
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
WC="" TARGET="" PRD_TARGET="" DRY=0 QUIET=0
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)     WC="${2:-}"; shift 2 ;;
    --target)     TARGET="${2:-}"; shift 2 ;;
    --prd-target) PRD_TARGET="${2:-}"; shift 2 ;;
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
[[ -n "$TARGET" ]]     || TARGET="$ROOT/.claude/workflows/dev-cycle.js"
[[ -n "$PRD_TARGET" ]] || PRD_TARGET="$ROOT/.claude/workflows/prd.js"
[[ -f "$WC" ]]     || die "no workspace.config.yaml at $WC — declare your repos under products: first"
[[ -f "$TARGET" ]] || die "no dev-cycle workflow at $TARGET"

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
jsq() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\'/\\\'}"; printf "'%s'" "$s"; }
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
STATUS_PAIRS=''   # accumulates "<canonical_key>\t<real name>\n" for EVERY status the org declares,
                  # in declared order. The workflow drives a monotonic subset (STATUS_ORDER); the
                  # rest are carried for humans/other tools — so a rich board isn't silently dropped.
while IFS=$'\t' read -r k v; do
  case "$k" in
    PREFIX)        PREFIX="$v" ;;
    AUTO_MERGE)    AM_RAW="$v" ;;
    AUTO_APPROVE)  AA_RAW="$v" ;;
    TO_HTML)       TH_RAW="$v" ;;
    FEATURE_BASE)  FEATURE_BASE="$v" ;;
    FIX_BASE)      FIX_BASE="$v" ;;
    NOTIFY_ENABLED)  NT_RAW="$v" ;;
    NOTIFY_PROVIDER) NOTIFY_PROVIDER="$v" ;;
    NOTIFY_CHANNEL)  NOTIFY_CHANNEL="$v" ;;
    DESIGN_ENABLED)     DESIGN_EN_RAW="$v" ;;
    DESIGN_FIGMA_KEY)   DESIGN_KEY="$v" ;;
    DESIGN_PAGE_NAMING) DESIGN_PAGE="$v" ;;
    IMG_ENABLED)        IMG_EN_RAW="$v" ;;
    IMG_QUALITY)        IMG_QUALITY="$v" ;;
    IMG_MAX)            IMG_MAX="$v" ;;
    ST_*)          STATUS_PAIRS+="${k#ST_}"$'\t'"$v"$'\n' ;;   # pass through every declared status
  esac
done < <(
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec); instat=0 }   # new top-level section
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
    sec=="design"       && /^  enabled:/         { print "DESIGN_ENABLED\t"     val($0); next }
    sec=="design"       && /^  figma_file_key:/  { print "DESIGN_FIGMA_KEY\t"   val($0); next }
    sec=="design"       && /^  page_naming:/     { print "DESIGN_PAGE_NAMING\t" val($0); next }
    sec=="image_generation" && /^  enabled:/         { print "IMG_ENABLED\t" val($0); next }
    sec=="image_generation" && /^  quality:/         { print "IMG_QUALITY\t" val($0); next }
    sec=="image_generation" && /^  max_per_request:/ { print "IMG_MAX\t"     val($0); next }
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
# Fall back to the historical 5-phase lifecycle when the org declared no statuses.
if [[ -z "$STATUS_PAIRS" ]]; then
  STATUS_PAIRS=$'not_started\tNot started\nin_progress\tIn progress\nready_to_test\tReady to test\ntesting\tTesting\ndone\tDone\n'
fi

# ── 2. kind → role/gate DEFAULTS (the one authoritative table) ────────────────────
# `kind` is a FREE-FORM, tech-agnostic development-context label (frontend, backend,
# web-app, service, migration, generic, …) — the tech is captured by `lang`, NOT the kind.
# Behaviour is decided by ARCHETYPE, and there are exactly two:
#   test-suite → QA pipeline: qa-planner/qa-runner build the suite, no code review, and this
#                repo PROVIDES the cross-repo test-suite gate. The ONE behaviourally-special kind.
#   * (any     → a "code" repo: plan→build→review (development-planner + developer + code-reviewer)
#   other kind)  with the guard + perf gates on. Refine per repo via green / guardian_focus.
# Echoes TAB-separated: plan build review guard perf testSuite base_feature base_fix
# green guardianFocus   — `review`/`base_*` are bare; green/guardianFocus are free text.
kind_defaults() {
  local kind="$1"
  case "$kind" in
    test-suite)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        qa-planner qa-runner null false false true "$FIX_BASE" "$FIX_BASE" \
        'the ticket + regression specs (scoped `npm test -- <specs>`, POM) green on every target platform the suite covers — the full-suite run is on-demand' \
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
while IFS=$'\037' read -r url kind path dist green gf am; do   # \037 (US): empty fields preserved
  [[ -n "$url" ]] || continue
  name="${url%.git}"; name="${name##*/}"; name="${name##*:}"
  [[ -n "$name" ]] || { warn "could not derive a repo name from url '$url' — skipped"; continue; }
  kind="${kind:-generic}"
  path="${path:-$name}"

  IFS=$'\t' read -r d_plan d_build d_review d_guard d_perf d_testsuite d_basef d_basex d_green d_gf \
    < <(kind_defaults "$kind")

  # per-repo overrides (else the kind default)
  [[ -n "$green" ]] && d_green="$green"
  [[ -n "$gf" ]]    && d_gf="$gf"

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
      else if(k~/^auto_merge:/) am=val(k) }
    function flush(){ if(url!=""){ printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", url,kind,path,dist,green,gf,am }
      url="";kind="";path="";dist="";green="";gf="";am="" }
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
const DESIGN_ENABLED = ${DESIGN_ENABLED}     // from workspace.config.yaml design.enabled; false ⇒ Figma OFF workspace-wide (dev/QA build from spec, not a Figma screenshot)
const STATUS = {
${status_body}}
const REPOS = {
${repos_body}}
"

# prd.js design block (the canonical-file behavior the /prd design phase reads).
PRD_BODY="const DESIGN_ENABLED = ${DESIGN_ENABLED}     // from workspace.config.yaml design.enabled; false ⇒ design phase skipped (no Figma)
const DESIGN_FIGMA_FILE_KEY = $(jsq "$DESIGN_KEY") // from workspace.config.yaml design.figma_file_key; set ⇒ build into THIS file (new page/feature), never create_new_file; empty ⇒ orphan file + WARN
const DESIGN_PAGE_NAMING = $(jsq "$DESIGN_PAGE")  // from workspace.config.yaml design.page_naming; tokens {work_key} {feature}
const IMAGE_GEN_ENABLED = ${IMAGE_GEN_ENABLED}     // from workspace.config.yaml image_generation.enabled; false ⇒ graphic-designer generates no images (assets 'unavailable')
const IMAGE_GEN_QUALITY = $(jsq "$IMG_QUALITY") // from workspace.config.yaml image_generation.quality (fast|balanced|quality)
const IMAGE_GEN_MAX_PER_REQUEST = ${IMG_MAX}        // from workspace.config.yaml image_generation.max_per_request; the graphic-designer's per-request budget cap
"

if [[ "$DRY" -eq 1 ]]; then
  printf '%s\n%s' "// ── dev-cycle.js ──" "$DEVCYCLE_BODY"
  [[ -n "$PRD_OK" ]] && printf '\n%s\n%s' "// ── prd.js (design) ──" "$PRD_BODY"
  exit 0
fi

# ── 5. splice each BODY between its file's markers, validate, commit ───────────────
# .js suffix so `node --check` validates the temp exactly as the real workflow is named:
# the workflow mixes `export` with top-level `return` (the Workflow engine wraps it in an
# async fn), which node accepts under .js but not under strict-ESM .mjs; an unknown/random
# extension instead makes node's loader bail with ERR_UNKNOWN_FILE_EXTENSION.
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
  # Validate JS if node is around; refuse to install a broken workflow.
  if command -v node >/dev/null 2>&1; then
    if ! node --check "$tmp" 2>/tmp/aiworks-nodecheck.$$; then
      printf '%s%s%s\n' "$c_err" "$(cat /tmp/aiworks-nodecheck.$$ 2>/dev/null)" "$c_off" >&2
      rm -f "$tmp" /tmp/aiworks-nodecheck.$$
      die "generated CONFIG failed node --check — left $base untouched (this is a bug in aiworks-config.sh)"
    fi
    rm -f /tmp/aiworks-nodecheck.$$
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
