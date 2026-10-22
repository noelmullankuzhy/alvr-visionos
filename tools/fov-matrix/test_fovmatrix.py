"""Tests for fovmatrix.py (settings mapping, points parsing, dump classification, stats, summary row)."""
import importlib.util
import json
import math
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('fovmatrix', os.path.join(HERE, 'fovmatrix.py'))
fm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fm)
_as = importlib.util.spec_from_file_location('avp_sharpness', os.path.join(HERE, '..', 'diag', 'avp-sharpness.py'))
AS = importlib.util.module_from_spec(_as)
_as.loader.exec_module(AS)

def wj(path, obj):
    with open(path, 'w') as f:
        json.dump(obj, f)


HEADER = '# name\tfov\trender\tfoveation\tmbps\tfps\textra\n'


def parse(text):
    return fm.parse_points(text.splitlines())


class PointsTest(unittest.TestCase):
    def test_parse_basic_and_comments(self):
        pts = parse(HEADER + '\n' + 'a\t1.0\t1.0\t0.5,0.45,3,3,0,0\t500\t90\n')
        self.assertEqual(len(pts), 1)
        p = pts[0]
        self.assertEqual((p['name'], p['fov_scale'], p['render_scale'], p['bitrate_mbps'], p['fps']), ('a', 1.0, 1.0, 500.0, 90.0))
        self.assertEqual(p['foveation'], (0.5, 0.45, 3.0, 3.0, 0.0, 0.0))
        self.assertEqual(p['extra'], [])

    def test_off_and_extra(self):
        pts = parse('b\t0.6\t1.03\toff\t500\t90\tvideo.x.y=1\tvideo.z={"variant":"A"}\n')
        self.assertIsNone(pts[0]['foveation'])
        self.assertEqual(pts[0]['extra'], ['video.x.y=1', 'video.z={"variant":"A"}'])

    def test_errors_are_precise(self):
        for bad, frag in [('a\t1.0\t1.0\t0.5,0.45,3,3,0\t500\t90\n', 'foveation'),
                          ('a\t1.0\t1.0\toff\t500\n', 'columns'),
                          ('a\tx\t1.0\toff\t500\t90\n', 'fov_scale'),
                          ('a\t0\t1.0\toff\t500\t90\n', 'fov_scale'),
                          ('a b\t1\t1\toff\t500\t90\n', 'name'),
                          ('a\t1\t1\toff\t500\t90\tnoequals\n', 'extra'),
                          ('a\t1\t1\toff\t500\t90\n' * 2, 'duplicate')]:
            with self.assertRaises(ValueError) as cm:
                parse(bad)
            self.assertIn(frag, str(cm.exception))

    def test_shipped_chart_points(self):
        with open(os.path.join(HERE, 'points-chart.tsv')) as f:
            pts = fm.parse_points(f.read().splitlines())
        self.assertEqual(len(pts), 10)
        self.assertEqual([p['name'] for p in pts][-1], 'oneone')
        for p in pts:
            self.assertEqual((p['fps'], p['bitrate_mbps']), (90.0, 500.0))
        by = {p['name']: p for p in pts}
        self.assertEqual(sorted(p['fov_scale'] for p in pts), [0.6, 0.6, 0.6, 0.6, 0.7, 0.7, 0.7, 1.0, 1.0, 1.0])
        self.assertEqual(by['oneone']['render_scale'], 1.03)
        self.assertEqual(by['oneone']['foveation'], (0.5, 0.45, 3.0, 3.0, 0.536, -0.159))


ENC_KEYS = ['video.encoder_config.nvenc.quality_preset={"variant":"P4"}',
            'video.encoder_config.nvenc.multi_pass={"variant":"Disabled"}',
            'video.encoder_config.nvenc.split_encode_mode={"variant":"ForceTwo"}']


