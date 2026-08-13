# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.2,<2",
# ]
# # The <2 bound is load-bearing: mcp 2.0 removed `mcp.server.fastmcp`, so an unbounded `mcp>=1.2`
# # resolves to a release this file cannot import. It only looks fine on a machine whose uv cache
# # still holds a 1.x environment.
# ///
"""monitoring-triage — on-demand, READ-ONLY MCP over GCP Cloud Monitoring (STAGING + PROD).

The sibling servers answer from things WE instrument. This one answers from what GCP measures on
our behalf and we cannot instrument: the internals of a managed service. When a trace proves the
time is not being spent inside our own code, this is the server that says where it went.

    SigNoz / telemetry-triage   spans and logs our services emit
    monitoring-triage           the managed resource underneath them — Memorystore CPU, Cloud SQL
                                connections, GKE node pressure, load-balancer latency

Five properties, each load-bearing:

  1. Typed read tools only. There is no passthrough tool and no caller-supplied URL: every request
     is a GET built here from a fixed host and a fixed path template. A write verb is unreachable
     because none is ever constructed.
  2. The identity is the same read-only service account the Kubernetes server uses —
     `k8s-triage@<project>.iam.gserviceaccount.com`, obtained by IMPERSONATION so no long-lived
     key exists on disk — carrying `roles/monitoring.viewer` in addition to its cluster role.
     Read-only is therefore enforced by GOOGLE: a write comes back 403 from the API before it is
     matched against a resource, not from a check in this file. `scripts/k8s/bootstrap-sa.sh`
     grants both roles and proves the property. See docs/adr/0007 and docs/adr/0010.
  3. Targets are CONFIGURED, not derived. A Cloud Monitoring scope is a GCP project, and a project
     is not discoverable from a kubeconfig the way a GKE cluster is, so `monitoring.targets` in
     workspace.config.yaml maps `<product>/<env>` to a project id. The `<env>` half is what the
     production gate reads (`scripts/lib/triage_policy.py` -> `triage.prod`). Staging needs no
     opt-in; it is not the production boundary.
  4. The correctness contract is enforced here, not left to the caller. A Cloud Monitoring query
     that names the wrong aligner or a naive timestamp does not fail — it returns a plausible
     number for the wrong question. So: the aligner is DERIVED from the metric's own descriptor,
     an ambiguous timestamp is REFUSED rather than guessed, and every result echoes the UTC window
     and the aligner that actually produced it.
  5. No PII vault. A time series carries numbers and resource labels, never personal data, so
     unlike pod logs there is nothing here to fingerprint for egress redaction. Results say so
     rather than leaving a reader to wonder.

  uv run scripts/monitoring/monitoring_triage_mcp.py --selftest         # deps, targets, policy, source scan
  uv run scripts/monitoring/monitoring_triage_mcp.py --verify agent/staging   # live read-only acceptance run
"""

from __future__ import annotations

import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import triage_policy  # noqa: E402

from mcp.server.fastmcp import FastMCP  # noqa: E402

# --- configuration -----------------------------------------------------------------------

SA_NAME = "k8s-triage"  # docs/adr/0010: one read-only identity per project, shared with k8s-triage
TOKEN_TTL_S = 45 * 60  # impersonated access tokens last an hour; refresh well before the edge
REQUEST_TIMEOUT_S = 30
API_HOST = "https://monitoring.googleapis.com"
API_VERSION = "v3"

ENV_PROD = "prod"
ENV_STAGING = "staging"

# A Cloud Monitoring page can be enormous. Every tool bounds its own output and REPORTS what it
# dropped, so a truncated answer can never read as a complete one.
MAX_SERIES = 20
MAX_POINTS = 1500
MAX_DESCRIPTORS = 200
# Cloud Monitoring paginates a timeSeries read by POINTS as well as by series, so a whole window
# needs several round-trips. Bounded, and hitting the bound is reported rather than passed off as
# the complete answer.
MAX_PAGES = 12

# Aligning a gauge with the mean is the right default for a level (memory used, connection count)
# and the WRONG one for a saturation question: a node pinned at its ceiling for ten minutes of a
# one-hour window averages out to nothing. Anything whose name reads as a ratio or a utilization
# is therefore aligned with the maximum instead.
_SATURATION_RE = re.compile(r"utilization|/usage$|ratio|_used_percent|cpu/usage_time", re.I)

