# Voice adapter (`scripts/voice/`)

> Everyday commands are `aiworks voice mute on|off`, `aiworks voice status` and
> `aiworks voice test`. The scripts below are the primitives those forward to; hooks and
> skills call them directly.

Spoken output for the workspace: an acknowledgement when you send a prompt, a line when
something lands, and push-to-talk dictation. Same shape as the other adapters —
`scripts/notify`, `scripts/diagram` — so it is switchable by config and never called
directly by a skill or agent that could just as well go through the entry script.

**Status: complete and in use.** The core, cues, the per-prompt acknowledgement, the closing
line, the mid-turn narration, Slack voice notes and push-to-talk dictation are all built.
Dictation still needs four **manual** steps before it works — `aiworks voice ptt install`
prints them, and `aiworks voice ptt doctor` says which one is missing.

> **`agent_logs/voice/` is git-ignored** — every `agent_logs/voice/…` path cited below is a
> working note on the machine that built this, not a file in your clone. The measurements those
> notes justify are restated here and in `docs/agents/voice.md`, which are the committed
> record. Nothing in the adapter reads them at runtime.

## Three gates, all silent

```
language: th             ⇒ voice runs   any other language ⇒ exit 0, prints nothing
voice.enabled            ⇒ voice runs   false              ⇒ exit 0, prints nothing
voice.autoplay.enabled   ⇒ speech runs  false              ⇒ the hooks do nothing
```

Under `autoplay` the three kinds switch independently — `ack`, `milestones`, `narrate` —
because they wear out at different rates. A spoken line for every prompt is the first thing to
tire of; a line when an MR lands is the reason to turn any of this on.

Silent is deliberate. This is a personal preference bolted onto shared tooling: an adapter
that complained on every call would turn one person's setup into everyone's stderr noise.
Use `-v` to hear *why* nothing happened:

```bash
scripts/voice/speak.sh -v "ทดสอบ"
# voice: speak skipped: workspace language is 'en', voice is th-only
```

The committed `workspace.config.yaml` ships `voice.enabled: false`, so the feature is inert
for the team by construction. Opt in via the git-ignored `workspace.config.local.yaml`:

```yaml
voice:
  enabled: true
```

## Speaking

```bash
scripts/voice/speak.sh "APP-1952 ปิดแล้วครับ"                    # queue it and return
scripts/voice/speak.sh --sync "ทดสอบ"                            # block until spoken
scripts/voice/speak.sh -v --dry-run "ทดสอบ"                      # what would happen, no API
scripts/voice/speak.sh --provider cartesia --voice <id> "ทดสอบ"   # audition, no config edit
scripts/voice/speak.sh --cue ship --mix sting "merge แล้วครับ"     # cue under/around the line
scripts/voice/speak.sh --out /tmp/line.mp3 --no-play "…"          # render a file, say nothing
```

`--kind` sets queue priority: `milestone` and `manual` are never dropped, `ack` is
droppable chatter (see below).

## Everything is content-addressed

The cache key is `provider | voice | model | cue | mix | normalized text`, and the cached
file is the **finished, already-mixed** audio. So the second time a sentence is needed it
costs nothing and plays instantly — the next ticket's identical Slack line, a repeated
milestone, this worktree's identity prefix. The cache lives under
`~/.cache/aiworks/voice/`, **machine-global**, which means several worktrees share it:
running five at once makes speech *cheaper* per utterance, not dearer.

`voice.cache.max_mb` (default 500) caps it. Eviction is least-recently-**used** (access
time, and playback is an access), so the lines you keep hearing survive. `prefix/` and
`cue/` are exempt — a handful of tiny files with the highest reuse here, each costing an
API call to rebuild.

## One loudness, because vendors do not agree on one

Every synthesized line is levelled to `voice.tts.loudness` (default **−16 LUFS**, ceiling
−1.5 dBTP) before it is mixed and cached. This is not polish. Measured on the same sentence:

```
elevenlabs Sarah   -14.1 LUFS      gemini Leda       -19.2      cartesia Suda   -28.8
openai     nova    -19.7           cartesia Somchai  -22.6      openai sage     -31.5
```

**17 LU** — about "three times quieter" by ear, and it is per *voice*, not just per vendor
(`sage` sits 12 LU below `nova` on the same endpoint). Two things broke because of it:
switching provider or voice silently changed how loud the assistant is, so the system volume
you set yesterday is wrong today; and `--cue`'s bed level is a fixed gain, so the same `0.22`
buried the cue under Sarah and let it drown `sage`. After levelling, the spread across 308
cached clips is **1.7 LU** and every true peak sits at or below −1.7 dBFS.

`linear=true` keeps it a single gain change over the whole clip, so the voice's own dynamics
survive; ffmpeg drops to its dynamic mode only when linear gain cannot reach the target under
the peak ceiling. Every failure path is **fail-open** — the un-levelled line still plays,
because a sentence already paid for must not be lost to a cosmetic step.

```bash
aiworks voice normalize -n     # what the already-cached audio measures now
aiworks voice normalize        # level it in place — local ffmpeg, no API call, no credit spent
```

The migration exists so switching this on does not re-buy audio you already own. It is
idempotent, and it deliberately skips `cue/`: an integrated-loudness reading over a 0.6 s chime
is not trustworthy, and those levels were auditioned by ear against `CUE_VOL`. Cues do vary
(−12.2 to −21.4 LUFS measured) — a separate call, by ear, not this command's business.

## One queue, one lock, no daemon

```
enqueue → try the lock →  got it: drain the WHOLE spool, including other sessions' jobs
                       →  didn't: exit, because the holder will reach our job too
```

`flock(1)` does not exist on macOS, so the lock is `fcntl` via `python3`, held across an
`execv` so it covers the entire playback rather than one shell builtin.

Drop rules, applied at drain time (staleness is only knowable when it is your turn):

| kind | rule |
|---|---|
| *any kind* | dropped while **muted** |
| `milestone`, `manual` | otherwise never dropped, and always first in line |
| `ack` | dropped when >30 s old · only the **newest per session** survives · dropped inside 20 s of the last utterance |

```bash
scripts/voice/queue.sh status     # what is queued, who spoke last, is the lock held
scripts/voice/queue.sh purge      # drop every queued job (keeps the audio cache)
```

## Push-to-talk (phase 4)

Hold the chord, speak, release — what you said becomes the prompt.

```bash
aiworks voice ptt install     # generate ~/.hammerspoon/voice-ptt.lua AND reload Hammerspoon
aiworks voice ptt doctor      # every prerequisite, in the order it breaks
aiworks voice ptt keys        # what your keyboard actually reports, while you hold it
aiworks voice ptt simulate 4  # drive the whole chain with no key press at all
aiworks voice ptt reload      # restart Hammerspoon (its own `quit` needs AppleScript, off by default)
aiworks voice mic-check       # calibrate the silence thresholds to your room  ← do this first
```

`install` **reloads Hammerspoon itself**, because writing the file is not installing it:
Hammerspoon reads its config only at launch, and the first version of this left a perfectly good
handler on disk that had never executed — every check passed and the hotkey did nothing.

### The chord: `voice.push_to_talk.hotkey`

| value | notes |
|---|---|
| `left_cmd+right_cmd` | both ⌘ keys — exist on every keyboard, do nothing when held together, collide with nothing |
| `right_cmd+right_alt` | same idea, if your keyboard has a right ⌥ |
| `right_alt` / `right_cmd` | single key, must be **held past 0.25 s** so an ordinary tap is not a trigger |
| `fn+right_cmd` | **built-in Apple keyboard only** — see below |

Left and right are separate keycodes, which is why a right-side chord collides with nothing:
every existing ⌘-shortcut, Spotlight's ⌘Space included, keeps working.

**`fn` from an external keyboard does not exist**, measured: with a Keychron K1 attached, holding
`fn` + Right ⌘ delivered `keyCode=54 flags=[cmd]` and *no fn event at all*. Its `fn` is handled
in the keyboard's own firmware and never reaches macOS. No `AppleFnUsageType` value changes that
— that setting only stops a bare `fn` tap on the *laptop* keyboard from switching input source.

**A same-flag chord needs the raw device bits.** `flags.cmd` is set by *either* ⌘, so it cannot
answer "is Right ⌘ still down?" while Left ⌘ is held — a `left_cmd+right_cmd` chord would start
recording and never stop. The handler reads the per-key IOKit masks
(`NX_DEVICEL/RCMDKEYMASK`…) instead, which is exact for every side and combination; the cooked
flag remains a fallback for chords whose keys have different modifiers.

