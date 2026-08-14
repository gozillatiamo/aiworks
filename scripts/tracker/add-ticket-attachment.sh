#!/usr/bin/env bash
# Attach a local file to a ticket in the configured tracker.
#
#   ./add-ticket-attachment.sh FM-9 ./mockup.png
#   ./add-ticket-attachment.sh FM-9 ./mockup.png --dry-run   # preview, don't send
#   id=$(./add-ticket-attachment.sh FM-9 ./shot.png --embed-id)  # then embed it in a comment
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: add-ticket-attachment.sh <ticket> <file> [--id-only|--embed-id] [--dry-run]

Upload a local file as an attachment on a ticket in the configured tracker
(TRACKER_PROVIDER). Jira: supported. Notion: not yet implemented.

An upload yields TWO handles and they are not interchangeable:

  the ATTACHMENT ID (numeric)  — the tracker's own handle. Use it to remove or
                                 download the file later.
  the EMBED ID (a media uuid)  — the only thing an inline image accepts. Feeding
                                 the numeric id to a comment is rejected with a
                                 bare ATTACHMENT_VALIDATION_ERROR.

To show the file inside a comment rather than burying it in the Attachments panel:

  id=$(add-ticket-attachment.sh FM-9 ./shot.png --embed-id)
  printf '![shot](attachment:%s)\n' "$id" | add-ticket-comment.sh FM-9

For an image the embed id carries the file's pixel size as a "@<W>x<H>" suffix
(uuid@1859x1053). Paste it WHOLE: without the size Jira renders the picture in
its 250x200 fallback box, which is a stamp nobody can read a screenshot from.

The image must sit ALONE on its line; several on one line render as a thumbnail strip.

Arguments:
  <ticket>      Ticket key (FM-9, APP-123, a number), a page id, or a URL.
  <file>        Path to the local file to upload.

Options:
  --id-only     Print ONLY the numeric attachment id (for remove/download).
  --embed-id    Print ONLY the media uuid — plus "@<W>x<H>" for an image — for
                ![alt](attachment:<id>) in a comment. Use it whole.
  --dry-run     Print the request instead of sending it.
  -h, --help    Show this help and exit.

Environment:
  TRACKER_PROVIDER  notion | jira (default: notion). Provider creds live in .env.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

ticket=""; file=""; dry=0; id_only=0; embed_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --id-only) id_only=1; shift ;;
    --embed-id) embed_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ -z "$ticket" ]]; then ticket="$1"; elif [[ -z "$file" ]]; then file="$1"; else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[[ -n "$ticket" ]] || die "usage: $(basename "$0") <ticket> <file>   (see -h)"
[[ -n "$file" ]]   || die "usage: $(basename "$0") <ticket> <file>   (see -h)"

if [[ "$id_only" -eq 1 && "$embed_only" -eq 1 ]]; then
  die "--id-only and --embed-id are different handles; pick one (see -h)"
fi

tracker_add_attachment "$ticket" "$dry" "$file" "$id_only" "$embed_only"
