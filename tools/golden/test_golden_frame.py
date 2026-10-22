import hashlib
import importlib.util
import io
import json
import math
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('golden_frame', HERE / 'golden-frame.py')
gf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gf)

D = math.pi / 180
DEV_L = (1.7321, 1.0, 1.1918, 1.0)          # |tan| left, right, bottom, top (avp-field.json, CornerTangents order)
DEV_R = (1.0, 1.7321, 1.1918, 1.0)


def swift_ndc(t, az_deg, el_deg):
    """GratingChart.ndc + CornerTangents.ndc (ResolutionChart.swift:212-216, CornerChart.swift:69-71), by hand."""
    l, r, b, top = t
    x, y = math.tan(az_deg * D), math.tan(el_deg * D) / math.cos(az_deg * D)
    return (2 * x - r + l) / (l + r), (2 * y - top + b) / (b + top)


class DeviceChart(unittest.TestCase):
    def test_patch_list_matches_resolution_chart(self):
        # GratingChart.patches: axis set then temporal20; V then H; cpd ascending at columnDeg 0, 2, -2, 4, -4, 6.
        p = gf.chart_patches()
        self.assertEqual(len(p), 24)
        self.assertEqual([(q['position'], q['orientation'], q['cpd']) for q in p[:7]],
                         [('axis', 'V', 8), ('axis', 'V', 10), ('axis', 'V', 12), ('axis', 'V', 14), ('axis', 'V', 17),
                          ('axis', 'V', 20), ('axis', 'H', 8)])
        self.assertEqual([q['temporal_deg'] for q in p[12:18]], [20, 22, 18, 24, 16, 26])
        self.assertEqual({q['up_deg'] for q in p if q['orientation'] == 'V'}, {1.0})
        self.assertEqual({q['up_deg'] for q in p if q['orientation'] == 'H'}, {-1.5})

    def test_patch_rects_equal_resolution_chart_for_device_tangents(self):
        # quad(t, eye:, patchRect).rect: the min/max NDC of the four Fick corners after the temporal mirror for L.
        for eye, t in (('L', DEV_L), ('R', DEV_R)):
            for p in gf.chart_patches():
                t0, t1 = p['temporal_deg'] - 0.75, p['temporal_deg'] + 0.75
                u0, u1 = p['up_deg'] - 0.75, p['up_deg'] + 0.75
                if eye == 'L':
                    t0, t1 = -t1, -t0
                corners = [swift_ndc(t, a, e) for a, e in ((t0, u0), (t1, u0), (t0, u1), (t1, u1))]
                want = (min(c[0] for c in corners), min(c[1] for c in corners),
                        max(c[0] for c in corners), max(c[1] for c in corners))
                got = gf.patch_ndc_rect(t, eye, p)
                for g, w in zip(got, want):
                    self.assertAlmostEqual(g, w, places=12)

    def test_axis_patch_hand_values(self):
        # L axis 8 cpd V: az -0.75..0.75, el 0.25..1.75; x0 = (2 tan(-0.75 deg) - 1 + 1.7321) / 2.7321.
        r = gf.patch_ndc_rect(DEV_L, 'L', gf.chart_patches()[0])
        self.assertAlmostEqual(r[0], (2 * math.tan(-0.75 * D) - 1 + 1.7321) / 2.7321, places=12)
        self.assertAlmostEqual(r[0], 0.258379, places=6)
        self.assertAlmostEqual(r[3], (2 * math.tan(1.75 * D) / math.cos(0.75 * D) - 1 + 1.1918) / 2.1918, places=12)