class FlagTest(unittest.TestCase):
    def test_default_is_dump_and_not_a_session_key(self):
        p = parse('a\t1\t1\toff\t100\t90\tvideo.q=2\n')[0]
        self.assertEqual(p['flag'], 'dump')
        self.assertEqual(p['extra'], ['video.q=2'])

    def test_flag_column_is_taken_out_of_the_session_sets(self):
        for f in ('dump', 'stress', 'stress,dump'):
            p = parse('a\t1\t1\toff\t100\t90\tflag=%s\tvideo.q=2\n' % f)[0]
            self.assertEqual(p['flag'], f)
            self.assertEqual(p['extra'], ['video.q=2'])
            self.assertEqual(fm.session_sets(p)[-1], 'video.q=2')
            self.assertFalse([x for x in fm.session_sets(p) if x.startswith('flag')])

    def test_bad_flag(self):
        for bad in ('flag=', 'flag=bogus', 'flag=dump,bogus', 'flag=on'):
            with self.assertRaises(ValueError) as cm:
                parse('a\t1\t1\toff\t100\t90\t%s\n' % bad)
            self.assertIn('flag', str(cm.exception))

    def test_has_dump(self):
        self.assertTrue(fm.flag_has_dump('dump'))
        self.assertTrue(fm.flag_has_dump('stress,dump'))
        self.assertFalse(fm.flag_has_dump('stress'))

    def test_sim_and_chart_points_stay_dump(self):
        for n in ('points-chart.tsv', 'points-chart-sim.tsv'):
            with open(os.path.join(HERE, n)) as f:
                self.assertEqual({p['flag'] for p in fm.parse_points(f.read().splitlines())}, {'dump'})

    def test_shipped_stress_points(self):
        with open(os.path.join(HERE, 'points-stress-enc.tsv')) as f:
            pts = {p['name']: p for p in fm.parse_points(f.read().splitlines())}
        self.assertEqual(list(pts), ['enc-base100', 's100', 's300', 's500', 's500-nosplit'])
        self.assertEqual([pts[n]['flag'] for n in pts], ['dump', 'stress', 'stress', 'stress', 'stress'])
        self.assertEqual([pts[n]['bitrate_mbps'] for n in pts], [100.0, 100.0, 300.0, 500.0, 500.0])
        for p in pts.values():
            self.assertEqual((p['fps'], p['fov_scale'], p['render_scale'], p['foveation']),
                             (90.0, 1.0, 1.0, (0.5, 0.45, 3.0, 3.0, 0.536, -0.159)))
        for n in ('enc-base100', 's100', 's300', 's500'):
            self.assertEqual(pts[n]['extra'], ENC_KEYS)
        self.assertEqual(pts['s500-nosplit']['extra'],
                         ENC_KEYS[:2] + ['video.encoder_config.nvenc.split_encode_mode={"variant":"Disabled"}'])


AVP_EYES = 'L:1.7321,1,1.1918,1;R:1,1.7321,1.1918,1'      # device CompositorServices |tan| L,R,D,U (avp-field.json)


