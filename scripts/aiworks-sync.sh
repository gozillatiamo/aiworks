#!/usr/bin/env bash
#
# aiworks-sync.sh  (run it as: aiworks sync) — onboard every repo declared in workspace.config.yaml.
#
# workspace.config.yaml is the SOURCE OF TRUTH: add a repo's URL under products[].repos[]
# and run this to set EVERYTHING up. For each declared repo it runs the full per-repo
# `aiworks add` toolchain (generate the mani.d entry, clone via mani, codegraph index, skill
# packs, hooks/settings, CLAUDE.md, scripts/dev.sh, skill generator, codegraph sync) — reading
# url/kind/lang/distribute/path straight from the config so you never retype them.
#
# Use it to bring up a workspace from a freshly-edited config, or to re-sync the whole set:
# `aiworks add` is idempotent, so repos already set up just report SKIP and move on.
#
# It also PREPARES the adapter .env files (scripts/{tracker,vcs,notify}/.env) when they are missing:
# each is seeded from its committed .env.example and pre-filled with the values derivable from
# workspace.config.yaml (vcs.provider → VCS_PROVIDER; tracker.provider → TRACKER_PROVIDER;
# tracker.ticket_prefix → JIRA_PROJECT_KEY for jira; tracker.statuses.done → NOTION_STATUS_DONE
# for notion; notify.provider/channel → NOTIFY_PROVIDER/NOTIFY_CHANNEL). An existing .env is left
# untouched — you still fill in the secrets by hand (e.g. the Slack token in notify/.env).
#
# It also PREPARES the image-generation config: ensures the git-ignored
# .claude/settings.local.json enables the `mcp-image` MCP server, and checks that
# GEMINI_API_KEY is present in the workspace-root `.env` (direnv — MCP secret SoT).
# Put the key there (https://aistudio.google.com/apikey); until then /prd-design
# preflight detects the gap and fails loud instead of shipping placeholder art.
#
# It also ENSURES the Obsidian vault share-contract: seeds `.obsidian/{app,appearance,
# core-plugins}.json` when missing (never clobbers) and keeps a managed `.gitignore` block that
# ignores personal UI layout (`workspace.json` / `workspace-mobile.json` / `graph.json`) so teammates inherit
# vault abilities without each other's open tabs. See docs/agents/obsidian.md.
#
# It also ENSURES codegraph (https://github.com/colbymchenry/codegraph) — the per-repo index the
# build/review agents grep through — is installed: a machine-wide CLI installed once for the whole
# sweep (npm i -g @colbymchenry/codegraph, else the bundled curl|sh installer). A no-op when it's
# already on PATH; best-effort, so a failed install just makes the repos' index steps SKIP.
#
# It does NOT set up deployed-environment triage. Registering the read-only triage MCPs is
# `scripts/triage-mcp.sh sync`, and the Kubernetes triage IDENTITY is created per cluster by a
# GCP project owner running `scripts/k8s/bootstrap-sa.sh` — neither is something a repo-onboarding
# sweep should do on your behalf, and the k8s check alone cost several gcloud/kubectl round-trips
# on every run. Sync REPORTS both in its summary; `aiworks doctor` scores them and `--fix` runs
# the one that is safe to automate. See docs/adr/0009.
#
# It also ENSURES the workspace lifecycle hooks — .superset/{setup,run,teardown}.sh — exist and
# that .superset/config.json registers all three (via scripts/aiworks-superset.sh). The hooks loop
# over every cloned repo, so the synced set is covered automatically; this creates the run hook
# (.superset/run.sh → each repo's `scripts/dev.sh run`) on workspaces that predate it.
#
# Usage:
#   aiworks sync [<product>|<repo>] [options]
#
#   <product>|<repo>      Narrow the sweep. If it names a product (products[].id) only that
#                         product's repos sync; otherwise it is treated as a repo name and ONLY
#                         that repo syncs (default: every repo of every product).
#   --repo <name>         Only sync the repo(s) with this name — repeatable, or comma-separated
#                         (e.g. --repo your-app,your-tests). Matches a repo's clone-dir name
#                         (the last URL segment, minus .git) or its `path:` override. Combine with
#                         a <product> to scope the match within that product.
#   --kind <kind>         Force the kind for ALL synced repos (overrides each entry's kind).
#   --distribute <how>    Override distribute for all synced repos (default: from each entry).
#   --skill-cmd <slash>   Forwarded to `aiworks add`.
#   --claude-timeout <s>  Forwarded to `aiworks add`.
#   --safe-perms          Forwarded to `aiworks add`.
#   --force               Forwarded — re-run already-done steps.
#   -y, --yes             Forwarded to `aiworks add` — assume yes: skip its Proceed prompt and,
#                         for a repo that already has a CLAUDE.md, skip it. OPT-IN: omit it and
#                         each repo runs interactively (e.g. asks regenerate/combine/skip an
#                         existing CLAUDE.md, read from /dev/tty). With no controlling terminal
#                         (CI/headless) `add` proceeds with its defaults either way — never blocks.
#   -n, --dry-run         List what WOULD be synced (and the add command per repo); run nothing.
#                         (implies --verbose — the preview is the whole point.)
#   -v, --verbose         Show the full step-by-step log. Output is QUIET by default — only
#                         warnings, errors, and the closing sync-summary section print (and -v
#                         is propagated to each per-repo `aiworks add`).
#   -h, --help            Show this help.
#
set -uo pipefail

# ── logging ─────────────────────────────────────────────────────────────────────
# QUIET by default: progress chatter (step/ok/dim) prints only with -v/--verbose (VERBOSE=1).
# warn/die ALWAYS print (problems must surface); the final sync-summary section is printed with
# raw printf below — unconditional — so the run always ENDS with its conclusion. A dry-run forces
# VERBOSE on (the preview IS the output), wired up right after arg parsing.
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
VERBOSE=0
step() { [[ "$VERBOSE" -eq 1 ]] || return 0; printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { [[ "$VERBOSE" -eq 1 ]] || return 0; printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
dim()  { [[ "$VERBOSE" -eq 1 ]] || return 0; printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

# Ctrl+C / kill stops the whole sweep, not just the current repo.
trap 'printf "\n%s✗ sync interrupted%s\n" "$c_warn" "$c_off" >&2; exit 130' INT TERM

# ── codegraph: install it once for the whole sweep if missing ─────────────────────
# codegraph (https://github.com/colbymchenry/codegraph) builds the per-repo index the
# build/review agents grep through. It's a MACHINE-WIDE CLI — installed once, not per repo —
# so we do it here as a workspace-level prep step (the per-repo `aiworks add` also self-installs
# at its step 4 for standalone runs; called from here it just finds it on PATH and skips).
# Prefer npm (any Node, all platforms); fall back to the bundled installer (curl … | sh —
# vendored runtime, no Node needed), which drops the binary in ~/.local/bin WITHOUT editing
# PATH, so we surface that dir on PATH (and export it to the child `aiworks add` runs).
# Best-effort: a failed install is reported and the repos' index steps SKIP, never aborting.
ensure_codegraph() {
  step "Ensure codegraph is installed (the per-repo index the build/review agents use)"
  if command -v codegraph >/dev/null 2>&1; then ok "codegraph already on PATH ($(command -v codegraph))"; return 0; fi
  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould install codegraph (npm i -g @colbymchenry/codegraph, or the bundled installer)%s\n' "$c_dim" "$c_off"
    return 0
  fi
  if command -v npm >/dev/null 2>&1; then
    dim "npm i -g @colbymchenry/codegraph"
    npm i -g @colbymchenry/codegraph >/dev/null 2>&1 || true
  fi
  if ! command -v codegraph >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    dim "curl -fsSL …/install.sh | sh"
    curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh >/dev/null 2>&1 || true
  fi
  # The bundled installer symlinks into ~/.local/bin (or $CODEGRAPH_BIN_DIR) without editing
  # PATH — surface it so this sweep AND the child `aiworks add` runs (which inherit our env) see it.
  local cg_bin="${CODEGRAPH_BIN_DIR:-$HOME/.local/bin}"
  if [[ -x "$cg_bin/codegraph" ]]; then case ":$PATH:" in *":$cg_bin:"*) ;; *) export PATH="$cg_bin:$PATH" ;; esac; fi
  if command -v codegraph >/dev/null 2>&1; then ok "codegraph installed ($(command -v codegraph))"
  else warn "could not install codegraph automatically (need npm or curl + network) — install it by hand (https://github.com/colbymchenry/codegraph); repos' index steps will SKIP until then"; fi
}

# ── graphify: install it once for the whole sweep if missing ──────────────────────
# graphify (https://github.com/Graphify-Labs/graphify) builds the META REPO's doc graph —
# prose only: docs/, docs/adr/ and the markdown under .claude/ and scripts/. It is NOT a
# per-repo tool and never indexes product code: codegraph owns code because it returns a
# symbol's verbatim source in one call, which graphify structurally cannot (its nodes carry
# a start line and no text). The split is recorded in docs/adr/0013.
# Python 3.12 is pinned deliberately — graphify's Leiden clustering will not run on 3.13+.
# Best-effort like codegraph above: a failed install is reported and the doc-graph step
# SKIPs, never aborting the sweep.
ensure_graphify() {
  step "Ensure graphify is installed (the meta repo's doc graph — prose only, ADR-0013)"
  if command -v graphify >/dev/null 2>&1; then ok "graphify already on PATH ($(command -v graphify))"; return 0; fi
  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould install graphify (uv tool install --python 3.12 "graphifyy[leiden,svg,sql]")%s\n' "$c_dim" "$c_off"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    dim 'uv tool install --python 3.12 "graphifyy[leiden,svg,sql]"'
    uv tool install --python 3.12 "graphifyy[leiden,svg,sql]" >/dev/null 2>&1 || true
  elif command -v pipx >/dev/null 2>&1; then
    dim 'pipx install "graphifyy[leiden,svg,sql]"'
    pipx install "graphifyy[leiden,svg,sql]" >/dev/null 2>&1 || true
  fi
  # uv tool and pipx both drop console scripts into ~/.local/bin without editing PATH —
  # surface it so this sweep and the child `aiworks add` runs (which inherit our env) see it.
  local gf_bin="$HOME/.local/bin"
  if [[ -x "$gf_bin/graphify" ]]; then case ":$PATH:" in *":$gf_bin:"*) ;; *) export PATH="$gf_bin:$PATH" ;; esac; fi
  if command -v graphify >/dev/null 2>&1; then ok "graphify installed ($(command -v graphify))"
  else warn "could not install graphify automatically (need uv or pipx + network) — install it by hand (uv tool install --python 3.12 'graphifyy[leiden,svg,sql]'); the doc-graph step will SKIP until then"; fi
}

