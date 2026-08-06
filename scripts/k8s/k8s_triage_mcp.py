# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.2,<2",
#   "kubernetes>=29",
# ]
# # The <2 bound is load-bearing: mcp 2.0 removed `mcp.server.fastmcp`, so an unbounded `mcp>=1.2`
# # resolves to a release this file cannot import. It only looks fine on a machine whose uv cache
# # still holds a 1.x environment.
# ///
"""k8s-triage — on-demand, READ-ONLY MCP over the deployed Kubernetes clusters (STAGING + PROD).

The credential a human carries for these clusters can delete a Deployment. This server never uses
it. Every call authenticates as a dedicated service account —
`k8s-triage@<project>.iam.gserviceaccount.com` — obtained by IMPERSONATION, so no long-lived key
exists on disk, and that identity is bound to the upstream `view` ClusterRole plus a small
`k8s-triage-extra` role. Read-only is therefore enforced by the API SERVER: a delete comes back
403 from Kubernetes before it is even matched against an object, not from a check in this file.
`scripts/k8s/bootstrap-sa.sh` creates that identity and proves the property. See docs/adr/0007.

Targets are DERIVED, never configured. Each kubeconfig context names a cluster as
`gke_<project>_<region>_<cluster>`; that string is written by GKE, so it reads identically on
every teammate's machine, while the context's own name is a personal alias and is ignored:

    gke_agent-384510_asia-southeast1_agent-staging   ->  product="agent"   env="staging"
    gke_core-287413_asia-southeast1_bluepi-prod      ->  product="bluepi"  env="prod"

Both axes are chosen PER CALL and neither is defaulted — `list_targets()` reports what this
machine can see, and an unnamed product or environment is an error rather than a guess. This
server never writes to `~/.kube/config`: switching the current context would be a machine-wide
side effect, and the next `kubectl` a human ran in their own terminal would inherit it.

Safety is layered:
  1. PRODUCTION is gated by policy, checked before a token is ever minted
     (`scripts/lib/triage_policy.py` -> `triage.prod`, read local-first). Holding a kubeconfig
     entry is not permission. Staging needs no opt-in — it is not the production boundary.
  2. The identity's RBAC is the actual guarantee. `view` excludes secrets, pods/exec and
     pods/portforward, and `k8s-triage-extra` adds only nodes, metrics and non-core API groups,
     so there is no rule under which a Secret can be read or a shell opened.
  3. This process calls read verbs only. That is convenience — a clear error instead of a 403 —
     and never the thing being relied on.
  4. PII provenance is PROD-ONLY, and covers pod LOGS, which is where personal data actually
     appears (request bodies, headers, player records). Log text from a prod target is fed to
     the vault (`scripts/lib/pii_provenance.py`) as keyed hashes, never values, which is what
     makes the egress redaction in the tracker / notify adapters prod-specific. Staging logs are
     never vaulted. Every result says which happened (`env` + `pii_vaulted`).
  5. Output is projected to a compact shape by default so one call cannot flood the context, and
     anything dropped is REPORTED (`truncated`, `returned`, `limit`) rather than silently cut.

  uv run scripts/k8s/k8s_triage_mcp.py --selftest          # deps + targets + policy, no cluster access
  uv run scripts/k8s/k8s_triage_mcp.py --verify staging    # live read-only acceptance run
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from kubernetes import client as k8s_client
from kubernetes.dynamic import DynamicClient
from mcp.server.fastmcp import FastMCP

# The production policy gate is load-bearing, so an import failure there is fatal rather than
# silently permissive. Provenance is a safety net that must not break triage if it is missing.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import triage_policy  # noqa: E402

try:
    import pii_provenance  # noqa: E402
except Exception:
    pii_provenance = None  # type: ignore[assignment]

# --- configuration -----------------------------------------------------------------------

SA_NAME = "k8s-triage"  # convention: one identity per GCP project, created by bootstrap-sa.sh
TOKEN_TTL_S = 45 * 60  # impersonated access tokens last an hour; refresh well before the edge
REQUEST_TIMEOUT_S = 20
DEFAULT_LIMIT = 100
MAX_LIMIT = 500
DEFAULT_TAIL_LINES = 200
MAX_TAIL_LINES = 5_000
MAX_LOG_BYTES = 256 * 1024

ENV_PROD = "prod"
ENV_STAGING = "staging"
ENVS = (ENV_STAGING, ENV_PROD)

mcp = FastMCP("k8s-triage")

_tokens: dict[str, tuple[float, str]] = {}  # project -> (expires_at, token)
_clients: dict[str, tuple[DynamicClient, k8s_client.ApiClient]] = {}
_ca_files: dict[str, str] = {}


# --- target derivation -------------------------------------------------------------------


def _kubeconfig_path() -> Path:
    return Path(os.environ.get("KUBECONFIG", "") or (Path.home() / ".kube" / "config"))


def _load_kubeconfig() -> dict:
    """Parse kubeconfig without the kubernetes loader, which resolves exec plugins and would run
    gke-gcloud-auth-plugin — i.e. authenticate as the HUMAN. This server must never hold that
    credential, so it reads the file for coordinates only and brings its own bearer token."""
    path = _kubeconfig_path()
    try:
        import yaml  # provided transitively by the kubernetes package

        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception:
        return {}


def _discover() -> dict[str, dict]:
    """{"<product>/<env>": {...}} for every GKE cluster this kubeconfig knows about."""
    cfg = _load_kubeconfig()
    clusters = {c.get("name"): c.get("cluster", {}) for c in (cfg.get("clusters") or [])}
    out: dict[str, dict] = {}
    for ctx in cfg.get("contexts") or []:
        ref = (ctx.get("context") or {}).get("cluster") or ""
        parts = ref.split("_")
        if len(parts) != 4 or parts[0] != "gke":
            continue  # not a GKE cluster reference; this server addresses GKE only
        _, project, region, cluster = parts
        if cluster.endswith("-" + ENV_PROD):
            env, product = ENV_PROD, cluster[: -len(ENV_PROD) - 1]
        elif cluster.endswith("-" + ENV_STAGING):
            env, product = ENV_STAGING, cluster[: -len(ENV_STAGING) - 1]
        else:
            continue  # no derivable environment; excluded rather than guessed
        info = clusters.get(ref) or {}
        server = info.get("server")
        ca = info.get("certificate-authority-data")
        if not server or not ca:
            continue
        out[f"{product}/{env}"] = {
            "product": product,
            "env": env,
            "project": project,
            "region": region,
            "cluster": cluster,
            "server": server,
            "ca_data": ca,
            "context_alias": ctx.get("name"),
            "service_account": f"{SA_NAME}@{project}.iam.gserviceaccount.com",
        }
    return out


def _targets() -> dict[str, dict]:
    return _discover()


def _resolve(product: str | None, env: str | None) -> dict:
    """Both axes are required. An unnamed environment must never resolve to production."""
    if not product or not env:
        raise ValueError(
            "both `product` and `env` are required — call list_targets() to see what exists"
        )
    env = env.strip().lower()
    product = product.strip().lower()
    if env not in ENVS:
        raise ValueError(f"env must be one of {ENVS}; got {env!r}")
    found = _targets()
    key = f"{product}/{env}"
    if key not in found:
        raise ValueError(
            f"no cluster for product={product!r} env={env!r}. Available: {sorted(found) or 'none'}"
        )
    return found[key]


# --- authentication ----------------------------------------------------------------------


def _assert_allowed(target: dict) -> None:
    """The production gate, checked before a token is minted or a socket is opened."""
    if target["env"] != ENV_PROD:
        return
    # The shared message, so every triage server refuses production in the same words and names
    # the same fix — including the warning about the removed pre-0005 key.
    triage_policy.assert_prod_allowed(f"PRODUCTION Kubernetes triage ({target['cluster']})")


def _token(project: str, service_account: str) -> str:
    """A short-lived access token for the read-only identity, via GCP impersonation.

    No key file exists: the caller's own credential is used to mint a token FOR the service
    account, which requires roles/iam.serviceAccountTokenCreator on it. Cached until shortly
    before expiry so a triage session is not one gcloud subprocess per call.
    """
    hit = _tokens.get(project)
    if hit and hit[0] > time.time():
        return hit[1]
    proc = subprocess.run(
        [
            "gcloud",
            "auth",
            "print-access-token",
            f"--impersonate-service-account={service_account}",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    token = proc.stdout.strip()
    if proc.returncode != 0 or not token:
        err = (proc.stderr or "").strip().splitlines()
        hint = err[-1] if err else "no output from gcloud"
        raise PermissionError(
            f"could not impersonate {service_account}: {hint}\n"
            f"Run: scripts/k8s/setup.sh   (it reports exactly what is missing)"
        )
    _tokens[project] = (time.time() + TOKEN_TTL_S, token)
    return token


def _client(target: dict) -> tuple[DynamicClient, k8s_client.ApiClient]:
    _assert_allowed(target)
    key = f"{target['product']}/{target['env']}"
    cached = _clients.get(key)
    if cached is not None:
        # Refresh the bearer token in place; the cached client keeps its connection pool.
        cached[1].configuration.api_key["authorization"] = "Bearer " + _token(
            target["project"], target["service_account"]
        )
        return cached

    ca_path = _ca_files.get(key)
    if not ca_path or not os.path.exists(ca_path):
        fd, ca_path = tempfile.mkstemp(prefix=f"k8s-triage-{target['cluster']}-", suffix=".crt")
        with os.fdopen(fd, "wb") as fh:
            fh.write(base64.b64decode(target["ca_data"]))
        _ca_files[key] = ca_path

    cfg = k8s_client.Configuration()
    cfg.host = target["server"]
    cfg.ssl_ca_cert = ca_path
    cfg.verify_ssl = True
    cfg.api_key = {"authorization": "Bearer " + _token(target["project"], target["service_account"])}
    api = k8s_client.ApiClient(configuration=cfg)
    dyn = DynamicClient(api)
    _clients[key] = (dyn, api)
    return _clients[key]


# --- result shaping ----------------------------------------------------------------------


def _vaults(env: str) -> bool:
    """Whether text from this env is fingerprinted for egress redaction. Prod only."""
    return env == ENV_PROD and pii_provenance is not None


def _result(target: dict, payload: dict) -> dict:
    """Stamp every result with the facts a reader must not have to remember: which cluster
    answered, and whether those values will be masked at egress."""
    return {
        "product": target["product"],
        "env": target["env"],
        "cluster": target["cluster"],
        "pii_vaulted": _vaults(target["env"]),
        **payload,
    }


def _age(ts: str | None) -> str:
    if not ts:
        return ""
    try:
        from datetime import datetime, timezone

        then = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        secs = int((datetime.now(timezone.utc) - then).total_seconds())
    except Exception:
        return ""
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def _project_pod(o: dict) -> dict:
    st = o.get("status") or {}
    cs = st.get("containerStatuses") or []
    ready = sum(1 for c in cs if c.get("ready"))
    waiting = [
        c["state"]["waiting"].get("reason")
        for c in cs
        if (c.get("state") or {}).get("waiting", {}).get("reason")
    ]
    terminated = [
        c["lastState"]["terminated"].get("reason")
        for c in cs
        if (c.get("lastState") or {}).get("terminated", {}).get("reason")
    ]
    return {
        "name": (o.get("metadata") or {}).get("name"),
        "namespace": (o.get("metadata") or {}).get("namespace"),
        "phase": st.get("phase"),
        "ready": f"{ready}/{len(cs)}" if cs else "0/0",
        "restarts": sum(c.get("restartCount", 0) for c in cs),
        "age": _age((o.get("metadata") or {}).get("creationTimestamp")),
        "node": (o.get("spec") or {}).get("nodeName"),
        "waiting": waiting or None,
        "last_terminated": terminated or None,
    }


def _project_event(o: dict) -> dict:
    involved = o.get("involvedObject") or o.get("regarding") or {}
    return {
        "type": o.get("type"),
        "reason": o.get("reason"),
        "object": f"{involved.get('kind','')}/{involved.get('name','')}".strip("/"),
        "namespace": (o.get("metadata") or {}).get("namespace"),
        "message": o.get("message"),
        "count": o.get("count") or o.get("deprecatedCount"),
        "last_seen": o.get("lastTimestamp") or o.get("deprecatedLastTimestamp") or o.get("eventTime"),
    }


def _project_workload(o: dict) -> dict:
    st = o.get("status") or {}
    return {
        "name": (o.get("metadata") or {}).get("name"),
        "namespace": (o.get("metadata") or {}).get("namespace"),
        "desired": (o.get("spec") or {}).get("replicas"),
        "ready": st.get("readyReplicas"),
        "updated": st.get("updatedReplicas"),
        "available": st.get("availableReplicas"),
        "age": _age((o.get("metadata") or {}).get("creationTimestamp")),
    }


def _project_generic(o: dict) -> dict:
    md = o.get("metadata") or {}
    return {
        "name": md.get("name"),
        "namespace": md.get("namespace"),
        "kind": o.get("kind"),
        "age": _age(md.get("creationTimestamp")),
    }


_PROJECTORS = {
    "Pod": _project_pod,
    "Event": _project_event,
    "Deployment": _project_workload,
    "StatefulSet": _project_workload,
    "DaemonSet": _project_workload,
    "ReplicaSet": _project_workload,
}


def _project(kind: str, obj: dict) -> dict:
    out = _PROJECTORS.get(kind, _project_generic)(obj)
    return {k: v for k, v in out.items() if v is not None}


# --- tools -------------------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """Every cluster this machine can address, derived from kubeconfig. Call this first.

    `product` and `env` from a row here are what every other tool expects. A target being listed
    means a kubeconfig entry exists — not that the read-only identity has been bootstrapped in it
    (run scripts/k8s/setup.sh to check that) and not that production is unlocked.
    """
    found = _targets()
    prod_ok = triage_policy.prod_allowed()
    rows = []
    for key in sorted(found):
        t = found[key]
        rows.append(
            {
                "product": t["product"],
                "env": t["env"],
                "cluster": t["cluster"],
                "project": t["project"],
                "identity": t["service_account"],
                "reachable": t["env"] != ENV_PROD or prod_ok,
            }
        )
    return {
        "targets": rows,
        "prod_allowed": prod_ok,
        "note": (
            "Production targets are refused unless `triage.prod: true` "
            "(workspace.config.local.yaml). Staging needs no opt-in."
        ),
    }


@mcp.tool()
def list_resources(
    product: str,
    env: str,
    kind: str,
    api_version: str = "v1",
    namespace: str | None = None,
    label_selector: str | None = None,
    field_selector: str | None = None,
    limit: int = DEFAULT_LIMIT,
    full: bool = False,
) -> dict:
    """List objects of any kind, including CRDs, in one cluster.

    `kind` is the Kubernetes kind ("Pod", "Deployment", "ApisixRoute"); `api_version` is its
    group/version ("v1", "apps/v1", "apisix.apache.org/v2"). Omit `namespace` to search the whole
    cluster. Results are projected to a compact shape unless `full=true`; when the result is cut
    short, `truncated` says so.
    """
    target = _resolve(product, env)
    dyn, _ = _client(target)
    limit = max(1, min(int(limit), MAX_LIMIT))
    try:
        res = dyn.resources.get(api_version=api_version, kind=kind)
    except Exception as exc:
        raise ValueError(
            f"no such resource kind={kind!r} api_version={api_version!r} in this cluster: {exc}"
        ) from exc
    got = res.get(
        namespace=namespace,
        label_selector=label_selector,
        field_selector=field_selector,
        limit=limit + 1,
        _request_timeout=REQUEST_TIMEOUT_S,
    )
    items = [i.to_dict() for i in (got.items or [])]
    truncated = len(items) > limit
    items = items[:limit]
    return _result(
        target,
        {
            "kind": kind,
            "api_version": api_version,
            "namespace": namespace or "(all)",
            "returned": len(items),
            "limit": limit,
            "truncated": truncated,
            "note": (
                f"more than {limit} objects match — raise `limit` (max {MAX_LIMIT}) or narrow "
                f"with namespace/label_selector"
            )
            if truncated
            else None,
            "items": items if full else [_project(kind, i) for i in items],
        },
    )


@mcp.tool()
def get_resource(
    product: str,
    env: str,
    kind: str,
    name: str,
    api_version: str = "v1",
    namespace: str | None = None,
) -> dict:
    """Fetch one object in full — the equivalent of `kubectl get <kind> <name> -o json`.

    Use this after `list_resources` has narrowed things down; it always returns the whole object,
    including spec and status.
    """
    target = _resolve(product, env)
    dyn, _ = _client(target)
    try:
        res = dyn.resources.get(api_version=api_version, kind=kind)
    except Exception as exc:
        raise ValueError(
            f"no such resource kind={kind!r} api_version={api_version!r} in this cluster: {exc}"
        ) from exc
    obj = res.get(name=name, namespace=namespace, _request_timeout=REQUEST_TIMEOUT_S)
    return _result(target, {"kind": kind, "api_version": api_version, "object": obj.to_dict()})


@mcp.tool()
def get_logs(
    product: str,
    env: str,
    namespace: str,
    pod: str,
    container: str | None = None,
    tail_lines: int = DEFAULT_TAIL_LINES,
    since_seconds: int | None = None,
    previous: bool = False,
) -> dict:
    """Read a pod's logs.

    `previous=true` reads the log of the PREVIOUS container instance — the only way to see why a
    pod that has already restarted died, which is usually the question worth asking. On a prod
    target the text is fingerprinted for egress redaction before it is returned.
    """
    target = _resolve(product, env)
    _, api = _client(target)
    tail_lines = max(1, min(int(tail_lines), MAX_TAIL_LINES))
    core = k8s_client.CoreV1Api(api)
    text = core.read_namespaced_pod_log(
        name=pod,
        namespace=namespace,
        container=container,
        tail_lines=tail_lines,
        since_seconds=since_seconds,
        previous=previous,
        timestamps=True,
        _request_timeout=REQUEST_TIMEOUT_S,
    )
    clipped = False
    if len(text.encode("utf-8", "replace")) > MAX_LOG_BYTES:
        text = text.encode("utf-8", "replace")[-MAX_LOG_BYTES:].decode("utf-8", "replace")
        clipped = True
    vaulted = 0
    if _vaults(target["env"]) and text:
        try:
            vaulted = pii_provenance.record_text(text)
        except Exception:
            pass  # provenance is a safety net; never fail a read because of it
    return _result(
        target,
        {
            "pod": pod,
            "namespace": namespace,
            "container": container,
            "previous": previous,
            "tail_lines": tail_lines,
            "clipped": clipped,
            "note": f"only the last {MAX_LOG_BYTES // 1024}KB is shown — narrow with "
            f"`since_seconds` or a smaller `tail_lines`"
            if clipped
            else None,
            "new_pii_digests": vaulted,
            "logs": text,
        },
    )


@mcp.tool()
def list_events(
    product: str,
    env: str,
    namespace: str | None = None,
    limit: int = DEFAULT_LIMIT,
    warnings_only: bool = False,
) -> dict:
    """Recent cluster events, newest first — the first place to look when a pod will not start,
    an image will not pull, a node is under pressure, or a probe is failing."""
    target = _resolve(product, env)
    dyn, _ = _client(target)
    limit = max(1, min(int(limit), MAX_LIMIT))
    res = dyn.resources.get(api_version="v1", kind="Event")
    got = res.get(
        namespace=namespace,
        field_selector="type=Warning" if warnings_only else None,
        limit=MAX_LIMIT,
        _request_timeout=REQUEST_TIMEOUT_S,
    )
    items = [_project_event(i.to_dict()) for i in (got.items or [])]
    items.sort(key=lambda e: e.get("last_seen") or "", reverse=True)
    truncated = len(items) > limit
    return _result(
        target,
        {
            "namespace": namespace or "(all)",
            "warnings_only": warnings_only,
            "returned": min(len(items), limit),
            "limit": limit,
            "truncated": truncated,
            "note": f"more events exist — raise `limit` (max {MAX_LIMIT})" if truncated else None,
            "events": items[:limit],
        },
    )


@mcp.tool()
def top_pods(product: str, env: str, namespace: str | None = None, limit: int = DEFAULT_LIMIT) -> dict:
    """Live CPU/memory per pod, from the metrics API — for "is it being throttled or OOM-pressured"."""
    target = _resolve(product, env)
    dyn, _ = _client(target)
    limit = max(1, min(int(limit), MAX_LIMIT))
    res = dyn.resources.get(api_version="metrics.k8s.io/v1beta1", kind="PodMetrics")
    got = res.get(namespace=namespace, _request_timeout=REQUEST_TIMEOUT_S)
    rows = []
    for i in got.items or []:
        o = i.to_dict()
        md = o.get("metadata") or {}
        for c in o.get("containers") or []:
            usage = c.get("usage") or {}
            rows.append(
                {
                    "pod": md.get("name"),
                    "namespace": md.get("namespace"),
                    "container": c.get("name"),
                    "cpu": usage.get("cpu"),
                    "memory": usage.get("memory"),
                }
            )
    truncated = len(rows) > limit
    return _result(
        target,
        {
            "namespace": namespace or "(all)",
            "returned": min(len(rows), limit),
            "truncated": truncated,
            "note": f"more pods exist — raise `limit` (max {MAX_LIMIT})" if truncated else None,
            "pods": rows[:limit],
        },
    )


@mcp.tool()
def top_nodes(product: str, env: str) -> dict:
    """Live CPU/memory per node — for "is the whole node starved" rather than one pod."""
    target = _resolve(product, env)
    dyn, _ = _client(target)
    res = dyn.resources.get(api_version="metrics.k8s.io/v1beta1", kind="NodeMetrics")
    got = res.get(_request_timeout=REQUEST_TIMEOUT_S)
    rows = []
    for i in got.items or []:
        o = i.to_dict()
        usage = o.get("usage") or {}
        rows.append(
            {
                "node": (o.get("metadata") or {}).get("name"),
                "cpu": usage.get("cpu"),
                "memory": usage.get("memory"),
            }
        )
    return _result(target, {"returned": len(rows), "nodes": rows})


@mcp.tool()
def disconnect() -> dict:
    """Drop every cached client, token and CA file. Call this when a triage job is finished."""
    n_clients, n_tokens = len(_clients), len(_tokens)
    for _, api in _clients.values():
        try:
            api.close()
        except Exception:
            pass
    _clients.clear()
    _tokens.clear()
    for path in _ca_files.values():
        try:
            os.unlink(path)
        except OSError:
            pass
    _ca_files.clear()
    return {
        "closed_clients": n_clients,
        "dropped_tokens": n_tokens,
        "note": "nothing is held until the next call",
    }


# --- command line ------------------------------------------------------------------------


def _selftest() -> int:
    """Deps, target derivation and policy — no cluster access, so it is safe anywhere."""
    ok = True

    def check(desc: str, cond: bool, detail: str = "") -> None:
        nonlocal ok
        print(f"  {'PASS' if cond else 'FAIL'}  {desc}{(' — ' + detail) if detail else ''}")
        ok = ok and cond

    check("kubeconfig readable", bool(_load_kubeconfig()), str(_kubeconfig_path()))
    found = _targets()
    check("at least one GKE target derived", bool(found), f"{len(found)} found")
    for key in sorted(found):
        t = found[key]
        print(f"        {key:<24} {t['cluster']:<18} {t['project']}")
    check(
        "every derived env is staging or prod",
        all(t["env"] in ENVS for t in found.values()),
    )
    check("triage_policy importable", hasattr(triage_policy, "assert_prod_allowed"))
    check("pii_provenance importable", pii_provenance is not None)
    try:
        _resolve(None, None)
        check("missing product/env is rejected", False)
    except ValueError:
        check("missing product/env is rejected", True)
    try:
        _resolve("agent", "production")
        check("an unknown env is rejected", False)
    except ValueError:
        check("an unknown env is rejected", True)
    print(f"  triage.prod = {triage_policy.prod_allowed()}")
    return 0 if ok else 1


def _verify(env: str) -> int:
    """Live acceptance run: read something, and confirm the identity cannot read a Secret."""
    found = {k: v for k, v in _targets().items() if v["env"] == env}
    if not found:
        print(f"no target with env={env}")
        return 1
    rc = 0
    for key, t in sorted(found.items()):
        print(f"\n  {key}  ({t['cluster']})")
        try:
            dyn, api = _client(t)
            pods = dyn.resources.get(api_version="v1", kind="Pod").get(limit=1, _request_timeout=20)
            print(f"    PASS  read pods ({len(pods.items or [])} returned)")
        except PermissionError as exc:
            # A cluster nobody has bootstrapped yet is not a failure of this server — it is the
            # fail-closed path working. Say what to run instead of reporting a fault.
            missing = "NOT_FOUND" in str(exc) or "does not exist" in str(exc)
            if missing:
                print(f"    SKIP  not bootstrapped — run: scripts/k8s/bootstrap-sa.sh --context {t['context_alias']}")
            else:
                print(f"    FAIL  {str(exc).splitlines()[0][:140]}")
                rc = 1
            continue
        except Exception as exc:
            print(f"    FAIL  read pods — {str(exc).splitlines()[0][:140]}")
            rc = 1
            continue
        try:
            dyn.resources.get(api_version="v1", kind="Secret").get(limit=1, _request_timeout=20)
            print("    FAIL  reading Secrets was ALLOWED — the identity is over-privileged")
            rc = 1
        except Exception as exc:
            if "403" in str(exc) or "orbidden" in str(exc):
                print("    PASS  Secrets refused by the API server (403)")
            else:
                print(f"    FAIL  Secrets refused for the WRONG reason — {str(exc).splitlines()[0][:120]}")
                rc = 1
    return rc


if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv and argv[0] == "--selftest":
        sys.exit(_selftest())
    if argv and argv[0] == "--verify":
        sys.exit(_verify(argv[1] if len(argv) > 1 else ENV_STAGING))
    if argv and argv[0] == "--targets":
        print(json.dumps(_targets(), indent=2))
        sys.exit(0)
    mcp.run()
