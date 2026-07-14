---
name: decompose-ticket
description: Split an oversized ticket (total Dev+QA points over 12) into smaller tickets that can each be built and shipped independently, then re-estimate every piece — but only when a genuinely independent decomposition exists; an irreducible ticket is left whole. Two branches by caller: the CTO ADVISES (proposes the seams + independent slices as solution-finding, writes no tickets) and the Product Owner EXECUTES (creates the pieces through the tracker adapter, re-estimates each, wires the split structure). Runs right after /estimate-ticket whenever the total exceeds 12, including inside the /prd workflow. Use when a ticket is too big to size, when asked to break down / split / decompose a <KEY>, or when another role needs an oversized ticket carved into independent, re-estimated pieces.
argument-hint: "<KEY> (e.g. OFB-1952) [advise|execute]"
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

A ticket whose **total (Dev + QA) points exceed 12** is too big to flow cleanly through the
pipeline — it hides risk, blocks parallelism, and estimates poorly. When such a ticket can
be carved into **independent slices**, split it into several smaller tickets and **re-estimate
each**. When it genuinely cannot be, leave it whole — a forced split is worse than an honest
big ticket.

All tracker reads/writes go through the **tracker adapter** (provider-agnostic —
`notion`|`jira`); **never** call a tracker MCP/API directly (keeps it headless-safe):

```
$CLAUDE_PROJECT_DIR/scripts/tracker/
  get-ticket-details.sh   <KEY>            # spec + the "Estimate: Dev … · QA …" line
  get-ticket-comments.sh  <KEY> [--deep]   # prior estimation/decomposition notes
  find-tickets.sh         [--query …] [--open] [--json]   # dedup: has it already been split?
  upsert-ticket-details.sh new --title … --issuetype … [--parent <EPIC>] \
      [--link "Split from":<ORIG>] --status … --body-file <spec.md>   # CREATE a piece
  upsert-ticket-details.sh <ORIG> --title … --status … --body-file …  # reconcile the original
  add-ticket-comment.sh   <KEY> "text"
```

Provider + auth + project/db come from `scripts/tracker/.env` — never passed. See
`docs/agents/issue-tracker.md`. **Child-issue flags (`--issuetype` / `--parent` / `--link`)
apply only when creating (ref `new`); the adapter ignores them on an update.** That is why
the epic path below builds a *fresh* short-named epic rather than retyping the original —
the adapter cannot change an existing issue's type or re-parent an existing issue under a
freshly created one.

**The original ticket becomes one of the pieces — never a leftover.** A *replace*-shape split
(`N ≤ 5`) reuses the original's own key as piece 1: retitle it, rewrite its body to that piece's
spec, and re-estimate it in place. There is no orphaned/superseded ticket to close, and that
piece keeps its pasted images/comments/history/links for free (an update carries them over
automatically — see the media-carryover note in `tracker_upsert`). Only pieces 2..N are created
fresh. An *epic*-shape split (`N > 5`) can't do this for the original itself (the adapter can't
re-parent an existing issue under a newly created epic — see above), so that shape still
supersedes the original into the new epic; every *other* piece is still fresh.

## When this fires — the 12-point rule

Trigger on **total (Dev + QA) points > 12** — the ticket's derived headline size (13+).
The natural moment is **right after `/estimate-ticket` sets the points**: read the total off
`get-ticket-details.sh`'s `Estimate:` line. A ticket that isn't estimated yet has no total to
test — estimate it first, then apply this rule. 12 or below → this skill does nothing.

## The independence bar — vertical slices, not horizontal layers

The whole point is pieces that can be built, reviewed, merged, and shipped **independently of
each other**. Cut along **seams** that yield **vertical slices** — each slice a self-contained
increment that reaches Done and stands on its own — never **horizontal layers** (the migration
alone, the API alone, the screen alone) that are dead weight until their siblings land.

A valid decomposition satisfies **every** bar below:

- **Independently deliverable** — each piece can go to Done without any *sibling* being done
  first. A suggested build *order* is fine (piece B extends A), but no piece may be inert until
  another merges, and there must be no cyclic dependency between pieces.
