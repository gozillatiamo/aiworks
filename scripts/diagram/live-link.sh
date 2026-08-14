#!/usr/bin/env bash
# Print a mermaid.live edit-in-browser link for a Mermaid diagram — nothing is
# sent over the network until a human actually opens the link.
#
#   ./live-link.sh diagram.mmd
#   echo 'flowchart LR; A-->B' | ./live-link.sh -
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: live-link.sh <mermaid-file|-> [--theme default|dark|forest|neutral]
       live-link.sh --check <url|pako-fragment|->

Print a mermaid.live edit link encoding the given Mermaid source, via the
configured diagram provider (DIAGRAM_PROVIDER, default: mermaid-ink).

Arguments:
  <mermaid-file|-> Path to a file with raw Mermaid text, or "-" to read stdin.

Options:
  --theme <name>  Mermaid theme (default: default).
  --check <url>   Don't encode: DECODE an existing link and confirm the editor can
                  open it. Use on a link after it has landed somewhere (a ticket
                  body, a comment) — one altered base64 character kills the zlib
                  stream, and mermaid.live answers a broken fragment by quietly
                  loading its own sample diagram, so it still looks like a diagram.
                  Accepts "-" to read the link from stdin.
  -h, --help      Show this help and exit.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

source_file=""; theme="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      [[ -n "${2:-}" ]] || die "--check needs a url, a pako fragment, or '-' for stdin"
      diagram_live_link_check "$2"; exit 0 ;;
    --theme) theme="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -|[!-]*)
      if [[ -z "$source_file" ]]; then source_file="$1"; else die "unexpected argument: $1"; fi
      shift ;;
    *) die "unknown option: $1   (see -h)" ;;
  esac
done

[[ -n "$source_file" ]] || die "usage: $(basename "$0") <mermaid-file|->   (see -h)"

diagram_live_link "$source_file" "$theme"
