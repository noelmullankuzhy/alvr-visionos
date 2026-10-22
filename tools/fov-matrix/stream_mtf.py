#!/usr/bin/env python3
"""Stream sharpness per matrix point: edge MTF50 of the angle chart's lines in the client's expanded stage image.

The angle chart (Management/goals/rdr2-vr/fov-model/angle-chart-spec.md) has no bars and no slanted edges: only thin
axis-aligned lines, green verticals at a = 5k deg and magenta horizontals at e = 5k deg, 7 render px wide at 0 deg, 5 px
at 15 deg multiples and 3 px otherwise, drawn without anti-aliasing. So the measure is the edge method without the slant:
each edge of a vertical line is an edge spread function (ESF, across x, averaged down the line), its difference the line
spread function (LSF), its normalised DTFT the MTF; MTF50 is the first frequency where the mean of the line's two edges
falls to 0.5. A 3 px line's edges overlap once blurred (no plateau between them), so only the 7 and 5 px lines are used:
  centre: the 0 deg line, rows e = -4..4 deg     up / down: the 0 deg line, rows e = 11..19 / -19..-11 deg
  nose / temple: the 15 deg lines (nose = +a for L, -a for R), rows e = -4..4 deg
Rows within 6 px of a horizontal line (the crossings) are skipped. Signal: linear-light luminance (Rec. 709 weights on
the decoded sRGB values linearised): the green lines stand out in luma, the magenta ones barely (so only vertical lines,
i.e. horizontal MTF, are measured).

Image: capture.json stage "expanded" (the stream after decode, chroma upsample and the FFR expand, before the display
warp), which sits on the server's render grid, so the dump's meta.json tangents give its px/deg exactly:
px/deg = W / (tanR - tanL) x sec^2(a) x pi/180. MTF is the discrete transfer at that grid relative to the server's
pixel-exact edge (the dump's own chart PNG measures 1.0 at every frequency): no slant means no oversampling, so it
includes the pixel aperture and is not corrected for it. A curve that stays above 0.5 to Nyquist (0.5 cycles/px) reports
'>' the Nyquist cpd. Each edge's window ends at the middle of the line's top, so a blur wide enough that the two edges
overlap (the line no longer reaches the chart's line level, green = 0.7152 linear luminance, within 2 % of the contrast;
sigma above about 0.9 px on a 5 px line, 1.2 px on the 7 px one) cuts each LSF short; that edge is flagged truncated and
its MTF50 reported as an upper bound ('<'). Python 3.9+, standard library only; images load through fov-overlay.py
(verify-capture.py).
"""
import argparse
import cmath
import importlib.util
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('fov_overlay', os.path.join(HERE, '..', 'diag', 'fov-overlay.py'))
fo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fo)

D = math.pi / 180
# (position, |a| deg, nose sign: +1 nose, -1 temple, 0 on the vertical meridian, e0 deg)
POSITIONS = (('centre', 0, 0, 0), ('nose', 15, 1, 0), ('temple', 15, -1, 0), ('up', 0, 0, 15), ('down', 0, 0, -15))
ROW_SPAN_DEG = 4.0          # rows averaged: e0 +- this
CROSS_MARGIN_PX = 6         # rows this close to a horizontal line (beyond its half width) are skipped
WINDOW_PX = 10              # ESF window on the background side of each edge
MIN_CONTRAST = 0.1          # line plateau over background, linear luminance
LINE_LUM = 0.7152           # the chart's vertical lines, sRGB (0, 255, 0): linear luminance
PLATEAU_TOL = 0.01          # samples this close to the line's maximum (fraction of contrast) are its top
TRUNCATED_FRACTION = 0.02   # line top short of LINE_LUM by more than this fraction of the contrast: the edges overlap
F_STEP = 0.005              # cycles/px, the MTF50 search grid
CURVE_STEP = 0.025          # cycles/px, the written curves


def _srgb_to_linear():
    out = []
    for v in range(256):
        x = v / 255
        out.append(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4)
    return out


LIN = _srgb_to_linear()


def line_width_px(angle):
    """Render px width of the chart line at `angle` deg (the spec; fov-overlay.py chart_lines)."""
    k = round(angle / 5)
    return 7 if k == 0 else 5 if (5 * k) % 15 == 0 else 3


class Grid:
    """The render grid: tangents tanL < 0 < tanR, tanD < 0 < tanU (meta.json order L, R, D, U, signed) and its size."""

    def __init__(self, tangents, width, height):
        self.tl, self.tr, self.td, self.tu = tangents
        self.width, self.height = width, height

    def col(self, a):
        """Column (pixel index, centre at i) of the vertical line at a deg."""
        return (math.tan(a * D) - self.tl) / (self.tr - self.tl) * self.width - 0.5

    def row(self, e):
        return (self.tu - math.tan(e * D)) / (self.tu - self.td) * self.height - 0.5

    def px_per_deg(self, a):
        return self.width / (self.tr - self.tl) * (1 + math.tan(a * D) ** 2) * D