CATALOG_PATH = Path(__file__).resolve().parent / "metric-catalog.json"

mcp = FastMCP("monitoring-triage")

_tokens: dict[str, tuple[float, str]] = {}
_descriptor_cache: dict[str, dict] = {}


# --- targets -----------------------------------------------------------------------------


def _config_files() -> list[Path]:
    """Local-first, matching every other reader of this config."""
    root = triage_policy.root()
    return [root / "workspace.config.local.yaml", root / "workspace.config.yaml"]


def _parse_targets(path: Path) -> dict[str, str]:
    """Read `monitoring.targets` — a flat `<product>/<env>: <project-id>` mapping.

    Deliberately hand-parsed rather than pulling in PyYAML: the block is two levels deep and one
    value type, and a triage server that cannot start because a dependency failed to resolve is
    worse than one that understands a narrow slice of YAML. Anything more elaborate than this
    shape belongs in the example config as prose, not in the live file (docs/adr/0006).
    """
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    in_monitoring = False
    in_targets = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", line):  # a new top-level section
            in_monitoring = line.startswith("monitoring:")
            in_targets = False
            continue
        if not in_monitoring:
            continue
        if re.match(r"^\s{1,2}targets:\s*$", line):
            in_targets = True
            continue
        if re.match(r"^\s{1,2}[A-Za-z_]", line):  # another key at the monitoring level
            in_targets = False
            continue
        if in_targets:
            m = re.match(r"^\s{3,6}([A-Za-z0-9_.-]+/[A-Za-z0-9_-]+):\s*([A-Za-z0-9_.-]+)\s*$", line)
            if m:
                out[m.group(1)] = m.group(2)
    return out


def _targets() -> dict[str, dict]:
    """{"<product>/<env>": {...}} for every declared Cloud Monitoring scope."""
    merged: dict[str, str] = {}
    for path in reversed(_config_files()):  # shared first, local wins
        merged.update(_parse_targets(path))

    out: dict[str, dict] = {}
    for name, project in merged.items():
        product, _, env = name.partition("/")
        if env not in (ENV_PROD, ENV_STAGING):
            continue  # an unnamed environment is an error rather than a guess
        out[name] = {
            "name": name,
            "product": product,
            "env": env,
            "project": project,
            "service_account": f"{SA_NAME}@{project}.iam.gserviceaccount.com",
        }
    return out


def _resolve(target: str | None) -> dict:
    known = _targets()
    if not known:
        raise ValueError(
            "no Cloud Monitoring targets are declared. Add a `monitoring.targets` block to "
            "workspace.config.yaml mapping `<product>/<env>` to a GCP project id — see "
            "workspace.config.example.yaml."
        )
    if target:
        hit = known.get(target.strip())
        if hit is None:
            raise ValueError(f"unknown target {target!r}; declared: {' | '.join(sorted(known))}")
        return hit
    staging = [t for n, t in sorted(known.items()) if t["env"] == ENV_STAGING]
    if len(staging) == 1:
        return staging[0]
    raise ValueError(
        f"target is required — this workspace declares {' | '.join(sorted(known))}. "
        "There is no default for production, and no single staging scope to fall back on."
    )


def _assert_allowed(target: dict) -> None:
    """The production gate, checked before a token is minted or a socket is opened."""
    if target["env"] != ENV_PROD:
        return
    # The shared message, so every triage server refuses production in the same words.
    triage_policy.assert_prod_allowed(
        f"PRODUCTION Cloud Monitoring triage ({target['name']}, project {target['project']})"
    )


# --- transport ---------------------------------------------------------------------------


def _token(project: str, service_account: str) -> str:
    """A short-lived access token for the read-only identity, via GCP impersonation.

    No key file exists: the caller's own credential is used to mint a token FOR the service
    account, which requires roles/iam.serviceAccountTokenCreator on it.
    """
    hit = _tokens.get(project)
    if hit and hit[0] > time.time():
        return hit[1]
    proc = subprocess.run(
        ["gcloud", "auth", "print-access-token", f"--impersonate-service-account={service_account}"],
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
            f"Run: scripts/k8s/setup.sh   (it diagnoses this shared identity — docs/adr/0010)"
        )
    _tokens[project] = (time.time() + TOKEN_TTL_S, token)
    return token


