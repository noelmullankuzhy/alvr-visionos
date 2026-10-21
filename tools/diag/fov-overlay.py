#!/usr/bin/env python3
"""Overlay the predicted FoV geometry on stream images and measure where the angle chart's lines landed.

Pattern: Management/goals/rdr2-vr/fov-model/angle-chart-spec.md (green vertical lines at a = 5k deg, magenta
horizontal lines at e = 5k deg). Maths: frustum-pixel-map.html section 7, checked against ALVR FFR.cpp,
CompressAxisAlignedPixelShader.hlsl and the client's Shaders.metal (decompressAxisAlignedCoord).

Modes (first argument):
  render    eye image before foveation: lines at linear tangent positions
  encoded   foveated eye image: forward foveation map
  drawable  DiagFrameCapture directory: view tangents -> logical screen -> physical via the rate tables; the stream
            covers s x the view tangents, black outside
  synth     write a synthetic image (--kind render|encoded|drawable) from the same parameters, for tests

--tangents L,R,D,U are literal |tan| of the render FOV's left/right/down/up (screen sides). Default device: left eye
1.7321,1.0,1.1918,1.0 (temporal, nasal, down, up); the right eye is mirrored (1.0,1.7321,1.1918,1.0). The render FOV
is s x these tangents (--fov-scale). drawable mode reads the view tangents from capture.json.
--region crops one eye out of a side-by-side frame (the overlay PNG is that crop); predicted_px and measured_px are in
source-image coordinates. residual_deg is signed in the image direction (+ right/down). Linear RGB is written as 8-bit
values directly (no gamma). Exit code 0 PASS, 1 FAIL, 2 bad input. Python 3.9+, standard library only.
"""
import argparse
import bisect
import importlib.util
import json
import math
from pathlib import Path
import statistics
import struct
import sys
import zlib

_spec = importlib.util.spec_from_file_location('verify_capture', Path(__file__).with_name('verify-capture.py'))
vc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vc)

D = math.pi / 180
F = {'T': 1.7321, 'N': 1.0, 'U': 1.0, 'D': 1.1918}
WT, HT = F['T'] + F['N'], F['U'] + F['D']
REN = (3648, 2912)
VT = {'T': math.tan(45 * D), 'N': math.tan(30 * D), 'U': math.tan(30 * D), 'D': math.tan(35 * D)}
VN = {'UT': 3, 'UN': 2, 'LN': 1.5, 'LT': 4}

BG = {'L': (0.06, 0.06, 0.12), 'R': (0.12, 0.06, 0.06)}
GREEN, MAGENTA, WHITE = (0, 1, 0), (1, 0, 1), (1, 1, 1)
MIN_CONTRAST = 0.15
PASS_MEDIAN_DEG, PASS_MAX_DEG, PASS_EXTENT_DEG, PASS_FOUND = 0.1, 0.5, 0.5, 0.5


# ---- page maths (frustum-pixel-map.html, section 7) --------------------------------------------------------------

def quad_n(x, y):
    return (VN['UN'] if x >= 0 else VN['UT']) if y >= 0 else (VN['LN'] if x >= 0 else VN['LT'])


def in_v(x, y):
    """x nose-positive."""
    a = VT['N'] if x >= 0 else VT['T']
    b = VT['U'] if y >= 0 else VT['D']
    n = quad_n(x, y)
    return (abs(x) / a) ** n + (abs(y) / b) ** n <= 1


def v_boundary(npts):
    pts = []
    for i in range(npts + 1):
        phi = i / npts * 2 * math.pi
        c, s = math.cos(phi), math.sin(phi)
        a = VT['T'] if c >= 0 else VT['N']
        b = VT['U'] if s >= 0 else VT['D']
        n = quad_n(-c, s)
        rho = 1 / ((abs(c) / a) ** n + (abs(s) / b) ** n) ** (1 / n)
        pts.append((-rho * c, rho * s))
    return pts


def v_stats(g=600):
    a = 0.0
    dx, dy = WT / g, HT / g
    for i in range(g):
        x = -F['T'] + (i + .5) * dx
        for j in range(g):
            if in_v(x, -F['D'] + (j + .5) * dy):
                a += dx * dy
    return {'area': a / (WT * HT)}


def fov_axis(c, s, r, n):
    """ALVR foveation per axis (FFR.cpp CalculateFoveationVars): c centre size, s shift, r edge ratio, n render px."""
    if c >= 0.999 or r <= 1.0001:
        return {'c': 1.0, 's': 0.0, 'r': 1.0, 'f': 1.0, 'opt': float(n), 'coded': int(math.ceil(n / 32) * 32)}
    edge = n - c * n
    ca = 1 - math.ceil(edge / (r * 2)) * (r * 2) / n
    ea = n - ca * n
    sa = math.ceil(s * ea / (r * 2)) * (r * 2) / ea if ea else 0.0
    f = ca + (1 - ca) / r
    opt = f * n
    return {'c': ca, 's': max(-1.0, min(1.0, sa)), 'r': r, 'f': f, 'opt': opt, 'coded': int(math.ceil(opt / 32) * 32)}


