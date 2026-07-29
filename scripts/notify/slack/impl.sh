#!/usr/bin/env bash
# Slack implementation of the notify interface. Sourced by ../lib.sh.
#
# Two auth modes, in priority order (whichever env var is set in scripts/notify/.env):
#   SLACK_BOT_TOKEN   → chat.postMessage (https://slack.com/api/chat.postMessage). Honours the
#                       target channel (#name or id) and returns a permalink. Needs the
#                       `chat:write` scope (and the bot invited to the channel).
#   SLACK_WEBHOOK_URL → an Incoming Webhook. Posts text only; the channel is fixed by the
#                       webhook config, so an explicit channel is ignored (with a note).

notify_require_config() {
  [[ -n "${SLACK_BOT_TOKEN:-}" || -n "${SLACK_WEBHOOK_URL:-}" ]] || \
    die "slack notify needs SLACK_BOT_TOKEN or SLACK_WEBHOOK_URL in scripts/notify/.env"
}

# notify_send CHANNEL TEXT [DRY] [THREAD_TS] -> prints "ok=1" + "permalink=<url>" on success,
# else dies. A non-empty THREAD_TS posts the message as a reply UNDER that thread (the review
# conclusion lands beneath the review-request), never broadcast to the channel.
notify_send() {
  local channel="$1" text="$2" dry="${3:-0}" thread_ts="${4:-}"

  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    [[ -n "$channel" ]] || die "slack chat.postMessage needs a channel — pass --channel or set NOTIFY_CHANNEL"
    if [[ "$dry" -eq 1 ]]; then
      printf 'DRY RUN — POST chat.postMessage channel=%s%s\n%s\n' "$channel" "${thread_ts:+ thread_ts=$thread_ts}" "$text"; return 0
    fi
    local payload resp
    payload="$(jq -n --arg c "$channel" --arg t "$text" --arg tt "$thread_ts" \
      '{channel:$c, text:$t, unfurl_links:false} + (if $tt != "" then {thread_ts:$tt} else {} end)')"
    resp="$(curl -sS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      -H 'Content-Type: application/json; charset=utf-8' \
      --data "$payload")" || die "slack request failed (network)"
    # not_in_channel → try to self-join (public channels; needs channels:join + channels:read
    # scopes) and retry once. Private channels still need a manual /invite of the bot.
    if [[ "$(printf '%s' "$resp" | jq -r '.error // empty')" == "not_in_channel" ]]; then
      local cid="$channel"
      if [[ "$channel" == \#* ]]; then
        cid="$(curl -sS "https://slack.com/api/conversations.list?limit=1000&types=public_channel" \
          -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null \
          | jq -r --arg n "${channel#\#}" '.channels[]? | select(.name==$n) | .id' | head -n1 || true)"
      fi
      if [[ -n "$cid" ]]; then
        curl -sS -X POST "https://slack.com/api/conversations.join" \
          -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
          -H 'Content-Type: application/json; charset=utf-8' \
          --data "$(jq -n --arg c "$cid" '{channel:$c}')" >/dev/null 2>&1 || true
        resp="$(curl -sS -X POST https://slack.com/api/chat.postMessage \
          -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
          -H 'Content-Type: application/json; charset=utf-8' \
          --data "$payload")" || die "slack request failed (network)"
      fi
    fi
    if [[ "$(printf '%s' "$resp" | jq -r '.ok')" != true ]]; then
      local err; err="$(printf '%s' "$resp" | jq -r '.error // "unknown"')"
      [[ "$err" == "not_in_channel" ]] && \
        die "slack rejected the message: not_in_channel — the bot isn't in $channel; invite it (/invite @<bot>) or grant the channels:join + channels:read scopes"
      die "slack rejected the message: $err"
    fi
    # Best-effort permalink (non-fatal if the scope/lookup isn't available).
    local ch ts link
    ch="$(printf '%s' "$resp" | jq -r '.channel // empty')"
    ts="$(printf '%s' "$resp" | jq -r '.ts // empty')"
    link=""
    if [[ -n "$ch" && -n "$ts" ]]; then
      link="$(curl -sS "https://slack.com/api/chat.getPermalink?channel=${ch}&message_ts=${ts}" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null | jq -r '.permalink // empty' || true)"
    fi
    printf 'ok=1\npermalink=%s\n' "$link"
    return 0
  fi

  # Incoming Webhook — channel is bound to the webhook, so an explicit one can't be honoured.
  [[ -z "$channel" ]] || echo "note: SLACK_WEBHOOK_URL ignores the channel ('$channel') — it posts to the webhook's bound channel" >&2
  # A webhook can post text but CANNOT upload a file (no files.* access), so file mode
  # must never reach here — notify_send_file dies early when no bot token is present.
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — POST webhook\n%s\n' "$text"; return 0
  fi
  local payload resp
  payload="$(jq -n --arg t "$text" '{text:$t}')"
  resp="$(curl -sS -X POST -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL")" \
    || die "slack webhook request failed (network)"
  [[ "$resp" == ok ]] || die "slack webhook rejected the message: ${resp:-<empty>}"
  printf 'ok=1\npermalink=\n'
}

