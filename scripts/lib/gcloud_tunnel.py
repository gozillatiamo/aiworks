"""scripts/lib/gcloud_tunnel.py — shared tunnel helper for the triage servers.

Covers three tunnel kinds: `gcloud` (one IAP SSH port-forward per target), `gost` (ONE shared
SOCKS5 forwarder process — `gost -C $PG_TRIAGE_GOST_CONFIG` — serving every gost target at once,
refcounted by holder) and `none` (direct).

stdlib only: this module is imported by both pg_triage_mcp.py and (eventually)
redis_triage_mcp.py, which carry different uv dependency sets, so it cannot import
psycopg, redis, or any third-party package.

The contract:

  parse_spec(label, spec) -> TunnelSpec   # raises ValueError, naming `label`
  argv(spec, log_path=None) -> list[str]  # pure; testable without spawning; `-E <log>` signs it
  open_tunnel(spec, ready=None) -> Tunnel # refuses a busy port — except a gost it can identify
                                          # as this gost.yaml's, or an ssh forward it can prove
                                          # is this spec's (adopted: used, never stopped)
  close_tunnel(tun) -> None               # kills the WHOLE process group it spawned
  is_alive(tun) -> bool
  owner_of(args) -> int | None            # the MCP pid that spawned a signed forward
  gost_preflight(spec) -> list[str]       # problems (empty = ok); never opens socks.auth
  gost_running() -> bool

  uv run scripts/lib/gcloud_tunnel.py --selftest
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
GOST_BIN = "gost"
GOST_CONFIG_VAR = "PG_TRIAGE_GOST_CONFIG"   # scripts/db/.env: gost.yaml path, absolute or relative to the workspace root
GOST_CONFIG: Path | None = None   # selftest seam; None -> resolved from GOST_CONFIG_VAR at call time
GOST_AUTH_FILE = "socks.auth"   # existence is checked; the file is NEVER opened
GOST_GUIDE = 'scripts/db/README.md ("gost (shared SOCKS proxy)")'
TUNNEL_SH = "scripts/db/tunnel.sh"   # the status|kill remedy named in refusals; redis points it at its own
SSH_COMMANDS = {"ssh"}               # lsof command names an adoptable forward may carry (selftest seam)
_SIGNATURE = re.compile(r"(?:^|/)triage-tunnel-(\d+)-")   # -E <log>: the MCP pid that spawned the forward


def gost_config() -> Path | None:
    """The gost.yaml this machine declared, or None when PG_TRIAGE_GOST_CONFIG is unset."""
    if GOST_CONFIG is not None:
        return GOST_CONFIG
    raw = os.environ.get(GOST_CONFIG_VAR, "").strip()
    return (_ROOT / raw).resolve() if raw else None


@dataclass(frozen=True)
class TunnelSpec:
    label: str       # "PGPROD_MAIN_TUNNEL" — every error message names itself
    kind: str        # "gcloud" | "gost" | "none"
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
    adopted_pid: int | None = None  # a gost/ssh started OUTSIDE the MCP: used, never stopped (ADR 0017)
    owner_detail: str = ""          # how an adopted forward was identified (for tunnel_status)


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
    if kind not in ("gcloud", "gost", "none"):
        raise ValueError(f"{label}: tunnel={kind!r}; use gcloud|gost|none")

    host = kv.get("host", "")
    local_str = kv.get("local", "")

    if kind == "gost":
        if not local_str:
            raise ValueError(f"{label}: local= is required for tunnel=gost (the service port in gost.yaml)")
        extra = sorted(set(kv) - {"tunnel", "local"})
        if extra:
            raise ValueError(
                f"{label}: {', '.join(k + '=' for k in extra)} not allowed with tunnel=gost — "
                f"hosts live in gost.yaml"
            )

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


def argv(spec: TunnelSpec, log_path: "Path | str | None" = None) -> list[str]:
    """Build the gcloud argv list for a TunnelSpec — pure, never spawns.

    Produces:
      gcloud compute ssh <vm> [--zone=<zone>] [--project=<p>] [--tunnel-through-iap]
         --quiet -- -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
         -L <local>:<host>:<port> [-E <log_path>]

    `-E <log_path>` (ssh's own log-file option) is the ownership signature: the file is named
    `triage-tunnel-<pid>-…` so a later process can tell whose forward it is (`owner_of`).

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
    if log_path is not None:
        cmd += ["-E", str(log_path)]
    return cmd


def owner_of(args: "list[str]") -> int | None:
    """The MCP pid a signed forward belongs to (`-E …/triage-tunnel-<pid>-…log`), or None when the
    argv carries no signature (a person's own forward, or one from before signatures)."""
    for i, a in enumerate(args):
        if a == "-E" and i + 1 < len(args):
            m = _SIGNATURE.search(args[i + 1])
        elif a.startswith("-E") and len(a) > 2:
            m = _SIGNATURE.search(a[2:])
        else:
            continue
        if m:
            return int(m.group(1))
    return None


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
    if spec.kind == "gost":
        return _open_gost(spec, ready, timeout)

    if _port_in_use(spec.local_port):
        pid, detail, why = _external_ssh(spec, ready)
        if pid is not None:
            return Tunnel(
                spec=spec, proc=None, log_path=None,
                opened_at=time.time(), last_used=time.time(),
                adopted_pid=pid, owner_detail=detail,
            )
        raise RuntimeError(
            f"127.0.0.1:{spec.local_port} is already in use and cannot be adopted: {why}. "
            f"Refusing a tunnel this process cannot prove is {spec.label}'s. "
            f"Inspect with `{TUNNEL_SH} status` and clear with `{TUNNEL_SH} kill`."
        )

    log_fd, log_path_str = tempfile.mkstemp(
        prefix=f"triage-tunnel-{os.getpid()}-{spec.label.lower().replace('_', '-')}-", suffix=".log"
    )
    log_path = Path(log_path_str)

    cmd = argv(spec, log_path)
    with open(log_fd, "wb") as fh:
        # Own session => own process group: teardown signals gcloud AND the ssh it forks.
        proc = subprocess.Popen(
            cmd, stdout=fh, stderr=fh, stdin=subprocess.DEVNULL, start_new_session=True,
        )

    tun = Tunnel(
        spec=spec, proc=proc, log_path=log_path,
        opened_at=time.time(), last_used=time.time(),
    )
    _wait_ready(
        tun, ready, timeout,
        what=f"gcloud tunnel for {spec.label} to {spec.vm!r}",
        hint="Check `gcloud auth list` and IAP/IAM access to the VM.",
    )
    return tun


def _wait_ready(tun: Tunnel, ready, timeout: float, what: str, hint: str) -> None:
    """Block until `tun.spec.local_port` accepts (or `ready()` is True). On child exit or timeout,
    close the tunnel and raise RuntimeError with the log tail + `hint`."""
    spec, proc = tun.spec, tun.proc

    def _tcp_ready() -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1.0)
            return s.connect_ex(("127.0.0.1", spec.local_port)) == 0

    probe = ready or _tcp_ready
    deadline = time.time() + timeout

    while time.time() < deadline:
        if proc.poll() is not None:
            tail: list[str] = []
            if tun.log_path is not None and tun.log_path.exists():
                tail = tun.log_path.read_text(errors="replace").strip().splitlines()[-6:]
            code = proc.returncode
            close_tunnel(tun)
            raise RuntimeError(
                f"{what} exited (code {code}). Last output:\n" + "\n".join(tail) + "\n" + hint
            )
        try:
            if probe():
                return
        except Exception:
            pass
        time.sleep(0.5)

    close_tunnel(tun)
    raise RuntimeError(
        f"{what} did not become ready within {timeout:.0f}s (127.0.0.1:{spec.local_port})"
    )


