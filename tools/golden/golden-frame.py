#!/usr/bin/env python3
"""Golden frame sets for the Vision Pro client: one offline per-eye image well above the display density, the same
content as the server frame the client would receive, and a meta.json the client can display them through.

Subcommands:
  render   L.png / R.png at the device per-eye frustum (tools/fov-matrix/avp-field.json), square pixels in tangent
           space, --ppd px/deg on the eye axis (default 80; the device draws 40 logical px/deg at quality 1.0).
           --content chart: the resolution chart patches of ResolutionChart.swift (GratingChart: 24 patches, bars as
           the client's Fick-corner quads) drawn with exact area coverage, a 1 deg grid of ticks and the eye-axis
           cross; head-locked at infinity, temporal mirrored per eye like the device chart.
           --content image --image PNG: the photo on a plane --distance m ahead, --plane-width m wide, centred
           between the eyes (--ipd m), so the two eyes see consistent parallax; area average then nearest.
  encode   L.server.png / R.server.png: the server frame per eye at --render WxH (or --point from
           points-chart-avp.tsv) with ALVR's foveated compression, the exact inverse of the client's expansion
           (ALVRClient/Shaders.metal:136-189 decompressAxisAlignedCoord with FFR.swift:79-102's aligned values;
           side-by-side halves Shaders.metal:217-221), every coded pixel the area average (linear light) of the golden
           over its footprint. --codec hevc runs a local ffmpeg round trip when ffmpeg is on PATH (else skipped).
  measure  a client capture of the displayed golden set (W33 chart capture: capture.json chart_capture + PNG):
           the W33 bar counter per patch and a Gaussian PSF per patch from its bar modulation against the golden's;
           prints setting -> finest correct cpd and PSF deg per eye / position / orientation.
  push     prints the devicectl copy command for Documents/diag/golden/<set> (does not run it).

Output: tools/golden/out/<set>/{L.png,R.png,L.server.png,R.server.png,meta.json} (out/ is git-ignored). PNGs are 8-bit
sRGB-encoded (chart: grey, image: RGB); all averaging is in linear light. Python 3.9+, standard library only.
"""
import argparse
from itertools import accumulate
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DIAG = REPO / 'tools' / 'diag'
FIELD_FILE = REPO / 'tools' / 'fov-matrix' / 'avp-field.json'
POINTS_FILE = REPO / 'tools' / 'fov-matrix' / 'points-chart-avp.tsv'
LENS_SWIFT = REPO / 'ALVRClient' / 'Diagnostics' / 'BoundaryDots.swift'
DOTS_LOG = Path('/Users/noel/Projects/Management/goals/rdr2-vr/evidence/device-20261021/diag-20261021T152509Z.log')
OUT = HERE / 'out'
ASPECT = (3648, 2912)                       # render size at render scale 1 (avp-sharpness.py ASPECT)
BUNDLE = 'uk.lumenio.alvr'                  # tools/diag/push-clips.sh
D = math.pi / 180


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fo = _load('fov_overlay', DIAG / 'fov-overlay.py')      # fov_axis / fov_off (FFR float32 maths), u_of_c, verify-capture


# ---- sRGB ----------------------------------------------------------------------------------------------------------

def _encode(x):
    return 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055


LINEAR = [(i / 255 / 12.92 if i / 255 <= 0.04045 else ((i / 255 + 0.055) / 1.055) ** 2.4) for i in range(256)]
ENC_N = 16383
ENC = bytes(int(round(_encode(i / ENC_N) * 255)) for i in range(ENC_N + 1))


def srgb8(v):
    """Linear light 0..1 -> sRGB-encoded byte (the one quantiser every writer here uses)."""
    return ENC[int(min(max(v, 0.0), 1.0) * ENC_N + 0.5)]


def to_bytes(values):
    return bytes(ENC[int(v * ENC_N + 0.5)] if 0.0 < v < 1.0 else (255 if v >= 1.0 else 0) for v in values)


# ---- PNG (verify-capture.py's reader/writer, for grey, RGB and RGBA, streamed) -----------------------------------------

COLOUR = {1: 0, 3: 2, 4: 6}


def write_png(path, width, height, channels, rows):
    """rows: `height` byte strings of width * channels; filter 0, one zlib stream."""
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    z, parts, n = zlib.compressobj(6), [], 0
    for row in rows:
        if len(row) != width * channels:
            raise ValueError('PNG row size mismatch')
        parts.append(z.compress(b'\0' + bytes(row)))
        n += 1
    if n != height:
        raise ValueError('PNG row count mismatch')
    parts.append(z.flush())
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, COLOUR[channels], 0, 0, 0)))
        f.write(chunk(b'IDAT', b''.join(parts)))
        f.write(chunk(b'IEND', b''))


