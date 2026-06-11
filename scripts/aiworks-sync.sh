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
# It also PREPARES the adapter .env files (scripts/{tracker,vcs}/.env) when they are missing:
# each is seeded from its committed .env.example and pre-filled with the values derivable from
# workspace.config.yaml (vcs.provider → VCS_PROVIDER; tracker.provider → TRACKER_PROVIDER;
# tracker.ticket_prefix → JIRA_PROJECT_KEY for jira; tracker.statuses.done → NOTION_STATUS_DONE
# for notion). An existing .env is left untouched — you still fill in the secrets by hand.
#
# Usage:
#   aiworks sync [<product>|<repo>] [options]
#
#   <product>|<repo>      Narrow the sweep. If it names a product (products[].id) only that
#                         product's repos sync; otherwise it is treated as a repo name and ONLY
#                         that repo syncs (default: every repo of every product).
#   --repo <name>         Only sync the repo(s) with this name — repeatable, or comma-separated
#                         (e.g. --repo agent-db,paotung-template). Matches a repo's clone-dir name
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
#   -h, --help            Show this help.
#
set -uo pipefail

# ── logging ─────────────────────────────────────────────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

# Ctrl+C / kill stops the whole sweep, not just the current repo.
trap 'printf "\n%s✗ sync interrupted%s\n" "$c_warn" "$c_off" >&2; exit 130' INT TERM

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
    -h|--help)         usage; exit 0 ;;
    -*)                die "unknown option: $1   (see -h)" ;;
    *)                 [[ -z "$SELECTOR" ]] || die "unexpected argument: $1 (one <product>|<repo> only)"; SELECTOR="$1"; shift ;;
  esac
done

# ── locate the workspace root ───────────────────────────────────────────────────
ROOT="$(cd "$DIR/.." && pwd)"
cd "$ROOT" || die "cannot cd to workspace root"
[[ -f "$ROOT/mani.yaml" ]] || die "no mani.yaml in $ROOT — run this from a workspace (next to mani.yaml)"
WC="$ROOT/workspace.config.yaml"
[[ -f "$WC" ]] || die "no workspace.config.yaml in $ROOT — copy workspace.config.example.yaml and declare your repos under products:"

# Parse products[].repos[] → one line per repo:  product \037 url \037 kind \037 lang \037 distribute \037 path
# Indentation contract (see workspace.config.example.yaml): products: at col 0; `  - id:`
# (2sp) per product; `    repos:` (4sp); `      - url:` (6sp) per repo; `        <field>:` (8sp).
parse_repos() {
  awk '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    function setkv(line){ k=line; sub(/^[ \t]*/,"",k)
      if(k ~ /^url:/) url=val(k); else if(k ~ /^kind:/) kind=val(k)
      else if(k ~ /^lang:/) lang=val(k); else if(k ~ /^distribute:/) dist=val(k)
      else if(k ~ /^path:/) path=val(k) }
    function flush(){ if(url!=""){ printf "%s\037%s\037%s\037%s\037%s\037%s\n", prod,url,kind,lang,dist,path }
      url="";kind="";lang="";dist="";path="" }
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
# scripts/{tracker,vcs}/.env are git-ignored LOCAL config the adapters source at runtime
# (scripts/{tracker,vcs}/lib.sh). They normally have to be hand-copied from .env.example
# and filled in. We can do better: seed each MISSING one from its committed .env.example
# and pre-fill the values DERIVABLE from workspace.config.yaml — the providers, the Jira
# project key, the Notion done-status. An EXISTING .env is never touched (we don't clobber
# a human's secrets); the rest of each .env keeps its .env.example comments to fill in by hand.

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
  local vcs_provider='' tracker_provider='' ticket_prefix='' status_done=''
  while IFS=$'\t' read -r k v; do
    case "$k" in
      VCS_PROVIDER)     vcs_provider="$v" ;;
      TRACKER_PROVIDER) tracker_provider="$v" ;;
      TICKET_PREFIX)    ticket_prefix="$v" ;;
      STATUS_DONE)      status_done="$v" ;;
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
  esac
  seed_env_file "$DIR/tracker" "${tkv[@]}"
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
printf '%sSyncing repos declared in workspace.config.yaml%s%s\n' "$c_step" "$sel" "$c_off"
[[ "$DRY" -eq 1 ]] && printf '  %s(dry run — nothing will be executed)%s\n' "$c_dim" "$c_off"

# Seed the adapter .env files (idempotent; never overwrites an existing .env) before the
# per-repo work, so the adapters the onboarded repos link to are already configured.
prepare_adapter_env

# ── iterate every declared repo and delegate to aiworks-add.sh ───────────────────
total=0; synced=0; failed=0; noted=(); MATCHED=""
while IFS=$'\037' read -r prod url kind lang dist path; do   # \037 (US) — empty fields aren't collapsed
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
  [[ -n "$lang" ]]          && cmd+=(--lang "$lang")
  if   [[ -n "$DISTRIBUTE" ]]; then cmd+=(--distribute "$DISTRIBUTE")
  elif [[ -n "$dist" ]];      then cmd+=(--distribute "$dist"); fi
  [[ -n "$SKILL_CMD" ]]      && cmd+=(--skill-cmd "$SKILL_CMD")
  [[ -n "$CLAUDE_TIMEOUT" ]] && cmd+=(--claude-timeout "$CLAUDE_TIMEOUT")
  [[ "$SAFE" -eq 1 ]]        && cmd+=(--safe-perms)
  [[ "$FORCE" -eq 1 ]]       && cmd+=(--force)

  if [[ "$DRY" -eq 1 ]]; then
    printf '  %s%s/%s%s (kind %s) → ' "$c_step" "$prod" "$key" "$c_off" "$repokind"
    printf '%q ' "${cmd[@]}"; printf '\n'
    continue
  fi

  step "Sync $prod/$key  (kind $repokind${path:+, dir $path/})"
  # </dev/null so aiworks-add never consumes this loop's parse stream. Its own prompts read
  # /dev/tty (not stdin), so when -y is OMITTED they still fire here; with no tty they fall back
  # to defaults. Ctrl+C is signal-based, so it still stops the whole sweep.
  if "${cmd[@]}" </dev/null; then synced=$((synced+1))
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
    "$GEN" || warn "could not regenerate dev-cycle.js CONFIG — run 'aiworks config' by hand"
  fi
fi

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
  printf '%sNext:%s `mani list projects` to see the set. (The .claude/workflows/dev-cycle.js CONFIG was regenerated from workspace.config.yaml automatically — no manual mirror needed.)\n' "$c_step" "$c_off"
fi
[[ "$failed" -eq 0 ]]
