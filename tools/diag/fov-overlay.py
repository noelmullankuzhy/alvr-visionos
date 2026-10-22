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
            (assumption: when the views are canted the client sends circumscribed tangents, larger than s x view,
            RealityKit.swift:98-160 / Renderer.swift:962; pass --stream-tangents L,R,D,U to override)
  synth     write a synthetic image (--kind render|encoded|drawable) from the same parameters, for tests

--tangents L,R,D,U are literal |tan| of the render FOV's left/right/down/up (screen sides). Default device: left eye
1.7321,1.0,1.1918,1.0 (temporal, nasal, down, up); the right eye is mirrored (1.0,1.7321,1.1918,1.0). The render FOV
is s x these tangents (--fov-scale). --stream-tangents overrides that stream extent. --foveation is off unless given
(or --meta says "foveation": true): ALVR pads to 32 px whenever it is enabled, even at c=1. resolved px/deg is 1/PSF, per
degree of the PSF width, not a pixel count. --meta tangents already include s: do not also pass --fov-scale there.
drawable mode reads the view tangents from capture.json. Its pixels are measured sRGB-encoded: capture.json "encoding"
"srgb" is used as is, absent or "linear" (the client's raw drawable) is encoded first. The head-locked lines cannot test s,
so the stream extent is the check: an extent that is not measured (touches the crop, or the stream background is not
separable from the surround) FAILs as "stream extent unverified". capture.json pose.delta_deg {yaw, pitch, roll} (display
minus render, right-handed, yaw +Y, pitch +X, roll +Z, intrinsic Y-X-Z) is compensated in the predicted positions; without
it one yaw is fitted to the x lines and a pass is labelled PASS-after-fitted-yaw. Drawable px/deg (client pixels) are
reported apart from the stream (coded) px/deg that the sharpness and prediction use; resolvability is judged in stream px.
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
MIN_CONTRAST, NOISE_SIGMAS = 0.03, 6.0      # a line must stand 6 sigma of its window's background above it
PASS_MEDIAN_DEG, PASS_MAX_DEG, PASS_EXTENT_DEG, PASS_FOUND = 0.1, 0.5, 0.5, 0.5
MIN_RESOLVABLE_PX = 2.0                      # lines narrower than this in the image cannot show sharpness
SEP_MIN = 8                                  # the stream background must stand this many (sRGB) counts above the surround


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


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def _srgb_lut():
    out = bytearray(256)
    for i in range(256):
        x = i / 255
        out[i] = int(round((12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055) * 255))
    return bytes(out)


SRGB_LUT = _srgb_lut()


def srgb_encode(pix):
    """Linear-light RGBA bytes -> sRGB-encoded (alpha untouched)."""
    out = bytearray(pix)
    for c in range(3):
        out[c::4] = bytes(pix[c::4]).translate(SRGB_LUT)
    return out


class Pose:
    """Display-minus-render head rotation in degrees: right-handed, yaw about +Y, pitch +X, roll +Z, intrinsic Y-X-Z
    (R = Ry Rx Rz, the display camera's orientation relative to the render camera).

    warp() maps a head-locked chart direction (render frame) to where the display frame sees it, as the axis' tau
    ('x': tangent, 'y': minus the tangent; row index grows downward). Exact for a pure yaw; with pitch/roll it is the
    value on the chart's own centre line (the other tangent 0), so a line's tilt is ignored (first order)."""

    def __init__(self, yaw=0.0, pitch=0.0, roll=0.0):
        self.angles = (yaw, pitch, roll)
        cy, sy, cp, sp, cr, sr = (math.cos(yaw * D), math.sin(yaw * D), math.cos(pitch * D), math.sin(pitch * D),
                                  math.cos(roll * D), math.sin(roll * D))
        ry = ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))
        rx = ((1, 0, 0), (0, cp, -sp), (0, sp, cp))
        rz = ((cr, -sr, 0), (sr, cr, 0), (0, 0, 1))
        mul = lambda a, b: tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))
        self.matrix = mul(mul(ry, rx), rz)
        self.identity = not any(self.angles)

    def warp(self, axis, tau, inverse=False):
        if self.identity:
            return tau
        if inverse:                                 # display -> render: fixed point of t += target - warp(t)
            t = tau
            for _ in range(60):
                t += tau - self.warp(axis, t)
            return t
        v = (tau, 0.0, -1.0) if axis == 'x' else (0.0, -tau, -1.0)
        m = self.matrix                             # render -> display uses the transpose
        w = [sum(m[j][i] * v[j] for j in range(3)) for i in range(3)]
        if w[2] >= -1e-9:
            return tau                              # direction at or behind the display plane: not drawable
        return w[0] / -w[2] if axis == 'x' else w[1] / w[2]

    def delta(self):
        return {'yaw': self.angles[0], 'pitch': self.angles[1], 'roll': self.angles[2]}


