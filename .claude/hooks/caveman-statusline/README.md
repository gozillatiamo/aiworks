# Caveman savings statusline

A Claude Code statusline that adds a **third line monitoring how many output
tokens the [caveman](https://github.com/JuliusBrussee/caveman) plugin has saved**
— lifetime tokens, estimated USD, and session count — so you can watch the
optimization pay off in real time.

```
[Opus 4.8  effort:high] my-project | main
████░░░░░░ 42% (84.0K/200.0K tokens)
⛏ [CAVEMAN] saved 137.1K tok (~$3.43) · 2 sess
```

The third line only renders while caveman is armed. When caveman is off, absent,
or has no logged savings yet, it either disappears or shows a hint to run
`/caveman-stats`.

> **Not auto-installed.** These files ship with the repo but are wired up by you,
> per the steps below — nothing is added to the shared `settings.json`.

## Files

| File | Role |
| --- | --- |
| `statusline.sh` | The statusline itself (3 lines; caveman block at the bottom). |
| `refresh-savings.sh` | Optional `Stop` hook that keeps the savings figures fresh every turn. |

## Requirements

- The **caveman** plugin installed (it writes the savings log this reads).
- `jq` — for the savings line (the first two lines render without it).
- `node` — only for the optional `refresh-savings.sh` auto-refresh hook.
- A POSIX shell (`bash`). Cross-platform: macOS and Linux.

## How the numbers are sourced

Caveman logs estimated savings to `$CLAUDE_CONFIG_DIR/.caveman-history.jsonl`
(usually `~/.claude/`). The statusline aggregates that log (latest snapshot per
session, summed). **The statusline cannot run `node`**, so the figures are only
as fresh as the last time the log was written — which happens when:

- you run `/caveman-stats` in a session, **or**
- the optional `refresh-savings.sh` `Stop` hook runs on turn end (see step 2).

Only caveman's `full` mode currently has benchmark data, so savings accrue in
that mode; other modes show the badge but no estimate.

## Install

### 1. Statusline (required)

**Option A — use this statusline as-is.** Point your user settings
(`~/.claude/settings.json`) at it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/caveman-statusline/statusline.sh\""
  }
}
```

(If you run Claude Code outside this repo, copy `statusline.sh` into
`~/.claude/` and point at the absolute path instead.)

**Option B — keep your own statusline.** Copy just the block marked
`── Caveman savings monitor ──` (and the `ORANGE`/`RESET` color vars and the
`format_tokens` helper it uses) into your existing statusline script.

### 2. Auto-refresh on turn end (optional but recommended)

Without this, the numbers update only when you run `/caveman-stats`. Add
`refresh-savings.sh` as a `Stop` hook in `~/.claude/settings.json` so they
refresh automatically (throttled to once per 60s):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/caveman-statusline/refresh-savings.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

If you already have `Stop` hooks, append this group to the existing `Stop`
array rather than replacing it.

> Hooks are loaded at session start — **restart Claude Code** (or start a new
> session) after editing `settings.json` for the `Stop` hook to take effect.
> The statusline change is live immediately (it re-runs on every render).

## Configuration

| Env var | Effect |
| --- | --- |
| `CAVEMAN_STATUSLINE_SAVINGS=0` | Hide the savings line without removing the script. |
| `CLAUDE_CONFIG_DIR` | Where caveman state is read from (defaults to `~/.claude`). |

## Notes

- **Honest numbers.** The figure is *output-token* reduction only — input and
  cache tokens (which dominate agentic sessions) are untouched by caveman. Don't
  read it as a share of your usage or limit. See the caveman project's
  `docs/HONEST-NUMBERS.md`.
- **Hardening.** Both scripts refuse symlinked state files and whitelist the
  caveman mode string before rendering, so a planted file can't inject terminal
  escapes. `refresh-savings.sh` always exits 0 and prints nothing.
