#!/usr/bin/env python3
"""Model lens of Boundary dots (style lens): the Frustum Pixel Map diagram's construction (function vBoundary).

Per eye, the device frustum's edge angles (deg from the eye axis) temporal T0, nasal N0, up U0, down D0 are moved inwards
by one inset angle: T = T0 - inset, ... clamped to >= 1 deg. That inset rectangle has half-extents a_T = tan T,
a_N = tan N, b_U = tan U, b_D = tan D in tangent space. The lens curve is a per-quadrant superellipse inscribed in it:
for phi (0 temporal, 90 up, 180 nasal, 270 down, in the eye's tangent plane), c = cos phi, s = sin phi,
a = a_T if c >= 0 else a_N, b = b_U if s >= 0 else b_D, n by quadrant (upper-nasal 2, upper-temporal 3, lower-nasal 1.5,
lower-temporal 4), rho = 1 / ((|c|/a)^n + (|s|/b)^n)^(1/n), point (rho c temporal+, rho s up+). The curve touches the
rectangle at the four axis crossings, so the rectangle is the lens bbox.

The Swift twin is ALVRClient/Diagnostics/BoundaryDotsLensModel.swift; fixtures/lens-model.json pins both (1e-6).
Standard library only.

  python3 tools/diag/lens_model.py svg      # build/lens-model.svg: frustum, inset rectangle, lens, axes, centre per eye
  python3 tools/diag/lens_model.py fixture  # the fixture JSON on stdout
"""
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MODEL = 'superellipse(2,3,1.5,4)'
EXPONENTS = {'upper_nasal': 2.0, 'upper_temporal': 3.0, 'lower_nasal': 1.5, 'lower_temporal': 4.0}
DEFAULT_INSET_DEG = 15.0
MIN_EDGE_DEG = 1.0
POINT_COUNT = 480
# Device m5_view |tan| left, right, bottom, top, 21 Oct (BoundaryDotsFrustum.device): L temporal is its left side.
DEVICE_TAN_LRDU = {'L': (1.7321, 1.0, 1.1918, 1.0), 'R': (1.0, 1.7321, 1.1918, 1.0)}
HUES = {'L': '#00c9ff', 'R': '#ffa800'}     # ProjectionOverlay.hue: L cyan, R orange


def frustum_deg(eye, tan_lrdu=None):
    """The frustum's edge angles (temporal, nasal, up, down) in degrees from the eye axis."""
    left, right, bottom, top = tan_lrdu or DEVICE_TAN_LRDU[eye]
    temporal, nasal = (left, right) if eye == 'L' else (right, left)
    return tuple(math.degrees(math.atan(t)) for t in (temporal, nasal, top, bottom))


def inset_rect(eye, inset_deg, tan_lrdu=None):
    """{temporal, nasal, up, down}: degrees, each frustum edge angle minus `inset_deg`, at least 1 deg; and
    {a_t, a_n, b_u, b_d}: their tangents."""
    edges = [max(MIN_EDGE_DEG, d - inset_deg) for d in frustum_deg(eye, tan_lrdu)]
    rect = dict(zip(('temporal', 'nasal', 'up', 'down'), edges))
    rect.update(zip(('a_t', 'a_n', 'b_u', 'b_d'), (math.tan(math.radians(d)) for d in edges)))
    return rect


def exponent(c, s):
    if s >= 0:
        return EXPONENTS['upper_temporal'] if c >= 0 else EXPONENTS['upper_nasal']
    return EXPONENTS['lower_temporal'] if c >= 0 else EXPONENTS['lower_nasal']


def point(rect, phi_deg):
    """Lens point at `phi_deg` in the eye's tangent plane: (temporal +, up +)."""
    phi = math.radians(phi_deg)
    c, s = math.cos(phi), math.sin(phi)
    a = rect['a_t'] if c >= 0 else rect['a_n']
    b = rect['b_u'] if s >= 0 else rect['b_d']
    n = exponent(c, s)
    rho = 1 / ((abs(c) / a) ** n + (abs(s) / b) ** n) ** (1 / n)
    return rho * c, rho * s