class EyeTangentsTest(unittest.TestCase):
    """eye_tangents=L:l,r,d,u;R:l,r,d,u: the client's -ALVRDebugEyeTangents launch argument, never a session path."""
    def test_default_is_none(self):
        self.assertIsNone(parse('a\t1\t1\toff\t100\t90\tvideo.q=2\n')[0]['eye_tangents'])

    def test_column_is_taken_out_of_the_session_sets(self):
        p = parse('a\t0.85\t1\toff\t100\t90\teye_tangents=%s\tvideo.q=2\n' % AVP_EYES)[0]
        self.assertEqual(p['eye_tangents'], AVP_EYES)
        self.assertEqual(p['extra'], ['video.q=2'])
        self.assertFalse([x for x in fm.session_sets(p) if 'eye_tangents' in x])

    def test_bad_values(self):
        for bad in ('L:1,1,1,1', 'L:1,1,1;R:1,1,1,1', 'L:1,1,1,1;R:1,0,1,1', 'L:1,1,1,1;R:1,-1,1,1', 'L:1,1,1,1;L:1,1,1,1',
                    'L:1,1,1,1;X:1,1,1,1', 'L:1,1,1,1;R:1,x,1,1', ''):
            with self.assertRaises(ValueError) as cm:
                parse('a\t1\t1\toff\t100\t90\teye_tangents=%s\n' % bad)
            self.assertIn('eye_tangents', str(cm.exception))

    def test_subcommand_prints_the_value_or_nothing(self):
        with tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False) as f:
            f.write('a\t1\t1\toff\t100\t90\teye_tangents=%s\nb\t1\t1\toff\t100\t90\n' % AVP_EYES)
        try:
            import io
            from contextlib import redirect_stdout
            for name, want in (('a', AVP_EYES + '\n'), ('b', '\n')):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    self.assertEqual(fm.main(['fovmatrix.py', 'eye-tangents', f.name, name]), 0)
                self.assertEqual(buf.getvalue(), want)
        finally:
            os.unlink(f.name)

    def test_shipped_avp_points(self):
        with open(os.path.join(HERE, 'points-chart-avp.tsv')) as f:
            text = f.read()
        pts = fm.parse_points(text.splitlines())
        names = ['a%s-%s' % (s, v) for s in ('100', '085', '070') for v in ('asrun', 'centred', 'wider')]
        rec = ['a100-axis-C', 'a100-axis-A', 'a100-wider-A']          # the doc's three recommended settings
        self.assertEqual([p['name'] for p in pts], names + rec + ['a100-crop-C', 'a100-crop-A', 'a100-crop-T'])
        for p in pts[:len(names)]:
            scale, variant = p['name'][1:].split('-')
            self.assertEqual(p['fov_scale'], int(scale) / 100)
            self.assertEqual(p['eye_tangents'], AVP_EYES)
            self.assertEqual((p['render_scale'], p['bitrate_mbps'], p['fps'], p['extra'], p['flag']), (1.0, 100.0, 90.0, [], 'dump'))
        # recommended: full frustum, the budget's render size (4176x3334 C axis, 3648x2912 A axis, 3008x2402 A wider)
        by = {p['name']: p for p in pts}
        for name, fv, rs, budget in (('a100-axis-C', (0.5, 0.45, 3.0, 3.0, 0.536, -0.159), 4176 / 3648, (2784, 2240)),
                                     ('a100-axis-A', (0.5, 0.45, 3.0, 3.0, 0.536, -0.159), 1.0, (2432, 1856)),
                                     ('a100-wider-A', (0.563, 0.618, 2.5, 2.5, 0.335, -0.168), 3008 / 3648, (2432, 1856))):
            p = by[name]
            self.assertEqual((p['fov_scale'], p['foveation'], p['eye_tangents'], p['bitrate_mbps'], p['fps'], p['flag']),
                             (1.0, fv, AVP_EYES, 100.0, 90.0, 'dump'))
            self.assertAlmostEqual(p['render_scale'], rs, places=4)
            ax, ay = AS.axes_for(fv, *fm.render_size(p['render_scale']))
            self.assertLessEqual(ax['coded'], budget[0])                          # the matrix's render fits the budget
            self.assertLessEqual(ay['coded'], budget[1])
        self.assertEqual(text, AS.points(AS.load()), 'regenerate: python3 tools/diag/avp-sharpness.py points > tools/fov-matrix/points-chart-avp.tsv')

    def test_device_density_by_hand(self):
        # viewport 6261x5023 over the device's |tan| spans (1.7321 + 1.0, 1.1918 + 1.0)
        px_x, px_y, deg = AS.device_density(AS.load())
        self.assertAlmostEqual(px_x, 6261 / 2.7321, places=6)
        self.assertEqual(round(px_x, 1), 2291.6)
        self.assertEqual(round(px_y, 1), 2291.7)
        self.assertEqual(round(deg, 1), 40.0)                   # 2291.6 x pi / 180 on the axis

    def test_axis_shift_by_hand(self):
        # Band centre on the eye axis (tan 0). ALVR eye UV: x from the temporal edge, y from the top (Shaders.metal);
        # shift = (t_lo - t_hi) / (t_lo + t_hi) / (1 - c).
        self.assertAlmostEqual((1.7321 - 1.0) / (1.7321 + 1.0), 0.2680, places=4)
        self.assertEqual(round(AS.axis_shift(1.7321, 1.0, 0.5), 3), 0.536)        # x: temporal 1.7321, nasal 1.0
        self.assertAlmostEqual(AS.axis_shift(1.7321, 1.0, 0.5), 0.2680 / 0.5, places=3)
        self.assertEqual(round(AS.axis_shift(1.0, 1.1918, 0.45), 3), -0.159)      # y: up 1.0, down 1.1918 (W32)
        self.assertAlmostEqual(AS.axis_shift(1.0, 1.1918, 0.45), (1.0 - 1.1918) / 2.1918 / 0.55, places=6)
        self.assertEqual(round(AS.axis_shift(1.1918, 1.0, 0.45), 3), 0.159)       # pre-W32 stream: up 1.1918, down 1.0
        self.assertEqual(AS.axis_shift(1.3, 1.3, 0.45), 0.0)
        self.assertEqual(AS.derive(AS.load(), 1.0, 'axis'), (0.5, 0.45, 3, 3, 0.536, -0.159))
        # the shift follows the tangents in the parameter file, not a literal
        p = AS.load()
        p['frustum_tan_LRDU'] = {'L': [1.7321, 1.0, 1.0, 1.1918], 'R': [1.0, 1.7321, 1.0, 1.1918]}
        self.assertEqual(AS.derive(p, 1.0, 'axis')[4:], (0.536, 0.159))

    def test_wider_exact_by_hand(self):
        p = AS.load()
        want = {1.0: (0.563, 0.618, 2.5, 2.5, 0.335, -0.168), 0.85: (0.662, 0.726, 2.5, 2.5, 0.37, -0.22),
                0.7: (0.805, 0.882, 2.5, 2.5, 0.485, -0.461)}
        for s, fv in want.items():
            self.assertEqual(AS.derive(p, s, 'wider'), fv)
        # s = 1 by hand: the field spans (tan 43 + tan 31) / 2.7321 = 0.5612 of the width and (tan 33 + tan 35) / 2.1918
        # = 0.6158 of the height; ALVR's 2r-px rounding at 3648/2912 widens them to 0.563/0.618. Centre fractions
        # (1.7321 - (tan 43 - tan 31) / 2) / 2.7321 and (1.0 - (tan 33 - tan 35) / 2) / 2.1918 give the shifts.
        t = lambda d: math.tan(math.radians(d))
        self.assertAlmostEqual((t(43) + t(31)) / 2.7321, 0.5612, places=4)
        self.assertAlmostEqual((t(33) + t(35)) / 2.1918, 0.6158, places=4)
        fx = (1.7321 - (t(43) - t(31)) / 2) / 2.7321
        fy = (1.0 - (t(33) - t(35)) / 2) / 2.1918
        self.assertEqual(round((fx - 0.5) / ((1 - 0.563) / 2), 3), 0.335)
        self.assertEqual(round((fy - 0.5) / ((1 - 0.618) / 2), 3), -0.168)

    def test_recommended_centre_by_hand(self):
        # Centre px/deg = render px over the |tan| span x pi/180 (1:1 band at the axis); min of horizontal and vertical.
        rec = AS.recommend(list(AS.candidates(AS.load())))
        self.assertEqual([(r['budget'], r['fov'], r['render']) for r in rec],
                         [('C', 'axis', (4176, 3334)), ('A', 'axis', (3648, 2912)), ('A', 'wider', (3008, 2402))])
        k = math.pi / 180
        for r, (w, h), want in zip(rec, ((4176, 3334), (3648, 2912), (3008, 2402)), (26.5, 23.2, 19.1)):
            hand = min(w / 2.7321 * k, h / 2.1918 * k)
            self.assertEqual(round(hand, 1), want)
            self.assertAlmostEqual(r['centre'], hand, places=2)
        # the render sizes from the budgets by hand: axis codes x at 0.5 + 0.5/3 = 2/3 (2784 / (2/3) = 4176, 2432 / (2/3)
        # = 3648); wider is height-bound at 0.618 + 0.382/2.5 = 0.7708 (1856 / 0.7708 = 2408 rows -> 3008x2402 after
        # ALVR's 32-px coded padding)
        self.assertEqual(round(2784 / (0.5 + 0.5 / 3)), 4176)
        self.assertEqual(round(2432 / (0.5 + 0.5 / 3)), 3648)
        self.assertEqual(round(1856 / (0.618 + 0.382 / 2.5)), 2408)

    def test_variants_derive_from_the_visible_field(self):
        p = AS.load()
        by = {(q['fov_scale'], q['name'].split('-')[1]): q['foveation'] for q in fm.parse_points(AS.points(p).splitlines())}
        self.assertEqual(by[(1.0, 'asrun')], (0.5, 0.45, 3.0, 3.0, 0.0, 0.0))
        # centred: band centre on the field centre (L eye x from the temporal edge, y from the top), at every fov scale
        for s in (1.0, 0.85, 0.7):
            cx, cy, rx, ry, shx, shy = by[(s, 'centred')]
            fx = (s * 1.7321 + (math.tan(math.radians(31)) - math.tan(math.radians(43))) / 2) / (s * 2.7321)
            fy = (s * 1.0 - (math.tan(math.radians(33)) - math.tan(math.radians(35))) / 2) / (s * 2.1918)
            self.assertAlmostEqual(shx, (fx - 0.5) / ((1 - cx) / 2), places=3)
            self.assertAlmostEqual(shy, (fy - 0.5) / ((1 - cy) / 2), places=3)
            cx, cy = by[(s, 'wider')][:2]          # wider: the band holds the whole field
            self.assertGreaterEqual(cx, (math.tan(math.radians(43)) + math.tan(math.radians(31))) / (s * 2.7321))
            self.assertGreaterEqual(cy, (math.tan(math.radians(33)) + math.tan(math.radians(35))) / (s * 2.1918))
        # a different (seal-off) field changes the variants without touching code
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
            q = json.loads(json.dumps(p))
            q['visible_field_deg'].update(nasal=40, temporal=55, up=40, down=45)
            json.dump(q, f)
        try:
            self.assertNotEqual(AS.derive(AS.load(f.name), 1.0, 'wider'), AS.derive(p, 1.0, 'wider'))
            self.assertGreater(AS.derive(AS.load(f.name), 1.0, 'wider')[0], AS.derive(p, 1.0, 'wider')[0])
        finally:
            os.unlink(f.name)