# notify_parse_permalink URL -> prints "<channel_id> <ts>" for a Slack message permalink
# (https://<team>.slack.com/archives/<C…>/p1785155192563299 -> "C… 1785155192.563299"), else
# nothing. The `p…` form is the ts with the dot removed, always 6 digits after it.
notify_parse_permalink() {
  local url="$1" ch ts
  ch="$(printf '%s' "$url" | sed -n 's#.*/archives/\([A-Z0-9]\{1,\}\)/p\([0-9]\{7,\}\).*#\1#p')"
  ts="$(printf '%s' "$url" | sed -n 's#.*/archives/[A-Z0-9]\{1,\}/p\([0-9]\{7,\}\).*#\1#p')"
  [[ -n "$ch" && -n "$ts" ]] || return 0
  printf '%s %s.%s\n' "$ch" "${ts%??????}" "${ts: -6}"
}

# notify_delete CHANNEL TS [DRY] -> delete a message this bot posted (chat.delete). Prints
# "ok=1 deleted=<ts>". Bot-token only: a webhook has no way to delete what it sent.
#
# This exists for the retraction case — a notification that went out to the wrong audience, or
# that shouldn't have gone out at all. It cannot delete anyone else's message (Slack rejects it),
# so the blast radius is exactly what this bot posted.
notify_delete() {
  local channel="$1" ts="$2" dry="${3:-0}"
  [[ -n "${SLACK_BOT_TOKEN:-}" ]] || \
    die "deleting needs SLACK_BOT_TOKEN (a webhook can't delete what it posted)"
  [[ -n "$channel" ]] || die "slack chat.delete needs a channel — pass --channel or a permalink"
  [[ -n "$ts" ]] || die "slack chat.delete needs a message ts"
  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — POST chat.delete channel=%s ts=%s\n' "$channel" "$ts"; return 0
  fi
  local resp
  resp="$(curl -sS -X POST https://slack.com/api/chat.delete \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$(jq -n --arg c "$channel" --arg t "$ts" '{channel:$c, ts:$t}')")" \
    || die "slack request failed (network)"
  if [[ "$(printf '%s' "$resp" | jq -r '.ok')" != true ]]; then
    local err; err="$(printf '%s' "$resp" | jq -r '.error // "unknown"')"
    case "$err" in
      message_not_found) die "slack: message_not_found — wrong channel/ts, or it is already gone" ;;
      cant_delete_message) die "slack: cant_delete_message — this token did not post that message" ;;
      *) die "slack rejected the delete: $err" ;;
    esac
  fi
  printf 'ok=1\ndeleted=%s\n' "$ts"
}