class PngImage:
    """8-bit RGBA sRGB-encoded pixels; (x0, y0): where this (possibly cropped) image sits in the full grid."""

    def __init__(self, width, height, pix, x0=0, y0=0):
        self.width, self.height, self.pix, self.x0, self.y0 = width, height, pix, x0, y0

    def contains(self, x, y):
        return 0 <= x - self.x0 < self.width and 0 <= y - self.y0 < self.height

    def lum(self, x, y):
        i = ((y - self.y0) * self.width + x - self.x0) * 4
        p = self.pix
        return 0.2126 * LIN[p[i]] + 0.7152 * LIN[p[i + 1]] + 0.0722 * LIN[p[i + 2]]


def sample_rows(grid, image, e0):
    """Rows within e0 +- ROW_SPAN_DEG, inside the image, clear of every horizontal line."""
    lines = [(grid.row(5 * k), line_width_px(5 * k)) for k in range(-17, 18) if abs(5 * k) < 90]
    y0, y1 = int(math.ceil(grid.row(e0 + ROW_SPAN_DEG))), int(math.floor(grid.row(e0 - ROW_SPAN_DEG)))
    return [y for y in range(y0, y1 + 1) if all(abs(y - c) > w / 2 + CROSS_MARGIN_PX for c, w in lines)]


def profile(image, xs, rows):
    return [sum(image.lum(x, y) for y in rows) / len(rows) for x in xs]


def _base(prof):
    return (sum(prof[:3]) + sum(prof[-3:])) / 6


def edge_lsfs(prof, width):
    """(rising LSF, falling LSF) of a line profile, or None: each edge's ESF difference from its background side to the
    middle of the line's top (the samples within PLATEAU_TOL of its maximum), normalised to unit sum."""
    d = [prof[i + 1] - prof[i] for i in range(len(prof) - 1)]
    n = len(d)
    rise = max(range(n), key=lambda i: d[i])
    fall = min(range(n), key=lambda i: d[i])
    if not 0 < fall - rise <= width + 3:
        return None
    base = _base(prof)
    top = max(prof[rise + 1:fall + 1])
    if top - base < MIN_CONTRAST:
        return None
    on_top = [i for i in range(rise + 1, fall + 1) if prof[i] >= top - PLATEAU_TOL * (top - base)]
    mid = (on_top[0] + on_top[-1] + 1) // 2
    up = d[max(0, rise - WINDOW_PX):mid]
    down = [-v for v in d[mid:min(n, fall + WINDOW_PX + 1)]]
    out = []
    for lsf in (up, down):
        s = sum(lsf)
        if s <= 0:
            return None
        out.append([v / s for v in lsf])
    return out


def truncated(prof):
    """The line's top short of the chart's line level by more than TRUNCATED_FRACTION of the contrast: the blur is too
    wide for the line (its two edges overlap), each LSF's tail is cut, so MTF50 is an upper bound."""
    base = _base(prof)
    return max(prof) - base < (1 - TRUNCATED_FRACTION) * (LINE_LUM - base)


def mtf(lsf, f):
    """|DTFT| of a unit-sum LSF at f cycles/px."""
    return abs(sum(v * cmath.exp(-2j * math.pi * f * n) for n, v in enumerate(lsf)))


def mtf50(curve):
    """First crossing of 0.5 in [(f, m)], linearly interpolated; None when it stays above 0.5."""
    for (f0, m0), (f1, m1) in zip(curve, curve[1:]):
        if m0 >= 0.5 > m1:
            return f0 + (m0 - 0.5) / (m0 - m1) * (f1 - f0)
    return None


def measure_edge(grid, image, a, e0):
    """MTF50 of the vertical line at a deg, rows around e0: {'f50_cyc_px', 'cpd', 'nyquist_cpd', 'px_per_deg', 'curve',
    'edges'} or None when the line is not found or out of the image."""
    w = line_width_px(a)
    c = grid.col(a)
    xs = list(range(int(math.floor(c - w / 2)) - WINDOW_PX - 2, int(math.ceil(c + w / 2)) + WINDOW_PX + 3))
    rows = [y for y in sample_rows(grid, image, e0) if image.contains(xs[0], y) and image.contains(xs[-1], y)]
    if len(rows) < 8:
        return None
    prof = profile(image, xs, rows)
    lsfs = edge_lsfs(prof, w)
    if lsfs is None:
        return None
    steps = int(round(0.5 / F_STEP))
    curve = [(k * F_STEP, sum(mtf(l, k * F_STEP) for l in lsfs) / 2) for k in range(steps + 1)]
    ppd = grid.px_per_deg(a)
    f50 = mtf50(curve)
    keep = int(round(CURVE_STEP / F_STEP))
    return {'a_deg': a, 'e0_deg': e0, 'line_px': w, 'rows': len(rows), 'px_per_deg': ppd, 'f50_cyc_px': f50,
            'cpd': None if f50 is None else f50 * ppd, 'nyquist_cpd': 0.5 * ppd, 'truncated': truncated(prof),
            'curve': [(f, m, mr, mf) for (f, m), mr, mf in
                      ((curve[k], mtf(lsfs[0], curve[k][0]), mtf(lsfs[1], curve[k][0])) for k in range(0, steps + 1, keep))]}


