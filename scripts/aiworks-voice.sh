#!/usr/bin/env bash
#
# aiworks-voice.sh  (run it as: aiworks voice) — the human-facing face of the voice adapter.
#
# WHY THIS EXISTS
#   scripts/voice/ is a set of primitives that hooks and skills call. The two things a PERSON
#   does — "shut up, I am on a call" and "why is it not talking?" — should not require
#   remembering which primitive owns them. This is that front door, and nothing more: it holds
#   no logic of its own, it forwards to the adapter.
#
# Usage:
#   aiworks voice setup             install the prerequisites (ffmpeg, credential file, cues)
#   aiworks voice mute [on|off]     silence / unsilence EVERY spoken output on this machine
#   aiworks voice status            the gates, the mute, the queue, the cache, the cues
#   aiworks voice say "ข้อความ"      speak a line now (blocks until spoken) — a live check
#   aiworks voice audition "…"      speak the same request at all 4 chattiness levels, to compare
#   aiworks voice cues [--force]    generate the sound-cue catalog
#   aiworks voice normalize [-n]    level the ALREADY-cached audio to voice.tts.loudness (-n = dry run)
#   aiworks voice test              speak one line and report the timings
#   aiworks voice mic-check [secs]  calibrate the push-to-talk silence thresholds to your room
#   aiworks voice ptt install       write ~/.hammerspoon/voice-ptt.lua and print the manual steps
#
# MUTE IS GLOBAL AND TOTAL FOR THIS MACHINE'S SPEAKERS, AND IT IS AN OFF SWITCH. It is a file
# (~/.cache/aiworks/voice/mute), so it applies to every clone and worktree at once, and it covers
# ack, milestone, narration, the identity prefix, the dictation cues and a direct `speak.sh` alike.
# Muted, nothing is summarized and nothing is synthesized — speech costs ZERO while it is on,
# rather than paying for audio that goes nowhere.
#
# It does NOT touch the Slack voice note (that audio is for the team, and its one switch is
# `voice.notify_voice.enabled` in workspace config) and it does NOT touch dictation (input, only
# while you hold the key). Neither of those is this machine talking.
#
# There is deliberately NO automatic call detection: Google Meet is a browser tab with no process
# to find, so an auto-detect would cover some calls and silently miss others.
#
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VOICE="$DIR/voice"

c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_warn=; c_err=; c_dim=; c_off=; }
die() { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }
[[ -d "$VOICE" ]] || die "no voice adapter at $VOICE"