def lens_points(eye, inset_deg, count=POINT_COUNT, tan_lrdu=None):
    """`count` points around, phi = 360 i / count, in the eye frame (temporal +, up +)."""
    rect = inset_rect(eye, inset_deg, tan_lrdu)
    return [point(rect, 360.0 * i / count) for i in range(count)]


def head(eye, p):
    """Eye frame (temporal, up) to head frame (x right, y up): L's temporal side is its left."""
    return (-p[0] if eye == 'L' else p[0]), p[1]


def box_lrud(eye, rect):
    """The inset rectangle as head-frame |tan| (left, right, up, down), ProjectionBox order."""
    left, right = (rect['a_t'], rect['a_n']) if eye == 'L' else (rect['a_n'], rect['a_t'])
    return left, right, rect['b_u'], rect['b_d']


def area_fraction(eye, inset_deg, tan_lrdu=None):
    """Lens polygon (480 points) area in tangent space over the frustum's."""
    left, right, bottom, top = tan_lrdu or DEVICE_TAN_LRDU[eye]
    xy = lens_points(eye, inset_deg, tan_lrdu=tan_lrdu)
    twice = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))
    return abs(twice) / 2 / ((left + right) * (bottom + top))


def ecc_deg(eye, ray_deg, inset_deg, tan_lrdu=None):
    """Eccentricity (deg) of the lens curve on the head-frame ray `ray_deg` (CCW from right)."""
    phi = ray_deg if eye == 'R' else 180 - ray_deg
    t, u = point(inset_rect(eye, inset_deg, tan_lrdu), phi % 360)
    return math.degrees(math.atan(math.hypot(t, u)))


def fixture():
    cases = []
    for inset in (15.0, 10.0):
        for eye in 'LR':
            rect = inset_rect(eye, inset)
            pts = [point(rect, phi) for phi in range(0, 360, 15)]
            cases.append({
                'name': '%s inset %g' % (eye, inset), 'eye': eye, 'inset_deg': inset,
                'rect_deg': {k: rect[k] for k in ('temporal', 'nasal', 'up', 'down')},
                'rect_tan': {k: rect[k] for k in ('a_t', 'a_n', 'b_u', 'b_d')},
                'box_tan_LRUD': list(box_lrud(eye, rect)),
                'points': [{'phi_deg': phi, 'eye': list(p), 'head': list(head(eye, p))}
                           for phi, p in zip(range(0, 360, 15), pts)],
                'area_fraction': area_fraction(eye, inset)})
    return {
        'about': 'Boundary dots model lens (style lens): inset rectangle and per-quadrant superellipse, checked by '
                 'tests/swift/BoundaryOutlineTests.swift (BoundaryDotsLensModel.swift) and tools/diag/test_lens_model.py '
                 '(lens_model.py) to 1e-6. Generated by `python3 tools/diag/lens_model.py fixture`. rect_deg: frustum edge '
                 'angle minus inset_deg (>= 1); rect_tan: a_t, a_n, b_u, b_d; box_tan_LRUD: head-frame |tan| left, right, '
                 'up, down. points: phi every 15 deg (0 temporal, 90 up, 180 nasal, 270 down); eye = (temporal +, up +), '
                 'head = (x right, y up). area_fraction: the 480-point polygon over the frustum, tangent space.',
        'model': MODEL, 'exponents': EXPONENTS, 'count': POINT_COUNT, 'min_edge_deg': MIN_EDGE_DEG,
        'device_tan_LRDU': {e: list(t) for e, t in DEVICE_TAN_LRDU.items()}, 'cases': cases}