# ── the meta repo's doc graph: report, never silently rebuild ─────────────────────
# graph.json + GRAPH_REPORT.md are COMMITTED, so a fresh clone already has the map and a
# sync must not spend the semantic pass again (~1.3M input tokens over 192 prose files,
# serialised — graphify forces concurrency 1 on the claude-cli backend). So this step only
# reports, and hands over the one command that refreshes it. It also installs the git merge
# driver, which is what stops two people committing graph.json in parallel from landing
# conflict markers in it.
sync_doc_graph() {
  step "Check the meta repo's doc graph (reports only — never re-spends the semantic pass)"
  command -v graphify >/dev/null 2>&1 || { warn "graphify not on PATH — doc graph not checked"; return 0; }
  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould run graphify check-update . and graphify hook install%s\n' "$c_dim" "$c_off"
    return 0
  fi
  if [[ ! -f "graphify-out/graph.json" ]]; then
    warn "no doc graph yet — build it once with: graphify extract . --backend claude-cli"
    return 0
  fi
  graphify hook install >/dev/null 2>&1 || true   # post-commit rebuild + graph.json merge driver
  if graphify check-update . >/dev/null 2>&1; then ok "doc graph present and current"
  else warn "doc graph is stale — refresh with: graphify extract . --backend claude-cli"; fi
}

DIR="$(cd "$(dirname "$0")" && pwd)"
ADD="$DIR/aiworks-add.sh"
[[ -x "$ADD" ]] || die "aiworks-add.sh not found/executable next to aiworks-sync.sh ($ADD)"

# ── args ──────────────────────────────────────────────────────────────────────
PRODUCT="" KIND="" DISTRIBUTE="" SKILL_CMD="" CLAUDE_TIMEOUT="" SAFE=0 FORCE=0 DRY=0 YES=0
SELECTOR=""        # the positional: a product id OR a repo name (auto-detected below)
REPO_FILTER=""     # space-separated repo names/paths to restrict to (from --repo and/or a repo positional)
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)            KIND="${2:-}"; shift 2 ;;
    --distribute)      DISTRIBUTE="${2:-}"; shift 2 ;;
    --repo)            [[ -n "${2:-}" ]] || die "--repo needs a repo name"; REPO_FILTER="$REPO_FILTER ${2//,/ }"; shift 2 ;;
    --skill-cmd)       SKILL_CMD="${2:-}"; shift 2 ;;
    --claude-timeout)  CLAUDE_TIMEOUT="${2:-}"; shift 2 ;;
    --safe-perms)      SAFE=1; shift ;;
    --force)           FORCE=1; shift ;;
    -y|--yes)          YES=1; shift ;;
    -n|--dry-run)      DRY=1; shift ;;
    -v|--verbose)      VERBOSE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                die "unknown option: $1   (see -h)" ;;
    *)                 [[ -z "$SELECTOR" ]] || die "unexpected argument: $1 (one <product>|<repo> only)"; SELECTOR="$1"; shift ;;
  esac
done

# A dry run is all about its preview, so show the full output regardless of the quiet default.
[[ "$DRY" -eq 1 ]] && VERBOSE=1

# ── locate the workspace root ───────────────────────────────────────────────────
ROOT="$(cd "$DIR/.." && pwd)"
cd "$ROOT" || die "cannot cd to workspace root"
[[ -f "$ROOT/mani.yaml" ]] || die "no mani.yaml in $ROOT — run this from a workspace (next to mani.yaml)"
WC="$ROOT/workspace.config.yaml"
[[ -f "$WC" ]] || die "no workspace.config.yaml in $ROOT — copy workspace.config.example.yaml and declare your repos under products:"

