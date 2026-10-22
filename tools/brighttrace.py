#!/usr/bin/env python3
"""Brightness trace analysis (ALVRClient/BrightTrace.swift, -ALVRBrightTrace YES or the Diagnostics toggle).

Reads Documents/diag/brighttrace-*.jsonl (one record per presented frame), or a log holding the forwarded lines (the
PC streamer.log, or a simulator console log): the 1 Hz `BRIGHTTRACE t_ms=...` summaries and the compact
`BRIGHTTRACE JUMP ... eyes=R changed=... L=in:a>b,out:a>b,gain:a>b,exp:a>b R=...` lines. Prints frame counts, per
eye the output levels (clusters of the output-vs-input transfer exponent and of the gain), each jump with the eyes that
stepped and the recorded fields that changed at that frame, and a one-line verdict.

Usage: python3 tools/brighttrace.py <brighttrace.jsonl | streamer.log> [...]
Python 3.9, stdlib only. Tests: tools/tests/test_brighttrace.py.
"""
import json
import math
import re
import sys

# Mirrors of BrightTrace.swift.
JUMP_EXPONENT_DELTA = 0.08
JUMP_LOG_GAIN_DELTA = 0.1
JUMP_INPUT_STABLE_RATIO = 0.03
LEVEL_GAP = 0.05
LUMA_FLOOR = 1e-4
# Clusters holding fewer than this share of an eye's values are reported but not counted as output levels.
MIN_LEVEL_SHARE = 0.02
# Jumps listed in full; the rest are counted.
MAX_JUMP_LINES = 20
# Totals taken from the 1 Hz summary lines.
SUMMARY_SUMS = ("frames", "new", "repeat", "jumps", "dropped", "dropped_lines")
JUMP_KEYS = ("t_ms", "seq", "ts_ns", "eyes", "changed")


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


def _fit(eye, key, index):
    if eye.get(key) is not None:
        return eye[key]
    fit = exponent(eye.get("in"), eye.get("out"))
    return fit[index] if fit else None


def eye_exponent(eye):
    return _fit(eye, "exp", 0)


def eye_log_gain(eye):
    return _fit(eye, "log_gain", 1)


def gain(eye):
    """Output mean over input mean (BrightTraceEye.gain)."""
    i, o = eye.get("in_mean"), eye.get("out_mean")
    return o / i if i is not None and o is not None and i > LUMA_FLOOR and o > LUMA_FLOOR else None


def stepped(a, b):
    """Gain or exponent step of one eye with a stable input (BrightTrace.stepped)."""
    ia, ib, ga, gb = a.get("in_mean"), b.get("in_mean"), gain(a), gain(b)
    if None in (ia, ib, ga, gb) or abs(ia - ib) / max(ia, ib) >= JUMP_INPUT_STABLE_RATIO:
        return False
    if abs(math.log(gb / ga)) > JUMP_LOG_GAIN_DELTA:
        return True
    ea, eb = eye_exponent(a), eye_exponent(b)
    return ea is not None and eb is not None and abs(eb - ea) > JUMP_EXPONENT_DELTA


def levels(values, gap=LEVEL_GAP):
    """Clusters of 1-D values split at gaps wider than `gap`: list of (centre, count)."""
    clusters = []
    for v in sorted(values):
        if clusters and v - clusters[-1][-1] <= gap:
            clusters[-1].append(v)
        else:
            clusters.append([v])
    return [(sum(c) / len(c), len(c)) for c in clusters]


def counted(clusters):
    total = sum(n for _, n in clusters)
    return [c for c in clusters if c[1] >= max(1, MIN_LEVEL_SHARE * total)]


def parse_number(text):
    return None if text == "na" else float(text)


def parse_jump(line):
    """A compact JUMP line -> the jump dict of detect_jumps (no field values)."""
    pairs = dict(re.findall(r"(\w+)=(\S+)", line[line.index("BRIGHTTRACE JUMP"):]))
    seq = pairs.get("seq", "?>?").split(">")
    per_eye = {}
    for name, value in pairs.items():
        if name in JUMP_KEYS or not value.startswith("in:"):
            continue
        per_eye[name] = {k: tuple(parse_number(x) for x in v.split(">")) for k, v in (p.split(":") for p in value.split(","))}
    changed = pairs.get("changed", "none")
    return {"t_ms": int(pairs.get("t_ms", 0)), "seq": (seq[0], seq[-1]), "eyes": pairs.get("eyes", "").split(","),
            "per_eye": per_eye, "changed": [] if changed == "none" else changed.split(","), "detail": None}


