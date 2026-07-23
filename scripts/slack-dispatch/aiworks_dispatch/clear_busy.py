"""Clear a thread's busy flag — invoked by the Stop-hook when a dispatched agent
session ends, so the next mention in that thread isn't rejected as "still working".

    python -m aiworks_dispatch.clear_busy --url <redis_url> --key <thread_key>

Best-effort: the busy flag also carries a TTL safety cap, so a failure here just
means the thread frees up a little later.
"""

from __future__ import annotations

import argparse
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--key", required=True)  # the thread key, e.g. thread:C123:169...
    args = ap.parse_args()
    try:
        import redis  # noqa: PLC0415

        redis.Redis.from_url(args.url, decode_responses=True).delete(f"{args.key}:busy")
    except Exception as e:  # noqa: BLE001
        print(f"clear_busy failed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
