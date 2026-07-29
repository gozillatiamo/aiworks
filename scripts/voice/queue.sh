#!/usr/bin/env bash
#
# Voice queue — one spool and one playback lock for the whole MACHINE, so several worktrees
# speaking at once take turns instead of talking over each other.
#
# Usage:
#   queue.sh enqueue --kind ack|narration|milestone|manual --audio FILE [--prefix FILE]
#                    [--session ID] [--text TEXT]
#   queue.sh drain [--background]      play everything queued; a no-op if someone else is playing
#   queue.sh status                    what is queued, who spoke last, muted?
#   queue.sh purge                     drop every queued job (does not touch the audio cache)
#   queue.sh mute on|off|status        silence everything, machine-wide. The user-facing name
#                                      for this is `aiworks voice mute on|off`
#
# WHY THERE IS NO DAEMON
#   enqueue, then try the lock. Got it ⇒ drain the WHOLE spool, including jobs other sessions
#   just added. Didn't ⇒ exit immediately, because whoever holds the lock will reach our job
#   before it finishes. No background process to supervise, no straggler to reap, and nothing
#   is left unplayed. `flock(1)` does not exist on macOS, so the lock is fcntl via python3
#   (measured) — see _with_lock.
#
# DROP RULES (drain time, not enqueue time — staleness is only knowable when it is our turn)
#   muted             EVERY kind is dropped. `aiworks voice mute on|off`
#   milestone/manual  otherwise never dropped, and always first in line
#   ack               dropped when older than 30 s · only the NEWEST per session survives ·
#                     dropped inside 20 s of the last utterance (silence discipline)
#   narration         the `max` step narrator. Dropped HARDER than an ack on both axes — 12 s
#                     stale, 7 s gap — and last in line. It is the only kind whose content goes
#                     off after seconds rather than minutes: "กำลังอ่าน X" arriving once X is done
#                     and two steps have passed describes the wrong moment, and a queue of them
#                     played back-to-back is a monologue about the past. The tighter GAP is not a
#                     contradiction of the ack's 20 s: an ack answers a prompt and there is one
#                     per turn, while narration is the running commentary and 20 s of silence
#                     between steps would drop most of it.
#
# IDENTITY PREFIX
#   Never for the FOCUSED session — the worktree you are currently prompting in attaches no
#   prefix at all (speak.sh drops it before synthesis; see voice_is_focused in lib.sh). You know
#   where you are, and an identity in front of every sentence there is noise.
#   For anything else — a background dev-cycle, a slack-dispatch job, the other window — played
#   when that session is not the one that spoke last, or after 60 s of silence.

set -euo pipefail
# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

voice_require jq afplay
voice_mkdirs

ACK_MAX_AGE=30      # an ack older than this is stale — the answer has moved on
SILENCE_GAP=20      # no two utterances closer than this, for acks
NARRATION_MAX_AGE=12  # a step narration older than this is about a step that already finished
NARRATION_GAP=7     # …and the running commentary needs a shorter floor than an ack's 20 s
PREFIX_GAP=60       # silence long enough that "which worktree?" is a real question again

# The session identity a job belongs to. Claude Code exports no stable session id to a hook's
# child, so the WORKTREE is the identity — which is what the user actually distinguishes by,
# and what identity.sh speaks.
voice_session_id() { printf '%s' "${VOICE_SESSION:-$VOICE_ROOT}"; }

# ── enqueue ───────────────────────────────────────────────────────────────────────
cmd_enqueue() {
  local kind=manual audio="" prefix="" session="" text=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)    kind="${2:?}"; shift 2 ;;
      --audio)   audio="${2:?}"; shift 2 ;;
      --prefix)  prefix="${2:?}"; shift 2 ;;
      --session) session="${2:?}"; shift 2 ;;
      --text)    text="${2:-}"; shift 2 ;;
      *) vdie "enqueue: unknown option $1" ;;
    esac
  done
  [[ -n "$audio" ]] || vdie "enqueue: --audio is required"
  [[ -f "$audio" ]] || vdie "enqueue: no such audio file: $audio"
  case "$kind" in ack|narration|milestone|manual) ;; *) vdie "enqueue: --kind must be ack|narration|milestone|manual" ;; esac
  [[ -n "$session" ]] || session="$(voice_session_id)"

  local now job
  now="$(voice_now)"
  job="$VOICE_SPOOL_DIR/$now-$$-$kind.json"
  jq -n --arg k "$kind" --arg s "$session" --arg a "$audio" --arg p "$prefix" \
        --arg t "$text" --argjson ts "$now" \
        '{ts: $ts, kind: $k, session: $s, audio: $a, prefix: $p, text: $t}' > "$job.tmp"
  mv "$job.tmp" "$job"     # atomic: a drain must never read a half-written job
  vlog "queued $kind ($(basename "$job"))"
}