def _get(target: dict, path: str, params: dict | None = None) -> dict:
    """The ONLY request this server makes. GET, to a host and path built here.

    There is no method parameter and no caller-supplied URL by design: read-only is a property of
    the code shape, not of a runtime check that a later edit could forget.
    """
    _assert_allowed(target)
    token = _token(target["project"], target["service_account"])
    url = f"{API_HOST}/{API_VERSION}/projects/{urllib.parse.quote(target['project'])}/{path}"
    if params:
        pairs = []
        for k, v in params.items():
            if v is None:
                continue
            if isinstance(v, (list, tuple)):
                pairs.extend((k, str(item)) for item in v)
            else:
                pairs.append((k, str(v)))
        url = f"{url}?{urllib.parse.urlencode(pairs)}"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8")[:600]
        except Exception:
            pass
        detail = ""
        try:
            detail = json.loads(body).get("error", {}).get("message", "")
        except Exception:
            detail = body
        if exc.code == 403:
            raise PermissionError(
                f"Cloud Monitoring refused this read for {target['service_account']}: {detail}\n"
                f"The identity needs roles/monitoring.viewer on project {target['project']} — "
                f"grant it with scripts/k8s/bootstrap-sa.sh (see docs/adr/0010)."
            ) from None
        raise RuntimeError(f"Cloud Monitoring returned HTTP {exc.code}: {detail}") from None


# --- the correctness contract -------------------------------------------------------------


def _instant(value: str | int | float, field: str) -> datetime:
    """Parse a caller-supplied time, or REFUSE it.

    A naive timestamp is the failure this rejects. Read as local time it silently shifts the whole
    window (seven hours, under Asia/Bangkok) and returns a confident answer about the wrong hours.
    So epoch milliseconds, or an ISO-8601 string that names its offset — nothing else.
    """
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return datetime.fromtimestamp(float(value) / 1000.0, tz=timezone.utc)
    text = str(value).strip()
    if re.fullmatch(r"-?\d{10,16}", text):
        return datetime.fromtimestamp(int(text) / 1000.0, tz=timezone.utc)
    iso = text.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(iso)
    except ValueError:
        raise ValueError(
            f"{field}={value!r} is not a time this server will guess at. Pass epoch MILLISECONDS "
            f"(1786352009000) or an ISO-8601 string carrying its offset "
            f"('2026-08-10T22:00:00+07:00', '2026-08-10T15:00:00Z')."
        ) from None
    if parsed.tzinfo is None:
        raise ValueError(
            f"{field}={value!r} names no timezone, and this server will not assume one — read as "
            f"local time it would shift the window and answer about the wrong hours. Add an "
            f"offset ('+07:00') or a 'Z', or pass epoch milliseconds."
        )
    return parsed.astimezone(timezone.utc)


def _alignment_period(window_s: float, requested: int | None) -> int:
    """Seconds per aligned point. Bounded so one call cannot return a million points."""
    if requested:
        return max(60, int(requested))
    target = window_s / 200.0
    return max(60, int(math.ceil(target / 60.0) * 60))


def _descriptor_path(metric_type: str) -> str:
    """The API path for one metric descriptor.

    `safe='/'` is load-bearing: a metric type IS a slash-separated path
    (`redis.googleapis.com/clients/blocked`) and the endpoint matches it as one. Percent-encoding
    those slashes returns `Invalid metric name: ...%2Fclients%2Fblocked` — an HTTP 400 naming a
    metric nobody asked for. Kept as its own function so --selftest can assert the shape without
    a network call; the encoded form shipped once and no offline check caught it.
    """
    return f"metricDescriptors/{urllib.parse.quote(metric_type, safe='/')}"


def _descriptor(target: dict, metric_type: str) -> dict:
    key = f"{target['project']}::{metric_type}"
    hit = _descriptor_cache.get(key)
    if hit is None:
        hit = _get(target, _descriptor_path(metric_type))
        _descriptor_cache[key] = hit
    return hit


