#!/usr/bin/env bash
#
# Turn a prompt (or any block of text) into the ONE Thai sentence that gets spoken back.
#
# Usage:
#   summarize.sh [-v] [options] --file PROMPT_FILE
#   summarize.sh [-v] [options] "text…"
#
#   --kind ack|report                 ack (default): "I heard your request, here is what I will
#                                     look at". report: "here is what just happened" — the same
#                                     model, a different job, and mixing the two produced a
#                                     finished MR announced as a plan to open one
#   --provider openai|gemini|claude   override voice.summarizer.provider
#   --particle ครับ|ค่ะ                the sentence-final particle to end on (pinned to the
#                                     voice's gender — a male voice saying ค่ะ is a real bug)
#   --seed TEXT                       phrasing instruction from variety.sh
#   --extra TEXT                      an additional style note (time of day, mood)
#   --chattiness LEVEL                terse|balanced|chatty — sets the sentence count, the length
#                                     budget and how much personality is allowed. Defaults to
#                                     voice.autoplay.chattiness (see voice_chattiness in lib.sh)
#   --plain                           strip the softener and the reaction word at ANY level: for
#                                     bad news, where a warm register is the wrong register
#   --max-chars N                     override the level's length budget (rarely needed)
#   --file PATH                       read the prompt from a file (prompts can be huge)
#
# Prints ONE line on stdout, or nothing on failure — a caller that gets nothing must speak
# nothing rather than fall back to a canned sentence. A canned "รับทราบครับ" on every failure
# is exactly the filler this feature is supposed to avoid.
#
# `claude` means the HEADLESS CLI (`claude -p`), so it needs no API key — useful on a machine
# that has Claude Code but no OpenAI/Gemini credentials. It is also the slowest of the three.

set -euo pipefail
# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROVIDER="" PARTICLE="ค่ะ" SEED="" EXTRA="" MAX="" FILE="" TEXT="" KIND=ack
LEVEL="" PLAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) export VOICE_VERBOSE=1; shift ;;
    --kind)       KIND="${2:?}"; shift 2 ;;
    --provider)   PROVIDER="${2:?}"; shift 2 ;;
    --particle)   PARTICLE="${2:?}"; shift 2 ;;
    --seed)       SEED="${2:-}"; shift 2 ;;
    --extra)      EXTRA="${2:-}"; shift 2 ;;
    --chattiness) LEVEL="${2:?}"; shift 2 ;;
    --plain)      PLAIN=1; shift ;;
    --max-chars)  MAX="${2:?}"; shift 2 ;;
    --file)       FILE="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0 ;;
    -*)           vdie "unknown option $1 (see -h)" ;;
    *)            TEXT="${TEXT:+$TEXT }$1"; shift ;;
  esac
done

if [[ -n "$FILE" ]]; then
  [[ -f "$FILE" ]] || vdie "no such prompt file: $FILE"
  TEXT="$(cat "$FILE")"
fi
[[ -n "$TEXT" ]] || vdie "nothing to summarize"

voice_require jq curl
voice_load_credentials
[[ -n "$PROVIDER" ]] || PROVIDER="$(voice_cfg voice.summarizer.provider openai)"
[[ -n "$LEVEL" ]] || LEVEL="$(voice_chattiness)"
case "$LEVEL" in terse|balanced|chatty) ;; *) LEVEL=terse ;; esac