def pose_from_capture(cap, sl):
    """pose.delta_deg of capture.json (or of the slice) -> Pose, or None when the capture does not carry one."""
    pose = cap.get('pose', sl.get('pose'))
    if not pose or pose.get('delta_deg') is None:
        return None
    try:
        d = pose['delta_deg']
        return Pose(float(d['yaw']), float(d['pitch']), float(d['roll']))
    except (KeyError, TypeError, ValueError):
        raise ValueError('capture.json pose.delta_deg must be {"yaw", "pitch", "roll"} in degrees')


def fov_axis(c, s, r, n):
    """ALVR foveation per axis (FFR.cpp CalculateFoveationVars): c centre size, s shift, r edge ratio, n render px.
    Foveation enabled pads to 32 even at c=1 (use fov_off for foveation disabled)."""
    # float32 as in FFR.cpp: settings and results are floats, the 1. / 2. literals promote to double
    c, s, r, n = f32(c), f32(s), f32(r), f32(n)
    edge = f32(n - f32(c * n))
    ca = f32(1. - math.ceil(edge / (r * 2.)) * (r * 2.) / n)
    ea = f32(n - f32(ca * n))
    sa = f32(math.ceil(f32(s * ea) / (r * 2.)) * (r * 2.) / ea) if ea else 0.0
    f = f32(ca + (1. - ca) / r)
    opt = f32(f * n)
    coded = int(math.ceil(f32(opt / 32.)) * 32)
    return {'c': ca, 's': sa, 'r': r, 'f': f, 'opt': opt, 'coded': coded}


def fov_off(n):
    """Foveation disabled (enableFoveatedEncoding false): the texture passes through, no 32 px padding."""
    return {'c': 1.0, 's': 0.0, 'r': 1.0, 'f': 1.0, 'opt': float(n), 'coded': int(n)}


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

    mirror = False                         # right-eye columns: ALVR foveates the mirrored eye image
    fov = None                             # foveation of this axis (page prediction, zones); None = off

    def __init__(self, lo, hi, n_render, valid, length):
        self.lo, self.hi = lo, hi          # stream (render FOV) tangent range
        self.n_render = n_render
        self.valid = valid                 # pixel range [a, b] holding the stream (the rest is padding)
        self.length = length               # image length in px

    def cell(self, i):
        """(fraction of pixel i inside the stream, tau range of that part)."""
        pa, pb = max(float(i), self.valid[0]), min(i + 1.0, self.valid[1])
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
        a, b = self.px(self.lo), self.px(self.hi)
        return min(a, b), max(a, b)

    def fov_or_off(self):
        return self.fov or fov_off(self.n_render)

    def band_t(self):
        """Span of the 1:1 band in stream fractions t (render image, left to right)."""
        u0, u1 = band_fractions(self.fov_or_off())
        return (1 - u1, 1 - u0) if self.mirror else (u0, u1)

    def page_px_per_deg(self, tau):
        """The page's delivered detail (render px/deg over the squeeze) at tangent tau on this axis."""
        fv = self.fov_or_off()
        t = self.t_of(tau)
        q = squeeze(c_of_u(1 - t if self.mirror else t, fv), fv)
        return self.n_render / (self.hi - self.lo) / q * (1 + tau * tau) * D


class RenderAxis(Axis):
    mode = 'render'

    def __init__(self, lo, hi, n, shift=0, fov=None, mirror=False):
        Axis.__init__(self, lo, hi, n, (0.0, n), n)
        self.shift = shift                 # source-image offset of the render image (--region)
        self.fov, self.mirror = fov, mirror

    def px(self, tau):
        return self.t_of(tau) * self.n_render + self.shift

    def tau(self, px):
        return self.lo + (px - self.shift) / self.n_render * (self.hi - self.lo)


