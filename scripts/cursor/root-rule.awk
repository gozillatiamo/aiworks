# root-rule.awk — re-express one repo's rule (or project instruction) as a rule
# that works from the WORKSPACE ROOT under Cursor.
#
#   awk -v repo=<dir> -v origin=<label> [-v desc=<fallback>] -f root-rule.awk <file>
#
# A repo's own rule is scoped with a repo-relative glob — `src/**`. Read from the
# workspace root that glob matches every repo's src/, so twenty repos' rules would
# all fire on one repo's file. Measured: `src/**` is the identical glob in 20 of 20
# repos here. This prefixes each glob with the repo directory, so `src/**` becomes
# `<repo>/src/**` and the rule fires on that repo only.
#
# Cursor honours a path-prefixed glob on a root rule and ignores the rule for any
# other path — measured 2026-07-26 with seven probe rules over three cursor-agent
# runs, including negative controls (a glob naming a different repo stayed silent)
# and a reciprocal run. See docs/agents/cursor.md.
#
# A rule with NO glob is repo-wide on the Claude side (always eligible within that
# repo), so its root form is `<repo>/**` — the faithful equivalent, and the reason
# this cannot simply drop such rules.
#
# The body is copied rather than linked: the frontmatter has to change, so the root
# form is a different file by construction and no symlink can express it. `aiworks
# cursor --check` diffs every generated file against what it would write, so the
# copy cannot drift unnoticed.

function prefix_glob(g,   s) {
  s = g
  sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
  sub(/^["']/, "", s);   sub(/["']$/, "", s)
  sub(/^\.\//, "", s);   sub(/^\/+/, "", s)
  if (s == "") return ""
  return repo "/" s
}

function add_glob(g,   p) {
  p = prefix_glob(g)
  if (p != "") globs[++nglobs] = p
}

BEGIN { fm = 0; nglobs = 0; description = ""; ingl = 0; body = "" }

# Only the first two --- lines delimit frontmatter. A later one is a horizontal
# rule in the prose and must survive into the body untouched.
/^---[ \t]*$/ && fm < 2 { fm++; next }

fm == 1 {
  if ($0 ~ /^description:/) {
    description = $0
    sub(/^description:[ \t]*/, "", description)
    ingl = 0
    next
  }
  if ($0 ~ /^globs:[ \t]*$/) { ingl = 1; next }
  if ($0 ~ /^globs:[ \t]*[^ \t]/) {
    line = $0; sub(/^globs:[ \t]*/, "", line)
    n = split(line, parts, ",")
    for (i = 1; i <= n; i++) add_glob(parts[i])
    ingl = 0
    next
  }
  if (ingl && $0 ~ /^[ \t]+-[ \t]/) {
    line = $0; sub(/^[ \t]+-[ \t]*/, "", line)
    add_glob(line)
    next
  }
  # `paths:` is Claude's key for the same thing; it is already mirrored into
  # `globs:` by the generator, so anything else in the frontmatter is dropped.
  if ($0 !~ /^[ \t]/) ingl = 0
  next
}

fm >= 2 { body = body $0 "\n" }

END {
  if (description == "") description = desc
  if (nglobs == 0) globs[++nglobs] = repo "/**"

  print "---"
  if (description != "") print "description: " description
  print "globs:"
  for (i = 1; i <= nglobs; i++) printf "  - \"%s\"\n", globs[i]
  print "alwaysApply: false"
  print "---"
  print ""

  # Provenance, not decoration. Touch files in two repos and both repos'
  # coding_standards fire at once; without this line the agent cannot tell which
  # standard governs which file, and the two often disagree.
  print origin
  print ""

  sub(/^\n+/, "", body)
  sub(/\n+$/, "\n", body)
  printf "%s", body
}