def u_of_c(C, a):
    """Encoded fraction C (0..1 of the unpadded coded width) -> render fraction u."""
    if a['f'] >= 0.9999:
        return C
    c, r = a['c'], a['r']
    c0, c2 = (1 - c) / 2, (r - 1) * c + 1
    f = c2 / r

    def left(C, s):
        c1 = (r - 1) * c0 * (s + 1) / r
        lo = c0 * (s + 1) / c2
        if lo <= 0:
            return C * f + c1
        g = C / lo
        return g * (C * f + c1) + (1 - g) * (C * c2)

    lo = c0 * (a['s'] + 1) / c2
    hi = c0 * (a['s'] - 1) / c2 + 1
    if C < lo:
        return left(C, a['s'])
    if C > hi:
        return 1 - left(1 - C, -a['s'])
    return C * f + (r - 1) * c0 * (a['s'] + 1) / r


def c_of_u(u, a):
    if a['f'] >= 0.9999:
        return u
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if u_of_c(mid, a) < u:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def squeeze(C, a):
    """q = (du/dC)/f, the page's squeeze factor at encoded fraction C."""
    if a['f'] >= 0.9999:
        return 1.0
    h = 1e-6
    c = min(max(C, h), 1 - h)
    return (u_of_c(c + h, a) - u_of_c(c - h, a)) / (2 * h) / a['f']


def centre_shift(cx, cy):
    return [(F['T'] / WT - 0.5) / (((1 - cx) / 2) or 1), (F['U'] / HT - 0.5) / (((1 - cy) / 2) or 1)]


def band_fractions(a):
    """Render-fraction span of the 1:1 band."""
    if a['f'] >= 0.9999:
        return 0.0, 1.0
    return (1 - a['c']) / 2 * (1 + a['s']), (1 - a['c']) / 2 * (a['s'] - 1) + 1


def page_model(L):
    """The page's build(): lever state {s, rs, cx, cy, r, shx, shy} on the standard device (left eye)."""
    W, H = round(REN[0] * L['rs']), round(REN[1] * L['rs'])
    ax, ay = fov_axis(L['cx'], L['shx'], L['r'], W), fov_axis(L['cy'], L['shy'], L['r'], H)
    s = L['s']
    m = {'L': L, 'W': W, 'H': H, 'ax': ax, 'ay': ay, 's': s, 'sT': s * F['T'], 'sL': s * F['T'], 'sN': s * F['N'],
         'sU': s * F['U'], 'sD': s * F['D']}
    m['sW'], m['sH'] = m['sT'] + m['sN'], m['sU'] + m['sD']
    m['kx'], m['ky'] = W / m['sW'], H / m['sH']
    u0, u1 = band_fractions(ax)
    v0, v1 = band_fractions(ay)
    m['band'] = {'x0': -m['sT'] + u0 * m['sW'], 'x1': -m['sT'] + u1 * m['sW'],
                 'yTop': m['sU'] - v0 * m['sH'], 'yBot': m['sU'] - v1 * m['sH']}
    return m


def detail_h(m, th):
    x = math.tan(th * D)
    if x < -m['sT'] or x > m['sN']:
        return None
    C = c_of_u((x + m['sT']) / m['sW'], m['ax'])
    return m['kx'] / squeeze(C, m['ax']) * (1 + x * x) * D


def detail_v(m, ph):
    y = math.tan(ph * D)
    if y > m['sU'] or y < -m['sD']:
        return None
    C = c_of_u((m['sU'] - y) / m['sH'], m['ay'])
    return m['ky'] / squeeze(C, m['ay']) * (1 + y * y) * D


# ---- axes ---------------------------------------------------------------------------------------------------------
# tau increases with pixel index: tau = x tangent for columns, -y tangent for rows.

class Axis:
    mode = ''

    def __init__(self, lo, hi, n_render, limit, length):
        self.lo, self.hi = lo, hi          # stream (render FOV) tangent range
        self.n_render = n_render
        self.limit = limit                 # pixels beyond this hold no stream (padding)
        self.length = length               # image length in px

    def cell(self, i):
        """(fraction of pixel i inside the stream, tau range of that part)."""
        pa, pb = float(i), min(i + 1.0, self.limit)
        if pb <= pa:
            return 0.0, 0.0, 0.0
        ta, tb = self.tau(pa), self.tau(pb)
        sa, sb = max(ta, self.lo), min(tb, self.hi)
        if sb <= sa or tb <= ta:
            return 0.0, ta, tb
        return (pb - pa) * (sb - sa) / (tb - ta), sa, sb

    def t_of(self, tau):
        return (tau - self.lo) / (self.hi - self.lo)

    def span(self):
        """Pixel range [a, b] holding the whole stream."""
        return self.px(self.lo), self.px(self.hi)


class RenderAxis(Axis):
    mode = 'render'

    def __init__(self, lo, hi, n, shift=0):
        Axis.__init__(self, lo, hi, n, n, n)
        self.shift = shift                 # source-image offset of the render image (--region)

    def px(self, tau):
        return self.t_of(tau) * self.n_render + self.shift

    def tau(self, px):
        return self.lo + (px - self.shift) / self.n_render * (self.hi - self.lo)