CROP_FIXTURE = os.path.join(HERE, '..', 'diag', 'fixtures', 'crop-fov.json')
CROP_EYES = 'L:1.0913,0.6371,0.7674,0.6371;R:0.6371,1.0913,0.7674,0.6371'   # model inset 15 rectangle + 2.5 deg, |tan| L,R,D,U


class CropTest(unittest.TestCase):
    """`crop` variant: the client's "Crop FOV to outline" (ALVRClient/CropFov.swift): the frame is the model lens's inset
    rectangle (device frustum edges moved in by inset_deg, R mirrored) widened by the margin, clamped to the device
    frustum, band centred on the eye axis."""
    def test_fixture_shared_with_swift(self):
        with open(CROP_FIXTURE) as f:
            fx = json.load(f)
        p = AS.load()
        self.assertEqual(fx['model'], p['crop']['model'])
        self.assertEqual(fx['model'], AS.lm.MODEL)
        self.assertEqual(fx['device_tan_LRDU'], {e: p['frustum_tan_LRDU'][e] for e in 'LR'})
        c = fx['center_size']
        self.assertEqual(fx['viewport'], p['frustum_tan_LRDU']['viewport'])
        for case in fx['cases']:
            want = case['expect']
            got = {e: AS.crop_tan(p, e, case['inset_deg'], case['margin_deg']) for e in 'LR'}
            for g, w in zip(got[case['eye']], want['sent_tan_LRDU']):
                self.assertAlmostEqual(g, w, delta=1e-4, msg=case['name'])
            shx, shy = AS.crop_shift(got, c)
            self.assertAlmostEqual(shx, want['center_shift'][0], delta=1e-3, msg=case['name'])
            self.assertAlmostEqual(shy, want['center_shift'][1], delta=1e-3, msg=case['name'])
            if 'pxdeg_centre' in want:
                l, r, d, u = got[case['eye']]
                w, h = want['render_px']
                self.assertAlmostEqual(min(w / (l + r), h / (d + u)) * math.pi / 180, want['pxdeg_centre'], delta=0.1, msg=case['name'])
            if 'one_to_one_px' in want:
                self.assertEqual(list(AS.one_to_one(p, got)), want['one_to_one_px'], msg=case['name'])

    def test_inset_margin_clamp_by_hand(self):
        t = lambda d: math.tan(math.radians(d))
        p = AS.load()
        T0 = math.degrees(math.atan(1.7321))        # L device: temporal 60.0007, nasal 45, up 45, down 50.0011
        D0 = math.degrees(math.atan(1.1918))
        # inset 15 margin 0: the inset rectangle, L temporal is left
        for g, w in zip(AS.crop_tan(p, 'L', 15, 0), (t(T0 - 15), t(30), t(D0 - 15), t(30))):
            self.assertAlmostEqual(g, w, places=9)
        # margin 2.5: each side 2.5 deg wider (47.5/32.5/37.5/32.5 for L, the left and bottom sides from the device edges 60.0007
        # and 50.0011 deg); R mirrored
        for g, w in zip(AS.crop_tan(p, 'L', 15, 2.5), (t(T0 - 12.5), t(32.5), t(D0 - 12.5), t(32.5))):
            self.assertAlmostEqual(g, w, places=9)
        for g, w in zip(AS.crop_tan(p, 'L', 15, 2.5), (1.091335, 0.637070, 0.767357, 0.637070)):
            self.assertAlmostEqual(g, w, places=5)
        for g, w in zip(AS.crop_tan(p, 'R', 15, 2.5), (0.637070, 1.091335, 0.767357, 0.637070)):
            self.assertAlmostEqual(g, w, places=5)
        # margin 2 is still available
        for g, w in zip(AS.crop_tan(p, 'L', 15, 2), (1.072395, 0.624869, 0.753584, 0.624869)):
            self.assertAlmostEqual(g, w, places=5)
        # inset 0 or 1 + margin 2: past the device frustum on every side -> the device's
        self.assertEqual(AS.crop_tan(p, 'L', 0, 2), [1.7321, 1.0, 1.1918, 1.0])
        self.assertEqual(AS.crop_tan(p, 'L', 1, 2), [1.7321, 1.0, 1.1918, 1.0])
        # inset 50: every edge stops at 1 deg, then + margin
        for g, w in zip(AS.crop_tan(p, 'L', 50, 2), (t(T0 - 48), t(3), t(3), t(3))):
            self.assertAlmostEqual(g, w, places=9)
        # defaults come from avp-field.json crop (inset 15, margin 2.5 = CropFov.defaultMarginDeg)
        self.assertEqual((p['crop']['inset_deg'], p['crop']['margin_deg']), (15, 2.5))
        self.assertEqual(AS.crop_tan(p, 'L'), AS.crop_tan(p, 'L', 15, 2.5))

    def test_crop_shift_by_hand(self):
        # band centre 0.5 + s c0 on the axis: s = (temporal / (temporal + nasal) - 0.5) / c0, y with up / (up + down)
        p = AS.load()
        fv = AS.derive(p, 1.0, 'crop')
        self.assertEqual(fv, (0.5, 0.45, 3, 3, 0.526, -0.169))
        self.assertAlmostEqual((1.091335 / (1.091335 + 0.637070) - 0.5) / 0.25, 0.526, places=3)
        self.assertAlmostEqual((0.637070 / (0.637070 + 0.767357) - 0.5) / 0.275, -0.169, places=3)
        # the device frustum gives the axis rows' shift
        dev = {e: p['frustum_tan_LRDU'][e] for e in 'LR'}
        self.assertEqual(tuple(round(v, 3) for v in AS.crop_shift(dev, (0.5, 0.45))), (0.536, -0.159))

    def test_crop_points_rows(self):
        p = AS.load()
        pts = {q['name']: q for q in fm.parse_points(AS.points(p).splitlines())}
        k = math.pi / 180
        # crop-C renders at the 1:1 size (3968x3232), crop-A at budget A's (3648x2912)
        for name, (w, h), budget, centre in (('a100-crop-C', (3968, 3232), (2784, 2240), 40.1),
                                             ('a100-crop-A', (3648, 2912), (2432, 1856), 36.2)):
            q = pts[name]
            self.assertEqual((q['fov_scale'], q['foveation'], q['eye_tangents'], q['bitrate_mbps'], q['fps'], q['flag']),
                             (1.0, (0.5, 0.45, 3.0, 3.0, 0.526, -0.169), CROP_EYES, 100.0, 90.0, 'dump'))
            self.assertAlmostEqual(q['render_scale'], w / 3648, places=4)
            if name == 'a100-crop-C':
                self.assertEqual(q['render_scale'], 1.0877)         # 3968 / 3648 = 1.087719
            ax, ay = AS.axes_for(q['foveation'], w, h)
            self.assertLessEqual(ax['coded'], budget[0])
            self.assertLessEqual(ay['coded'], budget[1])
            # centre px/deg by hand: render px over the cropped |tan| span (h binds), vs the frustum's at the same render
            hand = min(w / (1.0913 + 0.6371), h / (0.7674 + 0.6371)) * k
            self.assertEqual(round(hand, 1), centre)
            row = AS.crop_rows(p)[name]
            self.assertAlmostEqual(row['centre'], hand, places=2)
            self.assertAlmostEqual(row['frustum_centre'], min(w / 2.7321, h / 2.1918) * k, places=2)
        text = AS.points(p)
        self.assertIn('# a100-crop-C: render 3968x3232; predicted centre 40.1 px/deg (frustum 25.3 at the same render, x1.58 h / x1.56 v)', text)
        self.assertIn('# a100-crop-A: render 3648x2912; predicted centre 36.2 px/deg (frustum 23.2 at the same render, x1.58 h / x1.56 v)', text)

    def test_one_to_one_by_hand(self):
        # grid density 6261 / 2.7321 = 2291.64 and 5023 / 2.1918 = 2291.72 px per tangent unit; L frame 1.728406 x 1.404428
        p = AS.load()
        dx, dy = 6261 / 2.7321, 5023 / 2.1918
        self.assertAlmostEqual(dx, 2291.64, places=2)
        self.assertAlmostEqual(dx * 1.728406, 3960.89, places=1)
        self.assertAlmostEqual(dy * 1.404428, 3218.56, places=1)
        self.assertEqual(AS.one_to_one(p), (3968, 3232))        # 3960.89 -> 3968, 3218.56 -> 3232 (multiples of 32)
        self.assertEqual([AS.round_up_32(v) for v in (1, 32, 33, 3968, 3968.5)], [32, 32, 64, 3968, 4000])
        self.assertAlmostEqual(3968 / 3648, 1.087719, places=6)