# Parse products[].repos[] → one line per repo:  product \037 url \037 kind \037 lang \037 distribute \037 path \037 desc
# Indentation contract (see workspace.config.example.yaml): products: at col 0; `  - id:`
# (2sp) per product; `    repos:` (4sp); `      - url:` (6sp) per repo; `        <field>:` (8sp).
parse_repos() {
  awk '
    # A quoted scalar is read to its closing quote and unescaped, so a value holding ":",
    # "#", or a quote round-trips through aiworks-add.sh (which writes desc double-quoted).
    # Only an UNQUOTED value gets the trailing-comment strip — inside quotes, "#" is content.
    function val(s,   r,i,c){ sub(/^[^:]*:[ \t]*/,"",s)
      if(s ~ /^"/){ r=""
        for(i=2;i<=length(s);i++){ c=substr(s,i,1)
          if(c=="\\" && i<length(s)){ i++; r=r substr(s,i,1); continue }
          if(c=="\""){ break }
          r=r c }
        return r }
      if(s ~ /^'\''/){ r=""
        for(i=2;i<=length(s);i++){ c=substr(s,i,1)
          if(c=="'\''"){ if(substr(s,i+1,1)=="'\''"){ r=r "'\''"; i++; continue } break }
          r=r c }
        return r }
      sub(/[ \t]+#.*$/,"",s); return s }
    function setkv(line){ k=line; sub(/^[ \t]*/,"",k)
      if(k ~ /^url:/) url=val(k); else if(k ~ /^kind:/) kind=val(k)
      else if(k ~ /^lang:/) lang=val(k); else if(k ~ /^distribute:/) dist=val(k)
      else if(k ~ /^desc:/ || k ~ /^description:/) desc=val(k)
      else if(k ~ /^path:/) path=val(k) }
    function flush(){ if(url!=""){ printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", prod,url,kind,lang,dist,path,desc }
      url="";kind="";lang="";dist="";path="";desc="" }
    /^products:[ \t]*$/ { inp=1; next }
    inp && /^  - id:/ { flush(); prod=val($0); inrepos=0; next }
    inp && /^    repos:[ \t]*$/ { inrepos=1; next }
    inp && /^    [A-Za-z_]/ { inrepos=0; next }
    inrepos && /^      - / { flush(); l=$0; sub(/^      - /,"",l); setkv(l); next }
    inrepos && /^        [A-Za-z_]/ { setkv($0); next }
    /^[A-Za-z_]/ { flush(); inp=0; inrepos=0 }
    END{ flush() }
  ' "$WC"
}

# ── adapter .env preparation ─────────────────────────────────────────────────────
# scripts/{tracker,vcs,notify}/.env are git-ignored LOCAL config the adapters source at runtime
# (scripts/{tracker,vcs,notify}/lib.sh). They normally have to be hand-copied from .env.example
# and filled in. We can do better: seed each MISSING one from its committed .env.example
# and pre-fill the values DERIVABLE from workspace.config.yaml — the providers, the Jira
# project key, the Notion done-status, the notify channel. An EXISTING .env is never touched (we
# don't clobber a human's secrets); the rest of each .env keeps its .env.example comments to fill in by hand.

# Set KEY=VALUE in a .env file, in place: if a live OR commented-out `KEY=` line exists,
# replace the first one; otherwise append. Keeps the surrounding template/comments intact.
env_set() {
  local file="$1" key="$2" value="$3" tmp
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file" 2>/dev/null; then
    tmp="$(mktemp)" || return 1
    awk -v k="$key" -v v="$value" '
      !done && $0 ~ ("^[[:space:]]*#?[[:space:]]*" k "=") { print k "=" v; done=1; next }
      { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# Seed <dir>/.env from <dir>/.env.example (only if .env is missing) and set the given
# KEY VALUE pairs (a pair with an empty value is skipped). Honours $DRY. <dir> may not
# exist (nothing to do) — e.g. a workspace that ships only one adapter.
seed_env_file() {
  local dir="$1"; shift
  local env="$dir/.env" ex="$dir/.env.example" rel="${dir#$ROOT/}/.env"
  [[ -d "$dir" ]] || return 0

  # Describe the keys we'd actually set (skip empty values).
  local -a pairs=("$@"); local kv='' i
  for ((i=0; i<${#pairs[@]}; i+=2)); do
    [[ -n "${pairs[i+1]:-}" ]] && kv+="${kv:+, }${pairs[i]}=${pairs[i+1]}"
  done

  if [[ -f "$env" ]]; then
    ok "$rel exists — left untouched"
    return 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould create %s%s%s\n' "$c_dim" "$rel" "${kv:+ (set $kv)}" "$c_off"
    return 0
  fi

  if [[ -f "$ex" ]]; then
    cp "$ex" "$env" || { warn "could not seed $rel from $(basename "$ex")"; return 1; }
  else
    printf '# Seeded by `aiworks sync` from workspace.config.yaml. Fill in any secrets below.\n' > "$env"
  fi
  for ((i=0; i<${#pairs[@]}; i+=2)); do
    [[ -n "${pairs[i+1]:-}" ]] && env_set "$env" "${pairs[i]}" "${pairs[i+1]}"
  done
  ok "created $rel${kv:+ — set $kv}"
}

# Read the workspace.config.yaml scalars that map onto adapter env vars, then seed the
# tracker + vcs .env files. Provider-specific keys are only added for that provider.
prepare_adapter_env() {
  local vcs_provider='' tracker_provider='' ticket_prefix='' status_done='' notify_provider='' notify_channel=''
  local design_enabled='' design_file_key=''
  while IFS=$'\t' read -r k v; do
    case "$k" in
      VCS_PROVIDER)     vcs_provider="$v" ;;
      TRACKER_PROVIDER) tracker_provider="$v" ;;
      TICKET_PREFIX)    ticket_prefix="$v" ;;
      STATUS_DONE)      status_done="$v" ;;
      NOTIFY_PROVIDER)  notify_provider="$v" ;;
      NOTIFY_CHANNEL)   notify_channel="$v" ;;
      DESIGN_ENABLED)   design_enabled="$v" ;;
      DESIGN_FILE_KEY)  design_file_key="$v" ;;
    esac
  done < <(
    awk '
      function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                       gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
      /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec); instat=0 }
      sec=="vcs"     && /^  provider:/           { print "VCS_PROVIDER\t"     val($0); next }
      sec=="tracker" && /^  provider:/           { print "TRACKER_PROVIDER\t" val($0); next }
      sec=="tracker" && /^  ticket_prefix:/      { print "TICKET_PREFIX\t"    val($0); next }
      sec=="tracker" && /^  statuses:[ \t]*$/    { instat=1; next }
      sec=="tracker" && instat && /^    done:/   { print "STATUS_DONE\t"      val($0); next }
      sec=="tracker" && instat && /^  [A-Za-z_]/ { instat=0 }
      sec=="notify"  && /^  provider:/           { print "NOTIFY_PROVIDER\t"  val($0); next }
      sec=="notify"  && /^  channel:/            { print "NOTIFY_CHANNEL\t"   val($0); next }
      sec=="design"  && /^  enabled:/            { print "DESIGN_ENABLED\t"   val($0); next }
      sec=="design"  && /^  figma_file_key:/     { print "DESIGN_FILE_KEY\t"  val($0); next }
    ' "$WC"
  )

  step "Prepare adapter .env files from workspace.config.yaml"

  # vcs/.env — the provider (the adapter otherwise auto-detects it from the origin remote).
  seed_env_file "$DIR/vcs" VCS_PROVIDER "$vcs_provider"

  # tracker/.env — the provider, plus the one provider-specific value the config carries.
  local -a tkv=(TRACKER_PROVIDER "$tracker_provider")
  case "$tracker_provider" in
    jira)   tkv+=(JIRA_PROJECT_KEY  "$ticket_prefix") ;;   # ticket_prefix == the Jira project key
    notion) tkv+=(NOTION_STATUS_DONE "$status_done") ;;    # the "done" status name find-tickets uses
    linear) tkv+=(LINEAR_TEAM_KEY   "$ticket_prefix") ;;   # ticket_prefix == the Linear team key
  esac
  seed_env_file "$DIR/tracker" "${tkv[@]}"

  # notify/.env — the provider + default channel (the Slack token/webhook is filled in by hand).
  seed_env_file "$DIR/notify" NOTIFY_PROVIDER "$notify_provider" NOTIFY_CHANNEL "$notify_channel"

  # design — surface the Figma policy (no adapter .env; the mirror is regenerated by
  # `aiworks config`, which sync calls separately). See docs/agents/figma.md.
  case "$(printf '%s' "$design_enabled" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1)
      if [[ -n "$design_file_key" ]]; then
        ok "Design: Figma ENABLED; canonical file ${design_file_key} (screens build there — new page per feature)"
      else
        warn "Design: Figma ENABLED but design.figma_file_key is EMPTY — /prd-design runs will create NEW ORPHAN files. Set design.figma_file_key in workspace.config.yaml to build into the org's canonical file."
      fi ;;
    *) ok "Design: Figma DISABLED (design.enabled is off — the default). No agent calls Figma; set design.enabled: true to design." ;;
  esac
}

# ── image-generation config (mcp-image + GEMINI_API_KEY) ─────────────────────────
# The graphic-designer (Fiona) generates assets through the `mcp-image` MCP server
# (`mcp__mcp-image__generate_image`, Gemini) + the /image-generation skill. That server
# is launched via scripts/mcp/mcp-image.sh, which loads GEMINI_API_KEY from the
# workspace-root `.env` (direnv) — the single source of truth for MCP secrets. Do NOT
# put the key in `.claude/settings.local.json`. Here we only enable "mcp-image" in that
# file and check that `.env` already has a non-empty GEMINI_API_KEY (presence only).
seed_image_gen_settings() {
  local sl="$ROOT/.claude/settings.local.json" rel=".claude/settings.local.json"
  step "Prepare image-gen config (mcp-image; GEMINI_API_KEY from .env) in $rel"

  # image_generation policy from workspace.config.yaml (default OFF). When disabled we do NOT
  # wire up mcp-image — the graphic-designer's availability gate then returns assets as
  # 'unavailable'. quality/max are behavioral (the graphic-designer passes quality= per call
  # and honors the budget cap), surfaced here for visibility. See docs/agents/image-generation.md.
  local ig_enabled='' ig_quality='balanced' ig_max='2'
  if [[ -f "$WC" ]]; then
    while IFS=$'\t' read -r k v; do
      case "$k" in
        IG_ENABLED) ig_enabled="$v" ;;
        IG_QUALITY) ig_quality="$v" ;;
        IG_MAX)     ig_max="$v" ;;
      esac
    done < <(
      awk '
        function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                         gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
        /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec) }
        sec=="image_generation" && /^  enabled:/         { print "IG_ENABLED\t" val($0); next }
        sec=="image_generation" && /^  quality:/         { print "IG_QUALITY\t" val($0); next }
        sec=="image_generation" && /^  max_per_request:/ { print "IG_MAX\t"     val($0); next }
      ' "$WC"
    )
  fi
  case "$(printf '%s' "$ig_enabled" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) : ;;   # enabled — wire up mcp-image below
    *) ok "Image generation DISABLED (image_generation.enabled is off — the default). mcp-image not wired up; the graphic-designer returns assets 'unavailable'. Set image_generation.enabled: true to generate."
       return 0 ;;
  esac

  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould ensure %s enables "mcp-image" and check .env for GEMINI_API_KEY (quality=%s, max_per_request=%s)%s\n' "$c_dim" "$rel" "$ig_quality" "$ig_max" "$c_off"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node not found — can't auto-prepare $rel; add \"mcp-image\" to enabledMcpjsonServers by hand (see docs/agents/image-generation.md)"
    return 0
  fi
  local out
  out="$(NODE_SL="$sl" node <<'NODE'
