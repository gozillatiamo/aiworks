#!/usr/bin/env bash
# Host the implementor's visual results (screenshots, screen recordings) and print an
# embeddable "## Visual results" markdown section for a PR/MR body. Provider-neutral:
# uploads go through the adapter's vcs_upload_media (gh release asset / glab uploads API).
#
#   ./upload-media.sh --ticket FM-9 shot.png demo.mp4              # files
#   ./upload-media.sh --ticket FM-9 agent_logs/FM-9-media/         # a directory of media
#   ./upload-media.sh --ticket FM-9 https://cdn.example.com/x.png  # already-hosted URL
#   ./upload-media.sh --ticket FM-9 --dry-run shot.png             # preview, no upload
#
# Accepts any mix of files, directories, and http(s) URLs. Directories are scanned (one
# level deep) for images/videos. Prints NOTHING and exits 0 when no media is found, so a
# caller can append the output unconditionally.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: upload-media.sh --ticket <KEY> [--heading <text>] [--dry-run] <path|dir|url>...

Host media and print a "## Visual results" markdown section for a PR/MR body.

Options:
  --ticket  <KEY>   Ticket key, used to namespace assets + label each item (recommended).
  --heading <text>  Section heading (default: "## Visual results").
  --dry-run         Print the section that would be produced, without uploading.
  -h, --help        Show this help and exit.

Inputs:  any mix of image/video files, directories (scanned one level deep), and
         http(s) URLs (embedded as-is, not re-uploaded).
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

key=""; heading="## Visual results"; dry=0; items=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)  key="${2:-}";     shift 2 ;;
    --heading) heading="${2:-}"; shift 2 ;;
    --dry-run) dry=1;            shift ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)         items+=("$1");    shift ;;
  esac
done

[[ ${#items[@]} -gt 0 ]] || exit 0   # nothing to attach — silent, successful no-op.

# Expand inputs into a flat list of "files to upload" and "urls to embed".
files=(); urls=()
for it in "${items[@]}"; do
  case "$it" in
    http://*|https://*) urls+=("$it") ;;
    *)
      if [[ -d "$it" ]]; then
        # One level deep, sorted, media only. NUL-safe for spaces in names.
        while IFS= read -r -d '' f; do
          vcs_is_media "$f" && files+=("$f")
        done < <(find "$it" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
      elif [[ -f "$it" ]]; then
        if vcs_is_media "$it"; then files+=("$it")
        else echo "warn: skipping non-media file: $it" >&2; fi
      else
        echo "warn: not a file, directory, or url: $it" >&2
      fi
      ;;
  esac
done

# Build the markdown lines (uploads first, then pass-through URLs).
lines=()
for f in "${files[@]:-}"; do
  [[ -n "$f" ]] || continue
  if md="$(vcs_upload_media "$key" "$f" "$dry")"; then lines+=("$md"); fi
done
for u in "${urls[@]:-}"; do
  [[ -n "$u" ]] || continue
  base="${u##*/}"; base="${base%%\?*}"
  label="$(printf '%s%s' "${key:+$key }" "$base")"
  lines+=("$(vcs_media_md "$label" "$u" "$base")")
done

[[ ${#lines[@]} -gt 0 ]] || exit 0   # everything failed/filtered — emit nothing.

printf '%s\n\n' "$heading"
printf '%s\n' "${lines[@]}"