# ── the length budget: ONE table, keyed by (kind, level) ──────────────────────────
# It lives here rather than in the callers because here is where the prompt is built, and it used
# to be two magic numbers in two files (ack.sh had 90, milestone.sh had 120) that nothing tied
# together.
#
# SENTENCES ARE THE REAL KNOB. "ONE short Thai sentence" is an instruction the model obeys; a
# character cap is one it approximates. So the count leads and the cap is a backstop — and the cap
# is a CEILING, NOT A QUOTA. That distinction is the whole safety property of `chatty`: given room
# and only one fact, a model pads, and padding is one step from inventing. Measured on this very
# feature — an open-ended prompt had it reach for a plausible-looking file name, which is why the
# "never invent" line exists at all.
#
# Budgets are the closing line's; the ack gets less at every level on purpose — at the START of a
# turn you are waiting to work, and 13 seconds of preamble is 13 seconds of standing still.
# ~15 Thai characters per second of speech (measured: 90 chars ≈ 6 s).
# The phrase carries its own VERB AGREEMENT ("that says" vs "that say") rather than the JOB text
# gluing one on. That is not fussiness: it is what keeps `terse` byte-identical to the shipped
# prompt, which said "ONE short Thai sentence that says". A single shared verb form would have made
# terse read "…sentence saying…" — a one-word drift in the level that is specified as "unchanged",
# and the kind of difference that is impossible to argue about later.
# ⚠ THE COUNT IS PHRASED AS "ONE PER FACT, UP TO N" — NOT "TWO OR THREE SENTENCES".
# Measured, and it failed the first way round: "TWO or THREE short Thai sentences" plus a separate
# ceiling-not-quota paragraph produced, from the single fact "แก้ typo ใน README แล้ว", three
# sentences of which two were invented — "รอให้ผู้ใช้ตรวจสอบต่อไป" (a next step nobody mentioned) and
# "ขอบคุณที่ช่วยแจ้งให้ทราบ" (a thank-you, which the same prompt explicitly forbids). The model obeys
# the IMPERATIVE (a sentence count) over a CAVEAT, so the fact count has to be inside the imperative.
_level_cap() {   # → "<max chars>|<max sentences>"
  case "$LEVEL:$KIND" in
    terse:ack)       printf '90|1' ;;
    terse:report)    printf '120|1' ;;
    balanced:ack)    printf '140|2' ;;
    balanced:report) printf '200|2' ;;
    chatty:ack)      printf '200|3' ;;
    chatty:report)   printf '280|3' ;;
    *)               printf '90|1' ;;
  esac
}

# Keyed by the number of sentences actually allowed, not by the configured level — because the
# material can lower it (see below) and the imperative has to agree with the cap. "up to THREE
# sentences" next to "At most 60 characters" is how you get three fragments instead of one sentence.
_phrase() {   # N KIND
  case "$1:$2" in
    1:ack)    printf 'ONE short Thai sentence that says' ;;
    1:report) printf 'ONE short Thai sentence' ;;
    2:ack)    printf 'ONE short Thai sentence — a SECOND one only if you have a second real fact — that says' ;;
    2:report) printf 'ONE short Thai sentence, plus a SECOND one only if you have a second real fact' ;;
    *:ack)    printf 'ONE short Thai sentence PER FACT you actually have, up to THREE, that say' ;;
    *:report) printf 'ONE short Thai sentence PER FACT you actually have, up to THREE' ;;
  esac
}

# ── the personality ladder ────────────────────────────────────────────────────────
# Three things are graded, and each was chosen for what it CANNOT do:
#   softener   `ให้นะคะ` / `แล้วนะคะ` — 2–3 characters, cannot carry a false fact, and turns a
#              report into something addressed to a person
#   reaction   `ได้ค่ะ` / `เจอแล้วค่ะ` / `เรียบร้อยค่ะ` — states the OUTCOME in itself, unlike a
#              greeting, which costs characters and says nothing
#   follow-through   what will be reported next / what is waiting for the user — a fact about the
#              next step, not a connective
#
# What is NOT here, and must not be added: greetings, narration, and opinions without evidence.
# Same ruling as the plan's ban on quips (§9.2) — a warm turn of phrase lands the third time,
# grates on the fiftieth, and will eventually fire in the middle of an incident.
_persona() {
  [[ "$PLAIN" -eq 0 ]] || { printf 'Facts only. No softener, no reaction word, no warmth: this is bad news and a warm register would be the wrong one.'; return 0; }
  case "$LEVEL" in
    terse)    printf 'Facts only — no softener, no reaction word, no preamble.' ;;
    balanced) printf 'You may end on a soft address to the user (ให้นะคะ / แล้วนะคะ style) and open with a 1–2 word reaction that states the outcome (ได้ค่ะ / เจอแล้วค่ะ / เรียบร้อยค่ะ). No greeting, no narration, no opinion you have no evidence for.' ;;
    chatty)   printf 'You may open with a 1–2 word reaction that states the outcome (ได้ค่ะ / เจอแล้วค่ะ / เรียบร้อยค่ะ), end on a soft address to the user, and close with the follow-through — what you will report back, or what is now waiting for the user. Still no greeting, no narration, no jokes, and no opinion you have no evidence for.' ;;
  esac
}

