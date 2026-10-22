#!/usr/bin/env python3
"""Brightness trace analysis (ALVRClient/BrightTrace.swift, -ALVRBrightTrace YES or the Diagnostics toggle).

Reads Documents/diag/brighttrace-*.jsonl (one record per presented frame), or a log holding the forwarded lines (the
PC streamer.log, or a simulator console log): the 1 Hz `BRIGHTTRACE t_ms=...` summaries and the
`BRIGHTTRACE JUMP ... before={...} after={...}` records. Prints frame counts, the output levels (clusters of the
per-frame output-vs-input transfer exponent), each jump with the recorded fields that changed at that frame, and a
one-line verdict.

Usage: python3 tools/brighttrace.py <brighttrace.jsonl | streamer.log> [...]
Python 3.9, stdlib only. Tests: tools/tests/test_brighttrace.py.
"""
import json
import math
import re
import sys

# Mirrors of BrightTrace.swift.
JUMP_EXPONENT_DELTA = 0.08
JUMP_INPUT_STABLE_RATIO = 0.03
LEVEL_GAP = 0.05
LUMA_FLOOR = 1e-4
# Clusters holding fewer than this share of the exponents are reported but not counted as output levels.
MIN_LEVEL_SHARE = 0.02
# Totals taken from the 1 Hz summary lines.
SUMMARY_KEYS = ("frames", "new", "repeat", "levels", "jumps")


def exponent(inp, out):
    """Least-squares slope and intercept of log(out) on log(in), values paired by rank (both sorted)."""
    if inp is None or out is None or len(inp) != len(out):
        return None
    pairs = [(a, b) for a, b in zip(sorted(inp), sorted(out)) if a > LUMA_FLOOR and b > LUMA_FLOOR]
    if len(pairs) < 2:
        return None
    xs, ys = [math.log(a) for a, _ in pairs], [math.log(b) for _, b in pairs]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx <= 1e-12:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return slope, my - slope * mx


def eye_exponent(eye):
    if eye.get("exp") is not None:
        return eye["exp"]
    fit = exponent(eye.get("in"), eye.get("out"))
    return fit[0] if fit else None


def levels(values, gap=LEVEL_GAP):
    """Clusters of 1-D values split at gaps wider than `gap`: list of (centre, count)."""
    clusters = []
    for v in sorted(values):
        if clusters and v - clusters[-1][-1] <= gap:
            clusters[-1].append(v)
        else:
            clusters.append([v])
    return [(sum(c) / len(c), len(c)) for c in clusters]