- **Self-contained spec** — each piece carries its own goal, its slice of the acceptance
  criteria, and its own scope boundary; a planner can pick it up without reading the others.
- **Meaningfully smaller** — each piece is expected to re-estimate **at or below 12**. Expect
  the pieces' points to **sum higher than the original** (coordination overhead is real) — that
  is normal, do not force them to add back to the original total.
- **Complete cover** — the pieces together deliver everything the original promised; nothing
  in-scope is dropped and no gap opens between them.

**Irreducible tickets exist.** If no cut produces independent slices — one tightly-coupled
change, an atomic migration, a single indivisible algorithm — do **not** manufacture a split.
Leave the ticket whole and say why it is irreducible (Advise: in the proposal; Execute: in the
output). A big-but-honest ticket beats fake independence.

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

1. **Read** the ticket (`get-ticket-details.sh <KEY>` + comments) and confirm the total > 12.
2. **Skim the touched area** for real seams — **codegraph first** (`codegraph explore`/`search`
   in the repo the ticket targets), Grep/Glob/Read only as a last resort. Skim to find seams,
   not to design.
3. **Propose the slices** against the independence bar: for each proposed piece give a title, a
   one-line goal, which acceptance criteria it owns, a rough Dev/QA size, its cross-repo touches,
   and where it sits in the build order. Confirm each piece clears every bar; flag any that
   doesn't.
4. If the ticket is **irreducible**, say so plainly and stop — recommend it ship whole (or that a
   human re-scopes it), and do not propose an artificial split.

**Completion criterion (Advise):** a proposal the Product Owner can execute without re-deciding
the seams — each piece independently deliverable, self-contained, rough-sized, and ordered — OR
a clear irreducible verdict with the reason. No tickets are created in this branch.

## Execute flow (PO)

1. **Read + confirm.** `get-ticket-details.sh <KEY>` — confirm total > 12. If a CTO proposal was
   handed in, use its slices; otherwise derive them yourself against the independence bar.
2. **Dedup.** `find-tickets.sh --query "<distinctive token from the title>" --open` — if the
   ticket already has split-children or "Split from" siblings, it was decomposed already; stop
   and report the existing pieces rather than splitting twice.
3. **Settle the slices.** Lock the independent slices (each ideally ≤ 12). If no valid split
   exists → **stop**, leave the ticket whole, and report it irreducible with the reason. Never
   force a split.
4. **Pick the split shape by piece count** (see the next section) — `N ≤ 5` → *replace*; `N > 5`
   → *epic*.
5. **Create each piece** through the adapter with a self-contained spec in its body (goal, its
   slice of the acceptance criteria, scope boundary, build-order note, and a pointer back to the
   original / epic). Write the spec to a temp `.md` and pass `--body-file`. Give it the org's
   not-started status (see `issue-tracker.md`) and the same work issue-type as the original
   (Story/feature), not a sub-task. **Replace shape: piece 1 is the original ticket itself** —
   update it in place (retitle + rewrite body) rather than creating a new key for it; only
   pieces 2..N are genuinely new. Epic shape always creates every piece fresh (see above).
