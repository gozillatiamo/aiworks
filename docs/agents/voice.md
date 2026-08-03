# Voice — spoken output and dictation

The workspace can talk. It acknowledges a prompt, says a line when something actually happens,
attaches a voice note to the Slack messages it already sends, and takes dictation from a held
hotkey.

This page is the workspace-level entry: what it is, when it fires, and the one thing an **agent**
needs to know (the `VOICE:` tag). The implementation reference — every config key, every provider,
every measured number — is `scripts/voice/README.md`.

## It is inert unless three things are true

```
language: th             ⇒ voice runs   any other language ⇒ every command exits 0, silently
voice.enabled            ⇒ voice runs   false              ⇒ every command exits 0, silently
voice.autoplay.enabled   ⇒ speech runs  false              ⇒ the hooks do nothing
```

The committed `workspace.config.yaml` ships `voice.enabled: false`, and this is a **`th`-only**
feature by decision, so it is dead for the team as shipped. Opting in is personal: set it in the
git-ignored `workspace.config.local.yaml` (see `docs/adr/0003`). Nothing here is a shared default,
and `-v` on any voice command explains why it stayed quiet.

## Mute is an off switch, not a volume knob

**Muting the machine is enough.** There are two mutes and they mean the same thing:

| | how | state lives |
|---|---|---|
| by hand | `aiworks voice mute on` / `off` | one file, `~/.cache/aiworks/voice/mute` |
| by the OS | the mute key, the menu-bar slider, Control Centre | macOS, read live |

```bash
aiworks voice mute on      # the output half is DISABLED machine-wide — and costs nothing
aiworks voice mute off     # says so if the SYSTEM output is still muted (else you hunt a bug)
aiworks voice status       # every switch that decides whether you hear anything, in order
```

Either one, nothing is summarized and nothing is synthesized: no ack, no closing line, no
narration, no gate voice, no identity prefix, no cue, no sound effect, no dictation cue. The point
is the bill — the alternative was paying for an LLM call and a TTS call per turn to render audio
into speakers that are off.

The hand mute is a file, so every clone and worktree goes quiet at once; the OS mute needs no state
of ours, because the system already holds it. The one output that used to escape both was the `ack`
cue the `UserPromptSubmit` hook plays inline — it now does the check inside its own background
subshell, so the hook still returns instantly and the cue lands ~130 ms in instead of ~10 ms.

**`output muted`, never a volume threshold.** `output volume: 0` is not the same signal: macOS
reports 0 for HDMI / AirPlay / optical output, where the external device owns the volume — so
treating 0 as silence would quietly kill the feature for anyone using a monitor's speakers. Muted
is muted; quiet is not. When the flag cannot be read at all (not macOS), the answer is *not muted*:
failing open keeps a working feature working. `VOICE_OS_MUTED=1|0` forces it, which is how the
selftest covers this with no audio device.

**There is still no automatic call detection**, and now there is less need for one: Google Meet is a
browser tab with no process to find, so an auto-detect would cover some calls and silently miss
others. Muting the machine before a call — which people do by habit — is that switch.

**Two things it does not touch, because neither is this machine talking:**

- **The Slack voice note.** That audio is a deliverable for the team — rendered here, heard on
  someone else's phone — so it is not a question about the state of my speakers, and a muted laptop
  is not a reason to send the team less. Its one switch is `voice.notify_voice.enabled` in workspace
  config: a standing policy, set once, not a "for the next twenty minutes" toggle.
- **Dictation.** Push-to-talk is input, it runs only while you hold the key, and there is no
  background spend to save — a mute that stopped you dictating would be the switch breaking
  something you just explicitly asked for. Only its two cues go quiet.

## Sunmi (ซันมี่)

The assistant's spoken name, blended from the user's dogs Merry (แมรี่) and Sunny (ซันนี่). It is
what the summarizer is told it is called, and — when the deferred wake word lands — the word that
starts a listen. Two syllables, a real given name, phonetically distant from both dogs, and it
collides with no term in this domain.

## For agents: every finished turn speaks — name your own line

**A turn that ends with a reply gets a closing line spoken, always.** The result is the half you
cannot get from glancing at the screen, so it is not optional: the ack says what is starting, this
says what came out of it.