The split is deliberate: `ptt.sh` owns the **microphone and the transcript**, the Hammerspoon
handler owns the **keyboard** — the hotkey, the HUD, and whether the frontmost window is a
session it may type into. A shell cannot see the window list.

**Why that hotkey.** `fn` is a modifier no app binds as a chord root, and Right `⌘` is
distinguishable from Left `⌘` by keycode (54 vs 55) — so every existing ⌘-shortcut, Spotlight's
⌘Space included, keeps working untouched.

| during the hold | |
|---|---|
| release | transcribe → type → Enter |
| release just one key of the chord | same as release — the hold ends |
| `space` while holding | **review mode**: type it but do not press Enter, so you can fix a word. The key is swallowed, so it never reaches the app and ⌘+space never opens Spotlight |
| frontmost app is not a session | nothing is typed — the text goes to the clipboard and the HUD says which app it saw. Typing a dictated sentence into a browser form or a customer ticket is unrecoverable, so this is an allow-list |

**The preview is chunked, not streamed.** While you hold, the growing recording is
re-transcribed every ~1.5 s with the *cheap* model and the HUD updates; the text that actually
gets typed is always a final full-file pass through the accurate one. No websocket and no
realtime session — `gpt-realtime-whisper`'s per-minute price is unpublished. A 10 s utterance
costs about six extra `$0.003/min` calls, i.e. fractions of a cent. Expect the preview to
over-capitalize ("Commission Calculator") — that is the cheap model, and it is not what gets typed.

**A level meter answers the question the transcript can't.** The HUD draws a live bar from the raw
capture at ~12 fps, so it moves within a frame of your voice:

```
silence  ▁▂▂▁▂▂▁▁▁▁▁▁▁▂▁   (measured −48.9 dBFS)
speech   ▃█▇▆██▆█▇█▅▇▇▇▆   (measured  −7.2 dBFS)
```

No network, no process, no cost — it reads the tail of a file that is already being written, which
is only possible because capture is raw PCM. dBFS with a −55 dB floor, because a linear bar barely
moves for speech. "It feels laggy" usually means "I can't tell if it heard me", and a transcript
cannot beat the recognizer — this can.

Getting the *text* under ~0.3 s would mean replacing the batch poll with a streaming
WebSocket (Cartesia `ink-whisper` measured the fastest at 0.33 s; Gemini Live is the other
candidate). Apple's `SFSpeechRecognizer` looks free but `th-TH` has no on-device asset, so it goes
to Apple's servers anyway — a probe is kept at `agent_logs/voice/bench/sfspeech_probe.swift`.

Measured cadence: a transcript update every **~1.5 s**, and it stays flat at 24 s of speech because
only the last `preview.window_seconds` (default 12) is re-transcribed. Sending the whole prefix every pass
made the lag grow with the utterance — 0.98 s at 2 s of audio, 1.86 s at 10 s and rising. The
trade: on a long dictation the HUD shows the tail, not the beginning.

**Capture is raw PCM, not wav**, and that is load-bearing: ffmpeg writes a wav's header last and
buffers the audio, so a wav being recorded into stays at **zero bytes** until the process exits.
The preview had nothing to read and silently showed nothing. Raw PCM has no header, so any prefix
of the file is already valid audio.

**The cue fires when capture is live, not when recording is requested.** avfoundation needs
0.23–0.25 s to open the device (measured), so a cue at spawn time told you to start talking a
quarter-second before anything was being recorded — and the first word was lost every time.
`ptt.sh` waits for the first bytes to land, then plays the cue, so the cue means "speak now".
`preview.provider: none` turns it off — and then `auto_send` is **forced** false, because
pressing Enter on words you were never shown is not a feature.

### Two guards, both from measured failures

**Silence must never reach the API.** Handed silence, `gpt-4o-transcribe` returns *its own
prompt* as the transcript — a 7 s hold with nothing said came back as the entire domain hint,
which would have been typed into the session and sent. So a recording is screened first (too
short, or quiet by both mean **and** peak), and `listen.sh` independently discards a transcript
that looks like the hint echoed back, or a handful of characters out of near-silent audio (a
real hold produced the single word "context").

**The thresholds ship conservative and need calibrating.** Two silent recordings on the dev
machine measured 17 dB apart — fan and keyboard — and the loud one sailed past a −50 dB floor.
Discarding only when *both* measures are low means a wasted call now and then rather than a lost
sentence. `aiworks voice mic-check` records your silence and your voice, prints both, and tells
you what to put in `silence_db` / `silence_peak_db`.

### Nothing you said outlives the turn

The recording exists to produce a transcript, and once there is one it is deleted — **before** the
text is even printed, so nothing downstream can fail in a way that leaves audio behind. There are
five files, not one:

```
rec.pcm  rec.wav          the capture, and the wav wrapped for the transcriber
snap.pcm  snap.wav        the preview loop's rolling window (the last 12 s of you)
preview.txt               the interim words themselves
```

`_wipe_audio` removes all five on **every** path — success, silence, a transcriber failure, a
cancel — via an `EXIT` trap on `stop`, and again at the start of the next hold as a safety net for a
run that was killed mid-flight. The preview loop additionally traps `TERM`, because `stop` kills it
and its own tidy-up would otherwise never run: that is exactly how a stale `snap.pcm` used to sit in
the cache directory between sessions.

The **transcript** is written to Hammerspoon's log only while `ptt debug` is on. Otherwise the log
records its length and not its words — logging the text permanently would put back on disk exactly
what was just deleted, one representation over.

### The microphone follows your system default

`mic: default` resolves whatever **System Settings → Sound → Input** is set to, so plugging in a
headset moves dictation with it. Set a device **name** (substring, case-insensitive) to pin one
instead. `ptt status` says which of the two is in force, and the resolved name is logged on every
recording.

An avfoundation **index** is never accepted, in config or in code. The numbering is whatever is
plugged in at the time: index 0 was the built-in mic when this was planned and an Arctis headset
by the time it was built. A wrong index does not error — it records a microphone you are not
talking into, and the only symptom is a transcript that makes no sense.

## Speech-to-text

```bash
scripts/voice/listen.sh -v FILE                      # any audio file → text
scripts/voice/listen.sh --provider gemini --fast F    # audition another engine
```

| `voice.stt.provider` | measured | |
|---|---|---|
| `openai` (default) | **0.915** / 1.37 s / $0.36 per hr | best measured; keeps English terms in Latin script |
| `elevenlabs` | 0.889 / 2.05 s / $0.22 per hr | accurate but over-capitalizes; per-hour pricing |
| `gemini` | 0.837 / 2.5–3.2 s / **$0.115 per hr** | cheapest by 3×; least accurate |

`stt-hint.txt` is the domain vocabulary sent with every request, and it is load-bearing: without
it `null check` came back as "now check". **Add to it whenever dictation mis-hears a name you use
often** — every term in there is one an engine got wrong.

Round-tripped through TTS on this machine (`shard 3` is still the weak spot for all three):

```
said:        … ทำไม null check ที่ shard 3 ทำให้ payout หาย
openai   →   … ทำไม node check ที่ shard 3 ทำให้ pay-out หาย
gemini   →   … ทำไม null check ที่ chart 3 ทำให้ payout หาย
11labs   →   … ทำไม No Check ที่ชาร์จสาม ทำให้ Payout หาย
```

## Mute

```bash
aiworks voice mute on       # this machine says nothing — and pays for nothing
aiworks voice mute off      # reports it if the SYSTEM output is still muted, which also silences
aiworks voice mute          # report (bare form never toggles — a mute you can't see the
                            # state of is how you stay muted for a day without knowing).
                            # Prints `muted (system output)` when that is what is holding it
```

**Two switches, one meaning.** `voice_is_muted` in `lib.sh` is true if EITHER holds:

| | how | state | function |
|---|---|---|---|
| by hand | `aiworks voice mute on\|off` | one file, `~/.cache/aiworks/voice/mute` | file test |
| by the OS | the mute key / menu-bar slider / Control Centre | macOS holds it | `voice_os_muted` |

`voice_mute_reason` prints which one — `hand` \| `os` \| empty. Every status line uses it: "muted"
that does not say *which* mute sends you to unmute the wrong one.

