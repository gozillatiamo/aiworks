---
name: repair-script
description: >-
  Repair script for a defect in a running environment - generate the executable artifact a human
  runs to fix it, climbing a ladder that puts a repair through the service above one that writes
  the datastore directly. Use when someone asks for a script to clear, refund, re-send, settle or
  unstick named records in a deployed environment, or when a finished investigation's verdict has
  to become the thing that repairs it. Generates and hands over; never runs it.
---

# Repair script

A **repair script** is the executable end of an investigation: the artifact a human runs against
real data to put it right. This skill decides **which mechanism** repairs it, produces that
artifact, and hands it over with the work list that makes running it a decision rather than an
act of faith.

Two rules the whole skill exists to enforce:

> **Generate; never execute.** A repair moves real records — money, entitlements, state someone
> depends on. The person who runs it is the one who decides to.

> **A rung is skipped only on a receipt.** "That one probably won't work" is not a reason to drop
> to a cruder mechanism, and neither is "it's faster". Name the observation that closed the rung.

## The ladder

**Rung** is the unit this skill thinks in. The rungs are ordered by how much of the system a
repair goes through, highest first:

1. **Through the service** — replay or re-drive the real code path. It writes every side effect
   the original request would have: the record, the events, the caches, the traces.
2. **Direct at the datastore** — SQL against the tables. It writes the rows and nothing else;
   everything downstream stays wrong unless someone repairs that by hand too.

The organization's own file names its concrete rungs, the scripts on each, and the closed list of
observations that push a target down one. **Read it — the ladder is not yours to invent.**

## Step 1 — Fix the defect and the entity set

You are generating a mutation. Establish, before anything else:

- **The defect**, as an established verdict with a receipt behind it — not a reported symptom. A
  repair generated from "the player says the balance is wrong" repairs a guess. If the verdict is
  not established, this is the wrong skill: investigate first, then come back.
- **The entity set** — every record the repair will touch, found by scoping to the *entity* and
  reading its own history. **The date a human noticed is never the bound.** Widen until the far
  edge comes back empty; a query still returning hits at its boundary is a truncation.

**Done when:** the defect has a receipt, and the entity set was widened until its far edge
returned nothing.

## Step 2 — Load the organization's ladder

The rungs, the scripts, the parameters and the artifact conventions are **organization-specific
and live outside this skill** (`docs/adr/0008`). Resolve them the way `case-report` does: the repo
declared `kind: script` in `workspace.config.yaml`, then its repair guideline
`docs/repair-script.md` and the `docs/production-troubleshooting.md` it sits under. Follow its
rungs, its scripts and its artifact paths, not a shape you invented.

With no such repo, or none of those files: say so in the handoff, keep the two-rung ladder above,
and treat every convention you had to choose yourself as something a human must confirm.

**Done when:** the concrete rungs are written down in the organization's own terms, with the
script that serves each.

## Step 3 — Pick the rung, with the receipt

Start at the top rung and work down. For each rung above the one you land on, record the
observation that closed it — the empty query *run against a working control*, the failed status
code, the shape that has nothing to replay. A control matters more here than anywhere: an empty
result with no control is a wrong query, not an absent record.

A rung closed by assumption is the failure this step exists to prevent — it silently trades a
complete repair for a partial one.

**Done when:** the chosen rung is named, and every rung above it has a receipt beside it.

## Step 4 — Generate

Produce the artifact with the organization's own generator or template — never a bespoke
equivalent when one is declared for the shape.

- **Order the work by when it happened**, oldest first, so the repair replays the sequence the
  records were written in.
- **One artifact covers the whole entity set.** A repair split across a dozen hand-run commands is
  where a record gets missed.
- **A target the generator could not cover stays visible in the artifact** — a comment, a skipped
  list, a count in its summary. Never silently dropped; each one is a candidate for the next rung
  down.
- **Keep the safety wrapper** the organization's templates ship with (a dry-run default, a
  transaction the human commits by hand). Removing it is the human's edit, not yours.
- **Re-runnability is not assumed.** State plainly whether the artifact is safe to run twice, and
  if a partial run has to be regenerated rather than repeated, say so where the runner will see it.

**Done when:** every entity from Step 1 is either covered by the artifact or listed in it as not
covered, and the two together account for the whole set.

## Step 5 — Hand over

The artifact alone is not the deliverable. Ship with it:

1. **The rung, and the receipts** that closed the rungs above it.
2. **The work list** — every record the artifact touches, in run order, with the amount or state
   that will change; and separately, every record it does not.
3. **Verification, written above execute** — the same observation run before and after, so the two
   outputs compare. A runner who mutates first has nothing to compare against.
4. **The exact command**, plus whatever access it needs (a tunnel, a role, a one-line edit that
   arms it).

**Done when:** a person who was not part of the investigation could run it, check it, and tell
whether it worked — from the handoff alone.