class EncodedAxis(Axis):
    mode = 'encoded'

    def __init__(self, lo, hi, n, fov, shift=0):
        Axis.__init__(self, lo, hi, n, fov['opt'], fov['coded'])
        self.fov = fov
        self.shift = shift

    def px(self, tau):
        return self.fov['opt'] * c_of_u(min(1.0, max(0.0, self.t_of(tau))), self.fov) + self.shift

    def tau(self, px):
        return self.lo + u_of_c(min(1.0, max(0.0, (px - self.shift) / self.fov['opt'])), self.fov) * (self.hi - self.lo)


class DrawableAxis(Axis):
    mode = 'drawable'

    def __init__(self, lo, hi, n_render, view_lo, view_hi, origin, extent, table):
        Axis.__init__(self, lo, hi, n_render, table[-1], int(math.ceil(table[-1])))
        self.view_lo, self.view_hi, self.origin, self.extent, self.table = view_lo, view_hi, origin, extent, table

    def px(self, tau):
        return vc.interpolate(self.table, self.origin + self.extent * (tau - self.view_lo) / (self.view_hi - self.view_lo))

    def tau(self, px):
        logical = vc.inverse(self.table, px)
        return self.view_lo + (logical - self.origin) / self.extent * (self.view_hi - self.view_lo)


def make_axis(kind, mode, lo, hi, n_render, fov=None, drawable=None, shift=0):
    if mode == 'render':
        return RenderAxis(lo, hi, n_render, shift)
    if mode == 'encoded':
        return EncodedAxis(lo, hi, n_render, fov or fov_axis(1, 0, 1, n_render), shift)
    return DrawableAxis(lo, hi, n_render, *drawable)


def chart_lines(kind, lo, hi, n_render):
    """[(signed angle deg, tau centre, width render px, half width in tau)] for the chart lines inside [lo, hi]."""
    out = []
    for k in range(-17, 18):
        a = 5 * k
        t = math.tan(a * D) if kind == 'h' else -math.tan(a * D)
        w = 7 if k == 0 else 5 if a % 15 == 0 else 3
        hw = w / 2 * (hi - lo) / n_render
        if lo + hw <= t <= hi - hw:
            out.append((a, t, w, hw))
    return out


# ---- synthetic images ---------------------------------------------------------------------------------------------

def _rgb8(c):
    return bytes(max(0, min(255, int(round(v * 255)))) for v in c)


def _mix(bg, cv, ch):
    out = []
    for k in range(3):
        v = bg[k] * (1 - cv) * (1 - ch) + GREEN[k] * cv * (1 - ch) + MAGENTA[k] * ch * (1 - cv) + WHITE[k] * cv * ch
        out.append(v)
    return out


def _coverage(axis, kind, i, point):
    """(stream fraction, line coverage) of pixel i along an axis (kind 'h' columns, 'v' rows)."""
    frac, a, b = axis.cell(i)
    if frac <= 0:
        return 0.0, 0.0
    cover = 0.0
    for _angle, t, _w, hw in chart_lines(kind, axis.lo, axis.hi, axis.n_render):
        if point:
            tc = (a + b) / 2
            cover = 1.0 if abs(tc - t) <= hw else cover
        else:
            o = min(b, t + hw) - max(a, t - hw)
            if o > 0:
                cover = min(1.0, cover + o / (b - a))
    return frac, cover


def synth_image(xaxis, yaxis, eye, point=False):
    w, h = xaxis.length, yaxis.length
    bg = BG[eye]
    cols = [_coverage(xaxis, 'h', i, point) for i in range(w)]
    rows = [_coverage(yaxis, 'v', j, point) for j in range(h)]
    cache, rowcache, out = {}, {}, bytearray()
    for fy, ch in rows:
        key = (round(fy, 6), round(ch, 6))
        row = rowcache.get(key)
        if row is None:
            parts = []
            for fx, cv in cols:
                pk = (round(fx, 6), round(cv, 6)) + key
                px = cache.get(pk)
                if px is None:
                    f = fx * fy
                    px = _rgb8([v * f for v in _mix(bg, cv, ch)]) + b'\xff'
                    cache[pk] = px
                parts.append(px)
            row = b''.join(parts)
            rowcache[key] = row
        out += row
    return out


def synth_render(w, h, tangents, s, eye):
    left, right, down, up = tangents
    x = make_axis('h', 'render', -s * left, s * right, w)
    y = make_axis('v', 'render', -s * up, s * down, h)
    return synth_image(x, y, eye, point=True)


def synth_encoded(w, h, tangents, s, eye, fov):
    left, right, down, up = tangents
    x = make_axis('h', 'encoded', -s * left, s * right, w, fov=fov[0])
    y = make_axis('v', 'encoded', -s * up, s * down, h, fov=fov[1])
    return synth_image(x, y, eye), x.length, y.length