class EncodedAxis(Axis):
    mode = 'encoded'

    def __init__(self, lo, hi, n, fov, shift=0, mirror=False):
        coded, opt = fov['coded'], fov['opt']
        # mirrored (right eye): the stream sits against the right end of the half, padding on the left
        Axis.__init__(self, lo, hi, n, (coded - opt, float(coded)) if mirror else (0.0, opt), coded)
        self.fov, self.shift, self.mirror = fov, shift, mirror

    def px(self, tau):
        t = min(1.0, max(0.0, self.t_of(tau)))
        opt = self.fov['opt']
        if self.mirror:
            return self.fov['coded'] - opt * c_of_u(1 - t, self.fov) + self.shift
        return opt * c_of_u(t, self.fov) + self.shift

    def tau(self, px):
        rel, opt = px - self.shift, self.fov['opt']
        if self.mirror:
            t = 1 - u_of_c(min(1.0, max(0.0, (self.fov['coded'] - rel) / opt)), self.fov)
        else:
            t = u_of_c(min(1.0, max(0.0, rel / opt)), self.fov)
        return self.lo + t * (self.hi - self.lo)


class DrawableAxis(Axis):
    mode = 'drawable'

    def __init__(self, lo, hi, n_render, view_lo, view_hi, origin, extent, table, fov=None, mirror=False, pose=None):
        Axis.__init__(self, lo, hi, n_render, (0.0, table[-1]), int(math.ceil(table[-1])))
        self.view_lo, self.view_hi, self.origin, self.extent, self.table = view_lo, view_hi, origin, extent, table
        self.fov, self.mirror = fov, mirror
        self.pose = pose                   # (Pose, 'x'|'y'): render frame -> display frame, tau stays the render-frame tangent

    def px(self, tau):
        if self.pose:
            tau = self.pose[0].warp(self.pose[1], tau)
        return vc.interpolate(self.table, self.origin + self.extent * (tau - self.view_lo) / (self.view_hi - self.view_lo))

    def tau(self, px):
        logical = vc.inverse(self.table, px)
        tau = self.view_lo + (logical - self.origin) / self.extent * (self.view_hi - self.view_lo)
        return self.pose[0].warp(self.pose[1], tau, inverse=True) if self.pose else tau


def make_axis(kind, mode, lo, hi, n_render, fov=None, drawable=None, shift=0, mirror=False, pose=None):
    """fov: this axis's foveation (geometry in encoded mode; zones and the page prediction in the others).
    mirror: right-eye columns."""
    if mode == 'render':
        return RenderAxis(lo, hi, n_render, shift, fov, mirror)
    if mode == 'encoded':
        return EncodedAxis(lo, hi, n_render, fov or fov_off(n_render), shift, mirror)
    return DrawableAxis(lo, hi, n_render, *drawable, fov=fov, mirror=mirror, pose=(pose, 'x' if kind == 'h' else 'y') if pose else None)


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
    x = make_axis('h', 'encoded', -s * left, s * right, w, fov=fov[0], mirror=eye == 'R')
    y = make_axis('v', 'encoded', -s * up, s * down, h, fov=fov[1])
    img = bytearray(synth_image(x, y, eye))
    # ALVR's padding holds stray full-width/height colour (seen on real frames): a line-like artefact the search must ignore
    xs, ys = x.span(), y.span()
    cx = max(0, int(xs[0]) - 8) if eye == 'R' else min(x.length - 1, int(xs[1]) + 8)
    cy = min(y.length - 1, int(ys[1]) + 8)
    if (cx < xs[0] - 2) if eye == 'R' else (cx > xs[1] + 2):
        for j in range(y.length):
            img[(j * x.length + cx) * 4:(j * x.length + cx) * 4 + 3] = b'\x00\xff\x00'
    if cy > ys[1] + 2:
        for i in range(x.length):
            img[(cy * x.length + i) * 4:(cy * x.length + i) * 4 + 3] = b'\xff\x00\xff'
    return bytes(img), x.length, y.length


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


