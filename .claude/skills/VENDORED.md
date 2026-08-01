# Vendored plugin skills — where they came from

Two skill directories under `.claude/skills/` are **not written here**. They are byte-for-byte
copies of third-party plugin skills, committed on purpose and kept in sync by
`aiworks cursor` (`VENDOR_ROOT` in `scripts/aiworks-cursor.sh`; `--check` reports a copy that has
fallen behind the installed plugin).

| directory | upstream | licence | why it is vendored rather than linked |
|---|---|---|---|
| `caveman/` | https://github.com/JuliusBrussee/caveman | MIT © 2026 Julius Brussee | every agent definition here preloads it as the output-compression baseline |
| `debugging-code/` | https://github.com/AlmogBaku/debug-skill | MIT © 2025 Almog Baku | referenced by the developer / triage agent definitions |

## Why a copy at all

The plugin install lives in `~/.claude/plugins/…` — an absolute, per-machine path. Linking it
gives every teammate who clones this repo a **dangling** skill directory, and the agent
definitions that preload the skill then reference something that is not there. Only the skills
this workspace's own configuration *depends on* are vendored; the rest stay symlinked and
git-ignored (personal convenience, regenerated per machine).

The second reason is **Cursor**: it cannot resolve the `plugin:skill` form at all, so
`caveman:caveman` is unavailable there. A real directory at `.claude/skills/caveman` is invocable
as `/caveman`, which is the name every agent file also carries.

## Keeping the copies honest

`aiworks cursor` compares **per file** (`cmp`), not "directory exists → skip" — the test that once
left repos holding a stale hook snapshot for months. A `claude plugin update` therefore shows up as
drift instead of diverging silently. Two consequences worth knowing:

- a machine **without** the plugin installed keeps the committed copy and reports nothing — the
  copy is the source of truth for exactly that case;
- the sync **removes** files in the vendored directory that the plugin does not have, which is why
  this note lives here rather than as a `LICENCE` inside each skill directory. Each project's own
  licence text is in its upstream repo, linked above.

`.prettierignore` excludes these directories where a repo formats Markdown: reflowing a vendored
file makes every later run report drift that no re-sync can win.