6. **Re-estimate each piece — do not hand-write numbers.** Run `/estimate-ticket <NEW-KEY>` per
   piece so calibrated Dev/QA points land in the point **fields**. If a piece still comes back
   > 12, it wasn't sliced enough or it's an irreducible large piece — note it in the output (and,
   if it's cleanly divisible, split that one piece further).
7. **Reconcile the original** (see the split-shape section).
8. **Report** per *Output*.

**Completion criterion (Execute):** every piece exists on the board with a self-contained spec,
is linked/parented per the split shape, and is **estimated (point fields set)**; the original is
reconciled; and the pieces completely cover the original's scope. A piece whose points live only
in a comment is not done.

## Split shape — the tracker structure (by piece count)

Cut count `N` decides how the pieces relate to the original.

### N ≤ 5 → replace the original

The pieces are **independent siblings**. The original's own key becomes **piece 1** — pick
whichever piece it fits best (first in build order is the usual default, or whichever piece
most overlaps the original's existing component/repo/type); the rest are created fresh.

```sh
# 1) reuse the original as piece 1 — an ordinary update, no create-only flags needed
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <ORIG> \
  --title "<piece 1 title>" --status "<not-started status>" \
  --body-file <piece1-spec.md>
#    pasted images/attachments already on <ORIG> carry over onto it automatically

# 2) create pieces 2..N fresh — same work type as the original, linked back to it
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --title "<piece title>" --issuetype "<original's type, e.g. Story>" \
  --status "<not-started status>" \
  --link "Split from":<ORIG> \
  --body-file <piece-spec.md>
```

Then re-estimate **every** piece including the reused original (step 6) — its old combined
estimate no longer applies once its scope has shrunk to just piece 1. Nothing needs superseding
or closing: the original ticket simply *is* piece 1 now, under its own key, in whatever status
that piece is naturally in.

### N > 5 → new short-named epic, pieces as children

Too many for a flat replace — group them under an epic.

```sh
# 1) create the epic — a SHORT umbrella name distilled from the original title
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --title "<short epic name>" --issuetype Epic \
  --link "Split from":<ORIG> --body-file <epic-summary.md>
#    → read the epic <EPIC-KEY> from the "Created <KEY> — …" line

# 2) each piece is a CHILD of the epic
"$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh new \
  --title "<piece title>" --issuetype "<original's type>" \
  --parent <EPIC-KEY> --status "<not-started status>" \
  --body-file <piece-spec.md>
```

Then re-estimate each child (step 6), and **supersede the original into the epic**: body → a
pointer to `<EPIC-KEY>`, terminal status if the board has one, else flag for human closure. Unlike
the replace shape, the original can't become one of the children here — the adapter's `--parent`
only applies on create, so an existing issue can't be re-parented under the fresh epic — so this
is the one case where the original is still superseded rather than reused. Carry over its
attachments the same way: download anything `get-ticket-details.sh <ORIG>` flags
(`⚠ N embedded …`) and `add-ticket-attachment.sh` it onto whichever child(ren) need it.

If the provider rejects the `Epic` issue type (unknown name), the adapter **fails loud** and
prints the valid types — surface that and pick the org's real epic-level type; never invent one.
For the `Split from` link, the adapter silently substitutes the **closest existing** link type
(e.g. `Relates`) and says so — carry that note into the output; never drop the link.

## Guardrails

- **Points live in fields; estimation is `/estimate-ticket`'s job.** This skill never hand-writes
  Dev/QA points and never touches the derived total — it delegates every re-estimate to
  `/estimate-ticket` so the board stays calibrated.
- **Don't split below the bar.** Independent slices only; irreducible ⇒ keep whole. Prefer one
  honest big ticket over several fake-independent ones.
- **Complete cover, nothing dropped.** Every acceptance criterion of the original lands in exactly
  one piece. Attachments are scoped to the issue they live on — the piece that reuses the
  original's key (replace shape's piece 1) keeps them for free, but every *other* piece that
  needs them (mockups almost always belong on the UI-bearing piece, and on any piece whose AC
  cites literal numbers read off them) needs its own copy: download the image and
  `scripts/tracker/add-ticket-attachment.sh <NEW-KEY> <file>` it there (Jira only for now).
- **Idempotent.** Never split a ticket that already has split-children/siblings (step 2 dedup).
- **Adapter only, fail loud.** If the tracker is unreachable, report the split was **not** applied
  (don't fabricate keys) — same rule as `docs/agents/issue-tracker.md`.

## Output

Return a compact summary the caller (CTO consult / PO ticketing / `/prd`) can carry forward:

```
original:    <KEY>  (total <T> > 12)
verdict:     split | irreducible
shape:       replace | epic | n/a         # n/a when irreducible
epic:        <EPIC-KEY> | none            # the new epic, when shape=epic
pieces:                                   # empty when irreducible
  - <KEY-a>  dev <d>/qa <q> (total <t>)  — <one-line goal>   # replace shape: KEY-a == <ORIG>, reused as piece 1
  - <KEY-b>  …
original_state: reused as piece 1 (<ORIG>) | superseded (<status>) | left-open — human close needed | unchanged (irreducible)
note:        <irreducible reason / a piece still >12 / epic-type or link fallback / tracker issue>
```