class CropBandTest(unittest.TestCase):
    """`a100-crop-T`: the crop-C frame (inset 15 + 2.5 deg, render 3968x3232, the 1:1 size) with the full-detail band flush with the nasal
    edge and reaching 30 deg temporal, 25 deg up, 30 deg down (avp-field.json crop.band_T)."""
    def test_band_by_hand(self):
        t = lambda d: math.tan(math.radians(d))
        p = AS.load()
        self.assertEqual(p['crop']['band_T'], {'temporal_deg': 30, 'up_deg': 25, 'down_deg': 30})
        # L frame |tan| temporal 1.0913, nasal 0.6371, up 0.6371, down 0.7674; x spans tan30 + 0.6371, y tan25 + tan30
        cx = (t(30) + 0.6371) / (1.0913 + 0.6371)
        cy = (t(25) + t(30)) / (0.6371 + 0.7674)
        self.assertAlmostEqual(cx, 0.7026, places=4)
        self.assertAlmostEqual(cy, 0.7431, places=4)
        # band centre fraction across the frame, from the temporal edge / from the top; s = (f - 0.5) / ((1 - c) / 2)
        fx = ((1.0913 - t(30)) / 1.7284 + 1) / 2
        fy = ((0.6371 - t(25)) / 1.4045 + (0.6371 + t(30)) / 1.4045) / 2
        sx, sy = (fx - 0.5) / ((1 - cx) / 2), (fy - 0.5) / ((1 - cy) / 2)
        self.assertAlmostEqual(sx, 1.0, places=2)           # flush with the nasal edge
        self.assertAlmostEqual(sy, -0.053, places=3)
        fv = AS.band_fv(AS.crop_eyes(p), p['crop']['band_T'], p['centred']['edge_ratio'])
        self.assertAlmostEqual(fv[0], cx, places=3)
        self.assertAlmostEqual(fv[1], cy, places=3)
        self.assertEqual(fv[2:4], (3, 3))
        self.assertAlmostEqual(fv[4], sx, places=2)
        self.assertAlmostEqual(fv[5], sy, places=2)

    def test_points_row(self):
        p = AS.load()
        pts = {q['name']: q for q in fm.parse_points(AS.points(p).splitlines())}
        q, c = pts['a100-crop-T'], pts['a100-crop-C']
        self.assertEqual((q['fov_scale'], q['render_scale'], q['eye_tangents'], q['bitrate_mbps'], q['fps']),
                         (c['fov_scale'], c['render_scale'], c['eye_tangents'], c['bitrate_mbps'], c['fps']))
        self.assertAlmostEqual(q['render_scale'], 3968 / 3648, places=4)
        cx, cy, rx, ry, shx, shy = q['foveation']
        self.assertEqual((rx, ry), (3.0, 3.0))
        self.assertAlmostEqual(cx, 0.7026, places=3)
        self.assertAlmostEqual(cy, 0.7431, places=3)
        self.assertAlmostEqual(shx, 1.0, places=2)
        self.assertAlmostEqual(shy, -0.053, places=3)
        text = AS.points(p)
        self.assertIn('# a100-crop-T: render 3968x3232; predicted centre 40.1 px/deg (frustum 25.3 at the same render, x1.58 h / x1.56 v); '
                      'coded 3200x2688 vs budget C 2784x2240', text)
        # the band keeps the 1:1 density on the axis: same centre px/deg as crop-C (render and frame are the same)
        rows = AS.crop_rows(p)
        self.assertAlmostEqual(rows['a100-crop-T']['centre'], rows['a100-crop-C']['centre'], places=2)
        self.assertEqual(rows['a100-crop-T']['render'], rows['a100-crop-C']['render'])


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.p = parse('a\t0.6\t1.03\t0.6,0.6,2.5,2.5,0.536,-0.159\t500\t90\tvideo.q=2\n')[0]

    def test_render_size(self):
        self.assertEqual(fm.render_size(1.0), (3648, 2912))
        self.assertEqual(fm.render_size(1.03), (3757, 2999))

    def test_session_sets(self):
        s = fm.session_sets(self.p)
        self.assertIn('video.transcoding_view_resolution.Absolute.width=3757', s)
        self.assertIn('video.transcoding_view_resolution.Absolute.height.content=2999', s)
        self.assertIn('video.emulated_headset_view_resolution.Absolute.width=3757', s)
        self.assertIn('video.emulated_headset_view_resolution.Absolute.height.content=2999', s)
        self.assertIn('video.foveated_encoding.enabled=true', s)
        self.assertIn('video.foveated_encoding.content.center_size_x=0.6', s)
        self.assertIn('video.foveated_encoding.content.center_size_y=0.6', s)
        self.assertIn('video.foveated_encoding.content.edge_ratio_x=2.5', s)
        self.assertIn('video.foveated_encoding.content.edge_ratio_y=2.5', s)
        self.assertIn('video.foveated_encoding.content.center_shift_x=0.536', s)
        self.assertIn('video.foveated_encoding.content.center_shift_y=-0.159', s)
        self.assertIn('video.bitrate.mode.variant="ConstantMbps"', s)
        self.assertIn('video.bitrate.mode.ConstantMbps=500', s)
        self.assertIn('video.transcoding_view_resolution.variant="Absolute"', s)
        self.assertIn('video.preferred_fps=90.0', s)
        self.assertEqual(s[-1], 'video.q=2')

    def test_foveation_off(self):
        p = parse('a\t1\t1\toff\t100\t60\n')[0]
        s = fm.session_sets(p)
        self.assertIn('video.foveated_encoding.enabled=false', s)
        self.assertFalse([x for x in s if 'center_size' in x])

    def test_client_settings(self):
        c = fm.client_settings(self.p)
        self.assertEqual(c, {'fovRenderScale': 0.6, 'streamFullImmersion': True, 'captureDiagnosticFrames': True})

    def test_overlay_args(self):
        self.assertEqual(fm.overlay_args(self.p), ['--fov-scale', '0.6', '--render', '3757x2999',
                                                   '--foveation', '0.6,0.6,2.5,2.5,0.536,-0.159'])
        self.assertEqual(fm.overlay_args(parse('a\t1\t1\toff\t100\t60\n')[0])[-2:], ['--foveation', 'off'])

    def test_merge_client_settings_keeps_unrelated(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'globalsettings.data')
            with open(path, 'w') as f:
                json.dump({'hdrPQ': True, 'fovRenderScale': 1.0}, f)
            out = fm.merge_client_settings(path, {'fovRenderScale': 0.7})
            self.assertEqual(out['hdrPQ'], True)
            self.assertEqual(fm.merge_client_settings(path, {})['fovRenderScale'], 0.7)
            with open(path, 'w') as f:
                f.write('garbage')
            self.assertEqual(fm.merge_client_settings(path, {'a': 1}), {'a': 1})