- **An off switch, not a volume knob.** Muted, nothing is summarized and nothing is
  synthesized — ack, closing line, narration, gate voice, identity prefix, cues, sound effects,
  dictation cues and a direct `speak.sh` alike. So speech costs **zero** while it is on, instead
  of paying for an LLM call and a TTS call per turn to render audio nobody hears.
- **Global.** The hand mute is machine-wide, so every clone and worktree goes quiet at once. The
  OS mute is the machine's own state, so it needs nothing of ours.
- **Checked at every producer**, before it spends: `ack.sh` before the summarizer,
  `milestone.sh` before the summarizer, `narrate.sh` and `gate.sh` first thing, `speak.sh` before
  synthesis, `identity.sh` before the prefix synth, `sfx.sh play` before `afplay`, the
  `UserPromptSubmit` hook before the inline `ack` cue — and once more at drain, so anything queued
  before you muted does not slip out.
- **Drops, not defers.** Unmuting must not fire a backlog of everything you chose not to hear.
- **Drop the `.sh` and it is `aiworks voice mute`**, on purpose: this is the one thing a person
  does with the feature by hand.

### Reading the OS mute

`osascript -e 'output muted of (get volume settings)'`, ~120 ms measured. Affordable because every
producer runs DETACHED (nohup'd out of the hook), so it is never on the user's turn — and it buys
back a whole LLM + TTS round-trip. Two details that are not incidental:

- **Memoized for one second, not for the process.** `queue.sh`'s drain asks once per job while it
  plays a backlog; a mute pressed mid-drain has to stop the rest of it, and a per-process memo
  would carry a stale "not muted" through the whole queue.
- **`output muted` only, never `output volume == 0`.** macOS reports volume 0 for HDMI / AirPlay /
  optical output, where the external device owns the volume — treating 0 as silence would kill the
  feature for anyone on a monitor's speakers. When the field cannot be read at all (not macOS) the
  answer is *not muted*: failing open keeps a working feature working. `VOICE_OS_MUTED=1|0` forces
  it, which is how `narrate-selftest.sh` covers all of this with no audio device.

The inline `ack` cue is the one output that used to escape mute entirely: it never went through
`speak.sh` or `queue.sh`, so a muted machine still went "bong" on every prompt. The hook now does
the check inside the background subshell that plays it — the hook returns as fast as before and the
cue lands ~130 ms in rather than ~10 ms, still inside the 400 ms that makes it read as *heard you*.

### What mute is NOT about

Two things it deliberately does not touch, because neither one is this machine talking:

| | switch | why not mute |
|---|---|---|
| Slack voice note | `voice.notify_voice.enabled` (workspace config, `.local` overrides) | the audio is a deliverable for the TEAM — rendered here, heard on someone else's phone. Whether the channel gets one is a standing policy set once, not a question about the state of my speakers, and a muted laptop is not a reason to send the team less. `speak.sh` exempts `--no-play`, which is the flag `notify-voice.sh` renders with |
| dictation | `voice.push_to_talk.enabled` | INPUT, and it runs only while you hold the key, so there is no background spend to save. A mute that stopped you dictating would be the switch breaking a feature you just explicitly asked for. Only its two cues go quiet |

`--dry-run` is exempt for a third reason: it calls no API and writes nothing, it *is* the
diagnostic, and one that went silent while muted would hide the report you ran it for. It prints
`mute ON` instead.

`sfx.sh generate` is exempt on the same grounds: it is a setup step you ran on purpose and its
output is a *file*, not a sound. `sfx.sh play` is not exempt — a cue is output — and it prints
`muted (<reason>)` rather than doing nothing, because silence with no reason reads as a broken
cue file.

**The hand mute is a file, not a config key**, because it is a "for the next twenty minutes"
decision — config would mean editing it to go quiet and forgetting to edit it back. The two
switches in the table above are the reverse: standing decisions, so they live in config and nowhere
else. The OS mute is neither: it is the machine's own state, already in the place people reach for.

**There is no automatic call detection**, by decision — and honouring the OS mute is why it is no
longer missed. An earlier version `pgrep`'d for Zoom/Teams/Webex and was removed: Google Meet is a
browser tab with no process to find, so auto-detect would cover some calls and silently miss
others. Muting the machine before a call is the switch people already reach for by habit, and it
now costs nothing.

## The acknowledgement (phase 2)

Every prompt — typed or dictated — gets a two-beat answer. The pattern is fixed, with no
config: knobs per beat would mean nobody ever tunes any of them.

```
t=0 ms     the `ack` cue, from cache          ← the hook plays this and returns in ~60 ms
t≈1.3 s    the summarizer writes one Thai line  (measured, openai gpt-4o-mini)
t≈4.2 s    that line is spoken                  (measured end to end)
```

It stays quiet when speaking would be worse than silence:

| situation | why |
|---|---|
| prompt under 12 characters | "go", "ต่อ" — the cue already said everything |
| a session-management command | `/clear`, `/compact`, `/model` … an explicit list, not a guess: `/dev-cycle APP-1952` still gets an ack |
| the turn already ended | the answer is on screen; "กำลังไปดู X" after it is worse than nothing |
| a newer prompt arrived | this ack would describe the previous request |
| the machine is muted | `aiworks voice mute on`, **or** the system output is muted — checked before anything is spent |
| the summarizer returned nothing | speak nothing rather than a canned "รับทราบครับ" — filler on every failure is what this feature must not become |

**It states the task, it does not read your words back.** The summarizer is told it is ACCEPTING
the request and must say what it understood the work to be, in its own words — naming the work *is*
the acceptance, so there is no separate "รับทราบ" beat. A paraphrase of the prompt is explicitly
ruled out: you just said it, and a sentence you could have written yourself tells you nothing about
whether you were understood. A `/name` prompt is treated as invoking that workflow or skill —
*"เริ่ม dev-cycle ของ APP หนึ่ง ห้า เก้า แปด"*, never the literal slash command read aloud. Dev
vocabulary stays English (ticket, branch, review, commit, deploy): the model reached for *ตั๋ว* for
"ticket" until it was told not to.

What varies, per request: the mood (from the intent — prod/error/ship/review/test/plan), the
phrasing (six shapes, **rotated** not random, so two in a row are never the same), the time of
day, and the voice when an alternate is configured. What never varies: no invented jokes. A
quip lands the third time, grates on the fiftieth, and will eventually fire during an incident.

The Thai sentence-final particle is pinned to the voice's gender (`ครับ` male / `ค่ะ` female)
— a male voice saying "ได้เลยค่ะ" was a real bug in the demo round. The prompt asks for it, and
**the end of the pipe enforces it** — asking was measured to fail about 1 in 5 ("ได้ค่ะ … รอผลการตรวจสอบ
**ครับ**", both genders in one sentence, heard on a live run). `_pin_particle` corrects a
wrong-gender ending and `_add_particle` supplies a missing one, preserving the `นะ` softener
(`นะคะ`/`นะครับ` are a different register from bare `ค่ะ`/`ครับ`). Both are awk/sed on the final line, so
they cost nothing and cannot be talked out of it.

`aiworks voice test` used to hardcode `--particle 'ครับ'`, so the one command whose job is *prove you
can hear it* spoke the wrong gender on a female voice. It now derives the particle from the voice like
every other caller.

```bash
scripts/voice/ack.sh -v "the prompt"        # run the whole chain by hand, with reasoning
scripts/voice/summarize.sh -v "the prompt"  # just the one-line rewrite
aiworks voice test                          # end-to-end, with timings
```

Wired as two hooks in `.claude/settings.json`: `voice-ack.sh` on `UserPromptSubmit` (plays the
cue, forks, returns — it sits in front of your turn, so it does no network work at all) and
`voice-milestone.sh` on `Stop` (closes the turn, which is what lets a slow ack notice the
answer beat it). Both print nothing: a `UserPromptSubmit` hook's stdout becomes model context.

## Milestones (phase 3)

The closing line: what the finished turn actually **produced**, as opposed to the ack that fires
when you ask for it. **Every turn that ends with a reply speaks one** — the ack says what is
starting, this says what came out of it, and the second half is the one you cannot get from
glancing at the screen.

This is the reverse of how it shipped (*silence is the default*, unless a tag or a narrow keyword
match), changed after using it: staying quiet on most turns meant the feature announced the start of
the work and then never told you it was done.

| | | |
|---|---|---|
| **cost** | ~$0.01 a turn | one summarizer call + one TTS call; a finish summary is unique text, so it never hits the audio cache. A tagged turn costs only the TTS |
| **noise** | one utterance on a short turn, two on a long one | a fast turn's ack is dropped by the existing "the turn already ended" rule, so you hear the result and not both |
| **back down** | `milestone_every_turn: false` | only a tagged turn speaks. `milestones: false` for none at all; `ack: false` if the *opening* line is the one you tire of |

### Declare a milestone with a tag

Put a `VOICE:` line anywhere in the reply. This is the mechanism to reach for: it costs nothing
(no summarizer call), says exactly what you meant, and picks the cue.

```
VOICE[ship]: APP-1952 merged เข้า develop แล้วครับ MR !12 ปิดแล้ว
```

| group | for | cue |
|---|---|---|
| `[green]` | tests pass, review approved, QA good | chime at the **tail**, landing as the sentence does |
| `[red]` | must-fixes, failures | buzz **under** the words at 0.15 — the words stay loudest |
| `[ship]` | MR/PR opened, merged, ticket Done | fanfare **first**, then talk over its tail |
| `[needs-you]` | a plan awaiting approval, a question, a blocked gate | neutral chime at the tail |
| `[incident]` | production is unhappy | urgent register, cue under the words |
| bare `VOICE:` | anything else | no cue, words only |

Only the **first** tag in a reply is used: one turn has one outcome, and the first is where a
writer states it.

### Without a tag: the reply is summarized

An untagged turn (a workflow run, an agent, an ordinary answer) goes through the summarizer in
`report` mode over the reply's last text block — past tense, grounded in the reply's own words,
forbidden from inventing a name or a number that is not in it.

**"I finished" is not a result.** This is the failure mode that matters now that it runs every turn:
`เสร็จแล้วครับ` / `อธิบายให้ฟังแล้วครับ` reports the act of finishing, which the user can already see.
The prompt forbids it outright and demands the finding, the number, the verdict, or what is now
waiting for them — and for a turn that only *answered* something, the answer's conclusion.

The keyword match still runs, but **only to pick the cue**, never to decide whether to speak. It
stays narrow — corroborated evidence only: an MR/PR URL *beside* a merge word, a count *beside*
`must-fix`, a verdict *beside* a test word, a figure *beside* a production error. An earlier version
matched bare words and would have announced a merge because a reply *discussed* merging; a fanfare
over a merge that did not happen is worse than no cue at all. No match ⇒ words only.

`voice.autoplay.milestone_every_turn: false` returns to tag-only. (The pre-rename
`milestone_backstop` is still honoured in its `false` position, which meant the same thing.)

```bash
scripts/voice/milestone.sh -v --say '[ship] APP-1952 merged แล้วครับ'   # bypass detection
scripts/voice/milestone.sh -v --text "<a reply>"                        # test classification
```

## Mid-turn speech: there used to be a heartbeat, and it was removed

`heartbeat.sh` was a background sleeper spawned per turn that said *"ยังทำงานอยู่ครับ ตอนนี้ X"* on a
clock — 90 s, then 3 min, then 5 min, capped at six. **Deleted, not defaulted off.** In use it read as
an odd, disembodied interruption, and the reason is structural rather than a matter of tuning: a clock
fires whether or not anything happened, so it narrates a 3-second step never and a 90-second step
twice, and it can only name whichever tool it happens to catch — never why that tool.

Mid-turn speech is now the **conclusion narrator** (below): `chattiness: max` only, one line each time
something is WORKED OUT, spoken because the work moved forward rather than because time passed — plus
the **thresholds** (a step failed, it failed again, the turn is long) and the **gate voice**
(something is waiting for you), which are events for the same reason. At
every other level nothing is spoken between the ack and the closing line except a gate, which is
level-independent because "this is waiting for you" is not a matter of talkativeness.

## Slack voice notes

```bash
scripts/voice/notify-voice.sh --review APP-1952 --title "…" --channel "#dev-acme"
```

`notify-voice.sh` is `scripts/notify/send.sh` **plus a voice note** — one Slack message carrying
the text *and* the audio. With `voice.notify_voice.enabled` off (the shipped default) it forwards
its arguments verbatim, so it is a safe drop-in; `dev-cycle.js`'s Notify phase already calls it.

The spoken line is **not** the message. The text keeps every detail — ticket key, title, one URL
per repo — because that is what people read, search and click. The audio is one canonical
sentence per event (`review` / `ship` / `approved` / `must-fix`), byte-identical every time, so
the cache hits on the second ticket and every ticket after it and the voice note costs **nothing**
after the first. Speaking the digest instead would embed the ticket title, make every message a
unique string, and turn a free feature into a per-notification charge — for detail already on
screen.

`--reply` (a verdict threaded under the request) forwards **without** audio: thread discovery
lives inside the notify adapter, and attaching a file to a thread the caller has not resolved
would mean two messages.

**Mute does not apply here.** Mute is about this machine's speakers; this audio is for the team, and
a muted laptop is not a reason to send them less. The one switch is `voice.notify_voice.enabled` in
workspace config — a standing decision, not a "for the next twenty minutes" toggle. `speak.sh`
exempts `--no-play`, which is what this renders with.

## Sound cues

Eight cues — `ack`, `attention`, `ptt_start`, `ptt_stop`, `green`, `red`, `ship`, `incident` —
generated once and then free forever.

```bash
scripts/voice/sfx.sh generate [--force]   # build the catalog (voice.sfx.provider)
scripts/voice/sfx.sh list                 # what exists, how long, how loud
scripts/voice/sfx.sh play ship            # hear one
```

`voice.sfx.provider` is `elevenlabs` (a text prompt per cue; on the Starter plan this moved the
credit counter by **zero** in measurement) or `system` (macOS `/System/Library/Sounds` — no
network, no key). Noiz is deliberately not a provider: its skills are being removed, and a
provider for a vendor we are cancelling is dead code.

Every cue is **peak-normalized to −6 dBFS at generation time**. Without it the generated set
came back spanning −12.5 dB to 0.0 dB, and the loud one startles you at 1am.

Cues mix against speech four ways (`--mix`), all local ffmpeg, zero runtime cost:

| mix | shape | used for |
|---|---|---|
| `under` | cue beneath the whole line at low volume | bad news (`red`, `incident`) at 0.15 |
| `sting` | cue alone, voice in at 900 ms, cue fades out | delivery (`ship`) |
| `duck` | true sidechain ducking — the voice triggers it | a long line over a bed |
| `tail` | cue arrives as the sentence lands | a passed review |

## Identity prefix

Multiple worktrees speaking into one pair of ears needs a "who is this". First hit wins:

1. `<root>/.aiworks/voice-identity` — one line, spoken verbatim. `.aiworks/` is git-ignored.
2. ticket key from the branch + the ticket title (one tracker call, then cached).
3. the branch slug (`feat/slack-dispatch` → "branch slack dispatch").

```bash
scripts/voice/identity.sh text      # what this checkout will announce itself as
scripts/voice/identity.sh clear     # after renaming a branch or a ticket
```

**The focused session never introduces itself.** The worktree that last received a prompt
attaches no prefix at all — you know which one you just typed in. The signal is written by the
`UserPromptSubmit` hook (`voice_focus_set`), which is the only honest source for it, and read by
`speak.sh` *before* synthesis, so a suppressed prefix costs nothing either. `aiworks voice status`
prints which case this checkout is in.

For every other session — a background `dev-cycle`, a slack-dispatch job, the other window — the
prefix plays when that session is not the one that spoke last, or after 60 s of silence. Not
hearing it when three worktrees interleave makes the whole thing useless.

The prefix goes through the same spoken-form rewrite as everything else, which matters most here:
a raw `APP-1598` is read as one four-figure number.

## Chattiness — how much it says

`voice.autoplay.chattiness: terse | balanced | chatty | max`, resolved by `voice_chattiness` (lib.sh),
overridable per call with `VOICE_CHATTINESS` or `summarize.sh --chattiness`.

**Scope: how much, never whether.** "Whether" has four switches already; a fifth that could also
produce silence would give "why is it quiet?" five answers. `terse`…`chatty` reach the **ack +
closing line** only; `max` also turns on the **mid-turn narrator** (`narrate.sh`), which is the only
mid-turn voice the feature has. The Slack voice note stays one canonical sentence at every level,
because its repetition is what makes it free.

| level | sentences | ack cap | closing cap | personality allowed |
|---|---|---|---|---|
| `terse` | 1 | 90 | 120 | none — facts only. **The shipped prompt, byte for byte** |
| `balanced` | ≤2 | 140 | 200 | + softener (`ให้นะคะ`) + 1–2 word reaction (`ได้ค่ะ`) + 2nd fact |
| `chatty` | ≤3 | 200 | 280 | + 3rd fact + follow-through (what will be reported / what waits) |
| `max` | ≤4 | 260 | 360 | + **step order** in the ack — + a **conclusion spoken during the turn** each time something is worked out: the finding, its cause, the next move |

**The ladder above `terse` is the ROOT checkout's alone.** `voice_chattiness` clamps a linked worktree
to `terse` whatever the config resolves to, off the same `VOICE_MAIN_CLONE` (`--git-common-dir`) test
layer 2 of the config chain uses — and it has to, because that layer *deliberately* reads
`<main clone>/workspace.config.local.yaml`, so a worktree inherits the root's `max` instead of falling
back to the shared `terse`. The worktree session is usually the unwatched one (a background
`dev-cycle`, a slack-dispatch job) and `max` is the level that speaks per STEP; both checkouts share
one spool and one pair of speakers, so two `max` sessions queue rather than take turns. Since
`narrate.sh` gates on `== max`, the mid-turn narrator switches off in a worktree as a consequence rather
than as a second rule to keep in sync. `VOICE_CHATTINESS` is **not** clamped — a human typing one
audition or one test is per-invocation intent, not a machine preference. `aiworks voice status` prints
the configured level and the owning checkout when the two disagree. Owner:
`scripts/voice/chattiness-selftest.sh` — **10 cases** against a real `git worktree` rather than a
hand-set `VOICE_MAIN_CLONE` (which would prove only that an `if` works, and would keep passing after
the detection itself broke), including the case that keeps the suite honest: the worktree's **raw**
value is asserted to still be the root's `max`, so the clamp case cannot pass for the wrong reason —
an absent value rather than a clamped one. The end-to-end consequence (a real payload through
`narrate.sh`, silent in the worktree) stays in `narrate-selftest.sh`, which already has the harness.

Three graded pieces, each picked for what it *cannot* do: a **softener** is 2–3 characters and cannot
carry a false fact; a **reaction** states the outcome in itself, unlike a greeting, which costs
characters and says nothing; **follow-through** is a fact about the next step, not a connective.
Greetings, jokes and evidence-free opinions are not on the ladder at all — same ruling as the ban
on quips (§9.2).

### `max` — the only level that narrates

The first three differ in **length**; `max` differs in **what it may talk about**. Narration is
forbidden at every other level (there, the process is filler around the one fact that matters) and is
the requested content here. Register: a flight engineer reporting to the person in charge, shape
*[subject] [state] [figure]* — the prompt **describes** it rather than naming the character from the
films, because naming it produces a Thai butler impression and the useful half of that voice is the
status-report shape, not the accent.

Three conflicts in the assembled prompt had to be resolved for the level to do anything. The first two
were found by dumping the prompt (`VOICE_SHOW_PROMPT=1`), the third only by listening to
`aiworks voice audition` — neither method would have caught the other's:

| the shipped line | at `max` | why it mattered |
|---|---|---|
| report: *"do not describe your process, do not list what you did step by step"* | *"list the steps you actually took, in the order you took them — one status each"* (`NO_PROCESS`) | a prompt carrying both instructions is resolved by coin flip, differently every turn |
| ack: *"state the concrete work… the first step — **and stop**"* | + *"and then the ORDER you will take it in, but only as far as the request itself pins that order down"* (`ACCEPT_SHAPE`) | measured: with "and stop" left in, the `max` ack came back **shorter** than `chatty`'s (85 vs 92 chars) and named no order — the concrete instruction beat the persona |
| `_persona`'s reaction words `เรียบร้อยค่ะ` / `เจอแล้วค่ะ`, offered to **both** kinds | ack only: future tense pinned, completion words banned by name (`ACCEPT_SHAPE`) | those two words mean *finished* — fine on a report, a false claim on an ack. Measured: *"ได้ค่ะ ฉันจะไปเช็คการ rounding … **เรียบร้อยแล้ว** จะรายงานผลกลับให้ทราบค่ะ"*, a completed check that had not started. 3/3 clean after; the extra room is what surfaced it — one sentence has no space for both a future clause and a completion word |

Both keep the clamp that makes narration safe: only steps **the text actually contains**. Permission
to describe a process is exactly the permission a model would use to invent a plausible one. The
`NO_PROCESS` swap holds under `--plain` too — bad news drops the *warm* register, not the detail, and
"test แดง 3 ตัว, retry แล้วยังแดง" is the shape you want from an incident report.

`chatty` keeps its wording untouched even though its follow-through clause has a milder version of the
same tension: that text is measured, and adding a level is not licence to re-tune one nobody asked
about. Verified mechanically — all six existing prompt variants (3 levels × ack/report), plus their
`--plain` forms, are byte-identical to `HEAD`.

### `terse` is byte-identical, and that is checkable

```bash
VOICE_SHOW_PROMPT=1 scripts/voice/summarize.sh --chattiness terse --particle 'ครับ' --seed S x
```

No persona line, no ceiling line, the singular *"End the sentence with the particle"*, and the
sentence phrase still carries its own verb agreement (`ONE short Thai sentence **that says**`) so the
level specified as "unchanged" really is. The word `single` in *"the single most important number"*
is likewise kept only at `terse` — at three sentences there is room for two figures and pinning it to
one would throw the second away.

### The mid-turn narrator (`narrate.sh`) — `max` only

`PreToolUse`, `PostToolUse` and `PostToolUseFailure` → `narrate.sh`, detached, one temp file carrying
the hook payload (the response can be a whole file's contents, so argv is not an option and the reader
deletes the file — including before an `exec`, which the `EXIT` trap never sees). The `PreToolUse` side
sits between the model and its tool, so what makes it safe there is the shape of the hook: it exits 0
on every path, prints nothing on stdout, and forks. See the header of
`.claude/hooks/voice-narrate.sh` — the objection is written down next to what answers it.

**`narrate_source: insight` (default)** speaks one line per thing WORKED OUT, from the assistant's own
reasoning block, via `summarize.sh --kind insight`:

> *root cause คือ submodule pointer ค้างที่ APP-631 เพราะ teardown.sql พัง จะ bump แล้วรัน scoped test ใหม่ค่ะ*

The unit is a **conclusion**, not a tool call. Three gates, and the first two are what make it usable:

| gate | rejects | cost |
|---|---|---|
| `MIN_BLOCK` = 100 chars | a preamble (*"อ่าน queue.sh ก่อน"*) cannot hold a finding | free |
| the model answering `NONE` | a long block that is still only mechanics | one cheap-model call |
| the BLOCK's hash (`iblk`) | the same block, re-seen by every following tool call | free — the one dedupe that saves money, not just noise |

`NONE` is a **token to emit**, not an instruction to be quiet: told to "reply with nothing", the model
answered a mechanical block with an invented completion *and* an invented review request. The refusal
also has to be the **first** line of the prompt — the persona, ceiling, particle and closing "output
the sentence only" all push toward producing a sentence, so a refusal in the middle loses. Measured
after both fixes: 3/3 refusals on two mechanical blocks, 3/3 conclusions on a real finding. It
**never falls back** to the step sources, or *รัน cd* returns one silence at a time.

**`narrate_source: facts`** builds both of a step's lines from the call's own payload via
`tool-fact.py` — verb-first before, then subject/state/figure after. This was the default until the
person it was built for said *not every command you will run and every result for every command*:

| step | before (`PreToolUse`) | after (`PostToolUse`) |
|---|---|---|
| `Read queue.sh` | `อ่าน queue.sh` | `queue.sh อ่านแล้ว 260 บรรทัด` |
| `Bash cargo test` green / red | `รัน cargo test` | `cargo test ผ่าน 42` / `cargo test ตก 3 ผ่าน 39` |
| `Grep voice_cfg` | `ค้น voice_cfg` | `voice_cfg เจอ 14 แห่ง` |
| `Edit narrate.sh` | `แก้ narrate.sh` | `narrate.sh แก้แล้ว 12 บรรทัด` |
| `Glob **/*.sh` | `หาไฟล์ .sh` | `เจอ 42 ไฟล์` |
| `Agent Explore` | `เรียก agent Explore` | `agent Explore ตอบแล้ว` |
| `WebFetch` | `ดึง code.claude.com` | `ดึง code.claude.com แล้ว` |
| `mcp__pg_triage__execute_sql` | `ถาม pg triage execute sql` | `pg triage execute sql ตอบ 5 แถว` |
| `TodoWrite`, `ToolSearch`, `TaskList`, … | *nothing* | *nothing* — `SKIP_TOOLS`, because a line per bookkeeping call is a metronome |

Neither a glob nor a regex is read aloud on the before-side (`หาไฟล์ .sh`, not `**/*.sh`): punctuation
spoken by a TTS engine is noise, and the extension is the only speakable part of a pattern. An intent
is **always `info`** — a call that has not run cannot have failed — and `fact()` dispatches on the
event itself, so a `PreToolUse` payload cannot reach the result templates and come back saying
`อ่านแล้ว 0 บรรทัด`. Own switch: `narrate_intent`, `true` by default.

Test figures are read out of the runner's OWN summary line — cargo (`test result: ok. 42 passed`),
jest (`Tests: 3 failed, 42 passed`), mocha/cypress (`42 passing`), pytest — so a figure is spoken only
when a runner printed it. A failure is decided **before** the success templates run, so
`{"is_error": true}` says `gone.txt อ่านไม่ได้` rather than counting the error envelope as one line of
content (measured: it did, once).

**`narrate_source: prose`** is the earliest mechanism, and the fallback for the two step sources: the
assistant's own line from before the call ("อ่าน `queue.sh` ก่อน แล้วค่อยแก้ cadence"). Text and
`tool_use` never share one assistant message — measured, 0 of 2 534 in a real session — so "the last
text block in the file" is exactly the line that introduced the step that just ran. Free and true, but
only ~1 call in 5 has one in front of it, and it says the mechanical ones too — which is the whole
difference between it and `insight`, since both read the same block.

| rule | value | why |
|---|---|---|
| content gates | `insight` only | length, then `NONE`, then the block hash. The rule that does the work now: the channel is quiet because there is nothing to conclude, not because a clock says so |
| dedupe by hash | — | never the same line twice in a row. With `prose` one block introduces several calls (314 blocks / 1 523 calls ≈ 1 per 5, measured); with `facts` it catches three Reads of one file |
| queue staleness | 12 s | a line about work that finished three steps ago describes the wrong moment |
| queue depth | 3 per session, oldest dropped | the load-shedding that matters, and it belongs on the playback side — only there is it knowable how far behind the voice is. Was **1** (supersede-to-newest), which is what made a burst of five steps speak once. Matters under `facts`; a conclusion rarely queues |
| producer rate floor | `narrate_gap`, **0 = off** | 9 → 4 → 0. Under `facts` any floor drops one half of every pair (the two arrive ~1 s apart); under `insight` there is nothing left to throttle |
| queue rate floor | the same key | counts utterances from other kinds and other worktrees, which the producer cannot see. Two floors, ONE number — when they disagreed (7 vs 9) the shorter was dead code |
| per-turn cap | `narrate_max_per_turn`, **0 = off** | a cliff, not a throttle: past line N the turn goes silent. Set a number to bound spend; logged when it bites (`-v`), never silent |
| char cap | 170 insight / 34 intent / 60 facts / 90 prose / 110 threshold | a conclusion needs room for a because-clause and the next move (the summarizer caps itself at 160); a step pair has to fit inside the step it describes |

### Thresholds and the gate voice

Two channels that speak **outside** the per-step cadence, both `milestone` kind (never dropped by the
queue):

| channel | trigger | line | switch |
|---|---|---|---|
| threshold: red | a step failed (`PostToolUseFailure`, or a runner that printed failures) | `cargo test ล้ม` + red cue. **Bypasses the rate floor and the cap** | `voice.autoplay.thresholds` |
| threshold: repeat | the same step failed again | `… ล้ม ซ้ำรอบ 2`, counted so the third is not called the second | ″ |
| threshold: long turn | turn older than `long_turn_seconds` (300) | `ผ่านมา 11 นาทีแล้ว ยังทำอยู่ ล่าสุด <fact>` — single-shot per turn, once more at 3× | ″ |
| gate | `PermissionRequest` · `PermissionDenied` · `PreToolUse(ExitPlanMode)` · `Notification` | `ขออนุญาตรัน cargo test ค่ะ` · `git push ถูก block ค่ะ` (red) · `แผนพร้อมแล้ว ขออนุมัติค่ะ` · `รอคำสั่งอยู่ค่ะ` | `voice.autoplay.gates` |

`gate.sh` is **independent of `chattiness`** (a gate is a *whether*), never reads a notification's
English text aloud (unclassifiable ⇒ silent), and dedupes on the gate **class** for 20 s — one waiting
prompt arrives as both `PermissionRequest` and `Notification`, wording it differently, so a text hash
would let the machine ask twice.

The long-turn threshold is deliberately **not** the deleted heartbeat: a heartbeat fires on elapsed
time whether or not anything happened, and repeats; this fires once per turn, only on a step that
really ran, and names that step.

Written prose is not speakable prose, so the trim strips fences, table rows, heading marks, list
markers and link URLs, and keeps **backtick contents** (an identifier is usually the most informative
word in the line). Only the first sentence survives — **unless it carries nothing**: measured on this
workspace's own transcript, a plain "first chunk" rule produced `both: 0` (7 chars) and
`Memory เก็บแล้ว ทีนี้ max` with its point amputated, because an em dash is used mid-sentence
constantly here. So chunks accumulate to ~25 characters before the cap trims the tail — a too-short
line is the worse failure, since a long one is merely cut while a thin one says nothing.

It stays quiet once the turn has **ended** (the closing line owns the end), on a `VOICE[...]` tag
block (same reason), and at every level except `max`.

Regression suite: `scripts/voice/narrate-selftest.sh` — **83 cases** over the narrator, all three
sources, the insight gates (including *no summarizer call was made*, which is a file test on the stub's
own log), the before/after pair, both throttles (off by default *and* still working when set), the
queue's own drop rules, the real `PreToolUse` hook, the thresholds and the gate voice, in a throwaway
tree with its own config and a stubbed `speak.sh`, so it costs nothing; it also runs
`tool-fact.py --selftest` (36 fixtures). Session ids are **run-scoped**
on purpose: narration state is machine-global and keyed by session, so fixed ids leaked the previous
run's dedupe state into the next one, which is how the suite first went red on its own second run.

### Ceiling, not quota — and it is enforced, not requested

The safety property of `chatty` and `max`. Three measured failures, each fixed by moving the rule out
of the prompt and into the code:

| measured | fix |
|---|---|
| "TWO or THREE short Thai sentences" + a ceiling paragraph ⇒ from the 23-char input *"แก้ typo ใน README แล้ว"*: 3 sentences, 2 invented, one containing a fabricated figure ("3 จุด") | the count is now phrased **inside the imperative** — "ONE sentence PER FACT you actually have, up to THREE" — because a model obeys an imperative over a caveat |
| the same input still drew *"รอการตรวจสอบจากคุณ"* in 4/4 runs | the report prompt's "say what is waiting" clause now requires the text to actually say something is waiting |
| a 3-sentence budget on a 1-fact input is unsatisfiable in principle | the cap is computed from the **material**: `min(level cap, max(60, input × 0.6))`, and the sentence count is derived from the cap (~1 per 65 chars), never from a band — a first attempt used level bands and flattened a real 4-fact reply to one sentence |

Result on a 467-char reply: terse 32 chars · balanced 57 · chatty 130, every fact real. On a 23-char
input, `chatty` produces one sentence of ~35 characters.

Re-measured at `max`, the level with the most room *and* explicit permission to narrate — the case
where padding pressure is highest:

| input | `max` output |
|---|---|
| *"แก้ typo ใน README แล้ว"* (23 chars) | one sentence, 33–38 chars, 3 runs of 3 — no invented step, no invented figure |
| a 620-char reply naming 4 file changes | 310–329 chars, 4 statuses, every figure traceable to the input |
| a 90-char request (`/dev-cycle …`) | ack 124–163 chars, naming the order — vs `chatty`'s 92 with no order |

The material clamp is what holds the first row: at 23 characters in, the cap collapses to the 60-char
floor and the sentence count derived from it is 1, so `max`'s four-sentence budget is never even
offered. The level cannot pad what it was not given.

### The particle budget is enforced too

Asked twice in the prompt, failed twice — `chatty` came back with `ค่ะ` on all three sentences, which
is over-polite to the point of sounding mechanical. Now trimmed in code after `_clean`: keep the
**last** occurrence (the sentence-final particle) and one inside the **opening reaction** (which
carries its own), drop everything between. Never runs at `terse`.

### Bad news keeps the plain register

`--plain`, passed by `ack.sh` for `prod`/`error` intent and by `milestone.sh` for the `red`/`incident`
group, strips the softener and the reaction at **any** level. Chattiness is set once and lives for
months; nobody turns it down before production breaks.

```bash
aiworks voice audition "…"          # all three levels, spoken, with character counts
```

## Spoken form — what is said vs what is written

`voice_spoken_form` (lib.sh) rewrites every line before synthesis, and before the cache key, so
the key addresses what the audio actually contains.

| written | said | why |
|---|---|---|
| `APP-1598` | `APP หนึ่ง ห้า เก้า แปด` | an identifier is not a quantity; every engine read it as *หนึ่งพันห้าร้อยเก้าสิบแปด* |
| `feature/APP-1598-add-cashback` | `feature APP หนึ่ง ห้า เก้า แปด add cashback` | a path read verbatim is "slash" and "dash" between every word |
| `MR` · `PR` | `merge request` · `pull request` | read verbatim, `MR` is the honorific *Mr.* |
| `142` · `12 เคส` · `21 ใบ` | `หนึ่งร้อยสี่สิบสอง` · `สิบสอง เคส` · `ยี่สิบเอ็ด ใบ` | a quantity is still spoken in a *language*, and the vendors disagree on which |
| `8%` · `60%` | `แปด เปอร์เซ็นต์` | read verbatim the sign comes out as English "percent" |
| `0.915` | `ศูนย์ จุด เก้า หนึ่ง ห้า` | Thai reads a fraction digit by digit after จุด |
| `https://…/merge_requests/12` | unchanged | the lookbehind refuses a path segment preceded by `/`, so URLs are left alone |
| `gpt-4o` · `eleven_v3` · `UTF-8` · `sonic-3` · `14:30` · `2026-07-29` | unchanged | a digit run glued to an ASCII letter, `.`, `:` or `-` is part of something else, not a count |
| `Mr. Somchai` · `PRD` | unchanged | case-sensitive `MR`/`PR` with ASCII lookarounds; the generic key pattern needs 3+ digits |

A key is recognised from the workspace's own `tracker.ticket_prefix` (either case, any digit count,
so a lowercase branch matches) plus a generic `UPPERCASE-\d{3,}` fallback for another project's key.
Digits become Thai **words** rather than spaced digits so no engine gets a second chance to be
clever about them. The lookarounds are ASCII-only, never `\b`: Thai runs words together, and
`มีMRรอreview` would fail a `\b` test and keep the honorific reading.

**Why quantities are converted at all**, having been deliberately left alone at first: they are
not vendor-neutral. Measured on the same Thai sentences —

| written | ElevenLabs Sarah | OpenAI sage | Cartesia Suda | Gemini Leda |
|---|---|---|---|---|
| `1 2 3 … 10` | *One, two, three…* | หนึ่ง สอง สาม | หนึ่ง สอง สาม | *One, two…* |
| `มี 2 must-fix` | *มี two must fix* | มีสอง | มีสอง | มีสอง |
| `450 ms` | *450 milliseconds* | สี่ร้อยห้าสิบ | สี่ร้อยห้าสิบ | สี่ร้อยห้าสิบ |
| `8%` | *eight percent* | แปดเปอร์เซ็นต์ | แปดเปอร์เซ็นต์ | แปดเปอร์เซ็นต์ |

ElevenLabs reads numerals in **English** in the middle of a Thai sentence. Converting the digits
to Thai words in the text removes the vendor's discretion, so what the assistant says no longer
changes when `voice.tts.provider` does. Ticket keys are spelled **first**, so their digits are
already words by the time the quantity pass runs and cannot be re-read as a magnitude.

The three Thai irregulars are handled and are not optional — 20 is `ยี่สิบ` (not สองสิบ), a lone
10 is `สิบ` (not หนึ่งสิบ), and a trailing 1 is `เอ็ด` **only when the tens digit above it is
non-zero**:

```
21 → ยี่สิบเอ็ด      11 → สิบเอ็ด      121 → หนึ่งร้อยยี่สิบเอ็ด      tens non-zero ⇒ เอ็ด
101 → หนึ่งร้อยหนึ่ง  1001 → หนึ่งพันหนึ่ง  1101 → หนึ่งพันหนึ่งร้อยหนึ่ง   tens 0 ⇒ หนึ่ง
```

`เอ็ด` belongs to the …สิบเอ็ด position specifically. The first version of this converter used
"trailing 1 in a number longer than one digit", which is close enough to pass 21 and 11 and wrong
on 101 — and a native ear catches it immediately, so the condition is the tens digit, not the
length. A run longer than
9 digits is spelled digit by digit instead: past a billion it is an id somebody wrote without a
prefix, not a quantity. **Dates and clock times are still left in digits** — `2026-07-29` and
`14:30` reach the engine untouched, so on ElevenLabs they are still read in English. Rare enough
in a spoken line to leave; the Thai reading of a date is a bigger job than this rewrite.

## Providers

Switchable because they are **not** interchangeable. Numbers are from the Thai voice sweep
below — best voice of each vendor, median of five transcription passes:

| `voice.tts.provider` | best voice | terms kept | latency | why you'd pick it |
|---|---|---|---|---|
| `openai` | `sage` | **42/43 (98 %)** | 2.3 s | best measured Thai; $45/1M chars |
| `cartesia` | `Suda` | 41/43 (95 %) | **1.8 s** | fastest, and the only NATIVE Thai voices; plan-based credits |
| `elevenlabs` (default) | `Sarah` | 37/43 (86 %) | 4.2 s | steadiest voice measured (±1); most natural to most ears; $100/1M chars |
| `gemini` | `Leda` | 36/43 (84 %) | 7.5 s | cheapest ($16.7/1M) but slowest and most variable |

Voice ids are keyed **by provider** (`voice.tts.voice.<provider>`) so switching provider
cannot carry an id from the wrong vendor.

## Thai voice selection

Every candidate voice of every vendor was measured, not just the famous ones: **24** ElevenLabs
(the whole account library), **13** OpenAI, **30** Gemini prebuilt, **7** Cartesia native Thai.
Each spoke the same five Thai+English dev sentences; score is how many of **43** English
technical tokens come back as **Latin script** through `gpt-4o-transcribe`.

**One transcription pass is not a measurement.** Re-scoring byte-identical cached audio gave
`sage` 0/6 on one pass and 6/6 on the next, and `Sarah` 4/6 then 1/6 — the noisy component is
the *transcriber*, not the voice. Every number here is the **median of five passes**, and the
spread is reported because a wide one is itself a finding.

| vendor | best | runner-up | worst of the field | note |
|---|---|---|---|---|
| OpenAI | `sage` 42 | `coral` 37 | `ash`, `ballad` (6/11 on the screen) | `nova`, the old default, scored 35 |
| Cartesia | `Suda` 41 (f) | `Thaksin` 41 (m), `Somchai` 41 (m) | `Narin` | three-way tie; pick by gender/timbre |
| ElevenLabs | `Sarah` 37 (±1) | `Chris` 37 (±11), `Jessica` 35 | `Roger`/`Brian`/`Daniel`/`Liam`/`Will` — 0/11 | the sweep **confirmed** the original default |
| Gemini | `Leda` 36 | `Zephyr` 34, `Kore` 34 | `Puck` 30 | 22 of 30 voices score identically — see below |

What the sweep actually taught, beyond the ranking:

- **Native Thai training shows up in one specific place.** On a line that packs English terms
  into dense Thai with no pauses (`query นี้ใช้เวลา 450 ms ที่ index scan เลย cache …`), the
  Cartesia natives kept 5–6 of 6 terms in Latin script; ElevenLabs `Sarah` kept 1, and Gemini
  and OpenAI `nova` kept 0. Everyone else transliterates — `อินเด็กซ์สแกน`, `เรดิส`, `เลเทนซี`.
  On the other four sentences the four vendors are within a token of each other.
- **A one-sentence audition is actively misleading.** `Laura` won the single-sentence screen
  outright (11/11) and finished last of the ElevenLabs finalists over five (31/43, spread ±21),
  having *translated* `develop` into Thai (`เข้าพัฒนาแล้ว`) on one of them.
- **For Gemini the voice barely matters.** 22 of 30 prebuilt voices scored identically on the
  screening line: Thai rendering is a property of the model, not the voice. Choosing a
  different Gemini voice will not fix Thai — and `gemini-2.5-pro-preview-tts` /
  `gemini-3.1-flash-tts-preview` measured no better on it either (both slower).
- **ElevenLabs has no Thai voices to find.** Only `eleven_v3` lists Thai at all, the shared
  voice library returns **zero** for `language=th`, and an IVC clone of a native Thai reference
  measured worse than stock. Five of the account's own voices cannot carry Thai.

Reproduce or re-rank by ear — no config edit needed:

```bash
scripts/voice/speak.sh --provider openai --voice sage --sync "review เสร็จแล้ว มี 2 must-fix"
scripts/voice/speak.sh --provider cartesia --voice ccc7bb22-dcd0-42e4-822e-0731b950972f --sync "…"
```

The score answers "will the dictation loop and the listener get the terms right". It says
nothing about which voice you want in your ears for eight hours — that part is yours.

Traps that are already handled, and that you must not "simplify" away:

- Only ElevenLabs `eleven_v3` lists Thai. `eleven_flash_v2_5`/`turbo_v2_5` do **not** — do
  not optimize onto flash for latency.
- Gemini returns **raw PCM**, not a container; `providers/gemini.sh` wraps it with ffmpeg at
  the sample rate the response itself declares.
- Cartesia needs the `Cartesia-Version` header and calls the text field `transcript`.
- **Batch work must be serial.** Cartesia's free tier allows ~1 concurrent request and the
  Gemini TTS preview models have a tight RPM cap — a 3-worker sweep lost 20 of 74 clips to
  `429`. Normal use is one utterance at a time, so this only bites when benchmarking.
- The ElevenLabs key here lacks the `user_read` scope, so `/v1/user/subscription` returns
  `missing_permissions` — remaining credits cannot be checked from a script.
- ffmpeg picks its **output** muxer from the file extension, so every temp file keeps `.mp3`.

## Credentials

```
scripts/voice/.env     git-ignored, mode 600 — the keys live here
```

Credentials live in `scripts/voice/.env` — git-ignored, mode 600, seeded from `.env.example`
by `aiworks voice setup`. This is the same per-adapter `.env` the tracker, vcs, notify and
observability adapters use. A linked worktree does not inherit it: copy the real file in
from the main clone, exactly as for the other adapters.

`GEMINI_VOICE_API_KEY` is deliberately **not** the image generator's `GEMINI_API_KEY`: one
key per feature keeps a voice quota problem out of the design pipeline.

⚠ Never read, print, `grep` (without `-q`) or `bash -x` a real `.env` — see `CLAUDE.md`.
A hook blocks it, and these scripts never echo a key, including on error.

## Requirements

`jq`, `curl`, `shasum`, `afplay` (system), `python3` (the lock), `ffmpeg` + `ffprobe`
(cue mixing and Gemini's PCM). `aiworks setup` installs ffmpeg; everything else ships with
macOS or is already a workspace dependency.

## Config reference

Read local-first: `workspace.config.local.yaml` → the **main clone's**
`workspace.config.local.yaml` when this checkout is a linked worktree →
`workspace.config.yaml`. That middle layer exists because a git-ignored file does not travel
into a worktree, and without it the feature would be dead in exactly the sessions that need
the identity prefix most. Block style only — the reader does not parse flow style (`{ a: 1 }`).

| key | default | meaning |
|---|---|---|
| `voice.enabled` | `false` | master switch (plus the `th` gate) |
| `voice.tts.provider` | `elevenlabs` | `elevenlabs` \| `gemini` \| `cartesia` \| `openai` |
| `voice.tts.voice.<provider>` | per provider | voice id for that vendor |
| `voice.tts.model` | per provider | override the model |
| `voice.tts.loudness` | `-16` | target LUFS every synthesized line is levelled to; `off` disables |
| `voice.tts.gender.<provider>` | from a table | `f` \| `m` — pins the Thai sentence-final particle (`ค่ะ`/`ครับ`) |
| `voice.stt.provider` | `openai` | `openai` \| `elevenlabs` \| `gemini` |
| `voice.stt.model` | per provider | override the model |
| `voice.summarizer.provider` | `openai` | `openai` \| `gemini` \| `claude` (the headless CLI, no key needed) |
| `voice.summarizer.model.<provider>` | per provider | model for that vendor |
| `voice.sfx.provider` | `elevenlabs` | `elevenlabs` \| `system` |
| `voice.autoplay.enabled` | `false` | master switch for local speech |
| `voice.autoplay.ack` | `true` | the per-prompt acknowledgement |
| `voice.autoplay.milestones` | `true` | the closing line on a finished turn |
| `voice.autoplay.narrate` | `true` | the `max` mid-turn narrator: a spoken CONCLUSION each time something is worked out. Inert at every other level |
| `voice.autoplay.narrate_intent` | `true` | the BEFORE half of that pair. `false` = results only, which leaves every wait unexplained |
| `voice.autoplay.narrate_source` | `say` | `say` (only a `SAY[group]:` line the assistant named itself — verbatim, zero tokens, silence when untagged) \| `insight` (the same, plus a summarizer GUESS at an untagged block — measured wrong in both directions, hence opt-in) \| `facts` (the step metronome: the command it is about to run, then the figure it returned; zero tokens, and too much to listen to) \| `prose` (the assistant's sentence before the call, verbatim). `facts` and `prose` fall back to each other; the first two never fall back to a step |
| `voice.autoplay.narrate_gap` | `0` | seconds between narrated lines (0–60), **0 = no floor**. A number drops one half of every pair. Used by BOTH the producer and the queue |
| `voice.autoplay.narrate_max_per_turn` | `0` | lines per turn (0–500), **0 = no ceiling**. A number bounds a turn's spend, at the cost of the turn going silent past it |
| `voice.autoplay.thresholds` | `true` | speak unbidden on a failed step (red, bypasses the floor), a repeat failure, and a long turn |
| `voice.autoplay.long_turn_seconds` | `300` | when a still-running turn is worth saying once (30–3600), and once more at 3× |
| `voice.autoplay.gates` | `true` | speak when something is BLOCKED on you: permission prompt, plan approval, auto-mode denial. Never plain idle — that is not a gate. Independent of `chattiness` |
| `voice.autoplay.milestone_every_turn` | `true` | false ⇒ only an explicit `VOICE:` tag speaks (was `milestone_backstop`, still read in its `false` position) |
| `voice.autoplay.chattiness` | `terse` | `terse` \| `balanced` \| `chatty` \| `max` — how MUCH the ack and closing line say, never whether they speak. `max` also turns on the mid-turn narrator + thresholds and is the only level that narrates mid-turn; its ack/closing line are SHORTER than `chatty`'s on purpose. **ROOT CHECKOUT ONLY** — a linked worktree is clamped to `terse` (it inherits this key from the root's local config, shares one spool, and is usually the session nobody is watching) |
| `voice.notify_voice.enabled` | `false` | a voice note on the Slack post — the ONLY switch for it; neither mute (by hand or by the OS) reaches it |
| `voice.push_to_talk.enabled` | `false` | hold-to-dictate |
| `voice.push_to_talk.hotkey` | `right_cmd+right_alt` | the chord; baked into the Lua by `ptt install` |
| `voice.push_to_talk.mic` | `default` | `default` follows System Settings → Sound → Input; or a device NAME substring. Never an index |
| `voice.push_to_talk.preview.provider` | `elevenlabs` | `none` \| `openai` \| `elevenlabs` \| `gemini`; `none` forces `auto_send: false` |
| `voice.push_to_talk.preview.window_seconds` | `12` | how much of the tail the HUD re-transcribes; keeps the lag flat on long speech |
| `voice.push_to_talk.auto_send` | `true` | press Enter after typing (ignored when preview is `none`) |
| `voice.push_to_talk.silence_db` | `-50` | mean-volume floor — calibrate with `mic-check` |
| `voice.push_to_talk.silence_peak_db` | `-35` | peak floor; both must be below to discard |
| `voice.cache.max_mb` | `500` | LRU cap on `cache/` |
