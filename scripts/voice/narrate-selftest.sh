#!/usr/bin/env bash
#
# Regression suite for the `max` mid-turn voice: narrate.sh (step facts + thresholds) and gate.sh
# (the "waiting for you" voice). tool-fact.py has its own fixtures — `tool-fact.py --selftest` —
# and this suite runs them too, so one command covers the whole channel.
#
# Run:  scripts/voice/narrate-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Everything runs against a THROWAWAY tree in a temp dir with its OWN workspace.config.yaml
# (`language: th`, voice on, chattiness max) and a STUBBED speak.sh, so the suite is portable, it
# never reads the machine's real voice settings, and it costs nothing — no synthesis, no API call.
# Same doctrine as guards-selftest.sh.
#
# WHY SESSION IDS ARE RUN-SCOPED: narration state (the dedupe hash, the rate stamp, the per-turn
# count, the fired thresholds) is machine-global and keyed by session id, so fixed ids would leak the
# PREVIOUS run's state into this one — which is exactly how this suite first went red on its own
# second run.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # the workspace root
T="$(mktemp -d -t voice-narrate-selftest)"
trap 'rm -rf "$T"' EXIT

rm -rf "$T"; mkdir -p "$T/scripts" "$T/cache/cue" "$T/bin"
cp -R "$SRC/scripts/voice" "$T/scripts/voice"
# ISOLATE THE MACHINE'S STATE, both halves of it. Narration state, the spool and the hand mute all
# live under VOICE_CACHE_HOME, and the OS mute is read from the laptop's audio device — so without
# these two lines the suite goes red for everyone whose machine happens to be muted while they run
# it, which is exactly the state you are in when you are working on mute.
export VOICE_CACHE_HOME="$T/cache"
export VOICE_OS_MUTED=0
# A fake afplay, so "did a sound actually play?" is a file test rather than a thing you listen for.
cat > "$T/bin/afplay" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${VOICE_CACHE_HOME}/played"
STUB
chmod +x "$T/bin/afplay"
export PATH="$T/bin:$PATH"
# narrate_gap: 0 and a small cap are the SHIPPED shape (0 = no floor) plus a cap low enough to be
# provable in a handful of calls. The two throttles are switched on and off per case by setgap/setcap
# below, because "off by default" and "still works when set" are both regressions worth catching.
cat > "$T/workspace.config.yaml" <<'YAML'
language: th
voice:
  enabled: true
  autoplay:
    enabled: true
    chattiness: max
    narrate_source: facts
    narrate_intent: true
    narrate_gap: 0
    narrate_max_per_turn: 3
    long_turn_seconds: 300
YAML
# `narrate_source: facts` is set EXPLICITLY, and is no longer the shipped default (`insight` is):
# most cases below exercise the step sources — the thresholds, the floors, the char caps, the mute —
# and they are cheaper and more deterministic to assert than a summarizer call. The insight section
# flips the key for its own cases, and one case asserts what the default resolves to when the key is
# absent entirely, which is the thing a wrong default would otherwise hide.
cfgset() { # cfgset <key> <value> — the throwaway config is the only way to reach a config-only dial
  sed -i.bak "s/^\( *\)$1: .*/\1$1: $2/" "$T/workspace.config.yaml"
}
# Stub speak.sh: prove the handoff, the kind, the cue and the exact line — and spend nothing.
# It writes the line TWICE, to stdout and to a log: most cases call narrate.sh directly and read
# stdout, but the hook cases fork a DETACHED narrate.sh whose stdout goes nowhere, so those need a
# file to watch instead.
cat > "$T/scripts/voice/speak.sh" <<'STUB'
#!/usr/bin/env bash
kind=""; cue=""
# --mix / --cue-volume take a VALUE and must be consumed as a pair. When they were swallowed by the
# generic `-*) shift` they left their operands in $*, and a cue'd line came out as
# "SPOKE[milestone/red]: under --cue-volume 0.15 ต้นเหตุ…" — the stub inventing an argument bug the
# real speak.sh does not have.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;; --cue) cue="$2"; shift 2 ;;
    --mix|--cue-volume|--mood|--provider|--voice|--out) shift 2 ;;
    -*) shift ;; *) break ;;
  esac
done
printf 'SPOKE[%s%s]: %s\n' "$kind" "${cue:+/$cue}" "$*" \
  | tee -a "${VOICE_SPOKE_LOG:-${VOICE_CACHE_HOME}/spoke.log}"
STUB
chmod +x "$T/scripts/voice/speak.sh"
# Stub the summarizer as well. narrate.sh never calls it (a fact line is a template, and prose is
# the transcript's own sentence) — but the ack-cue case below runs the REAL UserPromptSubmit hook,
# which forks ack.sh, and that one does. Without this the suite would make a paid LLM call.
# It also LOGS every call, which is how "no summarizer call was made" becomes a file test rather
# than an assumption — the insight source's cheap length gate exists precisely to avoid paying for a
# block that cannot contain a conclusion, and an assertion on the spoken line alone cannot see that.
cat > "$T/scripts/voice/summarize.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${VOICE_CACHE_HOME}/summarized.log"
printf '%s\n' "${VOICE_TEST_SUMMARY:-กำลังไปดูให้ค่ะ}"
STUB
chmod +x "$T/scripts/voice/summarize.sh"
N="$T/scripts/voice/narrate.sh"
G="$T/scripts/voice/gate.sh"
RUN="$$"          # session ids must be unique per run: narration state is machine-global
_s() { printf '%s-%s' "$RUN" "$1"; }