const fs = require('fs');
const f = process.env.NODE_SL;
let raw = '';
try { raw = fs.readFileSync(f, 'utf8'); } catch (e) { raw = ''; }
let j;
if (raw.trim() === '') { j = {}; }
else { try { j = JSON.parse(raw); } catch (e) { console.log('PARSE_ERROR'); process.exit(0); } }
j.enabledMcpjsonServers = Array.isArray(j.enabledMcpjsonServers) ? j.enabledMcpjsonServers : [];
let changed = false;
if (!j.enabledMcpjsonServers.includes('mcp-image')) { j.enabledMcpjsonServers.unshift('mcp-image'); changed = true; }
// Secrets live in workspace .env — drop stale GEMINI_API_KEY from settings.local if present.
j.env = (j.env && typeof j.env === 'object' && !Array.isArray(j.env)) ? j.env : {};
if ('GEMINI_API_KEY' in j.env) { delete j.env.GEMINI_API_KEY; changed = true; }
if (Object.keys(j.env).length === 0) { delete j.env; changed = true; }
if (changed) {
  try { if (fs.existsSync(f)) fs.copyFileSync(f, f + '.bak'); } catch (e) {}
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + '\n');
}
console.log(changed ? 'CHANGED' : 'OK');
NODE
)"
  local has_key=0
  # Presence only — never print the value (CLAUDE.md .env rule).
  if [[ -f "$ROOT/.env" ]] && grep -q '^GEMINI_API_KEY=.\+' "$ROOT/.env"; then
    has_key=1
  fi
  case "$out" in
    PARSE_ERROR) warn "$rel is not valid JSON — left untouched; add \"mcp-image\" to enabledMcpjsonServers by hand" ;;
    CHANGED|OK)
      if [[ "$has_key" -eq 1 ]]; then
        ok "$rel ready — mcp-image enabled; GEMINI_API_KEY present in .env (quality=${ig_quality}, max_per_request=${ig_max})"
      else
        ok "$rel prepared — mcp-image enabled; now set GEMINI_API_KEY in the workspace .env (key: https://aistudio.google.com/apikey; quality=${ig_quality}, max_per_request=${ig_max}; see docs/agents/image-generation.md)"
      fi ;;
    *) warn "could not determine image-gen state for $rel" ;;
  esac
}


# ── Obsidian vault (shared settings; personal UI layout ignored) ─────────────────
# The workspace meta-repo is a valid Obsidian vault for reading docs/. Teammates share
# vault abilities (core plugins, appearance, app settings) via committed `.obsidian/*`
# files; each person's open tabs/panes stay local. Sync seeds the shareable files when
# missing and keeps a managed .gitignore block for workspace*.json — same shape as the
# `aiworks cursor` plugin-skill block. Never clobbers an existing file.
# See docs/agents/obsidian.md.
GI_OBSIDIAN_BEGIN='# >>> aiworks sync: obsidian (generated — do not edit by hand)'
GI_OBSIDIAN_END='# <<< aiworks sync: obsidian'

ensure_obsidian_vault() {
  local dir="$ROOT/.obsidian" gi="$ROOT/.gitignore" want have tmp seeded=0
  step "Ensure Obsidian vault shares settings (ignore personal workspace layout)"

  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould seed .obsidian/{app,appearance,core-plugins}.json if missing + keep .gitignore block for workspace*.json%s\n' \
      "$c_dim" "$c_off"
    return 0
  fi

  mkdir -p "$dir"

  if [[ ! -f "$dir/app.json" ]]; then
    printf '{}\n' > "$dir/app.json" && seeded=1 && ok "seeded .obsidian/app.json"
  fi
  if [[ ! -f "$dir/appearance.json" ]]; then
    printf '{}\n' > "$dir/appearance.json" && seeded=1 && ok "seeded .obsidian/appearance.json"
  fi
  if [[ ! -f "$dir/core-plugins.json" ]]; then
    # Prefer python3 over a bash heredoc so the seed stays one parseable function.
    if command -v python3 >/dev/null 2>&1; then
      OBSIDIAN_CORE_PLUGINS_OUT="$dir/core-plugins.json" python3 - <<'PY'
import json, os
cfg = {
  "file-explorer": True, "global-search": True, "switcher": True, "graph": True,
  "backlink": True, "canvas": True, "outgoing-link": True, "tag-pane": True,
  "footnotes": False, "properties": True, "page-preview": True, "daily-notes": True,
  "templates": True, "note-composer": True, "command-palette": True,
  "slash-command": False, "editor-status": True, "bookmarks": True,
  "markdown-importer": False, "zk-prefixer": False, "random-note": False,
  "outline": True, "word-count": True, "slides": False, "audio-recorder": False,
  "workspaces": False, "file-recovery": True, "publish": False, "sync": True,
  "bases": True, "webviewer": False,
}
open(os.environ["OBSIDIAN_CORE_PLUGINS_OUT"], "w", encoding="utf-8").write(
    json.dumps(cfg, indent=2) + "\n"
)
PY
      seeded=1
      ok "seeded .obsidian/core-plugins.json"
    else
      printf '{}\n' > "$dir/core-plugins.json" && seeded=1
      warn "seeded empty .obsidian/core-plugins.json (python3 missing — open Obsidian once to restore defaults)"
    fi
  fi
  [[ "$seeded" -eq 1 ]] || ok ".obsidian shareable config present"

  # Managed gitignore block — rewrite in place when missing or stale.
  touch "$gi"
  want="$(
    printf '%s\n' "$GI_OBSIDIAN_BEGIN"
    printf '# Obsidian vault — commit shared settings; keep personal UI layout local.\n'
    printf '# See docs/agents/obsidian.md.\n'
    printf '.obsidian/workspace.json\n'
    printf '.obsidian/workspace-mobile.json\n'
    printf '.obsidian/graph.json\n'
    printf '%s\n' "$GI_OBSIDIAN_END"
  )"
  have="$(awk -v b="$GI_OBSIDIAN_BEGIN" -v e="$GI_OBSIDIAN_END" \
    'index($0,b){f=1} f{print} index($0,e){f=0}' "$gi" 2>/dev/null)"
  if [[ "$have" == "$want" ]]; then
    ok ".gitignore obsidian block current"
    return 0
  fi
  tmp="$(mktemp)" || { warn "could not update .gitignore obsidian block (mktemp failed)"; return 0; }
  awk -v b="$GI_OBSIDIAN_BEGIN" -v e="$GI_OBSIDIAN_END" \
    'index($0,b){f=1} !f{print} index($0,e){f=0}' "$gi" > "$tmp" 2>/dev/null
  while [[ -s "$tmp" ]] && [[ -z "$(tail -n1 "$tmp")" ]]; do
    sed '$d' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  done
  { printf '\n'; printf '%s\n' "$want"; } >> "$tmp"
  mv "$tmp" "$gi" && ok ".gitignore obsidian block written"
}