def rate_table(logical, physical, rmin=0.35):
    """Apple-like monotone screen->physical table: full rate in the middle, falling to rmin at the edges."""
    rates = []
    for i in range(logical):
        t = abs((i + .5) / logical - .5) * 2
        rates.append(1.0 if t < 0.3 else 1 - (1 - rmin) * (t - 0.3) / 0.7)
    scale = physical / sum(rates)
    table, acc = [0.0], 0.0
    for r in rates:
        acc += r * scale
        table.append(acc)
    return table


def synth_drawable(directory, w, h, logical, tangents, s, render, eye):
    directory.mkdir(parents=True, exist_ok=True)
    left, right, down, up = tangents
    xt, yt = rate_table(logical[0], w), rate_table(logical[1], h)
    x = make_axis('h', 'drawable', -s * left, s * right, render[0], drawable=(-left, right, 0, logical[0], xt))
    y = make_axis('v', 'drawable', -s * up, s * down, render[1], drawable=(-up, down, 0, logical[1], yt))
    pix = synth_image(x, y, eye)
    vc.write_png(directory / 'slice.png', w, h, bytes(pix))
    meta = {'corner_chart': {'mode': 'Off', 'ring_percents': []}, 'trigger': 'synth', 'slices': [{
        'eye': eye, 'view': 0, 'slice': 0, 'png': 'slice.png', 'width': w, 'height': h,
        'viewport': [0, 0, logical[0], logical[1]], 'tangents': [left, right, down, up],
        'rate_map': {'screen_w': logical[0], 'screen_h': logical[1], 'physical_x': xt, 'physical_y': yt, 'layer': 0}}]}
    (directory / 'capture.json').write_text(json.dumps(meta))


# ---- measurement --------------------------------------------------------------------------------------------------