IFS='|' read -r LEVEL_MAX MAX_SENTENCES <<< "$(_level_cap)"
N="$MAX_SENTENCES"

# ── the budget cannot exceed the MATERIAL ─────────────────────────────────────────
# A 23-character input cannot honestly become three sentences, and asking the model not to try was
# measured failing twice: from "แก้ typo ใน README แล้ว" it invented a next step in 4/4 runs and, in
# one, invented a FIGURE ("3 จุด") — a fabricated number in a spoken result is the worst thing this
# feature can produce.
#
# So the ceiling comes from the INPUT as well as the level: a summary that runs to more than ~60 % of
# its source is not summarizing. Floored at 60 characters so a tiny result still gets a speakable
# line, and the sentence count is then derived FROM THE CAP (~one sentence per 65 characters) rather
# than from a band — a first attempt mapped the cap onto the level bands and flattened a genuine
# four-fact reply to a single sentence.
#
# `--kind report` ONLY, and that boundary is load-bearing: the ratio is a SUMMARIZATION rule, and an
# ack does not summarize anything. Its input is a REQUEST, and the reply is legitimately longer than a
# short one — "/dev-cycle OFB-1598" is 20 characters and deserves a full sentence naming the work.
# Measured: applied to acks, a 67-character prompt capped every level at the 60-char floor and the
# three levels became indistinguishable (55 / 60 / 62 characters), which is the whole feature not
# working. The ack's guard against invention is the "never invent a file name, ticket key, repo,
# number or error" rule, which is unconditional.
#
# Not applied at `terse` either: one sentence has no padding pressure, and that level's prompt is
# specified as byte-for-byte unchanged, which a shrinking "At most N characters" would break.
if [[ "$KIND" == "report" && "$LEVEL" != "terse" && -z "$MAX" ]] && command -v python3 >/dev/null 2>&1; then
  _in="$(printf '%s' "$TEXT" | wc -m | tr -d ' ')"
  read -r _fit _n <<< "$(python3 -c "
cap = max(60, min($LEVEL_MAX, int($_in * 0.6)))
print(cap, max(1, min($MAX_SENTENCES, round(cap / 65))))" 2>/dev/null || printf '%s %s' "$LEVEL_MAX" "$MAX_SENTENCES")"
  if [[ "$_fit" -lt "$LEVEL_MAX" ]]; then
    vlog "budget: input is $_in chars — cap $LEVEL_MAX → $_fit, sentences $MAX_SENTENCES → $_n"
    LEVEL_MAX="$_fit"; N="$_n"
  fi
fi
SENTENCES="$(_phrase "$N" "$KIND")"
[[ -n "$MAX" ]] || MAX="$LEVEL_MAX"
# "the SINGLE most important number" is right for one sentence and wrong for three — at `chatty`
# there is room for two figures and pinning it to one would throw away the second. Kept at `terse`
# because that level's prompt is specified as unchanged.
SINGLE=""; [[ "$LEVEL" == "terse" ]] && SINGLE="single "
vlog "chattiness=$LEVEL kind=$KIND sentences='$SENTENCES' max=$MAX${PLAIN:+ plain=$PLAIN}"

