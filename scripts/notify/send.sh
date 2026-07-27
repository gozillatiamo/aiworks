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
       send.sh --channel <ch> --thread-ts <ts> [text] [--dry-run]
       send.sh --channel <ch> [--thread-ts <ts>] --file <path> [text] [--title <t>] [--dry-run]
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
  --thread-ts <ts> Reply UNDER an explicit thread (the parent message ts). Unlike --reply
                  (which searches for a review-request by ticket key), this threads under a
                  ts you already hold — e.g. the Slack mention a bot is answering. Needs a
                  bot token (webhooks can't thread) and an explicit --channel. Cannot be
                  combined with --review/--reply.
  --file <path>   Upload <path> as a FILE (Slack file upload) instead of a text message; the
                  [text] argument becomes its caption (initial_comment) and the whole reply is
                  ONE message. Needs a bot token + the files:write scope (a webhook can't
                  upload). Combine with --thread-ts to attach into a thread. Cannot be combined
                  with --review/--reply. REFUSED (exit non-zero) when the file exceeds
                  OUTBOUND_MAX_FILE_MB (default 15) or carries a secret/token. PRODUCTION
                  personal values are REDACTED instead (a text file uploads as a redacted
                  copy; a binary one is refused) — local/staging data is never touched.
                  See docs/agents/pii-provenance.md.
  --title <text>  Header title for --review, OR the file title for --file (default: the ticket
                  title / the file's basename).
  --channel <ch>  Target channel (id or #name). Default: $NOTIFY_CHANNEL from .env.
                  Ignored by providers whose destination is fixed (e.g. a Slack webhook).
  --dry-run       Print what would be sent instead of sending it.
  -h, --help      Show this help and exit.

Environment (scripts/notify/.env):
  NOTIFY_PROVIDER   slack (default).
  NOTIFY_CHANNEL    default channel when --channel is omitted.
  SLACK_BOT_TOKEN   bot token for chat.postMessage (honours the channel + returns a permalink), OR
  SLACK_WEBHOOK_URL incoming webhook URL (channel fixed by the webhook).
  OUTBOUND_MAX_FILE_MB  max size (MB) a --file upload may be before it is refused (default 15).
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

# redact_prod_pii TEXT → prints TEXT with every PRODUCTION-derived personal value replaced by
# a <prod-pii:…> placeholder. Provenance decides, not shape: a value is redacted only if a
# sanctioned prod-read path (prod-pg-triage MCP, `--env prod` observability, the repro seed)
# actually saw it and vaulted its keyed hash — so local/staging test data posted to Slack is
# left exactly as written. Masks rather than refuses; the redaction is reported on stderr
# (category + count, never the value). PII_GATE=off disables; =on also masks unvaulted shapes.
# See docs/agents/pii-provenance.md.
redact_prod_pii() {
  local text="$1" engine="$DIR/../lib/pii_provenance.py" masked rc=0
  [[ -n "$text" ]] || { printf '%s' "$text"; return 0; }
  [[ "${PII_GATE:-auto}" == "off" ]] && { printf '%s' "$text"; return 0; }
  { [[ -f "$engine" ]] && command -v python3 >/dev/null; } || { printf '%s' "$text"; return 0; }

  masked="$(printf '%s' "$text" | python3 "$engine" mask -)" || rc=$?
  case "$rc" in
    10) echo "note: production PII was redacted from this message before posting." >&2
        printf '%s' "$masked" ;;
    0)  printf '%s' "$masked" ;;
    *)  printf '%s' "$text" ;;   # engine error → never block a legitimate post
  esac
}

# _is_binary_file FILE → 0 when the file must NOT be rewritten as text. Two independent
# signals, because a wrong "it's text" verdict corrupts the upload: a known-binary extension
# (a small png/pdf can be almost entirely printable bytes, so content sniffing alone says
# "text"), or a NUL byte in the first 8 KiB.
_is_binary_file() {
  local f="$1" ext
  ext="$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    png|jpg|jpeg|gif|webp|bmp|ico|tiff|pdf|zip|gz|tgz|bz2|xz|7z|rar|mp4|mov|avi|mkv|mp3|wav|\
    ogg|woff|woff2|ttf|otf|eot|xls|xlsx|doc|docx|ppt|pptx|bin|so|dylib|dll|exe|class|jar|pyc|\
    db|sqlite|sqlite3) return 0 ;;
  esac
  local raw stripped
  raw="$(head -c 8192 "$f" | wc -c | tr -d ' ')"
  stripped="$(head -c 8192 "$f" | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')"
  [[ "$raw" != "$stripped" ]]
}

