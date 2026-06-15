#!/usr/bin/env bash
# Open (or reuse) a pull request / merge request for the current ticket branch.
# Provider-neutral: github -> gh pr, gitlab -> glab mr. Prints the URL + number=.
#
#   ./open-pr.sh --head feature/FM-9 --base develop --title "FM-9: Add pet" --body "…"
#   ./open-pr.sh --title "FM-9: Add pet" --body "…"        # head=current branch, base=default
#   ./open-pr.sh --title "…" --body "…" --media shot.png --media demo.mp4
#   ./open-pr.sh --title "…" --body "…" --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: open-pr.sh --title <t> [--base <b>] [--head <h>] [--body <b>]
                  [--media <path|dir|url>]... [--ticket <KEY>] [--dry-run]

Open (or reuse) a PR/MR for HEAD -> BASE in the current repo.

Options:
  --title  <text>  PR/MR title (required).
  --base   <branch> Target branch (default: the repo's default branch).
  --head   <branch> Source branch (default: the current branch).
  --body   <text>  PR/MR description (default: empty).
  --media  <ref>   A visual result to attach (image/video file, a directory of them,
                   or an http(s) URL). Repeatable. Each is hosted via the adapter and
                   appended to the body under a "## Visual results" section.
  --ticket <KEY>   Ticket key for naming/labelling attached media (default: derived
                   from the head branch, e.g. feature/FM-9 -> FM-9).
  --dry-run        Print what would run (including the assembled body), without pushing,
                   uploading, or creating anything.
  -h, --help       Show this help and exit.

Environment:
  VCS_PROVIDER       github | gitlab (default: auto-detected from the origin remote).
  VCS_MEDIA_RELEASE  GitHub only: release tag used to host media (default: pr-media).
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

base=""; head=""; title=""; body=""; ticket=""; dry=0; media=()
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    need "${2:-}" "--base needs a value";  base="$2";   shift 2 ;;
    --head)    need "${2:-}" "--head needs a value";  head="$2";   shift 2 ;;
    --title)   need "${2:-}" "--title needs a value"; title="$2";  shift 2 ;;
    --body)    body="${2:-}"; shift 2 ;;
    --media)   need "${2:-}" "--media needs a value"; media+=("$2"); shift 2 ;;
    --ticket)  need "${2:-}" "--ticket needs a value"; ticket="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         die "unexpected argument: $1   (see -h)" ;;
  esac
done

[[ -n "$title" ]] || die "--title is required (see -h)"
[[ -n "$head" ]]  || head="$(git rev-parse --abbrev-ref HEAD)"
[[ -n "$base" ]]  || base="$(vcs_default_branch)"
[[ "$head" != "$base" ]] || die "head ($head) == base ($base) — nothing to open"

# Attach the implementor's visual results, if any, under a "## Visual results" section.
# Ticket defaults to the <PREFIX>-<n> embedded in the head branch (feature/FM-9 -> FM-9).
if [[ ${#media[@]} -gt 0 ]]; then
  [[ -n "$ticket" ]] || ticket="$(printf '%s' "$head" | grep -oiE '[A-Z]+-[0-9]+' | head -n1 || true)"
  dryflag=(); [[ "$dry" -eq 1 ]] && dryflag=(--dry-run)
  # bash 3.2 (macOS /bin/bash): expanding an EMPTY array as "${dryflag[@]}" trips
  # `set -u` ("unbound variable"). The ${arr[@]+"${arr[@]}"} form expands to nothing
  # when empty and to the elements (one word each) when set — bash-3.2-safe, and unlike
  # "${arr[@]:-}" it never injects a spurious empty positional argument.
  section="$("$DIR/upload-media.sh" --ticket "$ticket" ${dryflag[@]+"${dryflag[@]}"} "${media[@]}" || true)"
  if [[ -n "$section" ]]; then
    body="${body:+$body$'\n\n'}$section"
  fi
fi

# On a dry run, show the body we'd send (so callers/tests can see the media section).
if [[ "$dry" -eq 1 && -n "$body" ]]; then
  printf -- '--- body ---\n%s\n--- end body ---\n' "$body"
fi

vcs_open_pr "$base" "$head" "$title" "$body" "$dry"
