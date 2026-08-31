#!/usr/bin/env bash
# VCS adapter — shared dispatch for the PR/MR scripts.
# Sourced by the entry scripts (open-pr/pr-view/pr-comment/merge-pr/default-branch).
#
# Selects a provider implementation by VCS_PROVIDER (github | gitlab) and sources
# scripts/vcs/<provider>.sh, which defines the provider interface:
#
#   vcs_require_config                          — ensure the provider CLI is installed
#   vcs_open_pr   BASE HEAD TITLE BODY [DRY]    — create (or reuse) a PR/MR; print URL + number=
#   vcs_find_prs  KEY                           — print URLs of OPEN PRs/MRs whose title/branch contains KEY (read-only)
#   vcs_pr_view   NUMBER                        — print state=<MERGED|OPEN|CLOSED> + merge_sha= + approved=<yes|no|unknown>
#   vcs_pr_approved NUMBER                      — print yes|no|unknown: does the forge already record an approval on this PR/MR
#   vcs_pr_comment NUMBER PATH LINE BODY [DRY]  — comment (inline at PATH:LINE where supported;
#                                                 LINE is a single line N or a range N-M that
#                                                 highlights the whole block, not just its top)
#   vcs_pr_comments NUMBER                      — print the PR/MR's comments as plain text
#   vcs_pr_threads NUMBER                       — list resolvable review threads + their ids/state
#   vcs_pr_resolve_thread NUMBER THREAD_ID [RESOLVED=true] [DRY] — check/uncheck "Resolve thread"
#   vcs_pr_reply  NUMBER THREAD_ID BODY [DRY]  — post a threaded reply INSIDE an existing thread (nested, not a new comment)
#   vcs_merge_pr  NUMBER SUBJECT [DRY]          — server-side squash-merge, then print pr-view
#   vcs_approve_pr NUMBER BODY [DRY]            — reviewer PASS signal: post BODY as a one-line verdict + host-level approve (decoupled from merge). IDEMPOTENT: a no-op when vcs_pr_approved already says yes
#   vcs_close_pr  NUMBER [DRY]                  — close without merging (branch kept), then pr-view
#   vcs_upload_media KEY FILE [DRY]             — host one media file, print its embeddable markdown line
#
# default-branch and the media helpers below are provider-neutral, so they live here.
#
# The repo a call acts on defaults to the current working directory's git remote. An explicit
# VCS_REPO overrides that default for every provider (vcs_repo_ref below): a parallel() wave of
# per-repo agents shares one Bash cwd, so the cwd default alone mis-targets writes in that case.

set -euo pipefail

VCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The first characters of every approval verdict this adapter posts. Two jobs, both of which
# need the string to be STABLE across providers and across runs:
#   1. it is the second-tier record of an approval on a forge whose approvals API is disabled
#      (vcs_approve_pr degrades to a plain note; vcs_pr_approved reads that note back), and
#   2. it is what makes vcs_approve_pr idempotent, so a re-run of a review gate that already
#      passed does not stack a second identical verdict on the same PR/MR.
# Callers SHOULD start their --body with it; vcs_approve_pr prepends it when they don't.
VCS_APPROVAL_MARKER="${VCS_APPROVAL_MARKER:-✅ APPROVED}"

