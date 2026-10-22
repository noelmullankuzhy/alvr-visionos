#!/usr/bin/env python3
"""Tests for tools/brighttrace.py on synthetic fixtures (Python 3.9, stdlib only).

Run: python3 tools/tests/test_brighttrace.py
"""
import io
import json
import math
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import brighttrace  # noqa: E402

BASE_FIELDS = {"path": "metal", "pipeline": "biplanar", "binding": "explicit10", "hdr_pq": "true", "headroom": "1",
               "transfer": "pq", "matrix": "bt2020", "range": "limited", "encoding_gamma": "1", "gamut_hash": "abc",
               "decode": "sync", "cv_fourcc": "x420", "cv_transfer": "SMPTE_ST_2084_PQ", "drawable_format": "rgba16Float"}


def grid(level, k, gain=1.0):
    inp = [level * (0.2 + i / 320.0) for i in range(256)]
    return inp, [gain * v ** k for v in inp]


def eye(name, k, level=0.5, gain=1.0, grids=False):
    inp, out = grid(level, k, gain)
    return {"eye": name, "in_mean": sum(inp) / 256, "out_mean": sum(out) / 256, "exp": None if grids else k,
            "log_gain": None if grids else math.log(gain), "in": inp if grids else None, "out": out if grids else None}


def record(seq, ts, k, fields=None, level=0.5, grids=False, eyes=None):
    f = dict(BASE_FIELDS)
    f.update(fields or {})
    return {"seq": seq, "t_ms": 1_000_000 + seq * 11, "present_s": seq / 90.0, "ts_ns": ts, "new": True,
            "gen": 0, "changed": [], "fields": f, "eyes": eyes or [eye("L", k, level, grids=grids)]}


