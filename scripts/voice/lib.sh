#!/usr/bin/env bash
# Voice adapter — shared library for the voice scripts.
# Sourced by the entry scripts (speak.sh, queue.sh, identity.sh, …); not meant to run alone.
#
# WHAT LIVES HERE
#   voice_cfg PATH DEFAULT     read one dotted config path (voice.tts.provider) local-first
#   voice_language             the resolved workspace output language ('th' | 'en' | …)
#   voice_gate_or_exit KIND    the th + voice.enabled gate: exit 0 SILENTLY when it fails
#   voice_load_credentials     export the provider API keys (machine-global, .env override)
#   voice_load_tts_provider    source providers/<voice.tts.provider>.sh
#   voice_cache_key …          content-address a synthesis request
#   voice_normalize_text       whitespace-normalize the spoken text (part of the cache key)
#   voice_spoken_form TEXT     rewrite written text into what should be SAID (ids, MR/PR)
#   voice_chattiness           terse | balanced | chatty | max — how MUCH it says when it speaks
#   voice_narrate_get / _set   what the `max` step narrator last said, per session (dedupe + rate)
#   voice_focus_set / _is_focused   which worktree the user is currently prompting in
#   voice_is_muted             one machine-global file: muted ⇒ the feature spends NOTHING
#
# THE PROVIDER INTERFACE — each providers/<name>.sh defines:
#   voice_tts_synth TEXT OUT_MP3   synthesize TEXT to an mp3 at OUT_MP3 (rc!=0 on failure)
#   voice_tts_describe             print "<provider> <voice> <model>" for the cache key + logs
#
# CONFIG PRECEDENCE (see docs/adr/0003 for why .local exists at all)
#   1. <root>/workspace.config.local.yaml          personal, git-ignored
#   2. <main clone>/workspace.config.local.yaml    only when <root> is a LINKED WORKTREE
#   3. <root>/workspace.config.yaml                shared, committed
#
#   Layer 2 is not decoration. A Superset worktree is a `git worktree` of this repo, and a
#   git-ignored file does not travel into one — so a worktree sees the SHARED config only,
#   which deliberately ships voice.enabled: false. Without layer 2 the feature would be
#   silently dead in exactly the sessions that need the identity prefix most. The main clone
#   is found mechanically from `git rev-parse --git-common-dir`, never guessed.
#
# CREDENTIALS — machine-global first, per-repo .env overrides with NON-EMPTY values only:
#   1. ~/.config/aiworks/voice.env      mode 600, the real keys
#   2. scripts/voice/.env               per-clone override; EMPTY values are ignored
#   Same reason as above, one layer down: a worktree's adapter .env files are STUBS in this
#   workspace (a known trap — Jira/Slack creds are missing there), so a per-repo-only
#   credential path would break voice in every worktree. An empty stub must not clobber a
#   real machine-global key, hence "non-empty wins" rather than a plain source-in-order.
#
# Values are never echoed. Do not add a debug print of a key, and do not run these scripts
# under bash -x (see the .env rule in CLAUDE.md — xtrace prints sourced values verbatim).

set -euo pipefail

VOICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_ROOT="$(cd "$VOICE_DIR/../.." && pwd)"