What you control is *which sentence that is*. Put a `VOICE:` line anywhere in the reply and it is
spoken verbatim — free (no summarizer call), exactly what you meant, and it picks the cue. Leave it
out and the reply is summarized instead, which costs a call and gives the model the last word on
your work:

```
VOICE[ship]: OFB-1952 merged เข้า develop แล้วครับ MR !12 ปิดแล้ว
```

| group | for | cue |
|---|---|---|
| `[green]` | tests pass, review approved, QA verdict good | chime at the tail |
| `[red]` | must-fixes, failures | buzz under the words, quietly |
| `[ship]` | MR/PR opened, merged, ticket Done | fanfare first, then talk |
| `[needs-you]` | a plan awaiting approval, a question, a blocked gate | neutral chime |
| `[incident]` | production is unhappy | urgent register |
| bare `VOICE:` | anything else worth saying aloud | no cue |

Only the **first** tag in a reply is used. Write it in the reply's own language policy — under `th`
that means Thai prose with the English spine intact, exactly like the rest of the reply.

**Say the result, not that you finished.** "เสร็จแล้วครับ" and "อธิบายให้ฟังแล้วครับ" are the purest
noise this feature can make — the user can see that the turn ended. The line has to carry the
finding, the number, the verdict, or what is now waiting for them. A turn that only *answered*
something still has a result: the answer. The summarizer is told the same thing, so a tag is worth
writing mainly when you can be more exact than a paraphrase of your own reply.

Without a tag, a narrow keyword match still runs — but only to pick the **cue**, never to decide
whether to speak. It needs *corroborated* evidence (an MR URL beside a merge word, a count beside
`must-fix`, a figure beside a production error), because a fanfare over a merge that did not happen
is worse than no cue at all. No match ⇒ words only.

Cost and the way back down: a closing line is unique text, so it never hits the audio cache — about
$0.01 a turn. `voice.autoplay.milestone_every_turn: false` returns to the conservative mode (only a
tagged turn speaks); `voice.autoplay.milestones: false` silences all of them; and if the *opening*
ack is the one you tire of, that is `voice.autoplay.ack: false` — the two are independent on
purpose.

## How much it says — `chattiness`

```yaml
voice:
  autoplay:
    chattiness: balanced      # terse | balanced | chatty | max
```

**How much, never whether.** "Whether" already has four switches (`ack` · `milestones` ·
`milestone_every_turn` · `narrate`); a fifth thing that could also produce silence would give
"why is it quiet?" five possible answers and no way to tell which. `terse`…`chatty` reach the **ack
and the closing line only** — so at those levels nothing at all is spoken between them; `max`
additionally turns on the **mid-turn narrator** (`narrate`), which is the only mid-turn voice the feature
has. The Slack voice note stays one canonical sentence at every level, because its repetition is what
makes it free (it hits the audio cache).

The same finished turn, at each level:

```
terse     เอกสารแก้ครบ 6 ไฟล์ รอคุณสั่งค่ะ
          1 sentence, facts only. The length this feature shipped with — unchanged, byte for byte

balanced  เรียบร้อยค่ะ เอกสารแก้ไขครบ 6 ไฟล์ รอการอนุมัติจากคุณนะคะ
          + a 1–2 word reaction that states the outcome, + a softener, + the second fact

chatty    เรียบร้อยค่ะ การแก้ mute ทำให้ local speech เงียบครบ 4 ทาง และ voice note upload
          ปกติ 23031 bytes เอกสารแก้ครบ 6 ไฟล์ รอคุณสั่งค่ะ
          + the third fact, + the follow-through (what will be reported, what waits for you)

max       เรียบร้อยค่ะ แก้ 4 script เสร็จแล้ว ได้แก่ lib.sh เพิ่ม narration state,
          summarize.sh เพิ่ม cap 260 chars สำหรับ ack และ 360 สำหรับ report, queue.sh เพิ่ม kind
          narration, aiworks-voice.sh audition ครบ 4 ระดับ รอการตรวจสอบจากคุณค่ะ
          + the STEPS, in the order they happened, one status each — and it talked through the
          turn while the work happened
```

### `max`, and why it is a different kind of level

