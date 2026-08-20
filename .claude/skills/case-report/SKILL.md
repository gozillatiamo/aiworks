---
name: case-report
description: >-
  Turn a finished deployed-environment investigation into a case file a human can act on -
  background, entities, an evidence-backed verdict, and a runbook of verify + execute steps. Use
  when an operator, admin or support agent reported something wrong in a running environment and
  wants a written answer, or when a root-cause verdict must be handed to whoever acts on it. For a
  bug reproducible on a laptop the write-up belongs on the ticket.---

# Case file

A **case file** is written for the person who will act on it, not for the investigator who wrote
it. It answers three questions in order — what happened, why, and what do I do now — and each
answer is backed by a **receipt**.

A **receipt** is the exact tool call or command that produced a fact, plus what it returned. The
gate this skill exists to enforce:

> **A claim without a receipt does not go in the case file.** Source code may only *interpret* a
> receipt — it can explain a mechanism you measured. A verdict whose only support is reading
> source is not a verdict: tier it `SPECULATIVE`, name the observation that would settle it, and
> say so in the report.

That rule is not a style preference. A confident case file built from a plausible-looking code
path sends a human to run a mutation against real data on a wrong premise.

## Step 1 — Name the case

Fix one identifier and use it everywhere: the ticket key when one exists, otherwise
`<YYYY-MM-DD>-<short-slug>` (get the date from `date +%F`, never from memory). It becomes the
`Case:` value in the heading and the filename `<script-repo>/agent_logs/<CASE>-report.md`, where
`<script-repo>` is the repo Step 2 resolves. A case crosses whatever repos the symptom crosses and
often names none of them, so it lands beside the scripts its runbook cites — not in a code repo.

**Done when:** the identifier is fixed and no other name for this case appears in your output.

## Step 2 — Load the organization's template

The report's section set is **organization-specific and lives outside this skill**. Resolve it:

1. Read `workspace.config.yaml` and find the repo declared `kind: script` — that repo is the
   organization's store of reusable production-troubleshooting scripts and the guideline that
   goes with them.
2. Read that repo's troubleshooting guideline (`docs/production-troubleshooting.md`) and its
   case-report template (`docs/case-report-template.md`). Fill the template's sections, in its
   order, with its wording.

If no repo is declared `kind: script`, or it is not cloned, fall back to the generic skeleton —
Background · Entities involved · Relevant history · Verdict and root cause · Troubleshooting
(Verification, then Execute) — and say in the report that the organization template was unavailable.

**Done when:** the exact list of sections you are going to fill is written down, and you know
which are required and which are conditional.

## Step 3 — Receipts before prose

Gather evidence for every section *before* writing any of it. Four sources answer different
questions; the report states which ones ran and which did not:

| source | the question only it can answer |
|---|---|
| observability (SigNoz logs + traces) | what the request did — latency, error rate, span waterfall, base rate over a window. Covers **both the product's own services and the API gateway (APISIX)**: a request that never reached a service is visible only at the gateway. |
| `pg_triage` | what the data *actually is*, versus what the code implies. Read-only; name the environment on every call; disconnect when done. |
| `redis_triage` | whether the symptom is **stale** rather than wrong — a cached value disagreeing with the row, a session that should exist, a stream consumer group lagging or holding a stuck pending entry. |
| `k8s_triage` | **only when the question is about the runtime itself** — a pod replaced mid-incident, a route timeout or retry, node pressure, logs from a container that already died. Skip it when the other three answer the case. |

Reach for `/root-cause-deployed` when the cause is genuinely unknown — it is the method that keeps
competing explanations alive until evidence kills them. This skill is the write-up; that skill is
the investigation.

**Done when:** every fact you intend to state has a receipt, and every source above is either
used or explicitly recorded as not needed. A source you could not reach is a *finding* — name it
and what it would have settled. Never report an unreachable source as a clean result.

## Step 4 — Write the case file

Fill the template's sections. Concise, not verbose — the reader is triaging, not studying. A
conditional section that does not apply is dropped with a one-line reason, never left as an empty
heading.

Carry the verdict's tier (`CONFIRMED` / `LEADING` / `SPECULATIVE`) into the report in the verdict
section, together with what would change it. A single sighting caps at `SPECULATIVE` however well
the story fits.

**Done when:** every section is either filled from a receipt or dropped with its reason, and the
verdict names the specific rows, spans, keys or resources it rests on.

## Step 5 — The runbook

The troubleshooting section is a **runbook for a human**, never something you execute. You produce
guidance; a person decides and runs it.

- **Prefer an existing script.** Look in the `kind: script` repo first and cite the script's path
  and its parameters. A bespoke query is what you write when nothing there fits.
- **Bespoke SQL is wrapped so it cannot commit by accident** — open a transaction and roll back by
  default, leaving the commit as a deliberate edit by the human.
- **Verification runs twice, and is written first.** The pre and post checks must be the *same*
  observation so their outputs are comparable — that is what lets the human confirm the change did
  what it claimed. Give both as code blocks even when they are identical, and put that section
  **above** Execute: a reader who mutates before taking the pre-reading has nothing left to compare
  the result against, and the pre-reading is also the last chance to notice the case has moved since
  you investigated it.
- **A script worth keeping goes back to the store.** When a bespoke script would serve the next
  case too, say so and name where it belongs in the script repo. You propose; a human commits it.

**Done when:** Verification and Execute are both runnable as written — in that order — with no
placeholder a human has to guess at, and every mutation is reversible or its irreversibility is
stated in the report.

## Step 6 — Publish by form

The same case file goes to different surfaces in different languages, decided by **file type
first**:

- **`<script-repo>/agent_logs/<CASE>-report.md`** — English, always. The file-type invariant in
  `docs/agents/language.md` admits no exception, `agent_logs/` included.
- **Ticket comment, chat message, Slack, your reply** — the workspace output language, English
  spine (headings, labels, code, identifiers, technical terms stay English).

**Who gets it unasked.** Post the summary back **only when your prompt carries a reply target** —
a channel and thread the dispatcher wrote into your brief. That means a person is waiting somewhere
you are not, and silence reads as no answer. Reply through the **local** notify adapter of the
checkout you are running in, never another clone's copy, and confirm it returned `ok=1`. With no
reply target, the person who asked is right here: answer in the session and let them decide where
it goes.

Quote the inner-system identity or an aggregate, never a raw personal value — see
`docs/agents/pii-provenance.md`.

**Done when:** the file exists in English, and anything you posted elsewhere is in the resolved
output language.
