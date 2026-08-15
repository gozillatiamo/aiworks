# Obsidian — shared vault settings for the workspace meta-repo

The workspace meta-repo is a valid [Obsidian](https://obsidian.md) vault (handy for reading
`docs/`, ADRs, and agent notes). Teammates should inherit the **same vault abilities** — core
plugins, appearance, app settings — without inheriting each other's open tabs.

## What `aiworks sync` does

On every sync it:

1. **Seeds** `.obsidian/{app,appearance,core-plugins}.json` when missing (never overwrites).
2. **Keeps** a managed `.gitignore` block that ignores personal UI layout:
   - `.obsidian/workspace.json`
   - `.obsidian/workspace-mobile.json`
   - `.obsidian/graph.json`

The block is marked:

```
# >>> aiworks sync: obsidian (generated — do not edit by hand)
…
# <<< aiworks sync: obsidian
```

Hand-edits inside that block are overwritten on the next sync — change the seeds in
`scripts/aiworks-sync.sh` (`ensure_obsidian_vault`) instead.

## Commit vs keep local

| Path | Commit? | Why |
|---|---|---|
| `.obsidian/app.json` | yes | shared vault behaviour |
| `.obsidian/appearance.json` | yes | shared look |
| `.obsidian/core-plugins.json` | yes | shared core-plugin set |
| `.obsidian/community-plugins.json` + `.obsidian/plugins/` | yes, when the team agrees | shared community plugins |
| `.obsidian/hotkeys.json` | optional | shared shortcuts |
| `.obsidian/workspace.json` | **no** | per-person open tabs / panes |
| `.obsidian/workspace-mobile.json` | **no** | same, mobile |
| `.obsidian/graph.json` | **no** | local graph-view layout |

## Gotchas

- **Obsidian Sync ≠ git.** A Sync subscription is per-account; git-shared config does not share
  Sync. Prefer git for team vault settings.
- **Do not commit plugin configs that hold API keys** (or Sync account data).
- Opening the folder as a vault creates `workspace.json` locally — that is expected and ignored.
- Product-repo clones are unrelated: this contract applies only to the **workspace meta-repo**.