class DumpTest(unittest.TestCase):
    def test_classify(self):
        names = ['chart_L.png', 'chart_R.png', 'encoder_input_L.png', 'encoder_input_R.png', 'meta.json', 'notes.txt']
        got = fm.classify_dump(names)
        self.assertEqual(got, [('render', 'L', 'chart_L.png'), ('render', 'R', 'chart_R.png'),
                               ('encoded', 'L', 'encoder_input_L.png'), ('encoded', 'R', 'encoder_input_R.png')])

    def test_classify_words(self):
        got = fm.classify_dump(['eye-left-render.png', 'eye-right-render.png', 'foveated-left.png', 'foveated-right.png'])
        self.assertEqual([(m, e) for m, e, _ in got], [('render', 'L'), ('render', 'R'), ('encoded', 'L'), ('encoded', 'R')])

    def test_unknown_eye_skipped(self):
        self.assertEqual(fm.classify_dump(['mystery.png']), [])


def graph(**kw):
    base = {'encoder_s': 0.009, 'bitrate_bps': 500e6, 'client_fps': 90.0, 'decoder_s': 0.005}
    base.update(kw)
    return json.dumps({'event_type': {'id': 'GraphStatistics', 'data': base}})


class StatsTest(unittest.TestCase):
    def test_stats(self):
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, 'events.jsonl')
            with open(ev, 'w') as f:
                for e in (0.008, 0.009, 0.020):
                    f.write(graph(encoder_s=e) + '\n')
                f.write('not json\n')
                f.write(json.dumps({'event_type': {'id': 'Other', 'data': {}}}) + '\n')
            con = os.path.join(d, 'console.log')
            with open(con, 'w') as f:
                f.write('noise\n')
                for fps, dec in ((88.0, 6.0), (90.0, 7.0), (89.0, 8.0)):
                    f.write('ALVRSTATS ' + json.dumps({'presented_fps': fps, 'decode_ms_mean': dec, 'type': 'stats'}) + '\n')
            s = fm.stats(ev, con)
            self.assertAlmostEqual(s['encode_ms'], 9.0)
            self.assertAlmostEqual(s['bitrate_mbps'], 500.0)
            self.assertEqual(s['client_fps'], 89.0)
            self.assertEqual(s['decode_ms'], 7.0)
            self.assertEqual(s['graph_n'], 3)

    def test_encode_p95_and_over_budget(self):
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, 'events.jsonl')
            with open(ev, 'w') as f:   # 20 samples: 18 x 9 ms, 2 x 20 ms
                for e in [0.009] * 18 + [0.020] * 2:
                    f.write(graph(encoder_s=e) + '\n')
            s = fm.stats(ev, '/nonexistent')
            self.assertAlmostEqual(s['encode_ms'], 9.0)
            self.assertAlmostEqual(s['encode_ms_p95'], 20.0)       # nearest rank: the 19th of 20
            self.assertAlmostEqual(s['encode_over_budget'], 0.1)   # > 1000/90 ms
            with open(ev, 'w') as f:   # exactly on the budget is not over it
                f.write(graph(encoder_s=1 / 90) + '\n')
            self.assertEqual(fm.stats(ev, '/nonexistent')['encode_over_budget'], 0.0)

    def test_missing_files(self):
        s = fm.stats('/nonexistent/a', '/nonexistent/b')
        self.assertIsNone(s['encode_ms'])
        self.assertIsNone(s['encode_ms_p95'])
        self.assertIsNone(s['encode_over_budget'])
        self.assertIsNone(s['client_fps'])