def series(levels, field_change):
    """Two frames per video timestamp (one repeat); level index flips every 10 new frames."""
    out, prev = [], None
    for n in range(40):
        level = levels[(n // 10) % len(levels)]
        fields = {"pipeline": "secret" if level != levels[0] else "biplanar"} if field_change else {}
        for rep in range(2):
            r = record(len(out), 1000 + n, level, fields)
            r["new"] = rep == 0
            if prev is not None:
                r["changed"] = sorted(k for k in r["fields"] if r["fields"][k] != prev["fields"].get(k))
            out.append(r)
            prev = r
    return out


def stereo(count, ts, right):
    """Both eyes, a steady input; right(i) gives the right eye's (exponent, gain) at presented frame i."""
    return [record(i, ts(i), 1.0, eyes=[eye("L", 1.0), eye("R", right(i)[0], gain=right(i)[1])]) for i in range(count)]


def write_jsonl(records):
    handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
    for r in records:
        handle.write(json.dumps(r, separators=(",", ":")) + "\n")
    handle.close()
    return handle.name


def run(path):
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            code = brighttrace.main([path])
    finally:
        os.unlink(path)
    return code, buf.getvalue()


class ExponentTests(unittest.TestCase):
    def test_rank_paired_slope(self):
        inp, out = grid(0.5, 1.27)
        slope, gain = brighttrace.exponent(inp, list(reversed(out)))
        self.assertAlmostEqual(slope, 1.27, places=9)
        self.assertAlmostEqual(gain, 0.0, places=9)

    def test_levels(self):
        self.assertEqual(len(brighttrace.levels([1.0, 1.01, 1.27, 1.26])), 2)
        self.assertEqual(len(brighttrace.levels([1.0, 1.02, 0.99])), 1)

    def test_exponent_from_grids_when_not_recorded(self):
        r = record(0, 1, 1.25, grids=True)
        self.assertAlmostEqual(brighttrace.eye_exponent(r["eyes"][0]), 1.25, places=9)


class SeriesTests(unittest.TestCase):
    def test_two_levels_with_field_change(self):
        code, text = run(write_jsonl(series([1.0, 1.27], field_change=True)))
        self.assertEqual(code, 0)
        self.assertIn("frames: 80 (new 40, repeat 40)", text)
        self.assertIn("output levels: 2", text)
        self.assertIn("jumps: 3", text)
        self.assertIn("changed: pipeline (biplanar -> secret)", text)
        self.assertNotIn("no recorded field changed", text)
        self.assertIn("VERDICT client pipeline", text)

    def test_two_levels_without_field_change(self):
        code, text = run(write_jsonl(series([1.0, 1.27], field_change=False)))
        self.assertEqual(code, 0)
        self.assertIn("output levels: 2", text)
        self.assertIn("jumps: 3", text)
        self.assertEqual(text.count("no recorded field changed (outside the client pipeline)"), 3)
        self.assertIn("VERDICT outside the client pipeline", text)

    def test_stable_series(self):
        code, text = run(write_jsonl(series([1.0], field_change=False)))
        self.assertEqual(code, 0)
        self.assertIn("output levels: 1", text)
        self.assertIn("jumps: 0", text)
        self.assertIn("VERDICT stable", text)

    def test_right_only_gain_alternation(self):
        code, text = run(write_jsonl(stereo(80, lambda i: 1000 + i, lambda i: (1.0, 1.0 if i % 2 == 0 else 0.5))))
        self.assertEqual(code, 0)
        self.assertIn("eye L: exponent levels 1, gain levels 1", text)
        self.assertIn("eye R: exponent levels 1, gain levels 2", text)
        self.assertIn("output levels: 2", text)
        self.assertIn("jumps: 79 (L 0, R 79)", text)
        self.assertIn("eyes R: R gain 1 -> 0.5", text)
        self.assertIn("VERDICT outside the client pipeline: 79 jumps with no recorded field change (eyes R)", text)

    def test_right_only_exponent_alternation_on_repeats(self):
        records = stereo(80, lambda i: 1000 + i // 2, lambda i: (1.0 if i % 2 == 0 else 1.27, 1.0))
        jumps = brighttrace.detect_jumps(records)
        self.assertEqual(len(jumps), 79)
        self.assertTrue(all(j["eyes"] == ["R"] for j in jumps))
        code, text = run(write_jsonl(records))
        self.assertIn("frames: 80 (new 40, repeat 40)", text)
        self.assertIn("eye R: exponent levels 2, gain levels 1", text)
        self.assertIn("jumps: 79 (L 0, R 79)", text)
        self.assertIn("VERDICT outside the client pipeline", text)

    def test_both_eyes_stable(self):
        code, text = run(write_jsonl(stereo(80, lambda i: 1000 + i // 2, lambda i: (1.0, 1.0))))
        self.assertEqual(code, 0)
        self.assertIn("output levels: 1", text)
        self.assertIn("jumps: 0 (L 0, R 0)", text)
        self.assertIn("VERDICT stable", text)

    def test_small_gain_change_is_not_a_jump(self):
        records = [record(0, 1, 1.0), record(1, 2, 1.0, eyes=[eye("L", 1.0, gain=1.05)])]
        self.assertEqual(brighttrace.detect_jumps(records), [])

    def test_input_change_is_not_a_jump(self):
        records = [record(0, 1, 1.0), record(1, 2, 1.27, level=0.9)]
        self.assertEqual(brighttrace.detect_jumps(records), [])


class LogTests(unittest.TestCase):
    def test_forwarded_lines(self):
        lines = [
            "2026-10-23 10:00:00.000 [INFO] Client 192.168.1.20: [Info] [ALVR NATIVE] BRIGHTTRACE t_ms=1000 frames=90 new=72 repeat=18"
            " in_min=0.2 in_max=0.3 out_min=0.1 out_max=0.3 exp_min=1 exp_max=1 levels=2 levels_L=1 levels_R=2 gen_changes=0"
            " variants=biplanar/explicit10 attach_changes=0 jumps=2 jumps_L=0 jumps_R=2 dropped=3 dropped_lines=1",
            "2026-10-23 10:00:00.010 [INFO] Client 192.168.1.20: [Info] [ALVR NATIVE] BRIGHTTRACE JUMP t_ms=1001 seq=5>6 ts_ns=10>11"
            " eyes=R changed=none L=in:0.25>0.25,out:0.25>0.25,gain:1>1,exp:1>1 R=in:0.25>0.25,out:0.25>0.125,gain:1>0.5,exp:1>1",
            "2026-10-23 10:00:00.021 [INFO] Client 192.168.1.20: [Info] [ALVR NATIVE] BRIGHTTRACE JUMP t_ms=1012 seq=6>7 ts_ns=11>11"
            " eyes=R changed=pipeline L=in:0.25>0.25,out:0.25>0.25,gain:1>1,exp:1>1 R=in:0.25>0.25,out:0.125>0.25,gain:0.5>1,exp:na>1",
            "unrelated line",
        ]
        handle = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        handle.write("\n".join(lines) + "\n")
        handle.close()
        code, text = run(handle.name)
        self.assertEqual(code, 0)
        self.assertIn("summary lines: 1 (frames 90, new 72, repeat 18, levels max 2, jumps 2, dropped 3, dropped lines 1)", text)
        self.assertIn("logged jumps: 2 (R 2)", text)
        self.assertIn("seq 5->6 eyes R: R gain 1 -> 0.5", text)
        self.assertIn("; no recorded field changed (outside the client pipeline)", text)
        self.assertIn("exp na -> 1", text)
        self.assertIn("; changed: pipeline", text)
        self.assertIn("VERDICT mixed", text)


if __name__ == "__main__":
    unittest.main()