def read_png(path):
    """-> (width, height, channels, rows); 8-bit grey / RGB / RGBA, non-interlaced, all five filters."""
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('%s: not PNG' % path)
    pos, packed, ch = 8, [], None
    while pos < len(data):
        length = struct.unpack_from('!I', data, pos)[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            w, h, depth, colour, compression, filtering, interlace = struct.unpack('!2I5B', body)
            ch = {0: 1, 2: 3, 6: 4}.get(colour)
            if depth != 8 or ch is None or interlace or compression or filtering:
                raise ValueError('%s: need non-interlaced 8-bit grey, RGB or RGBA' % path)
        elif kind == b'IDAT':
            packed.append(body)
        pos += length + 12
        if kind == b'IEND':
            break
    raw = zlib.decompress(b''.join(packed))
    stride = w * ch
    if len(raw) != h * (stride + 1):
        raise ValueError('%s: PNG decoded size mismatch' % path)
    rows, previous = [], bytes(stride)
    for y in range(h):
        start = y * (stride + 1)
        filt, row = raw[start], raw[start + 1:start + 1 + stride]
        if filt == 0:
            pass
        elif filt == 2:
            row = bytes((a + b) & 255 for a, b in zip(row, previous))
        else:
            row = bytearray(row)
            for x in range(stride):
                a, b, c = (row[x - ch] if x >= ch else 0), previous[x], (previous[x - ch] if x >= ch else 0)
                if filt == 1:
                    p = a
                elif filt == 3:
                    p = (a + b) // 2
                elif filt == 4:
                    q = a + b - c
                    pa, pb, pc = abs(q - a), abs(q - b), abs(q - c)
                    p = a if pa <= pb and pa <= pc else b if pb <= pc else c
                else:
                    raise ValueError('%s: invalid PNG filter' % path)
                row[x] = (row[x] + p) & 255
            row = bytes(row)
        rows.append(row)
        previous = row
    return w, h, ch, rows


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


# ---- device frustum and the tangent-space grid -----------------------------------------------------------------------

def device_tangents(path=FIELD_FILE):
    """{'L': (left, right, bottom, top) |tan|, 'R': ...}: avp-field.json frustum_tan_LRDU (CornerTangents order)."""
    p = json.loads(Path(path).read_text())['frustum_tan_LRDU']
    return {e: tuple(float(v) for v in p[e]) for e in 'LR'}


class Frame:
    """One eye's golden grid: square pixels in tangent space, px_per_tan = ppd * 180 / pi (ppd on the eye axis).
    Pixel x = (tan_x + left) * k, y = (top - tan_y) * k (row 0 at the top); width/height round the frustum spans."""

    def __init__(self, tangents, ppd):
        self.tangents = tuple(float(v) for v in tangents)
        self.ppd = ppd
        self.px_per_tan = ppd / D
        l, r, b, t = self.tangents
        self.width, self.height = round((l + r) * self.px_per_tan), round((b + t) * self.px_per_tan)

    def tan_to_px(self, tx, ty):
        return (tx + self.tangents[0]) * self.px_per_tan, (self.tangents[3] - ty) * self.px_per_tan

    def axis_px(self):
        return self.tan_to_px(0.0, 0.0)

    def rect_px(self):
        """The frustum rectangle in golden px (exact; the image is width x height, within 0.5 px of it)."""
        l, r, b, t = self.tangents
        return [0.0, 0.0, (l + r) * self.px_per_tan, (b + t) * self.px_per_tan]


class Image:
    def __init__(self, width, height, channels, rows):
        self.width, self.height, self.channels, self.rows = width, height, channels, rows


# ---- the device chart (ResolutionChart.swift GratingChart) -------------------------------------------------------------

CPD = (8, 10, 12, 14, 17, 20)               # GratingChart.cyclesPerDegree
COLUMN_DEG = (0.0, 2, -2, 4, -4, 6)         # GratingChart.columnDeg
PATCH_DEG = 1.5
POSITIONS = (('axis', 0.0), ('temporal20', 20.0))


def chart_patches():
    """GratingChart.patches (ResolutionChart.swift:161-169): axis then temporal20, V then H, cpd ascending."""
    return [dict(position=pos, cpd=cpd, orientation=o, temporal_deg=t + COLUMN_DEG[i], up_deg=1.0 if o == 'V' else -1.5)
            for pos, t in POSITIONS for o in ('V', 'H') for i, cpd in enumerate(CPD)]


def patch_rect(p):
    """(t0, t1, u0, u1) degrees temporal / up (patchRect)."""
    h = PATCH_DEG / 2
    return (p['temporal_deg'] - h, p['temporal_deg'] + h, p['up_deg'] - h, p['up_deg'] + h)


def bars(p):
    """White bars from the patch's low edge, one per cycle, the last clipped (GratingChart.bars)."""
    t0, t1, u0, u1 = patch_rect(p)
    period = 1 / p['cpd']
    out = []
    for k in range(int(math.ceil(PATCH_DEG * p['cpd'] - 1e-9))):
        a = k * period
        b = min(a + period / 2, PATCH_DEG)
        out.append((t0 + a, t0 + b, u0, u1) if p['orientation'] == 'V' else (t0, t1, u0 + a, u0 + b))
    return out


def screen(r, eye):
    """Temporal is -x for the left eye (GratingChart.screen): (az0, az1, el0, el1)."""
    t0, t1, u0, u1 = r
    return (-t1, -t0, u0, u1) if eye == 'L' else r


def fick(az_deg, el_deg):
    """Fick angles -> view tangents (tan az, tan el / cos az), GratingChart.ndc."""
    return math.tan(az_deg * D), math.tan(el_deg * D) / math.cos(az_deg * D)


NDC_CONVENTION = ('eye NDC as the client draws overlays, CornerTangents.ndc (ALVRClient/Diagnostics/CornerChart.swift:69-71): '
                  'x = (2 tan_x - right + left) / (left + right), y = (2 tan_y - top + bottom) / (bottom + top), '
                  '+y up, the frustum is [-1, 1]^2; chart patches via GratingChart.quad(...).rect (ResolutionChart.swift:'
                  '212-230). Golden px = ((x + 1) / 2 * width, (1 - y) / 2 * height).')


def ndc(t, x, y):
    """CornerTangents.ndc (CornerChart.swift:69-71): view tangents -> eye NDC, +y up."""
    l, r, b, top = t
    return (2 * x - r + l) / (l + r), (2 * y - top + b) / (b + top)


def quad_corners(s):
    """Tangent corners of an az/el rectangle in CornerChart.Quad order (x0y0, x1y0, x0y1, x1y1)."""
    a0, a1, e0, e1 = s
    return [fick(a0, e0), fick(a1, e0), fick(a0, e1), fick(a1, e1)]


def patch_ndc_rect(t, eye, p):
    """GratingChart.quad(t, eye:, patchRect(p)).rect: (x0, y0, x1, y1) NDC, +y up."""
    pts = [ndc(t, x, y) for x, y in quad_corners(screen(patch_rect(p), eye))]
    return (min(q[0] for q in pts), min(q[1] for q in pts), max(q[0] for q in pts), max(q[1] for q in pts))


GRID_LEVEL, TICK_LEVEL = 0.25, 0.5          # linear light; bars and the axis cross are 1.0
GRID_ARM, GRID_W = 0.15, 0.03               # deg: grid crosses at every integer az / el
TICK_W, CROSS_W = 0.04, 0.04
CLEAR_DEG = 0.15                            # keep ticks this far from the patches


def chart_shapes(t, eye):
    """[(az0, az1, el0, el1, level)] screen rectangles: bars, the 1 deg grid, axis ticks and the eye-axis cross."""
    shapes = [screen(b, eye) + (1.0,) for p in chart_patches() for b in bars(p)]
    keep_out = [screen(patch_rect(p), eye) for p in chart_patches()]
    l, r, b, top = t

    def clear(s):
        return not any(s[0] < k[1] + CLEAR_DEG and s[1] > k[0] - CLEAR_DEG and s[2] < k[3] + CLEAR_DEG
                       and s[3] > k[2] - CLEAR_DEG for k in keep_out)

    def inside(az, el):
        if not -90 < az < 90:
            return False
        x, y = fick(az, el)
        return -l < x < r and -b < y < top

    def add(s, level):
        if clear(s):
            shapes.append(s + (level,))

    for az in range(-89, 90):
        for el in range(-89, 90):
            if not inside(az, el):
                continue
            if az == 0 and el == 0:
                continue
            if el == 0:                     # tick on the horizontal axis line, longer every 5 and 10 deg
                h = 0.8 if az % 10 == 0 else 0.5 if az % 5 == 0 else 0.25
                add((az - TICK_W / 2, az + TICK_W / 2, -h, h), TICK_LEVEL)
            elif az == 0:
                h = 0.8 if el % 10 == 0 else 0.5 if el % 5 == 0 else 0.25
                add((-h, h, el - TICK_W / 2, el + TICK_W / 2), TICK_LEVEL)
            else:
                add((az - GRID_ARM, az + GRID_ARM, el - GRID_W / 2, el + GRID_W / 2), GRID_LEVEL)
                add((az - GRID_W / 2, az + GRID_W / 2, el - GRID_ARM, el + GRID_ARM), GRID_LEVEL)
    # Eye-axis cross, sized to sit in the gap between the axis set's V (el >= 0.25) and H (el <= -0.75) rows.
    shapes.append((-0.6, 0.6, -CROSS_W / 2, CROSS_W / 2, 1.0))
    shapes.append((-CROSS_W / 2, CROSS_W / 2, -0.2, 0.2, 1.0))
    return shapes


def rasterize(frame, shapes, window=None):
    """Exact area coverage of each quad (vertical sides at tan az, straight top/bottom edges between the Fick corners,
    as the client's two triangles) per pixel; the top/bottom edge height is taken at the pixel centre column. Coverage
    sums in linear light (shapes do not overlap) and is sRGB-encoded. -> Image (grey) of the window (x, y, w, h)."""
    wx, wy, ww, wh = window or (0, 0, frame.width, frame.height)
    quads = []
    for az0, az1, el0, el1, level in shapes:
        (x0, yb0), (x1, yb1), (_, yt0), (_, yt1) = [frame.tan_to_px(*c) for c in quad_corners((az0, az1, el0, el1))]
        if x1 <= x0:
            continue
        ymin, ymax = min(yt0, yt1), max(yb0, yb1)
        if x1 <= wx or x0 >= wx + ww or ymax <= wy or ymin >= wy + wh:
            continue
        quads.append((ymin, ymax, x0, x1, yt0, yt1, yb0, yb1, level, max(yt0, yt1), min(yb0, yb1)))
    quads.sort()
    zero = bytes(ww)
    acc = [0.0] * ww
    rows, active, nxt, cache = [], [], 0, {}
    for j in range(wy, wy + wh):
        while nxt < len(quads) and quads[nxt][0] < j + 1:
            active.append(quads[nxt])
            nxt += 1
        active = [q for q in active if q[1] > j]
        hits = [q for q in active if q[0] < j + 1]
        if not hits:
            rows.append(zero)
            continue
        full = all(q[9] <= j and q[10] >= j + 1 for q in hits)
        key = tuple(id(q) for q in hits) if full else None
        if key is not None and key in cache:
            rows.append(cache[key])
            continue
        touched = []
        for _, _, x0, x1, yt0, yt1, yb0, yb1, level, ytmax, ybmin in hits:
            i0, i1 = max(int(math.floor(x0)), wx), min(int(math.ceil(x1)), wx + ww)
            whole = ytmax <= j and ybmin >= j + 1
            span = x1 - x0
            for i in range(i0, i1):
                cx = min(x1, i + 1) - max(x0, i)
                if whole:
                    cov = cx
                else:
                    f = (i + 0.5 - x0) / span
                    f = 0.0 if f < 0 else 1.0 if f > 1 else f
                    cy = min(yb0 + f * (yb1 - yb0), j + 1) - max(yt0 + f * (yt1 - yt0), j)
                    if cy <= 0:
                        continue
                    cov = cx * cy
                acc[i - wx] += cov * level
                touched.append(i - wx)
        row = bytearray(ww)
        for i in set(touched):
            row[i] = srgb8(acc[i])
            acc[i] = 0.0
        row = bytes(row)
        if key is not None:
            cache[key] = row
        rows.append(row)
    return Image(ww, wh, 1, rows)


def render_chart(frame, eye, window=None):
    return rasterize(frame, chart_shapes(frame.tangents, eye), window)


# ---- photo content -------------------------------------------------------------------------------------------------------

def box_reduce(img, k):
    """Integer k x k area average in linear light (RGB); the right/bottom remainder is dropped."""
    w, h = img.width // k, img.height // k
    rows = []
    for y in range(h):
        sums = [0.0] * (w * 3)
        for row in img.rows[y * k:(y + 1) * k]:
            lin = [LINEAR[v] for v in row[:w * k * 3]]
            for x in range(w):
                for c in range(3):
                    sums[x * 3 + c] += sum(lin[(x * k + i) * 3 + c] for i in range(k))
        rows.append(to_bytes(v / (k * k) for v in sums))
    return Image(w, h, 3, rows)


def load_rgb(path):
    w, h, ch, rows = read_png(path)
    if ch == 4:
        rows = [bytes(b for i, b in enumerate(r) if i % 4 != 3) for r in rows]
    elif ch == 1:
        rows = [bytes(b for v in r for b in (v, v, v)) for r in rows]
    return Image(w, h, 3, rows)


def render_image(frame, eye, src, distance, plane_width, ipd, window=None):
    """The photo on a plane `distance` m ahead (z = -distance), `plane_width` m wide, centred between the eyes; this eye
    sits at x = -ipd/2 (L) or +ipd/2 (R). A golden pixel at tangent (tx, ty) sees plane point (ex + tx d, ty d): a
    uniform scale, so the photo is first area-averaged by the integer factor that brings it to <= 1 source px per golden
    px, then sampled nearest. Black outside the photo."""
    wx, wy, ww, wh = window or (0, 0, frame.width, frame.height)
    ex = -ipd / 2 if eye == 'L' else ipd / 2
    plane_height = plane_width * src.height / src.width
    per_px = distance / frame.px_per_tan * src.width / plane_width       # source px per golden px
    k = int(per_px) if per_px >= 2 else 1
    if k > 1:
        src = box_reduce(src, k)
    sw, sh = src.width, src.height
    l, r, b, t = frame.tangents
    sentinel = sw * 3
    idx = []
    for i in range(wx, wx + ww):
        tx = (i + 0.5) / frame.px_per_tan - l
        sx = int(math.floor(((ex + tx * distance) + plane_width / 2) / plane_width * sw))
        base = sx * 3 if 0 <= sx < sw else sentinel
        idx += (base, base + 1, base + 2)
    zero, rows, cache = bytes(ww * 3), [], {}
    for j in range(wy, wy + wh):
        ty = t - (j + 0.5) / frame.px_per_tan
        sy = int(math.floor((plane_height / 2 - ty * distance) / plane_height * sh))
        if not 0 <= sy < sh:
            rows.append(zero)
            continue
        if sy not in cache:
            cache.clear()
            cache[sy] = bytes(map((src.rows[sy] + b'\0\0\0').__getitem__, idx))
        rows.append(cache[sy])
    return Image(ww, wh, 3, rows)


# ---- foveation: the client's expansion and its exact inverse ---------------------------------------------------------------

def fov_axes(fov, width, height):
    """(x axis, y axis) aligned foveation values; FFR.swift:79-102 = FFR.cpp, emulated in float32 by fov-overlay.py
    fov_axis (c, s, r, f, opt, coded). fov None: off (no padding, identity)."""
    if fov is None:
        return fo.fov_off(width), fo.fov_off(height)
    cx, cy, rx, ry, shx, shy = fov
    return fo.fov_axis(cx, shx, rx, width), fo.fov_axis(cy, shy, ry, height)


def _consts(a):
    c, s, r = a['c'], a['s'], a['r']
    c0 = (1 - c) * 0.5
    c1 = (r - 1) * c0 * (s + 1) / r
    c2 = (r - 1) * c + 1
    return c, s, r, c0, c1, c2


def client_expand(x, a):
    """Shaders.metal:148-188 decompressAxisAlignedCoord for one axis: eye UV x (target, uncompressed) -> the coded
    fraction C it samples (before EYE_SIZE_RATIO), including the shader's strict bounds and per-piece clamps."""
    if a['f'] >= 0.9999 and a['c'] >= 0.9999:
        return x
    c, s, r, c0, c1, c2 = _consts(a)
    lo, hi = c0 * (s + 1), c0 * (s - 1) + 1
    clamp = lambda v: min(max(v, 0.0), 1.0)
    if lo < x < hi:
        return clamp((x - c1) * r / c2)
    loC, hiC = c0 * (s + 1) / c2, c0 * (s - 1) / c2 + 1
    if x < lo:
        A = (c1 + c2 * loC) / loC
        return clamp((-A + math.sqrt(A * A + 4 * c2 * (1 - r) / (r * loC) * x)) / (2 * c2 * (1 - r)) * (r * loC))
    if x > hi:
        k = (c2 - r * c1 - 2 * r * c2 + c2 * r * (1 - hiC) + r) / (r * (1 - hiC))
        disc = k * k - 4 * ((c2 * r - c2) * (c1 - hiC + hiC * c2) / (r * (1 - hiC) * (1 - hiC))
                            - x * (c2 * r - c2) / (r * (1 - hiC)))
        return clamp((-k + math.sqrt(max(disc, 0.0))) / (2 * c2 * (r - 1)) * (r * (1 - hiC)))
    return 0.0                                  # exactly on a bound: the shader's three masks are all 0


def client_compress(C, a):
    """Inverse of client_expand: coded fraction C -> eye UV x. Each piece of the shader is a root of a quadratic in C,
    so x is that quadratic: left x = B C^2 + A C with A = (c1 + c2 loC)/loC, B = c2 (1 - r)/(r loC); centre
    x = C c2 / r + c1; right x = R C^2 + P C + Q / R with P, Q, R the shader's terms (Shaders.metal:172-185)."""
    if a['f'] >= 0.9999 and a['c'] >= 0.9999:
        return C
    c, s, r, c0, c1, c2 = _consts(a)
    loC, hiC = c0 * (s + 1) / c2, c0 * (s - 1) / c2 + 1
    if C < loC:
        A = (c1 + c2 * loC) / loC
        B = c2 * (1 - r) / (r * loC)
        return B * C * C + A * C
    if C > hiC:
        k = (c2 - r * c1 - 2 * r * c2 + c2 * r * (1 - hiC) + r) / (r * (1 - hiC))
        R = (c2 * r - c2) / (r * (1 - hiC))
        Q = (c2 * r - c2) * (c1 - hiC + hiC * c2) / (r * (1 - hiC) * (1 - hiC))
        return R * C * C + k * C + Q / R
    return C * c2 / r + c1


def coded_intervals(a, mirror):
    """Per coded pixel of one eye: the eye image fraction interval (lo, hi) it covers, or None (padding). Coded column
    k spans aligned UV [k, k+1]/coded = C * EYE_SIZE_RATIO (opt / coded), Shaders.metal:189. The right eye's x is
    mirrored (TextureToEyeUV / EyeToTextureUV, :136-145): C runs from its half's right edge, eye UV x = 1 - fraction."""
    n, opt = a['coded'], a['opt']
    out = []
    for k in range(n):
        lo, hi = ((n - k - 1) / opt, (n - k) / opt) if mirror else (k / opt, (k + 1) / opt)
        if lo >= 1:
            out.append(None)
            continue
        u0, u1 = client_compress(lo, a), client_compress(min(hi, 1.0), a)
        out.append((1 - u1, 1 - u0) if mirror else (u0, u1))
    return out


class _Encoder:
    """Area average over each coded pixel's footprint, separable: per golden row the horizontal box integral from a
    prefix sum, then golden rows weighted by their overlap with each coded row. Rows stream in; identical golden rows
    reuse their horizontal result."""

    def __init__(self, gw, gh, ax, ay, eye, span_x=(0.0, 1.0), span_y=(0.0, 1.0), channels=1):
        self.gw, self.ch = gw, channels
        # eye image fraction u -> golden px: the stream covers [span0, span1] of the golden frame
        def to_px(iv, span, n):
            if iv is None:
                return None
            lo, hi = (span[0] + v * (span[1] - span[0]) for v in iv)
            return min(max(lo * n, 0.0), n), min(max(hi * n, 0.0), n)
        self.xs = []
        for iv in coded_intervals(ax, eye == 'R'):
            p = to_px(iv, span_x, gw)
            if p is None or p[1] <= p[0]:
                self.xs.append(None)
                continue
            i0, i1 = min(int(p[0]), gw - 1), min(int(p[1]), gw)
            self.xs.append((i0, p[0] - i0, i1, p[1] - i1, 1 / (p[1] - p[0])))
        self.nx = len(self.xs)
        self.ys = [to_px(iv, span_y, gh) for iv in coded_intervals(ay, False)]
        self.contrib = {}
        for o, p in enumerate(self.ys):
            if p is None or p[1] <= p[0]:
                continue
            for g in range(int(p[0]), min(int(math.ceil(p[1])), gh)):
                w = (min(p[1], g + 1) - max(p[0], g)) / (p[1] - p[0])
                if w > 0:
                    self.contrib.setdefault(g, []).append((o, w))
        self.acc = [[[0.0] * self.nx for _ in self.ys] for _ in range(channels)]
        self.cache = {}
        self.g = 0

    def horizontal(self, row):
        row = list(row) + [0.0]
        P = list(accumulate(row, initial=0.0))
        return [0.0 if s is None else (P[s[2]] + s[3] * row[s[2]] - P[s[0]] - s[1] * row[s[0]]) * s[4] for s in self.xs]

    def feed(self, planes, key=None):
        targets = self.contrib.get(self.g, ())
        self.g += 1
        if not targets:
            return
        if key is not None and key in self.cache:
            hs = self.cache[key]
        else:
            hs = [self.horizontal(p) for p in planes]
            if key is not None:
                if len(self.cache) > 256:
                    self.cache.clear()
                self.cache[key] = hs
        for c, h in enumerate(hs):
            for o, w in targets:
                a = self.acc[c][o]
                self.acc[c][o] = [x + w * v for x, v in zip(a, h)]


def encode_plane(rows, gw, gh, ax, ay, eye, span_x=(0.0, 1.0), span_y=(0.0, 1.0)):
    """One float plane (gh rows of gw linear values) -> coded rows (ay coded x ax coded), padding 0."""
    e = _Encoder(gw, gh, ax, ay, eye, span_x, span_y)
    for row in rows:
        e.feed([row])
    return e.acc[0]


def encode_image(img, ax, ay, eye, span_x=(0.0, 1.0), span_y=(0.0, 1.0)):
    """8-bit sRGB golden Image -> 8-bit sRGB coded Image (same channel count)."""
    ch = img.channels
    e = _Encoder(img.width, img.height, ax, ay, eye, span_x, span_y, ch)
    for row in img.rows:
        if e.g not in e.contrib:
            e.g += 1
            continue
        lin = list(map(LINEAR.__getitem__, row))
        e.feed([lin[c::ch] for c in range(ch)], key=row)
    out = []
    for o in range(len(e.ys)):
        planes = [to_bytes(e.acc[c][o]) for c in range(ch)]
        if ch == 1:
            out.append(planes[0])
        else:
            row = bytearray(e.nx * ch)
            for c in range(ch):
                row[c::ch] = planes[c]
            out.append(bytes(row))
    return Image(e.nx, len(e.ys), ch, out)


def client_texture_uv(tex_x, tex_y, ax, ay, eye):
    """decompressAxisAlignedCoord (Shaders.metal:148-189) on a side-by-side texture UV of `eye`: the side-by-side UV of
    the coded frame it samples. Checked against the shader by tools/golden/fixtures/ffr-expand-*.tsv."""
    right = eye == 'R'
    eye_x = (tex_x + float(right) * (1 - 2 * tex_x)) * 2                 # TextureToEyeUV
    cx = client_expand(eye_x, ax) * (ax['opt'] / ax['coded'])
    cy = client_expand(tex_y, ay) * (ay['opt'] / ay['coded'])
    return cx * 0.5 + float(right) * (1 - cx), cy                        # EyeToTextureUV


def client_sample(coded, u, v, ax, ay, eye):
    """What the client shows at eye image fraction (u, v): the side-by-side target UV (Shaders.metal:217-221),
    decompressAxisAlignedCoord (:148-189), then a bilinear sample of this eye's coded half. coded: rows of floats."""
    right = eye == 'R'
    sx, cy = client_texture_uv(u * 0.5 + (0.5 if right else 0.0), v, ax, ay, eye)
    half = (sx - 0.5) * 2 if right else sx * 2
    h, w = len(coded), len(coded[0])
    px, py = half * w - 0.5, cy * h - 0.5
    x0, y0 = int(math.floor(px)), int(math.floor(py))
    fx, fy = px - x0, py - y0
    at = lambda x, y: coded[min(max(y, 0), h - 1)][min(max(x, 0), w - 1)]
    return ((at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) +
            (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy)


# ---- lens outline (W34 reference, else the 21 Oct dots log) ----------------------------------------------------------------

def _table(text):
    return {float(k): float(v) for k, v in re.findall(r'(-?[0-9.]+)\s*:\s*(-?[0-9.]+)', text)}


def lens_reference(swift=LENS_SWIFT, log=DOTS_LOG):
    """{'left': {ray: ecc}, 'right': {..} or None, 'source'}: rays CCW from right (deg), eccentricity from the head axis.
    W34's BoundaryDotsLensReference table when the client has it; else the dots log's dots_summary lines, L over Both
    (the same merge as W34's table)."""
    swift, log = Path(swift), Path(log)
    if swift.exists():
        m = re.search(r'enum BoundaryDotsLensReference\b(.*?)\n}', swift.read_text(), re.S)
        if m:
            left = re.search(r'static let left: \[Double: Double\] = \[(.*?)\]', m.group(1), re.S)
            right = re.search(r'static let right: \[Double: Double\]\? = \[(.*?)\]', m.group(1), re.S)
            if left:
                return {'left': _table(left.group(1)), 'right': _table(right.group(1)) if right else None,
                        'source': '%s BoundaryDotsLensReference (W34)' % swift}
    if not log.exists():
        return None
    latest = {}
    for line in log.read_text(errors='replace').splitlines():
        m = re.search(r'DIAG dots_summary t_ms=\d+ eye=(\w+) points=\d+ rays=(\S+)', line)
        if m:
            latest[m.group(1)] = {} if m.group(2) == 'none' else _table(m.group(2).replace(',', ' '))
    left = dict(latest.get('Both', {}))
    left.update(latest.get('L', {}))
    right = latest.get('R') or None
    if not left:
        return None
    return {'left': left, 'right': right,
            'source': '%s dots_summary eye=L (%d rays) over eye=Both' % (log, len(latest.get('L', {})))}


def _interpolate(samples, ray):
    ray %= 360
    if ray in samples:
        return samples[ray]
    rays = sorted(samples)
    below = max((q for q in rays if q < ray), default=rays[-1])
    above = min((q for q in rays if q > ray), default=rays[0])
    span = (above - below) % 360
    if span == 0:
        return samples[below]
    return samples[below] + ((ray - below) % 360) / span * (samples[above] - samples[below])


def lens_ecc(ref, eye, ray):
    """Eccentricity (deg) on a ray; R is the mirror of L about the vertical, R(phi) = L(180 - phi), unless measured."""
    if eye == 'R' and not ref.get('right'):
        return _interpolate(ref['left'], 180 - ray)
    return _interpolate(ref['right'] if eye == 'R' else ref['left'], ray)


def lens_outline(ref, eye, frame):
    """Closed polygon every 5 deg: projected-tangent directions (Boundary dots angles=projected_tangent)."""
    pts = []
    for ray in range(0, 360, 5):
        e = lens_ecc(ref, eye, ray)
        tx, ty = math.tan(e * D) * math.cos(ray * D), math.tan(e * D) * math.sin(ray * D)
        x, y = frame.tan_to_px(tx, ty)
        nx, ny = ndc(frame.tangents, tx, ty)
        pts.append({'ray_deg': ray, 'ecc_deg': round(e, 4), 'tan': [round(tx, 6), round(ty, 6)],
                    'ndc': [round(nx, 7), round(ny, 7)], 'px': [round(x, 2), round(y, 2)]})
    return pts


# ---- meta, sets ------------------------------------------------------------------------------------------------------------

def set_dir(args):
    return Path(args.out) / args.set


def update_files(meta, d):
    meta['files'] = {p.name: {'sha256': sha256(p), 'bytes': p.stat().st_size} for p in sorted(Path(d).glob('*.png'))}


def write_meta(meta, d):
    update_files(meta, d)
    (Path(d) / 'meta.json').write_text(json.dumps(meta, indent=1) + '\n')


def load_meta(d):
    p = Path(d) / 'meta.json'
    if not p.exists():
        raise ValueError('%s: no meta.json (run render first)' % d)
    return json.loads(p.read_text())


def chart_meta(frames):
    out = {}
    for eye, f in frames.items():
        rows = []
        for p in chart_patches():
            x0, y0, x1, y1 = patch_ndc_rect(f.tangents, eye, p)
            w, h = f.rect_px()[2], f.rect_px()[3]
            rows.append(dict(p, ndc_rect=[x0, y0, x1, y1],
                             px_rect=[(x0 + 1) / 2 * w, (1 - y1) / 2 * h, (x1 + 1) / 2 * w, (1 - y0) / 2 * h]))
        out[eye] = rows
    return {'source': 'ALVRClient/Diagnostics/ResolutionChart.swift GratingChart (patches, bars, Fick quads)',
            'patch_deg': PATCH_DEG, 'patches': out,
            'extras': 'grid crosses every 1 deg (linear %.2f), axis ticks (%.2f, longer at 5/10 deg), eye-axis cross; '
                      'no 7-segment labels' % (GRID_LEVEL, TICK_LEVEL)}


def cmd_render(a):
    tangents = device_tangents(a.field)
    d = set_dir(a)
    d.mkdir(parents=True, exist_ok=True)
    frames = {e: Frame(tangents[e], a.ppd) for e in 'LR'}
    src = load_rgb(a.image) if a.content == 'image' else None
    times = {}
    for eye, f in frames.items():
        t0 = time.time()
        img = render_chart(f, eye) if src is None else render_image(f, eye, src, a.distance, a.plane_width, a.ipd)
        write_png(d / ('%s.png' % eye), img.width, img.height, img.channels, img.rows)
        times[eye] = round(time.time() - t0, 2)
        print('%s.png %dx%d (%s) in %.1f s' % (eye, img.width, img.height, a.content, times[eye]))
    ref = lens_reference(a.lens_swift, a.dots_log)
    content = ({'kind': 'chart', 'head_locked': 'infinity', 'chart': 'see "chart"'} if src is None else
               {'kind': 'image', 'image': str(a.image), 'image_size': [src.width, src.height], 'distance_m': a.distance,
                'plane_width_m': a.plane_width, 'ipd_m': a.ipd,
                'assumption': 'view axes parallel to the head forward axis, eyes at x = -+ipd/2'})
    meta = {
        'set': a.set, 'tool': 'tools/golden/golden-frame.py', 'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'frustum': {'tangents_LRBT': {e: list(f.tangents) for e, f in frames.items()},
                    'order': '|tan| left, right, bottom, top (CornerTangents); source %s' % a.field},
        'density': {'px_per_deg_axis': a.ppd, 'px_per_tan': frames['L'].px_per_tan,
                    'grid': 'square px in tangent space: x = (tan_x + left) * px_per_tan, y = (top - tan_y) * px_per_tan'},
        'golden': {e: {'png': '%s.png' % e, 'size': [f.width, f.height], 'render_s': times[e]} for e, f in frames.items()},
        'content': content,
        'overlays': {
            'ndc_convention': NDC_CONVENTION,
            'frustum_rect': {e: {'tangents_LRBT': list(f.tangents), 'px': f.rect_px(),
                                 'ndc': [round(v, 9) for v in ndc(f.tangents, -f.tangents[0], -f.tangents[2]) +
                                         ndc(f.tangents, f.tangents[1], f.tangents[3])],
                                 'note': 'identity: the whole image'}
                             for e, f in frames.items()},
            'eye_axis': {e: {'tan': [0.0, 0.0], 'ndc': list(ndc(f.tangents, 0.0, 0.0)), 'px': list(f.axis_px())}
                         for e, f in frames.items()},
            'lens_outline': ({e: {'polygon': lens_outline(ref, e, f)} for e, f in frames.items()} if ref else None),
            'lens_source': ref['source'] if ref else 'none found',
            'lens_measured_rays': ({'L': ref['left'], 'R': ref['right'] or 'mirror of L: R(phi) = L(180 - phi)'}
                                   if ref else None),
        },
        'codec': {'status': 'none'},
    }
    if src is None:
        meta['chart'] = chart_meta(frames)
    write_meta(meta, d)
    print('wrote %s' % d)
    return 0


def parse_size(text):
    m = re.fullmatch(r'(\d+)x(\d+)', text)
    if not m:
        raise ValueError('size must be WxH, got %r' % text)
    return int(m.group(1)), int(m.group(2))


def parse_fov(text):
    if text in (None, 'off'):
        return None
    v = [float(x) for x in text.split(',')]
    if len(v) != 6:
        raise ValueError('foveation: cx,cy,rx,ry,shx,shy or off')
    return tuple(v)


def read_point(name, path=POINTS_FILE):
    for line in Path(path).read_text().splitlines():
        cols = line.split('\t')
        if line.startswith('#') or not cols or cols[0] != name:
            continue
        s, rs = float(cols[1]), float(cols[2])
        return {'fov_scale': s, 'render': (round(ASPECT[0] * rs), round(ASPECT[1] * rs)), 'foveation': parse_fov(cols[3]),
                'bitrate_mbps': float(cols[4]), 'fps': float(cols[5]), 'source': '%s %s' % (path, name)}
    raise ValueError('no point %r in %s' % (name, path))


def parse_bitrate(text):
    m = re.fullmatch(r'([0-9.]+)([kKmMgG]?)', text)
    if not m:
        raise ValueError('bitrate like 500M')
    return float(m.group(1)) * {'': 1, 'k': 1e3, 'm': 1e6, 'g': 1e9}[m.group(2).lower()]


def codec_round_trip(a, d, server, meta):
    ffmpeg = a.ffmpeg or shutil.which('ffmpeg')
    if not ffmpeg or not Path(ffmpeg).exists():
        msg = 'skipped: ffmpeg not on PATH (codec round trip not run; server PNGs are pre-codec)'
        print('codec %s: %s' % (a.codec, msg))
        return {'status': msg, 'requested': a.codec}
    bitrate = parse_bitrate(a.bitrate)
    encoder = a.encoder
    if encoder == 'auto':
        listing = subprocess.run([ffmpeg, '-hide_banner', '-encoders'], capture_output=True, text=True).stdout
        encoder = 'libx265' if 'libx265' in listing else 'hevc_videotoolbox'
    w, h = server['L'].width, server['L'].height
    with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
        clip = Path(tmp) / 'server.mp4'
        for e in 'LR':
            shutil.copyfile(d / ('%s.server.png' % e), d / ('%s.server.raw.png' % e))
        run = lambda cmd: subprocess.run(cmd, check=True, capture_output=True)
        run([ffmpeg, '-y', '-hide_banner', '-i', str(d / 'L.server.raw.png'), '-i', str(d / 'R.server.raw.png'),
             '-filter_complex', '[0][1]hstack=inputs=2,format=yuv420p', '-frames:v', '1', '-r', str(a.fps),
             '-c:v', encoder, '-b:v', str(int(bitrate)), '-tag:v', 'hvc1', str(clip)])
        pix = 'gray' if server['L'].channels == 1 else 'rgb24'
        run([ffmpeg, '-y', '-hide_banner', '-i', str(clip), '-filter_complex',
             '[0]split[a][b];[a]crop=%d:%d:0:0[l];[b]crop=%d:%d:%d:0[r]' % (w, h, w, h, w),
             '-map', '[l]', '-frames:v', '1', '-pred', 'none', '-pix_fmt', pix, str(d / 'L.server.png'),
             '-map', '[r]', '-frames:v', '1', '-pred', 'none', '-pix_fmt', pix, str(d / 'R.server.png')])
        size = clip.stat().st_size
    print('codec %s via %s: %d bytes for the frame pair (%.0f Mbit/s at %g fps)' % (a.codec, encoder, size,
                                                                                    size * 8 * a.fps / 1e6, a.fps))
    return {'status': 'round trip', 'codec': a.codec, 'encoder': encoder, 'ffmpeg': ffmpeg, 'bitrate_bps': bitrate,
            'fps': a.fps, 'frame_bytes': size, 'effective_mbps': size * 8 * a.fps / 1e6,
            'layout': 'L|R side by side, yuv420p, one frame; *.server.raw.png are the pre-codec frames'}


def cmd_encode(a):
    d = set_dir(a)
    meta = load_meta(d)
    point = read_point(a.point) if a.point else None
    render = parse_size(a.render) if a.render else point['render'] if point else (4176, 3333)
    fov = parse_fov(a.foveation) if a.foveation else point['foveation'] if point else None
    s = a.fov_scale if a.fov_scale is not None else point['fov_scale'] if point else 1.0
    ax, ay = fov_axes(fov, *render)
    server, t0 = {}, time.time()
    for eye in 'LR':
        l, r, b, t = meta['frustum']['tangents_LRBT'][eye]
        # the stream covers s x the frustum: golden fraction of its tangent span
        span_x = ((1 - s) * l / (l + r), (l + s * r) / (l + r))
        span_y = ((1 - s) * t / (b + t), (t + s * b) / (b + t))
        w, h, ch, rows = read_png(d / ('%s.png' % eye))
        img = encode_image(Image(w, h, ch, rows), ax, ay, eye, span_x, span_y)
        write_png(d / ('%s.server.png' % eye), img.width, img.height, img.channels, img.rows)
        server[eye] = img
        print('%s.server.png %dx%d from %dx%d in %.1f s' % (eye, img.width, img.height, w, h, time.time() - t0))
    for e in 'LR':
        p = d / ('%s.server.raw.png' % e)
        if p.exists():
            p.unlink()
    meta['render'] = {'size': list(render), 'fov_scale': s, 'point': point['source'] if point else None}
    meta['foveation'] = {
        'enabled': fov is not None,
        'settings': None if fov is None else dict(zip(('center_size_x', 'center_size_y', 'edge_ratio_x', 'edge_ratio_y',
                                                        'center_shift_x', 'center_shift_y'), fov)),
        'aligned': {'x': ax, 'y': ay, 'eye_size_ratio': [ax['opt'] / ax['coded'], ay['opt'] / ay['coded']]},
        'client_mapping': 'ALVRClient/Shaders.metal:136-189 (decompressAxisAlignedCoord, TextureToEyeUV, '
                          'EyeToTextureUV), :217-221 (side-by-side texCoord); FFR.swift:79-102 (aligned values)',
        'server_mapping': 'exact inverse of the client expansion per axis (golden-frame.py client_compress); each coded '
                          'pixel = area average (linear light) of the golden over its footprint',
    }
    meta['server'] = {'size': [ax['coded'], ay['coded']], 'png': {'L': 'L.server.png', 'R': 'R.server.png'},
                      'layout': 'one eye half of the side-by-side coded frame: L content at x [0, opt), R content at '
                                'x [coded - opt, coded) with x foveation mirrored; rows [0, opt_y); padding black',
                      'stream_tangents_LRBT': {e: [s * v for v in meta['frustum']['tangents_LRBT'][e]] for e in 'LR'}}
    meta['codec'] = codec_round_trip(a, d, server, meta) if a.codec else {'status': 'none'}
    write_meta(meta, d)
    print('wrote %s' % d)
    return 0


# ---- measure (W33 counter + Gaussian PSF against the golden) --------------------------------------------------------------

def counter_module(path=None):
    """tools/diag/diag-report.py when it has the W33 bar counter (feature/chart-autocapture); else None.
    GOLDEN_COUNTER=<diag-report.py> points at another copy."""
    path = Path(path or os.environ.get('GOLDEN_COUNTER') or DIAG / 'diag-report.py')
    try:
        m = _load('golden_counter', path)
    except (OSError, SyntaxError, ImportError):
        return None
    need = ('chart_captures', 'read_capture_png', 'patch_profile', 'count_bars', 'classify_bars', 'expected_bars')
    return m if all(hasattr(m, n) for n in need) else None


def modulation(profile, period_px):
    """Fundamental of a 50 % duty bar profile over black, relative to a full 0..white square wave: pi A1 / (4 mean),
    over whole periods (1.0 for ideal bars, up to the sampled square wave's own fundamental)."""
    n = int(len(profile) // period_px * period_px) or len(profile)
    v = profile[:n]
    mean = sum(v) / n
    if mean <= 0:
        return 0.0
    re_ = sum(x * math.cos(2 * math.pi * i / period_px) for i, x in enumerate(v))
    im_ = sum(x * math.sin(2 * math.pi * i / period_px) for i, x in enumerate(v))
    return math.pi * (2 / n * math.hypot(re_, im_)) / (4 * mean)


def psf_from_mtf(m, cpd):
    """Gaussian PSF FWHM (deg) whose MTF at `cpd` is m: MTF = exp(-(pi f p)^2 / (4 ln 2)); None outside (0, 1)."""
    if not 0 < m < 1:
        return None
    return math.sqrt(-4 * math.log(2) * math.log(m)) / (math.pi * cpd)


def golden_mtf(cpd, ppd):
    """The golden's own pixel box at `ppd` px/deg."""
    x = math.pi * cpd / ppd
    return math.sin(x) / x


LINEAR8 = bytes(int(round(v * 255)) for v in LINEAR)


def measure_rows(capture_dir, golden_ppd=80, cm=None):
    cm = cm or counter_module()
    if cm is None:
        raise ValueError('measure needs the W33 bar counter in tools/diag/diag-report.py (feature/chart-autocapture)')
    groups = {}
    for folder, data in cm.chart_captures(capture_dir):
        cc = data['chart_capture']
        linear = data.get('encoding', 'srgb') != 'srgb'
        setting = '%s rq=%s fov=%s' % (data.get('golden_set', Path(folder).name), cc.get('rq'), cc.get('fov'))
        for view in cc.get('views', []):
            sl = next((s for s in data.get('slices', []) if s.get('texture_index') == view.get('texture_index')
                       and s.get('slice') == view.get('slice')), None)
            if sl is None:
                continue
            w, h, pix = cm.read_capture_png(Path(folder) / sl['png'])
            lin = pix if linear else bytes(pix).translate(LINEAR8)
            for p in view.get('patches', []):
                cpd, orient = int(p['cpd']), p['orientation']
                prof = cm.patch_profile(w, h, pix, p['physical_rect'], orient)
                if not prof:
                    continue
                period = len(prof) / (PATCH_DEG * cpd)
                cls = cm.classify_bars(cm.count_bars(prof, period), cm.expected_bars(cpd))
                m = modulation(cm.patch_profile(w, h, lin, p['physical_rect'], orient), period)
                psf = psf_from_mtf(m / golden_mtf(cpd, golden_ppd), cpd)
                g = groups.setdefault((setting, view.get('eye'), p['position'], orient), [])
                g.append((cpd, cls, psf))
    rows = []
    for (setting, eye, pos, orient), g in sorted(groups.items()):
        g.sort()
        finest = None
        for cpd, cls, _ in g:                 # finest cpd with it and every coarser patch correct
            if cls != 'correct':
                break
            finest = cpd
        psfs = [p for _, _, p in g if p is not None]
        rows.append({'setting': setting, 'eye': eye, 'pos': pos, 'orient': orient, 'finest_correct_cpd': finest,
                     'psf_deg': statistics.median(psfs) if psfs else None,
                     'classes': ','.join('%d:%s' % (c, k) for c, k, _ in g)})
    return rows


def cmd_measure(a):
    ppd = a.ppd
    if ppd is None and a.set:
        ppd = load_meta(set_dir(a))['density']['px_per_deg_axis']
    rows = measure_rows(a.capture_dir, ppd or 80)
    head = ('setting', 'eye', 'pos', 'orient', 'finest_correct_cpd', 'psf_deg', 'classes')
    print('| ' + ' | '.join(head) + ' |')
    print('|' + '---|' * len(head))
    for r in rows:
        cells = [r[k] for k in head]
        cells[5] = 'n/a' if r['psf_deg'] is None else '%.4f' % r['psf_deg']
        cells[4] = 'none' if r['finest_correct_cpd'] is None else r['finest_correct_cpd']
        print('| ' + ' | '.join(str(c) for c in cells) + ' |')
    return 0


def cmd_push(a):
    d = set_dir(a)
    print('xcrun devicectl device copy to --device %s --domain-type appDataContainer --domain-identifier %s '
          '--source %s --destination Documents/diag/golden/%s --timeout 600' % (a.device, BUNDLE, d, a.set))
    return 0


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)

    def common(q):
        q.add_argument('--set', required=True, help='set name: <out>/<set>/')
        q.add_argument('--out', default=str(OUT))

    r = sub.add_parser('render')
    common(r)
    r.add_argument('--ppd', type=float, default=80, help='px/deg on the eye axis (default 80)')
    r.add_argument('--content', choices=('chart', 'image'), default='chart')
    r.add_argument('--image', type=Path)
    r.add_argument('--distance', type=float, default=2.0, help='image plane distance, m')
    r.add_argument('--plane-width', type=float, default=2.0, help='image plane width, m')
    r.add_argument('--ipd', type=float, default=0.063, help='m')
    r.add_argument('--field', type=Path, default=FIELD_FILE)
    r.add_argument('--lens-swift', type=Path, default=LENS_SWIFT)
    r.add_argument('--dots-log', type=Path, default=DOTS_LOG)
    e = sub.add_parser('encode')
    common(e)
    e.add_argument('--point', help='points-chart-avp.tsv row (render size from render scale, foveation, fov scale)')
    e.add_argument('--render', help='WxH per eye (default 4176x3333 or the point\'s)')
    e.add_argument('--foveation', help='cx,cy,rx,ry,shx,shy or off (default off or the point\'s)')
    e.add_argument('--fov-scale', type=float, help='stream covers s x the frustum (default 1 or the point\'s)')
    e.add_argument('--codec', choices=('hevc',))
    e.add_argument('--bitrate', default='500M')
    e.add_argument('--fps', type=float, default=90)
    e.add_argument('--encoder', default='auto', help='ffmpeg HEVC encoder (auto: libx265, else hevc_videotoolbox)')
    e.add_argument('--ffmpeg', help='ffmpeg binary (default: ffmpeg on PATH)')
    m = sub.add_parser('measure')
    m.add_argument('capture_dir', type=Path)
    m.add_argument('--set')
    m.add_argument('--out', default=str(OUT))
    m.add_argument('--ppd', type=float, help='golden px/deg (default: the set\'s meta, else 80)')
    q = sub.add_parser('push')
    common(q)
    q.add_argument('--device', default='DEVICE', help='devicectl device name or id')
    return p


def main(argv=None):
    a = build_parser().parse_args(argv)
    if getattr(a, 'ppd', None) is not None and a.ppd == int(a.ppd):
        a.ppd = int(a.ppd)
    try:
        if a.cmd == 'render' and a.content == 'image' and not a.image:
            raise ValueError('--content image needs --image PNG')
        return {'render': cmd_render, 'encode': cmd_encode, 'measure': cmd_measure, 'push': cmd_push}[a.cmd](a)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zlib.error) as error:
        print('golden-frame: %s' % error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