def load(paths):
    """Records (jsonl lines and the records inside JUMP lines, deduplicated by seq) and summary dicts."""
    records, summaries, seen = [], [], set()

    def add(record):
        key = record.get("seq")
        if key not in seen:
            seen.add(key)
            records.append(record)

    decoder = json.JSONDecoder()
    for path in paths:
        with open(path, errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        add(json.loads(line))
                    except ValueError:
                        pass
                elif "BRIGHTTRACE JUMP" in line:
                    for tag in ("before=", "after="):
                        at = line.find(" " + tag)
                        if at >= 0:
                            try:
                                add(decoder.raw_decode(line, at + len(tag) + 1)[0])
                            except ValueError:
                                pass
                elif "BRIGHTTRACE t_ms=" in line:
                    summaries.append(dict(re.findall(r"(\w+)=(\S+)", line[line.index("BRIGHTTRACE"):])))
    records.sort(key=lambda r: r.get("seq", 0))
    return records, summaries


def is_new(record, previous):
    return previous is None or record.get("ts_ns") != previous.get("ts_ns")


def detect_jumps(records):
    """Exponent steps between consecutive new frames with a stable input mean, per eye (no rate limit)."""
    jumps, before, between = [], None, []
    for record in records:
        if before is not None and record.get("ts_ns") == before.get("ts_ns"):
            between.append(record)
            continue
        if before is not None:
            best = None
            for a, b in zip(before.get("eyes", []), record.get("eyes", [])):
                ea, eb, ia, ib = eye_exponent(a), eye_exponent(b), a.get("in_mean"), b.get("in_mean")
                if None in (ea, eb, ia, ib) or max(ia, ib) <= 0 or abs(ia - ib) / max(ia, ib) >= JUMP_INPUT_STABLE_RATIO:
                    continue
                if abs(eb - ea) > JUMP_EXPONENT_DELTA and (best is None or abs(eb - ea) > abs(best["d_exp"])):
                    best = {"eye": b.get("eye", "?"), "d_exp": eb - ea, "exp": (ea, eb), "in": (ia, ib),
                            "out": (a.get("out_mean"), b.get("out_mean"))}
            if best:
                best.update(before=before, after=record, changed=changed_fields(before, between + [record]))
                jumps.append(best)
        before, between = record, []
    return jumps


def changed_fields(before, following):
    """Recorded fields that differ between `before` and the last of `following`, or that any of them flagged."""
    after = following[-1]
    a, b = before.get("fields", {}), after.get("fields", {})
    keys = {k for k in set(a) | set(b) if a.get(k) != b.get(k)}
    for record in following:
        keys.update(record.get("changed", []))
    return sorted(keys)


def fmt(v):
    return "na" if v is None else "%.4g" % v


def report(records, summaries):
    lines = []
    if summaries:
        totals = {k: 0 for k in SUMMARY_KEYS}
        for s in summaries:
            for k in ("frames", "new", "repeat", "jumps"):
                totals[k] += int(s.get(k, 0))
            totals["levels"] = max(totals["levels"], int(s.get("levels", 0)))
        lines.append("summary lines: %d (frames %d, new %d, repeat %d, levels max %d, jumps %d)" % (
            len(summaries), totals["frames"], totals["new"], totals["repeat"], totals["levels"], totals["jumps"]))
    new = sum(1 for i, r in enumerate(records) if is_new(r, records[i - 1] if i else None))
    lines.append("frames: %d (new %d, repeat %d)" % (len(records), new, len(records) - new))
    exps = [e for r in records for e in map(eye_exponent, r.get("eyes", [])) if e is not None]
    clusters = levels(exps)
    counted = [c for c in clusters if c[1] >= max(1, MIN_LEVEL_SHARE * len(exps))]
    lines.append("output levels: %d (transfer exponent clusters, gap %g)" % (len(counted), LEVEL_GAP))
    for centre, count in clusters:
        lines.append("  exp %s  n=%d%s" % (fmt(centre), count, "" if (centre, count) in counted else " (stray)"))
    jumps = detect_jumps(records)
    lines.append("jumps: %d" % len(jumps))
    t0 = records[0].get("t_ms", 0) if records else 0
    for j in jumps:
        before, after = j["before"], j["after"]
        head = "  t=%.3f s seq %s->%s eye %s: exp %s -> %s, in %s -> %s, out %s -> %s" % (
            (after.get("t_ms", 0) - t0) / 1000.0, before.get("seq"), after.get("seq"), j["eye"], fmt(j["exp"][0]),
            fmt(j["exp"][1]), fmt(j["in"][0]), fmt(j["in"][1]), fmt(j["out"][0]), fmt(j["out"][1]))
        if j["changed"]:
            a, b = before.get("fields", {}), after.get("fields", {})
            detail = ", ".join("%s (%s -> %s)" % (k, a.get(k, "none"), b.get(k, "none")) for k in j["changed"])
            lines.append(head + "; changed: " + detail)
        else:
            lines.append(head + "; no recorded field changed (outside the client pipeline)")
    lines.append(verdict(jumps, len(counted)))
    return lines


def verdict(jumps, level_count):
    explained = [j for j in jumps if j["changed"]]
    if not jumps:
        if level_count <= 1:
            return "VERDICT stable: one output level, no jumps"
        return "VERDICT %d output levels but no jump between consecutive new frames with stable input" % level_count
    fields = sorted({k for j in explained for k in j["changed"]})
    if len(explained) == len(jumps):
        return "VERDICT client pipeline: all %d jumps coincide with recorded field changes (%s)" % (len(jumps), ", ".join(fields))
    if not explained:
        return "VERDICT outside the client pipeline: %d jumps with no recorded field change" % len(jumps)
    return "VERDICT mixed: %d jumps with field changes (%s), %d without" % (len(explained), ", ".join(fields), len(jumps) - len(explained))


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    records, summaries = load(argv)
    print("\n".join(report(records, summaries)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