# ── drain ─────────────────────────────────────────────────────────────────────────
# Acquire the lock and hand off to _drain_locked with the fd still open, so the lock is held
# for the entire playback rather than for the length of a shell builtin. os.set_inheritable
# is load-bearing: Python 3 marks its own descriptors non-inheritable, and without it the
# lock would evaporate across the exec.
_with_lock() {
  local rc=0
  python3 - "$VOICE_LOCK" "${BASH_SOURCE[0]}" <<'PY' || rc=$?
import fcntl, os, sys
lock, script = sys.argv[1], sys.argv[2]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(3)
os.set_inheritable(fd, True)
os.execv("/bin/bash", ["bash", script, "_drain_locked"])
PY
  if [[ "$rc" -eq 3 ]]; then
    vlog "another session is playing — it will drain our job too"
    return 0
  fi
  return "$rc"
}

cmd_drain() {
  if [[ "${1:-}" == "--background" ]]; then
    # Detached on purpose: this is called from hooks, and a hook that waits for audio to
    # finish delays the user's turn by the length of the sentence. (No setsid on macOS.)
    ( VOICE_VERBOSE="$VOICE_VERBOSE" nohup "${BASH_SOURCE[0]}" drain >/dev/null 2>&1 & )
    return 0
  fi
  _with_lock
}

_last_spoken_field() {   # session | ts
  [[ -f "$VOICE_LAST_SPOKEN" ]] || { printf ''; return 0; }
  jq -r --arg f "$1" '.[$f] // "" | tostring' "$VOICE_LAST_SPOKEN" 2>/dev/null || printf ''
}

