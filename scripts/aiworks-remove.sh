#!/usr/bin/env bash
#
# aiworks-remove.sh  (run it as: aiworks remove) — offboard a repo (or ALL repos).
#
# The inverse of `aiworks add`. For each repo it deregisters:
#   1. remove its block from mani.d/<product>.yaml  (delete the file + its mani.yaml
#      import too, if that was its last project)
#   2. remove its entry from products[].repos[] in workspace.config.yaml (matched by the
#      repo name in its url; an emptied product block is left for you to delete)
#   3. drop <repo>/ from the workspace .gitignore
#   4. unlink the workspace adapters (scripts/{tracker,vcs}) + un-exclude them
#   5. (--purge only) delete the cloned working tree — REFUSES on a dirty or unpushed
#      tree unless --force
# …then, ONCE, regenerates the dev-cycle.js CONFIG mirror from the updated config.
#
# Best-effort + idempotent: a piece that's already gone is just skipped. Config edits are
# reversible via git; the working tree is touched ONLY with --purge.
#
# Usage:
#   aiworks remove <repo> [--purge] [--force] [-y]
#   aiworks remove --all  [--purge] [--force] [-y]      # offboard EVERY onboarded repo
#   aiworks remove all    [--purge] [--force] [-y]      # …same as --all
#
#   <repo>        Repo id / dir name as onboarded (the mani key, e.g. feeedme-api).
#   --all, all    Offboard every repo declared in workspace.config.yaml products[].repos[]
#                 / mani.d/*.yaml (the union, de-duplicated). Mutually exclusive with <repo>.
#   --purge       Also delete the cloned working tree (<repo>/). Refuses on a dirty or
#                 unpushed tree unless --force.
#   --force       With --purge, delete even if the tree is dirty/unpushed.
#   -y, --yes     Don't prompt; assume yes.
#   -h, --help    Show this help.
#
set -uo pipefail

# ── pretty logging (same surface as aiworks-add.sh) ────────────────────────────
c_step=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_step=; c_ok=; c_warn=; c_err=; c_off=; }
DONE=(); SKIPPED=(); FOLLOWUP=()
step()  { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()    { printf '    %s✓ %s%s\n' "$c_ok" "$*" "$c_off"; DONE+=("$*"); }
warn()  { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
skip()  { printf '    %s⤼ SKIP: %s%s\n' "$c_warn" "$*" "$c_off"; SKIPPED+=("$*"); }
die()   { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
# Remove every exact-match line from a file. Returns 0 if it removed anything, 1 if the
# line wasn't present. NOTE: `grep -v` exits 1 when its output is empty (i.e. the line was
# the file's ONLY line) — that is success here, so DON'T gate the mv on grep's exit code.
remove_line() {
  local f="$1" line="$2"
  [[ -f "$f" ]] && grep -qxF "$line" "$f" || return 1
  grep -vxF "$line" "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# ── args ───────────────────────────────────────────────────────────────────────
REPO="" ALL=0 PURGE=0 FORCE=0 YES=0
usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)     ALL=1; shift ;;
    --purge)   PURGE=1; shift ;;
    --force)   FORCE=1; shift ;;
    -y|--yes)  YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    all)       ALL=1; shift ;;                      # bare `all` positional ⇒ --all
    *)         [[ -z "$REPO" ]] || die "unexpected argument: $1 (one <repo> only)"; REPO="$1"; shift ;;
  esac
done
[[ "$ALL" -eq 1 && -n "$REPO" ]] && die "give either a <repo> or --all, not both   (see -h)"
if [[ "$ALL" -ne 1 ]]; then
  [[ -n "$REPO" ]] || die "usage: aiworks remove <repo>|--all [--purge] [--force] [-y]   (see -h)"
  [[ "$REPO" =~ ^[A-Za-z0-9._/-]+$ ]] || die "repo '$REPO' is not a simple id"
fi

