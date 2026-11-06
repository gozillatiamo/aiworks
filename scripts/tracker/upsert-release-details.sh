#!/usr/bin/env bash
# Write a RELEASE's note in the configured tracker — onto the release page's own text section.
#
#   ./upsert-release-details.sh v1.0.0 --description-file note.txt
#   ./upsert-release-details.sh https://x.atlassian.net/projects/FM/versions/10042/tab/release-report-all-issues --description-file note.txt
#   ./upsert-release-details.sh 10042 --description-file note.txt --dry-run
#
# The release is a Jira VERSION; the ref is its URL, numeric id, or NAME (looked up inside
# JIRA_PROJECT_KEY). The note lands in the rich-text section at the top of the release page
# (titled "Release note"; `•` lines become a list, their indented lines the how-to under each
# bullet) and the version's plain description is CLEARED — the releases list prints that
# beside every version, no place for a note. Both are REPLACED whole on every run: a release
# note is a record, not a transcript. Providers with no release concept (Notion, Linear) refuse.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: upsert-release-details.sh <release> --description-file <path> [--dry-run]

Replace the release page's text section with the file's contents (plain text, UTF-8) and
clear the version's description.

  <release>                 Release URL, numeric version id, or version name (e.g. v1.0.0).
  --description-file <path> The note; `-` reads stdin.
  --dry-run                 Print the request instead of sending it.
  -h, --help                Show this help and exit.

Environment:
  TRACKER_PROVIDER   jira (the only provider with releases). Creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

ref=""; file=""; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --description-file) [[ -n "${2:-}" ]] || die "--description-file needs a path"; file="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1   (see -h)" ;;
    *)  [[ -z "$ref" ]] || die "unexpected argument: $1   (see -h)"; ref="$1"; shift ;;
  esac
done
[[ -n "$ref" ]]  || die "a release (URL, id or name) is required   (see -h)"
[[ -n "$file" ]] || die "--description-file is required   (see -h)"
if [[ "$file" == "-" ]]; then text="$(cat)"; else [[ -r "$file" ]] || die "cannot read $file"; text="$(cat "$file")"; fi
[[ -n "$text" ]] || die "the description is empty"

tracker_upsert_release "$ref" "$dry" "$text"