# The main clone behind a linked worktree, else empty. `--git-common-dir` is the ONE
# mechanical way to get there: in a worktree it points at <main>/.git while --git-dir
# points at <main>/.git/worktrees/<name>.
voice_main_clone() {
  local common
  command -v git >/dev/null 2>&1 || return 0
  common="$(git -C "$VOICE_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [[ -n "$common" ]] || return 0
  case "$common" in
    /*) ;;
    *) common="$VOICE_ROOT/$common" ;;
  esac
  local main; main="$(cd "$(dirname "$common")" 2>/dev/null && pwd)" || return 0
  [[ "$main" != "$VOICE_ROOT" ]] && printf '%s' "$main"
  return 0
}
VOICE_MAIN_CLONE="$(voice_main_clone || true)"

# ── logging ───────────────────────────────────────────────────────────────────────
# Quiet by default: these scripts run from hooks, where stray stdout is noise at best
# and a broken hook contract at worst. -v turns the reasoning on, to stderr only.
# Exported so the child scripts (identity.sh, queue.sh) inherit it — a -v that stopped at the
# process boundary would hide exactly the steps you turned it on to see.
export VOICE_VERBOSE="${VOICE_VERBOSE:-0}"
vlog() { [[ "$VOICE_VERBOSE" == "1" ]] && printf 'voice: %s\n' "$*" >&2 || true; }
vdie() { printf 'voice: error: %s\n' "$*" >&2; exit 1; }

voice_require() {
  local b
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 || vdie "$b is required"; done
}

# ── config ────────────────────────────────────────────────────────────────────────
# Read one dotted path out of one YAML file. Block style only (2-space indent), which is
# what every section of workspace.config.yaml already uses — flow style ({ a: 1 }) is
# deliberately NOT parsed, so write the voice block expanded.
# Prints nothing when the path is absent or maps to a parent key, so the caller can tell
# "absent" from "false" and fall through to the next file.
_voice_yaml_get() {
  local f="$1" want="$2"
  [[ -f "$f" ]] || return 0
  awk -v want="$want" '
    function val(s){ sub(/^[^:]*:[ \t]*/,"",s); sub(/[ \t]+#.*$/,"",s);
                     gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
    /^[ \t]*(#|$)/  { next }
    /^[ \t]*-/      { next }          # list items hold no dotted scalar path we read
    {
      ind = match($0, /[^ ]/) - 1
      rest = substr($0, ind + 1)
      if (rest !~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) next
      key = rest; sub(/[ \t]*:.*/, "", key)
      d = int(ind / 2)
      stack[d] = key
      for (i = d + 1; i <= 20; i++) stack[i] = ""
      p = stack[0]
      for (i = 1; i <= d; i++) p = p "." stack[i]
      if (p == want) { v = val(rest); if (v != "") { print v; exit } }
    }
  ' "$f"
}

# voice_cfg <dotted.path> [default] — the resolved value, local-first (see header).
voice_cfg() {
  local want="$1" def="${2:-}" f v
  for f in \
    "$VOICE_ROOT/workspace.config.local.yaml" \
    ${VOICE_MAIN_CLONE:+"$VOICE_MAIN_CLONE/workspace.config.local.yaml"} \
    "$VOICE_ROOT/workspace.config.yaml"
  do
    v="$(_voice_yaml_get "$f" "$want")"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  printf '%s' "$def"
}

voice_cfg_bool() {   # true only for true/yes/1/on
  case "$(voice_cfg "$1" "${2:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;; *) return 1 ;;
  esac
}

# voice_cfg_int <dotted.path> <default> [min] [max] — a NUMERIC setting, clamped.
# Clamped rather than trusted: these numbers are seconds and counts that decide how often the
# machine talks and how much it spends. A typo'd `narrate_gap: 0` is an unbounded queue and a
# `400` is silence, and neither should be reachable by dropping a digit in a personal config.
voice_cfg_int() {
  local v; v="$(voice_cfg "$1" "$2")"
  [[ "$v" =~ ^-?[0-9]+$ ]] || { vlog "cfg $1: '$v' is not a number — using $2"; v="$2"; }
  if [[ -n "${3:-}" ]] && (( v < $3 )); then v="$3"; fi
  if [[ -n "${4:-}" ]] && (( v > $4 )); then v="$4"; fi
  printf '%s' "$v"
}

# The workspace output language, same precedence as everything else. VOICE_LANGUAGE is an
# override for TESTS and for a caller that already resolved it (the language hook) — it is
# not a way to opt a machine in or out; the config is.
voice_language() {
  if [[ -n "${VOICE_LANGUAGE:-}" ]]; then printf '%s' "$VOICE_LANGUAGE"; return 0; fi
  local f v
  for f in \
    "$VOICE_ROOT/workspace.config.local.yaml" \
    ${VOICE_MAIN_CLONE:+"$VOICE_MAIN_CLONE/workspace.config.local.yaml"} \
    "$VOICE_ROOT/workspace.config.yaml"
  do
    v="$(_voice_yaml_get "$f" language)"
    [[ -n "$v" ]] && { printf '%s' "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"; return 0; }
  done
  printf 'en'
}

# ── chattiness ────────────────────────────────────────────────────────────────────
# How much it says when it speaks — NOT whether it speaks. "When" already has four switches
# (autoplay.ack / .milestones / .milestone_every_turn / .narrate); a fifth thing that could also
# produce silence would give "why is it quiet?" five possible answers and no way to tell which.
#
#   terse      one sentence, facts only, no softener and no reaction word. Byte-for-byte the
#              behaviour that shipped, and the default here and in workspace.config.yaml.
#   balanced   one or two sentences, plus a softener (ให้นะคะ) and a 1–2 word reaction (ได้ค่ะ /
#              เจอแล้วค่ะ) and the second fact.
#   chatty     two or three, plus the third fact and the follow-through (what will be reported,
#              what is waiting for you).
#   max        up to four, in the register of a flight engineer reporting to the person in charge:
#              every sentence is [subject] [state] [figure] addressed to them, the STEPS are named
#              in the order they happen — AND a running narration mid-turn: one line per step,
#              spoken as the work happens (narrate.sh). The one level that narrates the process
#              rather than only the outcome.
#
# `terse`…`chatty` reach ack.sh and milestone.sh ONLY — so at those levels nothing at all is spoken
# between the ack and the closing line. `max` additionally turns on narrate.sh, the step narrator,
# which is now the ONLY mid-turn voice there is (the timed heartbeat that used to fill that space was
# removed). The Slack voice note stays one canonical sentence per event at every level (its repetition
# is what makes it free — it hits the audio cache — and that audio is the team's, not this
# machine's), and the identity prefix is an identifier with nothing to lengthen.
#
# An unreadable value falls back to `terse` rather than aborting: a typo in a personal config file
# must not take speech down, and falling back to the DOCUMENTED default is more predictable than
# picking the middle.
#
# VOICE_CHATTINESS overrides it, for `aiworks voice audition` and for tests — not as a way to set a
# machine's preference, which is the config's job.
#
# ── ANYTHING ABOVE `terse` IS THE ROOT WORKTREE'S ALONE ───────────────────────────
# A linked worktree speaks `terse`, whatever the config says. Three facts collide otherwise:
#
#   · the config chain deliberately falls back to <main clone>/workspace.config.local.yaml
#     (layer 2 above), because a git-ignored file does not travel into a worktree — so a worktree
#     INHERITS the root's `max` rather than defaulting to the shared file's `terse`;
#   · a worktree session is usually one nobody is watching: a background dev-cycle, a
#     slack-dispatch job. `max` is the level that narrates every STEP, so the worktree with the
#     least of your attention becomes the loudest thing in the room;
#   · every worktree speaks through ONE spool and ONE pair of speakers (VOICE_CACHE_HOME is
#     machine-global on purpose). Two `max` sessions do not take turns — they queue behind each
#     other, and the one you are actually reading waits for the one you are not.
#
# So the level is a ROOT-WORKTREE setting and this is its enforcement point, not a convention to
# remember: every caller (ack.sh · milestone.sh · narrate.sh · summarize.sh's fallback · `aiworks
# voice status`) goes through this function, and narrate.sh gates on `== max`, so the clamp turns
# the step narrator off in a worktree as a consequence rather than as a second rule.
#
# Mechanical, same as everywhere else in this file: VOICE_MAIN_CLONE is non-empty exactly when
# `--git-common-dir` points somewhere other than here, i.e. this is a linked worktree.
#
# The clamp does NOT apply to VOICE_CHATTINESS. That one is a human typing one command (an
# audition, a test), which is per-invocation intent — not a machine preference leaking through the
# config chain, which is the thing being fixed.
voice_chattiness() {
  local v from_env=0
  if [[ -n "${VOICE_CHATTINESS:-}" ]]; then v="$VOICE_CHATTINESS"; from_env=1
  else v="$(voice_cfg voice.autoplay.chattiness terse)"; fi
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    terse|balanced|chatty|max) ;;
    *) vlog "chattiness: '$v' is not terse|balanced|chatty|max — using terse"; v=terse ;;
  esac
  if [[ "$from_env" == 0 && -n "$VOICE_MAIN_CLONE" && "$v" != "terse" ]]; then
    vlog "chattiness: '$v' is the root worktree's setting — this is a linked worktree, so terse (main=$VOICE_MAIN_CLONE)"
    v=terse
  fi
  printf '%s' "$v"
}