The first three levels differ only in **length**. `max` differs in **what it is allowed to talk
about**: it is the only level that may narrate the process, which every other level explicitly
forbids — for them the process is filler around the one fact that matters.

The register is the one from the films, and it was **researched rather than guessed** — the actual
JARVIS dialogue across the Iron Man films, because the first `max` was built from an impression of it
and got the central property backwards. What the transcripts show:

| what he does | example |
|---|---|
| lines are **3–8 words**, never paragraphs | *"Thirteen, sir." · "18,000 feet." · "The armour is now at 92%."* |
| every line is a **state and a figure**, never an intention | *"Power: fifteen percent. Recommend you descend and re-charge, Sir."* |
| **unbidden warnings**, naming the consequence *to the person* | *"Might I remind you, if the suit loses power, so does your heart."* |
| **asks before the big step**, naming it | *"Shall I begin machining the parts?" · "The House Party Protocol, sir?"* |
| **contradicts flatly**, fact first | *"Actually, sir, it's in Miami."* |
| **dry wit**: rare, one clause, riding on a real answer | *"Am I to include the Belgium waffle stands?"* |
| in a crisis the register **collapses** to imperatives | *"Power critical, set course for home immediately."* |
| he **never narrates his own effort** | there is no *"I'm now searching through…"* in three films |

The correction that mattered: **the density comes from frequency, not from length.** The first `max`
raised the sentence budget (4 sentences, a 260/360-character ceiling) and produced a status report
read aloud — correct facts, wrong character. `max`'s ack and closing line are now **shorter than
`chatty`'s** (150/190), each sentence under ~45 characters, and the continuity comes from the four
channels below instead.

The prompt **describes** the register instead of naming the character, on purpose: naming it produces
a Thai butler impression, and the useful half of that voice is the status-report shape, not the accent.

| channel | at `max` |
|---|---|
| the **ack** | states the work *and the order it will be worked in* — future tense, completion words banned |
| the **mid-turn narrator** | a **conclusion each time something is worked out** — what it found, the cause, the next move — spoken *while* the turn runs, from the assistant's own reasoning (`narrate.sh`, on `PreToolUse` + `PostToolUse`) |
| the **thresholds** | speaks up unbidden when a step fails, when the same step fails again, or when the turn runs long — single-shot, never on a clock |
| the **gate voice** | says when something is **blocked on you**: a permission prompt, a plan up for approval, an auto-mode denial (`gate.sh`). Plain idle is not a gate |
| the **closing line** | up to 4 short statuses: the steps taken, then what is now waiting for the user |

The gate voice is the one channel that is **independent of `chattiness`** — a gate is a *whether*,
not a *how much*, so it has its own key (`voice.autoplay.gates`) and speaks at `terse` too.

### Anything above `terse` is the ROOT checkout's alone

**A linked worktree always speaks `terse`, whatever the config says.** Not a convention — the clamp
is in `voice_chattiness` (`scripts/voice/lib.sh`), keyed off the same `--git-common-dir` test the rest
of the adapter uses, so it holds for every caller including the mid-turn narrator (which gates on
`== max` and therefore goes quiet as a consequence, not as a second rule).

Three facts make it necessary:

- the config chain **deliberately** falls back to `<main clone>/workspace.config.local.yaml`, because
  a git-ignored file does not travel into a worktree. So a worktree *inherits* the root's `max` — it
  does not fall back to the shared file's `terse`;
- a worktree session is usually the one **nobody is watching**: a background `dev-cycle`, a
  slack-dispatch job. `max` is the level that narrates every step, so the checkout with the least of
  your attention becomes the loudest thing in the room;
- every worktree speaks through **one spool and one pair of speakers** (`VOICE_CACHE_HOME` is
  machine-global on purpose). Two `max` sessions do not take turns — they queue, and the one you are
  reading waits for the one you are not.

`aiworks voice status` says so in the worktree, naming the level that was configured and the checkout
that owns it — otherwise the row reads `terse` while the config file in front of you says `max`.
`VOICE_CHATTINESS=<level>` still overrides inside a worktree: one command a human typed is
per-invocation intent, not a preference leaking in through the config chain.

Proved against a real `git worktree`, not a simulated one — the whole point is that the gate is
mechanical, so a faked root variable would test nothing: `scripts/voice/chattiness-selftest.sh`
(10 cases, free to run — it only resolves config).

