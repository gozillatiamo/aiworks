"""scripts/lib/gcloud_tunnel.py — shared gcloud IAP port-forward helper for the triage servers.

stdlib only: this module is imported by both pg_triage_mcp.py and (eventually)
redis_triage_mcp.py, which carry different uv dependency sets, so it cannot import
psycopg, redis, or any third-party package.

The contract:

  parse_spec(label, spec) -> TunnelSpec   # raises ValueError, naming `label`
  argv(spec) -> list[str]                 # pure; testable without spawning
  open_tunnel(spec, ready=None) -> Tunnel # refuses a busy port; waits for readiness
  close_tunnel(tun) -> None
  is_alive(tun) -> bool

  uv run scripts/lib/gcloud_tunnel.py --selftest
"""

from __future__ import annotations

import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class TunnelSpec:
    label: str       # "PGPROD_MAIN_TUNNEL" — every error message names itself
    kind: str        # "gcloud" | "none"
    host: str
    port: int        # remote port (default 5432)
    local_port: int  # 127.0.0.1:<local_port> on this machine
    vm: str          # gcloud compute instance name
    zone: str        # gcloud zone (optional — uses gcloud default when empty)
    project: str     # gcloud project (optional — uses gcloud default when empty)
    iap: bool        # True -> --tunnel-through-iap (default)


@dataclass
class Tunnel:
    spec: TunnelSpec
    proc: subprocess.Popen | None  # None for kind=none (direct/VPN/bastion)
    log_path: Path | None
    opened_at: float
    last_used: float


TUNNEL_READY_TIMEOUT_S = 45

_KNOWN_KEYS = frozenset({"tunnel", "host", "port", "local", "vm", "zone", "project", "iap"})


def parse_spec(label: str, spec: str) -> TunnelSpec:
    """Parse one semicolon-separated key=value spec string into a TunnelSpec.

    Raises ValueError naming `label` on any validation error so every broken
    line can identify itself rather than disappearing silently.
    """
    kv: dict[str, str] = {}
    for part in spec.split(";"):
        part = part.strip()
        if not part:
            continue
        k, _, v = part.partition("=")
        k = k.strip().lower()
        v = v.strip()
        if k not in _KNOWN_KEYS:
            raise ValueError(
                f"{label}: unknown key {k!r}; supported: {', '.join(sorted(_KNOWN_KEYS))}"
            )
        kv[k] = v

    kind = kv.get("tunnel", "gcloud").lower()
    if kind not in ("gcloud", "none"):
        raise ValueError(f"{label}: tunnel={kind!r}; use gcloud|none")

    host = kv.get("host", "")
    local_str = kv.get("local", "")

    if kind == "gcloud":
        if not host:
            raise ValueError(f"{label}: host= is required for tunnel=gcloud")
        if not local_str:
            raise ValueError(f"{label}: local= is required for tunnel=gcloud")
        if not kv.get("vm"):
            raise ValueError(f"{label}: vm= is required for tunnel=gcloud")

    if local_str:
        try:
            local_port = int(local_str)
        except ValueError:
            raise ValueError(f"{label}: local={local_str!r} is not a valid port number")
    else:
        local_port = 0

    port_str = kv.get("port", "5432")
    try:
        remote_port = int(port_str)
    except ValueError:
        raise ValueError(f"{label}: port={port_str!r} is not a valid port number")

    iap_str = kv.get("iap", "true").lower()
    iap = iap_str in ("true", "yes", "1")

    return TunnelSpec(
        label=label,
        kind=kind,
        host=host,
        port=remote_port,
        local_port=local_port,
        vm=kv.get("vm", ""),
        zone=kv.get("zone", ""),
        project=kv.get("project", ""),
        iap=iap,
    )


