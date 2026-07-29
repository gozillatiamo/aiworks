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

```bash
aiworks voice mute on      # the output half is DISABLED machine-wide — and costs nothing
aiworks voice mute off
aiworks voice status       # every switch that decides whether you hear anything, in order
```

Muted, nothing is summarized and nothing is synthesized: no ack, no milestone, no heartbeat, no
identity prefix, no dictation cue. The point is the bill — the alternative was paying for an LLM
call and a TTS call per turn to render audio into muted speakers.

One file (`~/.cache/aiworks/voice/mute`), so every clone and worktree goes quiet at once. There is
deliberately no automatic call detection: Google Meet is a browser tab with no process to find, so
an auto-detect would cover some calls and silently miss others.

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
    chattiness: balanced      # terse | balanced | chatty
```

**How much, never whether.** "Whether" already has four switches (`ack` · `milestones` ·
`heartbeat` · `milestone_every_turn`); a fifth thing that could also produce silence would give
"why is it quiet?" five possible answers and no way to tell which. It reaches the **ack and the
closing line only** — the heartbeat stays a template and the Slack voice note stays one canonical
sentence, because in both cases the repetition is what makes them free (they hit the audio cache).

The same finished turn, at each level:

```
terse     เอกสารแก้ครบ 6 ไฟล์ รอคุณสั่งค่ะ
          1 sentence, facts only. The length this feature shipped with — unchanged, byte for byte

balanced  เรียบร้อยค่ะ เอกสารแก้ไขครบ 6 ไฟล์ รอการอนุมัติจากคุณนะคะ
          + a 1–2 word reaction that states the outcome, + a softener, + the second fact

chatty    เรียบร้อยค่ะ การแก้ mute ทำให้ local speech เงียบครบ 4 ทาง และ voice note upload
          ปกติ 23031 bytes เอกสารแก้ครบ 6 ไฟล์ รอคุณสั่งค่ะ
          + the third fact, + the follow-through (what will be reported, what waits for you)
```

**Ceiling, not quota.** One fact means one sentence even at `chatty`. This is the level's safety
property, not a nicety: given room and nothing to fill it with, a model pads, and padding is one
step from inventing. Measured — at a fixed 3-sentence budget, the one-line input *"แก้ typo ใน
README แล้ว"* produced an invented next step in 4/4 runs and, once, an invented figure ("3 จุด").
So the budget is computed from the material as well as the level, and the sentence count follows the
budget.

**Bad news keeps the plain register at every level** — `prod`/`error` intent and `red`/`incident`
group drop the softener and the reaction. Same ruling that keeps quips out: a warm turn of phrase
lands the third time, grates on the fiftieth, and will eventually fire mid-incident — and this is a
set-once preference nobody turns down before production breaks.

**Pick by ear, not from the table:**

```bash
aiworks voice audition "ช่วยเช็ค commission calculator ใน agent-webservice"
```

Speaks the same request at all three levels with the character count printed. Cost scales with it —
ack and closing lines never hit the cache, so at 100 turns/day on elevenlabs it is roughly
**terse $48 · balanced $76 · chatty $105** per month. `tts.provider: openai` (voice `sage`) is
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

## Where the rest lives

- `scripts/voice/README.md` — the reference: every key, every provider, every measured number

`agent_logs/` is **git-ignored**, so the three working notes behind this feature —
`agent_logs/voice/implementation-plan.md` (the decisions and what measurement changed about
them), `wake-word-plan.md` (the deferred wake word) and `bench/` (the probes) — exist only on
the machine that built it. They are not in your clone and nothing reads them at runtime: this
page and `scripts/voice/README.md` carry every number that survived into a decision. Ask if you
want one of them promoted into `docs/`.