def _aligner(descriptor: dict, requested: str | None) -> tuple[str, str]:
    """Choose the aligner from the metric's OWN descriptor, and say why.

    Left to a caller this is the quietest way to be wrong: ALIGN_MEAN on a cumulative counter
    reports a meaningless running total, and ALIGN_RATE on a gauge reports the slope of a level.
    """
    if requested:
        return requested, "caller-specified"
    kind = (descriptor.get("metricKind") or "").upper()
    vtype = (descriptor.get("valueType") or "").upper()
    mtype = descriptor.get("type") or ""
    if vtype == "DISTRIBUTION":
        return "ALIGN_PERCENTILE_99", f"{kind} DISTRIBUTION — a tail question, not a mean one"
    if kind in ("DELTA", "CUMULATIVE"):
        return "ALIGN_RATE", f"{kind} counter — a rate is the only meaningful reading"
    if _SATURATION_RE.search(mtype):
        return "ALIGN_MAX", "a saturation metric — the mean hides a ceiling that was hit"
    return "ALIGN_MEAN", f"{kind} {vtype} level"


def _result(target: dict, payload: dict) -> dict:
    """Stamp every result with what a reader must not have to remember."""
    return {
        "target": target["name"],
        "env": target["env"],
        "project": target["project"],
        "pii_vaulted": False,  # a time series carries no personal data — nothing to fingerprint
        **payload,
    }


# --- tools -------------------------------------------------------------------------------


@mcp.tool()
def list_targets() -> dict:
    """Every Cloud Monitoring scope this workspace declares, and whether it can be read now.

    Read this before assuming a project is unreachable: production is gated per-machine and a
    declared target may be refused until `triage.prod` is set."""
    known = _targets()
    prod_ok, source = triage_policy.resolve("prod")
    return {
        "targets": [
            {
                "target": t["name"],
                "product": t["product"],
                "env": t["env"],
                "project": t["project"],
                "service_account": t["service_account"],
                "readable_now": t["env"] != ENV_PROD or prod_ok,
            }
            for t in sorted(known.values(), key=lambda x: x["name"])
        ],
        "prod_allowed": prod_ok,
        "prod_policy_source": source,
        "note": (
            "No target declared? Add `monitoring.targets` to workspace.config.yaml. "
            "A prod target reading readable_now=false needs `triage.prod: true` in "
            "workspace.config.local.yaml."
        ),
    }


@mcp.tool()
def list_monitored_resources(target: str | None = None, contains: str | None = None) -> dict:
    """What KINDS of resource this project actually monitors (`redis_instance`, `cloudsql_database`,
    `k8s_node`, `gce_instance`, ...), with the labels each one is addressed by.

    This is the discovery step: it answers "what is even here" without a hardcoded list, so a
    service nobody anticipated is still reachable. Narrow with `contains`."""
    t = _resolve(target)
    page = _get(t, "monitoredResourceDescriptors", {"pageSize": MAX_DESCRIPTORS})
    items = page.get("resourceDescriptors", [])
    if contains:
        needle = contains.lower()
        items = [
            d
            for d in items
            if needle in (d.get("type") or "").lower()
            or needle in (d.get("displayName") or "").lower()
        ]
    shown = items[:MAX_DESCRIPTORS]
    return _result(
        t,
        {
            "resource_types": [
                {
                    "type": d.get("type"),
                    "display_name": d.get("displayName"),
                    "labels": [lb.get("key") for lb in d.get("labels", [])],
                }
                for d in shown
            ],
            "returned": len(shown),
            "truncated": len(items) > len(shown),
        },
    )


