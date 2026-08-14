#!/usr/bin/env bash
# mermaid-ink provider — renders via the public mermaid.ink / mermaid.live services.
# No auth, no install: one curl (render) or one local encode (live-link, nothing sent
# over the network until a human actually opens the link in a browser).
#
# Encoding notes (both endpoints, see https://mermaid.ink):
#   /img/<b64>   and  /svg/<b64>   — <b64> is plain URL-safe base64 of the raw Mermaid
#                                     TEXT (utf-8, no compression, no JSON envelope).
#   mermaid.live/edit#pako:<enc>   — <enc> is a URL-safe base64 of a ZLIB-DEFLATE
#                                     (pako.deflate-compatible) compressed JSON state
#                                     matching mermaid-live-editor's State type
#                                     (src/lib/types.d.ts): {"code":...,"mermaid":<JSON
#                                     STRING, e.g. "{\"theme\":\"default\"}">,
#                                     "updateDiagram":true,"rough":false}. The "mermaid"
#                                     field MUST be a JSON string, not a nested object —
#                                     the app does JSON.parse(state.mermaid) directly, so
#                                     a nested object throws and the editor renders blank.
#                                     Needed only for the human-editable live-editor link,
#                                     not for the image.

_b64url() {
  # stdin -> URL-safe base64, no line wraps, no padding (portable across BSD/GNU base64).
  base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

_pako_encode() {
  # stdin = raw Mermaid text; $1 = theme. Prints the pako-encoded state string.
  # Delegates to pako_encode.py (a real file, not a `python3 - <<PY` heredoc) —
  # a heredoc would replace this function's stdin entirely, so the piped Mermaid
  # text would never reach sys.stdin.read() inside the script.
  local theme="$1"
  python3 "$DIAGRAM_DIR/mermaid-ink/pako_encode.py" "$theme"
}

# diagram_render SOURCE_FILE OUT_FILE FORMAT THEME
diagram_render() {
  local source_file="$1" out_file="$2" format="$3" theme="$4"
  local text b64 path url http_code
  text="$(diagram_read_source "$source_file")"
  [[ -n "$text" ]] || die "empty Mermaid source — nothing to render"
  b64="$(printf '%s' "$text" | _b64url)"

  case "$format" in
    png) path="img"; url="https://mermaid.ink/${path}/${b64}?type=png&theme=${theme}" ;;
    svg) path="svg"; url="https://mermaid.ink/${path}/${b64}?theme=${theme}" ;;
    *)   die "unknown format '$format' (use png or svg)" ;;
  esac

  http_code="$(curl -fsSL -o "$out_file" -w '%{http_code}' "$url" 2>/dev/null)" \
    || die "mermaid.ink render failed (network error or invalid Mermaid syntax) — url: $url"
  [[ "$http_code" == "200" ]] || die "mermaid.ink returned HTTP $http_code — check the Mermaid syntax is valid"
  [[ -s "$out_file" ]] || die "mermaid.ink returned an empty body — check the Mermaid syntax is valid"
}

# diagram_live_link SOURCE_FILE THEME
diagram_live_link() {
  local source_file="$1" theme="$2"
  local text enc
  text="$(diagram_read_source "$source_file")"
  [[ -n "$text" ]] || die "empty Mermaid source — nothing to link"
  enc="$(printf '%s' "$text" | _pako_encode "$theme")"
  printf 'https://mermaid.live/edit#pako:%s\n' "$enc"
}

# diagram_live_link_check URL_OR_FRAGMENT — decode a link and confirm the editor can open
# it. For checking a link that has already travelled somewhere (a ticket body, a comment):
# a single altered base64 char kills the whole zlib stream, and mermaid.live answers a
# broken fragment by loading its own sample diagram, so the failure looks like success.
diagram_live_link_check() {
  python3 "$DIAGRAM_DIR/mermaid-ink/pako_check.py" "$1"
}
