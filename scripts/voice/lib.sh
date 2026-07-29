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
#   voice_chattiness           terse | balanced | chatty — how MUCH it says when it speaks
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
# (autoplay.ack / .milestones / .heartbeat / .milestone_every_turn); a fifth thing that could also
# produce silence would give "why is it quiet?" five possible answers and no way to tell which.
#
#   terse      one sentence, facts only, no softener and no reaction word. Byte-for-byte the
#              behaviour that shipped, and the default here and in workspace.config.yaml.
#   balanced   one or two sentences, plus a softener (ให้นะคะ) and a 1–2 word reaction (ได้ค่ะ /
#              เจอแล้วค่ะ) and the second fact.
#   chatty     two or three, plus the third fact and the follow-through (what will be reported,
#              what is waiting for you).
#
# It reaches ack.sh and milestone.sh ONLY. The heartbeat stays a template (its repetition is what
# makes it free — it hits the audio cache), the Slack voice note stays one canonical sentence per
# event (same reason, and that audio is the team's, not this machine's), and the identity prefix is
# an identifier with nothing to lengthen.
#
# An unreadable value falls back to `terse` rather than aborting: a typo in a personal config file
# must not take speech down, and falling back to the DOCUMENTED default is more predictable than
# picking the middle.
#
# VOICE_CHATTINESS overrides it, for `aiworks voice audition` and for tests — not as a way to set a
# machine's preference, which is the config's job.
voice_chattiness() {
  local v
  v="${VOICE_CHATTINESS:-$(voice_cfg voice.autoplay.chattiness terse)}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    terse|balanced|chatty) printf '%s' "$v" ;;
    *) vlog "chattiness: '$v' is not terse|balanced|chatty — using terse"; printf 'terse' ;;
  esac
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
#
# ORDINARY NUMBERS ARE LEFT ALONE. "3 must-fix", "12 tests", "5 นาที" are quantities and must
# stay quantities — only a ticket key's digits are split. A key is recognised by the workspace's
# own tracker.ticket_prefix (any digit count, either case, so a branch matches too), plus a
# generic UPPERCASE-3+DIGITS fallback for another project's key — 3 digits, so "UTF-8" and
# "gpt-4o" are not identifiers as far as this is concerned.
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
text = re.sub(r"  +", " ", text)
# "!" is deliberately not in the set: `MR !12` is a GitLab number, and it reads as one.
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
# One file, machine-global: present ⇒ silence, absent ⇒ speech. `aiworks voice mute on|off`.
#
# MUTE IS AN OFF SWITCH FOR THIS MACHINE'S SPEAKERS, NOT A VOLUME KNOB. Muted, everything the
# laptop was going to SAY is DISABLED rather than merely silenced: nothing is summarized, nothing
# is synthesized, no cue is played. So a muted machine spends nothing on speech, which is the
# point — the alternative was paying an LLM call and a TTS call per turn to render audio into
# muted speakers.
#
# It covers ack, milestone, heartbeat, the identity prefix and a direct speak.sh alike. A person
# who mutes by hand means "stop", not "a bit less".
#
# TWO THINGS IT DELIBERATELY DOES NOT COVER, because neither is this machine talking:
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
# A FILE, not a config key: this is a "for the next twenty minutes" decision. Putting it in
# workspace.config.local.yaml would mean editing config to go quiet — and forgetting to edit it
# back. Machine-global, so every worktree goes quiet at once rather than one clone at a time.
#
# THERE IS NO AUTOMATIC CALL DETECTION, by decision. An earlier version pgrep'd for
# Zoom/Teams/Webex; it was removed because it cannot be made honest — Google Meet is a browser
# TAB with no process to find, so the auto-detect would cover some calls and silently miss
# others, which is worse than covering none and having one switch you actually reach for.
VOICE_MUTE_FILE="$VOICE_CACHE_HOME/mute"

voice_is_muted() {
  [[ -f "$VOICE_MUTE_FILE" ]] || return 1
  vlog "muted ($VOICE_MUTE_FILE — 'aiworks voice mute off' to undo)"
  return 0
}

voice_now() { date +%s; }