# Per-provider model, with a sane default each — a single `model:` scalar would carry a model
# name from the wrong vendor the moment the provider is switched.
_model() {
  local m; m="$(voice_cfg "voice.summarizer.model.$PROVIDER" "")"
  [[ -n "$m" ]] || m="$(voice_cfg voice.summarizer.model "")"
  if [[ -z "$m" ]]; then
    case "$PROVIDER" in
      openai) m='gpt-4o-mini' ;;
      gemini) m='gemini-2.5-flash' ;;
      claude) m='claude-haiku-4-5-20251001' ;;
    esac
  fi
  printf '%s' "$m"
}

# The prompt is the measured one from the demo round, plus the three fixes measurement exposed:
# the particle is pinned to the voice's gender, English technical terms must stay in Latin
# script (transliterated dev-speak — "ไพพ์ไลน์" for pipeline — is unintelligible aloud), and
# nothing may be invented (a vague request had it reach for a plausible file name).
case "$KIND" in
  ack)
    # NOT a repeat-back. The first version acknowledged the request by paraphrasing the user's own
    # words, which out loud is a parrot: you just said the thing, hearing it read back tells you
    # nothing. What is actually worth hearing is that the request was UNDERSTOOD — so this states
    # the TASK, in the assistant's words, as an acceptance. Naming the work IS the acceptance;
    # there is no separate "รับทราบ" to add.
    JOB="The user just sent the request below and you are ACCEPTING it.