def load(paths):
    """Records (jsonl lines), logged jumps (JUMP lines) and summary dicts."""
    records, jumps, summaries = [], [], []
    for path in paths:
        with open(path, errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        records.append(json.loads(line))
                    except ValueError:
                        pass
                elif "BRIGHTTRACE JUMP" in line:
                    try:
                        jumps.append(parse_jump(line))
                    except ValueError:
                        pass
                elif "BRIGHTTRACE t_ms=" in line:
                    summaries.append(dict(re.findall(r"(\w+)=(\S+)", line[line.index("BRIGHTTRACE"):])))
    records.sort(key=lambda r: r.get("seq", 0))
    return records, jumps, summaries


def is_new(record, previous):
    return previous is None or record.get("ts_ns") != previous.get("ts_ns")


def detect_jumps(records):
    """Gain or exponent steps per eye between consecutive presented frames, repeats included (no rate limit)."""
    jumps = []
    for before, record in zip(records, records[1:]):
        eyes_before = {e.get("eye"): e for e in before.get("eyes", [])}
        names = [e.get("eye") for e in record.get("eyes", []) if e.get("eye") in eyes_before and stepped(eyes_before[e.get("eye")], e)]
        if not names:
            continue
        per_eye = {}
        for b in record.get("eyes", []):
            a = eyes_before.get(b.get("eye"), {})
            per_eye[b.get("eye")] = {"in": (a.get("in_mean"), b.get("in_mean")), "out": (a.get("out_mean"), b.get("out_mean")),
                                     "gain": (gain(a), gain(b)), "exp": (eye_exponent(a), eye_exponent(b))}
        fa, fb = before.get("fields", {}), record.get("fields", {})
        changed = sorted({k for k in set(fa) | set(fb) if fa.get(k) != fb.get(k)} | set(record.get("changed", [])))
        jumps.append({"t_ms": record.get("t_ms", 0), "seq": (before.get("seq"), record.get("seq")), "eyes": names,
                      "per_eye": per_eye, "changed": changed, "detail": {k: (fa.get(k, "none"), fb.get(k, "none")) for k in changed}})
    return jumps


def fmt(v):
    return "na" if v is None else "%.4g" % v


def jump_lines(jumps, eye_names):
    by_eye = ", ".join("%s %d" % (e, sum(1 for j in jumps if e in j["eyes"])) for e in eye_names)
    lines = ["%d (%s)" % (len(jumps), by_eye) if by_eye else "%d" % len(jumps)]
    t0 = jumps[0]["t_ms"] if jumps else 0
    for j in jumps[:MAX_JUMP_LINES]:
        steps = " | ".join("%s gain %s -> %s, exp %s -> %s, in %s -> %s, out %s -> %s" % (
            (e,) + tuple(fmt(v) for k in ("gain", "exp", "in", "out") for v in j["per_eye"].get(e, {}).get(k, (None, None))))
            for e in j["eyes"])
        head = "  t=%.3f s seq %s->%s eyes %s: %s" % ((j["t_ms"] - t0) / 1000.0, j["seq"][0], j["seq"][1], ",".join(j["eyes"]), steps)
        if not j["changed"]:
            lines.append(head + "; no recorded field changed (outside the client pipeline)")
        elif j["detail"]:
            lines.append(head + "; changed: " + ", ".join("%s (%s -> %s)" % (k, a, b) for k, (a, b) in sorted(j["detail"].items())))
        else:
            lines.append(head + "; changed: " + ", ".join(j["changed"]))
    if len(jumps) > MAX_JUMP_LINES:
        lines.append("  ... %d more" % (len(jumps) - MAX_JUMP_LINES))
    return lines


def report(records, logged, summaries):
    lines = []
    if summaries:
        totals = {k: sum(int(s.get(k, 0)) for s in summaries) for k in SUMMARY_SUMS}
        lines.append("summary lines: %d (frames %d, new %d, repeat %d, levels max %d, jumps %d, dropped %d, dropped lines %d)" % (
            len(summaries), totals["frames"], totals["new"], totals["repeat"], max(int(s.get("levels", 0)) for s in summaries),
            totals["jumps"], totals["dropped"], totals["dropped_lines"]))
    new = sum(1 for i, r in enumerate(records) if is_new(r, records[i - 1] if i else None))
    lines.append("frames: %d (new %d, repeat %d)" % (len(records), new, len(records) - new))
    eye_names = sorted({e.get("eye") for r in records for e in r.get("eyes", [])})
    level_count = 0
    for name in eye_names:
        eyes = [e for r in records for e in r.get("eyes", []) if e.get("eye") == name]
        exps = levels([v for v in map(eye_exponent, eyes) if v is not None])
        gains = levels([v for v in map(eye_log_gain, eyes) if v is not None])
        level_count = max(level_count, len(counted(exps)), len(counted(gains)))
        lines.append("eye %s: exponent levels %d, gain levels %d" % (name, len(counted(exps)), len(counted(gains))))
        for label, clusters, value in (("exp", exps, lambda c: c), ("gain", gains, math.exp)):
            for centre, count in clusters:
                lines.append("  %s %s  n=%d%s" % (label, fmt(value(centre)), count, "" if (centre, count) in counted(clusters) else " (stray)"))
    lines.append("output levels: %d (exponent or gain clusters, most of any eye, gap %g)" % (level_count, LEVEL_GAP))
    jumps = detect_jumps(records)
    if records or not logged:
        lines += ["jumps: " + jump_lines(jumps, eye_names)[0]] + jump_lines(jumps, eye_names)[1:]
    if logged:
        names = sorted({e for j in logged for e in j["eyes"]})
        lines += ["logged jumps: " + jump_lines(logged, names)[0]] + jump_lines(logged, names)[1:]
    lines.append(verdict(jumps if records else logged, level_count))
    return lines


def verdict(jumps, level_count):
    if not jumps:
        if level_count <= 1:
            return "VERDICT stable: one output level, no jumps"
        return "VERDICT %d output levels but no jump between consecutive frames with stable input" % level_count
    explained = [j for j in jumps if j["changed"]]
    fields = ", ".join(sorted({k for j in explained for k in j["changed"]}))
    eyes = "eyes " + ",".join(sorted({e for j in jumps for e in j["eyes"]}))
    if len(explained) == len(jumps):
        return "VERDICT client pipeline: all %d jumps coincide with recorded field changes (%s) (%s)" % (len(jumps), fields, eyes)
    if not explained:
        return "VERDICT outside the client pipeline: %d jumps with no recorded field change (%s)" % (len(jumps), eyes)
    return "VERDICT mixed: %d jumps with field changes (%s), %d without (%s)" % (len(explained), fields, len(jumps) - len(explained), eyes)


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    print("\n".join(report(*load(argv))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