# notify_send_file CHANNEL FILE [COMMENT] [DRY] [THREAD_TS] [TITLE] -> upload FILE into
# CHANNEL with an optional initial COMMENT, threaded under THREAD_TS. Prints "ok=1" +
# "permalink=<url>" on success, else dies. Uses Slack's external-upload flow (the current
# API; files.upload is retired): reserve a URL, PUT the bytes, then complete — attaching to
# the channel/thread in one message. Needs a BOT TOKEN + the files:write scope; a webhook
# can't upload (dies early). The outbound safety gate (size / PII / secrets) lives in
# send.sh, upstream of this primitive.
notify_send_file() {
  local channel="$1" file="$2" comment="${3:-}" dry="${4:-0}" thread_ts="${5:-}" title="${6:-}"

  [[ -n "${SLACK_BOT_TOKEN:-}" ]] || \
    die "slack file upload needs SLACK_BOT_TOKEN (a webhook can't upload files) — set it in scripts/notify/.env"
  [[ -n "$channel" ]] || die "slack file upload needs a channel — pass --channel or set NOTIFY_CHANNEL"
  [[ -f "$file" ]] || die "file not found: $file"

  local fname length
  fname="$(basename "$file")"
  [[ -n "$title" ]] || title="$fname"
  length="$(wc -c < "$file" | tr -d ' ')"   # portable byte size

  if [[ "$dry" -eq 1 ]]; then
    printf 'DRY RUN — files.completeUploadExternal channel=%s file=%s (%s bytes)%s title=%s\ninitial_comment=%s\n' \
      "$channel" "$fname" "$length" "${thread_ts:+ thread_ts=$thread_ts}" "$title" "$comment"
    return 0
  fi

  local cid; cid="$(_slack_channel_id "$channel")"
  [[ -n "$cid" ]] || die "could not resolve channel to an id: $channel"

  # 1. reserve an upload URL + file id
  local up upload_url file_id
  up="$(curl -sS -X POST https://slack.com/api/files.getUploadURLExternal \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    --data-urlencode "filename=$fname" \
    --data-urlencode "length=$length")" || die "slack getUploadURLExternal failed (network)"
  if [[ "$(printf '%s' "$up" | jq -r '.ok')" != true ]]; then
    local uerr; uerr="$(printf '%s' "$up" | jq -r '.error // "unknown"')"
    [[ "$uerr" == "missing_scope" || "$uerr" == "not_allowed_token_type" ]] && \
      die "slack rejected the upload: $uerr — the bot needs the files:write scope; add it to slack-app-manifest.yaml and reinstall the app"
    die "slack getUploadURLExternal rejected: $uerr"
  fi
  upload_url="$(printf '%s' "$up" | jq -r '.upload_url')"
  file_id="$(printf '%s' "$up" | jq -r '.file_id')"
  [[ -n "$upload_url" && -n "$file_id" ]] || die "slack getUploadURLExternal returned no upload_url/file_id"

  # 2. POST the raw bytes to the returned URL
  curl -sS -f -F "file=@${file}" "$upload_url" >/dev/null || die "slack file byte upload failed (PUT to upload_url)"

  # 3. complete — attach to the channel/thread, carrying the caption as initial_comment
  local files_arg payload complete
  files_arg="$(jq -n --arg id "$file_id" --arg t "$title" '[{id:$id, title:$t}]')"
  payload="$(jq -n --arg c "$cid" --argjson f "$files_arg" --arg tt "$thread_ts" --arg ic "$comment" \
    '{channel_id:$c, files:$f}
     + (if $tt != "" then {thread_ts:$tt} else {} end)
     + (if $ic != "" then {initial_comment:$ic} else {} end)')"
  complete="$(curl -sS -X POST https://slack.com/api/files.completeUploadExternal \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$payload")" || die "slack completeUploadExternal failed (network)"
  if [[ "$(printf '%s' "$complete" | jq -r '.ok')" != true ]]; then
    local err; err="$(printf '%s' "$complete" | jq -r '.error // "unknown"')"
    [[ "$err" == "missing_scope" || "$err" == "not_allowed_token_type" ]] && \
      die "slack rejected the upload: $err — the bot needs the files:write scope; add it to slack-app-manifest.yaml and reinstall the app"
    [[ "$err" == "not_in_channel" ]] && \
      die "slack rejected the upload: not_in_channel — the bot isn't in $channel; invite it (/invite @<bot>) or grant channels:join + channels:read"
    die "slack rejected the upload: $err"
  fi
  local link; link="$(printf '%s' "$complete" | jq -r '.files[0].permalink // empty')"
  printf 'ok=1\npermalink=%s\n' "$link"
}

