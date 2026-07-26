#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — a chat notification must not hand the reader something
# only the agent's own machine can open.
#
# The notify adapter posts to Slack, where the audience has no access to this
# worktree. Two failures keep recurring:
#
#   1. A local path as the deliverable. On APP-1944 the post-back cited
#      `agent_logs/APP-1944-plan.html` — 121 KB sitting in an ephemeral worktree
#      on one laptop, gitignored, and on top of that the file was a *rendered
#      doc* whose whole point was being shareable. To the reader it is a dead
#      link. Same for any absolute /Users/... path.
#
#   2. An .html deliverable with no URL. When `artifacts.enabled` is on, an
#      interactive doc is meant to be published to a shareable Artifact and the
#      summary is supposed to carry that URL (see the write-interactive-docs
#      skill). Mentioning the .html without a URL means the publish step was
#      skipped and nobody can tell.
#
# Only the MESSAGE text is inspected — flag values (--file/--channel/--thread-ts)
# are stripped first, so attaching `.aiworks/out/report.pdf` with `--file` stays
# perfectly fine. Attaching a file IS the correct way to deliver one.
#
# Exit 0 = allow. Exit 2 = block, stderr goes back to the model as feedback.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Only guard the notify adapter.
case "$cmd" in *scripts/notify/send.sh*) ;; *) exit 0 ;; esac

# Drop the flags and their values; what remains is (mostly) the message text.
msg=$(printf '%s' "$cmd" \
  | sed -E 's#[^ ]*scripts/notify/send\.sh##' \
  | sed -E 's/--(file|channel|thread-ts|thread_ts|repo|ticket|title)[= ]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^ ]+)//g')

fail() {
  {
    echo "⛔ Blocked: Slack message hands the reader something they cannot open."
    echo
    echo "$1"
    echo
    echo "Deliver it in a form the reader actually has:"
    echo "  • a FILE     — attach it:  send.sh --file .aiworks/out/<name>.<ext> \"<caption>\""
    echo "  • a DOC/page — publish it as an Artifact and paste the https:// URL"
    echo "  • a DIFF     — paste the PR/MR URL from scripts/vcs/"
    echo "  • short text — inline it in the message itself"
  } >&2
  exit 2
}

# 1. An absolute path on this machine.
printf '%s' "$msg" | grep -qE '/Users/[A-Za-z0-9._-]+/' \
  && fail "It cites an absolute path on THIS machine — the reader has no such file."

# 2. A gitignored local artifact directory.
printf '%s' "$msg" | grep -qE '(^|[^A-Za-z0-9_/-])agent_logs/' \
  && fail "It cites agent_logs/ — a git-ignored local dir that exists only here."

# 3. An .html deliverable with no URL to open it at.
if printf '%s' "$msg" | grep -qE '\.html([^A-Za-z0-9]|$)'; then
  printf '%s' "$msg" | grep -qE 'https?://' \
    || fail "It mentions an .html doc but carries no https:// URL. If artifacts are
enabled, publish the page as an Artifact and include its URL; otherwise render
it to PDF and attach that with --file."
fi

exit 0
