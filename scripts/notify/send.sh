#!/usr/bin/env bash
# Send one notification through the configured chat provider (NOTIFY_PROVIDER).
#
#   ./send.sh "Please review FM-12 …"                       # text as an argument
#   ./send.sh --channel "#reviews" "Please review FM-12 …"  # explicit channel
#   printf '%s' "$msg" | ./send.sh --channel "#reviews"     # text from stdin
#   ./send.sh "…" --dry-run                                 # preview, don't send
#
# The channel defaults to NOTIFY_CHANNEL (from scripts/notify/.env) when --channel is
# omitted. On success the provider prints `ok=1` and (where available) `permalink=<url>`.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: send.sh [--channel <id|#name>] [text] [--dry-run]

Post a message to the configured chat provider (NOTIFY_PROVIDER: slack). The message
text comes from the [text] argument, or from stdin when none is given.

Options:
  --channel <ch>  Target channel (id or #name). Default: $NOTIFY_CHANNEL from .env.
                  Ignored by providers whose destination is fixed (e.g. a Slack webhook).
  --dry-run       Print what would be sent instead of sending it.
  -h, --help      Show this help and exit.

Environment (scripts/notify/.env):
  NOTIFY_PROVIDER   slack (default).
  NOTIFY_CHANNEL    default channel when --channel is omitted.
  SLACK_BOT_TOKEN   bot token for chat.postMessage (honours the channel + returns a permalink), OR
  SLACK_WEBHOOK_URL incoming webhook URL (channel fixed by the webhook).
EOF
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

channel="${NOTIFY_CHANNEL:-}"; text=""; have_text=0; dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) channel="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ "$have_text" -eq 0 ]]; then text="$1"; have_text=1; else die "unexpected argument: $1   (see -h)"; fi
      shift ;;
  esac
done

# No text argument → read it from stdin (a redirected file or a pipe).
if [[ "$have_text" -eq 0 && ! -t 0 ]]; then text="$(cat)"; fi
[[ -n "$text" ]] || die "no message text — pass it as an argument or pipe it via stdin"

notify_send "$channel" "$text" "$dry"