def fixture_text(fx):
    """The fixture as JSON, one line per key and per point."""
    head_keys = [k for k in fx if k != 'cases']
    lines = ['{'] + [' %s: %s,' % (json.dumps(k), json.dumps(fx[k])) for k in head_keys] + [' "cases": [']
    for i, case in enumerate(fx['cases']):
        keys = [k for k in case if k != 'points']
        lines += ['  {'] + ['   %s: %s,' % (json.dumps(k), json.dumps(case[k])) for k in keys] + ['   "points": [']
        lines += ['    %s%s' % (json.dumps(p), ',' if j + 1 < len(case['points']) else '') for j, p in enumerate(case['points'])]
        lines += ['   ]', '  }' + (',' if i + 1 < len(fx['cases']) else '')]
    return '\n'.join(lines + [' ]', '}']) + '\n'


def svg(inset_deg=DEFAULT_INSET_DEG, scale=150.0):
    """Per eye (L left, R right, head frame): device frustum, inset rectangle (thin), lens, axes, 0.5 deg centre circle."""
    pad, gap = 30.0, 60.0
    panels, x0 = [], pad
    for eye in 'LR':
        left, right, bottom, top = DEVICE_TAN_LRDU[eye]
        panels.append((eye, x0 + left * scale, pad + top * scale))
        x0 += (left + right) * scale + gap
    width = x0 - gap + pad
    height = 2 * pad + max(t[2] + t[3] for t in DEVICE_TAN_LRDU.values()) * scale + 40
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" viewBox="0 0 %.0f %.0f">' % (width, height, width, height),
           '<rect width="100%" height="100%" fill="black"/>']

    def xy(cx, cy, x, y):
        return '%.2f,%.2f' % (cx + x * scale, cy - y * scale)
    for eye, cx, cy in panels:
        hue, (left, right, bottom, top) = HUES[eye], DEVICE_TAN_LRDU[eye]
        rect = inset_rect(eye, inset_deg)
        bl, br, bu, bd = box_lrud(eye, rect)
        box = lambda l, r, u, d: ' '.join(xy(cx, cy, *p) for p in ((-l, u), (r, u), (r, -d), (-l, -d)))
        lens = ' '.join(xy(cx, cy, *head(eye, p)) for p in lens_points(eye, inset_deg))
        circle = math.tan(math.radians(0.5)) * scale
        out += ['<polygon points="%s" fill="none" stroke="%s" stroke-width="3"/>' % (box(left, right, top, bottom), hue),
                '<polygon points="%s" fill="none" stroke="%s" stroke-width="1"/>' % (box(bl, br, bu, bd), hue),
                '<polygon points="%s" fill="none" stroke="%s" stroke-width="2"/>' % (lens, hue),
                '<polyline points="%s %s" fill="none" stroke="%s" stroke-width="1"/>' % (xy(cx, cy, -bl, 0), xy(cx, cy, br, 0), hue),
                '<polyline points="%s %s" fill="none" stroke="%s" stroke-width="1"/>' % (xy(cx, cy, 0, bu), xy(cx, cy, 0, -bd), hue),
                '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" stroke-width="1"/>' % (cx, cy, max(circle, 2), hue),
                '<text x="%.2f" y="%.2f" fill="%s" font-family="monospace" font-size="13">%s inset %g: temporal %.1f nasal %.1f '
                'up %.1f down %.1f deg, %s, area %.1f%%</text>' % (
                    cx - left * scale, cy + bottom * scale + 22, hue, eye, inset_deg, rect['temporal'], rect['nasal'], rect['up'],
                    rect['down'], MODEL, 100 * area_fraction(eye, inset_deg))]
    return '\n'.join(out + ['</svg>']) + '\n'


def main(argv):
    command = argv[1] if len(argv) > 1 else 'svg'
    if command == 'fixture':
        sys.stdout.write(fixture_text(fixture()))
    elif command == 'svg':
        path = REPO / 'build' / 'lens-model.svg'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(svg())
        print(path)
    else:
        sys.exit('usage: lens_model.py [svg|fixture]')


if __name__ == '__main__':
    main(sys.argv)
