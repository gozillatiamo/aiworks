#!/usr/bin/env bash
# Render a Mermaid diagram to a local PNG/SVG file, so it can be attached to a
# ticket via scripts/tracker/add-ticket-attachment.sh.
#
#   ./render.sh diagram.mmd out.png
#   echo 'flowchart LR; A-->B' | ./render.sh - out.png
#   ./render.sh diagram.mmd out.svg --theme dark
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: render.sh <mermaid-file|-> <out.png|out.svg> [--theme default|dark|forest|neutral]

Render Mermaid diagram source to a local image file via the configured diagram
provider (DIAGRAM_PROVIDER, default: mermaid-ink).

Arguments:
  <mermaid-file|-> Path to a file with raw Mermaid text, or "-" to read stdin.
  <out.png|out.svg> Destination path; the extension picks the render format.

Options:
  --theme <name>  Mermaid theme (default: default).
  --bg <color>    Background: a bare hex (FFFFFF), a !name (!white), or the word
                  "transparent". Default FFFFFF — OPAQUE on purpose. A transparent
                  PNG borrows whatever the viewer puts behind it, and Jira's
                  full-screen viewer is near-black, which makes the diagram's own
                  dark text and edges unreadable. Only ask for transparent when the
                  page it lands on is known.
  --dry-run       Print the provider URL that would be fetched; render nothing.
  -h, --help      Show this help and exit.

This script always renders when invoked — the "should a diagram be generated at
all" decision (workspace.config.yaml diagrams.enabled) lives in the calling
skill (/diagram-ticket), not here.
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

source_file=""; out_file=""; theme="default"; bg="FFFFFF"; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --theme) theme="${2:-}"; shift 2 ;;
    --bg)    [[ -n "${2:-}" ]] || die "--bg needs a color (hex, !name, or transparent)"; bg="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -|[!-]*)
      if [[ -z "$source_file" ]]; then source_file="$1"; elif [[ -z "$out_file" ]]; then out_file="$1"; else die "unexpected argument: $1"; fi
      shift ;;
    *) die "unknown option: $1   (see -h)" ;;
  esac
done

[[ -n "$source_file" ]] || die "usage: $(basename "$0") <mermaid-file|-> <out.png|out.svg>   (see -h)"
[[ -n "$out_file" ]]     || die "usage: $(basename "$0") <mermaid-file|-> <out.png|out.svg>   (see -h)"

format="${out_file##*.}"
diagram_render "$source_file" "$out_file" "$format" "$theme" "$bg" "$dry"
[[ "$dry" -eq 1 ]] || echo "rendered: $out_file ($(wc -c <"$out_file" | tr -d ' ') bytes, bg $bg)"