# outbound_gate FILE — the safety backstop before a --file upload leaves the org. Prints the
# path to actually upload (the original, or a redacted temp copy) and dies on a refusal:
#   1. size     — > OUTBOUND_MAX_FILE_MB (default 15). Dies.
#   2. prod PII — production-derived personal values, via the provenance engine
#                 scripts/lib/pii_provenance.py (the single policy). A TEXT file is uploaded
#                 as a redacted copy; a BINARY one (pdf/png/…) can't be rewritten safely, so
#                 that case still dies. Local/staging data is never touched.
#   3. secrets  — token/key shapes the PII list doesn't carry (AWS key, Slack/app token,
#                 PEM private key, or a KEY=<long-value> credential assignment). Dies —
#                 a credential is never "redact and carry on", regardless of environment.
# A model-authored deliverable should never contain these; this makes "never upload secrets"
# a deterministic wall, not just a prompt instruction.
outbound_gate() {
  local file="$1"
  [[ -f "$file" ]] || die "file not found: $file"

  local max_mb="${OUTBOUND_MAX_FILE_MB:-15}" bytes
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes > max_mb * 1024 * 1024 )); then
    die "refusing to upload $(basename "$file"): $(( bytes / 1024 / 1024 ))MB exceeds the ${max_mb}MB cap (raise OUTBOUND_MAX_FILE_MB to change)"
  fi

  if LC_ALL=C grep -nEiq \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{8,}' \
      -e 'xapp-[0-9]+-[A-Za-z0-9-]{8,}' \
      -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
      -e '(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CLIENT_?SECRET|BEARER)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_=.-]{12,}' \
      "$file"; then
    die "refusing to upload $(basename "$file"): a secret/token/key pattern was found. Never put credentials in a shared file."
  fi

  local engine="$DIR/../lib/pii_provenance.py"
  if [[ "${PII_GATE:-auto}" == "off" || ! -f "$engine" ]] || ! command -v python3 >/dev/null; then
    printf '%s' "$file"; return 0
  fi

  # A binary container (pdf/png/…) can't be rewritten without corrupting it, so it is judged
  # on its extracted text and REFUSED on a hit — the one case that still dies rather than
  # redacts. pii-scan.sh knows how to pull the real text out of a pdf (its xref table is a run
  # of 10-digit offsets that trips the phone detector in every pdf ever produced).
  #
  # Getting this classification wrong in the text direction CORRUPTS the upload, so it is
  # deliberately conservative: a known-binary extension is binary even if the bytes happen to
  # look textual (a small png is mostly ASCII and passes a naive `grep -I` check).
  local scan="$DIR/../lib/pii-scan.sh" rc=0
  if _is_binary_file "$file"; then
    [[ -f "$scan" ]] || { printf '%s' "$file"; return 0; }
    # Streamed, never captured: a binary's NUL bytes make bash warn on every command
    # substitution, and the extracted text is only ever fed to the scanner anyway.
    # shellcheck disable=SC1090
    ( . "$scan"; pii_scannable_text "$file" ) | python3 "$engine" scan - >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 10 ]] && die "refusing to upload $(basename "$file"): it carries PRODUCTION personal data and a binary file can't be redacted in place. Re-export it without the personal values (player_code / an aggregate instead), or send a text version."
    printf '%s' "$file"; return 0
  fi

  local masked
  masked="$(python3 "$engine" mask "$file")" || rc=$?
  if [[ $rc -eq 10 ]]; then
    # Upload a redacted copy under the SAME basename, so Slack still shows the real filename.
    local tmpdir; tmpdir="$(mktemp -d)"
    printf '%s' "$masked" > "$tmpdir/$(basename "$file")"
    echo "note: production PII was redacted from $(basename "$file"); uploading the redacted copy." >&2
    printf '%s' "$tmpdir/$(basename "$file")"; return 0
  fi
  printf '%s' "$file"
}

channel="${NOTIFY_CHANNEL:-}"; text=""; have_text=0; dry=0; review_key=""; review_title=""; reply_key=""; thread_ts_arg=""; file_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)   channel="${2:-}";      shift 2 ;;
    --review)    review_key="${2:-}";   shift 2 ;;
    --reply)     reply_key="${2:-}";    shift 2 ;;
    --thread-ts) thread_ts_arg="${2:-}"; shift 2 ;;
    --file)      file_path="${2:-}";    shift 2 ;;
    --title)     review_title="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1   (see -h)" ;;
    *)
      if [[ "$have_text" -eq 0 ]]; then text="$1"; have_text=1; else die "unexpected argument: $1   (see -h)"; fi
      shift ;;
  esac
done

if [[ -n "$thread_ts_arg" && ( -n "$review_key" || -n "$reply_key" ) ]]; then
  die "--thread-ts can't combine with --review/--reply (those choose their own thread)"
fi

# File mode: upload a file instead of posting text. Handled before the text-resolution
# below because the caption is OPTIONAL here (a file may go with no message), so it must not
# trip the "no message text" die. The outbound gate runs before any byte leaves the machine.
if [[ -n "$file_path" ]]; then
  [[ -z "$review_key" && -z "$reply_key" ]] || die "--file can't combine with --review/--reply (those compose their own message)"
  [[ -f "$file_path" ]] || die "file not found: $file_path   (see -h)"
  # Optional caption: the positional text, or piped stdin; empty is fine.
  if [[ "$have_text" -eq 0 && ! -t 0 ]]; then text="$(cat)"; fi
  upload_path="$(outbound_gate "$file_path")"
  text="$(redact_prod_pii "$text")"
  notify_send_file "$channel" "$upload_path" "$text" "$dry" "$thread_ts_arg" "$review_title"
  exit 0
fi

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

# Redact any PRODUCTION-derived personal value before the message leaves the org. Local and
# staging data is untouched (provenance decides, not shape) — see redact_prod_pii above.
text="$(redact_prod_pii "$text")"

if [[ -n "$reply_key" ]]; then
  # Thread the message under the review-request for this ticket. No request thread found ⇒
  # SKIP: print skipped=1 and post nothing (never a stray top-level message).
  ts="$(notify_find_thread "$channel" "$reply_key" || true)"
  if [[ -z "$ts" ]]; then
    printf 'skipped=1 reason=no-review-thread-for-%s\n' "$reply_key"; exit 0
  fi
  notify_send "$channel" "$text" "$dry" "$ts"
else
  # thread_ts_arg is empty for a top-level post, or the parent ts to reply under.
  notify_send "$channel" "$text" "$dry" "$thread_ts_arg"
fi
