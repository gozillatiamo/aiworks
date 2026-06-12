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

# notify_send CHANNEL TEXT [DRY] -> prints "ok=1" + "permalink=<url>" on success, else dies.
notify_send() {
  local channel="$1" text="$2" dry="${3:-0}"

  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    [[ -n "$channel" ]] || die "slack chat.postMessage needs a channel — pass --channel or set NOTIFY_CHANNEL"
    if [[ "$dry" -eq 1 ]]; then
      printf 'DRY RUN — POST chat.postMessage channel=%s\n%s\n' "$channel" "$text"; return 0
    fi
    local payload resp
    payload="$(jq -n --arg c "$channel" --arg t "$text" '{channel:$c, text:$t, unfurl_links:false}')"
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
