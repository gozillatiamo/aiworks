# Thai register is address mode, and the speaker decides the pronoun

**Status:** Accepted

Under `language: th` the agents produced Thai that was grammatically correct and read like a
translation — distant, stiff, and faintly accusatory when it carried bad news to an outside party.
Three separate complaints from a native reviewer (overuse of `คุณ`, `เรา` as first person, a blaming
tone) turned out to be **one** defect with one cause, so this workspace fixes the cause rather than
the three symptoms.

The cause is **mode**. Thai splits between *exposition* — documentation, specs, blog posts, written to
nobody in particular — and *address*, written to a person. The two select different grammar:
exposition takes `เรา`, `การ`+verb nominalization, formal connectives (`ดังนั้น`, `เนื่องจาก`) and a
stated conclusion; address takes `ผม`-or-nothing, bare verbs, `เลย`/`แต่`/`เพราะ`, a per-clause
`ครับ`/`ค่ะ`, and a question-shaped ending. A model has read far more Thai exposition than Thai
conversation, so it defaults to exposition and aims it at a person. That single mismatch produces
every symptom at once — which is why patching the symptoms individually never converged.

**The decision: a message addressed to a person is written in address mode**, and the full convention
lives in [`docs/agents/register.md`](../agents/register.md). Two consequences are load-bearing enough
to record here rather than only there.

**First — the pronoun is keyed on the speaker, not on the workspace.** `ผม`/`ครับ` and `ดิฉัน`/`ค่ะ`
are speaker-gender-marked and Thai has no established gender-neutral polite particle; dropping
particles entirely is grammatical and reads cold, which is the defect being fixed. So there are three
voices and they are deliberately not reconciled: the assistant speaking as itself uses its persona's
own particle and no first-person pronoun; a draft a human pastes under their own name uses
`outbound_first_person`/`outbound_particle` (default `ผม`/`ครับ`, overridable per person in
`workspace.config.local.yaml`); the company's position is `ทางเรา`/`ฝั่งเรา`, which is ungendered.
Anyone who notices the assistant saying `ค่ะ` beside an outbound draft saying `ครับ` and moves to
"fix the inconsistency" should stop — those are two different speakers, and collapsing them either
gives the assistant a person's voice it does not have or signs a user's message in someone else's.

**Second — ordering is per audience, and it overrides the compression rule for one surface.** Thai
business requests build shared context first and state the ask last; the direct, ask-first shape is
measurably the non-Thai pattern. That contradicts this workspace's verdict-first house style, and both
are correct for their own reader. Internal surfaces — a case report, a ticket, a reply to the operator
— keep verdict-first, because someone triaging needs the answer in line one. **An outbound message to
a partner team inverts to context-first**, because a stranger being asked to go dig through their own
logs needs to know why before being asked, and forty words of shared ground buys a straight answer in
one round-trip instead of three. This is the only place the workspace's compression doctrine is
deliberately overruled, and it is scoped to outbound messages alone.

The register never softens content. It governs how a thing is asked and framed, never a number, a
verdict or a warning — hedging "do not pay this, it already settled" is how a customer gets paid
twice.

Enforcement rides the existing language resolver (`.claude/hooks/resolve-language.sh`) rather than
adding a mechanism: the rule only exists when the resolved language is Thai, and that script already
knows exactly that, on `SessionStart` and on every `UserPromptSubmit`.

## Rejected alternatives

- **A checklist of rules — ban `คุณ`, prefer `ผม`, avoid blaming words.** Rejected: it treats three
  symptoms of one defect as three defects, so it cannot generalize to the cases it does not enumerate,
  and a list of twenty rules is skimmed while one rule is remembered. It was also, in effect, what the
  prose reminders were already doing.
- **A gender-neutral Thai register for every speaker.** Rejected: no such register exists in natural
  professional Thai. Every genuinely neutral construction drops the politeness particle, which is
  precisely the coldness this ADR exists to remove. Naming three speakers is honest about a real
  property of the language; pretending to neutrality would trade a visible inconsistency for an
  invisible rudeness.
- **A dedicated register plugin/hook, the way caveman and ponytail are packaged.** Rejected: those are
  always-on and independent of any other setting, so they need their own trigger. Register has no
  independent trigger — it is meaningful only when the language is already Thai, which one existing
  hook already resolves. A second mechanism would be a second thing to keep in sync for no coverage.
- **A `## Refinement` on [ADR-0002](0002-workspace-output-localization.md) instead of a new ADR.**
  Rejected: 0002 scopes itself explicitly to "a *language* decision only". Which language (0002), for
  whose reader ([ADR-0012](0012-case-reports-are-localized-for-their-reader.md)) and in which register
  are three orthogonal axes, and this repo spins a new ADR on a new axis.
- **Verdict-first everywhere, for consistency with the compression rule.** Rejected: the compression
  rule optimizes the reader's time inside this workspace, and a partner team's engineer is not that
  reader. Consistency is not worth two extra round-trips per escalation.
