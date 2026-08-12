# A case report is localized for its reader, not for the session

**Status:** Accepted. Amends [ADR-0002](0002-workspace-output-localization.md), which established
`language` as the single output-language axis.

ADR-0002 gave the workspace one language knob and made it authoritative: every surface an agent
writes follows `language`, and `.claude/hooks/resolve-language.sh` re-asserts it on every turn
precisely because a prose reminder was missed twice in practice. That is still right for every
surface it was written for — chat, tickets, PR/MR discussion, Slack, the `.html` render. All of them
are read by the people who set the config.

One artifact is not. A **deployed-environment case report** — the verdict, evidence and runbook of a
live-environment investigation — is produced for whoever *reported* the case: a support agent on
shift, an operator, someone answering a customer in a chat window. That person did not set
`language`, is not in the session, and frequently does not read the language the session runs in.
With one axis, the workspace had to choose between an operator who cannot read the answer and a team
that has to work in a language it did not pick. Both are wrong, and the workaround — the person
running the session translating the report by hand on the way out — puts a human in the middle of
the one artifact where a mistranslated number is most expensive.

## Decision

A second, optional key: **`case_report_language`**, resolved with the same precedence as `language`
(personal `workspace.config.local.yaml` > committed `workspace.config.yaml`), defaulting to
`language` when unset. It governs exactly two things: the case report **as relayed in chat**, and the
chat/Slack message that hands the case over.

**It is keyed on the artifact, not on the agent.** The same report must not arrive in a different
language depending on whether an `oncall` agent was spawned or the question was answered inline —
that is an implementation detail the reader cannot see, and making language depend on it would be
arbitrary from the only seat that matters.

Three boundaries hold regardless of its value, and each is load-bearing rather than tidy:

- **The English spine still applies** — identifiers, amounts, `table.column` names, headings, code,
  Arabic numerals. A refId or a micro-unit figure that shifts in translation is the failure this
  whole class of report exists to prevent.
- **The `.md` case file stays English**, under ADR-0002's file-type invariant. Only the relayed
  report is localized. The stable artifact a future agent reads does not fork by audience.
- **Tickets stay in `language`.** A Jira ticket is read by developers and outlives the case.

Two readers resolve the key, and both had to be wired or the decision would only half-hold:
`resolve-language.sh` appends the exception to the policy it injects every turn (which covers the
main session, since the main session is what actually prints the report to the operator), and the
`oncall` agent resolves it in its own first step (since an on-demand agent sits outside any workflow
and nothing injects a directive into it).

## Considered options

- **Flip `language` to the reporter's language (rejected).** Localizes everything, including the
  surfaces the team works in all day, to serve one artifact. It answers a narrow need with the
  widest possible instrument.
- **Hardcode the language in `.claude/agents/oncall.md` (rejected).** Cheapest and quite robust for
  the agent's own output, and it fails two ways: it does nothing for the main session's relay, which
  is what the operator actually reads, and it bakes one organization's language into a file
  contributed upstream de-branded, so the next organization inherits a setting that is wrong for
  them and invisible until someone notices.
- **Pass a `LANGUAGE_DIRECTIVE` by hand in each oncall brief (rejected).** Zero code, and the agent
  already honours such a line verbatim. It is also exactly the mechanism that measurably does not
  hold: a prose-level language directive scored 0/5 in practice where the injected one scored 5/5,
  which is the finding that produced this hook in the first place. A convention that depends on the
  orchestrator remembering is not a convention.
- **A `language:` key in the agent's own frontmatter (rejected).** Reads naturally and would be dead
  config — nothing in the harness consumes an unknown frontmatter key, so it would silently do
  nothing while looking like configuration, the same trap as `effort:` on a Haiku-model agent.
- **A new key resolved by the existing hook (chosen).** One source of truth, both readers agree, the
  exception is mechanical rather than remembered, and the key is generic — an organization that wants
  no exception simply omits it.

## Consequences

- **The per-turn injected policy grows a clause** whenever the two keys differ. That is deliberate:
  the injected directive and a localized report would otherwise contradict each other on every turn,
  and the directive would win — the precise drift ADR-0002's hook exists to prevent.
- **`.claude/.resolved-case-report-language`** is written beside `.resolved-language`, so
  non-interactive tooling can read the same resolution without re-deriving it from a personal,
  git-ignored file that a worktree may not even reach.
- **The config parser is now shared** between the two keys instead of duplicated. A second copy is
  how two resolutions drift apart, which is a failure this workspace has already paid for once in
  its observability adapter.
- **Two languages can appear in one turn** — a Thai report followed by English commentary in an
  English session. That reads slightly oddly and is the honest representation of what is happening:
  one part is a hand-off to somebody else, the rest is a conversation with you.
- **A report and its own case file now differ in language.** Anyone comparing them must expect that;
  the identifiers and figures are identical by the spine rule, so the comparison stays mechanical.
- **This does not widen to the deployed-case family.** `case-report`, `root-cause-deployed` and
  ad-hoc triage answers keep following `language`. Widening it is a later decision, taken when there
  is a second artifact with a genuinely external reader — not inferred from this one.