### The mid-turn narrator — a conclusion, named by the assistant

`voice.autoplay.narrate_source: say` (the default) speaks **only a line the assistant named itself**,
with a `SAY[group]:` line in its own prose — spoken verbatim, mid-turn, while the work continues:

```
SAY[red]: root cause คือ submodule pointer ค้างที่ OG-631 เพราะ teardown.sql พัง จะ bump แล้วรัน scoped test ใหม่ค่ะ
```

Same groups as the closing line's `VOICE[…]`, same free-and-exact economics, and a bare `SAY:` speaks
without a cue. **No tag ⇒ silence** — which is the right sound for a stretch of work that has not
concluded anything yet.

**Where it goes matters, and getting it wrong is silent.** The tag must sit **mid-turn, with a tool call
still to come** — a hook is what reads it. A tag in the *final* block of a reply is spoken by nobody:
its own turn has no tool call left to fire a hook, and the next turn's lookback is bounded to that turn
(measured: an unbounded one spoke the previous turn's closing tag right after the user typed something
new, which is the monologue about the past this channel exists to avoid). The closing line's
`VOICE[…]` owns the end of a turn; the two are not interchangeable.

**The unit is a conclusion, not a tool call**, and that correction is the entire history of this
channel. The version before it narrated every step in both directions — *รัน cd*, *อ่าน queue.sh*,
*cargo test ผ่าน 42* — and it did that correctly and fast. It was rejected on first contact with the
person it was built for, in one sentence: *not every command you will run and every result for every
command*. Nobody listening wants to be told which command is running. They want what a colleague
would say out loud: **what you found, why, and what you are doing about it.**

**Why the tag rather than a summarizer**, which is what this was built as first. Run over 12 of this
workspace's own mid-turn blocks, a model asked *"is this a conclusion?"* was wrong in both directions:

| block | verdict | should have been |
|---|---|---|
| *"the refusal lost to the prompt's own tail — and it invented a completion that was never in the input"* | `NONE` | spoken — that was the finding of the hour |
| *"Local commit + push were already done…"* | spoken as *"การ commit และ push เสร็จสิ้นแล้ว"* | `NONE` — status, not a conclusion (3/3 even after the prompt explicitly banned it) |
| *"voice_tts_gender is called in three places and defined nowhere"* | spoken | `NONE` — **the next block retracted it** (*"Correction: it is defined"*), and nothing can take spoken audio back |
| *"Now the cost lines and docs"*, *"PR #60 is up"*, … | `NONE` ✓ | correct |

A model cannot know that a later block corrects an earlier one, and it cannot know which of five true
statements was the point. The assistant does. So the judgement moved to the assistant and the default
became "speak only what was named".

`narrate_source: insight` keeps the summarizer as a **fallback** for anyone who would rather have a
guess than silence: the tag still wins when present, and an untagged block gets judged. Its hardest
job is refusing, so two gates, cheap one first:

| gate | what it rejects | cost |
|---|---|---|
| length, `MIN_BLOCK` = 100 chars | *"อ่าน queue.sh ก่อน"* — a preamble cannot contain a finding | free |
| the model, which answers `NONE` | a long block that is still only mechanics ("เปิดดู narrate.sh 271 บรรทัด แล้ว grep …") | one cheap-model call |
| the block's hash | the same block, seen again by every tool call that follows it | free, and it is the one dedupe that saves *money* rather than noise |

`NONE` is a **token to emit, not an instruction to stay quiet** — and that distinction was measured,
not assumed. Told to "reply with nothing", the first version answered a purely mechanical block with
*"queue.sh อ่านเสร็จแล้ว cadence แก้ไขเรียบร้อย รอให้ตรวจสอบต่อค่ะ"*: an invented completion **and** an
invented request for review, neither of which was in the input. The refusal also had to be hoisted to
the **first** line of the prompt: everything after the job description — the persona, the ceiling, the
particle rule, the closing *"Output the sentence only"* — pushes toward producing a polite sentence,
and a refusal buried in the middle loses to the imperative at the end. With the gate first and the
persona dropped: 3/3 refusals on two different mechanical blocks, 3/3 conclusions on a real finding,
and no invented next step on a finding that named none.