# The droppable kinds share one rule — newest-per-session survives, anything older than the kind's
# own budget goes — so they share one implementation. Parameterized rather than copied: an ack and a
# narration differ only in how fast their content goes off, and two near-identical loops would drift.
_prune_droppable() {   # KIND MAX_AGE
  local kind="$1" max_age="$2" now seen="" j sess ts
  now="$(voice_now)"
  # Reverse name order = newest first (the name starts with the epoch), so the first job seen
  # for a session is the one to keep.
  for j in $(ls -1r "$VOICE_SPOOL_DIR"/*-"$kind".json 2>/dev/null || true); do
    [[ -f "$j" ]] || continue
    sess="$(jq -r '.session // ""' "$j" 2>/dev/null || printf '')"
    ts="$(jq -r '.ts // 0' "$j" 2>/dev/null || printf 0)"
    case " $seen " in
      *" $sess "*) vlog "drop $kind: superseded ($(basename "$j"))"; rm -f "$j"; continue ;;
    esac
    seen="$seen $sess"
    if (( now - ts > max_age )); then
      vlog "drop $kind: ${max_age}s stale ($(basename "$j"))"
      rm -f "$j"
    fi
  done
}

# Jobs to play, in priority then chronological order. Narration is LAST: a result outranks a
# description of the work that produced it, and by the time a milestone is queued the steps it
# summarizes are over.
_ordered_jobs() {
  ls -1 "$VOICE_SPOOL_DIR"/*-milestone.json "$VOICE_SPOOL_DIR"/*-manual.json 2>/dev/null || true
  ls -1 "$VOICE_SPOOL_DIR"/*-ack.json 2>/dev/null || true
  ls -1 "$VOICE_SPOOL_DIR"/*-narration.json 2>/dev/null || true
}

_play() {   # FILE — afplay is synchronous, which is exactly what serialising needs
  [[ -f "$1" ]] || return 0
  afplay "$1" 2>/dev/null || vlog "afplay failed on $1"
}

cmd_drain_locked() {
  local pass=0
  while :; do
    _prune_droppable ack "$ACK_MAX_AGE"
    _prune_droppable narration "$NARRATION_MAX_AGE"
    local jobs; jobs="$(_ordered_jobs)"
    [[ -n "$jobs" ]] || break
    pass=$((pass + 1))
    (( pass > 200 )) && { vlog "drain: 200 passes, bailing out (something is re-queueing in a loop)"; break; }

    local j
    while IFS= read -r j; do
      [[ -f "$j" ]] || continue
      local kind sess audio prefix now last_sess last_ts gap
      kind="$(jq -r '.kind // "manual"' "$j")"
      sess="$(jq -r '.session // ""' "$j")"
      audio="$(jq -r '.audio // ""' "$j")"
      prefix="$(jq -r '.prefix // ""' "$j")"
      rm -f "$j"                       # claimed: never play the same job twice

      if [[ ! -f "$audio" ]]; then
        vlog "skip $kind: audio gone ($audio) — cache pruned under us"
        continue
      fi

      now="$(voice_now)"
      last_sess="$(_last_spoken_field session)"
      last_ts="$(_last_spoken_field ts)"
      [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
      gap=$((now - last_ts))

      # The LAST line of defence, and normally unreachable: mute stops every producer before it
      # spends anything (speak.sh exits before synthesis). What reaches here is a job that was
      # already queued when the mute went on — dropped, not deferred, because unmuting must not
      # fire a backlog of everything you chose not to hear.
      if voice_is_muted; then
        vlog "drop $kind: muted"
        continue
      fi

      if [[ "$kind" == "ack" ]]; then
        if (( last_ts > 0 && gap < SILENCE_GAP )); then
          vlog "drop ack: only ${gap}s since the last utterance (silence discipline)"
          continue
        fi
      elif [[ "$kind" == "narration" ]]; then
        # Its own floor: the running commentary is supposed to run, so it needs air between lines
        # rather than an ack's near-silence. narrate.sh already applies a floor of its own before
        # spending anything on synthesis; this one also counts utterances from OTHER kinds and
        # other worktrees, which the producer cannot see.
        if (( last_ts > 0 && gap < NARRATION_GAP )); then
          vlog "drop narration: only ${gap}s since the last utterance"
          continue
        fi
      fi

      if [[ -n "$prefix" && -f "$prefix" ]] \
         && { [[ "$sess" != "$last_sess" ]] || (( last_ts == 0 || gap > PREFIX_GAP )); }; then
        vlog "prefix: $(basename "$prefix")"
        _play "$prefix"
      fi
      vlog "play $kind [$sess]: $(basename "$audio")"
      _play "$audio"

      jq -n --arg s "$sess" --argjson ts "$(voice_now)" '{session: $s, ts: $ts}' \
        > "$VOICE_LAST_SPOKEN.tmp" && mv "$VOICE_LAST_SPOKEN.tmp" "$VOICE_LAST_SPOKEN"
    done <<< "$jobs"
  done
  # With the lock still held and nothing waiting to be said — the one safe moment to evict.
  voice_cache_prune
}

# ── status / purge ────────────────────────────────────────────────────────────────
cmd_status() {
  # `|| true` is not decoration: with an empty spool `ls` exits 1, and under `pipefail` that
  # failed the assignment and `set -e` killed the whole command — status printed NOTHING,
  # which is the one situation you most want it to report.
  local n; n="$( (ls -1 "$VOICE_SPOOL_DIR"/*.json 2>/dev/null || true) | wc -l | tr -d ' ')"
  printf 'spool      %s job(s) in %s\n' "$n" "$VOICE_SPOOL_DIR"
  local j
  for j in $(ls -1 "$VOICE_SPOOL_DIR"/*.json 2>/dev/null || true); do
    printf '  %-28s %s\n' "$(basename "$j")" "$(jq -r '.text // ""' "$j" | cut -c1-60)"
  done
  printf 'last spoke %s at %s\n' "$(_last_spoken_field session)" "$(_last_spoken_field ts)"
  if [[ -f "$VOICE_MUTE_FILE" ]]; then printf 'mute       ON (queue.sh mute off to unmute)\n'
  else printf 'mute       off\n'; fi
  if python3 - "$VOICE_LOCK" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(3)
PY
  then printf 'lock       free\n'; else printf 'lock       HELD (someone is playing)\n'; fi
}

cmd_purge() { rm -f "$VOICE_SPOOL_DIR"/*.json 2>/dev/null || true; vlog "spool purged"; }

# See the rationale on voice_is_muted in lib.sh (a file, machine-global, silences every kind).
cmd_mute() {
  voice_mkdirs
  case "${1:-status}" in
    on)     : > "$VOICE_MUTE_FILE"
            printf 'voice muted — nothing spoken, summarized or synthesized on this machine\n'
            printf '  (Slack voice notes and dictation are unaffected — neither is this machine talking)\n' ;;
    off)    rm -f "$VOICE_MUTE_FILE"; printf 'voice unmuted\n' ;;
    status) [[ -f "$VOICE_MUTE_FILE" ]] && printf 'muted\n' || printf 'not muted\n' ;;
    *)      vdie "mute: use on|off|status" ;;
  esac
}

# ── dispatch ──────────────────────────────────────────────────────────────────────
# -v anywhere before the command turns the reasoning on (to stderr).
if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then VOICE_VERBOSE=1; shift; fi

case "${1:-}" in
  enqueue)       shift; cmd_enqueue "$@" ;;
  drain)         shift; cmd_drain "$@" ;;
  _drain_locked) cmd_drain_locked ;;
  status)        cmd_status ;;
  purge)         cmd_purge ;;
  mute)          shift; cmd_mute "$@" ;;
  -h|--help|"")  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d' ;;
  *)             vdie "unknown command '$1' (see -h)" ;;
esac