def measure_eye(grid, image, eye):
    """{position: measure_edge result or None} for one eye."""
    sign = 1 if eye == 'L' else -1
    return {pos: measure_edge(grid, image, nose * sign * a if nose else a, e0) for pos, a, nose, e0 in POSITIONS}


def load_point(point_dir):
    """[(eye, Grid, PngImage)] for every expanded stage in point_dir/capture with the dump's meta.json; [] when absent."""
    cap_dir = os.path.join(point_dir, 'capture')
    try:
        with open(os.path.join(cap_dir, 'capture.json')) as f:
            cap = json.load(f)
        with open(os.path.join(point_dir, 'dump', 'meta.json')) as f:
            meta = json.load(f)
    except (OSError, ValueError):
        return []
    out = []
    for st in cap.get('stages') or []:
        if st.get('stage') != 'expanded' or st.get('eye') not in ('L', 'R'):
            continue
        eye = st['eye']
        tangents = meta['tangents'][0 if eye == 'L' else 1]
        w, h, pix = fo.read_stage_png(fo.Path(cap_dir) / st['png'], st.get('encoding', 'srgb'))
        out.append((eye, Grid(tangents, w, h), PngImage(w, h, pix)))
    return out


def measure_point(point_dir):
    """{eye: {position: result}}."""
    return {eye: measure_eye(grid, image, eye) for eye, grid, image in load_point(point_dir)}


def combine(results, position):
    """Column text for a position: mean cpd over the eyes; '>N' (the Nyquist cpd) when an eye stays above 0.5 to
    Nyquist; '<x' when an eye's edge was cut short (truncated: x is an upper bound); 'n/a' with no measurement."""
    rs = [r[position] for r in results.values() if r.get(position)]
    if not rs:
        return 'n/a'
    if any(r['cpd'] is None for r in rs):
        return '>%.1f' % min(r['nyquist_cpd'] for r in rs)
    return ('<' if any(r.get('truncated') for r in rs) else '') + '%.1f' % (sum(r['cpd'] for r in rs) / len(rs))


def curves_tsv(name, results):
    lines = []
    for eye in sorted(results):
        for pos, r in results[eye].items():
            if not r:
                continue
            for f, m, mr, mf in r['curve']:
                lines.append('\t'.join([name, eye, pos, '%g' % r['a_deg'], '%g' % r['e0_deg'], '%.3f' % f, '%.2f' % (f * r['px_per_deg']),
                                        '%.4f' % m, '%.4f' % mr, '%.4f' % mf]))
    return lines


CURVE_HEADER = 'point\teye\tposition\ta_deg\te0_deg\tf_cyc_px\tf_cpd\tmtf\tmtf_rising\tmtf_falling'


def main(argv=None):
    p = argparse.ArgumentParser(description='Edge MTF50 of a matrix point (capture expanded stage + dump meta.json).')
    p.add_argument('point_dir')
    p.add_argument('--name', help='point name in the curves (default: the directory name)')
    p.add_argument('--curves', help='append the MTF curves to this tsv (header written when new)')
    a = p.parse_args(argv)
    name = a.name or os.path.basename(os.path.normpath(a.point_dir))
    res = measure_point(a.point_dir)
    if not res:
        print('%s: no expanded stage capture or no dump/meta.json' % name)
        return 2
    for eye in sorted(res):
        for pos, r in res[eye].items():
            if r is None:
                print('%s %s %-6s n/a' % (name, eye, pos))
                continue
            print('%s %s %-6s a=%g e0=%g line=%dpx rows=%d px/deg=%.2f MTF50=%s cyc/px = %s cpd (Nyquist %.1f)%s' % (
                name, eye, pos, r['a_deg'], r['e0_deg'], r['line_px'], r['rows'], r['px_per_deg'],
                'n/a' if r['f50_cyc_px'] is None else '%.3f' % r['f50_cyc_px'], 'n/a' if r['cpd'] is None else '%.2f' % r['cpd'],
                r['nyquist_cpd'], ' truncated: upper bound' if r['truncated'] else ''))
    if a.curves:
        new = not os.path.exists(a.curves)
        with open(a.curves, 'a') as f:
            f.write('\n'.join(([CURVE_HEADER] if new else []) + curves_tsv(name, res)) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
