# agent.awk — project one canonical subagent (.claude/agents/<n>.md) onto Cursor.
#
#   awk -v src=<repo-relative source path> -f agent.awk <file>
#
# The two formats are byte-identical except for ONE key. `model:` carries Claude
# Code's tier vocabulary (opus / sonnet / haiku / fable). Cursor does not ignore
# those — measured 2026-10 on cursor-agent 2026.09.26: `opus` and `sonnet` are
# Cursor aliases for quota-gated Claude models and failed with
# `ActionRequiredError: You've hit your usage limit`, while `haiku` and `fable`
# are refused as unknown ids. So the projection rewrites that key to
# `model: inherit` — the subagent follows the session model, which this
# workspace keeps on `auto` (docs/adr/0040). Everything else is copied verbatim,
# including `effort:`, `tools:`, `skills:` and the whole body.
#
# Only the FIRST frontmatter block is touched. A `model:` in the prose, or a
# later `---` horizontal rule, must survive untouched.
#
# Line 2 is an ownership marker (a YAML comment): `aiworks cursor` refuses to
# overwrite or delete any .cursor/agents/*.md that lacks it, so a hand-written
# Cursor agent is never clobbered, and `--remove` deletes only what it wrote.

BEGIN { fm = 0 }

/^---[ \t]*$/ && fm < 2 {
  fm++
  print
  if (fm == 1) print "# aiworks-cursor: generated from " src " — edit that file, then run aiworks cursor"
  next
}

fm == 1 && /^model:[ \t]/ { print "model: inherit"; next }

{ print }