# --- gost: one shared SOCKS forwarder process for every tunnel=gost target -----------------

_gost_lock = threading.Lock()
_gost_proc: subprocess.Popen | None = None
_gost_log: Path | None = None
_gost_holders: list[Tunnel] = []   # every open gost Tunnel; gost dies when the last one closes


def gost_ports(config: Path) -> set[int]:
    """Local service ports declared in a gost config (`services[].addr: 127.0.0.1:<port>`)."""
    # ponytail: line regex, not a YAML parser — breaks if services[].addr moves to flow style or
    # binds localhost/0.0.0.0; use a parser if gost.yaml changes shape.
    text = config.read_text(errors="replace")
    return {int(m) for m in re.findall(r'^\s*addr:\s*["\']?127\.0\.0\.1:(\d+)', text, re.M)}


def gost_preflight(spec: TunnelSpec) -> list[str]:
    """Everything that must hold before `gost -C gost.yaml` is worth spawning. Returns problem
    lines (empty = ok). `socks.auth` is checked for EXISTENCE only — never opened."""
    problems: list[str] = []
    if shutil.which(GOST_BIN) is None:
        problems += [
            "!!! gost is NOT installed — production Postgres is reachable only through the SOCKS proxy.",
            "!!!   Install it:   brew install gost",
            f"!!!   Setup guide:  {GOST_GUIDE}",
        ]
    config = gost_config()
    if config is None:
        problems.append(f"gost config not set: {GOST_CONFIG_VAR} (see {GOST_GUIDE})")
        return problems
    if not config.is_file():
        problems.append(f"gost config not found: {config} (see {GOST_GUIDE})")
        return problems
    if not (config.parent / GOST_AUTH_FILE).exists():
        problems.append(
            f"SOCKS credentials file missing beside gost.yaml — "
            f'see "SOCKS credentials" in {GOST_GUIDE}'
        )
    declared = gost_ports(config)
    if spec.local_port not in declared:
        problems.append(
            f"{spec.label}: local={spec.local_port} is not a service port in gost.yaml "
            f"(declared: {', '.join(map(str, sorted(declared)))})"
        )
    return problems


def gost_running() -> bool:
    return _gost_proc is not None and _gost_proc.poll() is None


