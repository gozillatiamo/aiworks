---
name: ultra-review
description: Run a ticket's open MR/PR through two specialist review gates at once — code-reviewer (clean-code + spec), performance-engineer (profiling) — spawned in parallel, then aggregated into one combined verdict where a blocking finding at any gate caps the result. Honors the workspace output language and review.level. On a clean ticket-wide pass it posts the PASS approval on every MR/PR and advances the ticket to the configured ready-to-merge status (config-gated, skipped when that status is not configured). Use when the user wants a deep / full / ultra review, a multi-gate review, or a combined code + performance review of a <KEY> ticket — distinct from /review, the single spec+standards pass.
disable-model-invocation: true
---

# Ultra-review

Runs one ticket's open MR/PR through **two specialist gates in parallel** — Daniel
(code-reviewer), Liam (performance-engineer) — then aggregates their verdicts into one. A
**blocking finding at ANY gate caps the combined verdict**, no matter how clean the other is.

Distinct from `/review` (the single 2-axis spec+standards pass by two `general-purpose`
sub-agents): ultra-review fans out the two *acting* specialist agents, which comment
inline on the live MR/PR and render their own verdicts. The verdict grounding is shared —
[`.claude/skills/review/basis.md`](../review/basis.md) — and every gate reads it first.

**Scope — review, never merge.** The gates review, comment findings inline, and render a
verdict; the **orchestrator** posts the single ticket-wide PASS **approval** — and only when
every gate on every repo is clean (§3.5), never a gate per-repo. No one **merges** — not the
gates, not the orchestrator, even where `auto_merge` is on. Approve says "cleared the bar";
merge stays a separate, later human decision.

## 0. Resolve language + review level BEFORE spawning (do this FIRST)

These two values are resolved **once here** and pasted **verbatim** into both gate
briefs. The gates are real sub-agents that would otherwise each re-resolve from disk and can
drift; passing the resolved directive is the proven fix (mirrors `/review` step 4). Both
agent definitions honor an in-prompt directive over any self-resolution.

- **Output language.** If a `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line is already in
  your prompt, that value is authoritative — do NOT re-resolve. Otherwise read
  `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a
  `language:` line, else `workspace.config.yaml` — never from memory.
- **Review level.** Read `review.level` from `workspace.config.yaml` (default **strict** if
  absent).

State both resolved values + their source in one line before spawning. Hold this block to
paste into **every** gate brief (substitute the resolved values, never the literal `<…>`):

```
OUTPUT LANGUAGE = <en|th> (authoritative — do NOT re-resolve). Write every finding's prose
in this language; under th the finding SENTENCES are Thai with an English spine — headings/
labels, ALL code + identifiers + file paths, and technical/domain/proper-noun terms stay
English (Arabic numerals always); under en write English.
Review level = <strict|thorough> (passed in — do NOT re-read the config). At strict report
blocking must-fixes only; at thorough also triage the nice-to-have tier.
```

## 0.5 Detect the run: fresh vs re-visit

Two shapes of run, and the shape changes both the gate briefs (§2) and the aggregate (§3):

- **Fresh** — first ultra-review pass on this ticket's MR/PR. Gates review the whole diff and
  surface every must-fix they find.
- **Re-visit** — the user says "re-visit" / "revisit" / "re-review" / "recheck", or names a fix
  ("the author just fixed X"), for a ticket that already carries gate comments on its MR/PR. A
  re-visit is **not** a second fresh pass: each gate checks its **own prior findings** against
  the new commit — resolved, or still open — and raises nothing outside the lines the fix
  commit touched. **One exception:** if the fix commit itself introduces a new bug in those
  touched lines, that IS reportable as a new must-fix; it stays scoped to the fix diff, never a
  fresh full-file sweep.

Detect re-visit from the user's **phrasing**, not from prior comments merely existing — an
ordinary second look after unrelated commits is still a fresh pass. Default to fresh when unsure.

**Completion:** you know the run's mode, and — for re-visit — you hold the prior must-fix
thread list (`scripts/vcs/pr-threads.sh <num>`, run from inside each repo) plus the fix commit's
SHA.

## Process