@mcp.tool()
def list_metrics(prefix: str, target: str | None = None, contains: str | None = None) -> dict:
    """Every metric under a prefix, with the metricKind/valueType that decide how it must be read.

    `prefix` is a metric-type prefix, not a resource type — `redis.googleapis.com`,
    `cloudsql.googleapis.com/database`, `kubernetes.io/node`. Pair it with
    `list_monitored_resources` when you do not yet know which prefix a resource publishes under."""
    t = _resolve(target)
    page = _get(
        t,
        "metricDescriptors",
        {"filter": f'metric.type = starts_with("{prefix}")', "pageSize": MAX_DESCRIPTORS},
    )
    items = page.get("metricDescriptors", [])
    if contains:
        needle = contains.lower()
        items = [d for d in items if needle in (d.get("type") or "").lower()]
    shown = items[:MAX_DESCRIPTORS]
    return _result(
        t,
        {
            "prefix": prefix,
            "metrics": [
                {
                    "type": d.get("type"),
                    "kind": d.get("metricKind"),
                    "value_type": d.get("valueType"),
                    "unit": d.get("unit"),
                    "description": (d.get("description") or "")[:200],
                }
                for d in shown
            ],
            "returned": len(shown),
            "truncated": len(items) > len(shown),
        },
    )


@mcp.tool()
def curated_metrics(resource_type: str | None = None) -> dict:
    """The short list worth reading FIRST for a resource type we actually run, and what each one
    answers. Judgement the API cannot supply: `list_metrics` says what exists, this says what
    matters. Omit `resource_type` to see which types are curated."""
    try:
        catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"error": f"could not read {CATALOG_PATH.name}: {exc}", "curated": []}
    if not resource_type:
        return {
            "curated_resource_types": sorted(catalog),
            "note": "Anything not listed here is still reachable via list_metrics — the catalog is "
            "a shortcut for the resources we run, never the limit of what can be read.",
        }
    entry = catalog.get(resource_type)
    if entry is None:
        return {
            "resource_type": resource_type,
            "curated": [],
            "curated_resource_types": sorted(catalog),
            "note": "Not curated. Use list_monitored_resources + list_metrics to discover it.",
        }
    return {"resource_type": resource_type, **entry}


@mcp.tool()
def read_timeseries(
    metric_type: str,
    start: str,
    end: str,
    target: str | None = None,
    resource_filter: str | None = None,
    aligner: str | None = None,
    alignment_period_s: int | None = None,
    group_by: list[str] | None = None,
    reducer: str | None = None,
) -> dict:
    """Read one metric over a window. The workhorse.

    `start`/`end` take epoch MILLISECONDS or an ISO-8601 string that names its offset; an
    ambiguous timestamp is refused rather than guessed. `resource_filter` is an optional extra
    clause ANDed onto the metric filter, e.g. `resource.labels.instance_id = "ofb-prod"`.

    The aligner is derived from the metric's own descriptor unless you name one, and the result
    echoes the window, the aligner and the alignment period that actually produced the numbers —
    read them before quoting a figure."""
    t = _resolve(target)
    t0, t1 = _instant(start, "start"), _instant(end, "end")
    if t1 <= t0:
        raise ValueError(f"end ({t1.isoformat()}) must be after start ({t0.isoformat()})")
    window_s = (t1 - t0).total_seconds()

    descriptor = _descriptor(t, metric_type)
    chosen, why = _aligner(descriptor, aligner)
    period = _alignment_period(window_s, alignment_period_s)

    parts = [f'metric.type = "{metric_type}"']
    if resource_filter:
        parts.append(f"({resource_filter})")
    params = {
        "filter": " AND ".join(parts),
        "interval.startTime": t0.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "interval.endTime": t1.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "aggregation.alignmentPeriod": f"{period}s",
        "aggregation.perSeriesAligner": chosen,
        "view": "FULL",
    }
    if group_by:
        params["aggregation.groupByFields"] = list(group_by)
        params["aggregation.crossSeriesReducer"] = reducer or (
            "REDUCE_MAX" if chosen == "ALIGN_MAX" else "REDUCE_MEAN"
        )

    series, pages, dropped_pages = _timeseries_paged(t, params)

    shaped = []
    for s in series:
        pts = s.get("points", [])
        trimmed = pts[:MAX_POINTS]
        shaped.append(
            {
                "resource": s.get("resource", {}).get("labels", {}),
                "metric_labels": s.get("metric", {}).get("labels", {}),
                "unit": s.get("unit") or descriptor.get("unit"),
                "points": [
                    {
                        "t": p.get("interval", {}).get("endTime"),
                        "v": _point_value(p.get("value", {})),
                    }
                    for p in reversed(trimmed)  # oldest first — a series reads left to right
                ],
                "points_returned": len(trimmed),
                "points_truncated": len(pts) > len(trimmed),
            }
        )

    return _result(
        t,
        {
            "metric_type": metric_type,
            "metric_kind": descriptor.get("metricKind"),
            "value_type": descriptor.get("valueType"),
            "window_utc": {"start": t0.isoformat(), "end": t1.isoformat()},
            "aligner": chosen,
            "aligner_reason": why,
            "alignment_period_s": period,
            "cross_series_reducer": params.get("aggregation.crossSeriesReducer"),
            "filter": params["filter"],
            "series": shaped,
            "series_returned": len(shaped),
            "pages_fetched": pages,
            "series_truncated": dropped_pages,
            "note": (
                f"stopped at the {MAX_PAGES}-page cap — this window is INCOMPLETE; narrow it or "
                f"raise alignment_period_s"
            )
            if dropped_pages
            else None,
        },
    )