def synth_drawable(directory, w, h, logical, tangents, s, render, eye, encoding='linear', pose=None):
    directory.mkdir(parents=True, exist_ok=True)
    left, right, down, up = tangents
    xt, yt = rate_table(logical[0], w), rate_table(logical[1], h)
    x = make_axis('h', 'drawable', -s * left, s * right, render[0], drawable=(-left, right, 0, logical[0], xt), pose=pose)
    y = make_axis('v', 'drawable', -s * up, s * down, render[1], drawable=(-up, down, 0, logical[1], yt), pose=pose)
    pix = synth_image(x, y, eye)
    if encoding == 'srgb':
        pix = srgb_encode(pix)
    vc.write_png(directory / 'slice.png', w, h, bytes(pix))
    meta = {'corner_chart': {'mode': 'Off', 'ring_percents': []}, 'trigger': 'synth', 'slices': [{
        'eye': eye, 'view': 0, 'slice': 0, 'png': 'slice.png', 'width': w, 'height': h,
        'viewport': [0, 0, logical[0], logical[1]], 'tangents': [left, right, down, up],
        'rate_map': {'screen_w': logical[0], 'screen_h': logical[1], 'physical_x': xt, 'physical_y': yt, 'layer': 0}}]}
    meta['pose'] = {'delta_deg': (pose or Pose()).delta()}
    if encoding == 'srgb':                      # linear (the client's raw drawable) is the absent default
        meta['encoding'] = 'srgb'
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
    srt = sorted(seg)
    base = srt[len(seg) // 4]
    low = srt[:max(3, 3 * len(seg) // 4)]               # the window without its line
    med = low[len(low) // 2]
    noise = 1.4826 * sorted(abs(v - med) for v in low)[len(low) // 2]
    contrast = peak - base
    if contrast < max(MIN_CONTRAST, NOISE_SIGMAS * noise):
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


def edge_levels(pix, width, region, xspan, yspan):
    """Surround and stream-background levels (max RGB), to find the stream border relative to the surround itself.

    surround = the lowest of the four outer strips' medians (the stream may reach one side); background = median over
    the middle of the predicted stream span. The border is separable when the background stands SEP_MIN above the surround."""
    x0, y0, w, h = region

    def level(x, y):
        i = ((y0 + y) * width + x0 + x) * 4
        return max(pix[i:i + 3])

    mw, mh = max(2, w // 100), max(2, h // 100)
    xs, ys = sample_indices(w * 0.1, w * 0.9, 15), sample_indices(h * 0.1, h * 0.9, 15)
    strips = ([(x, k) for k in range(mh) for x in xs], [(x, h - 1 - k) for k in range(mh) for x in xs],
              [(k, y) for k in range(mw) for y in ys], [(w - 1 - k, y) for k in range(mw) for y in ys])
    surround = min(_median(level(x, y) for x, y in pts) for pts in strips)
    inner = []
    for a, b in ((max(0.0, xspan[0] - x0), min(w, xspan[1] - x0)), (max(0.0, yspan[0] - y0), min(h, yspan[1] - y0))):
        pad = 0.1 * (b - a)
        inner.append(sample_indices(a + pad, b - pad, 9) if b > a else [])
    background = _median(level(x, y) for x in inner[0] for y in inner[1])
    ok = background is not None and background - surround >= SEP_MIN
    return {'surround': surround, 'background': background, 'separable': ok,
            'threshold': surround + (background - surround) / 2 if ok else None}


def stream_edges(pix, width, region, axis_kind, thr):
    """First and last index above thr along an axis (median over a few rows/columns); None if it touches the crop."""
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
        idx = [i for i in range(n) if v[i] > thr and v[min(i + 1, n - 1)] > thr and v[min(i + 2, n - 1)] > thr]
        if idx:
            firsts.append(idx[0])
            lasts.append(min(n, idx[-1] + 3))
    if not firsts:
        return None, None
    a, b = statistics.median(firsts) + (x0 if horizontal else y0), statistics.median(lasts) + (x0 if horizontal else y0)
    lo_edge, hi_edge = (x0 if horizontal else y0), (x0 + n if horizontal else y0 + n)
    return (None if a <= lo_edge + 1 else a), (None if b >= hi_edge - 1 else b)


def local_scale(axis, tau_of_deg, a_deg, h=0.25):
    return abs(axis.px(tau_of_deg(a_deg + h)) - axis.px(tau_of_deg(a_deg - h))) / (2 * h)


def analyse(pix, width, region, xaxis, yaxis, drawable=False):
    """drawable: sharpness is judged in stream (coded) px, not in the client drawable's px, which outnumber them."""
    x0, y0, w, h = region
    xspan, yspan = xaxis.span(), yaxis.span()
    rel_x = (max(0.0, xspan[0] - x0) + 2, min(w, xspan[1] - x0) - 2)
    rel_y = (max(0.0, yspan[0] - y0) + 2, min(h, yspan[1] - y0) - 2)
    lines = []
    for kind, name, axname, axis, off, other, n_axis, span in (('v', 'vertical', 'x', xaxis, x0, rel_y, w, xspan),
                                                               ('h', 'horizontal', 'y', yaxis, y0, rel_x, h, yspan)):
        axkind = 'h' if kind == 'v' else 'v'
        specs = chart_lines(axkind, axis.lo, axis.hi, axis.n_render)
        preds = sorted(((s, axis.px(s[1]) - off) for s in specs if 0 <= axis.px(s[1]) - off < n_axis), key=lambda sp: sp[1])
        prof, used = profile(pix, width, region, kind, other)
        t0, t1 = axis.band_t()
        tau_of = (lambda a: math.tan(a * D)) if axkind == 'h' else (lambda a: -math.tan(a * D))
        for idx, (spec, p) in enumerate(preds):
            angle, tau, wpx, hw = spec
            prev_p = preds[idx - 1][1] if idx > 0 else None
            next_p = preds[idx + 1][1] if idx + 1 < len(preds) else None
            below = (p - prev_p) / 2 if prev_p is not None else ((next_p - p) / 2 if next_p is not None else 10)
            above = (next_p - p) / 2 if next_p is not None else below
            # never search the padding beyond the stream (ALVR pads to 32 px; that area is not image content)
            lo_win, hi_win = max(p - below, span[0] - off), min(p + above, span[1] - off)
            found = find_line(prof, lo_win, hi_win) if used else None
            t = axis.t_of(tau)
            zone = 'band' if t0 - 1e-9 <= t <= t1 + 1e-9 else 'edge'
            scale = local_scale(axis, tau_of, angle)
            page = axis.page_px_per_deg(tau)
            nominal = 2 * hw / (1 + tau * tau) / D
            rec = {'kind': name, 'axis': axname, 'angle_deg': angle, 'predicted_px': p + off, 'measured_px': None,
                   'residual_px': None, 'residual_deg': None, 'fwhm_px': None, 'fwhm_deg': None, 'contrast': None,
                   'zone': zone, 'nominal_width_deg': nominal, 'nominal_width_px': nominal * scale,
                   'nominal_width_stream_px': nominal * page,
                   'predicted_px_per_deg': page, 'local_px_per_deg': scale, 'resolvable': False,
                   'psf_deg': None, 'sharpness_px_per_deg': None}
            if found:
                rec['measured_px'] = found['centre'] + off
                rec['residual_px'] = found['centre'] - p
                rec['residual_deg'] = rec['residual_px'] / scale
                rec['contrast'] = found['contrast']
                if found['fwhm'] is not None:
                    rec['fwhm_px'] = found['fwhm']
                    rec['fwhm_deg'] = found['fwhm'] / scale
                    if (rec['nominal_width_stream_px'] if drawable else rec['nominal_width_px']) >= MIN_RESOLVABLE_PX:
                        # the line's own width comes out in quadrature; what is left is the pipeline's blur
                        rec['resolvable'] = True
                        rec['psf_deg'] = math.sqrt(max(0.0, rec['fwhm_deg'] ** 2 - nominal ** 2))
                        rec['sharpness_px_per_deg'] = page * nominal / rec['fwhm_deg']
            lines.append(rec)
    return lines


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


def _median(values):
    values = list(values)
    return statistics.median(values) if values else None


def zone_stats(zl, drawable=False):
    """drawable: the client drawable's own px/deg is reported apart (its pixels are not the stream's coded pixels)."""
    rs = [l for l in zl if l['resolvable']]
    psf = _median(l['psf_deg'] for l in rs)
    return {
        'drawable_px_per_deg': _median(l['local_px_per_deg'] for l in zl) if drawable else None,
        'n_predicted': len(zl), 'n_found': sum(1 for l in zl if l['measured_px'] is not None), 'n_resolvable': len(rs),
        'median_fwhm_deg': _median(l['fwhm_deg'] for l in rs),
        'median_nominal_deg': _median(l['nominal_width_deg'] for l in rs),
        'psf_deg': psf,
        # 1 / PSF: how fine a detail the pipeline still resolves (None when the PSF is below measurement)
        'resolved_px_per_deg': 1 / psf if psf else None,
        # page prediction x nominal / FWHM: falls as the lines blur out; equals the prediction when sharp
        'sharpness_px_per_deg': _median(l['sharpness_px_per_deg'] for l in rs),
        # the same lines as the measurement (W16: median over resolvable lines vs median prediction over all of them)
        'predicted_px_per_deg': _median(l['predicted_px_per_deg'] for l in rs),
        'predicted_px_per_deg_all': _median(l['predicted_px_per_deg'] for l in zl)}


def summarise(lines, extent, params, foveated):
    """foveated: {'x': bool, 'y': bool}; the verdict is per axis, and per zone where an axis is foveated."""
    found = [l for l in lines if l['measured_px'] is not None]
    res = [abs(l['residual_deg']) for l in found]
    s = {'n_predicted': len(lines), 'n_found': len(found),
         'median_abs_residual_deg': _median(res), 'max_abs_residual_deg': max(res) if res else None,
         'stream_extent_deg': extent, 'zones': {}, 'axes': {}}
    for zone in ('band', 'edge'):
        s['zones'][zone] = zone_stats([l for l in lines if l['zone'] == zone], params.get('mode') == 'drawable')
    reasons = []
    for ax in ('x', 'y'):
        al = [l for l in lines if l['axis'] == ax]
        af = [l for l in al if l['measured_px'] is not None]
        ar = [abs(l['residual_deg']) for l in af]
        med, mx = _median(ar), (max(ar) if ar else None)
        s['axes'][ax] = {'n_predicted': len(al), 'n_found': len(af), 'median_abs_residual_deg': med, 'max_abs_residual_deg': mx}
        if not al:
            continue
        if not af:
            reasons.append('%s no lines found (of %d predicted)' % (ax, len(al)))
            continue
        if len(af) < PASS_FOUND * len(al):
            reasons.append('%s found %d of %d predicted lines' % (ax, len(af), len(al)))
        if med > PASS_MEDIAN_DEG:
            reasons.append('%s median residual %.3f deg > %.1f' % (ax, med, PASS_MEDIAN_DEG))
        if mx > PASS_MAX_DEG:
            reasons.append('%s max residual %.3f deg > %.1f' % (ax, mx, PASS_MAX_DEG))
        if foveated.get(ax):
            for zone in ('band', 'edge'):
                zl = [l for l in al if l['zone'] == zone]
                zf = [l for l in zl if l['measured_px'] is not None]
                if zl and len(zf) < PASS_FOUND * len(zl):
                    what = 'edge unverified' if zone == 'edge' else 'band lines missing'
                    reasons.append('%s %s (found %d of %d %s lines)' % (ax, what, len(zf), len(zl), zone))
    if not lines:
        reasons.append('no lines predicted inside the image')
    for side, e in extent.items():
        if e['error_deg'] is not None and abs(e['error_deg']) > PASS_EXTENT_DEG:
            reasons.append('stream extent %s off by %.2f deg' % (side, e['error_deg']))
    if params.get('mode') == 'drawable':
        # the head-locked lines cannot test s: the extent is the only check, so an unmeasured one is a failure
        missing = [side for side, e in extent.items() if e['measured_deg'] is None]
        if missing:
            lv, why = params.get('extent_levels'), ''
            if lv and not lv['separable']:
                why = '; stream background %s vs surround %s counts is not separable' % (lv['background'], lv['surround'])
            reasons.append('stream extent unverified (%s%s)' % (', '.join(missing), why))
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


def draw_overlay(canvas, region, xaxis, yaxis, lines, eye, show_band, show_stream):
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
        u0, u1 = xaxis.band_t()
        v0, v1 = yaxis.band_t()
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
        return [fov_off(render[0]), fov_off(render[1])]
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
    p.add_argument('--stream-tangents', help='L,R,D,U |tan| the stream really covers (default fov-scale x tangents; the client sends '
                   'larger circumscribed tangents when the views are canted)')
    p.add_argument('--meta', type=Path, help='ALVR angle-chart dump meta.json: tangents, render size, foveation, coded size')
    p.add_argument('--out-png')
    p.add_argument('--out-json')
    p.add_argument('--kind', choices=['render', 'encoded', 'drawable'], help='synth: which image to write')
    p.add_argument('--out-dir', type=Path, help='synth drawable: capture directory to write')
    p.add_argument('--encoding', choices=['linear', 'srgb'], default='linear', help='synth drawable: pixel transfer to write')
    p.add_argument('--pose-delta', default='0,0,0', help='synth drawable: yaw,pitch,roll degrees (display minus render) to bake in and record')
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
        synth_drawable(a.out_dir, phys[0], phys[1], logical, tangents, a.fov_scale, render, a.eye, a.encoding,
                      Pose(*pair(a.pose_delta, float, 3, '--pose-delta')))
    return 0


def load_meta(path, eye):
    """ALVR angle-chart dump meta.json -> per-eye tangents (|tan| L,R,D,U), render size, foveation text, coded size."""
    m = json.loads(Path(path).read_text())
    t = m['tangents'][0 if eye == 'L' else 1]
    out = {'tangents': tuple(abs(float(v)) for v in t), 'render': (int(m['renderEyeSize'][0]), int(m['renderEyeSize'][1])),
           'coded': (int(m['codedSize'][0]), int(m['codedSize'][1]))}
    if m.get('foveation'):
        out['foveation'] = ','.join(repr(float(v)) for v in (m['centerSize'][0], m['centerSize'][1], m['edgeRatio'][0],
                                                              m['edgeRatio'][1], m['centerShift'][0], m['centerShift'][1]))
    else:
        out['foveation'] = 'off'
    return out


def run_measure(a):
    mode = a.mode
    s = a.fov_scale
    meta = load_meta(a.meta, a.eye) if a.meta else None
    if mode == 'drawable':
        if not a.capture_dir:
            raise ValueError('drawable needs --capture-dir')
        cap = json.loads((a.capture_dir / 'capture.json').read_text())
        sl = next((x for x in cap['slices'] if x['eye'] == a.eye), None)
        if sl is None:
            raise ValueError('no %s slice in capture.json' % a.eye)
        width, height, pix = vc.read_png(a.capture_dir / sl['png'])
        if (width, height) != (sl['width'], sl['height']):
            raise ValueError('texture/PNG size mismatch')
        tangents = tuple(sl['tangents'])
        encoding = cap.get('encoding', sl.get('encoding', 'linear'))
        if encoding not in ('srgb', 'linear'):
            raise ValueError('capture.json encoding must be srgb or linear, got %r' % (encoding,))
        if encoding == 'linear':                # the client writes linear light: measure on the sRGB-encoded counts
            pix = srgb_encode(pix)
    else:
        if not a.image:
            raise ValueError('%s needs --image' % mode)
        width, height, pix = vc.read_png(a.image)
        tangents = tuple(pair(a.tangents, float, 4, '--tangents')) if a.tangents else (meta['tangents'] if meta else device_tangents(a.eye, None))
    foveation = a.foveation if a.foveation is not None else (meta['foveation'] if meta else None)
    if a.region:
        region = tuple(int(v) for v in pair(a.region, float, 4, '--region'))
    elif meta and mode == 'encoded' and width == meta['coded'][0] and width % 2 == 0:
        per = width // 2                      # packed frame: left eye left half, right eye right half
        region = (0 if a.eye == 'L' else per, 0, per, height)
    else:
        region = (0, 0, width, height)
    x0, y0, w, h = region
    if w <= 0 or h <= 0 or x0 < 0 or y0 < 0 or x0 + w > width or y0 + h > height:
        raise ValueError('--region outside the image')
    if a.render:
        render = size_arg(a.render, '--render')
    elif meta:
        render = meta['render']
    else:
        render = (w, h) if mode == 'render' else REN
    left, right, down, up = tangents
    lo_x, hi_x, lo_y, hi_y = -s * left, s * right, -s * up, s * down
    if a.stream_tangents:                       # the stream's own |tan| L,R,D,U (already s x view): replaces s x tangents
        sl_, sr_, sd_, su_ = pair(a.stream_tangents, float, 4, '--stream-tangents')
        lo_x, hi_x, lo_y, hi_y = -sl_, sr_, -su_, sd_
    fov = parse_foveation(foveation, render)
    mirror = a.eye == 'R'
    if mode == 'render':
        xaxis = make_axis('h', 'render', lo_x, hi_x, render[0], fov=fov[0], shift=x0, mirror=mirror)
        yaxis = make_axis('v', 'render', lo_y, hi_y, render[1], fov=fov[1], shift=y0)
    elif mode == 'encoded':
        xaxis = make_axis('h', 'encoded', lo_x, hi_x, render[0], fov=fov[0], shift=x0, mirror=mirror)
        yaxis = make_axis('v', 'encoded', lo_y, hi_y, render[1], fov=fov[1], shift=y0)
    else:
        xt, yt = vc.tables(sl)
        vx, vy, vw, vh = sl['viewport']
        pose = pose_from_capture(cap, sl)

        def drawable_axes(pose):
            return (make_axis('h', 'drawable', lo_x, hi_x, render[0], fov=fov[0], mirror=mirror, drawable=(-left, right, vx, vw, xt), pose=pose),
                    make_axis('v', 'drawable', lo_y, hi_y, render[1], fov=fov[1], drawable=(-up, down, vy, vh, yt), pose=pose))
        xaxis, yaxis = drawable_axes(pose)
    params = {'mode': mode, 'eye': a.eye, 'fov_scale': s, 'tangents_LRDU': list(tangents), 'render': list(render),
              'foveation': foveation or 'off', 'region': [x0, y0, w, h], 'image_size': [width, height]}
    if mode == 'drawable':
        params['encoding'] = encoding
    notes = []
    if mode == 'encoded':
        coded = (fov[0]['coded'], fov[1]['coded'])
        params['coded_size_predicted'] = list(coded)
        if (w, h) != coded:
            params['coded_size_note'] = 'region differs from predicted coded size'
        if meta and coded != (meta['coded'][0] // 2, meta['coded'][1]):
            notes.append('coded size predicted %dx%d per eye, meta says %dx%d for both' % (coded[0], coded[1], meta['coded'][0], meta['coded'][1]))
    lines = analyse(pix, width, region, xaxis, yaxis, mode == 'drawable')
    fitted = None
    if mode == 'drawable':
        if pose is None:       # no pose in the capture: fit one yaw to the x lines and say so in the verdict
            fitted = _median(l['residual_deg'] for l in lines if l['axis'] == 'x' and l['residual_deg'] is not None) or 0.0
            pose = Pose(fitted)
            xaxis, yaxis = drawable_axes(pose)
            lines = analyse(pix, width, region, xaxis, yaxis, True)
        params['pose'] = {'source': 'capture.json' if fitted is None else 'fitted-yaw', 'delta_deg': pose.delta()}
    edges = None
    if mode == 'drawable':
        levels = edge_levels(pix, width, region, xaxis.span(), yaxis.span())
        params['extent_levels'] = levels
        xa = xb = ya = yb = None
        if levels['separable']:
            xa, xb = stream_edges(pix, width, region, 'h', levels['threshold'])
            ya, yb = stream_edges(pix, width, region, 'v', levels['threshold'])
        edges = {'left': xa, 'right': xb, 'up': ya, 'down': yb}
    extent = extent_report(mode, xaxis, yaxis, edges)
    summary = summarise(lines, extent, params, {'x': fov[0]['f'] < 0.9999, 'y': fov[1]['f'] < 0.9999})
    if fitted is not None:
        summary['fitted_yaw_deg'] = fitted
        if summary['verdict'] == 'PASS':
            summary['verdict'] = 'PASS-after-fitted-yaw'
    if notes:
        summary['verdict_reasons'].extend(notes)
        summary['verdict'] = 'FAIL'
    if a.out_png:
        canvas = Canvas(pix, width, region)
        draw_overlay(canvas, region, xaxis, yaxis, lines, a.eye, foveation not in (None, 'off'), True)
        vc.write_png(a.out_png, w, h, bytes(canvas.buf))
    if a.out_json:
        Path(a.out_json).write_text(json.dumps({'summary': summary, 'lines': lines}, indent=1))
    print_summary(summary, mode, a.eye, s)
    return 0 if summary['verdict'].startswith('PASS') else 1


def print_summary(summary, mode, eye, s):
    def f(v, fmt='%.3f'):
        return 'n/a' if v is None else fmt % v
    print('{} eye={} fov_scale={}: found {}/{} lines, median |residual| {} deg, max {} deg'.format(
        mode, eye, s, summary['n_found'], summary['n_predicted'], f(summary['median_abs_residual_deg']), f(summary['max_abs_residual_deg'])))
    for ax in ('x', 'y'):
        e = summary['axes'][ax]
        if e['n_predicted']:
            print('  axis {}: found {}/{}, median {} deg, max {} deg'.format(
                ax, e['n_found'], e['n_predicted'], f(e['median_abs_residual_deg']), f(e['max_abs_residual_deg'])))
    for zone in ('band', 'edge'):
        z = summary['zones'][zone]
        if not z['n_predicted']:
            continue
        unit = 'stream px/deg' if z['drawable_px_per_deg'] is not None else 'px/deg'
        print('  {}: found {}/{}, resolvable {}, sharpness {} {} (predicted {}), PSF {} deg, resolved (1/PSF, per deg) {}'.format(
            zone, z['n_found'], z['n_predicted'], z['n_resolvable'], f(z['sharpness_px_per_deg'], '%.1f'), unit,
            f(z['predicted_px_per_deg'], '%.1f'), f(z['psf_deg'], '%.4f'), f(z['resolved_px_per_deg'], '%.1f')))
        if z['drawable_px_per_deg'] is not None:
            print('    client: drawable px/deg {} (not comparable with the stream figures)'.format(f(z['drawable_px_per_deg'], '%.1f')))
    for side, e in summary['stream_extent_deg'].items():
        if e['measured_deg'] is not None:
            print('  stream {}: measured {:.2f} deg, predicted {:.2f} deg'.format(side, e['measured_deg'], e['predicted_deg']))
    fit = summary.get('fitted_yaw_deg')
    print('{}{}{}'.format(summary['verdict'], ''.join('; ' + r for r in summary['verdict_reasons']),
                          '' if fit is None else ' (fitted yaw %.3f deg; capture.json has no pose.delta_deg)' % fit))


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