### 1. Pin the ticket + its open MR/PR

Resolve the `<KEY>` ticket (id format + fetch via `docs/agents/issue-tracker.md`, through
`scripts/tracker/`). Find its **open MR/PR(s)** via the VCS adapter (`scripts/vcs/`) — for
each, capture the branch, the target branch, and the MR/PR number/ref.

**Completion:** you hold the ticket plus at least one open MR/PR (branch → target). If the
ticket has **no open MR/PR**, STOP and say so: these gates comment on a live MR/PR — open one
first (`/open-pr`), or use `/review` for a branch-only pass. Do not fabricate a diff.

*(Multi-repo ticket: collect every repo's open MR/PR and hand each gate the full list — the
gates review each. No wave engine here; that is dev-cycle's job.)*

### 2. Spawn the two gates in parallel

Send **one message with two `Agent` tool calls** — `code-reviewer`, `performance-engineer` —
so they run concurrently and don't pollute each other's context. Into **each** brief put:

- The shared directive block from §0 (language + review level), verbatim.
- The ticket `<KEY>` and the open MR/PR ref(s) + branch + target.
- `"This is an ultra-review pass — review, comment findings inline on the MR/PR, and render
  your verdict. Do NOT approve and do NOT merge (even if auto_merge is on): the orchestrator
  posts the single ticket-wide PASS approval once every gate on every repo is clean, and merge
  is a separate, later decision."`
- **A force-shell first line** (proven fix for the perf "no Bash" give-up — see §3):
  `"Your FIRST action is a real Bash call — run `scripts/vcs/pr-view.sh <num>` (or `git
  rev-parse --show-toplevel`) from inside the target repo BEFORE any analysis or prose. Do NOT
  reason about whether Bash/tools are available — you HAVE a scoped Bash grant (the code-reviewer
  uses the identical mechanism). Never self-report 'no Bash / no shell' without an actual failed
  attempt; a real denial comes with a real error you must quote."`
- **Code gate ONLY — the green run is a MUST DO, and it gates the approval:**
  `"Before you render a verdict, RUN THE SUITE on the MR/PR head yourself — workflow step 5
  ('Verify green'). Use the repo harness (`scripts/dev.sh test`, plus `analyze`/`gen` when
  that repo's `green:` in workspace.config.yaml names them), never the raw toolchain, and
  run the WHOLE suite, not just the ticket's tests. Return the invocation + result as a
  receipt: I cannot post the ticket-wide approval without one. A red suite is a must-fix —
  post it inline, after ruling out a known false-red (stale/shared test DB, submodule
  branch drift, a suite already red on the target branch). If it genuinely cannot run,
  say so with what you tried and the exact unblocking command — the verdict is then
  UNVERIFIED, never a pass. ⚠️ The performance gate is reading this SAME clone in
  parallel: do NOT leave the checkout moved. Either restore the original ref, or run in a
  throwaway `git worktree add`."`
  The performance gate gets the mirror-image line: `"Do NOT check out a different ref in
  the shared clone — read the branch with `git show <sha>:<path>`; the code gate is running
  the suite there."`
- **Re-visit mode only** (§0.5): replace the generic review instruction above with — paste the
  prior must-fix thread list (file/line/body/resolved-state) and the fix commit SHA, then:
  `"This is a RE-VISIT, not a fresh review. Check ONLY your own prior must-fix findings above
  against commit <SHA> — mark each resolved or still-open, with evidence. Do NOT review other
  code, do NOT raise nice-to-have/style findings you skipped last round, do NOT re-sweep the
  whole diff. One exception: if <SHA> introduces a new bug in the lines it touches, report that
  as a new must-fix — nothing further afield. The green run is NOT scoped down by a re-visit,
  though: <SHA> changed code, so run the suite again on it and return a fresh receipt — a
  green from the previous round proves nothing about this commit."`

Each gate then runs its own instrument (Daniel: `/review` + codegraph blast radius; Liam:
profiling) per its own definition — no extra tool grant needed. **Completion:** both gates
have returned a verdict — fresh: every must-fix found; re-visit: resolved/still-open per prior
finding, plus any new must-fix strictly confined to the fix commit's touched lines. **The code
gate has additionally returned a test receipt** (the invocation + result, or an explicit
could-not-run with what it tried) — §3.5 will not post an approval without it.

### 3. Aggregate

**Backstop — verify every finding actually landed inline, IN THE RIGHT LANGUAGE (do this
FIRST, before presenting).** A gate can return a verdict yet fail to post its findings — most
often it wrongly concludes it "has no shell / no Bash" and leaves them only in its return text
(a genuine denial is different: it comes with a real error). A gate can also post for real but
in the wrong language — a gate's own language self-resolution can drift even with the §0
directive pasted verbatim (root-caused 2026-07-22, ticket OFB-1803: code-reviewer posted two
must-fix comments in English on a `th`-resolved run). So for each repo's MR/PR, list the posted
review threads (`scripts/vcs/pr-threads.sh <num>`, run from inside that repo) and reconcile them
against the must-fixes each gate reported, checking BOTH:
1. **Presence** — is the finding on the MR/PR at all?
2. **Language** — under `th`, does the posted body actually contain Thai prose (not just an
   English body with technical terms)? Under `en`, is it English?

**MR/PR numbers collide across repos — verify cwd before every post.** `pr-comment.sh`
resolves its target repo from cwd, not from the number you pass. A multi-repo ticket
routinely has the SAME number in two different repos (e.g. OFB-1803: `backoffice` !806 AND
`agent-webservice` !806 — unrelated MRs, same number). Run `git remote get-url origin`
immediately before every `pr-comment.sh`/`pr-threads.sh` call and confirm it matches the repo
you intend — do not trust a `cd` from a prior step to have stuck (root-caused 2026-07-22,
OFB-1803: a stale cwd sent a backoffice-repo finding to an unrelated, already-merged MR in
agent-webservice that happened to share the number).

For any finding that fails either check — missing, or present but in the wrong language — post
(or re-post) it yourself via `scripts/vcs/pr-comment.sh --path <file> --line <n> --body …` —
anchored + quoting the code, in the resolved OUTPUT LANGUAGE, attributed to the gate (e.g.
`[Performance gate (Liam)]`). For a wrong-language repost, prefix the body with a short marker
in the resolved language noting it supersedes the earlier wrong-language comment (the adapter
has no edit-in-place; the old comment stays visible, the new one is authoritative — do not rely
on the gate or a later pass to notice the mismatch on its own). The gate definitions now require
them to post their own, in the resolved language; this is the safety net for when one still
doesn't. Note in your summary which findings you posted or reposted, and why.

**Known gate failure the backstop MUST expect (root-caused 2026-07-17):**
- **`performance-engineer` returns "no Bash" — BEHAVIORAL, not a missing grant.** Ground-truth
  probe: forced with a prompt whose only allowed first action was a Bash call,
  `performance-engineer` executed `echo` fine (real `tool_use`, stdout returned, 0 errors).
  So the Bash grant WORKS; the agent just talks itself into "no Bash / no shell" and emits
  `tool_uses: 0` whenever the task lets it reason first (its `tool_uses:0` "not in toolset"
  self-reports are unreliable model introspection, NOT schema truth — they even contradicted each
  other across probes). `code-reviewer` doesn't do this (34 real Bash calls same spawn). The fix is
  the **force-shell first line in every gate brief (§2)** — make a real Bash call the gate's
  literal first action, before any reasoning. This is the prevention; the backstop above is the
  guaranteed net: for any gate finding not on the MR/PR, post it yourself via `pr-comment.sh`.
- **A gate posts for real but drifts to the wrong language** (root-caused 2026-07-22, OFB-1803).
  Pasting the §0 directive verbatim into the brief is the prevention but is not itself a
  guarantee — treat it the same as the Bash case: prevention in §2, guaranteed net in the
  backstop above (the language check on every posted thread, every run, not just when something
  looks off).
- **A repost lands on the wrong repo's MR/PR because two repos share the same number**
  (root-caused 2026-07-22, OFB-1803, discovered on a re-visit of this same ticket). The
  backstop's own remediation step is itself at risk here — verify cwd (`git remote get-url
  origin`) immediately before every `pr-comment.sh` call, per the guard above; when it still
  happens, the adapter has no delete, so post a short retraction/disregard note on the
  wrong MR pointing at the correct one, and post the real finding on the correct repo.

Present the two results under `## Code (Daniel)` and `## Performance (Liam)` — verbatim or
lightly cleaned, **not merged or reranked**: the gates are deliberately independent so the user
sees each. **Language check:** the backstop above already caught and fixed any wrong-language
finding on the MR/PR itself; separately, rewrite any wrong-language prose in what you present
here into the resolved OUTPUT LANGUAGE before presenting — never show the user a finding in the
wrong language even if the MR/PR copy has since been corrected.

**Re-visit presentation (§0.5).** Under each gate's header, list every prior must-fix by
status — **resolved** (say how the commit fixed it) or **still open** (say why it isn't) — then
any genuinely new must-fix, marked `(new, introduced by <SHA>)` so it reads as distinct from a
re-surfaced old finding. If a gate's return smuggles in a fresh, previously-unraised finding that
is NOT confined to the fix commit's touched lines, drop it from this pass (or note it separately
as out-of-scope) — a re-visit reports on the prior round, not a second fresh sweep.

End with **one combined verdict** line: requirements genuinely **met / partially met / not
met**, then the review level and the worst single issue per gate — on a re-visit, the worst
remaining item is either a still-open prior must-fix or a new one from the fix commit. The
combined verdict is **capped by any blocking finding at any gate** — a critical perf regression
caps the verdict at "partially met" even when the code-quality gate is clean.

### 3.5 PASS signal — orchestrator-owned, gated on ticket-wide MET (still never merge)

The combined verdict answers one **ticket-wide** question: are the ticket's requirements
*genuinely met* across **every** repo's MR/PR? Post the PASS signal **only** on a clean **met**
— zero unresolved must-fix at *every* gate on *every* repo, no open `Human:` directive, **and a
green test receipt from the code gate on every repo**. When
met, the orchestrator itself posts it on **each** repo's MR/PR: one host-level approval + one
loud verdict line, via

```
scripts/vcs/pr-approve.sh <num> --body "✅ APPROVED — <KEY>: requirements met, standards clean, 0 must-fix, tests green (<the code gate's invocation + result>)."
```

body in the resolved OUTPUT LANGUAGE, and name the green run in it — an approval that cannot
point at a suite result is the failure this gate exists to prevent.

**No test receipt ⇒ no approval, even with zero must-fixes.** A code gate that could not run
the suite (missing toolchain, a dependency stack that would not come up) has produced an
**unverified** verdict, not a met one: treat it exactly like an open must-fix — post no
approval on any MR/PR, do not advance the ticket (§3.6), and give the blocker its own line in
the §4 notify with the exact command that would settle it. "It reads correct and nobody
objected" is not a pass; a review that never ran the tests cannot say the MR/PR doesn't break
them. **Never run the suite yourself to paper over a gate that didn't** — re-spawn the code
gate (or hand the blocker to a human) so the receipt comes from the gate that owns the verdict.

Like notify (§4) this is **orchestrator-owned and
deterministic, never left to the gates** — a gate that lost its shell (perf "no Bash") can't
approve, so a gate-owned approval would silently drop; and the §2 brief tells each gate NOT to
approve on its own, so the one PASS signal is single-sourced here.

**Hold the approval until the WHOLE ticket is met — ticket-wide, never per-repo.** A
**partially met / not met** verdict (any must-fix anywhere — this run's OFB-2244 shape) posts
**no** approval on **any** MR/PR, not even on a repo that came back clean. The ticket is one
unit and its repos are usually ship-order-coupled (OFB-2244: the agent-db migration must land
before the agent-webservice INSERT, or site-creation breaks platform-wide) — approving the
clean repo alone reads as "this MR is ready to merge on its own", which the coupling makes
false. When not fully met the inline must-fix threads (posted/backstopped in §3) plus the
combined-verdict notify (§4) are the whole communication: the **absence** of an approval *is*
the "changes requested" signal.

**Approve is decoupled from merge (scope holds).** A PASS signal says "cleared the bar"; it is
**not** a merge. Ultra-review still never merges (even with `auto_merge` on) — `pr-approve.sh`
registers the host approval + verdict note only; whether/when it then merges stays a separate,
later human decision.

### 3.6 Advance the ticket to READY TO MERGE — only after EVERY MR/PR is approved (config-gated)

Runs **only** once §3.5 has actually posted the PASS approval on **every** repo's MR/PR — the
same ticket-wide MET bar (zero unresolved must-fix at every gate on every repo, no open `Human:`
directive). If the verdict is anything but a clean met, or if the `pr-approve.sh` call was
**refused/failed on any repo** (e.g. denied by a permission gate — the approval didn't actually
land), the precondition "all MRs approved" is **not** satisfied: do **NOT** advance the ticket.

**Config gate — never hardcode the status name.** Read `tracker.statuses.ready_to_merge` from
config (`workspace.config.local.yaml` if that personal override has it, else
`workspace.config.yaml`). If there is **no** `ready_to_merge` entry, this step is a **quiet
skip** — log `no ready_to_merge status configured — leaving the ticket where it is` and move on;
it is **not** an error (a board without that status simply doesn't move). Only when the key
exists do you transition, using its configured value **verbatim** as the status name:

```
scripts/tracker/upsert-ticket-details.sh <KEY> --status "<tracker.statuses.ready_to_merge>"
```

(the tracker adapter maps that abstract status name to the provider's own transition — Jira
transition / Notion property — so this stays provider-agnostic).

**Monotonic — only ever move forward.** If the ticket is already at the ready-to-merge status,
or already past it (e.g. Testing / Done), **skip** — never regress a ticket backward. A
transition the board rejects because there is no valid path from the current status is
**logged, not fatal** (the review verdict still stands; the status just didn't move).

**Still never merge.** Advancing to READY TO MERGE is a *status* signal that the ticket cleared
review — it is **not** a merge, exactly like the §3.5 approval. Merge stays the separate, later
human decision. Report the status move (old → new, or the skip reason) in the §4 notify.

### 4. Notify — orchestrator-owned, deterministic (ALWAYS runs when `notify.enabled`)

Do **NOT** leave notify to the gates. A gate that lost its shell (perf hallucinating "no Bash")
posts nothing — so gate-owned notify is non-deterministic and silently drops. After aggregating,
the **orchestrator itself** posts the **one combined verdict** as a threaded reply under the
ticket's review-request:

```
scripts/notify/send.sh --reply <KEY>   # threads under the "please review" msg; top-level fallback if none
```

Pipe the combined verdict on stdin, in the resolved OUTPUT LANGUAGE. This is per
`workspace.config.yaml` `notify.enabled` + channel and is **not optional — never ask first**.
This orchestrator post is the guaranteed one; gates MAY still thread their own per-gate verdict
per their definition, but the run's notify does not depend on them. Report the returned
`permalink`.

**Keep it SHORT — the MR is the report, this message is the pointer.** Every must-fix is
already an inline thread on the MR/PR (§3 guarantees it), so Slack must not carry a second
copy. Write it ultra-compressed (`/caveman:caveman`) and cap it at **~8 lines**:

- the combined verdict + review level, one line;
- per gate, one line: its verdict and its **must-fix COUNT** — plus the ONE worst item, named
  in a clause, only when the gate is not clean;
- the test result, one line: what the code gate ran and whether it was green (or, if it could
  not run, that the approval is held for exactly that reason);
- the MR/PR URL(s) — that link IS the finding list;
- on a clean met that advanced the ticket in §3.6, the status move (`CODE REVIEW → READY TO
  MERGE`); on anything less, one line saying no approval was posted and the ticket did not move;
- any unverified claim, one line each — brevity trims words, never bad news.

**Never** paste a finding's body, its code snippet, its fix, or a per-check pass table into
Slack — those belong on the MR thread and in what you present in-session (§3). The full §3
presentation is for the human reading THIS session; the notify is for the human reading Slack,
and they are not the same message. If this run is driven by the Slack dispatcher (its post-back
step targets the same thread), this notify already satisfies it — the dispatcher post-back then
shrinks to a one-line pointer rather than repeating any of it.