# ── deployed-environment triage: REPORTED here, never installed here ──────────────
# Sync onboards repos. It does not reach into a deployed environment on anyone's behalf, and it
# does not bootstrap the identity that lets it — see docs/adr/0009. So the two things it used to
# do here are gone: it no longer registers the triage MCPs (`scripts/triage-mcp.sh sync` does,
# and `aiworks doctor --fix` runs that), and it no longer probes GKE for the read-only identity
# (`scripts/k8s/setup.sh` does, and `aiworks doctor --deep` scores it).
#
# What remains is one stanza in the summary. Its two halves are deliberately asymmetric:
#
#   MCPs   CONDITIONAL, because the state is a jq read of a local file — free to check, so the
#          line appears only when something is actually unregistered and a healthy workspace
#          stays silent. `status` is READ-ONLY; the writing form is never called from here.
#   k8s    STATIC, because the state costs gcloud + kubectl round-trips per cluster, which is
#          the whole reason it left sync. A line that never probes cannot slow a sync down.
#
# Both are suppressed by `triage.enabled: false` — someone who turned triage off asked not to
# hear about it, and a summary line that prints forever is one people stop reading.
#
# Reads one `<section>.<key>` out of ONE file; prints nothing when absent, so the caller can tell "absent"
# from "false" and fall through. Same awk shape as the QG_PROVIDER read below, and the same
# parser scripts/triage-mcp.sh uses — triage.enabled is read LOCAL-FIRST (docs/adr/0003),
# because it is a per-person decision and this must agree with the script that acts on it.
cfg_flag() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk -v want_sec="$2" -v want_key="$3" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec) }
    sec==want_sec && $0 ~ "^  "want_key":" { v=$0; sub(/^[^:]*:[ \t]*/,"",v); sub(/[ \t]+#.*$/,"",v);
      gsub(/^[ \t"'\'']+|[ \t"'\'']+$/,"",v); print tolower(v); exit }
  ' "$f" 2>/dev/null
}
TRIAGE_ENABLED_RAW="$(cfg_flag "$ROOT/workspace.config.local.yaml" triage enabled)"
[[ -n "$TRIAGE_ENABLED_RAW" ]] || TRIAGE_ENABLED_RAW="$(cfg_flag "$WC" triage enabled)"
TRIAGE_ENABLED=1
case "$TRIAGE_ENABLED_RAW" in false|no|0|off) TRIAGE_ENABLED=0 ;; esac

# Prints the stanza, or nothing. Never writes, never touches the network, safe under --dry-run.
triage_stanza() {
  [[ "$TRIAGE_ENABLED" -eq 1 ]] || return 0
  local sh="$DIR/triage-mcp.sh" missing="" k8s_line=1
  local mcp_line=""

  if [[ -x "$sh" ]] && command -v jq >/dev/null 2>&1; then
    missing="$("$sh" status 2>/dev/null | grep -c 'not registered' || true)"
    [[ "${missing:-0}" -gt 0 ]] && mcp_line="${missing} of 3 read-only triage MCP(s) not registered — \`scripts/triage-mcp.sh sync\` (sync no longer does this)"
  elif [[ ! -x "$sh" ]]; then
    mcp_line="scripts/triage-mcp.sh is missing — the read-only triage MCPs cannot be registered"
  fi

  [[ -x "$DIR/k8s/setup.sh" ]] || k8s_line=0

  [[ -n "$mcp_line" || "$k8s_line" -eq 1 ]] || return 0
  printf '%sTriage:%s\n' "$c_warn" "$c_off"
  [[ -n "$mcp_line" ]] && printf '  • %s\n' "$mcp_line"
  [[ "$k8s_line" -eq 1 ]] && printf '  • %s\n' \
    "Kubernetes triage identity is bootstrapped BY HAND, per cluster: \`scripts/k8s/setup.sh\` reports the gaps, a GCP project owner runs \`scripts/k8s/bootstrap-sa.sh --context <ctx>\`. \`aiworks doctor --deep\` scores it."
  return 0
}

# Resolve the positional: a known products[].id is a product filter; anything else is a repo name.
if [[ -n "$SELECTOR" ]]; then
  if parse_repos | awk -F$'\037' -v p="$SELECTOR" '$1==p{f=1} END{exit f?0:1}'; then
    PRODUCT="$SELECTOR"
  else
    REPO_FILTER="$REPO_FILTER $SELECTOR"
  fi
fi
REPO_FILTER="${REPO_FILTER# }"   # trim the leading space the appends leave behind
# Membership test for the repo filter (repo names/paths never contain spaces).
in_repo_filter() { case " $REPO_FILTER " in *" $1 "*) return 0 ;; esac; return 1; }

sel="${PRODUCT:+ (product: $PRODUCT)}${REPO_FILTER:+ (repo: $REPO_FILTER)}"
[[ "$VERBOSE" -eq 1 ]] && printf '%sSyncing repos declared in workspace.config.yaml%s%s\n' "$c_step" "$sel" "$c_off"
[[ "$DRY" -eq 1 ]] && printf '  %s(dry run — nothing will be executed)%s\n' "$c_dim" "$c_off"

# Ensure codegraph is installed once for the whole sweep (so the per-repo index steps don't
# each skip on a missing CLI). The child `aiworks add` runs inherit our PATH, so this covers them.
ensure_codegraph

# The meta repo's own half: graphify for prose, since codegraph indexes no shell and no
# markdown — 63% of this repo is invisible to it (docs/adr/0013). Install, then report on
# the committed doc graph without re-spending its semantic pass.
ensure_graphify
sync_doc_graph

# Seed the adapter .env files (idempotent; never overwrites an existing .env) before the
# per-repo work, so the adapters the onboarded repos link to are already configured.
prepare_adapter_env

# Prepare the image-generation config (enable mcp-image + seed a GEMINI_API_KEY placeholder
# in the git-ignored settings.local.json) so the graphic-designer's asset pipeline can work
# once the user supplies a key — and fails loud (via the /prd-design preflight) when it can't.
seed_image_gen_settings

# Obsidian vault share-contract: seed shared .obsidian settings + ignore personal UI layout.
# Idempotent; never clobbers existing vault prefs. See docs/agents/obsidian.md.
ensure_obsidian_vault

# NOTE: deployed-environment triage is deliberately NOT set up here — see triage_stanza() above
# and docs/adr/0009. It is reported in the summary and scored by `aiworks doctor`.

# ── SonarQube onboarding scaffold (quality_gate.provider: sonarqube) ─────────────
# Read the provider once, then seed a minimal sonar-project.properties into each CODE repo so the
# dev-cycle guardian gate resolves a real project instead of silently hitting "no project for this
# repo" (run-retro §2.4). No-op unless the provider is sonarqube; skips the test-suite repo (no
# guardian gate); never clobbers an existing file or a sonar.projectKey already defined in
# pom.xml / build.gradle(.kts) / package.json / .sonarlint/connectedMode.json.
QG_PROVIDER="$(awk '
  /^[A-Za-z_][A-Za-z0-9_]*:/ { sec=$0; sub(/:.*/,"",sec) }
  sec=="quality_gate" && /^  provider:/ { v=$0; sub(/^[^:]*:[ \t]*/,"",v); sub(/[ \t]+#.*$/,"",v);
    gsub(/^[ \t"'\'']+|[ \t"'\'']+$/,"",v); print v; exit }
' "$WC" 2>/dev/null)"
QG_PROVIDER="${QG_PROVIDER:-none}"

seed_sonar_scaffold() {
  local prod="$1" key="$2" repokind="$3" reldir="$4" url="$5"
  [[ "$QG_PROVIDER" == "sonarqube" ]] || return 0
  case "$repokind" in test-suite) return 0 ;; esac     # the QA repo has no guardian gate
  local dir="$ROOT/${reldir:-$key}"
  [[ -d "$dir" ]] || return 0
  [[ -f "$dir/sonar-project.properties" ]] && return 0
  # Don't double-define a key already configured elsewhere in the repo.
  if grep -qs 'sonar\.projectKey' \
       "$dir/pom.xml" "$dir/build.gradle" "$dir/build.gradle.kts" \
       "$dir/package.json" "$dir/.sonarlint/connectedMode.json" 2>/dev/null; then
    return 0
  fi
  # SonarCloud keys a project as `<gitlab-top-level-group>_<repo>` and scopes it to a
  # SonarCloud organization slug — BOTH come from the repo's GitLab path, NOT from the
  # workspace product id (`prod`, which was the old — wrong — prefix). Parse the path from
  # either URL form (git@host:<group>/<subgroup…>/<repo>.git or
  # https://host/<group>/<subgroup…>/<repo>.git): the top-level group is the key prefix, and
  # the first subgroup (when the path nests group/subgroup/repo) is the org slug. Override
  # with SONAR_KEY_PREFIX / SONAR_ORG in the environment when a setup names them differently.
  local gpath="${url%.git}"      # drop .git
  gpath="${gpath#*://}"          # drop scheme://          (https form; no-op for ssh)
  gpath="${gpath#*@}"            # drop user@              (ssh form; no-op for https)
  gpath="${gpath#*[:/]}"         # drop host + its : or /  → group[/subgroup…]/repo
  local oldifs="$IFS"; IFS='/'; set -f; local segs=($gpath); set +f; IFS="$oldifs"
  local prefix="${SONAR_KEY_PREFIX:-${segs[0]:-}}"   # :- guards keep this nounset-safe (set -u)
  local org="${SONAR_ORG:-}"
  if [[ -z "$org" ]]; then
    if [[ "${#segs[@]}" -ge 3 ]]; then org="${segs[1]:-}"; else org="${segs[0]:-}"; fi
  fi
  local pkey="${prefix:+${prefix}_}${key}"
  {
    printf '# Seeded by `aiworks sync` (quality_gate.provider: sonarqube) so the dev-cycle guardian gate\n'
    printf '# resolves a project. Set sonar.host.url + auth in CI/locally; tune sources/exclusions per repo.\n'
    [[ -n "$org" ]] && printf 'sonar.organization=%s\n' "$org"
    printf 'sonar.projectKey=%s\n' "$pkey"
    printf 'sonar.projectName=%s\n' "$key"
    printf 'sonar.sources=.\n'
  } > "$dir/sonar-project.properties" && ok "seeded sonar-project.properties (org=${org:-–}, projectKey=$pkey)"
}