# .env carries the CREDENTIALS and the workspace's normal defaults. It must not, however, be able
# to overrule a routing variable the CALLER set explicitly on the command line: aiming a call at a
# different provider or remote is exactly how an UPSTREAM contribution is made from a clone whose
# own remote is elsewhere —
#     VCS_PROVIDER=github VCS_REMOTE=aiworks scripts/vcs/open-pr.sh …
# — and `set -a; . .env` overwrites both, silently, so the call goes to the workspace's own forge
# while reporting success. Snapshot the caller's values and put them back afterwards.
_vcs_arg_provider="${VCS_PROVIDER:-}"
_vcs_arg_remote="${VCS_REMOTE:-}"
_vcs_arg_repo="${VCS_REPO:-}"
if [[ -f "$VCS_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$VCS_DIR/.env"
  set +a
fi
[[ -n "$_vcs_arg_provider" ]] && VCS_PROVIDER="$_vcs_arg_provider"
[[ -n "$_vcs_arg_remote" ]] && VCS_REMOTE="$_vcs_arg_remote"
[[ -n "$_vcs_arg_repo" ]] && VCS_REPO="$_vcs_arg_repo"
unset _vcs_arg_provider _vcs_arg_remote _vcs_arg_repo

# A VCS_REPO value reduced to the PROJECT PATH the forge knows — `group/subgroup/project` on
# GitLab, `owner/repo` on GitHub. That path is what every API call needs, and it is not what a
# caller has in hand: `git remote get-url origin` and workspace.config.yaml's `repos[].url` both
# print a CLONE URL. Sent verbatim, a URL reaches the API as a project id and comes back
# `{"message":"404 Project Not Found"}` — indistinguishable from a broken adapter, which is how a
# real run spent three rounds on it. A path with no host in it is already the answer and is left
# alone, so no existing caller changes.
vcs_normalize_repo_ref() {
  local r="${1%.git}"
  case "$r" in
    *://*) r="${r#*://}"; r="${r#*@}"; r="${r#*/}" ;;   # scheme URL: drop scheme, userinfo, host
    *@*:*) r="${r#*@}"; r="${r#*:}" ;;                  # scp-style git@host:group/project
  esac
  r="${r#/}"; printf '%s' "${r%/}"
}

# Project/repo the call acts on: explicit VCS_REPO wins, else the provider's own cwd-derived
# default (unchanged behaviour for every existing caller that never sets VCS_REPO). VCS_REPO is
# resolved to a project path ONCE, below — not here, because this runs inside `$( )` at every call
# site and a `die` in a command substitution kills only that subshell.
vcs_repo_ref() { printf '%s' "${VCS_REPO:-}"; }

# A DIAGNOSTIC CHANNEL that a command substitution cannot swallow. The providers' mutation calls
# announce which project they resolved (a wrong-target call used to surface as a bare exit 1 with no
# output at all), but several call sites capture a command's stderr — `err=$(… 2>&1)` — and then
# CLASSIFY the text: `case "$err" in *405*|*"not allowed"*`. A line written to fd 2 inside such a
# call lands in that string, so a group or repo whose name merely contains one of those patterns
# would turn any failure into a confident misdiagnosis.
#
# fd 9 is a duplicate of stderr taken HERE, before any of those redirections exist, so writing to it
# reaches the real stderr and never the captured value. `exec 9>&2` (not `{fd}>&2`) because macOS
# still ships bash 3.2.
exec 9>&2

# GitLab's URL-encoded project-path form (owner%2Frepo). No `${var//…}` substitution — it behaves
# differently on bash 3.2 (macOS's /bin/bash) vs 5.x for this pattern; sed is portable.
vcs_urlencode_path() { printf '%s' "$1" | sed 's@/@%2F@g'; }

die() { echo "error: $*" >&2; exit 1; }
command -v git >/dev/null || die "git is required"

# The workspace config that declares the repos, when this adapter runs inside a workspace. The
# adapters are SYMLINKED into every product repo, so the script's own logical path says nothing
# about where the workspace root is; `cd -P` resolves the symlink and lands on the real one.
_vcs_workspace_config() {
  local d
  for d in "${CLAUDE_PROJECT_DIR:-}" "$(cd -P "$VCS_DIR/../.." 2>/dev/null && pwd)"; do
    [[ -n "$d" && -f "$d/workspace.config.yaml" ]] && { printf '%s' "$d/workspace.config.yaml"; return 0; }
  done
  return 1
}

# Bare repo id -> the project path declared for it. `products[].repos[].url` is the ONE place the
# namespace is written down, and its last segment is the repo id the rest of the workspace uses
# (the same derivation aiworks-config.sh makes), so the lookup is: normalize every declared url,
# match on its last segment. Ambiguity is refused rather than guessed — two products may each
# declare a repo of the same name, and picking one at random writes to a stranger's project.
_vcs_path_for_repo_id() {
  local id="$1" cfg url path hit=''
  cfg="$(_vcs_workspace_config)" || return 1
  while IFS= read -r url; do
    path="$(vcs_normalize_repo_ref "$url")"
    [[ "${path##*/}" == "$id" ]] || continue
    if [[ -n "$hit" && "$hit" != "$path" ]]; then printf '%s\n%s' "$hit" "$path"; return 2; fi
    hit="$path"
  done < <(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*url:[[:space:]]*//p' "$cfg" | sed 's/[[:space:]]*#.*$//; s/["'"'"']//g')
  [[ -n "$hit" ]] || return 1
  printf '%s' "$hit"
}

# VCS_REPO IS RESOLVED HERE, ONCE, FOR EVERY PROVIDER AND EVERY SCRIPT. Three things get passed in
# it and only one of them is what the API wants:
#   • the project path (`group/subgroup/project`, `owner/repo`) — already correct, untouched;
#   • a clone URL — what `git remote get-url origin` and `repos[].url` print;
#   • a bare repo id (`project`) — what the workspace calls a repo everywhere else, so it is what
#     an agent reaches for and what the workflow's own prompts interpolate.
# The last two used to travel to the forge verbatim and come back `404 Project Not Found`, which
# reads like a broken adapter rather than a wrong argument. Fix it once, at the choke point every
# caller routes through, and fail LOUD (naming the config) when an id resolves to nothing.
if [[ -n "${VCS_REPO:-}" ]]; then
  VCS_REPO="$(vcs_normalize_repo_ref "$VCS_REPO")"
  case "$VCS_REPO" in
    */*) ;;
    *)
      _vcs_id="$VCS_REPO"
      if _vcs_hit="$(_vcs_path_for_repo_id "$_vcs_id")"; then
        VCS_REPO="$_vcs_hit"
      elif [[ "$?" -eq 2 ]]; then
        die "VCS_REPO='$_vcs_id' matches more than one repo declared in workspace.config.yaml:
$(printf '%s' "$_vcs_hit" | sed 's/^/      /')
  Pass the full project path of the one you mean."
      else
        _vcs_cfg="$(_vcs_workspace_config || true)"
        die "VCS_REPO='$_vcs_id' is a bare repo name, and the forge needs the full project path (group/subgroup/project on GitLab, owner/repo on GitHub) — sent as-is it returns '404 Project Not Found'.
  ${_vcs_cfg:+No repo with that name is declared in $_vcs_cfg}${_vcs_cfg:-No workspace.config.yaml was found (this checkout is not inside a workspace)}, so resolve it from the repo itself:
      git -C <the repo> remote get-url origin
  and pass what it prints (this adapter strips the git@host:/https://host/ prefix and the .git suffix for you)."
      fi
      unset _vcs_id _vcs_hit ;;
  esac
fi

# Resolve the provider: explicit VCS_PROVIDER wins; else sniff the origin remote host.
vcs_detect_provider() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *gitlab*) echo gitlab ;;
    *github*) echo github ;;
    *)        echo github ;; # default for github.com-style or unknown remotes
  esac
}

# Provider-neutral default-branch resolution (used by every provider).
vcs_default_branch() {
  local b
  b="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  [[ -n "$b" ]] || b="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n1 || true)"
  printf '%s' "${b:-main}"
}

# ── Media helpers (shared by the providers' vcs_upload_media) ─────────────────────
# Images render inline in a PR/MR body; everything else (video, zip, log) is linked,
# because most hosts only inline-play video for their own native web uploads — a link
# is the honest, always-works fallback. Extension-based, lowercased.
vcs_is_image() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    png|jpg|jpeg|gif|webp|svg|bmp|avif) return 0 ;;
    *) return 1 ;;
  esac
}

# A file is "media" worth attaching if it's an image or a common screen-capture video.
vcs_is_media() {
  vcs_is_image "$1" && return 0
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mp4|mov|webm|m4v|mkv) return 0 ;;
    *) return 1 ;;
  esac
}

# Render one embeddable markdown line: image syntax for images, a link otherwise.
vcs_media_md() {
  local label="$1" url="$2" name="$3"
  if vcs_is_image "$name"; then printf '![%s](%s)\n' "$label" "$url"
  else printf '[%s](%s)\n' "$label" "$url"; fi
}

# Asset names live in URLs/headers — keep them URL-safe and namespaced by ticket.
vcs_media_asset_name() {
  local key="$1" base="$2" name
  name="$(printf '%s' "$base" | tr ' ' '-' | sed 's/[^A-Za-z0-9._-]//g')"
  printf '%s%s' "${key:+${key}-}" "$name"
}

# A WRITER run from the META-REPO root targets the WORKSPACE repo — almost never what the
# caller meant. The adapters are symlinked into every product repo (scripts/vcs -> ../../scripts/vcs),
# so the same relative path works from anywhere and NOTHING signals which repo you are actually
# in: `git rev-parse --show-toplevel` inside the symlink answers with the meta-repo too. An agent
# that forgets to cd therefore opens its MR against the workspace, silently and successfully.
# Fail LOUD instead — the difference between "I misread this error as a broken adapter" and
# "I cd into the repo and retry" is the whole distance between those two outcomes.
# Framework work on the workspace's own repo is real: set VCS_ALLOW_META_REPO=1 deliberately.
# An explicit VCS_REPO satisfies the guard the same way: it is exactly the signal "nothing
# tells you which repo you're in" was missing, so a caller that names the repo explicitly is not
# the blind cwd case this guard exists to catch. With NEITHER set, it still dies loud.
case "$(basename "${0:-}")" in
  open-pr.sh|merge-pr.sh|close-pr.sh|pr-approve.sh|pr-comment.sh|pr-resolve-thread.sh|upload-media.sh)
    if [[ "${VCS_ALLOW_META_REPO:-0}" != 1 && -z "${VCS_REPO:-}" ]]; then
      _top=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$_top" && -f "$_top/workspace.config.yaml" ]]; then
        die "$(basename "$0") was run from the WORKSPACE root ($_top), so it would act on the workspace repo itself, not on a product repo.
  cd into the repo first — as its own command, since a writer must run BARE:
      cd $_top/<repo>
      scripts/vcs/$(basename "$0") …
  If you really do mean the workspace repo (framework work), re-run with VCS_ALLOW_META_REPO=1."
      fi
    fi ;;
esac

# Which remote a branch is pushed to before the PR/MR is opened. Normally `origin` — but a
# FRAMEWORK repo contributed from an adopter's clone has origin pointing at the adopter's own
# forge and the upstream as a second remote, so the branch would land on the wrong host.
VCS_REMOTE="${VCS_REMOTE:-origin}"

# Push HEAD's branch to the forge before opening the PR/MR — but ONLY from the target repo.
#
# VCS_REPO redirects every API call, and that was read as "the call is now cwd-independent". It
# is not: `git push` has no --repo, so it acts on the CURRENT WORKING DIRECTORY whatever VCS_REPO
# says. A parallel() wave of per-repo agents shares ONE Bash cwd, so `VCS_REPO=<other repo>
# open-pr.sh` pushed THIS repo's branch to THIS repo's remote and then asked the forge to open an
# MR from a branch that had never reached the target project. Pushing the wrong repo's branch is
# a real side effect on a real forge, so SKIP rather than guess — vcs_open_pr then reports the
# missing branch with the `git -C <repo> push` that fixes it, which is the actionable half.
vcs_push_head() {
  local head="$1" r url
  r="$(vcs_repo_ref)"
  if [[ -n "$r" ]]; then
    url="$(git remote get-url "$VCS_REMOTE" 2>/dev/null || true)"
    case "${url%.git}" in
      *"/$r"|*":$r") : ;;
      *) printf 'vcs: cwd remote (%s) is not %s — NOT pushing %s from here; it must already be on the target project\n' \
           "${url:-<none>}" "$r" "$head" >&9
         return 0 ;;
    esac
  fi
  git push -u "$VCS_REMOTE" "$head" >/dev/null 2>&1 || true
}

VCS_PROVIDER="${VCS_PROVIDER:-$(vcs_detect_provider)}"
IMPL="$VCS_DIR/$VCS_PROVIDER.sh"
[[ -f "$IMPL" ]] || die "unknown VCS_PROVIDER '$VCS_PROVIDER' (no $IMPL) — use 'github' or 'gitlab', or add $VCS_PROVIDER.sh"

# shellcheck disable=SC1090
. "$IMPL"
vcs_require_config