# ── the `max` register knobs (all inert at every other level) ──────────────────────
# Set by research, not by taste: JARVIS's lines in the Iron Man films are 3–8 words, spoken as a
# figure CHANGES, several within a few seconds during a burst. Length was the wrong dial — the
# first `max` raised it (4 long sentences, a 360-char ceiling) and came out sounding like a status
# report read aloud. These four dials are the right ones: shorter, more often, made of facts.
#
# `facts` reads the tool's own response (scripts/voice/tool-fact.py) and says the FIGURE — "queue.sh
# อ่านแล้ว 260 บรรทัด", "cargo test ผ่าน 42". `prose` is the previous mechanism, the assistant's own
# pre-tool sentence, which is an INTENTION — kept because it is free and because the two are worth
# comparing by ear, not because it is the default.
voice_narrate_source() {
  local v; v="$(printf '%s' "${VOICE_NARRATE_SOURCE:-$(voice_cfg voice.autoplay.narrate_source facts)}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in facts|prose) printf '%s' "$v" ;; *) vlog "narrate_source: '$v' is not facts|prose — using facts"; printf 'facts' ;; esac
}

# Seconds between narrated lines. 4 s, down from the first version's 9: at 9 s a burst of ten tool
# calls in twenty seconds could say two things, which is the opposite of the character being
# imitated. A spoken fact line is ~2-3 s, so 4 s still leaves air and still bounds the queue.
voice_narrate_gap() { voice_cfg_int voice.autoplay.narrate_gap 4 1 60; }

# The per-TURN ceiling, and the cost dial. Every narrated line is TTS spend; a runaway turn with
# 200 tool calls must not be able to spend 200 lines' worth. When it bites, narrate.sh SAYS so in
# its log rather than going quietly silent — a silent cap reads as a broken feature.
voice_narrate_cap() { voice_cfg_int voice.autoplay.narrate_max_per_turn 25 1 200; }

# When a turn passing this many seconds is worth mentioning ONCE (and once more at 3×). The
# heartbeat's mistake was repeating on a clock; this is a threshold crossing, single-shot per turn
# (see voice_threshold_fire), and it only ever fires on a step that actually ran.
voice_long_turn_seconds() { voice_cfg_int voice.autoplay.long_turn_seconds 300 30 3600; }

# ── narration state (the `max` step narrator) ─────────────────────────────────────
# WHY THE FIRST ATTEMPT AT `max` WAS WRONG, since this replaces it: it tightened a timed HEARTBEAT
# (45 s, ten beats) — a background sleeper that said "still working, currently <last tool>". A clock
# fires whether or not anything happened, so it narrates a 3-second step never and a 90-second step
# twice, and it can only name the tool it happens to catch, never why. That is a liveness ping, and
# `max` is not asking for liveness: it is asking to be TOLD WHAT IS HAPPENING, which is a property of
# the WORK, not of elapsed time. The heartbeat has since been DELETED outright rather than left off:
# in use it read as an odd, disembodied interruption, and nothing wants it back.
#
# So `max` is event-driven: every tool call is a step, and the narrator speaks THE ASSISTANT'S OWN
# PROSE — the line it writes before reaching for a tool ("อ่าน queue ก่อน แล้วค่อยแก้ cadence"),
# which is already exactly "what I am doing and what I am about to do". It costs no summarizer call,
# it cannot drift from the truth, and it needs no model of its own.
#
# This file is that channel's whole memory, because every PostToolUse hook is a FRESH process:
#   hash   what was last spoken. One prose block introduces SEVERAL tool calls (measured on a real
#          session: 314 prose blocks against 1 523 tool calls, ~1 per 5), so without this the same
#          sentence would be spoken five times in a row.
#   ts     when. Tool calls fire several per second while a spoken line takes seconds, so the
#          narrator needs a floor between utterances or it queues faster than it can drain.
voice_narrate_file() { printf '%s/nar-%s.json' "$VOICE_TURN_DIR" "$(voice_sha "${1:-default}")"; }

#   n      how many lines this TURN has already spoken — the per-turn cost ceiling. Reset by
#          `nturn` below rather than by a cleanup pass, because nothing runs between turns.
#   nturn  the turn `n` belongs to (the turn's start timestamp). A counter with no turn stamp
#          would carry one long turn's total into the next one and mute it.
#   fail   the hash of the last FAILED step, so a command that fails twice can be told from two
#          different commands failing once (the second failure is the news, not the first).
#   thr    space-separated names of the single-shot thresholds already announced this turn.
#
# NUMERIC FIELDS are ts / n / nturn: they default to 0, so a caller can do arithmetic on the
# result of a first-ever read without testing for the empty string.
voice_narrate_file() { printf '%s/nar-%s.json' "$VOICE_TURN_DIR" "$(voice_sha "${1:-default}")"; }

_voice_narrate_numeric() { case "$1" in ts|n|nturn|gatets|failn) return 0 ;; *) return 1 ;; esac; }

voice_narrate_get() {   # SESSION FIELD(hash|ts|n|nturn|fail|thr) → value ("" / 0 when unknown)
  local f v; f="$(voice_narrate_file "$1")"
  [[ -f "$f" ]] || { _voice_narrate_numeric "$2" && printf 0; return 0; }
  v="$(jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null || true)"
  if _voice_narrate_numeric "$2"; then [[ "$v" =~ ^[0-9]+$ ]] || v=0; fi
  printf '%s' "$v"
}

# MERGES rather than replaces (the first version wrote a fresh {hash, ts} object): the counters
# and the threshold list live in the same file, and a setter that dropped them would re-arm every
# single-shot threshold on the next narrated step.
voice_narrate_put() {   # SESSION FIELD VALUE — a string/number field, timestamp untouched
  voice_mkdirs
  local f; f="$(voice_narrate_file "$1")"
  if [[ -f "$f" ]]; then
    jq --arg k "$2" --arg v "$3" '.[$k] = $v' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  else
    jq -n --arg k "$2" --arg v "$3" '{($k): $v}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  fi
}

