# Thai register (address mode)

`language.md` decides **which language** an agent writes in. This decides **how the Thai reads** once
it does. Inert unless the resolved `language` — or `case_report_language` — is `th`; under `en`
nothing here fires. The operative one-liner lives in the root `CLAUDE.md`; the decision behind it is
[ADR-0016](../adr/0016-thai-register-is-address-mode-not-exposition-mode.md).

Machine-translated-sounding Thai is not a vocabulary problem. It is one wrong mode, and every symptom
falls out of it together.

## 1. The one rule — a message to a person is written in address mode

Thai splits along a line English does not have. **Exposition mode** is what documentation, a blog post
and a spec are written in: the reader is nobody in particular. **Address mode** is what you write to a
person. They select different grammar, and picking the wrong one is what "stiff", "cold" and "sounds
translated" all mean.

| | Exposition mode | **Address mode** |
|---|---|---|
| first person | `เรา` (generic "one/we") | **`ผม` / `ดิฉัน`, or nothing** |
| second person | `คุณ`, `ท่าน`, or none | **nothing**, or a kinship term |
| verbs | `การ` + verb, `ทำการ` + verb | **bare verb** |
| connectives | `ดังนั้น`, `อย่างไรก็ตาม`, `เนื่องจาก`, `ทั้งนี้` | **`เลย`, `แต่`, `เพราะ`** |
| ending | a stated conclusion | **a question, or `ครับ`/`ค่ะ`** |
| particles | sparse | **one per clause** |

An LLM has read far more Thai exposition than Thai conversation, so it defaults to the left column and
aims it at a person. That single mismatch produces the `เรา`, the `คุณ`, the noun-stacking and the
accusatory tone simultaneously. **Fixing the mode fixes all of them; fixing them one at a time does
not fix the mode.**

## 2. Who is speaking — three voices, and they are not interchangeable

`ผม`/`ครับ` and `ดิฉัน`/`ค่ะ` are speaker-gender-marked, and Thai has **no** established
gender-neutral polite particle. Dropping particles entirely is grammatical and reads cold, which is
the problem we are solving. So the register is keyed on *who is speaking*, and the three answers
differ on purpose:

| Speaker | Register | Where |
|---|---|---|
| **The assistant, as itself** | the persona's own particle, pro-drop, no first-person pronoun | chat, `VOICE[]`/`SAY[]` lines, a case report it narrates |
| **The human whose name is on it** | `outbound_first_person` / `outbound_particle` (default `ผม` / `ครับ`) | anything a person pastes under their own name — a partner team, an operator, support |
| **The company** | `ทางเรา` / `ฝั่งเรา` — ungendered, no override needed | our-side position, inside either of the above |

An assistant writing `ผม` is claiming a person's voice it does not have; a draft the user pastes
written in the assistant's voice is worse, because the recipient knows who sent it. Override the
outbound pair per person in `workspace.config.local.yaml` (`outbound_first_person`,
`outbound_particle`) — a shared default cannot be right for everyone, and the failure mode is
misgendering a teammate to an outside party.

⚠️ **`เรา` is not the polite first person.** It is the *solidarity* register — the same family as
`กู`/`มึง`, carrying no deference at all. `เรา` for "I" is either over-familiar or reads as generic
exposition. The polite first person is `ผม`/`ดิฉัน`, and most of the time it is simply omitted.
`ทางเรา`/`ฝั่งเรา` — "our side" — is a different word and stays.

## 3. Second person: `คุณ` is banned by default

`คุณ` is not impolite. It is **marked** — it selects the formal, status-explicit, non-intimate frame.
Between people who already have a working relationship, choosing the marked form *announces* that you
are declining the closer form available. That announcement is the coldness.

In order of preference: **omit it** · `ทาง<Team>` / `ฝั่ง<Team>` for an organization rather than a
person · `พี่` (+ nickname) upward or when seniority is unknown · a bare nickname between peers.
`น้อง` only downward and never to another company — it asserts seniority across an org boundary.

Thai drops pronouns freely, and specifically does so when the counterpart's status is unclear — which
is an agent's permanent condition. Politeness survives the drop: it is carried by `ครับ`/`ค่ะ`, by
`ช่วย…ให้หน่อย`, by `รบกวน`, by `นะครับ`, and by asking rather than asserting.

**`คุณ` stays legal in exactly one case:** a genuinely formal notice — contract-adjacent, legal, or a
first-contact email to a stranger — where formal distance is the intent, not an accident.

## 4. The officialese table, read backwards

Thai civil-service style guides list the words to use *in* an official document. That list read
backwards is the natural register:

| Don't (officialese) | Do (address mode) | | Don't | Do |
|---|---|---|---|---|
| `ดำเนินการ` | `ทำ` | | `หาก` | `ถ้า` |
| `ตรวจสอบ` | `เช็ค` / `ดู` | | `ขณะนี้` | `ตอนนี้` |
| `แจ้ง` | `บอก` | | `เหตุใด` | `ทำไม` |
| `ได้หรือไม่` | `ได้ไหม` | | `อย่างไร` | `ยังไง` |
| `ประสงค์` | `อยาก` | | `มิได้` | `ไม่ได้` |
| `อนุเคราะห์` | `ช่วย` | | `ประสานงานไปยัง` | `คุยกับ` |
| `กรุณา` / `โปรด` | `ช่วย…หน่อย` | | `แล้วเสร็จ` | `เสร็จแล้ว` |

Three structural ones matter more than any single word:

- **`ทำการ` + a Thai verb is padding.** `ทำการตรวจสอบ` → `เช็ค`. (Before an *English* verb it is
  idiomatic — `ทำการ deploy` is real Thai — but `deploy เลย` is still better in a message.)