OVERLAY = {'summary': {'verdict': 'PASS', 'median_abs_residual_deg': 0.04, 'max_abs_residual_deg': 0.31,
                       'stream_extent_deg': {'left': {'measured': 80.1, 'predicted': 80.0},
                                             'right': {'measured': 44.9, 'predicted': 45.0}},
                       'implied_px_per_deg': {'band': 38.5, 'edge': 12.0},
                       'predicted_px_per_deg': {'band': 38.8, 'edge': 12.1}}, 'lines': []}


class RowTest(unittest.TestCase):
    def make(self, d, overlay=OVERLAY, with_stats=True):
        os.makedirs(os.path.join(d, 'overlay'))
        if overlay is not None:
            wj(os.path.join(d, 'overlay', 'drawable.json'), overlay)
        wj(os.path.join(d, 'overlay', 'render-L.json'), {'verdict': 'FAIL', 'summary': {'verdict': 'FAIL'}})
        if with_stats:
            wj(os.path.join(d, 'stats.json'), {'encode_ms': 9.0, 'bitrate_mbps': 498.4, 'client_fps': 89.5, 'decode_ms': 7.0,
                                               'encode_ms_p95': 12.345, 'encode_over_budget': 0.0625})

    def test_row(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d)
            cols = fm.summary_row('a', d).split('\t')
            self.assertEqual(len(cols), len(fm.SUMMARY_COLUMNS))
            r = dict(zip(fm.SUMMARY_COLUMNS, cols))
            self.assertEqual(r['name'], 'a')
            self.assertEqual(r['verdict'], 'PASS')
            self.assertEqual(r['median_deg'], '0.040')
            self.assertEqual(r['max_deg'], '0.310')
            self.assertEqual(r['extent_err_deg'], '0.100')
            self.assertEqual(r['centre_px_deg'], '38.5/38.8')
            self.assertEqual((r['fps'], r['bitrate_mbps'], r['encode_ms']), ('89.5', '498.4', '9.00'))
            self.assertEqual(r['verdict_render'], 'FAIL')
            self.assertEqual(r['verdict_encoded'], 'n/a')
            self.assertEqual((r['encode_ms_p95'], r['encode_over_budget']), ('12.35', '0.062'))
            # appended: the old columns keep their place
            self.assertEqual(fm.SUMMARY_COLUMNS[-3:], ['notes', 'encode_ms_p95', 'encode_over_budget'])

    def test_no_overlay_and_error_marker(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, overlay=None)
            r = dict(zip(fm.SUMMARY_COLUMNS, fm.summary_row('a', d).split('\t')))
            self.assertEqual(r['verdict'], 'NO_OVERLAY')
            with open(os.path.join(d, 'ERROR'), 'w') as f:
                f.write('capture: none appeared')
            r = dict(zip(fm.SUMMARY_COLUMNS, fm.summary_row('a', d).split('\t')))
            self.assertEqual(r['verdict'], 'ERROR')
            self.assertEqual(r['notes'], 'capture: none appeared')

    def test_unknown_shape_is_na_not_crash(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, overlay={'summary': {'verdict': 'PASS'}}, with_stats=False)
            r = dict(zip(fm.SUMMARY_COLUMNS, fm.summary_row('a', d).split('\t')))
            self.assertEqual((r['median_deg'], r['extent_err_deg'], r['centre_px_deg'], r['fps']), ('n/a',) * 4)


class MiscTest(unittest.TestCase):
    def test_json_get(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'x.json')
            wj(p, {'result': {'report': '/a/b'}, 'ok': True})
            self.assertEqual(fm.json_get(p, 'result.report'), '/a/b')
            self.assertEqual(fm.json_get(p, 'result.nothing'), '')


if __name__ == '__main__':
    unittest.main()
