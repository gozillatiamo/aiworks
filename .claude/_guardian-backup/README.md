# Guardian-enabled backup — restore after CVP approval

Temporary state while the **Cyber Verification Program (CVP)** application is pending
(see `docs/cyber-verification-program-application.md`). The guardian-engineer gate is a
persistent false-positive of the real-time cyber-safeguard (measured n=10: ~70% block),
so it is **removed from the active review flow** until CVP is granted. This directory holds
the guardian-enabled versions to restore afterwards.

## Snapshots in this directory

| File | What it is |
|------|------------|
| `ultra-review.SKILL.md` | The **3-gate** ultra-review (code-reviewer + guardian-engineer + performance-engineer) with the terse guardian brief + neutral-agent backstop. |
| `dev-cycle.js` | The dev-cycle with the terse guardian gate prompt + `guardBackstop` (neutral-agent fallback). |
| `guardian-engineer.md` | The terse guardian agent definition (kept active; harmless when never spawned). |

## Active (temporary, guardian-OFF) state

- **ultra-review** — reverted to **2 gates** (code-reviewer + performance-engineer). Guardian
  is embedded in code here, so the active `SKILL.md` has it removed.
- **dev-cycle** — guardian is **config-gated**, not code-gated. It stays OFF because
  `workspace.config.yaml` → `quality_gate.provider: none` (the workflow skips the guardian gate
  entirely and never spawns it — no safeguard risk). The terse prompt + `guardBackstop` remain
  in `dev-cycle.js` but are dormant while the gate is off.

## Restore (once CVP is approved)

1. **ultra-review** — copy the 3-gate version back:
   ```bash
   cp .claude/_guardian-backup/ultra-review.SKILL.md .claude/skills/ultra-review/SKILL.md
   ```
2. **dev-cycle** — flip the config toggle (no code change needed; the guardian machinery is
   already in `dev-cycle.js`):
   ```yaml
   # workspace.config.yaml
   quality_gate:
     provider: sonarqube   # was: none
   ```
3. Restart the Claude Code session so the agent defs reload, then run one ticket end-to-end to
   confirm the guardian gate completes without a safeguard block.
4. Delete this backup directory once restore is verified.

_Backed up: 2026-07-17._