# ── synthetic transcripts ─────────────────────────────────────────────────────────
mk() { # mk <file> <json-lines...>
  local f="$1"; shift; : > "$f"; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
txt() { jq -cn --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; }
tool() { jq -cn --arg n "$1" --arg p "$2" '{type:"assistant",message:{content:[{type:"tool_use",name:$n,input:{file_path:$p}}]}}'; }

PROSE='อ่าน `queue.sh` ก่อน แล้วค่อยแก้ cadence — ตรงนี้คือจุดที่ drop rule อยู่

```bash
echo skip me
```

| a | b |
|---|---|'
mk "$T/t-prose.jsonl"    "$(txt "$PROSE")" "$(tool Read "$SRC/scripts/voice/queue.sh")"
mk "$T/t-tag.jsonl"      "$(txt 'VOICE[ship]: merged เข้า develop แล้วค่ะ')" "$(tool Read /x/y.sh)"
mk "$T/t-noprose.jsonl"  "$(tool Read /a/b/summarize.sh)"
mk "$T/t-heading.jsonl"  "$(txt '## ผลการตรวจ

- **พบ 3 จุด** ที่ `chattiness` ถูกอ่าน
- ต่อไปจะแก้ `lib.sh`')" "$(tool Grep chattiness)"

# ── synthetic hook payloads (what PostToolUse actually sends) ──────────────────────
pay() { # pay <file> <tool> <input-json> <response-json> [event]
  jq -n --arg n "$2" --argjson i "$3" --argjson r "$4" --arg e "${5:-PostToolUse}" \
    '{session_id:"x",hook_event_name:$e,tool_name:$n,tool_input:$i,tool_response:$r}' > "$1"
}
pay "$T/p-read.json"  Read '{"file_path":"/a/b/queue.sh"}' '"l1\nl2\nl3"'
pay "$T/p-green.json" Bash '{"command":"cargo test --lib"}' '"test result: ok. 42 passed; 0 failed"'
pay "$T/p-red.json"   Bash '{"command":"cargo test --lib"}' '"error: could not compile"' PostToolUseFailure
pay "$T/p-skip.json"  TodoWrite '{}' '"ok"'
pay "$T/p-grep.json"  Grep '{"pattern":"voice_cfg"}' '"a\nb\nc\nd"'
# The BEFORE half of a step: a PreToolUse payload has no tool_response at all.
pay "$T/p-pre-read.json" Read '{"file_path":"/a/b/queue.sh"}'  null PreToolUse
pay "$T/p-pre-bash.json" Bash '{"command":"cargo test --lib"}' null PreToolUse

pass=0; fail=0
ck() { # ck <label> <expect-substring|EMPTY> <actual>
  if [[ "$2" == "EMPTY" ]]; then
    if [[ -z "${3//[[:space:]]/}" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1 — expected silence, got: $3"; fail=$((fail+1)); fi
  elif [[ "$3" == *"$2"* ]]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1"; echo "        want ⊃ $2"; echo "        got    $3"; fail=$((fail+1)); fi
}
# The payload is consumed (deleted) by narrate.sh, so every case gets its own copy.
run() { # run <session> <payload|-> [transcript|-] [extra args...]
  local s="$1" p="$2" tr="${3:--}"
  # NOT `shift 3 || true`: with two arguments that shift FAILS and leaves argv untouched, so the
  # positional parameters were passed through to narrate.sh as stray operands and it died in its
  # own option parser. Every fact case failed that way while the prose cases (three arguments)
  # passed, which is a very convincing wrong answer.
  shift $(( $# > 3 ? 3 : $# ))
  local args=(--session "$s")
  if [[ "$p" != "-" ]]; then cp "$p" "$T/live.json"; args+=(--payload "$T/live.json"); fi
  [[ "$tr" != "-" ]] && args+=(--transcript "$tr")
  "$N" "${args[@]}" "$@" 2>/dev/null
}

echo "== facts: the line comes from the tool's own response =="
ck "Read says the file and its line count" "SPOKE[narration]: queue.sh อ่านแล้ว 3 บรรทัด" \
   "$(run "$(_s f1)" "$T/p-read.json")"
ck "a green test run says the figure" "SPOKE[narration]: cargo test ผ่าน 42" \
   "$(run "$(_s f2)" "$T/p-green.json")"
ck "grep says how many matches" "voice_cfg เจอ 4 แห่ง" \
   "$(run "$(_s f3)" "$T/p-grep.json")"

echo "== a failed step is a THRESHOLD, not a narration =="
out="$(run "$(_s f4)" "$T/p-red.json")"
ck "red goes out as a milestone with the red cue" "SPOKE[milestone/red]: cargo test ล้ม" "$out"
# Same failing step again, INSIDE the rate floor: a red must bypass the floor, and the repeat is
# itself the news.
out2="$(run "$(_s f4)" "$T/p-red.json")"
ck "the same failure again bypasses the floor and counts itself" "ล้ม ซ้ำรอบ 2" "$out2"

echo "== facts fall back to prose, and prose falls back to facts =="
ck "a skipped tool (no figure) uses the prose instead" "อ่าน queue.sh ก่อน" \
   "$(run "$(_s f5)" "$T/p-skip.json" "$T/t-prose.jsonl")"
ck "narrate_source=prose prefers the sentence" "อ่าน queue.sh ก่อน" \
   "$(VOICE_NARRATE_SOURCE=prose run "$(_s f6)" "$T/p-read.json" "$T/t-prose.jsonl")"
ck "…and still speaks the fact when there is no prose" "queue.sh อ่านแล้ว 3 บรรทัด" \
   "$(VOICE_NARRATE_SOURCE=prose run "$(_s f7)" "$T/p-read.json" "$T/t-noprose.jsonl")"
ck "no fact and no prose is silence" EMPTY \
   "$(run "$(_s f8)" "$T/p-skip.json" "$T/t-noprose.jsonl")"

echo "== the prose path still cleans markdown up =="
ck "heading marks stripped, words kept" "ผลการตรวจ" \
   "$(run "$(_s p1)" - "$T/t-heading.jsonl")"
ck "a VOICE tag is never narrated" EMPTY "$(run "$(_s p2)" - "$T/t-tag.jsonl")"

echo "== dedupe =="
ck "first line speaks" "SPOKE[narration]" "$(run "$(_s d1)" "$T/p-read.json")"
ck "the identical line is not spoken twice" EMPTY "$(run "$(_s d1)" "$T/p-read.json")"
why="$(cp "$T/p-read.json" "$T/live.json"; "$N" -v --session "$(_s d1)" --payload "$T/live.json" 2>&1 >/dev/null | tail -1)"
ck "…and says why with -v" "narrate:" "$why"

echo '== the DEFAULT source is say: only a line the assistant named itself =='
cp "$T/workspace.config.yaml" "$T/cfg0.keep"
sed -i.sed '/narrate_source:/d' "$T/workspace.config.yaml"
ck "no key at all ⇒ say" "say" "$( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_narrate_source )"
cp "$T/cfg0.keep" "$T/workspace.config.yaml"
mk "$T/t-say.jsonl" "$(txt 'ยืนยันแล้ว

SAY[red]: ต้นเหตุคือ queue supersede เหลือ job ใหม่สุดอันเดียว จะเปลี่ยนเป็น backlog ลึกสามค่ะ

ต่อไปจะเขียนเทสต์')" "$(tool Read /a/b/queue.sh)"
mk "$T/t-say-bare.jsonl" "$(txt 'SAY: เจอว่า INNER JOIN ตัด affiliate player ออกทั้งหมดค่ะ')"
cfgset narrate_source say
: > "$T/cache/summarized.log"
SY="$(_s s1)"
ck "a tagged line is spoken VERBATIM, as a milestone with its group's cue" \
   "SPOKE[milestone/red]: ต้นเหตุคือ queue supersede" "$(run "$SY" "$T/p-read.json" "$T/t-say.jsonl")"
# The bug this case exists for: the first version assigned $LINE before the dedupe check and returned
# 1, leaving LINE set — so the tag was spoken a SECOND time as a plain 60-char narration. Found by
# running it twice by hand against a real transcript, which is what a suite is supposed to do for you.
ck "the same tag never speaks twice" EMPTY "$(run "$SY" "$T/p-grep.json" "$T/t-say.jsonl")"
ck "a bare SAY: gets no cue — a sound per conclusion is a metronome again" \
   "SPOKE[milestone]: เจอว่า INNER JOIN" "$(run "$(_s s2)" "$T/p-read.json" "$T/t-say-bare.jsonl")"
ck "…and none of that called the summarizer" 0 "$(wc -l < "$T/cache/summarized.log" | tr -d ' ')"
# No tag ⇒ silence, and NOT a fall-through to the step fact: that is the whole point of the default.
ck "an untagged block is silent under the default" EMPTY \
   "$(run "$(_s s3)" "$T/p-green.json" "$T/t-prose.jsonl")"
cfgset narrate_source facts

echo "== narrate_source: insight adds the summarizer as a FALLBACK to the tag =="
# What the shipped config resolves to, with the key absent. A wrong default here is invisible to
# every other case in this file, because they all set the key.
cp "$T/workspace.config.yaml" "$T/cfg.keep"
ck "an unknown value falls back to the default" "say" \
   "$( . "$T/scripts/voice/lib.sh" 2>/dev/null; VOICE_NARRATE_SOURCE=steps voice_narrate_source )"
cp "$T/cfg.keep" "$T/workspace.config.yaml"
CONC='เจอแล้ว ต้นเหตุคือ queue.sh supersede narration เหลือ job ใหม่สุดต่อ session อันเดียว burst ห้า step
เลยพูดแค่ครั้งเดียว ไม่ใช่ rate floor อย่างที่คิดตอนแรก จะเปลี่ยนเป็น backlog ลึกสามแล้วทิ้งเก่าสุดก่อน'
mk "$T/t-conclusion.jsonl" "$(txt "$CONC")" "$(tool Read /a/b/queue.sh)"
mk "$T/t-step.jsonl"       "$(txt 'อ่าน `queue.sh` ก่อน')" "$(tool Read /a/b/queue.sh)"
cfgset narrate_source insight
: > "$T/cache/summarized.log"
IS="$(_s n1)"
ck "a block with a conclusion in it speaks" "SPOKE[narration]: กำลังไปดูให้ค่ะ" \
   "$(run "$IS" "$T/p-read.json" "$T/t-conclusion.jsonl")"
# Deduped on the BLOCK, not the spoken line: five tool calls follow one block, each spawning its own
# narrate.sh, and without this the same block is summarized — and PAID FOR — five times.
ck "the same block does not speak again for the next step" EMPTY \
   "$(run "$IS" "$T/p-grep.json" "$T/t-conclusion.jsonl")"
ck "…and it was summarized exactly once" 1 "$(wc -l < "$T/cache/summarized.log" | tr -d ' ')"
# The particle is pinned to the VOICE's gender, and `voice_tts_gender` lives in the PROVIDER file
# rather than in lib.sh — so a caller that forgets voice_load_tts_provider gets an empty gender, the
# default particle, and a male voice saying ค่ะ. Silent, and it was written that way on the first
# pass here. Asserted on the arguments the summarizer was actually handed.
ck "the summarizer is given a particle, not left to guess" "--particle" \
   "$(cat "$T/cache/summarized.log")"
ck "…and it is a real Thai particle" "ค" "$(cat "$T/cache/summarized.log")"
# The cheap gate: a short block cannot hold a conclusion, so it must not reach the summarizer at all.
: > "$T/cache/summarized.log"
ck "a block that only announces a step is silent" EMPTY \
   "$(run "$(_s n2)" "$T/p-read.json" "$T/t-step.jsonl")"
ck "…and cost nothing — no summarizer call" 0 "$(wc -l < "$T/cache/summarized.log" | tr -d ' ')"
# The model's own refusal. Most blocks are a step, so NONE is the common answer and it must be
# silence rather than a spoken "NONE".
ck "NONE from the summarizer is silence, not a spoken word" EMPTY \
   "$(VOICE_TEST_SUMMARY=NONE run "$(_s n3)" "$T/p-read.json" "$T/t-conclusion.jsonl")"
# insight NEVER falls back to the step sources: that would put "รัน cd" back one silence at a time.
ck "a refused block does not fall through to the step fact" EMPTY \
   "$(VOICE_TEST_SUMMARY=NONE run "$(_s n4)" "$T/p-green.json" "$T/t-conclusion.jsonl")"
ck "a VOICE-tagged block is still never narrated mid-turn" EMPTY \
   "$(run "$(_s n5)" "$T/p-read.json" "$T/t-tag.jsonl")"
# The tag outranks the guess even here: exact beats summarized, and it spends nothing.
: > "$T/cache/summarized.log"
ck "a SAY tag wins over the summarizer under insight too" "ต้นเหตุคือ queue supersede" \
   "$(run "$(_s n6)" "$T/p-read.json" "$T/t-say.jsonl")"
ck "…and skipped the model call entirely" 0 "$(wc -l < "$T/cache/summarized.log" | tr -d ' ')"
cfgset narrate_source facts

echo "== the pair: every step says what it is about to do, then how it went =="
# This is what `max` promises, and the two halves must both land on the SAME session with nothing
# between them — no rate floor, no dedupe collision, no threshold hijacking the first line.
PS="$(_s i1)"
ck "the step announces itself before running" "SPOKE[narration]: รัน cargo test" \
   "$(run "$PS" "$T/p-pre-bash.json" - --event PreToolUse)"
ck "…and the same step reports its figure right after" "SPOKE[narration]: cargo test ผ่าน 42" \
   "$(run "$PS" "$T/p-green.json")"
# A PreToolUse payload must never reach the RESULT templates: they would measure a response that
# does not exist and say "อ่านแล้ว 0 บรรทัด" — past tense, about nothing, before the work happened.
ck "the before-half speaks the file it is about to read" "SPOKE[narration]: อ่าน queue.sh" \
   "$(run "$(_s i2)" "$T/p-pre-read.json" - --event PreToolUse)"
# A threshold is a statement about what HAS happened, so it may not ride on the before-half: were it
# to fire, the line would come back as SPOKE[milestone/attention]: ผ่านมา … instead.
LI="$(_s i3)"
( . "$T/scripts/voice/lib.sh" 2>/dev/null
  voice_turn_start "$LI"
  f="$(voice_turn_file "$LI")"; jq '.turn = (.turn - 700)' "$f" > "$f.t" && mv "$f.t" "$f" ) >/dev/null 2>&1
ck "a long turn does not turn the before-half into a threshold" "SPOKE[narration]: อ่าน queue.sh" \
   "$(run "$LI" "$T/p-pre-read.json" - --event PreToolUse)"

echo "== narrate_intent: false = results only, the way this level used to work =="
cfgset narrate_intent false
ck "the before-half is silenced" EMPTY \
   "$(run "$(_s i4)" "$T/p-pre-read.json" - --event PreToolUse)"
ck "…and the result half still speaks" "queue.sh อ่านแล้ว 3 บรรทัด" \
   "$(run "$(_s i5)" "$T/p-read.json")"
cfgset narrate_intent true

echo "== no rate floor by default: consecutive steps all speak =="
RS="$(_s r0)"
ck "first speaks" "SPOKE[narration]" "$(run "$RS" "$T/p-read.json")"
ck "the very next line speaks too, with no wait" "voice_cfg เจอ 4 แห่ง" \
   "$(run "$RS" "$T/p-grep.json")"

echo "== …and a rate floor still throttles when someone sets a number =="
cfgset narrate_gap 4
ck "first speaks" "SPOKE[narration]" "$(run "$(_s r1)" "$T/p-read.json")"
ck "a different line inside the floor is dropped" EMPTY "$(run "$(_s r1)" "$T/p-grep.json")"
cfgset narrate_gap 0

echo "== the per-turn cap (3 in this suite's config) =="
CAPS="$(_s c1)"
( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_turn_start "$CAPS" ) >/dev/null 2>&1
spoke=0
for i in 1 2 3 4 5; do
  # Each iteration needs a DIFFERENT line (dedupe) and no floor in the way, so the stamp is
  # rewound between calls — the cap is what is under test here, not the cadence.
  ( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_narrate_put "$CAPS" ts 0 ) >/dev/null 2>&1
  pay "$T/p-loop.json" Read "{\"file_path\":\"/a/f$i.sh\"}" '"x\ny"'
  out="$(run "$CAPS" "$T/p-loop.json")"
  [[ -n "${out//[[:space:]]/}" ]] && spoke=$((spoke+1))
done
ck "stops at the cap and no further" "3" "$spoke"

echo "== …but the cap is 0 (off) as shipped, so a long turn keeps talking =="
cfgset narrate_max_per_turn 0
CAPZ="$(_s c2)"
( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_turn_start "$CAPZ" ) >/dev/null 2>&1
spoke=0
for i in 1 2 3 4 5 6; do
  pay "$T/p-loop.json" Read "{\"file_path\":\"/a/z$i.sh\"}" '"x\ny"'
  out="$(run "$CAPZ" "$T/p-loop.json")"
  [[ -n "${out//[[:space:]]/}" ]] && spoke=$((spoke+1))
done
ck "six steps in one turn, six lines — no ceiling in the way" 6 "$spoke"
cfgset narrate_max_per_turn 3

echo "== the long-turn threshold: single-shot, and only on a real step =="
LS="$(_s l1)"
( . "$T/scripts/voice/lib.sh" 2>/dev/null
  voice_turn_start "$LS"
  f="$(voice_turn_file "$LS")"; jq '.turn = (.turn - 700)' "$f" > "$f.t" && mv "$f.t" "$f" ) >/dev/null 2>&1
out="$(run "$LS" "$T/p-read.json")"
ck "says how long it has been running, with the last step" "ผ่านมา 11 นาที" "$out"
ck "…as a milestone that cannot be dropped" "SPOKE[milestone/attention]" "$out"
( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_narrate_put "$LS" ts 0 ) >/dev/null 2>&1
out2="$(run "$LS" "$T/p-grep.json")"
ck "the threshold does not fire twice in one turn" "SPOKE[narration]" "$out2"

echo "== the turn already ended: the closing line owns it =="
export VOICE_CACHE_HOME="${VOICE_CACHE_HOME:-$HOME/.cache/aiworks/voice}"
( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_turn_start "$(_s e1)"; voice_turn_end "$(_s e1)" ) >/dev/null 2>&1
ck "silent after the turn closed" EMPTY "$(run "$(_s e1)" "$T/p-read.json")"

echo "== every OTHER chattiness level is silent =="
for lvl in terse balanced chatty; do
  ck "chattiness=$lvl narrates nothing" EMPTY \
     "$(VOICE_CHATTINESS=$lvl run "$(_s x-$lvl)" "$T/p-read.json")"
done

echo "== a LINKED WORKTREE is clamped to terse, so the narrator goes quiet there =="
# `max` — the level that narrates every step — belongs to the ROOT checkout alone: two sessions on
# one machine share one spool and one pair of speakers. The clamp itself lives in voice_chattiness
# and is owned by chattiness-selftest.sh (config resolution, including the case that proves a
# worktree INHERITS the root's level rather than merely lacking one). What is proved HERE is the
# consequence, which needs this suite's harness: a real payload through a real narrate.sh.
# Against a REAL `git worktree`, never a simulated one — the gate is mechanical
# (`--git-common-dir`), so a hand-set root variable would test nothing.
WT_MAIN="$T/wtmain"; WT="$T/wt"
mkdir -p "$WT_MAIN"
# `worktree add` needs a repo with one commit; the CONTENT is irrelevant — only where the
# worktree's --git-common-dir points. So the scripts and the config go in afterwards as UNTRACKED
# files, which also keeps scripts/voice/.env out of a throwaway git object.
git -C "$WT_MAIN" init -q >/dev/null 2>&1
printf 'x\n' > "$WT_MAIN/.keep"
git -C "$WT_MAIN" add .keep >/dev/null 2>&1
git -C "$WT_MAIN" -c user.email=selftest@local -c user.name=selftest -c commit.gpgsign=false \
  commit -qm init >/dev/null 2>&1
git -C "$WT_MAIN" worktree add -q -b wt-probe "$WT" >/dev/null 2>&1
if [[ ! -e "$WT/.git" ]]; then
  echo "  FAIL could not create a linked worktree — the clamp is unproven"; fail=$((fail+1))
else
  for d in "$WT_MAIN" "$WT"; do
    cp -R "$T/scripts" "$d/scripts"; cp "$T/workspace.config.yaml" "$d/"
    rm -f "$d/scripts/voice/.env"
  done
  # narrate.sh gates on `== max`, so the step narrator goes quiet in the worktree without a second
  # rule to keep in sync. Same payload both sides, so the only variable is which checkout it runs in.
  nar() { cp "$3" "$T/live-wt.json"; "$1/scripts/voice/narrate.sh" --session "$2" --payload "$T/live-wt.json" 2>/dev/null; }
  ck "the root checkout still narrates the step" "SPOKE[narration]: queue.sh อ่านแล้ว 3 บรรทัด" \
     "$(nar "$WT_MAIN" "$(_s w1)" "$T/p-read.json")"
  ck "the worktree narrates nothing at all" EMPTY "$(nar "$WT" "$(_s w2)" "$T/p-read.json")"
fi

echo "== the payload temp file is always cleaned up =="
cp "$T/p-read.json" "$T/live.json"
"$N" --session "$(_s g0)" --payload "$T/live.json" >/dev/null 2>&1
[[ -f "$T/live.json" ]] && { echo "  FAIL payload left behind"; fail=$((fail+1)); } || { echo "  ok   payload deleted by the reader"; pass=$((pass+1)); }
cp "$T/p-read.json" "$T/live.json"
VOICE_CHATTINESS=terse "$N" --session "$(_s g0b)" --payload "$T/live.json" >/dev/null 2>&1
[[ -f "$T/live.json" ]] && { echo "  FAIL payload left behind on an early gate exit"; fail=$((fail+1)); } || { echo "  ok   …even when a gate exits early"; pass=$((pass+1)); }

echo "== the gate voice =="
gpay() { jq -n --arg e "$1" --arg n "$2" --argjson i "$3" --arg m "${4:-}" \
  '{session_id:"x",hook_event_name:$e,tool_name:$n,tool_input:$i,message:$m}' > "$T/gate.json"; }
grun() { cp "$T/gate.json" "$T/glive.json"; "$G" --session "$1" --event "$2" --payload "$T/glive.json" 2>/dev/null; }

gpay PermissionRequest Bash '{"command":"cargo test --lib -p my-crate"}'
ck "permission names the command" "SPOKE[milestone/attention]: ขออนุญาตรัน cargo test ค่ะ" \
   "$(grun "$(_s gt1)" PermissionRequest)"
gpay PermissionRequest Write '{"file_path":"/a/b/main.rs"}'
ck "permission for a file names the file" "ขออนุญาตใช้ Write กับ main.rs ค่ะ" \
   "$(grun "$(_s gt2)" PermissionRequest)"
gpay PermissionDenied Bash '{"command":"git push origin develop"}'
ck "an auto-mode denial is spoken, in red" "SPOKE[milestone/red]: git push ถูก block ค่ะ" \
   "$(grun "$(_s gt3)" PermissionDenied)"
gpay PreToolUse ExitPlanMode '{}'
ck "a plan up for approval" "แผนพร้อมแล้ว ขออนุมัติค่ะ" "$(grun "$(_s gt4)" PreToolUse)"
gpay PreToolUse Bash '{"command":"ls"}'
ck "PreToolUse for anything else is not a gate" EMPTY "$(grun "$(_s gt5)" PreToolUse)"
gpay Notification "" '{}' "Claude needs your permission to use Bash"
ck "a permission notification is classified" "ขออนุญาตทำงานต่อค่ะ" "$(grun "$(_s gt6)" Notification)"
# An idle notification is NOT a gate — nothing is blocked, the turn already ended, and the only
# news in it is that the user has not typed. Asserted as silence so it cannot come back by accident.
gpay Notification "" '{}' "Claude is waiting for your input"
ck "an idle notification says nothing" EMPTY "$(grun "$(_s gt7)" Notification)"
gpay Notification "" '{}' "Some unrecognised English sentence"
ck "an unclassifiable notification stays silent (never read aloud)" EMPTY "$(grun "$(_s gt8)" Notification)"
gpay PermissionRequest Bash '{"command":"cargo test --lib -p my-crate"}'
S9="$(_s gt9)"
ck "one prompt, two events: first speaks" "ขออนุญาตรัน cargo test" "$(grun "$S9" PermissionRequest)"
gpay Notification "" '{}' "Claude needs your permission to use Bash"
ck "…and the second event for the SAME prompt stays quiet" EMPTY "$(grun "$S9" Notification)"
# Deduped on the class, not the wording — so a DIFFERENT kind of gate still gets through at once.
gpay PreToolUse ExitPlanMode '{}'
ck "a different gate class is not swallowed by it" "แผนพร้อมแล้ว" "$(grun "$S9" PreToolUse)"
ck "gates: false silences it" EMPTY \
   "$(gpay PermissionRequest Bash '{"command":"ls -la"}'; VOICE_CHATTINESS=terse grun "$(_s gt10)" PermissionRequest >/dev/null; \
      sed -i.bak 's/    gates: true//' "$T/workspace.config.yaml" 2>/dev/null; \
      printf '    gates: false\n' >> "$T/workspace.config.yaml"; grun "$(_s gt11)" PermissionRequest)"
# The gate voice is INDEPENDENT of chattiness (it is a "whether", not a "how much") — restore the
# config and prove that at terse it still speaks.
sed -i.bak '/gates: false/d' "$T/workspace.config.yaml"
gpay PermissionRequest Bash '{"command":"cargo build"}'
ck "a gate speaks at terse too, unlike narration" "ขออนุญาตรัน cargo build ค่ะ" \
   "$(VOICE_CHATTINESS=terse grun "$(_s gt12)" PermissionRequest)"

echo "== mute: EVERY output is off, and nothing is spent =="
# WHY THE STUB'S LOG IS PER-CASE (VOICE_SPOKE_LOG): the ack case below runs the real hook, which forks
# ack.sh in the background, and that straggler lands in the log SECONDS later. A hook case that
# truncated one shared log and then waited for "any line" read the previous case's ack instead of its
# own narration — flaky, and it failed in the convincing direction (2 of 6 runs, with the ack's text
# right there in the diff).
#
# The stub speak.sh is the proxy for spend: it is what a real run would pay an LLM and a TTS call
# for, so silence here means the producer exited before either one.
: > "$T/cache/mute"
ck "a hand mute silences narration"  EMPTY "$(run "$(_s m1)" "$T/p-read.json")"
ck "a hand mute silences the gate voice" EMPTY \
   "$(gpay PermissionRequest Bash '{"command":"cargo test"}'; grun "$(_s m2)" PermissionRequest)"
rm -f "$T/cache/mute"
ck "the OS mute silences narration" EMPTY \
   "$(VOICE_OS_MUTED=1 run "$(_s m3)" "$T/p-read.json")"
ck "the OS mute silences the gate voice" EMPTY \
   "$(gpay PermissionRequest Bash '{"command":"cargo test"}'; VOICE_OS_MUTED=1 grun "$(_s m4)" PermissionRequest)"
ck "…and both off speaks again" "SPOKE[narration]" "$(run "$(_s m5)" "$T/p-read.json")"

# voice_mute_reason names the switch — a status line that says "muted" without saying WHICH mute
# sends you to unmute the wrong one.
reason() { ( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_mute_reason ); }
ck "reason: nothing"  EMPTY "$(reason)"
ck "reason: the OS"   "os"  "$(VOICE_OS_MUTED=1 reason)"
: > "$T/cache/mute"
ck "reason: by hand wins when both are on" "hand" "$(VOICE_OS_MUTED=1 reason)"
rm -f "$T/cache/mute"

echo "== mute covers the SOUND EFFECTS too, not just the speech =="
: > "$T/cache/cue/ack.mp3"; printf x > "$T/cache/cue/ack.mp3"
rm -f "$T/cache/played"
out="$(VOICE_OS_MUTED=1 "$T/scripts/voice/sfx.sh" play ack 2>&1)"
ck "sfx.sh play says it is muted instead of playing" "muted (os)" "$out"
[[ -f "$T/cache/played" ]] && { echo "  FAIL sfx played a cue while muted"; fail=$((fail+1)); } \
                          || { echo "  ok   …and no cue reached afplay"; pass=$((pass+1)); }
rm -f "$T/cache/played"
VOICE_OS_MUTED=0 "$T/scripts/voice/sfx.sh" play ack >/dev/null 2>&1
[[ -f "$T/cache/played" ]] && { echo "  ok   unmuted, the same cue does play"; pass=$((pass+1)); } \
                          || { echo "  FAIL cue did not play when unmuted"; fail=$((fail+1)); }

echo "== the ack cue the hook plays INLINE is muted too =="
# The one output that never went through speak.sh or queue.sh, and so was the one that still went
# "bong" on a muted machine. Run the real hook against the throwaway tree.
hook="$SRC/.claude/hooks/voice-ack.sh"
hookrun() { # hookrun <VOICE_OS_MUTED> — returns after the backgrounded cue had its chance
  rm -f "$T/cache/played"
  printf '{"session_id":"%s","prompt":"ตรวจ turnover commission ให้หน่อย"}' "$(_s h$1)" \
    | CLAUDE_PROJECT_DIR="$T" VOICE_OS_MUTED="$1" bash "$hook" >/dev/null 2>&1
  local i=0; while [[ ! -f "$T/cache/played" && $i -lt 30 ]]; do sleep 0.05; i=$((i+1)); done
}
hookrun 1
[[ -f "$T/cache/played" ]] && { echo "  FAIL the hook played the ack cue while muted"; fail=$((fail+1)); } \
                          || { echo "  ok   muted: the hook plays no cue"; pass=$((pass+1)); }
hookrun 0
[[ -f "$T/cache/played" ]] && { echo "  ok   unmuted: the cue still lands"; pass=$((pass+1)); } \
                          || { echo "  FAIL the cue stopped landing when unmuted"; fail=$((fail+1)); }

echo "== the REAL hook, on the event that sits in front of the tool =="
# The one link no other case covers: which EVENT reaches narrate.sh is decided by the hook, so a
# PreToolUse wiring that dropped the event name would leave every case above green and the feature
# silent — or worse, feed a response-less payload to the result templates.
nhook="$SRC/.claude/hooks/voice-narrate.sh"
HK="$T/hk.log"     # this block's own log — see VOICE_SPOKE_LOG above
hnar() { # hnar <session> <event> <tool_name> <tool_input-json> — fires the real hook, does not wait
  printf '{"session_id":"%s","hook_event_name":"%s","tool_name":"%s","tool_input":%s}' \
    "$1" "$2" "$3" "$4" \
    | VOICE_SPOKE_LOG="$HK" CLAUDE_PROJECT_DIR="$T" bash "$nhook" > "$T/hook.out" 2>&1
}
hkwait() { # hkwait <substring> — until the forked narrator's line lands, or 3 s
  local i=0; while ! grep -qF -- "$1" "$HK" 2>/dev/null && (( i < 60 )); do sleep 0.05; i=$((i+1)); done
}
: > "$HK"
hnar "$(_s hk1)" PreToolUse Bash '{"command":"cargo build --release"}'
hkwait "cargo build"
ck "the hook narrates what the step is about to do" "SPOKE[narration]: รัน cargo build" \
   "$(cat "$HK" 2>/dev/null)"
# A PreToolUse hook's stdout can reach the MODEL. A narration echoed back would become part of the
# conversation it describes — and a non-empty stdout on this event is one step from steering the run.
ck "…and prints nothing at all on stdout" EMPTY "$(cat "$T/hook.out" 2>/dev/null)"
# Silence is proved by a SENTINEL, not by sleeping: fire the quiet tool, then a tool that must speak,
# and wait for the sentinel's line. A `sleep 1` here would be both slower and a coin flip on a loaded
# machine, which is how the case above was flaky in the first place.
: > "$HK"
hnar "$(_s hk2)" PreToolUse TodoWrite '{}'
hnar "$(_s hk3)" PreToolUse Bash '{"command":"git status"}'
hkwait "git status"
ck "a bookkeeping tool is silent before the call too" 1 "$(wc -l < "$HK" | tr -d ' ')"
ck "…and the line that DID land is the other tool's" "รัน git status" "$(cat "$HK" 2>/dev/null)"

echo "== the queue keeps a BACKLOG of narrations, and drops the OLDEST first =="
# The rule that actually made `max` skip actions: narration used to be superseded down to the NEWEST
# job per session, so a burst of five steps queued five lines and played one. Jobs are written
# straight into the spool because `enqueue` drains immediately and so can never build a backlog to
# prune — this is the drain-time policy under test, not the producer's.
Q="$T/scripts/voice/queue.sh"
SPOOL="$T/cache/spool"; mkdir -p "$SPOOL"
rm -f "$T/cache/played" "$T/cache/last-spoken.json" "$SPOOL"/*.json
NOWQ="$(date +%s)"
for i in 1 2 3 4 5; do
  printf 'audio%s' "$i" > "$T/cache/n$i.mp3"
  jq -n --argjson ts "$((NOWQ - 5 + i))" --arg a "$T/cache/n$i.mp3" \
     '{ts:$ts, kind:"narration", session:"qsess", audio:$a, prefix:"", text:"x"}' \
     > "$SPOOL/$((NOWQ - 5 + i))-0$i-narration.json"
done
"$Q" drain >/dev/null 2>&1
ck "three of five survive — the depth, not one" 3 "$(wc -l < "$T/cache/played" | tr -d ' ')"
ck "…and the newest is among them" "n5.mp3" "$(cat "$T/cache/played" 2>/dev/null)"
ck "the OLDEST is the one dropped" 0 "$(grep -c 'n1.mp3' "$T/cache/played" 2>/dev/null || true)"
rm -f "$T/cache/played"

echo "== tool-fact.py fixtures =="
if python3 "$SRC/scripts/voice/tool-fact.py" --selftest >/dev/null 2>&1; then
  echo "  ok   tool-fact fixtures green"; pass=$((pass+1))
else
  echo "  FAIL tool-fact fixtures (run scripts/voice/tool-fact.py --selftest)"; fail=$((fail+1))
fi

echo; echo "pass=$pass fail=$fail"
exit $(( fail > 0 ))
