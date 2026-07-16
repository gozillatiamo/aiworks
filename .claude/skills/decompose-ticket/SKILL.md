---
name: decompose-ticket
description: Split an oversized ticket (total Dev+QA points over 24) into smaller tickets that can each be built and shipped in parallel (no hard cross-piece dependency), then re-estimate every piece — parallel independence is first-class; only a truly huge ticket (over 36) may instead split along hard 'is blocked by' dependencies, and a ticket with no valid parallel cut is left whole. Two branches by caller: the CTO ADVISES (proposes the seams + independent slices as solution-finding, writes no tickets) and the Product Owner EXECUTES (creates the pieces through the tracker adapter, re-estimates each, wires the split structure). Runs right after /estimate-ticket whenever the total exceeds 24, including inside the /prd workflow. Use when a ticket is too big to size, when asked to break down / split / decompose a <KEY>, or when another role needs an oversized ticket carved into independent, re-estimated pieces.
argument-hint: "<KEY> (e.g. APP-1952) [advise|execute]"
model: opus
effort: high
allowed-tools:
  - Bash(scripts/tracker/*)
  # Codegraph (per-repo index): skim the touched area to find real seams —
  # codegraph explore/search before Grep/Glob/Read (which stay the last resort).
  - Bash(codegraph *)
  - Read
  - Grep
  - Glob
  - Skill
  - AskUserQuestion
---

# Decomposing an oversized ticket

A ticket whose **total (Dev + QA) points exceed 24** is too big to flow cleanly through the
pipeline — it hides risk, blocks parallelism, and estimates poorly. Split it into smaller pieces
that can each be built, reviewed, and shipped **in parallel** — no piece waiting on a sibling —
and **re-estimate each**. Parallel independence is **first-class**: over 24 you split only into
pieces with no hard dependency on one another. Only once a ticket is genuinely huge — **over 36** —
is a dependency-ordered split (wired with `is blocked by` links) allowed. When no valid cut exists
at all, leave the ticket whole — a forced split is worse than an honest big ticket.

All tracker reads/writes go through the **tracker adapter** (provider-agnostic —
`notion`|`jira`); **never** call a tracker MCP/API directly (keeps it headless-safe):

```
$CLAUDE_PROJECT_DIR/scripts/tracker/
  get-ticket-details.sh   <KEY>            # spec + the "Estimate: Dev … · QA …" line
  get-ticket-comments.sh  <KEY> [--deep]   # prior estimation/decomposition notes
  find-tickets.sh         [--query …] [--open] [--json]   # dedup: has it already been split?
  upsert-ticket-details.sh new --title … --issuetype … [--parent <EPIC>] \
      [--link "Split from":<ORIG>] [--priority <ORIG-PRIORITY>] --status … --body-file <spec.md>   # CREATE a piece
  upsert-ticket-details.sh <ORIG> --title … --status … --body-file …  # reconcile the original
  add-ticket-comment.sh   <KEY> "text"
```

Provider + auth + project/db come from `scripts/tracker/.env` — never passed. See
`docs/agents/issue-tracker.md`. **Most child-issue flags (`--issuetype` / `--link` / `--subtask`
/ `--component`) apply only when creating (ref `new`); the adapter ignores them on an update
and warns.** `--parent` is the exception — it also re-parents an *existing* issue, so the
epic path below can move the original ticket itself under the freshly created epic instead of
superseding it; the adapter still can't retype an existing issue, which is why the epic is
always a *fresh* issue rather than the original retyped in place.

**The original ticket becomes one of the pieces — never a leftover.** A *replace*-shape split
(`N < 4`) reuses the original's own key as piece 1: retitle it, rewrite its body to that piece's
spec, and re-estimate it in place. There is no orphaned/superseded ticket to close, and that
piece keeps its pasted images/comments/history/links for free (an update carries them over
automatically — see the media-carryover note in `tracker_upsert`). Only pieces 2..N are created
fresh. An *epic*-shape split (`N >= 4`) reuses the original too — it becomes a child of the new
epic via `--parent <EPIC-KEY>` on an update — so every piece keeps its own history; only the
epic itself is a new issue.

## When this fires — the two gates

Trigger on **total (Dev + QA) points > 24** — the ticket's derived headline size (25+).
The natural moment is **right after `/estimate-ticket` sets the points**: read the total off
`get-ticket-details.sh`'s `Estimate:` line. A ticket that isn't estimated yet has no total to
test — estimate it first, then apply this rule. 24 or below → this skill does nothing.

The total also decides **how far the independence bar bends** — a second gate at **36** governs
whether a hard-dependency split is allowed at all. See *The independence bar* below.

## The independence bar — parallel slices, not horizontal layers

The whole point is pieces built, reviewed, merged, and shipped **in parallel** — a developer
picks up any piece without waiting on a sibling. Cut along **seams** that yield **vertical
slices** — each a self-contained increment that reaches Done and stands on its own — never
**horizontal layers** (the migration alone, the API alone, the screen alone) that are dead
weight until their siblings land.

A valid decomposition satisfies **every** bar below:

- **Parallel-independent** — pieces carry **no hard dependency on each other**: any piece can be
  built and reach Done without a *sibling* merging first, and there is no cyclic dependency. A
  suggested build *order* is fine ("B reads best after A"), but "better after" is **not** "blocked
  by" — if a piece is genuinely inert until another merges, that pair is **not** parallel, and
  whether such a split is allowed at all is decided by the two gates below.
- **Self-contained spec** — each piece carries its own goal, its slice of the acceptance
  criteria, and its own scope boundary; a planner can pick it up without reading the others.
- **Meaningfully smaller** — each piece is expected to re-estimate **at or below 24**. Expect
  the pieces' points to **sum higher than the original** (coordination overhead is real) — that
  is normal, do not force them to add back to the original total.
- **Complete cover** — the pieces together deliver everything the original promised; nothing
  in-scope is dropped and no gap opens between them.

### The two gates — when a hard dependency is allowed

Parallelism is first-class; the original's **total** decides how far the bar bends:

- **Gate 1 — total > 24 (up to 36): parallel or nothing.** Split **only** into parallel-independent
  pieces. If the only decomposition you can find is a hard-dependency chain (each piece blocked by
  the prior), that is **not** a valid split — leave the ticket whole, over 24, and say why. A big
  honest ticket beats a fake-parallel one. No `is blocked by` links are created in this band.
- **Gate 2 — total > 36: dependency allowed.** The ticket is too big to leave whole, so a
  dependency-ordered split is permitted. Still prefer parallel pieces; where a piece genuinely
  cannot start until an earlier one merges, wire the order as a real **is blocked by** link on it
  pointing at the earlier piece — Jira's Linked work items, not just a "Requires: `<KEY>`" prose
  note — so the board shows the ordering the spec describes.

**Irreducible tickets exist.** If no valid cut exists — one tightly-coupled change, an atomic
migration, a single indivisible algorithm; or, under Gate 1, only a dependency chain is possible —
do **not** manufacture a split. Leave the ticket whole and say why (Advise: in the proposal;
Execute: in the output). A big-but-honest ticket beats fake independence.

## Two branches — detect from the caller

- **Advise** (the **CTO**, solution-finding / consulting) — assess splittability and **propose**
  the decomposition; write **no** tickets. This is the CTO's consulting voice: find the seams,
  name the independent slices, rough-size each, and give the build order + cross-repo touches.
  The proposal is handed to the Product Owner. Default here when the caller is the CTO, when the
  invocation says `advise`, or inside `/prd`'s Consult stage.
- **Execute** (the **Product Owner**, writing tickets) — take the CTO's proposal (or, standalone,
  derive the slices yourself against the bar above), then **create** the pieces through the
  adapter, **re-estimate each**, wire the split structure, and reconcile the original. Default
  when the caller is the Product Owner, when the invocation says `execute`, or inside `/prd`'s
  Ticketing stage.

---

## Advise flow (CTO)

1. **Read** the ticket (`get-ticket-details.sh <KEY>` + comments) and confirm the total > 24.
2. **Skim the touched area** for real seams — **codegraph first** (`codegraph explore`/`search`
   in the repo the ticket targets), Grep/Glob/Read only as a last resort. Skim to find seams,
   not to design.
3. **Propose the slices** against the independence bar: for each proposed piece give a title, a
   one-line goal, which acceptance criteria it owns, a rough Dev/QA size, its cross-repo touches,
   and where it sits in the build order. Aim for **parallel-independent** pieces; only when the
   total is **> 36** may you propose a dependency-ordered chain (name each hard `is blocked by`).
   Confirm each piece clears every bar; flag any that doesn't.
4. If the ticket is **irreducible** — or the total is ≤ 36 and the only decomposition is a
   dependency chain — say so plainly and stop: recommend it ship whole (or that a human
   re-scopes it), and do not propose an artificial or chain-only split.

**Completion criterion (Advise):** a proposal the Product Owner can execute without re-deciding
the seams — each piece independently deliverable, self-contained, rough-sized, and ordered — OR
a clear irreducible verdict with the reason. No tickets are created in this branch.

## Execute flow (PO)

1. **Read + confirm.** `get-ticket-details.sh <KEY>` — confirm total > 24. If a CTO proposal was
   handed in, use its slices; otherwise derive them yourself against the independence bar. Note
   the `Sprint:` line if present (`Sprint: <name> (id <id>)`) and the `Priority:` line — every
   fresh piece created below must land in that same sprint and carry that same priority.
2. **Dedup.** `find-tickets.sh --query "<distinctive token from the title>" --open` — if the
   ticket already has split-children or "Split from" siblings, it was decomposed already; stop
   and report the existing pieces rather than splitting twice.
3. **Settle the slices.** Lock the **parallel-independent** slices (each ideally ≤ 24), applying
   the two gates: at total ≤ 36 the slices must be parallel — if the only decomposition is a
   dependency chain, **stop**, leave the ticket whole, and report it irreducible with the reason.
   Only at total > 36 may the slices form a dependency-ordered chain. Never force a split.
4. **Pick the split shape by piece count** (see the next section) — `N < 4` → *replace*; `N >= 4`
   → *epic*.
5. **Create each piece** through the adapter with a self-contained spec in its body (goal, its
   slice of the acceptance criteria, scope boundary, build-order note, and a pointer back to the
   original / epic). Write the spec to a temp `.md` and pass `--body-file`. Give it the org's
   not-started status (see `issue-tracker.md`) and the same work issue-type as the original
   (Story/feature), not a sub-task. **Both shapes reuse the original as one of the pieces** —
   update it in place (retitle + rewrite body, plus `--parent <EPIC-KEY>` for epic shape) rather
   than creating a new key for it; only the other pieces are genuinely new (epic shape: also the
   epic itself). Before re-parenting the original under a freshly created epic, check its
   `Parent:` line (`get-ticket-details.sh`) — Jira/Notion parent is single-valued, so this
   silently evicts it from any pre-existing parent; note that trade-off in the output rather than
   doing it quietly. **Every genuinely new piece gets `--sprint <ORIG-SPRINT-ID>`** (the id read
   off step 1's `Sprint:` line) — a split is a scope change, not a scheduling one, so each piece
   stays in the sprint the original was already committed to. Skip the flag only when the
   original had no sprint set. **Likewise every genuinely new piece (and the epic) gets
   `--priority <ORIG-PRIORITY>`** (the value on step 1's `Priority:` line) — a split changes
   scope, not urgency, so each piece inherits the original's priority; the reused original keeps
   its priority automatically. **Only in a dependency-ordered split (Gate 2, original total > 36):
   whenever a piece's build order says it Requires an earlier piece, add
   `--link "is blocked by":<EARLIER-KEY>` to that piece's own create/update call** (works on the
   reused original too — `--link` applies on update, not just create) — this is what actually puts
   the "is blocked by" relationship in Jira's Linked work items, not just prose in the body. A
   Gate-1 split (total ≤ 36) is parallel by construction, so it wires no such links.
6. **Re-estimate each piece — do not hand-write numbers.** Run `/estimate-ticket <NEW-KEY>` per
   piece so calibrated Dev/QA points land in the point **fields**. If a piece still comes back
   > 24, it wasn't sliced enough or it's an irreducible large piece — note it in the output (and,
   if it's cleanly divisible, split that one piece further).
7. **Reconcile the original** (see the split-shape section).
8. **Report** per *Output*.

**Completion criterion (Execute):** every piece exists on the board with a self-contained spec,
is linked/parented per the split shape, and is **estimated (point fields set)**; the original is
reconciled; and the pieces completely cover the original's scope. A piece whose points live only
in a comment is not done.

## Split shape — the tracker structure (by piece count)

Cut count `N` decides how the pieces relate to the original.

### N < 4 → replace the original

The pieces are **independent siblings**. The original's own key becomes **piece 1** — pick
whichever piece it fits best (first in build order is the usual default, or whichever piece
most overlaps the original's existing component/repo/type); the rest are created fresh.

```sh
# 1) reuse the original as piece 1 — an ordinary update, no create-only flags needed
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <ORIG> \
  --title "<piece 1 title>" --status "<not-started status>" \
  --body-file <piece1-spec.md>
#    pasted images/attachments already on <ORIG> carry over onto it automatically

# 2) create pieces 2..N fresh — same work type as the original, linked back to it,
#    same sprint + priority as the original (read them off get-ticket-details.sh's Sprint:/Priority: lines).
#    Add --link "is blocked by":<EARLIER-KEY> ONLY for a Gate-2 (>36) dependency split; a Gate-1
#    (≤36) split is parallel by construction, so drop that flag entirely.
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --title "<piece title>" --issuetype "<original's type, e.g. Story>" \
  --status "<not-started status>" \
  --link "Split from":<ORIG> --link "is blocked by":<EARLIER-KEY> \
  --priority <ORIG-PRIORITY> --sprint <ORIG-SPRINT-ID> \
  --body-file <piece-spec.md>
```

Then re-estimate **every** piece including the reused original (step 6) — its old combined
estimate no longer applies once its scope has shrunk to just piece 1. Nothing needs superseding
or closing: the original ticket simply *is* piece 1 now, under its own key, in whatever status
that piece is naturally in.

### N >= 4 → new short-named epic, pieces as children

Too many for a flat replace — group them under an epic. The original becomes **one of the
children** (re-parented via update), same as replace shape reuses it as piece 1 — no
superseding, no closing.

```sh
# 1) create the epic — a SHORT umbrella name distilled from the original title
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --title "<short epic name>" --issuetype Epic --priority <ORIG-PRIORITY> \
  --link "Split from":<ORIG> --body-file <epic-summary.md>
#    → read the epic <EPIC-KEY> from the "Created <KEY> — …" line

# 2) reuse the original as one of the pieces — re-parent it under the new epic (ordinary
#    update; --parent works on an existing issue, see the note above this section)
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <ORIG> \
  --title "<piece title>" --parent <EPIC-KEY> --status "<not-started status>" \
  --body-file <piece-spec.md>
#    pasted images/attachments already on <ORIG> carry over onto it automatically

# 3) create every other piece fresh, as a CHILD of the epic, same sprint + priority as the original.
#    Add --link "is blocked by":<EARLIER-KEY> ONLY for a Gate-2 (>36) dependency split; a Gate-1
#    (≤36) split is parallel, so drop that flag.
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --title "<piece title>" --issuetype "<original's type>" \
  --parent <EPIC-KEY> --status "<not-started status>" \
  --priority <ORIG-PRIORITY> --sprint <ORIG-SPRINT-ID> \
  --link "is blocked by":<EARLIER-KEY> \
  --body-file <piece-spec.md>
```

Then re-estimate every piece including the reused original (step 6) — its old combined estimate
no longer applies once its scope has shrunk to just one piece. If the original had its own
pre-existing parent (check `Parent:` on `get-ticket-details.sh <ORIG>` in step 1), re-parenting
it under the new epic replaces that membership — call this out in the output rather than doing
it silently; it's a real trade-off, not a bug. Carry over the original's attachments the same
way as any other piece that needs them: download anything `get-ticket-details.sh <ORIG>` flags
(`⚠ N embedded …`) and `add-ticket-attachment.sh` it onto whichever child(ren) need it.

If the provider rejects the `Epic` issue type (unknown name), the adapter **fails loud** and
prints the valid types — surface that and pick the org's real epic-level type; never invent one.
For the `Split from` link, the adapter silently substitutes the **closest existing** link type
(e.g. `Relates`) and says so — carry that note into the output; never drop the link.

## Guardrails

- **Points live in fields; estimation is `/estimate-ticket`'s job.** This skill never hand-writes
  Dev/QA points and never touches the derived total — it delegates every re-estimate to
  `/estimate-ticket` so the board stays calibrated.
- **Parallel-first, gated by size.** At total ≤ 36, split only into parallel-independent slices; a
  chain-only decomposition ⇒ keep whole. Only above 36 may pieces carry hard dependencies.
  Irreducible ⇒ keep whole. Prefer one honest big ticket over several fake-parallel ones.
- **Complete cover, nothing dropped.** Every acceptance criterion of the original lands in exactly
  one piece. Attachments are scoped to the issue they live on — the piece that reuses the
  original's key keeps them for free (either shape), but every *other* piece that needs them
  (mockups almost always belong on the UI-bearing piece, and on any piece whose AC cites literal
  numbers read off them) needs its own copy: download the image and
  `scripts/tracker/add-ticket-attachment.sh <NEW-KEY> <file>` it there (Jira only for now).
- **Same sprint as the original.** A split changes scope, not schedule — every genuinely new
  piece gets `--sprint <ORIG-SPRINT-ID>` so it lands in the sprint the original was already
  committed to (the reused-original piece already has the right sprint; nothing to do there).
- **Same priority as the original.** A split changes scope, not urgency — every genuinely new
  piece (and the epic) gets `--priority <ORIG-PRIORITY>` so it inherits the original's priority
  (the reused-original piece already has it; nothing to do there). Re-estimation in step 6 may
  change a piece's points, but never its priority.
- **Idempotent.** Never split a ticket that already has split-children/siblings (step 2 dedup).
- **Hard dependencies become real links, not just prose — Gate 2 only.** A hard dependency is
  allowed only in a > 36 split; there, every "Requires: `<KEY>`" build-order note on a piece gets
  a matching `--link "is blocked by":<KEY>` on that piece's own create/update call — same
  closest-match/fail-loud behavior as `Split from`: if the exact phrase is missing, the adapter
  substitutes the closest link type and says so; carry that note into the output. A ≤ 36 split is
  parallel, so it produces no such links.
- **Adapter only, fail loud.** If the tracker is unreachable, report the split was **not** applied
  (don't fabricate keys) — same rule as `docs/agents/issue-tracker.md`.

## Output

Return a compact summary the caller (CTO consult / PO ticketing / `/prd`) can carry forward:

```
original:    <KEY>  (total <T> > 24)
verdict:     split | irreducible
shape:       replace | epic | n/a         # n/a when irreducible
epic:        <EPIC-KEY> | none            # the new epic, when shape=epic
pieces:                                   # empty when irreducible
  - <KEY-a>  dev <d>/qa <q> (total <t>)  — <one-line goal>   # KEY-a == <ORIG>, reused as a piece (either shape)
  - <KEY-b>  dev <d>/qa <q> (total <t>)  — <one-line goal>  [blocked by <KEY-a>]   # Gate-2 (>36) splits only, where a hard build-order dependency exists
  - <KEY-c>  …
original_state: reused as piece 1 (<ORIG>) | reused as epic child (<ORIG>, evicted from prior parent <OLD-PARENT> if any) | unchanged (irreducible)
note:        <irreducible reason / a piece still >24 / epic-type or link fallback / tracker issue>
```