def _timeseries_paged(target: dict, params: dict) -> tuple[list, int, bool]:
    """Follow nextPageToken and merge the pages into whole series.

    Cloud Monitoring paginates a timeSeries read by POINTS as well as by series: a single series
    over a three-hour window comes back split across pages, each page carrying the same series
    identity and the next slice of points. Reading only the first page therefore returns a short,
    biased sample (the most recent minutes) that looks like a complete answer — the maximum of a
    fifth of a window is not the maximum of the window, and nothing in the response says so.

    Series identity is the resource + metric label pair, which is what makes two pages the same
    line on a chart.
    """
    merged: dict[tuple, dict] = {}
    token, pages = None, 0
    while pages < MAX_PAGES:
        page = _get(target, "timeSeries", {**params, "pageToken": token} if token else params)
        pages += 1
        for s in page.get("timeSeries", []):
            key = (
                tuple(sorted((s.get("resource", {}).get("labels") or {}).items())),
                tuple(sorted((s.get("metric", {}).get("labels") or {}).items())),
            )
            if key in merged:
                merged[key].setdefault("points", []).extend(s.get("points", []))
            elif len(merged) < MAX_SERIES:
                merged[key] = s
        token = page.get("nextPageToken") or None
        if not token:
            return list(merged.values()), pages, False
    return list(merged.values()), pages, True  # hit the page cap — reported, never implied complete


def _point_value(value: dict):
    """Cloud Monitoring types a point by which key is present; a distribution is summarized."""
    for key in ("doubleValue", "int64Value", "boolValue", "stringValue"):
        if key in value:
            v = value[key]
            return float(v) if key == "int64Value" else v
    dist = value.get("distributionValue")
    if dist is not None:
        return {
            "count": dist.get("count"),
            "mean": dist.get("mean"),
        }
    return None


@mcp.tool()
def disconnect() -> dict:
    """Drop every cached impersonation token and descriptor. The teardown step — run it when the
    investigation is done rather than leaving minted credentials in memory."""
    tokens, descriptors = len(_tokens), len(_descriptor_cache)
    _tokens.clear()
    _descriptor_cache.clear()
    return {
        "tokens_dropped": tokens,
        "descriptors_dropped": descriptors,
        "note": "Nothing was open — this server holds no sockets between calls.",
    }


# --- selftest / verify --------------------------------------------------------------------