def sample_indices(lo, hi, count):
    lo, hi = int(math.ceil(lo)), int(math.floor(hi))
    if hi < lo:
        return []
    if hi - lo + 1 <= count:
        return list(range(lo, hi + 1))
    return [lo + (hi - lo) * k // (count - 1) for k in range(count)]


def profile(pix, width, region, kind, other_span, count=96):
    """Mean line signal across the other axis, skipping rows/columns that are themselves the other colour's line.

    kind 'v' = vertical lines: a profile over columns (green minus the larger of red and blue);
    kind 'h' = horizontal lines: a profile over rows (min(red, blue) minus green)."""
    x0, y0, w, h = region
    vertical = kind == 'v'
    n = w if vertical else h
    prof, used = [0.0] * n, 0
    for k in sample_indices(other_span[0], other_span[1], count):
        if vertical:
            base = ((y0 + k) * width + x0) * 4
            row = pix[base:base + w * 4]
        else:
            base = (y0 * width + x0 + k) * 4
            row = None
        if vertical:
            r, g, b = row[0::4], row[1::4], row[2::4]
        else:
            stride, end = width * 4, base + (h - 1) * width * 4 + 1
            r, g, b = pix[base:end:stride], pix[base + 1:end + 1:stride], pix[base + 2:end + 2:stride]
        if vertical:
            sig = [gg - (rr if rr > bb else bb) for rr, gg, bb in zip(r, g, b)]
            other = sum(1 for rr, gg, bb in zip(r, g, b) if (rr if rr < bb else bb) - gg > 128)
        else:
            sig = [(rr if rr < bb else bb) - gg for rr, gg, bb in zip(r, g, b)]
            other = sum(1 for rr, gg, bb in zip(r, g, b) if gg - (rr if rr > bb else bb) > 128)
        if other > 0.5 * n or not any(r) and not any(g) and not any(b):
            continue
        used += 1
        for i, v in enumerate(sig):
            if v > 0:
                prof[i] += v
    if not used:
        return [0.0] * n, 0
    return [v / used / 255 for v in prof], used


def find_line(prof, lo_win, hi_win):
    i0, i1 = max(0, int(math.floor(lo_win))), min(len(prof), int(math.ceil(hi_win)))
    if i1 - i0 < 3:
        return None
    seg = prof[i0:i1]
    peak = max(seg)
    ip = seg.index(peak)
    base = sorted(seg)[len(seg) // 4]
    contrast = peak - base
    if contrast < MIN_CONTRAST:
        return None
    thr = base + 0.2 * contrast
    ia = ip
    while ia > 0 and seg[ia - 1] > thr:
        ia -= 1
    ib = ip
    while ib < len(seg) - 1 and seg[ib + 1] > thr:
        ib += 1
    ja, jb = max(0, ia - 1), min(len(seg) - 1, ib + 1)
    wsum = sum(max(0.0, seg[j] - base) for j in range(ja, jb + 1))
    centre = sum((i0 + j + .5) * max(0.0, seg[j] - base) for j in range(ja, jb + 1)) / wsum
    half = base + contrast / 2
    fwhm = None
    j = ip
    while j > 0 and seg[j] > half:
        j -= 1
    left_cross = None
    if seg[j] <= half < seg[j + 1]:
        left_cross = i0 + j + .5 + (half - seg[j]) / (seg[j + 1] - seg[j])
    j = ip
    while j < len(seg) - 1 and seg[j] > half:
        j += 1
    right_cross = None
    if seg[j] <= half < seg[j - 1]:
        right_cross = i0 + j + .5 - (half - seg[j]) / (seg[j - 1] - seg[j])
    if left_cross is not None and right_cross is not None:
        fwhm = right_cross - left_cross
    return {'centre': centre, 'fwhm': fwhm, 'contrast': contrast}


def stream_edges(pix, width, region, axis_kind, span):
    """First and last non-black index along an axis (median over a few rows/columns); None if it touches the crop."""
    x0, y0, w, h = region
    horizontal = axis_kind == 'h'
    n = w if horizontal else h
    other = (h if horizontal else w)
    firsts, lasts = [], []
    for k in sample_indices(other * 0.35, other * 0.65, 9):
        if horizontal:
            base = ((y0 + k) * width + x0) * 4
            v = [max(pix[base + 4 * i:base + 4 * i + 3]) for i in range(n)]
        else:
            base = (y0 * width + x0 + k) * 4
            v = [max(pix[base + 4 * width * i:base + 4 * width * i + 3]) for i in range(n)]
        idx = [i for i in range(n - 2) if v[i] > 6 and v[i + 1] > 6 and v[i + 2] > 6]
        if idx:
            firsts.append(idx[0])
            lasts.append(idx[-1] + 1)
    if not firsts:
        return None, None
    a, b = statistics.median(firsts) + (x0 if horizontal else y0), statistics.median(lasts) + (x0 if horizontal else y0)
    lo_edge, hi_edge = (x0 if horizontal else y0), (x0 + n if horizontal else y0 + n)
    return (None if a <= lo_edge + 1 else a), (None if b >= hi_edge - 1 else b)


def local_scale(axis, tau_of_deg, a_deg, h=0.25):
    return abs(axis.px(tau_of_deg(a_deg + h)) - axis.px(tau_of_deg(a_deg - h))) / (2 * h)


def analyse(mode, pix, width, height, region, xaxis, yaxis, eye, fov, tangents_note, band_fov):
    x0, y0, w, h = region
    xspan = xaxis.span()
    yspan = yaxis.span()
    rel_x = (max(0.0, xspan[0] - x0) + 2, min(w, xspan[1] - x0) - 2)
    rel_y = (max(0.0, yspan[0] - y0) + 2, min(h, yspan[1] - y0) - 2)
    lines = []
    page_scale = mode in ('render', 'encoded')
    for kind, name, axis, off, other, n_axis, fv in (('v', 'vertical', xaxis, x0, rel_y, w, fov[0]),
                                                      ('h', 'horizontal', yaxis, y0, rel_x, h, fov[1])):
        axkind = 'h' if kind == 'v' else 'v'
        specs = chart_lines(axkind, axis.lo, axis.hi, axis.n_render)
        preds = [(s, axis.px(s[1]) - off) for s in specs]
        preds = sorted(((s, p) for s, p in preds if 0 <= p < n_axis), key=lambda sp: sp[1])
        prof, used = profile(pix, width, region, kind, other)
        u0, u1 = band_fractions(fv)
        for idx, (spec, p) in enumerate(preds):
            angle, tau, wpx, hw = spec
            prev_p = preds[idx - 1][1] if idx > 0 else None
            next_p = preds[idx + 1][1] if idx + 1 < len(preds) else None
            below = (p - prev_p) / 2 if prev_p is not None else ((next_p - p) / 2 if next_p is not None else 10)
            above = (next_p - p) / 2 if next_p is not None else below
            found = find_line(prof, p - below, p + above) if used else None
            t = axis.t_of(tau)
            zone = 'band' if u0 - 1e-9 <= t <= u1 + 1e-9 else 'edge'
            tau_of = (lambda a: math.tan(a * D)) if axkind == 'h' else (lambda a: -math.tan(a * D))
            scale = local_scale(axis, tau_of, angle)
            if page_scale and mode == 'render':
                page = n_axis_render(axis) / (axis.hi - axis.lo) * (1 + tau * tau) * D
            elif page_scale:
                C = c_of_u(t, fv)
                page = axis.n_render / (axis.hi - axis.lo) / squeeze(C, fv) * (1 + tau * tau) * D
            else:
                page = None
            nominal = 2 * hw / (1 + tau * tau) / D
            rec = {'kind': name, 'angle_deg': angle, 'predicted_px': p + off, 'measured_px': None, 'residual_px': None,
                   'residual_deg': None, 'fwhm_px': None, 'fwhm_deg': None, 'contrast': None, 'zone': zone,
                   'nominal_width_deg': nominal, 'predicted_px_per_deg': page if page is not None else scale,
                   'local_px_per_deg': scale}
            if found:
                rec['measured_px'] = found['centre'] + off
                rec['residual_px'] = found['centre'] - p
                rec['residual_deg'] = rec['residual_px'] / scale
                rec['contrast'] = found['contrast']
                if found['fwhm'] is not None:
                    rec['fwhm_px'] = found['fwhm']
                    rec['fwhm_deg'] = found['fwhm'] / scale
            lines.append(rec)
    return lines


def n_axis_render(axis):
    return axis.n_render


def extent_report(mode, xaxis, yaxis, edges):
    sides = {'left': (xaxis, xaxis.lo, 0), 'right': (xaxis, xaxis.hi, 1), 'up': (yaxis, yaxis.lo, 0), 'down': (yaxis, yaxis.hi, 1)}
    out = {}
    for side, (axis, tau, hi_side) in sides.items():
        pred = math.degrees(math.atan(abs(tau)))
        meas = None
        if edges and edges.get(side) is not None:
            meas = math.degrees(math.atan(abs(axis.tau(edges[side]))))
        out[side] = {'predicted_deg': pred, 'measured_deg': meas, 'error_deg': None if meas is None else meas - pred}
    return out


def summarise(lines, extent, params):
    found = [l for l in lines if l['measured_px'] is not None]
    res = [abs(l['residual_deg']) for l in found]
    s = {'n_predicted': len(lines), 'n_found': len(found),
         'median_abs_residual_deg': statistics.median(res) if res else None,
         'max_abs_residual_deg': max(res) if res else None,
         'stream_extent_deg': extent, 'zones': {}}
    for zone in ('band', 'edge'):
        zl = [l for l in lines if l['zone'] == zone]
        fw = [l for l in zl if l['fwhm_px'] is not None and l['measured_px'] is not None]
        s['zones'][zone] = {
            'n_predicted': len(zl), 'n_found': sum(1 for l in zl if l['measured_px'] is not None),
            'median_fwhm_deg': statistics.median(l['fwhm_deg'] for l in fw) if fw else None,
            'implied_px_per_deg': statistics.median(l['fwhm_px'] / l['nominal_width_deg'] for l in fw) if fw else None,
            'predicted_px_per_deg': statistics.median(l['predicted_px_per_deg'] for l in zl) if zl else None}
    reasons = []
    if not found:
        reasons.append('no lines found')
    else:
        if s['n_found'] < PASS_FOUND * s['n_predicted']:
            reasons.append('found %d of %d predicted lines' % (s['n_found'], s['n_predicted']))
        if s['median_abs_residual_deg'] > PASS_MEDIAN_DEG:
            reasons.append('median residual %.3f deg > %.1f' % (s['median_abs_residual_deg'], PASS_MEDIAN_DEG))
        if s['max_abs_residual_deg'] > PASS_MAX_DEG:
            reasons.append('max residual %.3f deg > %.1f' % (s['max_abs_residual_deg'], PASS_MAX_DEG))
    for side, e in extent.items():
        if e['error_deg'] is not None and abs(e['error_deg']) > PASS_EXTENT_DEG:
            reasons.append('stream extent %s off by %.2f deg' % (side, e['error_deg']))
    s['verdict'] = 'FAIL' if reasons else 'PASS'
    s['verdict_reasons'] = reasons
    s['params'] = params
    return s


# ---- overlay ------------------------------------------------------------------------------------------------------

CYAN, YELLOW, ORANGE, WHITE8, RED = (0, 200, 255), (255, 255, 0), (255, 140, 0), (255, 255, 255), (255, 0, 0)


class Canvas:
    def __init__(self, pix, width, region):
        x0, y0, w, h = region
        self.w, self.h = w, h
        dim = bytes(int(i * 0.4) for i in range(256))
        buf = bytearray(b''.join(pix[((y0 + j) * width + x0) * 4:((y0 + j) * width + x0 + w) * 4] for j in range(h)))
        buf = bytearray(bytes(buf).translate(dim))
        buf[3::4] = b'\xff' * (w * h)
        self.buf = buf

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 4
            self.buf[i:i + 3] = bytes(c)

    def vline(self, x, c, y0=0, y1=None, step=1):
        x = int(math.floor(x))
        for y in range(max(0, y0), self.h if y1 is None else min(self.h, y1), step):
            self.put(x, y, c)

    def hline(self, y, c, x0=0, x1=None, step=1):
        y = int(math.floor(y))
        for x in range(max(0, x0), self.w if x1 is None else min(self.w, x1), step):
            self.put(x, y, c)

    def segment(self, a, b, c):
        (xa, ya), (xb, yb) = a, b
        n = int(max(abs(xb - xa), abs(yb - ya))) + 1
        if n > 20000:
            return
        for k in range(n + 1):
            t = k / n
            self.put(int(math.floor(xa + (xb - xa) * t)), int(math.floor(ya + (yb - ya) * t)), c)


def draw_overlay(canvas, region, xaxis, yaxis, lines, eye, fov, show_band, show_stream):
    x0, y0, w, h = region
    sx = lambda tau: xaxis.px(tau) - x0
    sy = lambda tau: yaxis.px(tau) - y0
    for l in lines:
        p = l['predicted_px']
        if l['kind'] == 'vertical':
            canvas.vline(p - x0, CYAN)
        else:
            canvas.hline(p - y0, CYAN)
    if show_stream:
        for tau, axis, off, vert in ((xaxis.lo, xaxis, x0, True), (xaxis.hi, xaxis, x0, True),
                                     (yaxis.lo, yaxis, y0, False), (yaxis.hi, yaxis, y0, False)):
            p = axis.px(tau) - off
            if vert and 0 <= p < w:
                canvas.vline(p, ORANGE)
            elif not vert and 0 <= p < h:
                canvas.hline(p, ORANGE)
    if show_band:
        u0, u1 = band_fractions(fov[0])
        v0, v1 = band_fractions(fov[1])
        bx0 = sx(xaxis.lo + u0 * (xaxis.hi - xaxis.lo))
        bx1 = sx(xaxis.lo + u1 * (xaxis.hi - xaxis.lo))
        by0 = sy(yaxis.lo + v0 * (yaxis.hi - yaxis.lo))
        by1 = sy(yaxis.lo + v1 * (yaxis.hi - yaxis.lo))
        for bx in (bx0, bx1):
            canvas.vline(bx, RED, int(by0), int(by1) + 1)
        for by in (by0, by1):
            canvas.hline(by, RED, int(bx0), int(bx1) + 1)
    pts = [(sx(xn if eye == 'L' else -xn), sy(-y)) for xn, y in v_boundary(480)]
    for a, b in zip(pts, pts[1:]):
        canvas.segment(a, b, WHITE8)
    for l in lines:
        if l['measured_px'] is None:
            continue
        if l['kind'] == 'vertical':
            m = l['measured_px'] - x0
            canvas.vline(m, YELLOW, 0, 14)
            canvas.vline(m, YELLOW, h - 14, h)
        else:
            m = l['measured_px'] - y0
            canvas.hline(m, YELLOW, 0, 14)
            canvas.hline(m, YELLOW, w - 14, w)


# ---- CLI ----------------------------------------------------------------------------------------------------------

def pair(text, kind=float, count=None, name='value'):
    try:
        parts = [kind(p) for p in text.split(',')]
    except ValueError:
        raise ValueError('bad %s: %r' % (name, text))
    if count and len(parts) != count:
        raise ValueError('%s needs %d comma-separated values' % (name, count))
    return parts


def size_arg(text, name):
    try:
        w, h = text.lower().split('x')
        return int(w), int(h)
    except ValueError:
        raise ValueError('%s must be WxH' % name)


def parse_foveation(text, render):
    if text is None or text.lower() == 'off':
        return [fov_axis(1, 0, 1, render[0]), fov_axis(1, 0, 1, render[1])]
    cx, cy, rx, ry, shx, shy = pair(text, float, 6, '--foveation')
    return [fov_axis(cx, shx, rx, render[0]), fov_axis(cy, shy, ry, render[1])]


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('mode', choices=['render', 'encoded', 'drawable', 'synth'])
    p.add_argument('--image', type=Path)
    p.add_argument('--capture-dir', type=Path)
    p.add_argument('--eye', choices=['L', 'R'], default='L')
    p.add_argument('--region', help='x,y,w,h crop of the image (e.g. one eye of a side-by-side frame)')
    p.add_argument('--tangents', help='L,R,D,U |tan| of the unscaled device FOV (default: device, mirrored for R)')
    p.add_argument('--fov-scale', type=float, default=1.0)
    p.add_argument('--render', help='WxH per eye (default: 3648x2912; render mode: the region size)')
    p.add_argument('--foveation', help='cx,cy,rx,ry,shx,shy or off (default off)')
    p.add_argument('--out-png')
    p.add_argument('--out-json')
    p.add_argument('--kind', choices=['render', 'encoded', 'drawable'], help='synth: which image to write')
    p.add_argument('--out-dir', type=Path, help='synth drawable: capture directory to write')
    p.add_argument('--phys', default='2432x2368', help='synth drawable: physical texture size')
    p.add_argument('--logical', default='6261x5023', help='synth drawable: logical screen size')
    return p


def device_tangents(eye, text):
    if text:
        return tuple(pair(text, float, 4, '--tangents'))
    return (F['T'], F['N'], F['D'], F['U']) if eye == 'L' else (F['N'], F['T'], F['D'], F['U'])


def do_synth(a):
    render = size_arg(a.render or '%dx%d' % REN, '--render')
    tangents = device_tangents(a.eye, a.tangents)
    if a.kind == 'render':
        pix = synth_render(render[0], render[1], tangents, a.fov_scale, a.eye)
        vc.write_png(a.out_png, render[0], render[1], bytes(pix))
    elif a.kind == 'encoded':
        fov = parse_foveation(a.foveation, render)
        pix, w, h = synth_encoded(render[0], render[1], tangents, a.fov_scale, a.eye, fov)
        vc.write_png(a.out_png, w, h, bytes(pix))
    else:
        phys, logical = size_arg(a.phys, '--phys'), size_arg(a.logical, '--logical')
        synth_drawable(a.out_dir, phys[0], phys[1], logical, tangents, a.fov_scale, render, a.eye)
    return 0


def run_measure(a):
    mode = a.mode
    s = a.fov_scale
    if mode == 'drawable':
        if not a.capture_dir:
            raise ValueError('drawable needs --capture-dir')
        meta = json.loads((a.capture_dir / 'capture.json').read_text())
        sl = next((x for x in meta['slices'] if x['eye'] == a.eye), None)
        if sl is None:
            raise ValueError('no %s slice in capture.json' % a.eye)
        width, height, pix = vc.read_png(a.capture_dir / sl['png'])
        if (width, height) != (sl['width'], sl['height']):
            raise ValueError('texture/PNG size mismatch')
        tangents = tuple(sl['tangents'])
    else:
        if not a.image:
            raise ValueError('%s needs --image' % mode)
        width, height, pix = vc.read_png(a.image)
        tangents = device_tangents(a.eye, a.tangents)
    region = tuple(int(v) for v in pair(a.region, float, 4, '--region')) if a.region else (0, 0, width, height)
    x0, y0, w, h = region
    if w <= 0 or h <= 0 or x0 < 0 or y0 < 0 or x0 + w > width or y0 + h > height:
        raise ValueError('--region outside the image')
    if a.render:
        render = size_arg(a.render, '--render')
    else:
        render = (w, h) if mode == 'render' else REN
    left, right, down, up = tangents
    lo_x, hi_x, lo_y, hi_y = -s * left, s * right, -s * up, s * down
    fov = parse_foveation(a.foveation, render)
    if mode == 'render':
        xaxis = make_axis('h', 'render', lo_x, hi_x, render[0], shift=x0)
        yaxis = make_axis('v', 'render', lo_y, hi_y, render[1], shift=y0)
    elif mode == 'encoded':
        xaxis = make_axis('h', 'encoded', lo_x, hi_x, render[0], fov=fov[0], shift=x0)
        yaxis = make_axis('v', 'encoded', lo_y, hi_y, render[1], fov=fov[1], shift=y0)
    else:
        xt, yt = vc.tables(sl)
        vx, vy, vw, vh = sl['viewport']
        xaxis = make_axis('h', 'drawable', lo_x, hi_x, render[0], drawable=(-left, right, vx, vw, xt))
        yaxis = make_axis('v', 'drawable', lo_y, hi_y, render[1], drawable=(-up, down, vy, vh, yt))
    params = {'mode': mode, 'eye': a.eye, 'fov_scale': s, 'tangents_LRDU': list(tangents), 'render': list(render),
              'foveation': a.foveation or 'off', 'region': [x0, y0, w, h], 'image_size': [width, height]}
    if mode == 'encoded':
        params['coded_size_predicted'] = [fov[0]['coded'], fov[1]['coded']]
        if (w, h) != (fov[0]['coded'], fov[1]['coded']):
            params['coded_size_note'] = 'region differs from predicted coded size'
    lines = analyse(mode, pix, width, height, region, xaxis, yaxis, a.eye, fov, None, None)
    edges = None
    if mode == 'drawable':
        xa, xb = stream_edges(pix, width, region, 'h', None)
        ya, yb = stream_edges(pix, width, region, 'v', None)
        edges = {'left': xa, 'right': xb, 'up': ya, 'down': yb}
    extent = extent_report(mode, xaxis, yaxis, edges)
    summary = summarise(lines, extent, params)
    if a.out_png:
        canvas = Canvas(pix, width, region)
        draw_overlay(canvas, region, xaxis, yaxis, lines, a.eye, fov, a.foveation not in (None, 'off'), True)
        vc.write_png(a.out_png, w, h, bytes(canvas.buf))
    if a.out_json:
        Path(a.out_json).write_text(json.dumps({'summary': summary, 'lines': lines}, indent=1))
    z = summary['zones']
    print('{} eye={} fov_scale={}: found {}/{} lines, median |residual| {} deg, max {} deg'.format(
        mode, a.eye, s, summary['n_found'], summary['n_predicted'],
        'n/a' if summary['median_abs_residual_deg'] is None else '%.3f' % summary['median_abs_residual_deg'],
        'n/a' if summary['max_abs_residual_deg'] is None else '%.3f' % summary['max_abs_residual_deg']))
    for zone in ('band', 'edge'):
        if z[zone]['median_fwhm_deg'] is not None:
            print('  {}: {} lines, median FWHM {:.3f} deg, implied {:.1f} px/deg vs predicted {:.1f}'.format(
                zone, z[zone]['n_found'], z[zone]['median_fwhm_deg'], z[zone]['implied_px_per_deg'], z[zone]['predicted_px_per_deg']))
    for side, e in extent.items():
        if e['measured_deg'] is not None:
            print('  stream {}: measured {:.2f} deg, predicted {:.2f} deg'.format(side, e['measured_deg'], e['predicted_deg']))
    print('{}{}'.format(summary['verdict'], ''.join('; ' + r for r in summary['verdict_reasons'])))
    return 0 if summary['verdict'] == 'PASS' else 1


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        if a.mode == 'synth':
            if not a.kind:
                raise ValueError('synth needs --kind')
            if a.kind == 'drawable' and not a.out_dir:
                raise ValueError('synth drawable needs --out-dir')
            if a.kind != 'drawable' and not a.out_png:
                raise ValueError('synth %s needs --out-png' % a.kind)
            return do_synth(a)
        return run_measure(a)
    except (ValueError, KeyError, OSError, ZeroDivisionError, struct.error, zlib.error) as error:
        print('fov-overlay: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