voice_narrate_set() {   # SESSION HASH [TURN] — records what was said and WHEN, bumping the count
  voice_mkdirs
  local f turn; f="$(voice_narrate_file "$1")"; turn="${3:-0}"
  if [[ -f "$f" ]]; then
    jq --arg h "$2" --argjson t "$(voice_now)" --arg turn "$turn" '
      . as $o
      | (if ($o.nturn // "0") == $turn then (($o.n // "0") | tonumber) else 0 end) as $n
      | $o + {hash: $h, ts: $t, n: (($n + 1) | tostring), nturn: $turn}
    ' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  else
    jq -n --arg h "$2" --argjson t "$(voice_now)" --arg turn "$turn" \
      '{hash: $h, ts: $t, n: "1", nturn: $turn}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  fi
}

# How many lines this turn has spoken — 0 once the turn stamp moves on, without a reset pass.
voice_narrate_count() {   # SESSION TURN → number
  local n turn
  n="$(voice_narrate_get "$1" n)"; turn="$(voice_narrate_get "$1" nturn)"
  [[ "$turn" == "$2" ]] && printf '%s' "$n" || printf 0
}

# A single-shot threshold: true (and ARMS it) the first time it is asked for in this turn, false
# after. This is what separates a threshold from the deleted heartbeat — the same condition
# staying true does NOT keep speaking, because a repeated "still slow" is a clock in disguise.
voice_threshold_fire() {   # SESSION TURN NAME → 0 = speak now, 1 = already announced
  local key="$2:$3" seen
  seen="$(voice_narrate_get "$1" thr)"
  case " $seen " in *" $key "*) return 1 ;; esac
  voice_narrate_put "$1" thr "$(printf '%s %s' "$seen" "$key" | sed -E 's/^ +//')"
  return 0
}

# ── the gate ──────────────────────────────────────────────────────────────────────
# Decision #17: voice is a `th`-only feature, and a failed gate is SILENT — exit 0, no
# output. A voice adapter that complained on every call would turn a personal preference
# into everyone's stderr noise; -v is how you find out why nothing happened.
voice_gate_or_exit() {
  local what="${1:-voice}" lang
  lang="$(voice_language)"
  if [[ "$lang" != "th" ]]; then
    vlog "$what skipped: workspace language is '$lang', voice is th-only (docs/agents/language.md)"
    exit 0
  fi
  if ! voice_cfg_bool voice.enabled false; then
    vlog "$what skipped: voice.enabled is false (set it in workspace.config.local.yaml)"
    exit 0
  fi
  return 0
}

# ── credentials ───────────────────────────────────────────────────────────────────
voice_load_credentials() {
  local f line k v
  f="$HOME/.config/aiworks/voice.env"
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
  f="$VOICE_DIR/.env"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [[ -n "$v" ]] || continue          # an empty stub must not clobber the real key
    export "$k=$v"
  done < "$f"
}

# voice_need_key NAME — the key's value, or a message naming exactly which file to fix. The
# NAME is printed, never the value, including on the error path.
voice_need_key() {
  local name="$1"
  [[ -n "${!name:-}" ]] || vdie "$name is not set — add it to ~/.config/aiworks/voice.env (mode 600) or scripts/voice/.env"
  printf '%s' "${!name}"
}

# ── paths ─────────────────────────────────────────────────────────────────────────
# Machine-global on purpose: several worktrees speak through ONE cache, ONE spool and ONE
# playback lock, so parallel work gets cheaper per utterance instead of overlapping.
VOICE_CACHE_HOME="${VOICE_CACHE_HOME:-$HOME/.cache/aiworks/voice}"
VOICE_AUDIO_DIR="$VOICE_CACHE_HOME/cache"
VOICE_PREFIX_DIR="$VOICE_CACHE_HOME/prefix"
VOICE_CUE_DIR="$VOICE_CACHE_HOME/cue"
VOICE_SPOOL_DIR="$VOICE_CACHE_HOME/spool"
VOICE_IDENT_DIR="$VOICE_CACHE_HOME/identity"
VOICE_TURN_DIR="$VOICE_CACHE_HOME/turn"
VOICE_LOCK="$VOICE_CACHE_HOME/play.lock"
VOICE_LAST_SPOKEN="$VOICE_CACHE_HOME/last-spoken.json"

voice_mkdirs() {
  mkdir -p "$VOICE_AUDIO_DIR" "$VOICE_PREFIX_DIR" "$VOICE_CUE_DIR" "$VOICE_SPOOL_DIR" \
           "$VOICE_IDENT_DIR" "$VOICE_TURN_DIR"
}

# ── turn state ────────────────────────────────────────────────────────────────────
# One file per Claude session: {turn: <epoch of the last prompt>, ended: <epoch|0>}.
# It answers the two questions an ack cannot answer on its own — has the answer already
# landed (⇒ saying "กำลังไปดู X" now is worse than silence), and has a NEWER prompt arrived
# (⇒ this ack is about to describe the wrong request).
voice_turn_file() { printf '%s/%s.json' "$VOICE_TURN_DIR" "$(voice_sha "${1:-default}")"; }

voice_turn_start() {   # SESSION_ID
  voice_mkdirs
  local f; f="$(voice_turn_file "$1")"
  jq -n --argjson t "$(voice_now)" '{turn: $t, ended: 0}' > "$f.tmp" && mv "$f.tmp" "$f"
}

voice_turn_end() {   # SESSION_ID
  voice_mkdirs
  local f; f="$(voice_turn_file "$1")"
  if [[ -f "$f" ]]; then
    jq --argjson e "$(voice_now)" '.ended = $e' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  else
    jq -n --argjson e "$(voice_now)" '{turn: 0, ended: $e}' > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

voice_turn_get() {   # SESSION_ID FIELD → number (0 when unknown)
  local f v; f="$(voice_turn_file "$1")"
  [[ -f "$f" ]] || { printf 0; return 0; }
  v="$(jq -r --arg k "$2" '.[$k] // 0' "$f" 2>/dev/null || printf 0)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

# ── cache keys ────────────────────────────────────────────────────────────────────
# Normalizing before hashing is what makes the Slack line free (§9.3): the same sentence
# with different spacing must land on the same file.
voice_normalize_text() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//'
}

voice_sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-40; }

# ── the spoken form ───────────────────────────────────────────────────────────────
# What should be SAID is not always what is written. Applied by speak.sh and identity.sh to
# every line BEFORE synthesis — and before the cache key, so the cache is keyed on what the
# audio actually contains.
#
# THREE REWRITES, each from something that was wrong out loud:
#
#   OFB-1598              A ticket number is an IDENTIFIER, not a quantity, and every engine
#                         read it as one number ("หนึ่งพันห้าร้อยเก้าสิบแปด") — which nobody can
#                         map back to a ticket. Spoken digit by digit, as Thai WORDS rather
#                         than spaced digits, so no engine gets a second chance to be clever.
#   feature/OFB-1598-x    The same, plus the separators: a branch read verbatim is "slash"
#                         and "dash" between every word.
#   MR · PR               "MR" is read as the honorific Mr. — "มี MR รอ review" came out as
#                         "มี mister รอ review". Expanded to the words they stand for, in
#                         English, which is what a Thai dev says anyway.
#   142 · 8% · 12         A QUANTITY IS STILL SPOKEN IN A LANGUAGE, and the vendors disagree on
#                         which. Measured on the same Thai sentences: ElevenLabs reads every
#                         numeral in ENGLISH mid-Thai-sentence ("มี two must fix", "450
#                         milliseconds", "8%" as "eight percent"), while OpenAI, Cartesia and
#                         Gemini read them in Thai. Bare "1 2 3 … 10" came out English on
#                         ElevenLabs and Gemini both. So the digits are converted to Thai number
#                         WORDS here, and what the assistant says stops depending on which
#                         vendor is configured.
#
# A QUANTITY IS STILL A QUANTITY. "142" becomes "หนึ่งร้อยสี่สิบสอง", the number — not the four
# digits, which is the identifier reading and is reserved for ticket keys. A key is recognised by
# the workspace's own tracker.ticket_prefix (any digit count, either case, so a branch matches
# too), plus a generic UPPERCASE-3+DIGITS fallback for another project's key — 3 digits, so
# "UTF-8" and "gpt-4o" are not identifiers as far as this is concerned. Keys are spelled FIRST,
# so their digits are already words by the time the quantity pass runs and cannot be re-read.
#
# Anything glued to an ASCII letter or to `.`/`:`/`-` is left alone, which is what keeps
# `gpt-4o`, `eleven_v3`, `UTF-8`, `sonic-3` and `14:30` out of it. A decimal is read the Thai
# way — the integer part as a number, then "จุด" and the fraction digit by digit.
voice_spoken_form() {
  local text="${1:-}" prefix
  [[ -n "$text" ]] || return 0
  case "$text" in
    # Nothing to rewrite unless there is an ASCII letter or digit in it. Skips the python3
    # start-up for a line of pure Thai, which is most of them.
    *[A-Za-z0-9]*) ;;
    *) printf '%s' "$text"; return 0 ;;
  esac
  command -v python3 >/dev/null 2>&1 || { printf '%s' "$text"; return 0; }
  prefix="$(voice_cfg tracker.ticket_prefix "")"
  python3 -c '