def _selftest() -> int:
    """Deps, targets, policy wiring, and a source scan proving no write verb is constructed."""
    failures = 0

    def check(label: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"  {'ok' if ok else 'FAIL'}  {label}{('  — ' + detail) if detail else ''}")
        if not ok:
            failures += 1

    check("triage policy wired", hasattr(triage_policy, "assert_prod_allowed"))
    check("catalog present", CATALOG_PATH.exists(), str(CATALOG_PATH.name))
    try:
        json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
        check("catalog parses", True)
    except Exception as exc:
        check("catalog parses", False, str(exc))

    src = Path(__file__).read_text(encoding="utf-8")
    body = "\n".join(l for l in src.splitlines() if "selftest-allow" not in l)
    # Layer 3: the regression guard. Read-only here is a shape — one GET builder, no method
    # parameter — so the test is that no other verb is ever spelled.
    for verb in ("POST", "PUT", "PATCH", "DELETE"):
        check(
            f"no {verb} request constructed",
            f'method="{verb}"' not in body and f"method='{verb}'" not in body,
        )
    check("single request builder", body.count("urllib.request.urlopen") == 1)  # selftest-allow
    check("no passthrough tool exposed", "def execute" not in body)  # selftest-allow

    targets = _targets()
    if targets:
        print(f"  ..   targets declared — {' | '.join(sorted(targets))}")
        for name, t in sorted(targets.items()):
            check(f"target {name} names a project", bool(t["project"]), t["project"])
    else:
        print(
            "  ..   no targets declared — add a `monitoring.targets` block to "
            "workspace.config.yaml (see workspace.config.example.yaml)"
        )

    for bad in ("2026-08-10T22:00:00", "yesterday", ""):
        try:
            _instant(bad, "start")
            check(f"naive time {bad!r} refused", False)
        except ValueError:
            check(f"naive time {bad!r} refused", True)
    try:
        got = _instant("2026-08-10T22:00:00+07:00", "start")
        check("offset time accepted as UTC", got.hour == 15, got.isoformat())
    except Exception as exc:
        check("offset time accepted as UTC", False, str(exc))
    check("epoch ms accepted", _instant(1786352009000, "start").year == 2026)

    gauge = {"metricKind": "GAUGE", "valueType": "DOUBLE", "type": "redis.googleapis.com/stats/cpu_utilization"}
    counter = {"metricKind": "DELTA", "valueType": "INT64", "type": "redis.googleapis.com/commands/calls"}
    path = _descriptor_path("redis.googleapis.com/clients/blocked")
    check(
        "descriptor path keeps its slashes",
        path == "metricDescriptors/redis.googleapis.com/clients/blocked",
        path,
    )
    check("descriptor path percent-encodes nothing else", "%" not in path)
    check("saturation gauge aligns MAX", _aligner(gauge, None)[0] == "ALIGN_MAX")
    check("counter aligns RATE", _aligner(counter, None)[0] == "ALIGN_RATE")
    check("caller override honoured", _aligner(gauge, "ALIGN_MIN")[0] == "ALIGN_MIN")

    prod_ok, source = triage_policy.resolve("prod")
    print(f"  ..   triage.prod = {str(prod_ok).lower()} ({source})")
    print(f"\n{'FAILED' if failures else 'PASS'} — {failures} failure(s)")
    return 1 if failures else 0


def _verify(name: str) -> int:
    """A live, read-only acceptance run against one target."""
    try:
        t = _resolve(name or None)
    except ValueError as exc:
        print(f"FAIL  {exc}")
        return 1
    print(f"target    {t['name']}  (project {t['project']}, env {t['env']})")
    print(f"identity  {t['service_account']}")
    try:
        _assert_allowed(t)
    except Exception as exc:
        print(f"FAIL  {exc}")
        return 1
    try:
        res = list_monitored_resources(t["name"])
        kinds = [r["type"] for r in res["resource_types"]]
        print(f"ok    {len(kinds)} monitored resource type(s); e.g. {', '.join(kinds[:5])}")
    except Exception as exc:
        print(f"FAIL  could not list monitored resources: {exc}")
        return 1
    now_ms = int(time.time() * 1000)
    for probe in ("redis.googleapis.com", "compute.googleapis.com/instance/cpu"):
        try:
            found = list_metrics(probe, t["name"])["metrics"]
            if not found:
                print(f"..    no metrics under {probe} in this project")
                continue
            first = found[0]["type"]
            out = read_timeseries(first, now_ms - 3600_000, now_ms, t["name"])
            print(
                f"ok    read {first} — {out['series_returned']} series, "
                f"aligner {out['aligner']} ({out['aligner_reason']}), "
                f"window {out['window_utc']['start']} .. {out['window_utc']['end']}"
            )
            print("\nPASS — read-only acceptance run complete")
            return 0
        except Exception as exc:
            print(f"..    {probe}: {exc}")
    print("FAIL  no metric could be read on this target")
    return 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    if "--verify" in sys.argv:
        idx = sys.argv.index("--verify")
        raise SystemExit(_verify(sys.argv[idx + 1] if len(sys.argv) > idx + 1 else ""))
    mcp.run()  # stdio transport