def argv(spec: TunnelSpec) -> list[str]:
    """Build the gcloud argv list for a TunnelSpec — pure, never spawns.

    Produces:
      gcloud compute ssh <vm> [--zone=<zone>] [--project=<p>] [--tunnel-through-iap]
         --quiet -- -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
         -L <local>:<host>:<port>

    Returns a list (never a shell string) so no element can reach the command line as a
    shell metacharacter.
    """
    cmd: list[str] = ["gcloud", "compute", "ssh", spec.vm]
    if spec.zone:
        cmd.append(f"--zone={spec.zone}")
    if spec.project:
        cmd.append(f"--project={spec.project}")
    if spec.iap:
        cmd.append("--tunnel-through-iap")
    cmd.append("--quiet")
    cmd += [
        "--",
        "-N",
        "-T",
        "-o",
        "ExitOnForwardFailure=yes",
        "-o",
        "ServerAliveInterval=30",
        "-L",
        f"{spec.local_port}:{spec.host}:{spec.port}",
    ]
    return cmd


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def open_tunnel(
    spec: TunnelSpec,
    ready: "callable[[], bool] | None" = None,
    timeout: float = TUNNEL_READY_TIMEOUT_S,
) -> Tunnel:
    """Spawn the port-forward and wait until it is ready.

    Raises RuntimeError:
    - BEFORE spawning, if the local port is already in use — names
      `scripts/db/tunnel.sh status|kill` so the human knows the remedy.
    - If the child exits before readiness (includes the log tail + IAP hints).
    - If readiness is not confirmed within `timeout` seconds.

    `ready` is an optional callable returning True when the forwarded service answers.
    When None, a plain TCP connect to 127.0.0.1:<local_port> is the probe. The parameter
    exists so redis_triage_mcp.py can keep its end-to-end PING probe when it migrates
    here — one optional parameter, no speculative machinery.
    """
    if spec.kind == "none":
        return Tunnel(
            spec=spec, proc=None, log_path=None,
            opened_at=time.time(), last_used=time.time(),
        )

    if _port_in_use(spec.local_port):
        raise RuntimeError(
            f"127.0.0.1:{spec.local_port} is already in use — refusing to adopt a tunnel "
            f"this process did not open (it may point somewhere else entirely). "
            f"Inspect with `scripts/db/tunnel.sh status` and clear with "
            f"`scripts/db/tunnel.sh kill`."
        )

    log_fd, log_path_str = tempfile.mkstemp(
        prefix=f"pg-tunnel-{spec.label.lower().replace('_', '-')}-", suffix=".log"
    )
    log_path = Path(log_path_str)

    cmd = argv(spec)
    with open(log_fd, "wb") as fh:
        proc = subprocess.Popen(cmd, stdout=fh, stderr=fh, stdin=subprocess.DEVNULL)

    tun = Tunnel(
        spec=spec, proc=proc, log_path=log_path,
        opened_at=time.time(), last_used=time.time(),
    )

    def _tcp_ready() -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1.0)
            return s.connect_ex(("127.0.0.1", spec.local_port)) == 0

    probe = ready or _tcp_ready
    deadline = time.time() + timeout

    while time.time() < deadline:
        if proc.poll() is not None:
            tail = log_path.read_text(errors="replace").strip().splitlines()[-6:]
            _cleanup_log(log_path)
            raise RuntimeError(
                f"gcloud tunnel for {spec.label} to {spec.vm!r} exited "
                f"(code {proc.returncode}). Last output:\n"
                + "\n".join(tail)
                + "\nCheck `gcloud auth list` and IAP/IAM access to the VM."
            )
        try:
            if probe():
                return tun
        except Exception:
            pass
        time.sleep(0.5)

    close_tunnel(tun)
    raise RuntimeError(
        f"tunnel for {spec.label} to {spec.vm!r} did not become ready within {timeout:.0f}s "
        f"(127.0.0.1:{spec.local_port})"
    )


def close_tunnel(tun: Tunnel) -> None:
    """Terminate the port-forward process and remove the log file."""
    if tun.proc is None:
        return
    if tun.proc.poll() is None:
        tun.proc.terminate()
        try:
            tun.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tun.proc.kill()
    _cleanup_log(tun.log_path)


def _cleanup_log(log_path: Path | None) -> None:
    try:
        if log_path is not None:
            log_path.unlink(missing_ok=True)
    except Exception:
        pass


def is_alive(tun: Tunnel) -> bool:
    """Whether the tunnel process is still running.

    Returns True for kind=none (direct connection — nothing to reap).
    """
    if tun.proc is None:
        return True
    return tun.proc.poll() is None


# --- selftest ----------------------------------------------------------------------------


