#!/usr/bin/env python3
"""Compare a candidate load-test run against N base-branch runs of the same scenario.

Reads k6 `--summary-export` JSON (or any {"metrics": {name: {...}}} shape). Emits the
verdict, the per-metric table, and the markdown to post — as JSON on stdout.

The whole point is that the numbers are decided here, not by a model reading a report:
same inputs, same verdict, every run.

  compare.py --base base1.json --base base2.json --candidate cand.json \
             --tolerance-pct 10 --noise-ceiling-multiple 2 \
             [--metric 'checkout_latency:p(99):lower' ...]

Exit codes: 0 pass · 1 fail · 2 unavailable · 3 bad input.
"""
import argparse
import json
import statistics
import sys

# Tracked by default. A trend metric contributes its p(95) and p(99); a rate/counter
# contributes its value. `lower` = smaller is better (latency, errors); `higher` = the reverse.
DEFAULT_TREND_STATS = ('p(95)', 'p(99)')
HIGHER_IS_BETTER = ('iterations', 'http_reqs', 'data_received')


def die(msg):
    """Bad input exits 3 — never 1, which the caller reads as a real regression."""
    print(msg, file=sys.stderr)
    sys.exit(3)


def load(path):
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        die(f'compare.py: cannot read {path}: {exc}')
    metrics = doc.get('metrics') if isinstance(doc, dict) else None
    if not isinstance(metrics, dict):
        die(f'compare.py: {path} has no "metrics" object — not a k6 summary export')
    return metrics


def series(metrics):
    """Flatten one run into {(metric, stat): value}."""
    out = {}
    for name, body in metrics.items():
        if not isinstance(body, dict):
            continue
        for stat in DEFAULT_TREND_STATS:
            if isinstance(body.get(stat), (int, float)):
                out[(name, stat)] = float(body[stat])
        for stat in ('rate', 'value', 'count'):
            if isinstance(body.get(stat), (int, float)):
                out[(name, stat)] = float(body[stat])
                break
    return out


def direction(name, override):
    if (name, None) in override:
        return override[(name, None)]
    return 'higher' if any(name.startswith(p) for p in HIGHER_IS_BETTER) else 'lower'


def pct(delta, ref):
    return (delta / ref) * 100.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', action='append', required=True, metavar='FILE')
    ap.add_argument('--candidate', required=True, metavar='FILE')
    ap.add_argument('--tolerance-pct', type=float, default=10.0)
    ap.add_argument('--noise-ceiling-multiple', type=float, default=2.0)
    ap.add_argument('--metric', action='append', default=[], metavar='NAME:STAT:DIR',
                    help='force-track a metric, e.g. search_latency:p(99):lower')
    args = ap.parse_args()

    if len(args.base) < 2:
        die('compare.py: need at least 2 --base runs to measure a noise floor')

    bases = [series(load(p)) for p in args.base]
    cand = series(load(args.candidate))

    forced, dir_override = [], {}
    for spec in args.metric:
        parts = spec.split(':')
        if len(parts) != 3:
            die(f'compare.py: --metric wants NAME:STAT:DIR, got {spec!r}')
        name, stat, d = parts
        if d not in ('lower', 'higher'):
            die(f'compare.py: --metric DIR must be lower|higher, got {d!r}')
        forced.append((name, stat))
        dir_override[(name, None)] = d

    keys = sorted(set(forced) | (set(cand) & set.intersection(*(set(b) for b in bases))),
                  key=lambda k: (k[0], k[1]))

    ceiling = args.tolerance_pct * args.noise_ceiling_multiple
    rows, skipped, too_noisy, regressed = [], [], [], []

    for key in keys:
        name, stat = key
        vals = [b[key] for b in bases if key in b]
        if len(vals) < 2 or key not in cand:
            skipped.append(f'{name} {stat} (missing from a run)')
            continue
        ref = statistics.median(vals)
        better = direction(name, dir_override)
        raw = cand[key] - ref
        if ref == 0:
            # A perfect base (0 errors is the usual one) has no percentage to take, and
            # skipping it would hide the single regression a load gate most needs to catch:
            # an error rate that was zero and no longer is. Judge it on the raw move instead.
            if raw == 0:
                delta, noise, threshold = 0.0, 0.0, args.tolerance_pct
            else:
                worse = raw > 0 if better == 'lower' else raw < 0
                if not worse:
                    skipped.append(f'{name} {stat} (base 0, candidate improved)')
                    continue
                regressed.append(f'{name} {stat} 0 → {cand[key]:g} (base was perfect)')
                rows.append({'metric': name, 'stat': stat, 'better': better,
                             'base': ref, 'candidate': cand[key], 'delta_pct': None,
                             'noise_pct': 0.0, 'threshold_pct': 0.0, 'verdict': 'fail'})
                continue
        else:
            noise = max(abs(pct(v - ref, ref)) for v in vals)
            delta = pct(raw if better == 'lower' else -raw, ref)
            threshold = max(args.tolerance_pct, noise)
        if noise > ceiling:
            too_noisy.append(f'{name} {stat} (noise {noise:.1f}% > ceiling {ceiling:.1f}%)')
            verdict = 'unavailable'
        elif delta > threshold:
            regressed.append(f'{name} {stat} +{delta:.1f}% (threshold {threshold:.1f}%)')
            verdict = 'fail'
        else:
            verdict = 'pass'
        rows.append({'metric': name, 'stat': stat, 'better': better,
                     'base': ref, 'candidate': cand[key], 'delta_pct': round(delta, 2),
                     'noise_pct': round(noise, 2), 'threshold_pct': round(threshold, 2),
                     'verdict': verdict})

    if not rows:
        verdict = 'unavailable'
    elif too_noisy:
        verdict = 'unavailable'
    elif regressed:
        verdict = 'fail'
    else:
        verdict = 'pass'

    mark = {'pass': '✅', 'fail': '❌', 'unavailable': '⚠️'}
    lines = ['| Metric | Base | Candidate | Δ | Noise floor | Threshold | |',
             '|---|---:|---:|---:|---:|---:|:--:|']
    for r in rows:
        arrow = '↓ better' if r['better'] == 'lower' else '↑ better'
        delta = 'n/a (base 0)' if r['delta_pct'] is None else f"{r['delta_pct']:+.1f}%"
        lines.append(
            f"| `{r['metric']}` {r['stat']} ({arrow}) | {r['base']:.2f} | {r['candidate']:.2f} "
            f"| {delta} | {r['noise_pct']:.1f}% | {r['threshold_pct']:.1f}% "
            f"| {mark[r['verdict']]} |")
    if skipped:
        lines.append('')
        lines.append(f"Not compared: {'; '.join(skipped)}.")

    json.dump({'verdict': verdict, 'base_runs': len(bases),
               'tolerance_pct': args.tolerance_pct, 'noise_ceiling_pct': ceiling,
               'regressed': regressed, 'too_noisy': too_noisy, 'skipped': skipped,
               'metrics': rows, 'markdown': '\n'.join(lines)},
              sys.stdout, indent=2)
    sys.stdout.write('\n')
    sys.exit({'pass': 0, 'fail': 1, 'unavailable': 2}[verdict])


if __name__ == '__main__':
    main()