**Neither falls back to the step sources.** A block with no conclusion is silence — falling back to
`facts` would return *รัน cd* to the channel one silence at a time.

Two other sources remain, and both cost nothing:

- **`facts`** — the step metronome described above, whole and still tested: two lines per tool call
  from `tool_input`/`tool_response`, templates so nothing can be invented, tools with no news silent
  by list (`TodoWrite`, `ToolSearch`, …). Owner `scripts/voice/tool-fact.py`, 36 fixtures. The
  register of the character this level imitates — *"The armour is now at 92%"* — and, for a person
  rather than a film, too much.
- **`prose`** — the assistant's own sentence from before the call, verbatim and truncated. Judges
  nothing, so it says the mechanical ones too.

### Thresholds — speaking up unbidden (`voice.autoplay.thresholds`)

| threshold | what it says | rules |
|---|---|---|
| a step **failed** | *cargo test ล้ม* | red cue, `milestone` kind (never dropped), and it **bypasses the rate floor and the per-turn cap** — a failure is the one thing worth interrupting for. Fed by the `PostToolUseFailure` hook event, so it does not have to guess from output text |
| the **same** step failed again | *cargo test ล้ม ซ้ำรอบ 2* | counted, not flagged: the third attempt is more news than the second |
| the turn is **running long** | *ผ่านมา 11 นาทีแล้ว ยังทำอยู่ ล่าสุด …* | single-shot per turn (and once more at 3× `long_turn_seconds`), and only on a step that actually ran |

The long-turn line is the one to be careful about, because it looks like the deleted heartbeat and is
not: a heartbeat fires on elapsed time **whether or not anything happened** and repeats; this fires
once, on a real step, and names that step.

### The gate voice — what is waiting for you (`voice.autoplay.gates`)

The most recognisable thing the character does is not narration at all: *"Shall I begin machining the
parts?"* — he names the big step and waits. Every gate in this workspace already existed and every one
of them was **silent**, so stepping away from the screen meant coming back to find nothing had
happened.

| event | spoken |
|---|---|
| `PermissionRequest` | *ขออนุญาตรัน cargo test ค่ะ* · *ขออนุญาตใช้ Write กับ main.rs ค่ะ* |
| `PermissionDenied` | *git push ถูก block ค่ะ* (red) |
| `PreToolUse(ExitPlanMode)` | *แผนพร้อมแล้ว ขออนุมัติค่ะ* |
| `Notification` | classified: permission → *ขออนุญาตทำงานต่อค่ะ* · agent done → *agent ทำเสร็จแล้วค่ะ*. An idle notification is deliberately unclassified — see below |

**Idle is not a gate, and there is deliberately no class for it.** Claude Code sends a
*"waiting for your input"* notification when a finished turn sits untouched, and speaking it
(*รอคำสั่งอยู่ค่ะ*) was the one line here that fired while somebody was **thinking**. Nothing is
blocked, nothing needs a decision, the turn already ended and the closing line already said what
happened — the only new information is that the person has not typed yet, which is the one fact they
cannot fail to know. Every other class names something that will not move until a human acts. The
notification falls through to the unclassifiable branch and stays silent.

`PermissionDenied` earns its place on its own: an auto-mode denial never becomes a prompt at all — the
model simply gets a refusal and reroutes, and [eight of them in one
ticket](../../CLAUDE.md) went unnoticed until the transcript was read back afterwards.

Two properties worth knowing: it **never reads the notification's own text aloud** (those messages are
English and this is a Thai voice — an event it cannot classify stays silent), and it dedupes on the
gate **class** rather than the wording, because one waiting prompt arrives as two events that word it
differently and would otherwise ask twice.

**Under Cursor, only part of this crosses.** The generated mirror can express `PreToolUse` and
`PostToolUse`, so the mid-turn narrator and the plan gate work there; `PermissionRequest`,
`PermissionDenied`, `Notification` and `PostToolUseFailure` have no Cursor equivalent and
`aiworks cursor` drops them (it says so at `scripts/aiworks-cursor.sh`). In Cursor you therefore get
the narration but not the permission/denial voice — same class of gap as workflows not crossing.

