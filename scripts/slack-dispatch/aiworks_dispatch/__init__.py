"""aiworks_dispatch — Slack @-mention -> Superset on-demand Claude dispatcher.

A long-running Socket Mode service that turns a Slack `@bot <request>` into a
fresh Superset git worktree on this machine with a Claude agent launched inside
it. The agent posts its result back to the originating Slack thread itself, via
the workspace notify adapter (scripts/notify/send.sh) — this service only mints
a correlation id, dispatches, and acknowledges receipt.

See README.md for the full architecture and setup.
"""

__version__ = "0.1.0"
