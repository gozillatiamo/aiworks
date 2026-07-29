#!/usr/bin/env bash
#
# Voice identity — the short phrase spoken BEFORE a sentence so you know which worktree is
# talking. Only played when the speaker changed or after a silence (see queue.sh).
#
# Usage:
#   identity.sh text            print the spoken identity for this checkout
#   identity.sh audio           print the path to the rendered prefix mp3 (synthesizing once)
#   identity.sh clear           forget the cached resolution (after a branch or title change)
#
# THE CHAIN (decision #21), first hit wins:
#   1. <root>/.aiworks/voice-identity   a one-line file, spoken verbatim. Hand-set, always
#                                       right, and .aiworks/ is git-ignored so it never
#                                       travels to a teammate.
#   2. ticket key + ticket title        the key comes from the branch name, the title from the
#                                       tracker adapter ONCE and then from cache. "OFB-1952
#                                       admin swap deposit" is what you actually think of the
#                                       worktree as.
#   3. branch slug                      always available, never wrong, just less memorable.
#
# The tracker call is the only network step, it is cached per (checkout, branch), and it is
# time-boxed — an unreachable Jira must degrade to the branch slug, never hang a hook.

set -euo pipefail
# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MAX_LEN=44        # longer than this stops being a prefix and becomes a sentence
TRACKER_TIMEOUT=15

_branch() { git -C "$VOICE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf ''; }

_cache_file() { printf '%s/%s.txt' "$VOICE_IDENT_DIR" "$(voice_sha "$VOICE_ROOT|$(_branch)")"; }

_ticket_key() {   # e.g. feat/OFB-1952-admin-swap → OFB-1952
  local prefix branch
  prefix="$(voice_cfg tracker.ticket_prefix "")"
  [[ -n "$prefix" ]] || return 0
  branch="$(_branch)"
  printf '%s' "$branch" | tr '[:lower:]' '[:upper:]' | grep -oE "$prefix-[0-9]+" | head -1 || true
}

_ticket_title() {   # KEY → the title, or nothing
  local key="$1" script="$VOICE_ROOT/scripts/tracker/get-ticket-details.sh" out
  [[ -x "$script" ]] || return 0
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$TRACKER_TIMEOUT" "$script" "$key" 2>/dev/null | head -1)" || return 0
  else
    out="$("$script" "$key" 2>/dev/null | head -1)" || return 0
  fi
  # First line is "<KEY> — <title>"; anything else means the adapter changed shape, so bail
  # rather than speak a URL or an error message.
  printf '%s' "$out" | sed -n 's/^[A-Z][A-Z0-9]*-[0-9]* — //p'
}

_truncate() {   # trim to MAX_LEN on a word boundary — a cut-off word reads as a glitch
  local s="$1"
  [[ "${#s}" -le "$MAX_LEN" ]] && { printf '%s' "$s"; return 0; }
  printf '%s' "${s:0:$MAX_LEN}" | sed -E 's/[^ ]*$//; s/ +$//'
}

_resolve() {
  local f="$VOICE_ROOT/.aiworks/voice-identity" key title branch
  if [[ -f "$f" ]]; then
    head -1 "$f" | sed -E 's/^ +//; s/ +$//'
    return 0
  fi
  key="$(_ticket_key)"
  if [[ -n "$key" ]]; then
    title="$(_ticket_title "$key")"
    if [[ -n "$title" ]]; then _truncate "$key $title"; else printf '%s' "$key"; fi
    return 0
  fi
  branch="$(_branch)"
  if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
    # "feat/slack-dispatch" → "branch slack dispatch": the separators are punctuation to a
    # TTS engine and it spells them out otherwise.
    _truncate "branch $(printf '%s' "${branch##*/}" | tr '_-' '  ')"
    return 0
  fi
  printf '%s' "$(basename "$VOICE_ROOT")"
}

cmd_text() {
  local cache; cache="$(_cache_file)"
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
  voice_mkdirs
  local t; t="$(_resolve)"
  [[ -n "$t" ]] || t="$(basename "$VOICE_ROOT")"
  printf '%s' "$t" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  printf '%s' "$t"
}

cmd_audio() {
  # Muted ⇒ no synthesis, like every other TTS call. Reached only via speak.sh, which already
  # stops earlier — this is here so the rule holds for a direct call too.
  if voice_is_muted; then vlog "prefix: muted — not synthesizing"; return 0; fi
  voice_mkdirs
  voice_load_credentials
  voice_load_tts_provider
  local text provider voice model out
  # The prefix is mostly a TICKET KEY, which is the single worst thing to hand a TTS engine
  # unrewritten: "OFB-1598" comes out as one four-figure number. voice_spoken_form splits it.
  text="$(voice_spoken_form "$(cmd_text)")"
  read -r provider voice model <<< "$(voice_tts_describe)"
  out="$VOICE_PREFIX_DIR/$(voice_cache_key "$text" "$provider" "$voice" "$model" "" "").mp3"
  if [[ -s "$out" ]]; then vlog "prefix cache hit: $text"; printf '%s' "$out"; return 0; fi
  vlog "prefix synth ($provider/$voice): $text"
  local tmp="$out.tmp.$$.mp3"   # keep the extension: ffmpeg picks its muxer from it (gemini)
  voice_tts_synth "$text" "$tmp"
  mv "$tmp" "$out"
  printf '%s' "$out"
}

cmd_clear() { rm -f "$(_cache_file)"; vlog "identity cache cleared for $(_branch)"; }

if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then VOICE_VERBOSE=1; shift; fi
case "${1:-text}" in
  text)  cmd_text; printf '\n' ;;
  audio) cmd_audio; printf '\n' ;;
  clear) cmd_clear ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d' ;;
  *) vdie "unknown command '$1' (see -h)" ;;
esac
