# Workspace bring-up never bootstraps deployed-environment access

**Status:** Accepted

`aiworks sync` is the repo onboarding sweep: clone what is declared, link the adapters, wire the
agent config. It had also grown two deployed-environment steps — it registered the three read-only
triage MCP servers (`docs/adr/0005`, `docs/adr/0007`), and it probed every GKE context in the
kubeconfig to score the read-only Kubernetes identity. Both are now gone. Sync **reports** the
state, `aiworks doctor` **diagnoses** it, and a human **bootstraps** it.

## Why bring-up is the wrong place for either

Three separate reasons, and each one is enough on its own.

**It wrote something nobody asked for.** `seed_triage_mcps` ran `scripts/triage-mcp.sh sync`, which
mutates `~/.claude.json`. A teammate who runs `aiworks sync` to pick up a newly declared repo has
consented to cloning repos, not to having three MCP servers appear in their client. Registration is
cheap to reverse, but the surprise is the point: a sweep that onboards repos should not be the thing
that decides what talks to production.

**It was slow, on the command run most often.** `check_k8s_triage` called `scripts/k8s/setup.sh
--quiet`, which is a `gcloud iam service-accounts describe`, a `gcloud auth print-access-token
--impersonate-service-account`, and two `kubectl auth can-i` round-trips **per GKE context**. On a
laptop with four clusters in the kubeconfig that is a multi-second tax on every sync, paid by
everybody, including the majority who never open a cluster.

**It could not fix what it found.** This is the decisive one. The gap `setup.sh` reports is almost
always "the triage identity does not exist in this project" or "you may not impersonate it", and the
command that closes it — `scripts/k8s/bootstrap-sa.sh --context <ctx>` — requires ownership of the
GCP project. Sync cannot have that, must not have that, and so the probe could only ever restate a
sentence a human still had to act on. Paying a network round-trip to reprint a static instruction is
the whole cost with none of the benefit.

## What sync prints instead, and why the two halves differ

Sync gained a `Triage:` stanza in its summary, printed in all three summary branches (the 0-repo
case, `--dry-run`, and a normal run) so it cannot be missed by whichever way the command was
invoked. The two lines are deliberately **asymmetric**:

- **The MCP line is conditional.** `scripts/triage-mcp.sh status` reads a local JSON file with `jq`.
  It is free, it makes no network call, and it is honest under `--dry-run`, so the line appears only
  when something is actually unregistered — and says the exact command that registers it.
- **The Kubernetes line is static.** It always prints, and it probes nothing. Any conditional
  version of this line would cost precisely the probe that was just removed, which would put the
  cost back to buy a slightly better-worded sentence. So the line states the shape of the thing
  instead: the identity is bootstrapped by hand, per cluster, `setup.sh` reports the gaps, a project
  owner runs `bootstrap-sa.sh`, and `aiworks doctor --deep` scores it.

The stanza never writes, never touches the network, and never affects the exit code — it is printed
before the exit-status line that sync already owned.

## Doctor takes over the scoring, split across its two tiers

`aiworks doctor` gained a `triage` group, and it keeps the workspace's doctor contract
(`docs/agents/doctor.md`): report the finding, name the command that owns it, never carry the repair
logic itself. The group is split by cost, using the same intra-group `--deep` fencing that
`agent-cfg` and `tooling` already use:

- **The MCPs are an offline check.** Same `jq` read sync does. A missing registration is a `fail`
  whose owner command is `scripts/triage-mcp.sh sync` — genuinely auto-fixable, so `doctor --fix`
  runs it. A pre-`0005` leftover registration and a hand-edited command line are both `warn`s,
  because neither is broken and the second is somebody's deliberate override.
- **The Kubernetes identity is `--deep` only.** Its fix is advisory: prefixed `see:`, which is the
  doctor's existing escape hatch for a finding whose owner is a person, not a command. `doctor
  --fix` therefore can never run `bootstrap-sa.sh` — a script that grants IAM on a GCP project must
  stay something a human types, having read what it does.

`triage.enabled: false` silences the whole thing: the doctor group skips, and the sync stanza does
not print at all. Registration is what that key has always governed (`0005`), so a workspace that
opted out of triage sees no reminders about it anywhere.

## The consequence, stated rather than discovered

After a fresh clone the triage MCPs are **not** registered until somebody runs
`scripts/triage-mcp.sh sync`. That is the deliberate trade: one explicit command, once, in exchange
for a bring-up that neither writes client config nor talks to Google. It is not a silent gap — the
sync summary names it with the command attached, `aiworks doctor` fails on it in its offline tier,
and `doctor --fix` repairs it. The first of those three that anyone runs hands them the same
one-line answer.

## A bug this surfaced

Moving the scoring into doctor exposed a defect in `scripts/triage-mcp.sh` that had been there since
the file's first commit: its `LEGACY[]` table — the list of pre-`0005` server names to deregister —
had itself been swept by the very rename it exists to clean up, and so named the *current* three
servers. `status` reported every healthy registration as a leftover, and `sync` deregistered and
re-registered all three on every run. It went unnoticed for as long as nothing read that output;
the moment a doctor group did, it would have inherited the false warning. The table now holds the
real pre-`0005` names, and the comment above it says why it must never be renamed again.