def _run(cmd: list[str]) -> str:
    """stdout of a process-table query (`lsof`/`ps`), "" on any failure — a failure must read as
    "nothing identified", which refuses (fail closed)."""
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=5, env={**os.environ, "LC_ALL": "C"},
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _listener_rows(ports: set[int]) -> list[tuple[int, int, str, int]]:
    """(port, pid, command, uid) for every 127.0.0.1 TCP listener lsof can see on `ports` —
    one row per pid, so a port held by two processes shows twice. v6 (`[::1]`) is ignored.
    Reads the process table only — never connects (a connect to gost dials prod upstream)."""
    rows: list[tuple[int, int, str, int]] = []
    pid, cmd, uid = 0, "", -1
    for line in _run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"]).splitlines():
        tag, val = line[:1], line[1:]
        if tag == "p":
            pid, cmd, uid = int(val), "", -1
        elif tag == "c":
            cmd = val
        elif tag == "u":
            uid = int(val)
        elif tag == "n" and val.startswith("127.0.0.1:"):
            port = int(val.rsplit(":", 1)[1])
            if port in ports and (port, pid, cmd, uid) not in rows:
                rows.append((port, pid, cmd, uid))
    return rows


def _listeners(ports: set[int]) -> dict[int, tuple[int, str, int]]:
    """port -> (pid, command, uid), last listener wins (gost holds every port once)."""
    return {port: (pid, cmd, uid) for port, pid, cmd, uid in _listener_rows(ports)}


def _ps_args(pid: int) -> tuple[int, list[str]]:
    """(ppid, argv words) of `pid`, (0, []) when ps cannot read it."""
    words = _run(["ps", "-ww", "-o", "ppid=,args=", "-p", str(pid)]).split()   # -ww: never truncate argv
    if len(words) < 2:
        return 0, []
    return int(words[0]), words[1:]


def _forward_of(args: list[str]) -> str:
    """The `-L` forward in an ssh argv, normalised to `local:host:port` (a `127.0.0.1:` or
    `localhost:` bind prefix dropped, host lower-cased); "" when there is none."""
    fwd = ""
    for i, a in enumerate(args):
        if a == "-L" and i + 1 < len(args):
            fwd = args[i + 1]
        elif a.startswith("-L") and len(a) > 2:
            fwd = a[2:]
    parts = fwd.lower().split(":")
    if len(parts) == 4 and parts[0] in ("127.0.0.1", "localhost"):
        parts = parts[1:]
    return ":".join(parts) if len(parts) == 3 else ""


def _external_ssh(spec: TunnelSpec, ready) -> tuple[int | None, str, str]:
    """Identify an ssh forward started outside this process that serves `spec`.

    Returns (pid, detail, "") when ONE process passes every check, (None, "", reason) otherwise.
    Checks, in order (ADR 0017 addendum — an identified ssh forward is adopted for connecting,
    never for killing): one listener; it is `ssh` and ours; its `-L` forward is exactly this
    spec's; the VM is provable from its own argv (`start-iap-tunnel <vm>`) or its parent's
    (`compute ssh <vm>`), zone/project matching when both sides declare them; its signature,
    if any, names a LIVE owner (a dead owner's forward is an orphan — refuse, never reclaim);
    and `ready()` passes when the caller gave one."""
    rows = _listener_rows({spec.local_port})
    if not rows:
        return None, "", f"127.0.0.1:{spec.local_port} is busy but lsof shows no listener"
    if len(rows) != 1:
        return None, "", f"port is held by {len(rows)} processes"
    _, pid, cmd, uid = rows[0]
    if cmd not in SSH_COMMANDS:
        return None, "", f"pid {pid} is {cmd!r}, not ssh"
    if uid != os.getuid():
        return None, "", f"pid {pid} belongs to another user"
    ppid, args = _ps_args(pid)
    if not args:
        return None, "", f"pid {pid}: cannot read its argv"
    want = f"{spec.local_port}:{spec.host.lower()}:{spec.port}"
    got = _forward_of(args)
    if got != want:
        return None, "", f"pid {pid} forwards {got or 'nothing'!r}, not {want!r}"
    via = ""
    if "start-iap-tunnel" in args and args[args.index("start-iap-tunnel") + 1:][:1] == [spec.vm]:
        via, scope = f"start-iap-tunnel {spec.vm}", args
    else:
        _, pargs = _ps_args(ppid) if ppid > 1 else (0, [])
        for i in range(len(pargs) - 2):
            if pargs[i:i + 3] == ["compute", "ssh", spec.vm]:
                via, scope = f"gcloud compute ssh {spec.vm} (pid {ppid})", pargs
                break
    if not via:
        return None, "", f"pid {pid}: cannot prove which VM it goes through (want {spec.vm!r})"
    for flag, val in (("--zone", spec.zone), ("--project", spec.project)):
        seen = [a.split("=", 1)[1] for a in scope if a.startswith(flag + "=")]
        if val and seen and seen[0] != val:
            return None, "", f"pid {pid}: {flag}={seen[0]}, not {val}"
    owner = owner_of(args)
    if owner is not None and not _pid_exists(owner):
        return None, "", (
            f"pid {pid} is an orphan of an earlier triage session (owner pid {owner} is gone)"
        )
    if ready is not None:
        try:
            ok = bool(ready())
        except Exception:
            ok = False
        if not ok:
            return None, "", f"pid {pid} listens but the service behind it does not answer (stale forward?)"
    who = "unsigned (a person's own forward)" if owner is None else f"owner pid {owner}"
    return pid, f"ssh pid {pid} via {via}, {who}", ""