Reply with $SENTENCES what you understood the TASK to be — in YOUR OWN
words, as the assistant taking it on. Never echo, quote or paraphrase the user's phrasing back
at them: a sentence they could have written themselves says nothing.
If the request is clear enough to act on, state the concrete work you are about to do — the
thing, the place, the first step — and stop; that statement IS the acceptance.
If it is vague, say what you will go and look at first, and name nothing you were not given.
A request beginning with /name is INVOKING the workflow or skill called \`name\` — say that you are
starting it and on what (a ticket key, a repo, a file); never read the slash out or describe the
command itself as the thing you are going to look at.
Style: ${SEED:-plain and specific, the work first}."
    ;;
  report)
    # A finished turn, not a request. The tense matters out loud: "จะดู X" when X is already
    # done sounds like nothing happened.
    #
    # THE HARD PART IS THAT "I FINISHED" IS NOT A RESULT. This runs at the end of EVERY turn, so
    # the failure mode is a closing line that reports the act of finishing — "เสร็จแล้วครับ",
    # "อธิบายให้ฟังแล้วครับ" — which is the purest noise this feature can produce: you can see that
    # the turn ended. The sentence has to carry the finding, the number, the verdict, or what is now
    # waiting for you. A turn that only ANSWERED something still has a result: the answer.
    JOB="Below is what you JUST FINISHED doing, and this line is the last thing the user hears about
it. Report the OUTCOME in $SENTENCES — past tense, the result first, with the
${SINGLE}most important number, name or verdict in it.
Never report the act of finishing. \"เสร็จแล้ว\", \"ทำให้แล้ว\", \"อธิบายให้ฟังแล้ว\" say nothing the
user cannot already see; say WHAT came out of it instead.
If the turn answered a question rather than changing something, give the ANSWER's conclusion.
If — and ONLY if — the text below actually says something is waiting on the user (a question asked, an
approval requested, a decision left open), say what is waiting. Never assert that you are waiting for
anything when the text does not say so: \"รอการตรวจสอบจากคุณ\" was generated four times out of four
from a one-line input that said nothing of the kind.
Style: ${SEED:-state the outcome plainly, no preamble}.
Do not describe your process, do not list what you did step by step, do not say you will do
anything next, and do not thank anyone."
    ;;
  *) vdie "--kind must be ack|report" ;;
esac

# ── the level's extra lines, and why `terse` gets NONE ─────────────────────────────
# At `terse` the assembled prompt is byte-for-byte the one that shipped: no persona line, no
# ceiling line, and the singular "End the sentence". That is deliberate and checkable — `terse` was
# specified as "exactly today's behaviour", and a prompt that gained even a well-meant extra line
# would no longer be that. It also means the level cannot be blamed for a change it did not make.
#
# The ceiling line only exists where there is room to pad, which is only where more than one
# sentence is allowed.
PERSONA="" CEILING="" PARTICLE_LINE="End the sentence with the particle \"$PARTICLE\"."
if [[ "$LEVEL" != "terse" || "$PLAIN" -eq 1 ]]; then
  PERSONA="$(_persona)"
  # Measured: "not every sentence" was not enough — a 3-sentence chatty line came back with the
  # particle on all three ("ได้ค่ะ … ไม่ตรงค่ะ … ได้เลยค่ะ"), which is over-polite to the point of
  # sounding mechanical. So the budget is stated as a COUNT, and the opening reaction is named as
  # the one other place it may appear, since a reaction word carries the particle inside it.
  PARTICLE_LINE="The particle \"$PARTICLE\" appears at most TWICE in the whole reply: once at the very
end, and optionally inside the opening reaction word. Never on a middle sentence."
fi
if [[ "$LEVEL" != "terse" ]]; then
  CEILING="The sentence count is a CEILING, NOT A QUOTA. If the text below holds only ONE fact,
output exactly ONE sentence and stop. Never add a next step, an invitation to go and check
something, or a thank-you in order to reach the limit — every one of those has been generated from
a one-line input, and none of them was in it. An added sentence with nothing in it is worse than a
short line."
fi

SYS="You are the voice of a Thai-speaking dev assistant named Sunmi (ซันมี่).
$JOB
At most $MAX characters.${EXTRA:+ $EXTRA.}${PERSONA:+
$PERSONA}${CEILING:+
$CEILING}
$PARTICLE_LINE
Keep English technical terms, identifiers, ticket keys and file names in Latin script exactly as written.
Never translate dev vocabulary into Thai — ticket, branch, review, merge request, commit, deploy,
test, log, pipeline stay in English (a Thai word for one of these is not what a Thai dev says).
Never invent a file name, ticket key, repo, number or error that is not in the text below. If it
names nothing concrete, speak without naming anything.
No greeting, no emoji, no quotes, no markdown. Output the sentence only."

# The `terse` prompt, verbatim, for the check that it never drifted. Printed by --show-prompt.
[[ "${VOICE_SHOW_PROMPT:-0}" == "1" ]] && { printf '%s\n' "$SYS"; exit 0; }

# Trim the input: a 40 KB prompt is mostly pasted logs, and the tail rarely changes the intent.
PROMPT="$(printf '%s' "$TEXT" | head -c 6000)"

_clean() {   # one line, no quotes, no stray markdown — the model occasionally adds them anyway
  # The leading-label strip is not hypothetical: Gemini returned "Sunmi: ดู commission
  # calculator…" on the second measured run, and a spoken "Sunmi colon" is instantly wrong.
  tr '\n' ' ' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]+$//; s/^["'"'"'`]+//; s/["'"'"'`]+$//' \
    | sed -E 's/^(Sunmi|ซันมี่|Assistant|AI)[[:space:]]*[:：][[:space:]]*//' \
    | sed -E 's/[。．｡]+$//' \
    | sed -E 's/  +/ /g'
}