import re, sys
text, prefix = sys.argv[1], sys.argv[2]

TH = {"0": "ศูนย์", "1": "หนึ่ง", "2": "สอง", "3": "สาม", "4": "สี่",
      "5": "ห้า", "6": "หก", "7": "เจ็ด", "8": "แปด", "9": "เก้า"}
def spell(n): return " ".join(TH[c] for c in n)

# Thai reading of a number. The three irregulars are not optional — a Thai listener hears
# "ยี่สิบหนึ่ง" as a foreigner speaking: 20 is ยี่สิบ (not สองสิบ), a lone 10 is สิบ (not หนึ่งสิบ),
# and a trailing 1 is เอ็ด — but ONLY when the tens digit above it is non-zero.
#
# That last condition is the whole rule, and getting it wrong is not subtle to a native ear:
#   21 → ยี่สิบเอ็ด        11 → สิบเอ็ด        121 → หนึ่งร้อยยี่สิบเอ็ด     (tens non-zero ⇒ เอ็ด)
#   101 → หนึ่งร้อยหนึ่ง   1001 → หนึ่งพันหนึ่ง   1101 → หนึ่งพันหนึ่งร้อยหนึ่ง  (tens 0 ⇒ หนึ่ง)
# เอ็ด belongs to the …สิบเอ็ด position specifically; a 0 in the tens place always gives หนึ่ง.
UNITS = ["", "สิบ", "ร้อย", "พัน", "หมื่น", "แสน"]
def th_int(n):
    if n == 0:
        return "ศูนย์"
    if n >= 10 ** 6:                       # ล้าน is a full group, and it nests: 100000000 = หนึ่งร้อยล้าน
        head, rest = divmod(n, 10 ** 6)
        return th_int(head) + "ล้าน" + (th_int(rest) if rest else "")
    s, out = str(n), ""
    tens = int(s[-2]) if len(s) >= 2 else 0
    for i, c in enumerate(s):
        d, place = int(c), len(s) - 1 - i
        if d == 0:
            continue
        if place == 1 and d == 2:
            out += "ยี่สิบ"
        elif place == 1 and d == 1:
            out += "สิบ"
        elif place == 0 and d == 1 and tens != 0:
            out += "เอ็ด"
        else:
            out += TH[c] + UNITS[place]
    return out

def th_number(tok):
    if "." in tok:                          # 0.915 → ศูนย์ จุด เก้า หนึ่ง ห้า
        whole, frac = tok.split(".", 1)
        return th_int(int(whole)) + " จุด " + spell(frac)
    # Past a million-and-a-half digits nothing is a quantity any more — that is an id someone
    # wrote without a prefix, so read it as digits rather than inventing a magnitude.
    return th_int(int(tok)) if len(tok) <= 9 else spell(tok)

# Lookarounds on ASCII only, never \b: \w is unicode-aware, so "มีMRรอ" (Thai runs together
# without spaces) would fail a \b test and keep the honorific reading.
NB = r"(?<![A-Za-z0-9])"
pats = []
if prefix:
    pats.append(re.compile(NB + r"(" + re.escape(prefix) + r")-(\d+)(?![0-9])", re.I))