cmd="${1:-status}"; [[ $# -gt 0 ]] && shift

case "$cmd" in
  mute)
    # Bare `aiworks voice mute` reports rather than toggles: a toggle you cannot see the state
    # of is how you end up muted for a day without knowing.
    exec "$VOICE/queue.sh" mute "${1:-status}"
    ;;

  normalize)
    # New syntheses are levelled by speak.sh. Everything ALREADY in the cache was recorded at
    # whatever loudness its vendor felt like, so it would keep playing at the old level forever
    # — and re-synthesizing it all would cost real money for audio we already own. This levels
    # the existing files in place instead: local ffmpeg, no API call, no credit spent.
    # Idempotent (a file already at the target gets a ~0 dB gain), so re-running it is harmless.
    # shellcheck source=./voice/lib.sh
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    dry=0; [[ "${1:-}" == -n || "${1:-}" == --dry-run ]] && dry=1
    target="$(voice_loudness_target)"
    [[ -n "$target" ]] || die "voice.tts.loudness is off — nothing to normalize to"
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required (aiworks voice setup)"
    printf 'target %s LUFS  %s\n\n' "$target" "$([[ $dry -eq 1 ]] && echo '(dry run — nothing written)')"
    n=0; done_=0; skipped=0
    while IFS= read -r f; do
      n=$((n + 1))
      before="$(ffmpeg -hide_banner -nostats -i "$f" -af ebur128 -f null - 2>&1 \
                | awk '/^  Integrated loudness/{g=1} g&&/I:/{print $2; exit}')"
      if [[ $dry -eq 1 ]]; then
        printf '  %-42s %8s LUFS\n' "$(basename "$f")" "${before:-?}"; continue
      fi
      tmp="$f.norm.$$.mp3"
      if voice_loudnorm "$f" "$tmp"; then
        mv "$tmp" "$f"; done_=$((done_ + 1))
        printf '  %-42s %8s → %s LUFS\n' "$(basename "$f")" "${before:-?}" "$target"
      else
        rm -f "$tmp"; skipped=$((skipped + 1))
        printf '  %-42s %8s %sleft alone%s\n' "$(basename "$f")" "${before:-?}" "$c_dim" "$c_off"
      fi
      # SPEECH ONLY — cue/ is deliberately out of scope. Two reasons: an integrated-loudness
      # measurement over a 0.6 s chime is not trustworthy (R128 gating wants seconds of
      # material, so a short cue can come back over-amplified), and the cue levels that ARE in
      # the mix were auditioned by ear against `CUE_VOL`, so re-levelling them would silently
      # retune a balance somebody already chose. Cues do vary (−12.2 to −21.4 LUFS measured) —
      # that is a separate decision, taken by ear, not a bug this command should fix.
    done < <(find "$VOICE_AUDIO_DIR" "$VOICE_PREFIX_DIR" -type f -name '*.mp3' 2>/dev/null | sort)
    printf '\n%s%d speech file(s)%s' "$c_dim" "$n" "$c_off"
    [[ $dry -eq 1 ]] || printf ' · %d levelled · %d left alone' "$done_" "$skipped"
    printf '\n%scue/ left alone on purpose — see the comment in aiworks-voice.sh%s\n' "$c_dim" "$c_off"
    exit 0
    ;;

  status)
    # Everything that decides whether you hear anything, in the order it is decided — so a
    # "why is it silent?" is answered by reading down the list, not by guessing.
    # shellcheck source=./voice/lib.sh
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    set +e
    lang="$(voice_language)"
    printf 'language          %s' "$lang"
    [[ "$lang" == "th" ]] && printf ' %s✓%s\n' "$c_ok" "$c_off" \
                          || printf ' %s← voice is th-only, everything below is inert%s\n' "$c_warn" "$c_off"
    # SECOND, above every config switch: mute DISABLES the output half rather than turning it
    # down, so it is the answer to "why is it silent?" more often than any of the flags below —
    # and reading it last, after nine rows of `on ✓`, is how you waste ten minutes. Both switches
    # get their OWN row and the reason is named: "muted" that does not say WHICH mute sends you to
    # the wrong one.
    case "$(voice_mute_reason)" in
      hand)
        printf 'mute              %sON (by hand) — nothing spoken, summarized or synthesized%s\n' \
          "$c_warn" "$c_off"
        printf '                  %saiworks voice mute off · Slack voice notes + dictation unaffected%s\n' \
          "$c_dim" "$c_off" ;;
      os)
        printf 'mute              %sON (system output is muted) — nothing spoken, summarized or synthesized%s\n' \
          "$c_warn" "$c_off"
        printf '                  %sunmute the machine · Slack voice notes + dictation unaffected%s\n' \
          "$c_dim" "$c_off" ;;
      *)  printf 'mute              off\n' ;;
    esac
    # Short labels rather than the config path, so the value column stays aligned — a status
    # table that shifts by row is harder to read than the paths are to look up.
    # 'key|label|default' — the autoplay sub-switches default TRUE, so a missing key must not
    # be reported as off.
    for kv in 'voice.enabled|enabled|false' 'voice.autoplay.enabled|local speech|false' \
              'voice.autoplay.ack|  · ack per prompt|true' \
              'voice.autoplay.milestones|  · closing line|true' \
              'voice.autoplay.milestone_every_turn|    every turn|true' \
              'voice.autoplay.narrate|  · step narration|true' \
              'voice.autoplay.thresholds|  · thresholds|true' \
              'voice.autoplay.gates|  · gate voice|true' \
              'voice.notify_voice.enabled|slack voice note|false' \
              'voice.push_to_talk.enabled|push-to-talk|false'; do
      k="${kv%%|*}"; rest="${kv#*|}"; label="${rest%|*}"; def="${rest##*|}"
      if voice_cfg_bool "$k" "$def"; then printf '%-19s on %s✓%s\n' "$label" "$c_ok" "$c_off"
      else printf '%-19s off\n' "$label"; fi
    done
    # `max` reaches a third channel (the step narrator), so the note has to say so — and if
    # `narrate` is OFF, say THAT, because the mid-turn commentary is most of what `max` buys and a
    # level that silently delivers half of itself is the kind of thing you debug for ten minutes.
    chat="$(voice_chattiness)"
    # A linked worktree is clamped to `terse` (see voice_chattiness). Say so HERE, naming the level
    # that was configured and the checkout that owns it — otherwise this row reads `terse` while the
    # config file in front of you says `max`, and the config file looks broken.
    raw="$(printf '%s' "$(voice_cfg voice.autoplay.chattiness terse)" | tr '[:upper:]' '[:lower:]')"
    if [[ -n "$VOICE_MAIN_CLONE" && "$raw" != "$chat" ]]; then
      printf 'chattiness        %s %s← %s is the root checkout'\''s setting; a linked worktree always\n' \
        "$chat" "$c_warn" "$raw"
      printf '                  speaks terse (one spool, one pair of speakers)%s\n' "$c_off"
      printf '                  %sroot: %s%s\n' "$c_dim" "$VOICE_MAIN_CLONE" "$c_off"
    elif [[ "$chat" != "max" ]]; then
      printf 'chattiness        %s %s(ack + closing line only · aiworks voice audition to compare)%s\n' \
        "$chat" "$c_dim" "$c_off"
    elif voice_cfg_bool voice.autoplay.narrate true; then
      # The shape depends on the SOURCE, and the two differ in what a line is ABOUT, not just how
      # often one arrives — which is the whole point of the setting and so belongs in the row.
      src="$(voice_narrate_source)"
      case "$src" in
        say)     shape="a conclusion, each time one is named (SAY[…]) — silence otherwise" ;;
        insight) shape="a named conclusion, or a summarized guess at an untagged block" ;;
        prose)   shape="the assistant's own sentence from before each step" ;;
        *)       if voice_cfg_bool voice.autoplay.narrate_intent true; then
                   shape="every step twice — one fact line before it, one after"
                 else
                   shape="one fact line per step, after it only (narrate_intent is off)"
                 fi ;;
      esac
      # The two throttles are 0 = off as shipped, and a `0s apart, 0 max/turn` row read as broken.
      # Named only when a number is actually set — where they matter, since either one silently
      # drops part of what this level promises to say.
      g="$(voice_narrate_gap)"; ncap="$(voice_narrate_cap)"; thr=""
      (( g > 0 ))    && thr="$thr · ≥${g}s apart"
      (( ncap > 0 )) && thr="$thr · ≤$ncap lines/turn"
      printf 'chattiness        %s %s(ack + closing line + %s%s)%s\n' \
        "$chat" "$c_dim" "$shape" "$thr" "$c_off"
    else
      printf 'chattiness        %s %s← narrate is off, so nothing speaks mid-turn — the running\n' \
        "$chat" "$c_warn"
      printf '                  commentary is most of `max`. Set voice.autoplay.narrate: true%s\n' "$c_off"
    fi
    printf 'tts               %s / %s\n' "$(voice_cfg voice.tts.provider elevenlabs)" \
      "$(voice_cfg "voice.tts.voice.$(voice_cfg voice.tts.provider elevenlabs)" '(provider default)')"
    printf 'stt               %s\n' "$(voice_cfg voice.stt.provider openai)"
    printf 'summarizer        %s\n' "$(voice_cfg voice.summarizer.provider openai)"
    printf 'sfx               %s\n' "$(voice_cfg voice.sfx.provider elevenlabs)"
    ident="$("$VOICE/identity.sh" text 2>/dev/null || printf '(unresolved)')"
    # The prefix is suppressed for the worktree you are prompting in, so print WHETHER it would be
    # spoken, not just what it would say — "why did it not say the ticket?" is otherwise a mystery.
    if voice_is_focused; then
      printf 'identity          %s %s(not spoken — this is the worktree you are prompting in)%s\n' \
        "$ident" "$c_dim" "$c_off"
    else
      printf 'identity          %s %s(spoken as: %s)%s\n' "$ident" "$c_dim" \
        "$(voice_spoken_form "$ident")" "$c_off"
    fi
    printf '\n'
    "$VOICE/queue.sh" status
    printf '\n'
    # Counted from the catalog, never hardcoded — adding a cue to sfx.sh must not leave this
    # line reporting "8 of 7".
    cues_all="$("$VOICE/sfx.sh" list 2>/dev/null | tail -n +2 | grep -c . || printf 0)"
    cues_have="$("$VOICE/sfx.sh" list 2>/dev/null | tail -n +2 | grep -vc 'not generated' || printf 0)"
    printf 'cues              %s of %s generated %s(aiworks voice cues)%s\n' \
      "$cues_have" "$cues_all" "$c_dim" "$c_off"
    printf 'cache             %s in %s\n' "$(du -sh "$VOICE_AUDIO_DIR" 2>/dev/null | awk '{print $1}')" "$VOICE_AUDIO_DIR"
    # Which credentials are present — the NAMES only. Never the values, and never by printing
    # the file: this is the same rule as everywhere else in the workspace (see CLAUDE.md).
    voice_load_credentials
    printf 'credentials       '
    for v in ELEVENLABS_API_KEY OPENAI_API_KEY GEMINI_VOICE_API_KEY CARTESIA_API_KEY; do
      if [[ -n "${!v:-}" ]]; then printf '%s%s%s ' "$c_ok" "${v%_API_KEY}" "$c_off"
      else printf '%s%s-%s ' "$c_dim" "${v%_API_KEY}" "$c_off"; fi
    done
    printf '\n'
    ;;

  setup)
    # DELIBERATELY NOT part of `aiworks setup`. Voice is `th`-only, off by default and personal, so
    # installing ffmpeg and a GUI automation app for every teammate — to support a feature that is
    # inert for them — would be spending their time and disk on someone else's preference. Whoever
    # opts in runs this.
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    set +e
    printf 'Voice prerequisites\n\n'

    lang="$(voice_language)"
    if [[ "$lang" != "th" ]]; then
      printf '%s! language resolves to %s — voice is th-only and will stay silent.%s\n' "$c_warn" "$lang" "$c_off"
      printf '  Set `language: th` in workspace.config.local.yaml to opt in.\n\n'
    fi

    # ffmpeg: cue mixing, Gemini's raw PCM, and every recording. Not optional for anything here.
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
      printf '  %s✓%s ffmpeg\n' "$c_ok" "$c_off"
    elif command -v brew >/dev/null 2>&1; then
      printf '  installing ffmpeg…\n'; brew install ffmpeg >/dev/null 2>&1 \
        && printf '  %s✓%s ffmpeg\n' "$c_ok" "$c_off" || printf '  %s✗ brew install ffmpeg failed%s\n' "$c_err" "$c_off"
    else
      printf '  %s✗ ffmpeg missing and no brew — install it by hand%s\n' "$c_err" "$c_off"
    fi

    # The credential file, created EMPTY if absent. Never populated by this script: a key belongs
    # to a person, and prompting for one here would put it in a shell history.
    envf="$HOME/.config/aiworks/voice.env"
    if [[ -f "$envf" ]]; then
      printf '  %s✓%s %s\n' "$c_ok" "$c_off" "$envf"
    else
      mkdir -p "$(dirname "$envf")"
      { sed -n '1,20p' "$VOICE/.env.example" | sed 's/^# Voice adapter — PER-CLONE.*/# Voice adapter credentials — machine-global./'
        printf '\nELEVENLABS_API_KEY=\nOPENAI_API_KEY=\nGEMINI_VOICE_API_KEY=\nCARTESIA_API_KEY=\n'
      } > "$envf"
      chmod 600 "$envf"
      printf '  %s✓%s created %s (mode 600) — paste your keys into it\n' "$c_ok" "$c_off" "$envf"
    fi
    voice_load_credentials
    for v in ELEVENLABS_API_KEY OPENAI_API_KEY GEMINI_VOICE_API_KEY CARTESIA_API_KEY; do
      [[ -n "${!v:-}" ]] && printf '      %s✓%s %s\n' "$c_ok" "$c_off" "$v" \
                         || printf '      %s·%s %s (unset)\n' "$c_dim" "$c_off" "$v"
    done

    # The cue catalog: one-off, then free forever. Needs a key, so it comes after the check above.
    if [[ "$lang" == "th" ]] && voice_cfg_bool voice.enabled false; then
      printf '  generating the sound cues…\n'
      "$VOICE/sfx.sh" generate >/dev/null 2>&1 \
        && printf '  %s✓%s cues\n' "$c_ok" "$c_off" \
        || printf '  %s! cues not generated — check the key, then: aiworks voice cues%s\n' "$c_warn" "$c_off"
    else
      printf '  %s·%s cues skipped (voice.enabled is false)\n' "$c_dim" "$c_off"
    fi

    # Hammerspoon is push-to-talk only, and it is a GUI app — never installed silently.
    printf '\nPush-to-talk (optional)\n'
    if [[ -d /Applications/Hammerspoon.app ]]; then
      printf '  %s✓%s Hammerspoon installed — next: aiworks voice ptt install\n' "$c_ok" "$c_off"
    else
      printf '  %s·%s not set up. It needs a GUI app plus Accessibility and Microphone consent,\n' "$c_dim" "$c_off"
      printf '    so it is opt-in even here:\n'
      printf '      brew install --cask hammerspoon && aiworks voice ptt install\n'
    fi

    printf '\nThen: %saiworks voice test%s\n' "$c_ok" "$c_off"
    ;;

  audition)
    # Picking a chattiness level is decided BY EAR, not from a table of character counts — and it
    # should not cost four config edits and four restarts to hear four options. This speaks the
    # same request at all four, in order, announcing each one first.
    #
    # What it CANNOT audition is `max`'s step narration: that one only exists inside a running turn,
    # and faking it here would be a demo of a thing you have not actually turned on.
    [[ $# -gt 0 ]] || die "usage: aiworks voice audition \"the prompt to react to\" [--kind ack|report]"
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    set +e
    kind=ack; text=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --kind) kind="${2:?}"; shift 2 ;;
        *) text="${text:+$text }$1"; shift ;;
      esac
    done
    if voice_is_muted; then
      printf '%smuted (%s) — unmute first, or you will audition four silences%s\n' \
        "$c_warn" "$(voice_mute_reason)" "$c_off"; exit 0
    fi
    printf '%s%s%s  (%s)\n\n' "$c_dim" "$text" "$c_off" "$kind"
    for lvl in terse balanced chatty max; do
      line="$(VOICE_CHATTINESS="$lvl" "$VOICE/summarize.sh" --kind "$kind" --particle 'ค่ะ' "$text" 2>/dev/null)"
      if [[ -z "$line" ]]; then
        printf '  %-9s %s(the summarizer returned nothing)%s\n' "$lvl" "$c_warn" "$c_off"; continue
      fi
      # wc -m: the cap is in characters and Thai is multibyte, so bytes would read 3× too long.
      printf '  %-9s %s %s(%s chars)%s\n' "$lvl" "$line" "$c_dim" \
        "$(printf '%s' "$line" | wc -m | tr -d ' ')" "$c_off"
      "$VOICE/speak.sh" --sync --no-prefix "$line" >/dev/null 2>&1
    done
    printf '\nSet the one you want: %svoice.autoplay.chattiness%s in workspace.config.local.yaml\n' "$c_ok" "$c_off"
    ;;

  say)
    [[ $# -gt 0 ]] || die "usage: aiworks voice say \"ข้อความ\""
    # Muted, speak.sh exits 0 in silence — correct for a hook, confusing for a command you typed.
    # So say so here: an interactive command that appears to do nothing is a bug report waiting
    # to happen.
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    set +e
    if voice_is_muted; then
      printf '%smuted — nothing will be spoken or synthesized (aiworks voice mute off)%s\n' \
        "$c_warn" "$c_off"; exit 0
    fi
    exec "$VOICE/speak.sh" --sync "$@"
    ;;

  ptt)
    sub="${1:-status}"; [[ $# -gt 0 ]] && shift
    case "$sub" in
      install)
        # GENERATED, never hand-edited: the template lives in scripts/voice/voice-ptt.lua so it
        # is reviewed and versioned with the rest of the adapter, and the only thing injected is
        # the absolute path to this checkout's scripts.
        hsdir="$HOME/.hammerspoon"; init="$hsdir/init.lua"; target="$hsdir/voice-ptt.lua"
        mkdir -p "$hsdir" || die "could not create $hsdir"
        # The chord is baked in at generate time rather than read by the Lua at runtime: the
        # handler must not shell out to a YAML reader on every key event.
        . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
        set +e
        hotkey="$(voice_cfg voice.push_to_talk.hotkey right_cmd+right_alt)"
        sed -e "s|@@VOICE_DIR@@|$VOICE|g" -e "s|@@HOTKEY@@|$hotkey|g" \
          "$VOICE/voice-ptt.lua" > "$target" || die "could not write $target"
        printf '%s✓%s wrote %s  %s(chord: %s)%s\n' "$c_ok" "$c_off" "$target" "$c_dim" "$hotkey" "$c_off"

        # UNDECLARED-GLOBAL LINT. `luac -p` passes a reference to a local that is declared LATER,
        # because Lua compiles it as a global read and it only fails at RUNTIME — which is how
        # `rawFlags` used before its declaration killed every key event while looking fine to
        # every check. The bytecode names each global it reads, so anything outside this
        # allow-list is a typo or an ordering bug, caught here instead of by the user.
        if command -v luac >/dev/null 2>&1; then
          allowed='^(hs|os|io|string|table|math|pcall|tostring|tonumber|type|ipairs|pairs|require|print|select|error|assert|setmetatable|rawget)$'
          strays="$(luac -l -p "$target" 2>/dev/null \
                    | sed -nE 's/.*GETTABUP.*_ENV "([A-Za-z_][A-Za-z0-9_]*)".*/\1/p' \
                    | sort -u | grep -Ev "$allowed" || true)"
          if [[ -n "$strays" ]]; then
            printf '   %s✗ reads undefined global(s): %s%s\n' "$c_err" "$(printf '%s' "$strays" | tr '\n' ' ')" "$c_off"
            printf '     Almost always a local used ABOVE its declaration — it will fail at runtime,\n'
            printf '     inside the key handler, where nothing surfaces the error.\n'
            die "refusing to install a handler that will error on every key event"
          fi
          printf '   %s✓%s no undefined globals\n' "$c_ok" "$c_off"
        fi
        case "$hotkey" in
          *fn*) printf '   %s! `fn` only reaches macOS from the BUILT-IN keyboard — an external one\n' "$c_warn"
                printf '     never sends it (measured). Use right_cmd+right_alt to work everywhere.%s\n' "$c_off" ;;
        esac
        if ! grep -q 'voice-ptt' "$init" 2>/dev/null; then
          printf '\n-- Sunmi push-to-talk (generated by `aiworks voice ptt install`)\nrequire("voice-ptt")\n' >> "$init"
          printf '%s✓%s added require("voice-ptt") to %s\n' "$c_ok" "$c_off" "$init"
        else
          printf '  %s already required from init.lua%s\n' "$c_dim" "$c_off"
        fi

        printf '\n%sManual steps — none of these can be scripted:%s\n' "$c_warn" "$c_off"
        if [[ -d /Applications/Hammerspoon.app ]]; then
          printf '  %s✓%s Hammerspoon installed\n' "$c_ok" "$c_off"
        else
          printf '  1. brew install --cask hammerspoon      (not installed yet)\n'
        fi
        printf '  2. Open Hammerspoon → grant it ACCESSIBILITY (System Settings → Privacy &\n'
        printf '     Security → Accessibility). Without it the hotkey cannot see key events.\n'
        printf '  3. Grant MICROPHONE access when first prompted — to the process that RECORDS.\n'
        printf '     ffmpeg is spawned by Hammerspoon here, so the grant lands on Hammerspoon.\n'
        # Only relevant to an fn chord — printing it for a right_cmd+right_alt setup would be
        # telling someone to change a system setting their hotkey never touches.
        case "$hotkey" in
          *fn*)
            printf '  4. defaults write com.apple.HIToolbox AppleFnUsageType -int 0\n'
            printf '     %s(Globe → Do Nothing) then LOG OUT AND BACK IN. Without it a bare fn tap\n' "$c_dim"
            printf '     changes the input source, so a mistimed release flips your keyboard layout\n'
            printf '     mid-sentence. ⌃⌥Space still switches language.%s\n' "$c_off" ;;
        esac
        # RELOAD HERE, automatically. Writing the file is not installing it: Hammerspoon reads
        # its config only at launch, so the first run of this command left a perfectly good
        # handler on disk that had never executed — and the hotkey "did nothing" with every
        # check passing. Never leave that gap for the next person.
        if pgrep -x Hammerspoon >/dev/null 2>&1; then
          printf '\nReloading Hammerspoon so the handler actually runs…\n'
          pkill -x Hammerspoon 2>/dev/null && sleep 2
          open -a Hammerspoon >/dev/null 2>&1 && sleep 6
          logf="$HOME/.cache/aiworks/voice/ptt/hammerspoon.log"
          if grep -q 'loaded OK' "$logf" 2>/dev/null; then
            printf '  %s✓%s handler loaded — %s\n' "$c_ok" "$c_off" "$(grep -c 'loaded OK' "$logf") load(s) logged"
            grep -q 'FATAL' "$logf" && printf '  %s✗ see: aiworks voice ptt doctor%s\n' "$c_err" "$c_off"
          else
            printf '  %s! nothing logged — run: aiworks voice ptt doctor%s\n' "$c_warn" "$c_off"
          fi
        else
          printf '\n  5. Open Hammerspoon (it is not running — nothing loads until it is).\n'
        fi

        printf '\nThen: hold %s, speak, release.\n' "$hotkey"
        printf '  aiworks voice ptt keys        what your keyboard actually reports\n'
        printf '  aiworks voice ptt simulate    prove the pipeline without a key press\n'
        printf '  aiworks voice ptt doctor      every prerequisite, in the order it breaks\n'
        printf '  aiworks voice mic-check       if dictation comes back empty or hallucinated\n'
        ;;
      debug)
        # Turn on per-event logging in the key handler. Off by default: it writes a line for
        # every modifier press on the machine, which is a lot of lines.
        f="$HOME/.cache/aiworks/voice/ptt/debug"
        mkdir -p "$(dirname "$f")"
        case "${1:-on}" in
          on)  : > "$f"; printf 'key logging ON — hold the combo, then: aiworks voice ptt doctor\n' ;;
          off) rm -f "$f"; printf 'key logging off\n' ;;
          *)   die "usage: aiworks voice ptt debug [on|off]" ;;
        esac
        ;;

      doctor)
        # Everything that has to be true for the hotkey to fire, in the order it breaks.
        log="$HOME/.cache/aiworks/voice/ptt/hammerspoon.log"
        printf '%s1. Hammerspoon%s\n' "$c_dim" "$c_off"
        [[ -d /Applications/Hammerspoon.app ]] \
          && printf '   installed  %s✓%s\n' "$c_ok" "$c_off" \
          || printf '   installed  %s✗ brew install --cask hammerspoon%s\n' "$c_err" "$c_off"
        pgrep -x Hammerspoon >/dev/null \
          && printf '   running    %s✓ pid %s%s\n' "$c_ok" "$(pgrep -x Hammerspoon)" "$c_off" \
          || printf '   running    %s✗ open it%s\n' "$c_err" "$c_off"

        printf '\n%s2. Our handler%s\n' "$c_dim" "$c_off"
        [[ -f "$HOME/.hammerspoon/voice-ptt.lua" ]] \
          && printf '   installed  %s✓%s %s\n' "$c_ok" "$c_off" "$HOME/.hammerspoon/voice-ptt.lua" \
          || printf '   installed  %s✗ aiworks voice ptt install%s\n' "$c_err" "$c_off"
        grep -q 'require("voice-ptt")' "$HOME/.hammerspoon/init.lua" 2>/dev/null \
          && printf '   required   %s✓ from init.lua%s\n' "$c_ok" "$c_off" \
          || printf '   required   %s✗ init.lua does not require it%s\n' "$c_err" "$c_off"
        if command -v luac >/dev/null 2>&1; then
          luac -p "$HOME/.hammerspoon/voice-ptt.lua" 2>/dev/null \
            && printf '   syntax     %s✓%s\n' "$c_ok" "$c_off" \
            || printf '   syntax     %s✗ luac -p says it is broken%s\n' "$c_err" "$c_off"
        fi

        printf '\n%s3. macOS permissions + settings%s\n' "$c_dim" "$c_off"
        fnusage="$(defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || printf 'unset')"
        if [[ "$fnusage" == "0" ]]; then
          printf '   fn key     %s✓ Do Nothing%s\n' "$c_ok" "$c_off"
        else
          printf '   fn key     %s! AppleFnUsageType=%s%s — a bare fn tap changes the input source,\n' \
            "$c_warn" "$fnusage" "$c_off"
          printf '              so a mistimed release flips your keyboard layout. Fix:\n'
          printf '              defaults write com.apple.HIToolbox AppleFnUsageType -int 0   then LOG OUT/IN\n'
        fi
        printf '   %saccessibility: read from the handler log below — an eventtap without it\n' "$c_dim"
        printf '   starts fine and then receives NOTHING, which is the usual cause.%s\n' "$c_off"

        # A callback error is invisible everywhere else: the tap stays "enabled", the log stays
        # empty, and only Hammerspoon's in-memory console knows. This is where the real cause of
        # a dead hotkey turned out to be, so it is checked before anything else is believed.
        printf '\n%s4. Callback errors (Hammerspoon console)%s\n' "$c_dim" "$c_off"
        if pgrep -x Hammerspoon >/dev/null; then
          cerr="$(osascript -e 'tell application "Hammerspoon" to execute lua code "local c = tostring(hs.console.getConsole()); local i = c:find(\"eventtap callback error\"); return i and c:sub(i, i+160) or \"none\""' 2>&1 | head -1)"
          case "$cerr" in
            none) printf '   %s✓ none%s\n' "$c_ok" "$c_off" ;;
            *"currently disabled"*) printf '   %s(console unreadable — `aiworks voice ptt debug on` then `… ptt reload`)%s\n' "$c_dim" "$c_off" ;;
            *) printf '   %s✗ %s%s\n' "$c_err" "$cerr" "$c_off"
               printf '     The tap still reports "enabled" and the log stays empty — a callback that\n'
               printf '     throws logs only here. Usually a local used above its declaration.\n' ;;
          esac
        fi

        printf '\n%s5. Handler log%s  %s\n' "$c_dim" "$c_off" "$log"
        if [[ -s "$log" ]]; then tail -25 "$log" | sed 's/^/   /'
        else printf '   %s(empty — the handler has not run since it was installed. Reload the\n' "$c_warn"
             printf '   Hammerspoon config: its menu-bar icon → Reload Config)%s\n' "$c_off"
        fi

        # Asked over the AppleScript bridge, NOT the `hs` CLI: a Homebrew `hs` on PATH is a
        # different build from the one Hammerspoon's cliInstall serves, and it hangs forever
        # rather than erroring. The bridge is only open in debug mode.
        printf "\n%s6. Live state%s\n" "$c_dim" "$c_off"
        if pgrep -x Hammerspoon >/dev/null; then
          out="$(osascript -e 'tell application "Hammerspoon" to execute lua code "return require(\"voice-ptt\").selftest()"' 2>&1 | head -1)"
          case "$out" in
            *accessibility=true*) printf '   %s✓%s %s\n' "$c_ok" "$c_off" "$out" ;;
            *accessibility=false*) printf '   %s✗ ACCESSIBILITY NOT GRANTED — the taps receive nothing.%s\n' "$c_err" "$c_off"
                                   printf '     System Settings → Privacy & Security → Accessibility → Hammerspoon\n' ;;
            *"currently disabled"*) printf '   %s(bridge closed — `aiworks voice ptt debug on` then `… ptt reload`)%s\n' "$c_dim" "$c_off" ;;
            *) printf '   %s%s%s\n' "$c_dim" "${out:-no answer}" "$c_off" ;;
          esac
        else
          printf '   %s(Hammerspoon not running)%s\n' "$c_dim" "$c_off"
        fi

        printf '\n%sTo see what your keys actually report:%s\n' "$c_warn" "$c_off"
        printf '  aiworks voice ptt keys        hold the combo while it watches\n'
        printf '  aiworks voice ptt simulate    prove the pipeline with no key press at all\n'
        ;;

      simulate)
        # Prove the pipeline without a key press. Needs the AppleScript bridge, which the
        # handler only enables in debug mode.
        secs="${1:-4}"
        pgrep -x Hammerspoon >/dev/null || die "Hammerspoon is not running"
        printf 'holding for %ss — speak now…\n' "$secs"
        osascript -e "tell application \"Hammerspoon\" to execute lua code \"return require('voice-ptt').simulate($secs)\"" 2>&1 | head -2
        sleep "$((secs + 8))"
        printf '\n=== handler log ===\n'
        tail -12 "$HOME/.cache/aiworks/voice/ptt/hammerspoon.log" | sed 's/^/  /'
        ;;

      reload)
        # Hammerspoon reloads its config only on request, and `install` just writes the file —
        # forgetting this step is why the hotkey appeared to do nothing at all. Its own `quit`
        # goes through AppleScript, which is off by default, so pkill is the reliable way.
        pkill -x Hammerspoon 2>/dev/null && sleep 2
        open -a Hammerspoon || die "could not launch Hammerspoon"
        sleep 6
        printf 'reloaded — pid %s\n' "$(pgrep -x Hammerspoon || printf NONE)"
        tail -6 "$HOME/.cache/aiworks/voice/ptt/hammerspoon.log" 2>/dev/null | sed 's/^/  /'
        ;;

      keys)
        # Watch what the keyboard actually reports, live. This is the answer to "did I hold the
        # right keys?" — it prints the keycode and every flag, exactly as macOS delivered it.
        f="$HOME/.cache/aiworks/voice/ptt/debug"
        mkdir -p "$(dirname "$f")"; : > "$f"
        grep -q 'AppleScript bridge ON' "$HOME/.cache/aiworks/voice/ptt/hammerspoon.log" 2>/dev/null \
          || printf '%s(debug was off when the handler loaded — run `aiworks voice ptt reload` first)%s\n' "$c_warn" "$c_off"
        printf 'Hold your combo now. Watching for %ss…\n\n' "${1:-15}"
        : > "$HOME/.cache/aiworks/voice/ptt/keys.tmp"
        n0="$(wc -l < "$HOME/.cache/aiworks/voice/ptt/hammerspoon.log" 2>/dev/null || printf 0)"
        sleep "${1:-15}"
        tail -n "+$((n0 + 1))" "$HOME/.cache/aiworks/voice/ptt/hammerspoon.log" 2>/dev/null \
          | grep -E 'flagsChanged|keyDown|hold|ptt' | sed 's/^/  /' \
          || printf '  (nothing arrived — the tap is not receiving events)\n'
        # Report against the chord that is actually configured, not a hardcoded one.
        . "$VOICE/lib.sh" 2>/dev/null; set +e
        hk="$(voice_cfg voice.push_to_talk.hotkey right_cmd+right_alt)"
        printf '\n%sWanted: keys_down=[%s] while you hold it.%s\n' "$c_dim" "$(printf '%s' "$hk" | tr '+' '\n' | grep -v '^fn$' | sort | paste -sd+ -)" "$c_off"
        printf '%skeys_down comes from the raw IOKit side-bits, so Left ⌘ (55) and Right ⌘ (54)\n' "$c_dim"
        printf 'are distinguishable even though both set the same `cmd` flag.%s\n' "$c_off"
        printf '\n%sIf nothing arrived at all, check for a callback error:%s\n' "$c_dim" "$c_off"
        printf '  osascript -e '\''tell application "Hammerspoon" to execute lua code "return tostring(hs.console.getConsole()):sub(-800)"'\''\n'
        ;;

      status) exec "$VOICE/ptt.sh" status ;;
      *)      exec "$VOICE/ptt.sh" "$sub" "$@" ;;
    esac
    ;;

  cues)  exec "$VOICE/sfx.sh" -v generate "$@" ;;

  mic-check)
    # Calibrate the push-to-talk silence thresholds against YOUR voice and room. They cannot be
    # shipped correct: two silent recordings on the dev machine measured 17 dB apart, so the
    # only honest defaults are conservative ones plus this command.
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    set +e
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required (brew install ffmpeg)"
    secs="${1:-4}"
    idx="$("$VOICE/ptt.sh" status | sed -nE 's/^microphone \[([0-9]+)\].*/\1/p')"
    name="$("$VOICE/ptt.sh" status | sed -nE 's/^microphone \[[0-9]+\] (.*)/\1/p')"
    tmp="$(mktemp -d -t micchk)"; trap 'rm -rf "$tmp"' EXIT
    measure() {   # LABEL FILE
      vd="$(ffmpeg -hide_banner -i "$2" -af volumedetect -f null - 2>&1)"
      printf '  %-22s mean %8s   peak %8s\n' "$1" \
        "$(printf '%s' "$vd" | sed -nE 's/.*mean_volume: (-?[0-9.]+) dB.*/\1dB/p' | head -1)" \
        "$(printf '%s' "$vd" | sed -nE 's/.*max_volume: (-?[0-9.]+) dB.*/\1dB/p' | head -1)"
    }
    printf 'microphone: [%s] %s\n\n' "$idx" "$name"
    printf 'Stay QUIET for %ss…\n' "$secs"
    ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$idx" -t "$secs" -ac 1 -ar 16000 \
      -y "$tmp/quiet.wav" 2>/dev/null
    measure "silence" "$tmp/quiet.wav"
    printf '\nNow SPEAK normally for %ss (say a sentence you would dictate)…\n' "$secs"
    ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$idx" -t "$secs" -ac 1 -ar 16000 \
      -y "$tmp/speech.wav" 2>/dev/null
    measure "speech" "$tmp/speech.wav"
    printf '\ntranscript: %s\n' "$("$VOICE/listen.sh" "$tmp/speech.wav" 2>/dev/null || printf '(none — discarded by a guard)')"
    printf '\nSet the floors BETWEEN the two rows, in workspace.config.local.yaml:\n'
    printf '  voice:\n    push_to_talk:\n      silence_db: <between the two means>\n      silence_peak_db: <between the two peaks>\n'
    printf '%sA recording is treated as silence only when BOTH are below their floor.%s\n' "$c_dim" "$c_off"
    ;;

  test)
    # A live end-to-end check with the timings printed, so "is it working?" has an answer that
    # is not "listen and hope".
    . "$VOICE/lib.sh" 2>/dev/null || die "could not load $VOICE/lib.sh"
    set +e
    if [[ "$(voice_language)" != "th" ]]; then
      printf '%svoice is th-only and this workspace resolves to %s — nothing to test%s\n' \
        "$c_warn" "$(voice_language)" "$c_off"; exit 0
    fi
    voice_cfg_bool voice.enabled false || { printf '%svoice.enabled is false%s\n' "$c_warn" "$c_off"; exit 0; }
    if voice_is_muted; then
      [[ "$(voice_mute_reason)" == os ]] \
        && printf '%smuted — the system output is muted, unmute the machine%s\n' "$c_warn" "$c_off" \
        || printf '%smuted — run: aiworks voice mute off%s\n' "$c_warn" "$c_off"
      exit 0
    fi
    t0="$(python3 -c 'import time;print(time.time())')"
    el() { python3 -c "import time;print(time.time()-$t0)"; }
    # Backgrounded, like the real hook does it — playing the cue synchronously would fold its
    # own half-second into every number below and report a shape the ack never has.
    ( "$VOICE/sfx.sh" play ack 2>/dev/null & ) 2>/dev/null
    printf 'cue started       %.2fs\n' "$(el)"
    # A concrete request on purpose: given a vague one the summarizer has nothing to name and
    # will reach for a plausible file name, which reads as a hallucination in a smoke test.
    #
    # The particle is DERIVED from the voice, like every other caller does it (ack.sh, milestone.sh,
    # notify-voice.sh, narrate.sh). It used to be hardcoded to 'ครับ', so the one command whose whole
    # job is "prove you can hear it" spoke the wrong gender on a female voice — which is what this
    # feature calls a real bug, coming out of its own smoke test. Heard, not read: the line came back
    # "ได้ค่ะ … ก่อนครับ", both genders in one sentence.
    . "$VOICE/variety.sh" 2>/dev/null
    voice_load_tts_provider
    line="$("$VOICE/summarize.sh" --particle "$(variety_particle "$(voice_tts_gender)")" \
            "ช่วยเช็ค commission calculator ใน agent-webservice ให้หน่อย" 2>/dev/null)"
    printf 'summarizer done   %.2fs  %s\n' "$(el)" "${line:-(failed)}"
    [[ -n "$line" ]] || die "the summarizer returned nothing — check voice.summarizer.provider and its key"
    "$VOICE/speak.sh" --sync --no-prefix "$line"
    # --sync blocks through playback, so this is "finished being heard", not "started speaking".
    printf 'finished speaking %.2fs  %s(includes the audio playing)%s\n' "$(el)" "$c_dim" "$c_off"
    printf '%sok%s\n' "$c_ok" "$c_off"
    ;;

  help|-h|--help) usage ;;
  *) die "unknown subcommand ${cmd@Q} (try: aiworks voice help)" ;;
esac