**Why it is not a timer, and why the first version of `max` was wrong.** That version tightened a
timed **heartbeat** instead — a background sleeper that said *"still working, currently X"* every 45 s,
ten beats. A clock fires whether or not anything happened, so it narrates a 3-second step never and a
90-second step twice, and it can only ever name the tool it happens to catch, never *why*. `max` is
not asking for liveness, it is asking to be told what is happening; that is a property of the **work**,
so the narrator hooks the step.

**That heartbeat has since been deleted outright**, not merely switched off: in use it read as an odd,
disembodied interruption, and once the narrator exists there is nothing a clock adds. Mid-turn speech
is therefore `max`-only and event-driven.

**What keeps it from becoming noise** — and note *where* each rule lives, because that is the part
that took a second pass to get right:

| rule | why |
|---|---|
| **the content gates** (`insight`) | length, then the model's `NONE`, then the block hash — described above. This is the rule that does the work now: what keeps the channel quiet is *having nothing to conclude*, not a clock |
| **dedupe** by hash | the same line is never spoken twice in a row. With `prose` this is essential — one block introduces ~5 tool calls (314 prose blocks against 1 523 tool calls, measured) — and with `facts` it catches three Reads of one file |
| **staleness** of 12 s, and a **depth of 3** per session, in the queue | a line about work that finished three steps ago describes the wrong moment. Load-shedding belongs on the **playback** side: only there is it knowable how far behind the voice actually is, and dropping is oldest-first. Matters most under `facts`, which can queue faster than speech; a conclusion arrives every few tool calls and rarely queues at all. Thresholds and gates are `milestone` instead, and are never dropped |
| **rate floor** of `narrate_gap` — **0, off** | it went 9 → 4 → 0. Under `facts` a floor drops one half of every step pair, since the two arrive about a second apart; under `insight` there is nothing to throttle, because the content gates already refuse most blocks. Set a number to buy quiet. One config key feeds the producer's floor and the queue's — when they disagreed (7 and 9), the shorter one was dead code |
| **per-turn cap** of `narrate_max_per_turn` — **0, off** | a number bounds a turn's TTS spend, but a ceiling is a cliff, not a throttle: the turn goes silent from line N onwards. When a number is set and it bites, `-v` says so — a silent cap reads as a broken feature |

**Two rounds of "too quiet" and one of "too much", in that order** — worth keeping because the fixes
pull in opposite directions. First the channel skipped most steps, and none of the three causes was
visible from outside: a 4-second floor in front of a channel whose lines arrived in pairs, a 25-line
per-turn ceiling that made every long turn go quiet halfway, and — the biggest — a queue that
superseded narration down to the **newest job per session**, so a burst of five steps queued five
lines and played one. All three were fixed. Then the result, working exactly as specified, turned out
to be the wrong thing: *not every command you will run and every result for every command*. The
throttles stayed off; what changed was the **unit** — from a tool call to a conclusion. A channel that
speaks only when there is something to conclude does not need a rate limiter, which is why the old
defaults are still 0.

It also stays quiet once the turn has **ended**: the closing line owns the end of a turn.

**`max` needs `narrate: true` to be itself** — the mid-turn voice is most of what the level buys, and
`voice.autoplay.narrate: false` keeps the ack and closing line while stopping the talking in between.
`aiworks voice status` says so outright when the two disagree, and prints the shape it will actually
use — naming the source, and any throttle that is set. Regression suite:
`scripts/voice/narrate-selftest.sh` (83 cases: the insight gates including "no summarizer call was
made", all three sources, the throttles, the queue's drop rules, the real hook, the thresholds and the
gate voice — in a throwaway tree with stubbed synthesis, so it costs nothing).

**Three prompt conflicts had to be resolved for it to work at all**, and the room the level adds is
what surfaced each one:

1. the report's *"do not describe your process, do not list what you did step by step"* — inverted at
   `max`. Left in, a prompt carrying both instructions is resolved by coin flip, differently every
   turn.
2. the ack's *"state the first step — **and stop**"* — replaced by the order of work. Left in, it was
   the more concrete instruction and the model obeyed it over the persona: measured, the `max` ack
   came back **shorter** than `chatty`'s (85 vs 92 characters) and named no order at all.
