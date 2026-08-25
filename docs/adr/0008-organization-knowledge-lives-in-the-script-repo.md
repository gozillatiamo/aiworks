# Organization knowledge lives in the script repo, not in the framework

**Status:** Accepted

This workspace is a framework meant to be adopted by an organization and filled with its product.
Most of the time the split costs nothing, because a skill can name a generic concept and let each
adopter supply the specifics. The production-case write-up broke the arrangement, because the thing
that needed writing down was *entirely* product.

The `case-report` skill produces the artifact a human acts on after a live case: background, the
entities involved, the verdict, and a runbook. Its section set — who the affected parties are and
in what roles, which account and organization they belong to, the activity history, the money
history, eligibility for whatever programs the product runs — is not a framework concept with
product examples in it. It **is** the product. A framework skill carrying those headings would be
one company's skill wearing a framework's name, and every other organization inheriting it would
start by deleting the parts that describe somebody else's business.

## The split, and where the seam sits

The framework keeps the **process**: gather receipts before writing prose; the evidence sources and
what each one alone can answer; a verdict carrying its tier; a runbook whose verification is the
same observation run before and after. None of that knows what the product sells.

The organization keeps the **domain**: the section set, which triage source fills each section, the
reusable scripts a runbook cites, and the guideline tying them together. That material lives in the
repo declared `kind: script` in `workspace.config.yaml` — the repo that already stores the
troubleshooting scripts, which is where someone looking for "how do we handle a production case"
goes first anyway.

The alternative was to write the domain into the skill and scrub it when the framework is shared.
It was rejected because scrubbing is a step a human performs from memory, on a diff, months later.
It has no failure signal — a leak looks exactly like a skill until someone outside notices. Putting
the domain in a different repo makes the boundary a fact of the filesystem instead of a promise
about a future code review.

## The binding is config for the repo, convention for the filenames

The skill resolves the *repo* from configuration, and the *filenames* by convention:
`docs/production-troubleshooting.md` and `docs/case-report-template.md` — and, for the sibling
`repair-script` skill that generates the artifact a case's runbook hands over, `docs/repair-script.md`.

That split looks inconsistent and is deliberate. Which repo holds an organization's scripts is a
genuine per-organization fact, and each one names it differently. What the guideline file is called
is a contract between the framework and any organization adopting it; making it configurable would
add a key that must be maintained forever to point at a name that never changes, and would let a
typo in a personal override silently produce a report with no template.

When no repo is declared `kind: script`, or it is not cloned, the skill falls back to a generic
skeleton and **says so in the report**. A missing template degrades the write-up; it never silently
produces one that looks complete.

## Consequences

The case file lands in `<script-repo>/agent_logs/<CASE>-report.md`, not in a code repo. A production
case crosses whatever repos the symptom crosses and frequently names none of them, so the
per-touched-repo rule in `docs/agents/plan-artifacts.md` does not apply to it; it sits beside the
scripts its runbook cites. `agent_logs/` is git-ignored there as everywhere, so the file stays a
working deliverable.

Producing a case report now costs one cross-repo read. That is the price of the boundary, and it
buys a framework an organization can adopt without inheriting somebody else's product.