# Resolve a channel #name (or pass an id through) to a channel id. Empty on failure.
# Tries public_channel alone first — cheapest, and covers every channel this org actually
# uses. Falls back to public_channel,private_channel only if that misses: a bot token
# without groups:read gets missing_scope on the combined call, and even when the scope IS
# present, combining types roughly doubles the channel count under the same limit=1000
# page, which can push the target channel past the first page. Public-only avoids both
# failure modes for a channel we already know is public; the combined call remains the
# fallback for genuinely private channels.
_slack_channel_id() {
  local ch="$1" resp id
  case "$ch" in
    \#*)
      resp="$(curl -sS "https://slack.com/api/conversations.list?limit=1000&types=public_channel" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null || true)"
      id="$(printf '%s' "$resp" | jq -r --arg n "${ch#\#}" '.channels[]? | select(.name==$n) | .id' 2>/dev/null | head -n1)"
      if [[ -z "$id" ]]; then
        resp="$(curl -sS "https://slack.com/api/conversations.list?limit=1000&types=public_channel,private_channel" \
          -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null || true)"
        id="$(printf '%s' "$resp" | jq -r --arg n "${ch#\#}" '.channels[]? | select(.name==$n) | .id' 2>/dev/null | head -n1)"
      fi
      printf '%s' "$id" ;;
    U*|W*)
      # A USER id, not a channel. chat.postMessage accepts one and opens the IM for you, but
      # the file-upload API does NOT — files.completeUploadExternal answers `invalid_arguments`
      # for a U… channel_id, which is how a DM'd file upload fails. conversations.open resolves
      # it to the IM's own D… id; opening an existing IM is idempotent and notifies nobody.
      #
      # ⚠ NEEDS THE `im:write` BOT SCOPE, which this workspace's app does NOT currently have
      #   (measured 2026-07-28: conversations.open → missing_scope, needed
      #   "channels:write,groups:write,mpim:write,im:write"). Until an admin adds im:write in
      #   the Slack app's OAuth & Permissions and reinstalls, this falls back to the id as
      #   given and a file upload to a DM still fails with invalid_arguments. The fallback is
      #   also what keeps a genuine channel whose id starts with U/W from being mangled.
      resp="$(curl -sS -X POST https://slack.com/api/conversations.open \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data "$(jq -nc --arg u "$ch" '{users: $u}')" 2>/dev/null || true)"
      id="$(printf '%s' "$resp" | jq -r '.channel.id // empty' 2>/dev/null || true)"
      printf '%s' "${id:-$ch}" ;;
    *)   printf '%s' "$ch" ;;
  esac
}

# notify_find_thread CHANNEL KEY -> print the ts of the NEWEST channel message whose text
# contains KEY — the review-request a reviewer replies under. Best-effort by design: bot
# tokens can't search.messages, so we scan conversations.history (needs channels:history /
# groups:history + channels:read). ANY miss — webhook mode, no scope, no match — prints
# nothing, and the caller SKIPS (never falls back to a top-level post). conversations.history
# returns top-level messages newest-first, so the first match is the latest request; the
# reviewer's own in-thread replies are not top-level, so they never shadow the request.
notify_find_thread() {
  local channel="$1" key="$2" cid
  [[ -n "${SLACK_BOT_TOKEN:-}" ]] || return 0
  cid="$(_slack_channel_id "$channel")"
  [[ -n "$cid" ]] || return 0
  curl -sS "https://slack.com/api/conversations.history?channel=${cid}&limit=200" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null \
    | jq -r --arg k "$key" 'if .ok then (.messages[]? | select((.text // "") | test($k; "i")) | .ts) else empty end' 2>/dev/null \
    | head -n1
}