# ── test-suite contract: `dev.sh artifacts` must actually answer ──────────────────
# The QA skills attach a run's own evidence (screenshots, the rendered run report) to a
# ticket, and they get every path from the repo's own `scripts/dev.sh artifacts` so they
# never have to know whether the repo runs Cypress, Playwright, k6 or Appium. But dev.sh
# is SCAFFOLDED BY A MODEL (aiworks-add step 10, best-effort) — a repo can end up without
# the subcommand, and the failure is silent and plausible: the report just says "no
# screenshots captured", which is exactly what a genuinely capture-less run says too.
# So verify it here rather than trusting the generator. Advisory: this reports, never
# blocks — a sync is not the place to fail a repo over a reporting nicety.
check_artifacts_contract() {
  local key="$1" repokind="$2" reldir="$3"
  [[ "$repokind" == "test-suite" ]] || return 0
  local dir="$ROOT/${reldir:-$key}"
  [[ -x "$dir/scripts/dev.sh" ]] || return 0        # no harness at all — step 10 already said so
  # stdout and stderr are kept APART on purpose. The rows are the stdout contract; the
  # diagnostics ("no test run yet", "cannot parse run timestamp") go to stderr, and folding
  # the two together made every diagnostic look like a malformed row.
  local out err rc=0 errf
  errf="$(mktemp)" || return 0
  out="$( cd "$dir" && ./scripts/dev.sh artifacts 2>"$errf" )" || rc=$?
  err="$(<"$errf")"; rm -f "$errf"
  # rc 2 is "unknown command" — the subcommand is genuinely missing.
  if [[ "$rc" -eq 2 ]] || printf '%s' "$err$out" | grep -qiE 'unknown (sub)?command'; then
    warn "$key: scripts/dev.sh has no 'artifacts' subcommand — QA reports on this repo will attach no evidence (see .claude/skills/report-test-results/SKILL.md §3)"
    return 0
  fi
  # Any OTHER non-zero exit is the healthy "nothing captured yet" answer, and it is what a
  # FRESH CLONE always gives: no run log exists, so both the k6 and the Cypress harness say
  # so on stderr and return 1. There are no rows to validate — a pass, not a finding.
  [[ "$rc" -eq 0 ]] || return 0
  # It answered with rows. Every row must be the 3-column contract.
  if [[ -n "$out" ]] && ! printf '%s' "$out" | awk -F'\t' 'NF!=3{bad=1} END{exit bad?1:0}'; then
    warn "$key: 'dev.sh artifacts' rows are not '<id><TAB><kind><TAB><path>' — QA reports cannot join them to scenarios"
  fi
}

# ── CLAUDE.md budget: the always-loaded instruction has to stay small ─────────────
# Every CLAUDE.md is loaded IN FULL at the start of every session, so its length is a
# per-turn tax and, past a point, a drag on adherence (Anthropic's own guidance: target
# under 200 lines). `aiworks add` step 7 already caps a NEW repo at 60 — but that guard
# fires once, at onboarding, and says nothing as the file grows afterwards. This is the
# drift check: it re-measures on every sync, for the root and for every repo.
#
# The cure when it fires is `.claude/rules/<topic>.md` carrying a `paths:` list, which
# loads only when Claude reads a matching file. ⚠️ A rule with NO `paths:` loads at launch
# with the same priority as CLAUDE.md, so moving prose into one to satisfy this check buys
# nothing — scope the rule, or delete what a doc or a hook already owns. Reports, never
# blocks: a sync is not the place to fail a repo over the size of its instruction.
CLAUDEMD_MAX_ROOT=100   # a meta-repo indexing every repo, the adapter families and docs/
CLAUDEMD_MAX_REPO=100   # the same cap aiworks-add.sh step 7 hands to /init
check_claudemd_size() {
  local label="$1" dir="$2" max="$3" n
  [[ -f "$dir/CLAUDE.md" ]] || return 0
  n="$(grep -c '' "$dir/CLAUDE.md" 2>/dev/null || echo 0)"
  [[ "$n" -gt "$max" ]] || return 0
  warn "$label: CLAUDE.md is $n lines (>$max) — move path-specific detail into .claude/rules/<topic>.md with a paths: list, and drop what a doc or hook already owns"
  noted+=("$label: CLAUDE.md $n lines (>$max)")
}