pats.append(re.compile(NB + r"([A-Z][A-Z0-9]{1,9})-(\d{3,})(?![0-9])"))

def spell_keys(s):
    for rx in pats:
        s = rx.sub(lambda m: m.group(1).upper() + " " + spell(m.group(2)), s)
    return s
def has_key(s):
    return any(rx.search(s) for rx in pats)

# A branch, but not a URL: the lookbehind refuses a segment preceded by "/", so every path
# inside an https:// link is left alone (a URL read aloud is noise either way).
BRANCH = re.compile(r"(?<![\w/])((?:[A-Za-z][\w.]*/)+)([A-Za-z0-9][\w.-]*)")
def branch(m):
    head, tail = m.group(1), m.group(2)
    if not has_key(tail):
        return m.group(0)
    return head.replace("/", " ") + re.sub(r"[-_]+", " ", spell_keys(tail))

# Padded with spaces: Thai runs words together, so "มีMRรอreview" would otherwise become
# "มีmerge requestรอreview" and hand the engine one unpronounceable token.
text = re.sub(NB + r"MRs(?![A-Za-z0-9])", " merge requests ", text)
text = re.sub(NB + r"PRs(?![A-Za-z0-9])", " pull requests ", text)
text = re.sub(NB + r"MR(?![A-Za-z0-9])", " merge request ", text)
text = re.sub(NB + r"PR(?![A-Za-z0-9])", " pull request ", text)
text = BRANCH.sub(branch, text)
text = spell_keys(text)

# QUANTITIES, last — after every identifier has already become words. The guard on both sides is
# what keeps a version or a time out of it: a digit run touching an ASCII letter, `.`, `:` or `-`
# is part of something else (gpt-4o, eleven_v3, UTF-8, 14:30, 2026-07-29), not a count. The
# decimal form is matched as one token so "0.915" is not read as two numbers.
QTY = re.compile(r"(?<![A-Za-z0-9.:-])(\d+(?:\.\d+)?)(?![A-Za-z0-9.:-])")
text = QTY.sub(lambda m: " " + th_number(m.group(1)) + " ", text)
# Only now, so "8%" has already become "แปด %". Read verbatim the sign comes out as English
# "percent" on the same engines that read the numeral in English.
text = text.replace("%", " เปอร์เซ็นต์ ")
text = re.sub(r"  +", " ", text)
# "!" is deliberately not in the set: `MR !12` is a GitLab number, and it reads as one — so the
# space the quantity pass inserts after it is taken back out, or it becomes "! สิบสอง".
text = re.sub(r"! +", "!", text)
text = re.sub(r" +([.,;:?)])", r"\1", text)
sys.stdout.write(text.strip())
' "$text" "$prefix" 2>/dev/null || printf '%s' "$text"
}

# ── focus ─────────────────────────────────────────────────────────────────────────
# The worktree the user is CURRENTLY prompting in — written by the UserPromptSubmit hook, which
# is the only honest signal for it: you just typed there.
#
# It exists so the identity prefix can shut up. Hearing "OFB-1598" in front of every sentence in
# the session you are looking at is noise — you know where you are. The prefix earns its keep
# only when a DIFFERENT worktree speaks (a background dev-cycle, a slack-dispatch job, the other
# window), and that is exactly "session != focused".
VOICE_FOCUS_FILE="$VOICE_CACHE_HOME/focused"

voice_focus_set() {   # [SESSION] — defaults to this checkout
  voice_mkdirs
  printf '%s' "${1:-$VOICE_ROOT}" > "$VOICE_FOCUS_FILE.tmp" 2>/dev/null \
    && mv "$VOICE_FOCUS_FILE.tmp" "$VOICE_FOCUS_FILE"
}

voice_focus_get() { [[ -f "$VOICE_FOCUS_FILE" ]] && cat "$VOICE_FOCUS_FILE" 2>/dev/null || printf ''; }

voice_is_focused() {   # [SESSION]
  local me="${1:-$VOICE_ROOT}" cur
  cur="$(voice_focus_get)"
  [[ -n "$cur" && "$cur" == "$me" ]]
}

# voice_cache_key TEXT PROVIDER VOICE MODEL CUE MIX — every input that changes the BYTES is
# in the key, because the cache holds the FINISHED (already mixed) file.
voice_cache_key() {
  voice_sha "$(printf '%s|%s|%s|%s|%s|%s' "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "$(voice_normalize_text "$1")")"
}

# ── loudness ──────────────────────────────────────────────────────────────────────
# EVERY VENDOR SHIPS A DIFFERENT VOLUME, and so does every voice inside a vendor. Measured on
# one sentence: ElevenLabs Sarah −14.1 LUFS · Gemini Leda −19.2 · OpenAI nova −19.7 · Cartesia
# Somchai −22.6 · Cartesia Suda −28.8 · OpenAI sage −31.5. That is an 17 LU spread — roughly
# "three times quieter" by ear, and it was audible the first time two providers were auditioned
# back to back. Two things break because of it:
#
#   · switching `voice.tts.provider` (or just the voice) silently changes how loud the
#     assistant is, so the system volume you set yesterday is wrong today;
#   · `--cue`'s bed level is a FIXED gain (`CUE_VOL`, 0.22), so the same number buries the cue
#     under Sarah and lets it drown sage.
#
# So every synthesized line is normalized to one target before it is mixed and cached. A cache
# hit pays nothing: this runs on the synthesis path only.
voice_loudness_target() {   # prints the target LUFS, or nothing when normalization is off
  local t; t="$(voice_cfg voice.tts.loudness -16)"
  case "$t" in off|none|false|"") return 0 ;; esac
  printf '%s' "$t"
}

_voice_ln_field() { printf '%s\n' "$1" | sed -nE "s/.*\"$2\"[^\"]*\"([^\"]*)\".*/\1/p"; }

