# scripts/stagehand

Puts what the assistant just touched on screen — an edited file in the editor, a fetched URL in a
browser tab — placed in whatever screen space is free, without taking the keyboard.

Design, rationale and the two coordinate traps: **`docs/agents/stagehand.md`**. Every config key:
`workspace.config.example.yaml`. Off by default; root worktree only.

## Run it by hand

```bash
# what WOULD happen, touching nothing
scripts/stagehand/show.sh --dry-run --payload <hook-payload.json>

# for real, with the placement decision printed to stderr
STAGE_VERBOSE=1 scripts/stagehand/show.sh --tool Edit --file "$PWD/some/file.rs" -v
STAGE_VERBOSE=1 scripts/stagehand/show.sh --url https://bluepi.atlassian.net/browse/OFB-1 -v

# the follow path — what a REPLY would put on screen
scripts/stagehand/follow.sh --dry-run --text 'ofb-k6-loadtests!14 and OFB-2179'
scripts/stagehand/follow.sh --dry-run --text 'SHOW: agent-db!555 ~signature_key'   # focus phrase
scripts/stagehand/show.sh --ident 'https://gitlab.com/a/b/-/merge_requests/14/diffs'  # tab identity
scripts/stagehand/follow.sh --dry-run --transcript ~/.claude/projects/<slug>/<session>.jsonl

# the placer alone
osascript -l JavaScript scripts/stagehand/place.js --displays          # geometry + builtin flags
osascript -l JavaScript scripts/stagehand/place.js --plan --protect iTerm2 --taken '0:left-half'
osascript -l JavaScript scripts/stagehand/place.js --plan --protect iTerm2 --prefer '2:top-half'
osascript -l JavaScript scripts/stagehand/place.js Cursor --match file.rs --dry-run --protect iTerm2
```

## Test

```bash
scripts/stagehand/selftest.sh          # 56 assertions, no window moves
scripts/stagehand/selftest.sh --live   # 60 — also parks a real window, places it, restores it
```

The gate group creates a **real** linked `git worktree` and asserts silence in it — the
root-worktree-only rule is the whole scope of the feature, so it is not tested against a mocked
environment variable.

## Turning it off

```bash
STAGEHAND=off <command>                       # one command
# workspace.config.local.yaml → stagehand.enabled: false     (this machine)
# workspace.config.local.yaml → stagehand.placement: off     (open things, move nothing)
```

## Adding a trigger

Routing lives in one `case` in `show.sh`. A new tool that should show something needs a branch that
sets `file=` or `url=`; everything downstream (debounce, opening, placement, focus restore) is
shared. If it sets `url=` from a tool **response**, the host must be in `stagehand.url_hosts` — that
list is a security boundary, not tidiness. See the header comment in `show.sh`.
