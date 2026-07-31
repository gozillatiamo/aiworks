# Decomposition piece-spec templates

Write each split piece's body and the epic summary from the matching skeleton below.
Pass the filled Markdown through `upsert-ticket-details.sh --body-file <spec.md>` (Execute
flow, step 5). The skeletons only mark the SHAPE — fill every `<placeholder>` from the
original ticket's content + the CTO proposal; carry through the original's acceptance
criteria, scope, and links (nothing dropped — *complete cover*).

**Language of the FILLED-IN prose (read before composing).** If your OUTPUT LANGUAGE is
`th` (per the `LANGUAGE_DIRECTIVE` in your prompt, else resolved from
`workspace.config.local.yaml` / `workspace.config.yaml`), then EVERY value you write into a
`<placeholder>` — the problem statement, proposed change, each scope item, each acceptance
criterion, the build-order note, each technical note, the epic objective/success criteria —
is **Thai prose**. Do NOT copy the English placeholder wording; the placeholders only mark
the shape. Keep English ONLY for: the section **headings** (`## Problem`, `## Scope`,
`## Acceptance criteria` …), the ticket **title** (`# <title>`), the `- [ ]` / `-` list
syntax, and all code / identifiers / API names / package names / version numbers / domain &
proper-noun terms (Arabic numerals always). **A piece body that comes back in English under
`th` is a defect, not a stylistic choice** — the tracker adapter now hard-blocks an
all-English body written under a `th` policy (`upsert-ticket-details.sh` language gate), so a
non-localized body will be rejected before it reaches the board. Default `en` ⇒ write
everything in English exactly as the skeleton shows; this block is a no-op.

**Stay at the business-requirement level.** Fold the CTO's feasibility/risk findings into
the *Scope* and a short *Technical notes* section; the rest of the body stays in
business-requirement voice. Never write concrete file paths, function names, or
step-by-step implementation into a piece body.

## Piece — Task / Story / Improvement

```
# <concise piece title>

## Problem
<what is broken / missing today and why this slice matters — the piece's own slice of the
original problem, self-contained so a planner needs no sibling>

## Proposed change
<one paragraph: what this piece delivers, at the capability level>

## Scope
- <in-scope item>

## Out of scope
- <explicit boundary — what a sibling piece owns instead>

## Acceptance criteria
- [ ] <this piece's slice of the original acceptance criteria>

## Depends on
<build-order note + pointer back to the original / epic. Gate-1 (≤36) split: "none — parallel
with siblings <KEYS>". Gate-2 (>36) split where genuinely blocked: "<KEY> (must merge first)"
— and this same dependency is wired as a real `--link "is blocked by":<KEY>`>

## Technical notes
- <CTO feasibility/risk finding folded in — high level, area/service hints only>
```

## Epic summary (N >= 4 split shape)

```
# <short epic name>

## Objective
<one paragraph: the whole change the epic delivers and why, at the capability level>

## Scope
- <slice name>: <one-line goal>

## Build Order
- <KEY>: <role in the order — foundation / parallel-after-foundation / final gate>

## Success Criteria
- <what "the epic is Done" means across all pieces>
```