# voice_loudnorm IN OUT — two-pass EBU R128 normalization to voice_loudness_target.
#
# `linear=true` makes it ONE gain change across the clip, so the voice's own dynamics survive;
# ffmpeg falls back to its dynamic mode only when linear gain cannot reach the target without
# breaching the −1.5 dBTP ceiling. Measured on the sweep clips: an 18.4 LU spread collapsed to
# 0.8 LU with every true peak at or under −1.7 dBFS.
#
# FAIL-OPEN on every path: the caller keeps the original file. A sentence already paid for must
# never be lost to a cosmetic step — the same rule the cue mix follows.
voice_loudnorm() {
  local in="$1" out="$2" target json I TP LRA THR OFF
  target="$(voice_loudness_target)"
  [[ -n "$target" ]] || return 1
  command -v ffmpeg >/dev/null 2>&1 || { vlog "loudnorm skipped: no ffmpeg"; return 1; }

  json="$(ffmpeg -hide_banner -nostats -i "$in" \
            -af "loudnorm=I=$target:TP=-1.5:LRA=11:print_format=json" -f null - 2>&1 \
          | sed -n '/^{/,/^}/p')" || { vlog "loudnorm: measure pass failed"; return 1; }
  I="$(_voice_ln_field "$json" input_i)";       TP="$(_voice_ln_field "$json" input_tp)"
  LRA="$(_voice_ln_field "$json" input_lra)";   THR="$(_voice_ln_field "$json" input_thresh)"
  OFF="$(_voice_ln_field "$json" target_offset)"
  [[ -n "$I" && -n "$TP" && -n "$LRA" && -n "$THR" && -n "$OFF" ]] \
    || { vlog "loudnorm: could not read the measurement"; return 1; }
  # A clip measured as silence has no gain that fixes it, and `-inf` poisons the apply pass.
  case "$I" in -inf*|inf*|nan*) vlog "loudnorm: input measured $I — left alone"; return 1 ;; esac

  ffmpeg -y -hide_banner -loglevel error -i "$in" -af \
    "loudnorm=I=$target:TP=-1.5:LRA=11:measured_I=$I:measured_TP=$TP:measured_LRA=$LRA:measured_thresh=$THR:offset=$OFF:linear=true" \
    -c:a libmp3lame -b:a 128k "$out" \
    || { rm -f "$out"; vlog "loudnorm: apply pass failed"; return 1; }
  [[ -s "$out" ]] || { rm -f "$out"; vlog "loudnorm: apply pass wrote nothing"; return 1; }
  vlog "loudnorm: $I LUFS → $target LUFS"
}

# ── cache size ────────────────────────────────────────────────────────────────────
# An audio cache that only grows is a slow leak in ~/.cache, so trim it to voice.cache.max_mb
# on a least-recently-USED basis (`ls -tu` = access time, and playback is an access — so the
# sentences you actually keep hearing survive, unlike an mtime/FIFO policy that would evict
# them for being old).
#
# Only cache/ is pruned. prefix/ and cue/ are deliberately exempt: they are a handful of tiny
# files with the highest reuse of anything here, and each one costs an API call to rebuild.
#
# Call it with the playback lock HELD (queue.sh does), so two drains never prune each other's
# files mid-read.
voice_cache_prune() {
  local cap_mb used_kb cap_kb target_kb f sz
  cap_mb="$(voice_cfg voice.cache.max_mb 500)"
  [[ "$cap_mb" =~ ^[0-9]+$ ]] || cap_mb=500
  [[ "$cap_mb" -gt 0 ]] || return 0
  [[ -d "$VOICE_AUDIO_DIR" ]] || return 0
  used_kb="$(du -sk "$VOICE_AUDIO_DIR" 2>/dev/null | awk '{print $1}')"
  [[ -n "$used_kb" ]] || return 0
  cap_kb=$((cap_mb * 1024))
  [[ "$used_kb" -le "$cap_kb" ]] && return 0
  target_kb=$((cap_kb * 9 / 10))     # trim to 90 %, so this doesn't run on every single call
  vlog "cache prune: ${used_kb}KB used > ${cap_kb}KB cap, trimming to ${target_kb}KB"
  # Oldest access first: reverse of `ls -tu`.
  for f in $( (ls -1tu "$VOICE_AUDIO_DIR" 2>/dev/null || true) | tail -r); do
    [[ "$used_kb" -le "$target_kb" ]] && break
    sz="$(du -k "$VOICE_AUDIO_DIR/$f" 2>/dev/null | awk '{print $1}')"
    rm -f "$VOICE_AUDIO_DIR/$f" || continue
    used_kb=$((used_kb - ${sz:-0}))
  done
  vlog "cache prune: now ${used_kb}KB"
}

# ── providers ─────────────────────────────────────────────────────────────────────
# VOICE_TTS_PROVIDER_FORCE / VOICE_TTS_VOICE_FORCE (set by speak.sh --provider/--voice) exist
# so a voice can be auditioned without editing config — the whole point of "switchable" is
# being able to hear the alternative before committing to it.
voice_load_tts_provider() {
  VOICE_TTS_PROVIDER="${VOICE_TTS_PROVIDER_FORCE:-$(voice_cfg voice.tts.provider elevenlabs)}"
  local impl="$VOICE_DIR/providers/$VOICE_TTS_PROVIDER.sh"
  [[ -f "$impl" ]] || vdie "unknown voice.tts.provider '$VOICE_TTS_PROVIDER' (no $impl) — use elevenlabs|gemini|cartesia|openai"
  # shellcheck disable=SC1090
  . "$impl"
  command -v voice_tts_synth >/dev/null 2>&1 || vdie "$impl defines no voice_tts_synth"
}

# STT lives in providers/stt-<name>.sh, a SEPARATE file from the TTS provider of the same
# vendor. Two vendors can be selected at once (tts: elevenlabs + stt: openai), and if both
# halves shared one file, loading the second would redefine the first's voice_tts_synth.
voice_load_stt_provider() {
  VOICE_STT_PROVIDER="${VOICE_STT_PROVIDER_FORCE:-$(voice_cfg voice.stt.provider openai)}"
  local impl="$VOICE_DIR/providers/stt-$VOICE_STT_PROVIDER.sh"
  [[ -f "$impl" ]] || vdie "unknown voice.stt.provider '$VOICE_STT_PROVIDER' (no $impl) — use openai|gemini|elevenlabs"
  # shellcheck disable=SC1090
  . "$impl"
  command -v voice_stt_transcribe >/dev/null 2>&1 || vdie "$impl defines no voice_stt_transcribe"
}