3. the reaction words the persona offers (`เรียบร้อยค่ะ`, `เจอแล้วค่ะ`) mean *finished* — harmless on
   a report, a **false claim** on an ack. Measured before the fix: *"ได้ค่ะ ฉันจะไปเช็คการ rounding …
   **เรียบร้อยแล้ว** จะรายงานผลกลับให้ทราบค่ะ"* — a completed check that had not started. The ack at
   `max` is now pinned to future tense with completion words banned outright; 3 runs of 3 clean after.

The first two were found by dumping the assembled prompt (`VOICE_SHOW_PROMPT=1`), the third by
listening to `aiworks voice audition`. Neither method would have caught the other's.

**Ceiling, not quota.** One fact means one sentence even at `max`. This is the level's safety
property, not a nicety: given room and nothing to fill it with, a model pads, and padding is one
step from inventing. Measured — at a fixed 3-sentence budget, the one-line input *"แก้ typo ใน
README แล้ว"* produced an invented next step in 4/4 runs and, once, an invented figure ("3 จุด").
So the budget is computed from the material as well as the level, and the sentence count follows the
budget. Re-measured at `max` — the level with the most room *and* explicit permission to narrate —
the same input produced one 33–38 character sentence in 3 runs of 3, with no invented step.

**Bad news keeps the plain register at every level** — `prod`/`error` intent and `red`/`incident`
group drop the softener and the reaction. Same ruling that keeps quips out: a warm turn of phrase
lands the third time, grates on the fiftieth, and will eventually fire mid-incident — and this is a
set-once preference nobody turns down before production breaks.

**Pick by ear, not from the table:**

```bash
aiworks voice audition "ช่วยเช็ค commission calculator ใน agent-webservice"
```

