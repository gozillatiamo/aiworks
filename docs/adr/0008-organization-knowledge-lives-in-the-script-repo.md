# Organization knowledge lives in the script repo, not in the framework

**Status:** Accepted

This repo is two things at once: the organization's workspace, and the base a de-branded framework
is contributed upstream from. Most of the time that costs nothing, because a skill that names a
domain table is scrubbed on the way up. The production-case write-up broke the arrangement, because
the thing that needed writing down was *entirely* domain.

The `case-report` skill produces the artifact a human acts on after a live case: background, the
entities involved, the verdict, and a runbook. Its section set — who the player, agent or admin
is, the site and agency, the betting history, the financial history, promotion and commission
eligibility — is not a framework concept with domain examples in it. It **is** the domain. A
framework skill carrying those headings would be a betting-platform skill wearing a framework's
name, and every future organization inheriting it would start by deleting the parts that describe
somebody else's product.

## The split, and where the seam sits

The framework keeps the **process**: gather receipts before writing prose; four evidence sources
and what each one alone can answer; a verdict carrying its tier; a runbook whose verification is
the same observation run before and after. None of that knows what a bet is.

The organization keeps the **domain**: the section set, which triage source fills each section, the
reusable scripts a runbook cites, and the guideline tying them together. That material lives in the
repo declared `kind: script` in `workspace.config.yaml` — the repo that already stores the
troubleshooting scripts, which is where someone looking for "how do we handle a production case"
goes first anyway.

The alternative was the practice already in use elsewhere: write the domain into the skill and
scrub it at contribution time. It was rejected because scrubbing is a step a human performs from
memory, on a diff, months later. It has no failure signal — a leak looks exactly like a skill until
someone outside notices. Putting the domain in a different repo makes the boundary a fact of the
filesystem instead of a promise about a future code review.

## The binding is config for the repo, convention for the filenames

The skill resolves the *repo* from configuration, and the *filenames* by convention:
`docs/production-troubleshooting.md` and `docs/case-report-template.md` — and, for the sibling
`repair-script` skill that generates the artifact a case's runbook hands over, `docs/repair-script.md`.

That split looks inconsistent and is deliberate. Which repo holds an organization's scripts is a
genuine per-organization fact — this one calls it `dev-script`, the next will not. What the
guideline file is called is a contract between the framework and any organization adopting it;
making it configurable would add a key that must be maintained forever to point at a name that
never changes, and would let a typo in a personal override silently produce a report with no
template.

When no repo is declared `kind: script`, or it is not cloned, the skill falls back to a generic
skeleton and **says so in the report**. A missing template degrades the write-up; it never
silently produces one that looks complete.

## Consequences

The case file lands in `<script-repo>/agent_logs/<CASE>-report.md`, not in a code repo. A
production case crosses whatever repos the symptom crosses and frequently names none of them, so
the per-touched-repo rule in `docs/agents/plan-artifacts.md` does not apply to it; it sits beside
the scripts its runbook cites. `agent_logs/` is git-ignored there as everywhere, so the file stays
a working deliverable.

Producing a case report now costs one cross-repo read. That is the price of the boundary, and it
buys a framework that can be handed to another organization without an audit.