# ── reconcile mani.d/ + mani.yaml imports with products[] ─────────────────────────
# `aiworks add` only APPENDS mani.d/<product>.yaml and its import line. A product rename
# (or a repo moving between products) leaves the old file + import in place. Mani then
# merges DUPLICATE project keys across imports by silently dropping them — `mani list
# projects` shows only the non-colliding repos (typical after a product rename left
# both the old and new mani.d/<product>.yaml importing the same keys). Prune BEFORE the parallel
# pre-clone so `mani sync --parallel` sees the live set.
#
# Rules:
#   1. mani.d/<id>.yaml whose <id> is not a products[].id → delete (+ drop import).
#   2. A project key listed under the wrong product file (config says it belongs elsewhere)
#      → strip that block; delete the file if it goes empty.
#   3. mani.yaml `import:` list → rewritten to exactly the live mani.d files, in products[]
#      order (no stale lines, no orphans).
reconcile_mani_registry() {
  step "Reconcile mani.d/ + mani.yaml imports with products[]"

  local -a products=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && products+=("$id")
  done < <(awk '
    /^products:[ \t]*$/ { inp=1; next }
    inp && /^  - id:/ {
      sub(/^[^:]*:[ \t]*/, "")
      gsub(/^["'\'' \t]+|["'\'' \t]+$/, "")
      if ($0 != "") print
      next
    }
    inp && /^[A-Za-z_]/ { inp=0 }
  ' "$WC")

  is_live_product() {
    local p="$1" x
    for x in "${products[@]+"${products[@]}"}"; do [[ "$x" == "$p" ]] && return 0; done
    return 1
  }

  # repo_name → owning products[].id (from config). Used to strip misplaced keys.
  #
  # A FLAT "<key>\037<product>" table, deliberately not an associative array: macOS still
  # ships bash 3.2 as /bin/bash, and `#!/usr/bin/env bash` takes whatever is first on PATH.
  # There `local -A` is `invalid option`, so the name stays a plain string — and then
  # `repo_owner[$key]=` evaluates the subscript as ARITHMETIC, which turns a hyphenated repo
  # name into a subtraction of variable names and kills the run under `set -u`
  # (`turnover-commission-batch` → `turnover: unbound variable`). Keep this 3.2-clean.
  local repo_owner=''
  local prod url kind lang dist path desc key
  while IFS=$'\037' read -r prod url kind lang dist path desc; do
    [[ -n "$url" ]] || continue
    key="${url%.git}"; key="${key##*/}"; key="${key##*:}"
    # Mani project keys are always the URL-derived repo name (path: is only the clone dir).
    [[ -n "$key" && -n "$prod" ]] && repo_owner="${repo_owner}${key}"$'\037'"${prod}"$'\n'
  done < <(parse_repos)

  owner_of() {  # $1=repo-key → its products[].id on stdout; empty when the config knows no such key
    local k v
    while IFS=$'\037' read -r k v; do
      [[ "$k" == "$1" ]] && { printf '%s' "$v"; return 0; }
    done <<< "$repo_owner"
    return 1
  }

  strip_mani_project() {  # $1=file $2=repo-key — drop `  <key>:` + indented fields
    local file="$1" repo="$2"
    awk -v key="$repo" '
      skip==1 && /^    / { next }
      skip==1 { skip=0 }
      $0 ~ ("^  " key ":[ \t]*$") { skip=1; next }
      { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  }

  mani_file_empty() {  # no project keys left
    ! grep -qE '^  [A-Za-z0-9._-]+:[[:space:]]*$' "$1" 2>/dev/null
  }

  mkdir -p "$ROOT/mani.d"
  local f base repo owner changed=0
  shopt -s nullglob
  for f in "$ROOT"/mani.d/*.yaml; do
    base="$(basename "$f" .yaml)"
    if ! is_live_product "$base"; then
      if [[ "$DRY" -eq 1 ]]; then
        printf '    %swould remove stale mani.d/%s.yaml (no products[].id match)%s\n' \
          "$c_dim" "$base" "$c_off"
      else
        rm -f "$f" && ok "removed stale mani.d/$base.yaml (not in products[])"
      fi
      changed=1
      continue
    fi
    # Strip project keys that config assigns to a DIFFERENT product (rename / move leftovers).
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      owner="$(owner_of "$repo" || true)"
      [[ -n "$owner" && "$owner" != "$base" ]] || continue
      if [[ "$DRY" -eq 1 ]]; then
        printf '    %swould strip project %s from mani.d/%s.yaml (owned by products[].id=%s)%s\n' \
          "$c_dim" "$repo" "$base" "$owner" "$c_off"
      else
        strip_mani_project "$f" "$repo" \
          && ok "stripped project '$repo' from mani.d/$base.yaml (belongs to $owner)"
      fi
      changed=1
    done < <(awk '/^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
                     sub(/:[[:space:]]*$/, ""); sub(/^  /, ""); print
                   }' "$f")
    if [[ -f "$f" ]] && mani_file_empty "$f"; then
      if [[ "$DRY" -eq 1 ]]; then
        printf '    %swould remove empty mani.d/%s.yaml%s\n' "$c_dim" "$base" "$c_off"
      else
        rm -f "$f" && ok "removed empty mani.d/$base.yaml"
      fi
      changed=1
    fi
  done

  # Desired import list = live mani.d files for products[], in config order.
  local -a desired=()
  for id in "${products[@]+"${products[@]}"}"; do
    [[ -f "$ROOT/mani.d/$id.yaml" ]] && desired+=("mani.d/$id.yaml")
  done

  local current="" want=""
  current="$(awk '
    /^import:[ \t]*$/ { inn=1; next }
    inn && /^  - / { sub(/^  - [ \t]*/, ""); print; next }
    inn && /^[A-Za-z_#]/ { exit }
  ' "$ROOT/mani.yaml" | paste -sd'|' -)"
  want="$(printf '%s\n' "${desired[@]+"${desired[@]}"}" | paste -sd'|' -)"

  if [[ "$current" != "$want" ]]; then
    if [[ "$DRY" -eq 1 ]]; then
      printf '    %swould rewrite mani.yaml import: → [%s]%s\n' \
        "$c_dim" "$(printf '%s' "$want" | tr '|' ' ')" "$c_off"
    else
      local tmp wantf
      tmp="$(mktemp)" || die "mktemp failed rewriting mani.yaml imports"
      wantf="$(mktemp)" || { rm -f "$tmp"; die "mktemp failed for import want-list"; }
      printf '%s\n' "${desired[@]+"${desired[@]}"}" > "$wantf"
      awk -v wantf="$wantf" '
        BEGIN {
          while ((getline line < wantf) > 0) { n++; d[n]=line }
          close(wantf)
        }
        /^import:[ \t]*$/ {
          print
          for (i=1; i<=n; i++) print "  - " d[i]
          if (n) print ""
          skip=1
          next
        }
        skip && /^  - / { next }
        skip && /^[ \t]*$/ { next }
        skip && (/^[A-Za-z_]/ || /^#/) { skip=0 }
        { print }
      ' "$ROOT/mani.yaml" > "$tmp" && mv "$tmp" "$ROOT/mani.yaml" \
        && ok "rewrote mani.yaml import: ($(printf '%s' "$want" | tr '|' ' '))" \
        || { rm -f "$tmp"; warn "could not rewrite mani.yaml imports — edit by hand"; }
      rm -f "$wantf"
      changed=1
    fi
  fi

  # Duplicate project keys across remaining files still break mani silently — surface them.
  local dups
  dups="$(awk '
    /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      k=$0; sub(/:[[:space:]]*$/, "", k); sub(/^  /, "", k)
      file=FILENAME; sub(/.*\//, "", file)
      if (seen[k] != "" && seen[k] != file) print k " in " seen[k] " and " file
      else seen[k]=file
    }
  ' "$ROOT"/mani.d/*.yaml 2>/dev/null || true)"
  if [[ -n "$dups" ]]; then
    warn "duplicate mani project key(s) still present — mani will drop them on import:"
    while IFS= read -r line; do [[ -n "$line" ]] && printf '      %s\n' "$line"; done <<< "$dups"
    noted+=("mani.d: duplicate project keys (mani silently drops collisions)")
  fi

  [[ "$changed" -eq 0 && -z "$dups" ]] && ok "mani.d/ + imports already match products[]"
  shopt -u nullglob
}

noted=()  # may also collect duplicate-key warnings from reconcile_mani_registry
reconcile_mani_registry

# ── parallel pre-clone: clone the WHOLE set up front, concurrently ────────────────
# The per-repo loop below delegates to `aiworks add`, whose step 3 clones via a BARE
# `mani sync` — so a fresh workspace clones all N repos ONE AT A TIME. Measured on the OFB
# set (18 repos): 125s sequential vs 42s with `mani sync --parallel` (~3x, saves ~83s). On a
# fresh Superset worktree the clone is the single biggest, CACHE-IMMUNE cost — node installs
# hit the machine-global pnpm/npm store (warm) and codegraph indexes fast, but every new
# worktree must re-clone from scratch. So clone the whole set here, in parallel, BEFORE the
# onboard loop; each per-repo `aiworks add` then finds its repo already cloned (step 3 SKIP)
# and only onboards. `mani sync` is idempotent (only MISSING repos are cloned), so this is a
# fast no-op on re-runs. SSH-key auth via ssh-agent means --parallel needs no per-repo prompt
# (mani cautions against --parallel only for repos needing INTERACTIVE credentials).
# Covers the full sweep AND a product-scoped sync: product == tags[0] on every mani.d entry
# (guaranteed by `aiworks add`), so `mani sync -t <product>` clones exactly that product's
# repos. A --repo/repo-name filter is small and left to the per-repo clone (cloning one repo
# gains nothing). Tunable: raise concurrency with `-f <N>` (mani's default forks: 4).
if [[ -z "$REPO_FILTER" ]]; then
  mani_scope=(); [[ -n "$PRODUCT" ]] && mani_scope=(-t "$PRODUCT")
  step "Pre-clone every repo in parallel (mani sync --parallel${PRODUCT:+ -t $PRODUCT})"
  if [[ "$DRY" -eq 1 ]]; then
    printf '    %swould run: mani sync --parallel%s  (clone every MISSING repo concurrently, ~3x vs sequential)%s\n' "$c_dim" "${PRODUCT:+ -t $PRODUCT}" "$c_off"
  elif ! command -v mani >/dev/null 2>&1; then
    warn "mani not installed — skipping the parallel pre-clone; each repo clones during its own onboard"
  else
    preclone_rc=0
    if [[ "$VERBOSE" -eq 1 ]]; then mani sync --parallel ${mani_scope[@]+"${mani_scope[@]}"} || preclone_rc=$?
    else mani sync --parallel ${mani_scope[@]+"${mani_scope[@]}"} >/dev/null 2>&1 || preclone_rc=$?; fi
    if [[ "$preclone_rc" -eq 0 ]]; then ok "parallel pre-clone done (already-present repos skipped)"
    else warn "parallel pre-clone exited $preclone_rc — each repo's onboard will retry its own clone"; fi
  fi
fi

# ── iterate every declared repo and delegate to aiworks-add.sh ───────────────────
total=0; synced=0; failed=0; MATCHED=""  # noted[] seeded before reconcile_mani_registry
while IFS=$'\037' read -r prod url kind lang dist path desc; do   # \037 (US) — empty fields aren't collapsed
  [[ -n "$url" ]] || continue
  [[ -z "$PRODUCT" || "$prod" == "$PRODUCT" ]] || continue
  key="${url%.git}"; key="${key##*/}"; key="${key##*:}"
  [[ -n "$key" ]] || { warn "could not derive a repo name from url '$url' — skipping"; noted+=("$url: bad url"); continue; }
  if [[ -n "$REPO_FILTER" ]]; then          # restrict to the named repo(s) when a repo filter is set
    if   in_repo_filter "$key";                   then MATCHED="$MATCHED $key"
    elif [[ -n "$path" ]] && in_repo_filter "$path"; then MATCHED="$MATCHED $path"
    else continue; fi
  fi
  repokind="$KIND"; [[ -n "$repokind" ]] || repokind="${kind:-generic}"
  total=$((total+1))

  cmd=("$ADD" --url "$url" --product "$prod" --kind "$repokind")
  [[ "$YES" -eq 1 ]]        && cmd+=(-y)   # opt-in: only assume-yes when the caller passed -y to sync
  [[ -n "$path" ]]          && cmd+=(--path "$path")
  [[ -n "$desc" ]]          && cmd+=(--desc "$desc")
  [[ -n "$lang" ]]          && cmd+=(--lang "$lang")
  if   [[ -n "$DISTRIBUTE" ]]; then cmd+=(--distribute "$DISTRIBUTE")
  elif [[ -n "$dist" ]];      then cmd+=(--distribute "$dist"); fi
  [[ -n "$SKILL_CMD" ]]      && cmd+=(--skill-cmd "$SKILL_CMD")
  [[ -n "$CLAUDE_TIMEOUT" ]] && cmd+=(--claude-timeout "$CLAUDE_TIMEOUT")
  [[ "$SAFE" -eq 1 ]]        && cmd+=(--safe-perms)
  [[ "$FORCE" -eq 1 ]]       && cmd+=(--force)
  [[ "$VERBOSE" -eq 1 ]]     && cmd+=(--verbose)   # quiet by default; propagate -v so add is verbose too

  if [[ "$DRY" -eq 1 ]]; then
    printf '  %s%s/%s%s (kind %s) → ' "$c_step" "$prod" "$key" "$c_off" "$repokind"
    printf '%q ' "${cmd[@]}"; printf '\n'
    continue
  fi

  step "Sync $prod/$key  (kind $repokind${path:+, dir $path/})"
  # </dev/null so aiworks-add never consumes this loop's parse stream. Its own prompts read
  # /dev/tty (not stdin), so when -y is OMITTED they still fire here; with no tty they fall back
  # to defaults. Ctrl+C is signal-based, so it still stops the whole sweep.
  if "${cmd[@]}" </dev/null; then synced=$((synced+1)); seed_sonar_scaffold "$prod" "$key" "$repokind" "$path" "$url"; check_artifacts_contract "$key" "$repokind" "$path"; check_claudemd_size "$key" "$ROOT/${path:-$key}" "$CLAUDEMD_MAX_REPO"
  else
    rc=$?
    [[ "$rc" -eq 130 ]] && { printf '\n%s✗ interrupted during %s/%s%s\n' "$c_warn" "$prod" "$key" "$c_off" >&2; exit 130; }
    failed=$((failed+1)); noted+=("$prod/$key: aiworks-add exited $rc")
  fi
done < <(parse_repos)

# Flag any requested repo name that matched no declared repo (typo / wrong product scope).
if [[ -n "$REPO_FILTER" ]]; then
  for want in $REPO_FILTER; do
    case " $MATCHED " in
      *" $want "*) ;;
      *) warn "no repo named '$want' to sync${PRODUCT:+ under product '$PRODUCT'}"
         noted+=("repo '$want': not found in workspace.config.yaml${PRODUCT:+ under product '$PRODUCT'}") ;;
    esac
  done