def _external_gost(ports: set[int]) -> tuple[int | None, str]:
    """Identify a gost started outside this process that serves EVERY declared port.

    Returns (pid, "") when one process passes every check, (None, "") when no declared port has
    a visible listener, and (None, reason) when a listener exists but must not be adopted. Every
    check reads `lsof`/`ps` only; nothing is ever sent to a port (ADR 0017 addendum 5)."""
    held = _listeners(ports)
    if not held:
        return None, ""
    pids = {v[0] for v in held.values()}
    if len(pids) != 1:
        return None, f"ports are held by {len(pids)} processes"
    pid, cmd, uid = next(iter(held.values()))
    if cmd != "gost":
        return None, f"pid {pid} is {cmd!r}, not gost"
    if uid != os.getuid():
        return None, f"pid {pid} belongs to another user"
    missing = sorted(ports - set(held))
    if missing:
        return None, (
            f"pid {pid} does not serve {', '.join(map(str, missing))} — it is not running this "
            f"gost.yaml, or started before a port was added; restart it"
        )
    # `uid ppid lstart(5 words) args...` — split on whitespace, never fixed columns (`Sep  5`).
    ps = _run(["ps", "-o", "uid=,ppid=,lstart=,args=", "-p", str(pid)]).split()
    cwd = ""
    for line in _run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"]).splitlines():
        if line.startswith("n"):
            cwd = line[1:]
    args = ps[7:]
    conf = ""
    for i, a in enumerate(args):
        if a == "-C" and i + 1 < len(args):
            conf = args[i + 1]
        elif a.startswith("-C="):
            conf = a[3:]
    if len(ps) < 8 or not cwd or not conf:
        return None, f"pid {pid}: cannot read its -C config or cwd"
    config = gost_config()
    resolved = (Path(cwd) / conf).resolve()
    if config is None or resolved != config.resolve():
        return None, f"pid {pid} runs a different config ({resolved}), not {GOST_CONFIG_VAR}"
    try:
        started = time.mktime(time.strptime(" ".join(ps[2:7]), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None, f"pid {pid}: cannot read its -C config or cwd"
    if config.stat().st_mtime > started + 1:
        return None, (
            f"pid {pid} started before {config} last changed — restart it "
            f"(gost -C {config})"
        )
    if ps[1] == "1" and conf == str(config):
        return None, (
            f"pid {pid} looks like an orphan of an earlier pg_triage session "
            f"(ppid 1, the MCP's own argv)"
        )
    return pid, ""


def _open_gost(spec: TunnelSpec, ready, timeout: float) -> Tunnel:
    global _gost_proc, _gost_log, _gost_holders
    problems = gost_preflight(spec)
    if problems:
        raise RuntimeError("\n".join(problems))

    with _gost_lock:
        if not gost_running():
            _gost_holders = []
            _gost_proc = None
            config = gost_config()  # preflight above guarantees it is set and a file
            ports = gost_ports(config)
            pid, why = _external_gost(ports)
            if pid is not None:  # a gost started outside the MCP: use it, never stop it (ADR 0017)
                now = time.time()
                return Tunnel(spec=spec, proc=None, log_path=None, opened_at=now, last_used=now,
                              adopted_pid=pid)
            busy = sorted(_listeners(ports)) if why else sorted(p for p in ports if _port_in_use(p))
            if busy:
                raise RuntimeError(
                    f"127.0.0.1:{', '.join(map(str, busy))} is already in use and cannot be adopted — "
                    f"{why or 'the listener is not visible to lsof (another user, or not bound to 127.0.0.1)'}. "
                    f"Inspect with `scripts/db/tunnel.sh status`; stop it (or `scripts/db/tunnel.sh kill`) "
                    f"to let the MCP start its own."
                )
            log_fd, log_path_str = tempfile.mkstemp(prefix="pg-tunnel-gost-", suffix=".log")
            _gost_log = Path(log_path_str)
            with open(log_fd, "wb") as fh:
                _gost_proc = subprocess.Popen(
                    [GOST_BIN, "-C", str(config)], cwd=config.parent,
                    stdout=fh, stderr=fh, stdin=subprocess.DEVNULL,
                )
        tun = Tunnel(
            spec=spec, proc=_gost_proc, log_path=_gost_log,
            opened_at=time.time(), last_used=time.time(),
        )
        _gost_holders.append(tun)

    _wait_ready(
        tun, ready, timeout,
        what=f"gost for {spec.label}",
        hint=f'See "When it fails" in {GOST_GUIDE}.',
    )
    return tun


def _close_gost(tun: Tunnel) -> None:
    global _gost_proc, _gost_log, _gost_holders
    with _gost_lock:
        _gost_holders = [t for t in _gost_holders if t is not tun]   # identity; idempotent
        if tun.proc is not _gost_proc or _gost_holders:
            return   # stale generation, or someone still needs the shared process
        _terminate(tun.proc)
        _cleanup_log(_gost_log)
        _gost_proc = None
        _gost_log = None


def _terminate(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def _pid_exists(pid: int) -> bool:
    """Existence probe only: signal 0 delivers nothing to the process."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def close_tunnel(tun: Tunnel) -> None:
    """Terminate the port-forward process GROUP and remove the log file. A gost tunnel only
    releases its hold; the shared gost process stops when the last holder closes. An ADOPTED
    gost or ssh forward is never touched — the MCP did not start it and must not stop it."""
    if tun.adopted_pid is not None:
        return  # ADR 0017 addendum 5: adopted for connecting, never for killing
    if tun.proc is None:
        return
    if tun.spec.kind == "gost":
        _close_gost(tun)
        return
    _terminate_group(tun.proc)
    _cleanup_log(tun.log_path)


def _terminate_group(proc: subprocess.Popen) -> None:
    """SIGTERM the process group `proc` leads (gcloud + the ssh it forked), wait 5 s, then
    SIGKILL the group. A group that is already gone is not an error."""

    def _signal_group(sig: int) -> None:
        try:
            os.killpg(proc.pid, sig)   # the group it leads (start_new_session=True)
            return
        except ProcessLookupError:
            pass
        try:
            os.kill(proc.pid, sig)     # not a leader (a stand-in spawned in our own group)
        except ProcessLookupError:
            pass

    if proc.poll() is None:
        _signal_group(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    _signal_group(signal.SIGKILL)
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def _cleanup_log(log_path: Path | None) -> None:
    try:
        if log_path is not None:
            log_path.unlink(missing_ok=True)
    except Exception:
        pass


def is_alive(tun: Tunnel) -> bool:
    """Whether the tunnel process is still running.

    Returns True for kind=none (direct connection — nothing to reap). An adopted forward is alive
    while its pid exists — a signal-0 probe, never a connect (a connect to gost dials upstream).
    """
    if tun.adopted_pid is not None:
        return _pid_exists(tun.adopted_pid)
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
    expect_err("LBL", "tunnel=badkind;host=h;local=15439;vm=v", "gcloud|gost|none")

    # --- parse_spec: tunnel=gost ---------------------------------------------------------
    spec_gost = parse_spec("PGPROD_MAIN_TUNNEL", "tunnel=gost;local=65432")
    check("gost spec parses", spec_gost.kind == "gost" and spec_gost.local_port == 65432)
    expect_err("LBL", "tunnel=gost", "local=")                              # missing local
    expect_err("LBL", "tunnel=gost;local=65432;host=x", "gost.yaml")        # host not allowed
    expect_err("LBL", "tunnel=gost;local=65432;vm=v", "gost.yaml")          # vm not allowed

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

    # --- adopted tunnel: never stopped (a `sleep` stands in for a person's gost) --------------
    sleeper = subprocess.Popen(["sleep", "60"])
    try:
        adopted = Tunnel(spec=spec_gost, proc=None, log_path=None, opened_at=0, last_used=0,
                         adopted_pid=sleeper.pid)
        check("adopted: alive while the pid exists", is_alive(adopted))
        close_tunnel(adopted)
        close_tunnel(adopted)
        check("adopted: close_tunnel never stops the process", sleeper.poll() is None)
    finally:
        sleeper.kill()   # the fixture owns it — module code never signals an adopted pid
        sleeper.wait()
    check("adopted: dead once the pid is gone", not is_alive(adopted))

    # --- signature: argv -E <log> + owner_of ---------------------------------------------------
    signed = argv(spec, "/tmp/triage-tunnel-4242-lbl-abc.log")
    check("argv: unchanged without a log path", "-E" not in argv(spec))
    check("argv: -E <log> appended after the forward", signed[-2:] == ["-E", "/tmp/triage-tunnel-4242-lbl-abc.log"])
    check("owner_of: reads the pid out of -E", owner_of(signed) == 4242)
    check("owner_of: glued -E form", owner_of(["ssh", "-E/x/triage-tunnel-7-l-q.log"]) == 7)
    check("owner_of: unsigned argv is None", owner_of(argv(spec)) is None)
    check("owner_of: a stray log name is not a signature", owner_of(["ssh", "-E", "/tmp/other.log"]) is None)

    # --- ssh forwards: process-group teardown + adoption (hermetic stand-ins) -----------------
    # `ssh` is a copy of the perl binary (a script would make lsof name the interpreter, so the
    # command-name check could never see "ssh") that binds the -L port; `gcloud` is a shell
    # parent that forks it and waits — the same shape as `gcloud compute ssh` forking the real
    # ssh. The listener never accepts, so its backlog must outlast every probe the checks below
    # make: a saturated backlog drops the SYN, `_port_in_use` reads False, and open_tunnel
    # takes the spawn path against a port a stand-in already holds.
    global SSH_COMMANDS
    saved_ssh, saved_path = SSH_COMMANDS, os.environ.get("PATH", "")
    with tempfile.TemporaryDirectory() as fxdir:
        fx = Path(fxdir)
        shutil.copy(shutil.which("perl") or "/usr/bin/perl", fx / "ssh")
        listen = ['-e', 'use IO::Socket::INET; my ($i) = grep { $ARGV[$_] eq "-L" } 0..$#ARGV;'
                  ' my ($p) = $ARGV[$i + 1] =~ /^(\\d+)/; my $s = IO::Socket::INET->new('
                  'LocalAddr => "127.0.0.1", LocalPort => $p, Listen => 128, ReuseAddr => 1) or die; sleep 60',
                  '--']
        (fx / "gcloud").write_text(
            f'#!/bin/sh\n"$(dirname "$0")/ssh" {listen[0]} \'{listen[1]}\' {listen[2]} "$@" &\nwait\n'
        )
        for f in ("ssh", "gcloud"):
            (fx / f).chmod(0o755)
        fixtures: list[subprocess.Popen] = []

        def _free() -> int:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(("127.0.0.1", 0))
                return s.getsockname()[1]

        def _wait_port(port: int) -> None:
            for _ in range(60):
                if _port_in_use(port):
                    return
                time.sleep(0.1)

        def stand_in(port: int, host: str = "h", vm: str = "vmx", parent: bool = True,
                     sig: str | None = None, extra: list[str] | None = None) -> subprocess.Popen:
            tail = ["-N", "-L", f"{port}:{host}:6379"] + (["-E", sig] if sig else [])
            cmd = ([str(fx / "gcloud"), "compute", "ssh", vm] + (extra or []) + ["--quiet", "--"] + tail
                   if parent else [str(fx / "ssh")] + listen + tail)
            proc = subprocess.Popen(cmd, start_new_session=True, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            fixtures.append(proc)
            _wait_port(port)
            return proc

        def refusal(spec_: TunnelSpec, ready=None) -> str:
            try:
                tun = open_tunnel(spec_, ready=ready, timeout=1)
            except RuntimeError as exc:
                return str(exc)
            close_tunnel(tun)
            return ""

        def refused(label: str, needle: str, spec_str: str, ready=None) -> None:
            msg = refusal(parse_spec("LBL", spec_str), ready=ready)
            check(label, needle in msg, msg[:120])

        try:
            # S1: spawn path kills the whole group (parent `gcloud` AND the `ssh` it forked)
            os.environ["PATH"] = f"{fx}:{saved_path}"
            p = _free()
            spec_grp = parse_spec("LBL", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx")
            tun_grp = open_tunnel(spec_grp, timeout=10)
            rows = _listener_rows({p})
            child = rows[0][1] if rows else 0
            check("group: spawned forward listens via a child", child not in (0, tun_grp.proc.pid))
            check("group: log name carries the owner signature",
                  owner_of(argv(spec_grp, tun_grp.log_path)) == os.getpid())
            close_tunnel(tun_grp)
            time.sleep(0.3)
            check("group: close_tunnel kills the forked child too", not _pid_exists(child))
            check("group: port released", not _port_in_use(p))
            check("group: log removed", not tun_grp.log_path.exists())
            os.environ["PATH"] = saved_path

            # S3: adoption — identify, then adopt or refuse naming the failed condition
            p = _free()
            spec_ok = parse_spec("LBL", f"tunnel=gcloud;host=H;port=6379;local={p};vm=vmx;zone=z1")
            manual = stand_in(p)
            SSH_COMMANDS = {"not-a-forward"}
            msg = refusal(spec_ok)
            check("adopt: a non-ssh command is refused", "not ssh" in msg and TUNNEL_SH in msg, msg[:100])
            SSH_COMMANDS = saved_ssh
            tun_ad = open_tunnel(spec_ok, ready=lambda: True, timeout=1)
            check("adopt: identified forward is adopted", tun_ad.adopted_pid == _listener_rows({p})[0][1]
                  and tun_ad.proc is None, tun_ad.owner_detail)
            check("adopt: owner_detail names the VM and 'unsigned'",
                  "vmx" in tun_ad.owner_detail and "unsigned" in tun_ad.owner_detail)
            close_tunnel(tun_ad)
            close_tunnel(tun_ad)
            check("adopt: close_tunnel never stops it", manual.poll() is None and is_alive(tun_ad))
            check("adopt: an undeclared zone on the forward is not held against it",
                  refusal(parse_spec("LBL", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx;zone=z2")) == "")
            os.killpg(manual.pid, signal.SIGKILL); manual.wait()
            time.sleep(0.2)
            check("adopt: dead once the pid is gone", not is_alive(tun_ad))

            p = _free(); stand_in(p, extra=["--zone=z1"])
            refused("adopt: declared zone must match", "--zone=z1, not z2", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx;zone=z2")
            check("adopt: matching zone adopts", refusal(
                parse_spec("LBL", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx;zone=z1")) == "")

            p = _free(); stand_in(p, host="other")
            refused("adopt: wrong forward is refused", "forwards", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx")
            p = _free(); stand_in(p, vm="vmy")
            refused("adopt: wrong VM is refused", "cannot prove which VM", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx")
            p = _free(); stand_in(p, parent=False)
            refused("adopt: no VM proof is refused", "cannot prove which VM", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx")
            dead = subprocess.Popen(["true"]); dead.wait()
            p = _free(); stand_in(p, sig=f"/tmp/triage-tunnel-{dead.pid}-lbl-x.log")
            refused("adopt: orphan of a dead owner is refused", "orphan", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx")
            p = _free(); stand_in(p, sig=f"/tmp/triage-tunnel-{os.getpid()}-lbl-x.log")
            tun_live = open_tunnel(parse_spec("LBL", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx"), timeout=1)
            check("adopt: live-owner signature adopts", f"owner pid {os.getpid()}" in tun_live.owner_detail)
            refused("adopt: ready() False refuses as stale", "does not answer", f"tunnel=gcloud;host=h;port=6379;local={p};vm=vmx", ready=lambda: False)
        finally:
            SSH_COMMANDS = saved_ssh
            os.environ["PATH"] = saved_path
            for proc in fixtures:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()

    # --- gost: preflight + shared process (hermetic temp config, never the declared gost.yaml) ----
    global GOST_BIN, GOST_CONFIG

    def _free_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _gost_yaml(*ports: int) -> str:
        out = ["services:"]
        for i, p in enumerate(ports):
            out += [
                f"  - name: svc{i}",
                f"    addr: 127.0.0.1:{p}",
                "    handler: { type: tcp }",
                "    listener: { type: tcp }",
                "    forwarder:",
                "      nodes: [{ name: sink, addr: 127.0.0.1:1 }]",
            ]
        return "\n".join(out) + "\n"

    saved_bin, saved_cfg = GOST_BIN, GOST_CONFIG
    with tempfile.TemporaryDirectory(prefix="gost-selftest-") as td:
        cfg = Path(td) / "gost.yaml"
        p1, p2 = _free_port(), _free_port()
        cfg.write_text(_gost_yaml(p1, p2))
        GOST_CONFIG = cfg
        spec_a = parse_spec("PGPROD_A_TUNNEL", f"tunnel=gost;local={p1}")
        spec_b = parse_spec("PGPROD_B_TUNNEL", f"tunnel=gost;local={p2}")
        try:
            check("gost_ports reads service ports", gost_ports(cfg) == {p1, p2}, str(gost_ports(cfg)))

            GOST_BIN = "gost-definitely-missing"
            probs = "\n".join(gost_preflight(spec_a))
            check("preflight: missing binary says brew install gost", "brew install gost" in probs, probs[:80])
            check("preflight: missing binary points at the guide", "README.md" in probs)
            check("preflight: missing binary is a loud banner", "!!!" in probs)
            GOST_BIN = saved_bin

            probs = "\n".join(gost_preflight(spec_a))
            check("preflight: missing socks.auth reported", "SOCKS credentials" in probs, probs[:80])
            (Path(td) / GOST_AUTH_FILE).touch()

            spec_x = parse_spec("PGPROD_X_TUNNEL", "tunnel=gost;local=1")
            probs = "\n".join(gost_preflight(spec_x))
            check("preflight: undeclared local port reported", "not a service port" in probs, probs[:80])

            GOST_CONFIG = Path(td) / "nope.yaml"
            probs = "\n".join(gost_preflight(spec_a))
            check("preflight: missing gost.yaml reported", "gost config not found" in probs, probs[:80])

            # With the seam released, PG_TRIAGE_GOST_CONFIG is the only source of the path.
            GOST_CONFIG = None
            saved_env = os.environ.pop(GOST_CONFIG_VAR, None)
            try:
                probs = "\n".join(gost_preflight(spec_a))
                check("preflight: unset PG_TRIAGE_GOST_CONFIG reported", "gost config not set" in probs, probs[:80])
                os.environ[GOST_CONFIG_VAR] = str(cfg)
                check("config: absolute path resolves as given", gost_config() == cfg.resolve())
                os.environ[GOST_CONFIG_VAR] = "some/dir/gost.yaml"
                check("config: relative path resolves from the workspace root",
                      gost_config() == (_ROOT / "some/dir/gost.yaml").resolve())
            finally:
                os.environ.pop(GOST_CONFIG_VAR, None)
                if saved_env is not None:
                    os.environ[GOST_CONFIG_VAR] = saved_env
            GOST_CONFIG = cfg

            if shutil.which(GOST_BIN) is None:
                print("  skip gost process checks — gost not installed (brew install gost)")
            else:
                check("preflight: complete config passes", gost_preflight(spec_a) == [])

                # busy declared port -> refused before spawn
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
                    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    srv.bind(("127.0.0.1", p2))
                    srv.listen(1)
                    try:
                        open_tunnel(spec_a, timeout=2)
                        check("gost: busy declared port refused", False, "no error raised")
                    except RuntimeError as exc:
                        msg = str(exc)
                        check("gost: busy declared port refused", "already in use" in msg, msg[:80])
                        check("gost: busy port names tunnel.sh", "scripts/db/tunnel.sh" in msg)
                        check("gost: busy port says why (not gost)", "not gost" in msg, msg[:120])
                    check("gost: nothing spawned after refusal", not gost_running())

                # --- a gost started outside the MCP (the guide's own spelling) -----------------
                def _manual(conf: str = "gost.yaml") -> subprocess.Popen:
                    proc = subprocess.Popen(
                        [GOST_BIN, "-C", conf], cwd=td,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    )
                    want = gost_ports(Path(td) / conf)
                    for _ in range(100):  # wait by reading the process table, never by connecting
                        if {v[0] for v in _listeners(want).values()} == {proc.pid} \
                                and set(_listeners(want)) == want:
                            break
                        time.sleep(0.1)
                    return proc

                def _refused(label: str, fragment: str) -> None:
                    try:
                        open_tunnel(spec_a, timeout=2)
                        check(f"gost: refuse {label}", False, "adopted or spawned")
                    except RuntimeError as exc:
                        msg = str(exc)
                        check(f"gost: refuse {label}", "already in use" in msg and fragment in msg,
                              msg[:140])
                    check(f"gost: refuse {label} spawned nothing", not gost_running())

                manual = _manual()
                try:
                    tun_a = open_tunnel(spec_a, timeout=2)
                    tun_b = open_tunnel(spec_b, timeout=2)
                    check("adopt: manual gost is adopted",
                          tun_a.adopted_pid == manual.pid and tun_a.proc is None)
                    check("adopt: second target adopts too", tun_b.adopted_pid == manual.pid)
                    check("adopt: shared-gost state untouched",
                          not gost_running() and _gost_holders == [])
                    close_tunnel(tun_a)
                    close_tunnel(tun_b)
                    check("adopt: close leaves the manual gost running",
                          manual.poll() is None and set(_listeners({p1, p2})) == {p1, p2})

                    # stale: config edited after the process started
                    st = cfg.stat()
                    os.utime(cfg, (st.st_atime + 60, st.st_mtime + 60))
                    try:
                        _refused("stale config", "started before")
                    finally:
                        os.utime(cfg, (st.st_atime, st.st_mtime))
                finally:
                    manual.terminate()
                    manual.wait(timeout=5)
                time.sleep(0.2)

                # fallback: manual gost gone -> the MCP spawns its own (full lifecycle)
                tun_a = open_tunnel(spec_a, timeout=10)
                check("adopt: falls back to self-spawn", gost_running() and tun_a.adopted_pid is None)
                close_tunnel(tun_a)
                check("adopt: self-spawned still stops with its last holder", not gost_running())
                time.sleep(0.2)

                # partial: a gost serving only p1
                (Path(td) / "half.yaml").write_text(_gost_yaml(p1))
                half = _manual("half.yaml")
                try:
                    _refused("partial port set", "does not serve")
                finally:
                    half.terminate()
                    half.wait(timeout=5)
                time.sleep(0.2)

                # other config: same ports, different file
                (Path(td) / "copy.yaml").write_text(cfg.read_text())
                other = _manual("copy.yaml")
                try:
                    _refused("different config", "different config")
                finally:
                    other.terminate()
                    other.wait(timeout=5)
                time.sleep(0.2)

                # MCP orphan signature: ppid 1 + the MCP's own absolute argv
                subprocess.Popen(
                    ["sh", "-c", f'"{GOST_BIN}" -C "{cfg}" >/dev/null 2>&1 &'], cwd=td,
                ).wait()
                orphan = 0
                for _ in range(100):
                    held = _listeners({p1, p2})
                    if set(held) == {p1, p2}:
                        orphan = held[p1][0]
                        break
                    time.sleep(0.1)
                try:
                    ppid = _run(["ps", "-o", "ppid=", "-p", str(orphan)]).strip()
                    if ppid != "1":
                        print(f"  skip orphan check — detached gost has ppid {ppid!r}, not 1 (subreaper?)")
                    else:
                        _refused("MCP orphan", "orphan")
                finally:
                    if orphan:
                        os.kill(orphan, 15)   # the fixture's own process
                        for _ in range(50):
                            if not _pid_exists(orphan):
                                break
                            time.sleep(0.1)
                time.sleep(0.2)

                tun_a = open_tunnel(spec_a, timeout=10)
                tun_b = open_tunnel(spec_b, timeout=10)
                check("gost: two targets share one process", tun_a.proc is tun_b.proc and gost_running())
                check("gost: both ports accept", _port_in_use(p1) and _port_in_use(p2))
                close_tunnel(tun_a)
                check("gost: closing one holder keeps gost", gost_running() and _port_in_use(p2))
                close_tunnel(tun_a)
                check("gost: double close is harmless", gost_running())
                close_tunnel(tun_b)
                check("gost: last holder stops gost", not gost_running())
                time.sleep(0.2)
                check("gost: ports freed", not _port_in_use(p1) and not _port_in_use(p2))

                # external crash -> stale holders never kill the next generation
                tun_a = open_tunnel(spec_a, timeout=10)
                tun_b = open_tunnel(spec_b, timeout=10)
                tun_a.proc.kill()
                tun_a.proc.wait(timeout=5)
                check("gost: crash marks every holder dead", not is_alive(tun_a) and not is_alive(tun_b))
                tun_a2 = open_tunnel(spec_a, timeout=10)
                check("gost: reopen spawns a new process", tun_a2.proc is not tun_a.proc and gost_running())
                close_tunnel(tun_b)
                check("gost: closing a stale holder keeps the new process", gost_running())
                close_tunnel(tun_a2)
                check("gost: last new holder stops gost", not gost_running())
        finally:
            GOST_BIN, GOST_CONFIG = saved_bin, saved_cfg
            for t in list(_gost_holders):
                close_tunnel(t)

    print("selftest ok" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print(__doc__)
    raise SystemExit(0)