case "$PROVIDER" in
  openai)
    key="$(voice_need_key OPENAI_API_KEY)"
    out="$(jq -nc --arg s "$SYS" --arg u "$PROMPT" --arg m "$(_model)" '
        {model: $m, temperature: 0.7, max_completion_tokens: 200,
         messages: [{role: "system", content: $s}, {role: "user", content: $u}]}' \
      | curl -sS --max-time 60 -X POST "https://api.openai.com/v1/chat/completions" \
          -H "Authorization: Bearer $key" -H "Content-Type: application/json" --data-binary @-)" \
      || { vlog "summarize: openai request failed"; exit 1; }
    line="$(printf '%s' "$out" | jq -r '.choices[0].message.content // empty')"
    [[ -n "$line" ]] || { vlog "summarize: openai returned no content — $(printf '%s' "$out" | head -c 200)"; exit 1; }
    ;;
  gemini)
    key="$(voice_need_key GEMINI_VOICE_API_KEY)"
    # thinkingBudget 0: this is a one-line rewrite, and thinking tokens here are pure latency.
    out="$(jq -nc --arg t "$SYS

REQUEST:
$PROMPT" '{contents: [{parts: [{text: $t}]}],
           generationConfig: {thinkingConfig: {thinkingBudget: 0}, maxOutputTokens: 200}}' \
      | curl -sS --max-time 60 -X POST \
          "https://generativelanguage.googleapis.com/v1beta/models/$(_model):generateContent" \
          -H "x-goog-api-key: $key" -H "Content-Type: application/json" --data-binary @-)" \
      || { vlog "summarize: gemini request failed"; exit 1; }
    line="$(printf '%s' "$out" | jq -r '.candidates[0].content.parts[0].text // empty')"
    [[ -n "$line" ]] || { vlog "summarize: gemini returned no content — $(printf '%s' "$out" | head -c 200)"; exit 1; }
    ;;
  claude)
    command -v claude >/dev/null 2>&1 || { vlog "summarize: the claude CLI is not on PATH"; exit 1; }
    line="$(printf '%s\n\nREQUEST:\n%s\n' "$SYS" "$PROMPT" \
            | claude -p --model "$(_model)" 2>/dev/null)" \
      || { vlog "summarize: claude -p failed"; exit 1; }
    ;;
  *) vdie "unknown voice.summarizer.provider '$PROVIDER' — use openai|gemini|claude" ;;
esac

line="$(printf '%s' "$line" | _clean)"
[[ -n "$line" ]] || { vlog "summarize: empty after cleanup"; exit 1; }

# ── the particle budget, ENFORCED ─────────────────────────────────────────────────
# Asking for it in the prompt was tried twice and failed twice: "End the LAST sentence with the
# particle — not every sentence" produced ค่ะ on all three sentences, and restating it as an
# explicit count of two still produced three. A three-particle Thai sentence is over-polite to the
# point of sounding mechanical, so this is enforced rather than requested.
#
# Kept: the LAST occurrence (the sentence-final particle, which is the one that must be there) and
# an occurrence inside the OPENING reaction word, which carries its own. Everything in between goes.
# Only ever runs above `terse` — one sentence has nothing to strip, and terse's output path is
# specified as unchanged.
if [[ "$LEVEL" != "terse" ]] && command -v python3 >/dev/null 2>&1; then
  stripped="$(python3 -c '
import sys
line, p = sys.argv[1], sys.argv[2]
OPENING = 15          # a reaction word ("ได้ค่ะ", "เรียบร้อยค่ะ") lives in the first few characters
at, i = [], line.find(p)
while i != -1:
    at.append(i); i = line.find(p, i + len(p))
if len(at) > 1:
    keep = {at[-1]}
    if at[0] < OPENING: keep.add(at[0])
    out, prev = [], 0
    for i in at:
        if i in keep: continue
        out.append(line[prev:i]); prev = i + len(p)
    out.append(line[prev:])
    line = "".join(out)
sys.stdout.write(" ".join(line.split()))
' "$line" "$PARTICLE" 2>/dev/null)"
  if [[ -n "$stripped" && "$stripped" != "$line" ]]; then
    vlog "particle budget: trimmed to the opening + the ending — was '$line'"
    line="$stripped"
  fi
fi
printf '%s\n' "$line"