# The domain vocabulary every STT request carries. Comments and blank lines stripped, newlines
# folded to spaces — see scripts/voice/stt-hint.txt for why this exists at all.
voice_stt_hint() {
  local f="$VOICE_DIR/stt-hint.txt"
  [[ -f "$f" ]] || return 0
  grep -v '^[[:space:]]*#' "$f" | tr '\n' ' ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//'
}

# ── mute ──────────────────────────────────────────────────────────────────────────
# TWO MUTES, ONE MEANING: silence is an OFF SWITCH, never a volume knob.
#
#   BY HAND   one file, machine-global: present ⇒ silence, absent ⇒ speech.
#             `aiworks voice mute on|off`.
#   BY THE OS  the system output is muted (the F10 key, the menu-bar slider, Control Centre).
#             Read live from macOS, not remembered.
#
# EITHER ONE DISABLES EVERY OUTPUT, rather than merely silencing it: nothing is summarized,
# nothing is synthesized, no cue and no sound effect is played. So a muted machine spends
# NOTHING on speech — which is the whole point. The alternative, and what this used to do for
# the OS half, was paying an LLM call plus a TTS call per turn to render audio into speakers
# that are off.
#
# It covers ack, milestone, narration, the gate voice, the identity prefix, the `ack` cue the
# UserPromptSubmit hook plays inline, `sfx.sh play` and a direct speak.sh alike. A person who
# mutes — by either switch — means "stop", not "a bit less".
#
# WHY THE OS FLAG AND NOT A VOLUME THRESHOLD: `output muted` is an explicit human action, and it
# is the one field that means it. `output volume: 0` is NOT the same signal — macOS reports 0 for
# HDMI / AirPlay / optical output, where the external device owns the volume, so treating 0 as
# silence would quietly kill the feature for anyone on a monitor's speakers. Muted is muted;
# quiet is not.
#
# TWO THINGS NEITHER MUTE COVERS, because neither is this machine talking:
#
#   The SLACK VOICE NOTE. That audio is a deliverable for the team, rendered here and heard on
#   someone else's phone, so it is not a question about the state of my speakers. Its one switch is
#   `voice.notify_voice.enabled` in workspace config (`.local` overrides) — a standing policy set
#   once, not a "for the next twenty minutes" toggle. speak.sh exempts `--no-play`, which is the
#   flag notify-voice.sh renders with.
#
#   DICTATION. Push-to-talk is INPUT and it only runs while you hold the key — there is no
#   background spend to save, and a mute that stopped you from dictating would be the switch
#   breaking a feature you just explicitly asked for. Only its cues go quiet.
#
# THE HAND MUTE IS A FILE, not a config key: it is a "for the next twenty minutes" decision, and
# putting it in workspace.config.local.yaml would mean editing config to go quiet — then forgetting
# to edit it back. Machine-global, so every worktree goes quiet at once rather than one clone at a
# time. The OS mute needs no state of ours at all: the system already holds it.
#
# THERE IS NO AUTOMATIC CALL DETECTION, by decision. An earlier version pgrep'd for
# Zoom/Teams/Webex; it was removed because it cannot be made honest — Google Meet is a browser
# TAB with no process to find, so the auto-detect would cover some calls and silently miss
# others, which is worse than covering none and having one switch you actually reach for. Muting
# the machine before a call, which people already do out of habit, is now that switch.
VOICE_MUTE_FILE="$VOICE_CACHE_HOME/mute"

# Is the SYSTEM output muted? macOS only, read live.
#
# COST: one osascript, ~120 ms measured. That is affordable because every producer of speech runs
# DETACHED (nohup'd out of the hook), so the 120 ms is never on the user's turn — and it buys back
# a whole LLM + TTS round-trip. The one inline caller, the `ack` cue in
# .claude/hooks/voice-ack.sh, does the check inside its own background subshell for the same reason.
#
# Memoized for ONE SECOND, not for the process: queue.sh's drain calls this once per job while it
# plays a backlog, and a mute pressed mid-drain has to stop the rest of it. A per-process memo
# would carry a stale "not muted" through the whole queue.
#
# `VOICE_OS_MUTED=1|0` forces the answer — the selftest uses it so the suite needs no audio device
# and no macOS, and it is the escape hatch if a machine ever reports this field wrongly.
#
# NOT muted is the answer when we cannot tell (no osascript, i.e. not macOS; or the call fails).
# Failing open keeps a working feature working; failing closed would make voice silently dead on a
# machine that never had a mute to begin with.
_VOICE_OS_MUTE_VAL=""
_VOICE_OS_MUTE_AT=0
voice_os_muted() {
  if [[ -n "${VOICE_OS_MUTED:-}" ]]; then
    [[ "$VOICE_OS_MUTED" == "1" ]] && return 0 || return 1
  fi
  command -v osascript >/dev/null 2>&1 || return 1
  local now; now="$(date +%s)"
  if [[ -z "$_VOICE_OS_MUTE_VAL" ]] || (( now - _VOICE_OS_MUTE_AT >= 1 )); then
    _VOICE_OS_MUTE_VAL="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)"
    [[ "$_VOICE_OS_MUTE_VAL" == "true" ]] || _VOICE_OS_MUTE_VAL="false"
    _VOICE_OS_MUTE_AT="$now"
  fi
  [[ "$_VOICE_OS_MUTE_VAL" == "true" ]]
}

# Which switch is holding it: `hand` | `os` | `` (not muted). For status output and logs — the
# answer to "why is it silent?" has to name the switch, or you go looking for the wrong one.
voice_mute_reason() {
  [[ -f "$VOICE_MUTE_FILE" ]] && { printf 'hand'; return 0; }
  voice_os_muted && { printf 'os'; return 0; }
  return 0
}

voice_is_muted() {
  if [[ -f "$VOICE_MUTE_FILE" ]]; then
    vlog "muted ($VOICE_MUTE_FILE — 'aiworks voice mute off' to undo)"
    return 0
  fi
  if voice_os_muted; then
    vlog "muted (system output is muted — unmute the machine to hear anything)"
    return 0
  fi
  return 1
}

voice_now() { date +%s; }
