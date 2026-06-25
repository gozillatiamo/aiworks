# The basis for a review verdict

Three ideas ground every finding. Read them before judging anything — they decide
what counts as a problem and what counts as proof.

## 1. The requirements are the bar

The originating ticket's requirements are what the change exists to achieve. They
are the **bar** the verdict measures against, and the review's core question is
**"are the requirements genuinely met?"**

*Genuinely* is load-bearing. A requirement is not met because code exists that
gestures at it — only when the behaviour the ticket asked for is present, complete,
and correct. Three ways the bar is missed:

- **Missing / partial** — the ticket asked for it; the diff doesn't deliver it, or
  delivers only part.
- **Wrong** — the diff implements it, but the behaviour is incorrect, or it breaks a
  dependent the requirement relies on.
- **Superficial** — the code resembles the requirement but doesn't hold up under
  verification (§2).

Scope creep — behaviour the ticket did **not** ask for — is a finding too: unrequested
risk against the bar.

## 2. The coding standards are the bottom line

The repo's coding standards are a **hard floor** every change must clear — not one
instrument among many to weigh, but a non-negotiable bottom line. They live in the
repo's standards docs: `.claude/rules/coding_standards/` (split per area —
`route`, `dao`, `services`, `aggregator`, `util`, `error`, `models_schemas`,
`constant`, …), plus `CLAUDE.md` / `CONTRIBUTING.md` and any `STYLE`/`STANDARDS` docs.

A standards breach is a **hard finding (must-fix)**, never a judgement call: a diff
that clears the bar (§1) but breaks a coding standard is **not genuinely met**. The
bar is what the change must *reach*; the bottom line is what it must *never fall
below* — both have to hold for the verdict to pass.

Skip only what tooling already enforces (linters / formatters / `rustfmt` /
`tsconfig`) — those are caught mechanically. Everything the standards docs state
that tooling does **not** check is the floor you verify by reading; cite the exact
rule (file + section) for every breach.

## 3. The repo's knowledge is your instrument

You don't certify "genuinely met" by eyeballing the diff. You **verify** it against
what this repo already knows about itself. These are the instruments — name the one
that produced each finding:

- **Structure** — where things live; the module/context boundaries and layering a
  change must respect.
- **Design patterns** — the idioms this codebase commits to (feature-first, the
  established abstractions, the data-flow shape).
- **Docs & ADRs** — `docs/`, `docs/adr/`, CONTEXT files: decisions already made, which
  a change must honour or explicitly supersede.
- **Coding standards** — graduated to the bottom line (§2); verify breaches there, as
  must-fixes, not as one weighed instrument among these.
- **Codegraph + blast radius** — the repo's pre-built index. `codegraph explore`/`search`
  to understand a touched area; **`codegraph callers`/`codegraph impact`** to see what
  depends on a changed symbol *outside* the diff. Prefer it over a grep+read sweep;
  `Grep`/`Glob` are the last resort for a detail it didn't cover.

These are not a second scorecard to tick. They are how you tell "looks done" from
"is done": a requirement built against the grain of the repo's structure, in violation
of an ADR, or breaking an out-of-diff dependent is **not genuinely met**. Cite the
instrument for every finding — the file + rule, the ADR, the codegraph dependent.