Speaks the same request at all four levels with the character count printed — but not `max`'s step
narration, which only exists inside a running turn and would be a demo of something you have not
turned on. Cost scales with the level: every line here is unique text, so none of it hits the cache.
At 100 turns/day on elevenlabs it is roughly **terse $48 · balanced $76 · chatty $105 · max ~$135**
per month — the first three measured; `max` extrapolated as ~$75 for its ack + closing line (now
shorter than `chatty`'s) plus ~$60 for the mid-turn narrator. That is **lower than the per-step
version's ~$135**, which is the pleasant surprise of the rewrite: a handful of conclusions a turn is
less audio than two lines for every tool call, and most blocks are refused before anything is
synthesized. `insight` adds a cheap-model call per substantive block — cents a month, not dollars.
`narrate_max_per_turn` is 0 (off) by default; set a number and that number is the ceiling, or
`narrate: false` to remove the channel. The `facts` source is the cheap one on paper — a fact line
repeats across turns (*"cargo test ผ่าน 42"*) and a repeated line is a **cache hit, therefore free** —
but paying nothing for lines nobody wanted to hear is not a saving.
`tts.provider: openai` (voice `sage`) is
~2.2× cheaper *and* measured best on Thai; `gemini` is ~6× cheaper but slowest and weakest of the
four. Every vendor's voices were swept — see `scripts/voice/README.md` § Thai voice selection.

## What it says, versus what is written

Two rewrites happen between a line of text and the audio, and both exist because the naive version
was wrong out loud.

**Identifiers are spelled, quantities are read as numbers — both in Thai.** `OFB-1598` is read
digit by digit, because every engine otherwise reads it as one four-figure number that nobody can
map back to a ticket; a branch gets the same treatment plus its separators, so
`feature/OFB-1598-add-cashback` is spoken as *"feature OFB หนึ่ง ห้า เก้า แปด add cashback"*. An
ordinary quantity stays a quantity but becomes a Thai **word** — `บรรทัด 142` is *"บรรทัด
หนึ่งร้อยสี่สิบสอง"*, `8%` is *"แปด เปอร์เซ็นต์"* — because a numeral is still spoken in some
language and the vendors disagree on which: ElevenLabs reads them in **English** mid-Thai-sentence
(*"มี two must fix"*, *"450 milliseconds"*) while the other three read them in Thai. Converting the
text takes that discretion away, so switching provider no longer changes what is said. Version
strings, times and dates are untouched (`gpt-4o`, `14:30`, `2026-07-29`). **`MR` and `PR` are
expanded** to *merge request* / *pull request* — read verbatim, `MR` comes out as the honorific
*Mr.*

**The session you are prompting in never introduces itself.** The identity prefix (the ticket key or
branch spoken before a sentence) is suppressed for the worktree that last received a prompt — you
know where you just typed. It plays only when a worktree you are *not* in speaks up: a background
`dev-cycle`, a slack-dispatch job, the other window. `aiworks voice status` says which case you are
in.

## Slack voice notes

`scripts/voice/notify-voice.sh` is `scripts/notify/send.sh` **plus a voice note** — one message
carrying the text and the audio. `dev-cycle.js`'s Notify phase already calls it, and with
`voice.notify_voice.enabled` off (the default) it forwards its arguments verbatim, so it is a
no-op for anyone who has not opted in.

The spoken line is a fixed sentence per event, not the message: the text keeps every detail
because that is what people read and click, and a canonical sentence is byte-identical every time,
so the audio cache hits on the second ticket and the voice note costs nothing after the first.

The existing notification etiquette is unchanged — product work auto-posts, workspace/framework
work asks first (see `CLAUDE.md`). A voice note does not make a message more welcome.

## Dictation

Hold the chord (`voice.push_to_talk.hotkey`, default both ⌘ keys), speak, release; the text is
typed into the frontmost session and sent. It never types into a window it does not recognise —
that goes to the clipboard instead.

```bash
aiworks voice ptt install     # generate the key handler AND reload Hammerspoon
aiworks voice mic-check       # calibrate the silence thresholds to your room — do this first
aiworks voice ptt doctor      # every prerequisite, in the order it breaks
```

Needs Hammerspoon with Accessibility and Microphone permission; `ptt install` prints what is left
to do by hand. `ptt doctor` is the thing to run when it does not work — it reads Hammerspoon's own
console, which is where a dead hotkey's cause actually hides.

**Nothing you said outlives the turn.** The moment the transcript is in hand, the recording is
deleted — the raw capture, the wrapped wav, the preview loop's two rolling snapshots and the interim
text — on every path, including silence, a transcriber failure and a cancel, and again at the start
of the next hold. The transcript itself is written to Hammerspoon's log only while
`aiworks voice ptt debug on`; otherwise the log records its length and not its words.

The acknowledgement you hear back is not a read-back of your words. It states what the assistant
understood the **task** to be, and naming the work is the acceptance — a sentence you could have
written yourself tells you nothing about whether you were understood.

## Credentials

```
~/.config/aiworks/voice.env     mode 600 — the real keys live here
scripts/voice/.env              per-clone override; EMPTY values are ignored
```

Machine-global first, because a Superset worktree gets **stub** adapter `.env` files in this
workspace and a per-repo-only path would leave voice dead in every worktree.
`GEMINI_VOICE_API_KEY` is deliberately separate from the image generator's `GEMINI_API_KEY`.

⚠ Never read, print, `grep` (without `-q`) or `bash -x` a real `.env` — see `CLAUDE.md`.

## Turned a flag on and the machine stayed quiet?

Check the flag's **value**, not the wiring. `enabled: ture` resolves to false, which is exactly
what a deliberate `false` looks like, so `aiworks voice status` says `off` — truthfully, and without
naming the typo. That is how `stagehand.enabled` stayed off for weeks. Both readers now log it
(`VOICE_VERBOSE=1` / `STAGE_VERBOSE=1`), and `aiworks config` reports it unprompted with the file,
the key and the value. A value in neither the truthy (`true`/`yes`/`1`/`on`) nor the falsy
(`false`/`no`/`0`/`off`) set resolves to the key's **documented default** rather than to an invented
`false`. `voice_cfg_int` has always defended itself this way; `voice_cfg_bool` now does too.

## Where the rest lives

- `scripts/voice/README.md` — the reference: every key, every provider, every measured number

`agent_logs/` is **git-ignored**, so the three working notes behind this feature —
`agent_logs/voice/implementation-plan.md` (the decisions and what measurement changed about
them), `wake-word-plan.md` (the deferred wake word) and `bench/` (the probes) — exist only on
the machine that built it. They are not in your clone and nothing reads them at runtime: this
page and `scripts/voice/README.md` carry every number that survived into a decision. Ask if you
want one of them promoted into `docs/`.