class TangentGrid(unittest.TestCase):
    def test_frame_size_at_80_px_per_deg(self):
        f = gf.Frame(DEV_L, 80)
        self.assertAlmostEqual(f.px_per_tan, 80 * 180 / math.pi, places=9)
        self.assertEqual((f.width, f.height), (round(2.7321 * 80 * 180 / math.pi), round(2.1918 * 80 * 180 / math.pi)))
        self.assertEqual((f.width, f.height), (12523, 10046))
        ax, ay = f.axis_px()
        self.assertAlmostEqual(ax, 1.7321 * 80 * 180 / math.pi, places=6)
        self.assertAlmostEqual(ay, 1.0 * 80 * 180 / math.pi, places=6)

    def test_bar_lands_on_expected_columns_at_80_px_per_deg(self):
        # L eye, axis 8 cpd vertical bars: temporal t0 = -0.75 deg, bar k spans t0 + k/8 .. t0 + k/8 + 1/16 temporal;
        # temporal is -x for L, so az = -t. Columns: X = (tan az + 1.7321) * 80 * 180 / pi.
        f = gf.Frame(DEV_L, 80)
        g = f.px_per_tan
        row_y = int((1.0 - math.tan(1.0 * D) / math.cos(0.0)) * g)       # through the patch centre, el 1 deg
        x0 = int((math.tan(-0.8 * D) + 1.7321) * g)
        x1 = int((math.tan(0.8 * D) + 1.7321) * g) + 1
        img = gf.render_chart(f, 'L', window=(x0, row_y, x1 - x0, 1))
        row = img.rows[0]
        for k in range(12):
            az_hi, az_lo = 0.75 - k / 8, 0.75 - k / 8 - 1 / 16
            c_lo, c_hi = (math.tan(az_lo * D) + 1.7321) * g, (math.tan(az_hi * D) + 1.7321) * g
            self.assertAlmostEqual(c_hi - c_lo, 5.0, delta=0.01)       # 1/16 deg at 80 px/deg on the axis
            inside = range(math.ceil(c_lo) + 1, math.floor(c_hi) - 1)
            for c in inside:
                self.assertEqual(row[c - x0], 255, (k, c))
            # The gap before the next bar (towards -az) is black, away from the edges.
            for c in range(math.ceil(c_lo - 5.0) + 1, math.floor(c_lo) - 1):
                self.assertEqual(row[c - x0], 0, (k, c))
            # Edge pixels carry the exact area coverage (linear light, sRGB-encoded).
            edge = math.floor(c_lo)
            cover = (edge + 1) - c_lo
            self.assertEqual(row[edge - x0], gf.srgb8(cover), (k, edge))

    def test_photo_box_reduce_averages_in_linear_light(self):
        img = gf.Image(2, 2, 3, [bytes([255, 255, 255, 0, 0, 0]), bytes([0, 0, 0, 255, 255, 255])])
        small = gf.box_reduce(img, 2)
        self.assertEqual((small.width, small.height), (1, 1))
        self.assertEqual(small.rows[0], bytes([gf.srgb8(0.5)] * 3))

    def test_photo_plane_is_centred_between_the_eyes(self):
        # 2 px photo (black | white) on a plane 1 m wide at 1 m: the split sits at tan_x = -ex / d per eye.
        src = gf.Image(2, 1, 3, [bytes([0, 0, 0, 255, 255, 255])])
        f = gf.Frame((1.0, 1.0, 1.0, 1.0), 20)
        for eye, ex in (('L', -0.05), ('R', 0.05)):
            row = gf.render_image(f, eye, src, 1.0, 1.0, 0.1).rows[f.height // 2]
            first_white = next(i for i in range(f.width) if row[i * 3] == 255)
            self.assertAlmostEqual(first_white, f.tan_to_px(-ex, 0)[0], delta=1.0)

    def test_lens_outline_pixels_use_projected_tangents(self):
        # Boundary dots angles=projected_tangent: (tan x, tan y) = tan(ecc) (cos ray, sin ray).
        f = gf.Frame(DEV_L, 10)
        x, y = f.tan_to_px(math.tan(40 * D) * math.cos(math.pi), 0.0)
        self.assertAlmostEqual(x, (1.7321 - math.tan(40 * D)) * f.px_per_tan, places=9)
        self.assertAlmostEqual(y, 1.0 * f.px_per_tan, places=9)

    def test_lens_outline_ndc_hand_values(self):
        # A 45 deg circle (tan 1) on the L frustum (1.7321, 1, 1.1918, 1), CornerTangents.ndc by hand:
        # ray 0 (1, 0) -> x (2 - 1 + 1.7321) / 2.7321 = 1, y 0.1918 / 2.1918; ray 90 (0, 1) -> y (2 - 1 + 1.1918) / 2.1918
        # = 1; ray 180 (-1, 0) -> x (-2 - 1 + 1.7321) / 2.7321 = -0.4640752.
        f = gf.Frame(DEV_L, 3)
        ref = {'left': {0.0: 45.0, 90.0: 45.0, 180.0: 45.0, 270.0: 45.0}, 'right': None}
        pts = {p['ray_deg']: p for p in gf.lens_outline(ref, 'L', f)}
        self.assertAlmostEqual(pts[0]['ndc'][0], 1.0, places=6)
        self.assertAlmostEqual(pts[0]['ndc'][1], 0.087507984, places=6)
        self.assertAlmostEqual(pts[90]['ndc'][0], 0.267962373, places=6)
        self.assertAlmostEqual(pts[90]['ndc'][1], 1.0, places=6)
        self.assertAlmostEqual(pts[180]['ndc'][0], -0.464075253, places=6)
        # px is the same point: ((x + 1) / 2 w, (1 - y) / 2 h).
        x, y = pts[180]['ndc']
        self.assertAlmostEqual(pts[180]['px'][0], (x + 1) / 2 * f.rect_px()[2], places=1)
        self.assertAlmostEqual(pts[180]['px'][1], (1 - y) / 2 * f.rect_px()[3], places=1)


FOV = (0.5, 0.45, 3, 3, 0.536, -0.159)          # a100-axis (points-chart-avp.tsv)


class Foveation(unittest.TestCase):
    def axes(self, w=4176, h=3333, fov=FOV):
        return gf.fov_axes(fov, w, h)

    def test_aligned_vars_follow_ffr_swift(self):
        ax, ay = self.axes()
        # FFR.swift:79-99 by hand for x: edge 2088 -> ceil(2088 / 6) * 6 = 2088 -> c 0.5; f = 0.5 + 0.5 / 3.
        self.assertAlmostEqual(ax['c'], 0.5, places=6)
        self.assertAlmostEqual(ax['f'], 0.5 + 0.5 / 3, places=6)
        self.assertEqual(ax['coded'], math.ceil(4176 * (0.5 + 0.5 / 3) / 32) * 32)
        self.assertEqual(ay['coded'] % 32, 0)

    def test_compress_is_the_exact_inverse_of_the_client_expansion(self):
        for a in self.axes():
            for i in range(1001):
                c = i / 1000
                self.assertAlmostEqual(gf.client_expand(gf.client_compress(c, a), a), c, places=9)
                u = gf.client_compress(c, a)
                self.assertGreaterEqual(u, -1e-12)
                self.assertLessEqual(u, 1 + 1e-12)
            # monotonic and continuous at the band edges
            us = [gf.client_compress(i / 4000, a) for i in range(4001)]
            self.assertTrue(all(b > p for p, b in zip(us, us[1:])))
            self.assertLess(max(b - p for p, b in zip(us, us[1:])), 4 / 4000 * a['r'])

    def test_compress_agrees_with_alvr_server_mapping(self):
        # fov-overlay.py u_of_c is the ALVR server's CompressAxisAlignedPixelShader map; same curve.
        for a in self.axes():
            for i in range(101):
                self.assertAlmostEqual(gf.client_compress(i / 100, a), gf.fo.u_of_c(i / 100, a), places=6)

    def test_round_trip_reproduces_client_expansion_within_one_pixel(self):
        # Synthetic golden: a horizontal ramp (value = eye image fraction) and a vertical one, float planes. Encode to
        # the server frame, then expand each target pixel with the client's shader maths (bilinear sample) and read the
        # fraction back: it must land within one target pixel of the pixel's own centre. Excluded: target pixels whose
        # sample point lies outside the first/last coded pixel centre, where the client's bilinear sampler clamps (the
        # outermost coded pixel spans up to 2r - 1 = 5 target px); at most 3 per edge.
        tw, th = 120, 96
        ax, ay = self.axes(tw, th)
        gw, gh = tw * 3, th * 3

        def clamped(f, a, mirror=False):
            c = gf.client_expand(1 - f if mirror else f, a) * a['opt'] - 0.5
            return c < 0 or c > a['opt'] - 1

        for eye in ('L', 'R'):
            ramp_x = [[(i + 0.5) / gw for i in range(gw)] for _ in range(gh)]
            ramp_y = [[(j + 0.5) / gh] * gw for j in range(gh)]
            sx = gf.encode_plane(ramp_x, gw, gh, ax, ay, eye)
            sy = gf.encode_plane(ramp_y, gw, gh, ax, ay, eye)
            self.assertEqual((len(sx[0]), len(sx)), (ax['coded'], ay['coded']))
            skip_x = [i for i in range(tw) if clamped((i + 0.5) / tw, ax, eye == 'R')]
            skip_y = [j for j in range(th) if clamped((j + 0.5) / th, ay)]
            self.assertLessEqual(len(skip_x), 6, skip_x)
            self.assertLessEqual(len(skip_y), 6, skip_y)
            worst = 0.0
            for j in range(th):
                for i in range(tw):
                    if (j % 5 and i % 5) or i in skip_x or j in skip_y:
                        continue
                    u = gf.client_sample(sx, (i + 0.5) / tw, (j + 0.5) / th, ax, ay, eye)
                    v = gf.client_sample(sy, (i + 0.5) / tw, (j + 0.5) / th, ax, ay, eye)
                    worst = max(worst, abs(u * tw - (i + 0.5)), abs(v * th - (j + 0.5)))
            self.assertLess(worst, 1.0, eye)

    def test_right_eye_content_is_flush_right_and_padding_black(self):
        tw, th = 120, 96
        ax, ay = self.axes(tw, th)
        ones = [[1.0] * 30 for _ in range(24)]
        for eye, pad_cols in (('L', range(math.ceil(ax['opt']), ax['coded'])),
                              ('R', range(0, ax['coded'] - math.ceil(ax['opt'])))):
            s = gf.encode_plane(ones, 30, 24, ax, ay, eye)
            self.assertTrue(all(s[0][c] == 0.0 for c in pad_cols), eye)
            self.assertTrue(all(row[c] == 0.0 for row in s[math.ceil(ay['opt']):] for c in range(ax['coded'])))
            mid = ax['coded'] // 2
            self.assertAlmostEqual(s[0][mid], 1.0, places=9)

    def test_foveation_off_is_a_plain_area_average(self):
        ax, ay = gf.fov_axes(None, 4, 2)
        s = gf.encode_plane([[0.0, 1.0] * 4, [1.0, 1.0] * 4, [0.0] * 8, [0.0] * 8], 8, 4, ax, ay, 'L')
        self.assertEqual([[round(v, 9) for v in r] for r in s], [[0.75] * 4, [0.0] * 4])


FIXTURE = HERE / 'fixtures' / 'ffr-expand-a100-axis-C.tsv'


class MetalFixture(unittest.TestCase):
    """The client's expansion from the real shader: tests/swift/DiagFFRExpandFixtureTests.swift runs
    decompressAxisAlignedCoord (Shaders.metal:148-189) on the Mac GPU and writes the fixture."""

    def test_client_expand_matches_the_shader_fixture(self):
        if not FIXTURE.exists():
            self.skipTest('%s absent: run sh tests/swift/run-tests.sh DiagFFRExpandFixtureTests on the Mac' % FIXTURE)
        lines = [l for l in FIXTURE.read_text().splitlines() if l and not l.startswith('#')]
        self.assertEqual(lines[0].split('\t'), ['uv_in_x', 'uv_in_y', 'eye', 'uv_out_x', 'uv_out_y'])
        rows = [l.split('\t') for l in lines[1:]]
        self.assertEqual(len(rows), 2 * 9 * 9)
        ax, ay = gf.fov_axes(FOV, 4176, 3333)             # a100-axis-C: render 1.1447 x 3648x2912
        worst = 0.0
        for ux, uy, eye, ox, oy in rows:
            got = gf.client_texture_uv(float(ux), float(uy), ax, ay, eye)
            err = max(abs(got[0] - float(ox)), abs(got[1] - float(oy)))
            worst = max(worst, err)
            self.assertLess(err, 1e-4, '%s (%s, %s): tool %s, shader (%s, %s)' % (eye, ux, uy, got, ox, oy))
        print('ffr fixture: %d points, worst |tool - shader| %.2e' % (len(rows), worst))

    def test_texture_uv_hand_values(self):
        # Foveation off: the identity, with the R half on the right (Shaders.metal:136-145, :217-221).
        ax, ay = gf.fov_axes(None, 100, 80)
        self.assertEqual(gf.client_texture_uv(0.25, 0.5, ax, ay, 'L'), (0.25, 0.5))
        self.assertEqual(gf.client_texture_uv(0.75, 0.5, ax, ay, 'R'), (0.75, 0.5))


class LensOutline(unittest.TestCase):
    LOG = ('DIAG dots_summary t_ms=1 eye=L points=11 rays=45:35,75:30,105:32.5,120:32.5,135:35,150:37.5,165:37.5,'
           '180:40,195:42.5,210:40,225:40\n'
           'DIAG dots_summary t_ms=1 eye=R points=0 rays=none\n'
           'DIAG dots_summary t_ms=2 eye=Both points=23 rays=0:37.5,15:35,30:35,45:32.5,60:30,75:30,90:30,105:32.5,'
           '120:32.5,135:35,150:40,165:37.5,180:40,195:42.5,210:42.5,240:30,255:32.5,270:32.5,285:30,300:32.5,315:32.5,'
           '330:32.5,345:37.5\n')
    # W34 BoundaryDotsLensReference.left: L rays, the others from Both.
    W34 = {0: 37.5, 15: 35, 30: 35, 45: 35, 60: 30, 75: 30, 90: 30, 105: 32.5, 120: 32.5, 135: 35, 150: 37.5, 165: 37.5,
           180: 40, 195: 42.5, 210: 40, 225: 40, 240: 30, 255: 32.5, 270: 32.5, 285: 30, 300: 32.5, 315: 32.5, 330: 32.5,
           345: 37.5}

    def test_log_fallback_merges_l_over_both(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'diag.log'
            p.write_text(self.LOG)
            ref = gf.lens_reference(swift=Path(d) / 'missing.swift', log=p)
        self.assertEqual(ref['left'], {float(k): float(v) for k, v in self.W34.items()})
        self.assertIn('diag.log', ref['source'])
        self.assertIsNone(ref['right'])

    def test_w34_swift_table_is_preferred_when_present(self):
        swift = ('enum BoundaryDotsLensReference {\n    static let tag = "device-20261021"\n'
                 '    static let left: [Double: Double] = [\n        0: 37.5, 90: 30, 180: 40,\n        270: 32.5,\n    ]\n'
                 '    static let right: [Double: Double]? = nil\n}\n')
        with tempfile.TemporaryDirectory() as d:
            s = Path(d) / 'BoundaryDots.swift'
            s.write_text(swift)
            ref = gf.lens_reference(swift=s, log=Path(d) / 'missing.log')
        self.assertEqual(ref['left'], {0.0: 37.5, 90.0: 30.0, 180.0: 40.0, 270.0: 32.5})
        self.assertIn('BoundaryDots.swift', ref['source'])

    def test_right_eye_is_the_mirror_and_interpolation_is_circular(self):
        ref = {'left': {0.0: 30.0, 90.0: 40.0, 180.0: 50.0, 270.0: 20.0}, 'right': None}
        self.assertAlmostEqual(gf.lens_ecc(ref, 'L', 45), 35.0)
        self.assertAlmostEqual(gf.lens_ecc(ref, 'L', 315), 25.0)
        self.assertAlmostEqual(gf.lens_ecc(ref, 'R', 0), 50.0)      # R(phi) = L(180 - phi)
        self.assertAlmostEqual(gf.lens_ecc(ref, 'R', 180), 30.0)


class MetaAndCli(unittest.TestCase):
    def test_render_encode_meta_sha256_and_push(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'out'
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(gf.main(['render', '--set', 'tiny', '--out', str(out), '--ppd', '3']), 0)
                self.assertEqual(gf.main(['encode', '--set', 'tiny', '--out', str(out), '--render', '96x80',
                                          '--foveation', '0.5,0.45,3,3,0.536,-0.159']), 0)
                self.assertEqual(gf.main(['push', '--set', 'tiny', '--out', str(out), '--device', 'AVP']), 0)
            s = out / 'tiny'
            meta = json.loads((s / 'meta.json').read_text())
            for name in ('L.png', 'R.png', 'L.server.png', 'R.server.png'):
                self.assertEqual(meta['files'][name]['sha256'], hashlib.sha256((s / name).read_bytes()).hexdigest(), name)
            self.assertEqual(meta['frustum']['tangents_LRBT']['L'], list(DEV_L))
            self.assertEqual(meta['density']['px_per_deg_axis'], 3)
            self.assertEqual(meta['render']['size'], [96, 80])
            self.assertEqual(meta['foveation']['settings'], {'center_size_x': 0.5, 'center_size_y': 0.45,
                                                             'center_shift_x': 0.536, 'center_shift_y': -0.159,
                                                             'edge_ratio_x': 3, 'edge_ratio_y': 3})
            self.assertEqual(meta['codec']['status'], 'none')
            self.assertEqual(len(meta['overlays']['lens_outline']['L']['polygon']), 72)
            self.assertEqual(meta['overlays']['frustum_rect']['L']['tangents_LRBT'], list(DEV_L))
            self.assertEqual(len(meta['chart']['patches']['R']), 24)
            # Every overlay element also in eye NDC (CornerTangents.ndc, CornerChart.swift:69-71), by hand:
            # L axis x = (0 - 1 + 1.7321) / 2.7321, y = (0 - 1 + 1.1918) / 2.1918; R x mirrored.
            ov = meta['overlays']
            self.assertIn('CornerChart.swift:69-71', ov['ndc_convention'])
            for eye in 'LR':
                self.assertEqual(ov['frustum_rect'][eye]['ndc'], [-1.0, -1.0, 1.0, 1.0])
            self.assertAlmostEqual(ov['eye_axis']['L']['ndc'][0], 0.267962373, places=8)
            self.assertAlmostEqual(ov['eye_axis']['L']['ndc'][1], 0.087507984, places=8)
            self.assertAlmostEqual(ov['eye_axis']['R']['ndc'][0], -0.267962373, places=8)
            self.assertEqual(ov['eye_axis']['L']['tan'], [0.0, 0.0])
            p = ov['lens_outline']['L']['polygon'][0]
            tx, ty = p['tan']
            self.assertAlmostEqual(p['ndc'][0], (2 * tx - 1 + 1.7321) / 2.7321, places=6)
            self.assertAlmostEqual(p['ndc'][1], (2 * ty - 1 + 1.1918) / 2.1918, places=6)
            self.assertTrue(all('ndc' in q for q in ov['lens_outline']['R']['polygon']))
            self.assertEqual(len(meta['chart']['patches']['L'][0]['ndc_rect']), 4)
            w, h, ch, _ = gf.read_png(s / 'L.server.png')
            self.assertEqual((w, h), tuple(meta['server']['size']))
            text = buf.getvalue()
            self.assertIn('xcrun devicectl device copy to --device AVP', text)
            self.assertIn('Documents/diag/golden/tiny', text)

    def test_codec_skips_without_ffmpeg(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'out'
            with redirect_stdout(io.StringIO()) as buf:
                gf.main(['render', '--set', 't', '--out', str(out), '--ppd', '2'])
                rc = gf.main(['encode', '--set', 't', '--out', str(out), '--render', '64x48', '--codec', 'hevc',
                              '--bitrate', '500M', '--ffmpeg', str(Path(d) / 'no-ffmpeg')])
            self.assertEqual(rc, 0)
            self.assertIn('skipped', buf.getvalue())
            meta = json.loads((out / 't' / 'meta.json').read_text())
            self.assertTrue(meta['codec']['status'].startswith('skipped'))

    def test_png_round_trip_grey_and_rgb(self):
        with tempfile.TemporaryDirectory() as d:
            for ch in (1, 3):
                p = Path(d) / ('x%d.png' % ch)
                rows = [bytes((i * 7 + j * 3 + k) & 255 for i in range(5) for k in range(ch)) for j in range(4)]
                gf.write_png(p, 5, 4, ch, rows)
                self.assertEqual(gf.read_png(p), (5, 4, ch, rows))


class Measure(unittest.TestCase):
    def test_gaussian_psf_from_modulation(self):
        # Gaussian PSF of FWHM p: MTF(f) = exp(-(pi f p)^2 / (4 ln 2)).
        p, f = 0.05, 10
        m = math.exp(-(math.pi * f * p) ** 2 / (4 * math.log(2)))
        self.assertAlmostEqual(gf.psf_from_mtf(m, f), p, places=12)
        self.assertIsNone(gf.psf_from_mtf(1.2, f))
        self.assertIsNone(gf.psf_from_mtf(0.0, f))

    def test_fundamental_modulation_of_a_square_wave(self):
        prof = [255.0 if (i // 5) % 2 == 0 else 0.0 for i in range(100)]      # 10 px period
        # the sampled square wave's fundamental over the continuous one: pi / (10 sin(pi / 10))
        self.assertAlmostEqual(gf.modulation(prof, 10.0), math.pi / (10 * math.sin(math.pi / 10)), places=9)
        half = [0.5 * v + 0.25 * 255 for v in prof]                             # contrast halved about the same mean
        self.assertAlmostEqual(gf.modulation(half, 10.0) / gf.modulation(prof, 10.0), 0.5, places=9)

    @unittest.skipUnless(gf.counter_module() is not None, 'W33 bar counter (feature/chart-autocapture) not merged')
    def test_measure_reads_a_w33_capture(self):
        # A perfect L capture at 80 px/deg: every patch's bars drawn into its physical rect (W33 capture layout).
        ppd, w, h = 80, 1400, 400
        pix = bytearray(w * h * 4)
        patches = []
        for k, p in enumerate(gf.chart_patches()[:12]):
            x0, y0 = 20 + (k % 6) * 220, 40 + (k // 6) * 200
            x1, y1 = x0 + 120, y0 + 120
            period = 120 / (1.5 * p['cpd'])
            for y in range(y0, y1):
                for x in range(x0, x1):
                    d = (x - x0) if p['orientation'] == 'V' else (y - y0)
                    on = (d + 0.5) % period < period / 2
                    pix[(y * w + x) * 4:(y * w + x) * 4 + 4] = b'\xff\xff\xff\xff' if on else b'\0\0\0\xff'
            patches.append(dict(position=p['position'], cpd=p['cpd'], orientation=p['orientation'],
                                physical_rect=[x0, y0, x1, y1], nyquist_logical_cpd=20.0, nyquist_physical_cpd=20.0))
        with tempfile.TemporaryDirectory() as d:
            cap = Path(d) / 'chart-1'
            cap.mkdir()
            gf.fo.vc.write_png(cap / 'L.png', w, h, bytes(pix))
            (cap / 'capture.json').write_text(json.dumps(dict(
                t_ms=1, encoding='srgb', slices=[dict(eye='L', view=0, slice=0, texture_index=0, png='L.png', width=w, height=h)],
                chart_capture=dict(mode='auto', rq='1.000', rq_set='1.000', fov='off', views=[
                    dict(eye='L', view=0, slice=0, texture_index=0, patches=patches)]))))
            rows = gf.measure_rows(Path(d), golden_ppd=ppd)
        self.assertEqual([(r['eye'], r['pos'], r['orient']) for r in rows], [('L', 'axis', 'H'), ('L', 'axis', 'V')])
        self.assertEqual({r['finest_correct_cpd'] for r in rows}, {20})


if __name__ == '__main__':
    unittest.main()
