#!/usr/bin/env bash
# Comment on a PR/MR — inline at PATH:LINE where the provider supports it, else a
# normal PR/MR comment that references PATH:LINE in its text.
#
# Review-comment convention (all reviewers): a review comment MUST anchor to the
# code — pass --path + --line so it lands inline at the exact spot, AND quote the
# offending line/block as a fenced code snippet in --body. No vague, location-less
# review comments.
#
# Anchor precision: the FIRST line of the quoted snippet is the exact offending line, and
# --line is VERIFIED against it. If the anchored line doesn't contain that quoted line, the
# anchor auto-corrects to the unique match within ±ANCHOR_WINDOW lines (the small off-by-N
# slip — e.g. a definition whose --line landed on the blank/attribute line above the
# signature), printing the correction; with no unique nearby match it posts as given and
# WARNs. So the highlight always covers the code the comment is about.
#
#   ./pr-comment.sh 42 --path lib/foo.dart --line 88 \
#       --body $'Guard the null case.\n\n```dart\nfinal pet = cache[id]; // can be null\nreturn pet.name;       // NPE if absent\n```'
#   ./pr-comment.sh 42 --body "Overall LGTM."
#   ./pr-comment.sh 42 --path … --line … --body … --dry-run
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: pr-comment.sh <number> --body <text> [--path <file> --line <n>] [--dry-run]

Options:
  --body <text>  Comment body (required).
  --path <file>  File to anchor an inline comment to (optional).
  --line <n>     Line number for the inline comment (optional; needs --path).
  --dry-run      Print what would be posted, without posting.
  -h, --help     Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

num=""; path=""; line=""; body=""; dry=0
need() { [[ -n "${1:-}" ]] || die "$2"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    need "${2:-}" "--path needs a value"; path="$2"; shift 2 ;;
    --line)    need "${2:-}" "--line needs a value"; line="$2"; shift 2 ;;
    --body)    need "${2:-}" "--body needs a value"; body="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         num="$1"; shift ;;
  esac
done

[[ -n "$num" ]]  || die "usage: $(basename "$0") <number> --body <text> [--path <f> --line <n>]"
[[ -n "$body" ]] || die "--body is required (see -h)"

# Anchor precision guard (provider-neutral): make the inline anchor land on the code the
# comment quotes. The body convention quotes the offending line/block as a fenced snippet
# whose FIRST line is that exact line; verify --line against it and auto-correct a small
# off-by-N (unique match within ±ANCHOR_WINDOW lines), else post as given and WARN. Only
# fires for an inline comment (--path + --line) whose file is readable on the checked-out
# branch (the new/RIGHT side the anchor targets).
ANCHOR_WINDOW=15
verify_anchor() {
  [[ -n "$path" && -n "$line" && -f "$path" ]] || return 0
  local quoted q at lo hi matches n newline
  # First non-blank line inside the first fenced ``` block of the body.
  quoted="$(printf '%s\n' "$body" | awk '
    /^[[:space:]]*```/ { if (!inb) { inb=1; next } else { exit } }
    inb && $0 !~ /^[[:space:]]*$/ { print; exit }')"
  q="$(printf '%s' "$quoted" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$q" ]] || return 0                                    # nothing quoted → can't verify
  at="$(sed -n "${line}p" "$path" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ "$at" == *"$q"* ]] && return 0                            # already on the quoted line
  lo=$(( line > ANCHOR_WINDOW ? line - ANCHOR_WINDOW : 1 )); hi=$(( line + ANCHOR_WINDOW ))
  matches="$(awk -v lo="$lo" -v hi="$hi" -v q="$q" '
    NR>=lo && NR<=hi { s=$0; gsub(/^[[:space:]]+/,"",s); gsub(/[[:space:]]+$/,"",s)
                       if (index(s,q)) print NR }' "$path")"
  n="$(printf '%s' "$matches" | grep -c . || true)"
  if [[ "$n" -eq 1 ]]; then
    newline="$(printf '%s' "$matches" | head -n1)"
    printf 'note: anchor auto-corrected %s:%s -> %s to match the quoted code (%q)\n' "$path" "$line" "$newline" "$q" >&2
    line="$newline"
  else
    printf 'WARN: anchor %s:%s does not contain the quoted code (%q) and no unique match within ±%s lines — posting at %s as given; check the anchor\n' \
      "$path" "$line" "$q" "$ANCHOR_WINDOW" "$line" >&2
  fi
}
verify_anchor
vcs_pr_comment "$num" "$path" "$line" "$body" "$dry"
