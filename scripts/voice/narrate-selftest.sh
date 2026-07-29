#!/usr/bin/env bash
#
# Regression suite for narrate.sh — the `max` step narrator.
#
# Run:  scripts/voice/narrate-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Everything runs against a THROWAWAY tree in a temp dir with its OWN workspace.config.yaml
# (`language: th`, voice on, chattiness max) and a STUBBED speak.sh, so the suite is portable, it
# never reads the machine's real voice settings, and it costs nothing — no synthesis, no API call.
# Same doctrine as guards-selftest.sh.
#
# WHY SESSION IDS ARE RUN-SCOPED: narration state (the dedupe hash + the rate stamp) is
# machine-global and keyed by session id, so fixed ids would leak the PREVIOUS run's state into this
# one — which is exactly how this suite first went red on its own second run.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # the workspace root
T="$(mktemp -d -t voice-narrate-selftest)"
trap 'rm -rf "$T"' EXIT

rm -rf "$T"; mkdir -p "$T/scripts"
cp -R "$SRC/scripts/voice" "$T/scripts/voice"
cat > "$T/workspace.config.yaml" <<'YAML'
language: th
voice:
  enabled: true
  autoplay:
    enabled: true
    chattiness: max
YAML
# Stub speak.sh: prove the handoff and the exact line, spend nothing.
cat > "$T/scripts/voice/speak.sh" <<'STUB'
#!/usr/bin/env bash
kind=""; while [[ $# -gt 0 ]]; do case "$1" in --kind) kind="$2"; shift 2 ;; -*) shift ;; *) break ;; esac; done
printf 'SPOKE[%s]: %s\n' "$kind" "$*"
STUB
chmod +x "$T/scripts/voice/speak.sh"
N="$T/scripts/voice/narrate.sh"
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

pass=0; fail=0
ck() { # ck <label> <expect-substring|EMPTY> <actual>
  if [[ "$2" == "EMPTY" ]]; then
    if [[ -z "${3//[[:space:]]/}" ]]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1 — expected silence, got: $3"; fail=$((fail+1)); fi
  elif [[ "$3" == *"$2"* ]]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1"; echo "        want ⊃ $2"; echo "        got    $3"; fail=$((fail+1)); fi
}

echo "== the line it speaks =="
out="$("$N" --session "$(_s s1)" --transcript "$T/t-prose.jsonl" 2>/dev/null)"
ck "prose becomes one sentence, no fence/table" "SPOKE[narration]: อ่าน queue.sh ก่อน แล้วค่อยแก้ cadence" "$out"

echo "== dedupe: the same prose introduces the next tool call too =="
out2="$(VOICE_VERBOSE= "$N" --session "$(_s s1)" --transcript "$T/t-prose.jsonl" 2>/dev/null)"
ck "second call on the same block is silent" EMPTY "$out2"
why="$("$N" -v --session "$(_s s1)" --transcript "$T/t-prose.jsonl" 2>&1 >/dev/null | tail -1)"
ck "…and says why with -v" "narrate:" "$why"

echo "== markdown headings and list markers =="
out="$("$N" --session "$(_s s2)" --transcript "$T/t-heading.jsonl" 2>/dev/null)"
ck "heading marks stripped, words kept" "ผลการตรวจ" "$out"

echo "== a VOICE tag belongs to the closing line =="
out="$("$N" --session "$(_s s3)" --transcript "$T/t-tag.jsonl" 2>/dev/null)"
ck "tag block is never narrated" EMPTY "$out"

echo "== no prose at all: the activity fallback =="
out="$("$N" --session "$(_s s4)" --transcript "$T/t-noprose.jsonl" 2>/dev/null)"
ck "falls back to the tool activity" "กำลัง Read summarize.sh" "$out"

echo "== the turn already ended: the closing line owns it =="
export VOICE_CACHE_HOME="${VOICE_CACHE_HOME:-$HOME/.cache/aiworks/voice}"
( . "$T/scripts/voice/lib.sh" 2>/dev/null; voice_turn_start "$(_s s5)"; voice_turn_end "$(_s s5)" ) >/dev/null 2>&1
out="$("$N" --session "$(_s s5)" --transcript "$T/t-prose.jsonl" 2>/dev/null)"
ck "silent after the turn closed" EMPTY "$out"

echo "== rate floor: a fresh block within MIN_GAP =="
out="$("$N" --session "$(_s s6)" --transcript "$T/t-prose.jsonl" 2>/dev/null)"          # first, speaks
out2="$("$N" --session "$(_s s6)" --transcript "$T/t-heading.jsonl" 2>/dev/null)"       # different text, too soon
ck "first line speaks"                 "SPOKE[narration]" "$out"
ck "a DIFFERENT line inside the floor is dropped" EMPTY "$out2"

echo "== every OTHER chattiness level is silent =="
for lvl in terse balanced chatty; do
  out="$(VOICE_CHATTINESS=$lvl "$N" --session "$(_s s-$lvl)" --transcript "$T/t-prose.jsonl" 2>/dev/null)"
  ck "chattiness=$lvl narrates nothing" EMPTY "$out"
done

echo; echo "pass=$pass fail=$fail"
exit $(( fail > 0 ))
