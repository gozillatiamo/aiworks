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
       send.sh --review <ticket-key> [--title <text>] [--channel <ch>] [--dry-run]
       send.sh --reply <ticket-key> [text] [--channel <ch>] [--dry-run]

Post a message to the configured chat provider (NOTIFY_PROVIDER: slack).

Two ways to supply the message:
  • raw       — the [text] argument, or stdin when none is given.
  • --review  — compose a "please review" digest for a ticket: gather its OPEN PR/MR
                across EVERY workspace repo (matched by the ticket key in the PR/MR title
                or branch, via scripts/vcs/find-prs.sh) and format
                  Please review, <KEY> <title>.
                  <ticket endpoint URL>
                  - <repo>: <url>
                The gather is done here so no repo is ever missed. Exits non-zero when
                the ticket has no open PR/MR anywhere (nothing to announce).

--reply threads the message UNDER the review-request for a ticket: it finds the newest
channel message containing the key (the "please review" the requester posted) and replies
in that thread. If no such thread is found, it SKIPS — prints `skipped=1` and posts
nothing (never a stray top-level message). This is how a reviewer's verdict lands where
the request was made. Reply mode needs a bot token (a webhook can't read history) — a
webhook always skips.

Options:
  --review <KEY>  Compose + send the review digest for ticket KEY (don't also pass text).
  --reply <KEY>   Post [text] as a reply in the review-request thread for KEY; skip if none.
  --title <text>  Header title for --review (default: looked up from the tracker adapter).
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

# Assemble the "please review" digest for a ticket by gathering its OPEN PR/MR across
# EVERY workspace repo — deterministic, so no repo is ever missed (the failure mode when
# the list is assembled by hand). A repo's PR/MR is matched by the ticket key in its title
# or branch via the VCS adapter (scripts/vcs/find-prs.sh). The shape is:
#
#   Please review, <KEY> <title>.
#   <ticket endpoint URL>
#   - <repo>: <pr_url>
#   - <repo>: <pr_url>
#
# Title + endpoint come from the tracker adapter (get-ticket-details.sh: line 1 is
# "<KEY> — <title>", line 2 is the ticket endpoint URL). The lookup is best-effort — a
# caller-supplied --title wins for the header, and an unreachable tracker just omits the
# endpoint line; neither ever blocks the send.
compose_review_digest() {  # KEY [TITLE]  -> prints the digest, or nothing if no PR/MR found
  local key="$1" title="${2:-}"
  local root repo name url rows="" any=0 details="" endpoint=""
  root="$(cd "$DIR/../.." && pwd)"   # scripts/notify/ -> workspace (org) root
  if [[ -x "$root/scripts/tracker/get-ticket-details.sh" ]]; then
    details="$("$root/scripts/tracker/get-ticket-details.sh" "$key" 2>/dev/null || true)"
  fi
  # Header title: --title wins; else line 1 "<KEY> — <title>" (dropped if it's just the key).
  if [[ -z "$title" && -n "$details" ]]; then
    title="$(printf '%s\n' "$details" | head -n1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*(—|–|-)?[[:space:]]*//")"
    [[ -z "${title//[[:space:]]/}" || "$title" == *"$key"* ]] && title=""
  fi
  # Endpoint: the URL on line 2 (the adapter's contract). Omitted if absent/not a URL.
  if [[ -n "$details" ]]; then
    endpoint="$(printf '%s\n' "$details" | sed -n '2p' | grep -oE 'https?://[^[:space:]]+' | head -n1 || true)"
  fi
  for repo in "$root"/*/; do
    [[ -d "${repo}.git" ]] || continue           # only real git clones
    name="$(basename "$repo")"
    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      rows+="- ${name}: ${url}"$'\n'; any=1
    done < <(cd "$repo" && "$root/scripts/vcs/find-prs.sh" "$key" 2>/dev/null || true)
  done
  [[ "$any" -eq 1 ]] || return 0                  # nothing found -> empty stdout
  printf 'Please review, %s%s.\n' "$key" "${title:+ $title}"
  [[ -n "$endpoint" ]] && printf '%s\n' "$endpoint"
  printf '%s' "${rows%$'\n'}"
}

channel="${NOTIFY_CHANNEL:-}"; text=""; have_text=0; dry=0; review_key=""; review_title=""; reply_key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) channel="${2:-}";      shift 2 ;;
    --review)  review_key="${2:-}";   shift 2 ;;
    --reply)   reply_key="${2:-}";    shift 2 ;;
    --title)   review_title="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ "$have_text" -eq 0 ]]; then text="$1"; have_text=1; else die "unexpected argument: $1   (see -h)"; fi
      shift ;;
  esac
done

if [[ -n "$review_key" ]]; then
  [[ -n "$reply_key" ]] && die "--review and --reply are different modes — pick one"
  [[ "$have_text" -eq 0 ]] || die "--review <KEY> composes the message itself — don't also pass text"
  text="$(compose_review_digest "$review_key" "$review_title")"
  [[ -n "$text" ]] || die "no open PR/MR found for $review_key in any workspace repo — nothing to announce"
else
  # No text argument → read it from stdin (a redirected file or a pipe).
  if [[ "$have_text" -eq 0 && ! -t 0 ]]; then text="$(cat)"; fi
  [[ -n "$text" ]] || die "no message text — pass it as an argument, pipe it via stdin, or use --review <KEY>"
fi

if [[ -n "$reply_key" ]]; then
  # Thread the message under the review-request for this ticket. No request thread found ⇒
  # SKIP: print skipped=1 and post nothing (never a stray top-level message).
  ts="$(notify_find_thread "$channel" "$reply_key" || true)"
  if [[ -z "$ts" ]]; then
    printf 'skipped=1 reason=no-review-thread-for-%s\n' "$reply_key"; exit 0
  fi
  notify_send "$channel" "$text" "$dry" "$ts"
else
  notify_send "$channel" "$text" "$dry"
fi