- **`การ-` / `ความ-` noun stacking** is the single loudest bloat marker.
  `การดำเนินการแก้ไขปัญหาการเชื่อมต่อ` → `แก้เรื่องต่อไม่ติด`.
- **The `ถูก` passive is adversative** — it grammatically encodes the subject as *suffering*
  something, and traditionally belongs to misfortune (`ถูกลงโทษ`). So `request ถูกปฏิเสธโดยระบบฝั่งคุณ`
  is translationese *and* an accusation in one construction. Describe the state instead:
  `ไม่มี response กลับมา`.

**English technical terms stay verbatim, inline, unquoted** — that is `language.md`'s spine rule and it
is also what real Thai engineers do. English verbs take Thai particles and never inflect
(`deploy แล้ว`, `off ไปเลย`, `ลอง retry ดู`). Do not translate them, and never reach for a coined Thai
equivalent. The exception runs the other way: a handful of terms are fossilized in Thai script
(`เว็บ`, `อัปเดต`, `คอม`) and writing the English mid-sentence looks stranger than the Thai.

## 5. Ordering — the one thing mode does not decide

Thai business requests build **shared context first and state the ask last**; going straight to the
point is measurably the non-Thai pattern. That is the opposite of this workspace's house style, and
both are right for their own reader:

- **Internal — you, an operator, a ticket, a case file: verdict first, unchanged.** `## Verdict` in
  line one is why a case report is usable at all, and someone triaging is not reading for pleasure.
- **Outbound to a partner team: context first, ask last.** Someone about to go digging through their
  own logs on your behalf needs to know why before being asked. Forty words of shared ground buys a
  straight answer in one round-trip instead of three.

This is a deliberate carve-out from the compression rule, not an oversight — see §8.

## 6. Reporting a problem to an outside team

Shape, in order. It is not specific to any one partner; it is how you avoid a week of round-trips
with any of them.

1. **Open on your own side's evidence, not theirs.** `เท่าที่เช็ค log ฝั่งผม…` — never
   `ฝั่งคุณ…` as the first words. Naming where the fault lives before showing the data is the
   accusation, regardless of how politely it is worded.
2. **Attach the raw payload verbatim** in a fenced block — the request/response body, pretty-printed,
   no key added, removed or reordered, and say so. A partner greps their logs with it.
3. **Downgrade the conclusion to an observation.** `ดูเหมือน` / `น่าจะ` / `เท่าที่เห็น`, and leave
   room for the answer being "intentional by design".
4. **One question per numbered line**, each answerable independently.
5. **Name the imposition** before making it — `รบกวน`, `ถ้าพอมีเวลา`, `พอจะ…ได้ไหมครับ`.
6. **Close on the shared goal** — `จะได้ช่วยกันไล่ตามได้ง่ายขึ้น`. `ช่วยกัน` is literally the grammar
   of solving it together, and it is the cheapest sentence in the message.
7. **Stamp times in both zones** and list the identifiers to grep on their side.

No `เรียน คุณ…` / `จึงเรียนมาเพื่อทราบ` / `ด้วยความเคารพอย่างสูง` in a chat message. That furniture is
correct in a Thai business *email* and is the loudest possible stiffness signal anywhere else.

### Accusation anti-patterns

| Instead of | Write |
|---|---|
| opening with `ฝั่งคุณ` / `ทางคุณ` | own-side evidence first, or `ไม่แน่ใจว่าฝั่งไหน` |
| `ทำไมไม่ retry` | `ไม่ทราบว่ามีการ retry ไหมครับ` |
| `…ใช่ไหม` confirming an assumed fault | ask the mechanism: `จัดการ retry ยังไงบ้างครับ` |
| `ฝั่งคุณไม่มี retry` (flat verdict) | `เหมือนจะยังไม่เห็น retry เข้ามาเลยครับ` |
| `ถูกทิ้งที่ฝั่งคุณ` | `ไม่มี response กลับมา` |

## 7. Warmth is in the framing, never in the finding

**The register governs how you ask and how you frame. It never softens a number, a verdict, or a
warning.** `ห้ามจ่าย ฿780 — settle มาแล้ว` does not become `อาจจะยังไม่ได้จ่ายนะครับ`; hedging that
sentence pays a customer twice. Bad news keeps the plain register at every level — the same ruling
that keeps quips out of an incident line.

So: `เกรงใจ` lives in the sentence *around* the evidence. Maximum warmth toward the person, zero
softening of the fact.

## 8. Where it stops

- **Code, identifiers, commit messages, branch names, and any `.md` file** — English, always.
  `language.md` §2, unchanged.
- **Compression still applies to the reply.** Address mode adds particles and a closing line to an
  *outbound message*; it does not license preamble in a chat reply. The §5 ordering carve-out is
  scoped to outbound messages and nothing else.
- **The product's own UI copy** follows the product's design and localization, never this file.
- **Under `en` this file is inert** — no directive fires, no behavior changes.

## 9. How it reaches each spawn path

| Path | Mechanism |
|---|---|
| main session | `.claude/hooks/resolve-language.sh` appends the register clause to the `th` policy it already injects on `SessionStart` + every `UserPromptSubmit` |
| direct `Agent` spawn | the same clause rides the `LANGUAGE_DIRECTIVE` that `pretool-agent-context.sh` rewrites into the brief |
| headless workflow | the resolver sub-agent's `LANGUAGE_DIRECTIVE`, unchanged plumbing |
| Cursor | falls back to this doc + the root `CLAUDE.md` line — `updatedInput` is ignored on `Task` there |

There is no separate register hook on purpose. The rule only exists when the language is Thai, and one
resolver already knows exactly that; a second mechanism would be a second thing to keep in sync.
