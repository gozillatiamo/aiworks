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
cat > "$T/workspace.config.yaml" <<'YAML'
language: th
voice:
  enabled: true
  autoplay:
    enabled: true
    chattiness: max
    narrate_gap: 4
    narrate_max_per_turn: 3
    long_turn_seconds: 300
YAML
# Stub speak.sh: prove the handoff, the kind, the cue and the exact line — and spend nothing.
cat > "$T/scripts/voice/speak.sh" <<'STUB'
#!/usr/bin/env bash
kind=""; cue=""
while [[ $# -gt 0 ]]; do
  case "$1" in --kind) kind="$2"; shift 2 ;; --cue) cue="$2"; shift 2 ;; -*) shift ;; *) break ;; esac
done
printf 'SPOKE[%s%s]: %s\n' "$kind" "${cue:+/$cue}" "$*"
STUB
chmod +x "$T/scripts/voice/speak.sh"
# Stub the summarizer as well. narrate.sh never calls it (a fact line is a template, and prose is
# the transcript's own sentence) — but the ack-cue case below runs the REAL UserPromptSubmit hook,
# which forks ack.sh, and that one does. Without this the suite would make a paid LLM call.
cat > "$T/scripts/voice/summarize.sh" <<'STUB'
#!/usr/bin/env bash
printf 'กำลังไปดูให้ค่ะ\n'
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

echo "== rate floor: a DIFFERENT line, too soon =="
ck "first speaks" "SPOKE[narration]" "$(run "$(_s r1)" "$T/p-read.json")"
ck "a different line inside the floor is dropped" EMPTY "$(run "$(_s r1)" "$T/p-grep.json")"

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

echo "== a LINKED WORKTREE is clamped to terse, whatever the root's config says =="
# Two sessions on one machine share one spool and one pair of speakers, so `max` — the level that
# narrates every step — belongs to the ROOT checkout alone. The clamp lives in voice_chattiness
# (lib.sh) and is proved here against a REAL `git worktree`, not a simulated one: the whole point is
# that the gate is mechanical (`--git-common-dir`), so a fake root variable would test nothing.
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
  lvl() { bash -c '. "$1/scripts/voice/lib.sh" 2>/dev/null; voice_chattiness' _ "$1" 2>/dev/null; }
  ck "the root checkout keeps its max" "max" "$(lvl "$WT_MAIN")"
  ck "the linked worktree reads terse instead" "terse" "$(lvl "$WT")"
  # The escape hatch stays open: one command a human typed is per-invocation intent, not a machine
  # preference leaking in through the config chain — which is the thing being clamped.
  ck "VOICE_CHATTINESS still overrides inside the worktree" "max" \
     "$(VOICE_CHATTINESS=max lvl "$WT")"
  # …and the consequence that matters: narrate.sh gates on `== max`, so the step narrator goes
  # quiet in the worktree without a second rule to keep in sync.
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

gpay PermissionRequest Bash '{"command":"cargo test --lib -p ofb"}'
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
gpay Notification "" '{}' "Claude is waiting for your input"
ck "an idle notification is classified" "รอคำสั่งอยู่ค่ะ" "$(grun "$(_s gt7)" Notification)"
gpay Notification "" '{}' "Some unrecognised English sentence"
ck "an unclassifiable notification stays silent (never read aloud)" EMPTY "$(grun "$(_s gt8)" Notification)"
gpay PermissionRequest Bash '{"command":"cargo test --lib -p ofb"}'
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

echo "== tool-fact.py fixtures =="
if python3 "$SRC/scripts/voice/tool-fact.py" --selftest >/dev/null 2>&1; then
  echo "  ok   tool-fact fixtures green"; pass=$((pass+1))
else
  echo "  FAIL tool-fact fixtures (run scripts/voice/tool-fact.py --selftest)"; fail=$((fail+1))
fi

echo; echo "pass=$pass fail=$fail"
exit $(( fail > 0 ))