# ── locate the workspace root ───────────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || die "cannot cd to workspace root"
[[ -f "$ROOT/mani.yaml" ]] || die "no mani.yaml in $ROOT — run this from a workspace (next to mani.yaml)"
WC="$ROOT/workspace.config.yaml"

# Resolve the clone DIR from a repo's products[].repos[] entry (its 8-space `path:`
# override, matched by the repo name in its url) — falls back to the repo name.
wc_path_for() {
  local name="$1" p=""
  [[ -f "$WC" ]] && p="$(awk -v NAME="$name" '
    $0 ~ ("^      - url:.*[/:]" NAME "(\\.git)?[ \t]*(#.*)?$") {f=1; next}
    f && /^        path:/ {sub(/^        path:[ \t]*/,""); sub(/[ \t]+#.*$/,""); print; exit}
    f && !/^        / {exit}' "$WC")"
  printf '%s' "${p:-$name}"
}

# Print every onboarded repo NAME (one per line, de-duplicated) — the union of the repo
# names in workspace.config.yaml products[].repos[] (derived from each url's last path
# segment) and the project keys in mani.d/*.yaml. Used by --all.
all_repos() {
  {
    if [[ -f "$WC" ]]; then
      awk '
        /^      - url:/ {
          s=$0
          sub(/[ \t]*#.*$/, "", s)            # strip trailing comment
          sub(/^      - url:[ \t]*/, "", s)   # strip the "- url:" prefix
          sub(/\.git[ \t]*$/, "", s)          # strip a trailing .git
          sub(/[ \t]+$/, "", s)               # strip trailing whitespace
          n = split(s, a, /[\/:]/)            # repo name = last path segment
          if (a[n] != "") print a[n]
        }' "$WC"
    fi
    for f in "$ROOT"/mani.d/*.yaml; do
      [[ -f "$f" ]] || continue
      awk '/^  [A-Za-z0-9._-]+:[[:space:]]*$/ { sub(/:[[:space:]]*$/, ""); sub(/^  /, ""); print }' "$f"
    done
  } | sort -u
}

# ── offboard ONE repo: config/gitignore/adapters/clone (steps 1–5; NOT the dev-cycle
#    regen — that runs once at the end so an --all pass regenerates the mirror just once).
offboard_one() {
  local REPO="$1" DIR_REL REPO_DIR prod_file exclude a
  DIR_REL="$(wc_path_for "$REPO")"
  REPO_DIR="$ROOT/$DIR_REL"

  printf '\n%s──── repo: %s ────%s  (dir: %s/%s)\n' "$c_step" "$REPO" "$c_off" "$DIR_REL" \
    "$([[ "$PURGE" -eq 1 ]] && printf ' — WILL DELETE the working tree' || printf ' — kept (config-only)')"

  # 1. mani.d/<product>.yaml ───────────────────────────────────────────────────
  step "1. Deregister from mani.d/"
  prod_file="$(grep -lE "^  ${REPO}:[[:space:]]*$" "$ROOT"/mani.d/*.yaml 2>/dev/null | head -1)"
  if [[ -z "$prod_file" ]]; then
    skip "[$REPO] 1. no mani.d entry (already gone?)"
  else
    # Delete the repo's block: its `  <repo>:` line + the 4-space field lines under it.
    if awk -v key="$REPO" '
          skip==1 && /^    / { next }
          skip==1 { skip=0 }
          $0 ~ ("^  " key ":[ \t]*$") { skip=1; next }
          { print }' "$prod_file" > "$prod_file.tmp" && mv "$prod_file.tmp" "$prod_file"; then
      ok "[$REPO] removed project from $(basename "$prod_file")"
      # If that was the last project, drop the (now-empty) file + its mani.yaml import.
      if ! grep -qE '^  [A-Za-z0-9._-]+:[[:space:]]*$' "$prod_file"; then
        rm -f "$prod_file" && ok "[$REPO] removed empty mani.d/$(basename "$prod_file")"
        remove_line "$ROOT/mani.yaml" "  - mani.d/$(basename "$prod_file")" \
          && ok "[$REPO] removed its import from mani.yaml" || warn "no import line for $(basename "$prod_file") in mani.yaml"
      fi
    else skip "[$REPO] 1. could not edit $(basename "$prod_file") — remove the block by hand"; fi
  fi

  # 2. workspace.config.yaml products[].repos[] ─────────────────────────────────
  step "2. Deregister from workspace.config.yaml (products[].repos[])"
  if [[ ! -f "$WC" ]]; then
    skip "[$REPO] 2. no workspace.config.yaml"
  elif ! grep -qE "^      - url:.*[/:]$REPO(\.git)?[[:space:]]*(#.*)?$" "$WC"; then
    skip "[$REPO] 2. no products[].repos[] entry (already gone?)"
  else
    # Delete the repo item: its `      - url: …<repo>` line + the 8-space field lines under it.
    if awk -v NAME="$REPO" '
          $0 ~ ("^      - url:.*[/:]" NAME "(\\.git)?[ \t]*(#.*)?$") { skip=1; next }
          skip==1 && /^        / { next }
          skip==1 { skip=0 }
          { print }' "$WC" > "$WC.tmp" && mv "$WC.tmp" "$WC"; then
      ok "[$REPO] removed products[].repos[] entry from workspace.config.yaml"
    else skip "[$REPO] 2. could not edit workspace.config.yaml — remove the repo block by hand"; fi
  fi

  # 3. workspace .gitignore ─────────────────────────────────────────────────────
  step "3. Un-ignore $DIR_REL/ in the workspace .gitignore"
  if remove_line "$ROOT/.gitignore" "$DIR_REL/"; then ok "[$REPO] removed $DIR_REL/ from the workspace .gitignore"
  else skip "[$REPO] 3. $DIR_REL/ not in the workspace .gitignore"; fi

  # 4. unlink the workspace adapters + drop them from .git/info/exclude ──────────
  # The inverse of `aiworks add` step 3.3: remove the scripts/{tracker,vcs} symlinks we wired
  # in (ONLY if they are our symlinks — never a real dir the repo owns) and the matching
  # local-only ignore lines. Best-effort, and run BEFORE the purge so a kept tree (config-only
  # remove, or a --purge that refuses on a dirty tree) is left clean.
  step "4. Unlink adapters + un-exclude in $DIR_REL/.git/info/exclude"
  if [[ ! -d "$REPO_DIR" ]]; then
    skip "[$REPO] 4. no working tree at $DIR_REL/ — nothing to unlink"
  else
    exclude="$REPO_DIR/.git/info/exclude"
    for a in tracker vcs; do
      if [[ -L "$REPO_DIR/scripts/$a" ]]; then rm -f "$REPO_DIR/scripts/$a" && ok "[$REPO] unlinked scripts/$a"
      else skip "[$REPO] 4. scripts/$a not a workspace symlink (left as-is)"; fi
      if remove_line "$exclude" "scripts/$a"; then ok "[$REPO] dropped scripts/$a from .git/info/exclude"
      else skip "[$REPO] 4. scripts/$a not in .git/info/exclude"; fi
    done
  fi

  # 5. (--purge) delete the cloned working tree ─────────────────────────────────
  step "5. Working tree ($DIR_REL/)"
  if [[ "$PURGE" -ne 1 ]]; then
    skip "[$REPO] 5. kept $DIR_REL/ (pass --purge to delete the clone)"
  elif [[ ! -d "$REPO_DIR" ]]; then
    skip "[$REPO] 5. no working tree at $DIR_REL/ — nothing to delete"
  else
    local dirty unpushed no_upstream reason
    dirty="$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"
    unpushed="$(git -C "$REPO_DIR" log --oneline '@{u}..' 2>/dev/null)"
    no_upstream=0; git -C "$REPO_DIR" rev-parse '@{u}' >/dev/null 2>&1 || no_upstream=1
    if [[ "$FORCE" -ne 1 && ( -n "$dirty" || -n "$unpushed" || "$no_upstream" -eq 1 ) ]]; then
      reason="$([[ -n "$dirty" ]] && printf 'uncommitted changes; '; [[ -n "$unpushed" ]] && printf 'unpushed commits; '; [[ "$no_upstream" -eq 1 ]] && printf 'no upstream to confirm pushed; ')"
      skip "[$REPO] 5. NOT deleting $DIR_REL/ — ${reason}re-run with --force to delete anyway"
    else
      rm -rf "$REPO_DIR" && ok "[$REPO] deleted working tree $DIR_REL/"
    fi
  fi
}

# ── plan: the repo(s) to offboard ────────────────────────────────────────────────
REPOS=()
if [[ "$ALL" -eq 1 ]]; then
  while IFS= read -r r; do [[ -n "$r" ]] && REPOS+=("$r"); done < <(all_repos)
  [[ "${#REPOS[@]}" -gt 0 ]] || die "--all: no onboarded repos found (nothing in workspace.config.yaml / mani.d)"
  SUMMARY_LABEL="ALL (${#REPOS[@]} repos)"
  printf '%sOffboarding ALL %d repos%s: %s\n' "$c_step" "${#REPOS[@]}" "$c_off" "${REPOS[*]}"
  [[ "$PURGE" -eq 1 ]] && printf '%s  --purge: WILL DELETE every working tree (refuses on a dirty/unpushed tree unless --force)%s\n' "$c_warn" "$c_off"
else
  REPOS=("$REPO")
  SUMMARY_LABEL="$REPO"
  printf '%sOffboarding repo "%s"%s  (dir: %s/%s)\n' "$c_step" "$REPO" "$c_off" "$(wc_path_for "$REPO")" \
    "$([[ "$PURGE" -eq 1 ]] && printf ' — WILL DELETE the working tree' || printf ' — kept (config-only)')"
fi

if [[ "$YES" -ne 1 && -t 0 ]]; then
  prompt="Proceed? [y/N] "; [[ "$ALL" -eq 1 ]] && prompt="Remove ALL ${#REPOS[@]} repos? [y/N] "
  read -r -p "$prompt" a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"
fi

# ── run: offboard each repo (steps 1–5) ───────────────────────────────────────────
for r in "${REPOS[@]}"; do offboard_one "$r"; done

# ── regenerate the dev-cycle workflow CONFIG from workspace.config.yaml (ONCE) ─────
# The workflow can't read the FS at runtime, so it carries an in-source mirror. Regenerate
# it from the (now repo-less) workspace.config.yaml so the removed entries are dropped too.
step "6. Regenerate the dev-cycle.js CONFIG from workspace.config.yaml"
GEN="$(cd "$(dirname "$0")" && pwd)/aiworks-config.sh"
if [[ -x "$GEN" ]]; then
  if out="$("$GEN" -q 2>&1)"; then ok "dev-cycle.js CONFIG re-mirrored from workspace.config.yaml (the removed entries are gone)"
  else skip "6. could not regenerate dev-cycle.js CONFIG — run 'aiworks config' by hand. Detail: ${out}"; fi
else
  skip "6. aiworks-config.sh not found — remove the entries from dev-cycle.js by hand"
fi

# ── summary ──────────────────────────────────────────────────────────────────────
printf '\n%s──────── offboarding summary: %s ────────%s\n' "$c_step" "$SUMMARY_LABEL" "$c_off"
printf '%sDone (%d):%s\n' "$c_ok" "${#DONE[@]}" "$c_off"; for d in "${DONE[@]:-}"; do [[ -n "$d" ]] && printf '  ✓ %s\n' "$d"; done
if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
  printf '%sSkipped (%d):%s\n' "$c_warn" "${#SKIPPED[@]}" "$c_off"
  for s in "${SKIPPED[@]}"; do printf '  ⤼ %s\n' "$s"; done
fi
printf '%sNext:%s the .claude/workflows/dev-cycle.js CONFIG was regenerated from workspace.config.yaml — no manual edit needed (re-run `aiworks config` any time to re-sync).\n' "$c_step" "$c_off"