fi

# ── regenerate the workflow CONFIG once from the now up-to-date workspace.config.yaml ──
# (the workflow can't read the FS at runtime, so it keeps an in-source mirror).
if [[ "$DRY" -ne 1 ]]; then
  GEN="$DIR/aiworks-config.sh"
  if [[ -x "$GEN" ]]; then
    step "Regenerate the dev-cycle.js CONFIG from workspace.config.yaml"
    # quiet by default — swallow the sub-tool's own chatter (keep stderr) unless -v.
    if [[ "$VERBOSE" -eq 1 ]]; then "$GEN" || warn "could not regenerate dev-cycle.js CONFIG — run 'aiworks config' by hand"
    else "$GEN" >/dev/null || warn "could not regenerate dev-cycle.js CONFIG — run 'aiworks config' by hand"; fi
  fi
fi

# ── ensure the workspace lifecycle hooks (.superset/{setup,run,teardown}) cover the repo set ──
# The hooks loop over every cloned repo, so the synced set is covered automatically — this just
# makes sure the trio EXISTS and config.json registers all three (creating .superset/run.sh on
# workspaces that predate the run hook). Idempotent; honoured in dry-run too.
SUPGEN="$DIR/aiworks-superset.sh"
if [[ -x "$SUPGEN" ]]; then   # prints its own "==> Ensure .superset lifecycle hooks…" header
  if   [[ "$DRY" -eq 1 ]];     then "$SUPGEN" -n || warn "could not preview .superset hooks"
  elif [[ "$VERBOSE" -eq 1 ]]; then "$SUPGEN"    || warn "could not ensure .superset hooks — run 'aiworks-superset.sh' by hand"
  else "$SUPGEN" >/dev/null || warn "could not ensure .superset hooks — run 'aiworks-superset.sh' by hand"; fi   # quiet by default
fi

# ── project the whole workspace onto Cursor ───────────────────────────────────────
# One pass over the root + every repo, after the per-repo work above has settled the
# Claude-side config. Symlinks only (plus the generated hooks/permissions pair), so a
# repo that was already in sync costs nothing. Never runs in dry-run.
CURGEN="$DIR/aiworks-cursor.sh"
if [[ -x "$CURGEN" && "$DRY" -ne 1 ]]; then
  step "Project the agent config onto Cursor (AGENTS.md + .cursor/) for the root and every repo"
  if [[ "$VERBOSE" -eq 1 ]]; then "$CURGEN" || warn "could not project the Cursor layer — run 'aiworks cursor' by hand"
  else "$CURGEN" >/dev/null || warn "could not project the Cursor layer — run 'aiworks cursor' by hand"; fi
fi

# ── the root's own instruction is subject to the same budget ─────────────────────
[[ "$DRY" -eq 1 ]] || check_claudemd_size "(workspace root)" "$ROOT" "$CLAUDEMD_MAX_ROOT"

# ── summary ──────────────────────────────────────────────────────────────────────
printf '\n%s──────── sync summary ────────%s\n' "$c_step" "$c_off"
if [[ "$total" -eq 0 ]]; then
  printf '%sNo repos to sync%s%s%s — declare them under products[].repos[] in workspace.config.yaml (each needs a url + kind).\n' "$c_warn" "${PRODUCT:+ for product '$PRODUCT'}" "${REPO_FILTER:+ matching repo(s) '$REPO_FILTER'}" "$c_off"
elif [[ "$DRY" -eq 1 ]]; then
  printf '%s%d repo(s)%s would be synced (dry run). Re-run without --dry-run to execute.\n' "$c_step" "$total" "$c_off"
else
  printf '%sRepos: %d   synced/ok: %d   failed: %d%s\n' "$c_step" "$total" "$synced" "$failed" "$c_off"
  if [[ "${#noted[@]}" -gt 0 ]]; then
    printf '%sNotes:%s\n' "$c_warn" "$c_off"; for n in "${noted[@]}"; do printf '  • %s\n' "$n"; done
  fi
  printf '%sNext:%s `mani list projects` to see the set, then `cursor %s.code-workspace` to open every repo as its own Source Control panel. (The .claude/workflows/dev-cycle.js CONFIG and %s.code-workspace were regenerated from workspace.config.yaml automatically — no manual mirror needed.)\n' "$c_step" "$c_off" "$(basename "$ROOT")" "$(basename "$ROOT")"
fi
# Printed in EVERY branch, including a 0-repo run and a dry run: triage readiness has nothing to
# do with how many repos matched the filter, so scoping it to the normal branch would hide it
# from exactly the narrow re-sync (`aiworks sync --repo one-thing`) people run most often.
triage_stanza
[[ "$failed" -eq 0 ]]
