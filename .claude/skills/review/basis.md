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

## 4. The review level sets how deep you report

Read `review.level` from `workspace.config.yaml` (default **strict** when absent). It
decides whether the **nice-to-have** tier is surfaced at all — it never softens a
must-fix.

- **strict** — report **only must-fixes**: the bar breaches (§1) and bottom-line
  breaches (§2) that block a "met" verdict. Suppress the nice-to-have tier entirely —
  raise no polish, no optional refactor, no "you might consider" finding.
- **thorough** — report must-fixes **plus** nice-to-have: also surface the non-blocking
  instrument findings (§3 judgement calls, optional refactors, hardening) as clearly
  labelled advisory findings, separate from the must-fixes.

Must-fixes are the floor at both levels; the level only gates the tier above them.

## 5. Every claim carries a receipt

§3 tells you to name the instrument behind a finding. This is the other half: the
instrument has to be one you actually **ran or read** — a **receipt**, the command
output you produced or the `file:line` you opened. A claim with no receipt is a
**hypothesis**, not a verdict — say so; never dress it as fact.

You have **no build or test tool**: you *read* the developer's results
(`scripts/dev.sh status`/`why`), you never run the suite yourself. So "it compiles",
"tests pass", "0 errors", "verified via cargo/npm" are **never yours to assert** — cite
the developer's actual gate result, or write "should, pending the gate". A build result
you did not read is a **fabricated instrument**: the one move a review may never make.

A claim about a **fix that isn't written yet** — "widening this compiles", "needs zero
call-site changes" — is a hypothesis about code that does not exist; only the developer,
and the gate that builds it, can settle it. Name the smell and the direction, and let the
gate rule — never win a developer's pushback by asserting an unrun result. Proving a fix
builds is the writer's job and the gate's, not the reviewer's.

This disciplines your **evidence, not your spine**: a real smell is still a must-fix
stated plainly — you just hold it with a receipt (the standard it breaks, the dependent
`codegraph` shows) and leave the compile to the gate.
