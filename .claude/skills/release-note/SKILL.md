---
name: release-note
description: >-
  Write a Thai, non-technical release note for one Jira release and post it as that release's
  description — one entry per ticket, how-to bullets for anything a user sees, one line for
  anything purely technical. Use whenever someone asks for a release note, release notes,
  "what's in v1.0.0", a release announcement for users, or to write/update/refresh the Jira
  release (fix version) description — given a release URL, a version name like v1.0.0, or a
  version id, even if they do not say "Jira". Not for a PR/MR changelog or a sprint summary.
argument-hint: "<release url | version name | id> [--dry-run]"
arguments: [release, flags]
model: haiku
allowed-tools:
  - Bash(scripts/tracker/*)
---

# Release note

Turn one Jira release into a short Thai note its users can read, and store it as the release's
description. Run the tracker scripts **from the workspace root**.

## What this note is

A release note is read by people who use the product, not by the team that built it. It
answers two questions in under a minute: *what changed for me*, and *how do I use it*. It is
**always Thai**, whatever the workspace `language:` says — the workspace switch governs how the
team talks to itself; this text belongs to the product's users. The English spine still holds
(`docs/agents/language.md`): product and feature names, screen names, proper nouns and
Arabic numerals stay as they are.

The voice is **the company speaking to its users** (`docs/agents/register.md` §2): `ทางเรา`
for "we", no first-person pronoun otherwise, and no `ครับ`/`ค่ะ` — the company has no gender.
Address mode, not exposition (ADR-0016): bare verbs, no `การ`/`ทำการ` noun stacking, no
`คุณ` (say nothing, or name the role: `ผู้ใช้`, `แอดมิน`), connectives `เลย`/`แต่`/`เพราะ`, a
soft `นะ`/`ได้เลย` where a line would otherwise read cold. Warmth sits in the framing; a fact
stays plain.

## Steps

1. **List the release.**
   `scripts/tracker/find-tickets.sh --fix-version <release> --json --limit 0` — the release
   URL, the version NAME (`v1.0.0`) or the numeric id all work. Every ticket in the fix version is in
   the note, whatever its status: the version IS the release, and the note is overwritten on
   the next run if a ticket moves. Zero tickets ⇒ stop and say so; do not post an empty note.
2. **Read each ticket.** `scripts/tracker/get-ticket-details.sh <KEY>` — summary and
   description (acceptance criteria included). Skip comments: they are dev and QA traffic,
   exactly the tone to keep out.
3. **Classify each ticket with one question:** *does anything a user sees or does change?*
   - **Yes ⇒ user-facing.** A bullet naming the change in the user's words, then a how-to of
     **at most 5 lines** (where to find it, what to press, what they get). Fewer is better.
   - **No ⇒ technical.** One line, plain words, no mechanism — `ระบบโหลดหน้ารายการเร็วขึ้น`,
     not what index was added. Issue type and labels are hints, never the rule: a `Story`
     can be pure backend and a `Task` can ship a button.
4. **Write the note** in the skeleton below. Every ticket appears exactly once; no ticket
   keys anywhere — the reader does not know what `FM-123` is, and Jira already links them.
5. **Post it.** Write the text to a temp file (`$TMPDIR`, never `agent_logs/` — Thai in a
   `.md` is banned by `language.md`), then
   `scripts/tracker/upsert-release-details.sh <release> --description-file <tmp>`. The script
   accepts the release URL, the name or the id, and replaces the description whole. With
   `--dry-run` it prints the request and nothing changes. Jira caps the field at 16,384
   bytes and the script refuses an oversized note: tighten the how-tos, never drop a ticket.
6. **Reply** with the note as posted and the release URL the script prints. No chat
   notification — anyone who wants it in Slack pastes the link.

## Skeleton

Plain text: Jira renders no headings or Markdown in a version description. Structure is line
breaks and `•`. The opening is the *conclusion* of the release — what it is about, one or two
lines — not a list restated.

```
<1–2 lines: what this release does for the user, overall>

<• one bullet per user-facing ticket>
  <how-to, ≤5 lines, indented>

ด้านเทคนิค
<• one line per technical ticket>
```

## Example

Three tickets: FM-41 "Export order list to Excel" (Story), FM-44 "Admin can reset a user's
PIN from the user page" (Task), FM-46 "Move session cache to Redis cluster" (Story).

```
รอบนี้เน้นให้แอดมินทำงานกับรายการออเดอร์และดูแลผู้ใช้ได้เร็วขึ้น โดยไม่ต้องติดต่อทีมเทคนิค

• ดาวน์โหลดรายการออเดอร์เป็นไฟล์ Excel ได้แล้ว
  ไปที่หน้า Orders กดปุ่ม Export มุมขวาบน
  เลือกช่วงวันที่ที่ต้องการ แล้วกด Download
  ไฟล์จะเปิดใน Excel ได้ทันที

• แอดมินรีเซ็ต PIN ให้ผู้ใช้ได้จากหน้าผู้ใช้โดยตรง
  เปิดหน้า Users เลือกผู้ใช้ที่ต้องการ
  กด Reset PIN แล้วยืนยัน ผู้ใช้จะได้ PIN ใหม่ทาง SMS

ด้านเทคนิค
• ปรับระบบหลังบ้านให้รองรับผู้ใช้พร้อมกันได้มากขึ้น
```

Why it reads right: the opening says what the release is *for*; each how-to is a path a
person can follow with the screen in front of them; the Redis move is one line of outcome,
no mechanism; `ทางเรา` is absent because nothing here needed a "we"; no key, no particle.