def _selftest() -> int:
    failures = 0

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if not cond:
            failures += 1
        print(f"  {'ok  ' if cond else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")

    print("gcloud_tunnel selftest")

    # --- parse_spec: valid gcloud spec ---------------------------------------------------
    spec = parse_spec(
        "PGPROD_MAIN_TUNNEL",
        "tunnel=gcloud;host=prod-db.internal;port=5432;local=15432;vm=bastion;zone=asia-southeast1-a",
    )
    check("valid spec parses", spec.kind == "gcloud" and spec.host == "prod-db.internal")
    check("port defaults correctly", spec.port == 5432)
    check("local_port set", spec.local_port == 15432)
    check("vm set", spec.vm == "bastion")
    check("zone set", spec.zone == "asia-southeast1-a")
    check("iap defaults to True", spec.iap is True)
    check("project defaults to empty string", spec.project == "")
    check("label preserved", spec.label == "PGPROD_MAIN_TUNNEL")

    # --- parse_spec: iap=false -----------------------------------------------------------
    spec2 = parse_spec("LBL", "tunnel=gcloud;host=h;local=15433;vm=v;iap=false")
    check("iap=false parsed", spec2.iap is False)

    # --- parse_spec: project optional ----------------------------------------------------
    spec3 = parse_spec("LBL", "tunnel=gcloud;host=h;local=15434;vm=v;project=my-project")
    check("project optional", spec3.project == "my-project")

    # --- parse_spec: tunnel=none ---------------------------------------------------------
    spec_none = parse_spec("LBL", "tunnel=none;host=bastion;local=15435")
    check("tunnel=none parsed", spec_none.kind == "none")

    # --- parse_spec: validation errors ---------------------------------------------------
    def expect_err(label: str, spec_str: str, fragment: str) -> None:
        try:
            parse_spec(label, spec_str)
            check(f"should reject: {spec_str[:40]}", False, "no error raised")
        except ValueError as exc:
            check(f"rejects: {spec_str[:40]}", fragment in str(exc), str(exc))

    expect_err("LBL", "tunnel=gcloud;local=15436;vm=v", "host=")         # missing host
    expect_err("LBL", "tunnel=gcloud;host=h;vm=v", "local=")             # missing local
    expect_err("LBL", "tunnel=gcloud;host=h;local=15437", "vm=")         # missing vm
    expect_err("LBL", "tunnel=gcloud;host=h;local=notaport;vm=v", "not a valid port")
    expect_err("LBL", "tunnel=gcloud;host=h;local=15438;vm=v;badkey=x", "unknown key")
    expect_err("LBL", "tunnel=badkind;host=h;local=15439;vm=v", "gcloud|none")

    # --- argv: shape assertions ----------------------------------------------------------
    spec_iap = parse_spec("LBL", "tunnel=gcloud;host=db.internal;local=15440;vm=my-vm;zone=us-east1-b;iap=true")
    args_iap = argv(spec_iap)
    check("argv is a list", isinstance(args_iap, list))
    check("no shell string in argv", all(isinstance(a, str) for a in args_iap))
    check("-- separator present", "--" in args_iap)
    check("-N present", "-N" in args_iap)
    check("-L present", "-L" in args_iap)
    check("--tunnel-through-iap present when iap=true", "--tunnel-through-iap" in args_iap)
    check("-L value correct", f"15440:db.internal:5432" in args_iap)

    spec_no_iap = parse_spec("LBL", "tunnel=gcloud;host=db;local=15441;vm=vm;iap=false")
    args_no_iap = argv(spec_no_iap)
    check("--tunnel-through-iap absent when iap=false", "--tunnel-through-iap" not in args_no_iap)

    spec_zone_empty = parse_spec("LBL", "tunnel=gcloud;host=db;local=15442;vm=vm2")
    args_zone_empty = argv(spec_zone_empty)
    check("--zone absent when zone not set", not any(a.startswith("--zone=") for a in args_zone_empty))

    spec_with_project = parse_spec("LBL", "tunnel=gcloud;host=db;local=15443;vm=vm3;project=p123")
    args_proj = argv(spec_with_project)
    check("--project present when set", "--project=p123" in args_proj)

    # --- port-in-use refusal (bind a real socket, no gcloud needed) ----------------------
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        busy_port = srv.getsockname()[1]
        spec_busy = parse_spec(
            "PGPROD_TEST_TUNNEL",
            f"tunnel=gcloud;host=h;local={busy_port};vm=v",
        )
        try:
            open_tunnel(spec_busy, timeout=0.1)
            check("port-in-use is refused", False, "no error raised")
        except RuntimeError as exc:
            msg = str(exc)
            check("port-in-use is refused", "already in use" in msg, msg[:120])
            check("port-in-use names tunnel.sh", "scripts/db/tunnel.sh" in msg, msg[:120])

    print("selftest ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(__doc__)
    raise SystemExit(0)
