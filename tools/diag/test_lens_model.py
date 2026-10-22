"""Boundary dots model lens (lens_model.py): the inset rectangle, the per-quadrant superellipse and the shared fixture
with tests/swift/BoundaryOutlineTests.swift (both supported Pythons)."""
import importlib.util
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('lens_model', Path(__file__).with_name('lens_model.py'))
lm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lm)

FIXTURE = Path(__file__).with_name('fixtures') / 'lens-model.json'
EXACT = (math.tan(math.radians(60)), 1.0, math.tan(math.radians(50)), 1.0)     # L 60/45/45/50 temporal/nasal/up/down


def t(d):
    return math.tan(math.radians(d))


class LensModelTests(unittest.TestCase):
    def test_inset_rect(self):
        r = lm.inset_rect('L', 15, EXACT)
        for k, want in (('temporal', 45), ('nasal', 30), ('up', 30), ('down', 35)):
            self.assertAlmostEqual(r[k], want, places=9)
        for k, want in (('a_t', t(45)), ('a_n', t(30)), ('b_u', t(30)), ('b_d', t(35))):
            self.assertAlmostEqual(r[k], want, places=9)
        device = lm.inset_rect('L', 15)
        for k, want in (('temporal', 45), ('nasal', 30), ('up', 30), ('down', 35)):
            self.assertAlmostEqual(device[k], want, delta=2e-3)
        self.assertEqual(lm.inset_rect('R', 15), device, 'R mirrored')
        self.assertEqual(lm.box_lrud('L', device), (device['a_t'], device['a_n'], device['b_u'], device['b_d']))
        self.assertEqual(lm.box_lrud('R', device), (device['a_n'], device['a_t'], device['b_u'], device['b_d']))
        deep = lm.inset_rect('L', 50, EXACT)
        self.assertEqual([round(deep[k], 9) for k in ('temporal', 'nasal', 'up', 'down')], [10, 1, 1, 1], 'edges >= 1 deg')

    def test_lens_points(self):
        pts = lm.lens_points('L', 15, tan_lrdu=EXACT)
        self.assertEqual(len(pts), 480)
        for i, want in ((0, (1, 0)), (120, (0, t(30))), (240, (-t(30), 0)), (360, (0, -t(35)))):
            self.assertAlmostEqual(pts[i][0], want[0], places=9)
            self.assertAlmostEqual(pts[i][1], want[1], places=9)
        x, y = pts[60]                                          # phi 45, upper temporal, n = 3
        self.assertAlmostEqual(x, 0.544452, places=6)
        self.assertAlmostEqual(y, 0.544452, places=6)
        self.assertTrue(x < 1 and y < t(30), 'inside the rectangle')
        self.assertGreater((x / 1) ** 2 + (y / t(30)) ** 2, 1, 'outside the inscribed ellipse')
        self.assertEqual([lm.exponent(-0.6, 0.8), lm.exponent(0.6, 0.8), lm.exponent(-0.6, -0.8), lm.exponent(0.6, -0.8)],
                         [2, 3, 1.5, 4])
        r = lm.inset_rect('L', 15)
        xs = [p[0] for p in lm.lens_points('L', 15)]
        ys = [p[1] for p in lm.lens_points('L', 15)]
        for got, want in ((max(xs), r['a_t']), (-min(xs), r['a_n']), (max(ys), r['b_u']), (-min(ys), r['b_d'])):
            self.assertAlmostEqual(got, want, places=9)
        self.assertEqual(lm.head('L', (1, 2)), (-1, 2))
        self.assertEqual(lm.head('R', (1, 2)), (1, 2))
        self.assertAlmostEqual(lm.ecc_deg('L', 180, 15), r['temporal'], places=9)
        self.assertAlmostEqual(lm.ecc_deg('R', 0, 15), r['temporal'], places=9)
        self.assertAlmostEqual(lm.ecc_deg('L', 90, 15), 30, places=9)
        self.assertLess(lm.area_fraction('L', 20), lm.area_fraction('L', 15))

    def test_fixture_shared_with_swift(self):
        fx = json.loads(FIXTURE.read_text())
        self.assertEqual(fx['model'], lm.MODEL)
        self.assertEqual(fx['count'], lm.POINT_COUNT)
        self.assertEqual(len(fx['cases']), 4)
        for case in fx['cases']:
            eye, inset, name = case['eye'], case['inset_deg'], case['name']
            r = lm.inset_rect(eye, inset)
            for k, v in list(case['rect_deg'].items()) + list(case['rect_tan'].items()):
                self.assertAlmostEqual(r[k], v, delta=1e-6, msg=name)
            for got, want in zip(lm.box_lrud(eye, r), case['box_tan_LRUD']):
                self.assertAlmostEqual(got, want, delta=1e-6, msg=name)
            self.assertEqual(len(case['points']), 24)
            for p in case['points']:
                e = lm.point(r, p['phi_deg'])
                for got, want in zip(e + lm.head(eye, e), p['eye'] + p['head']):
                    self.assertAlmostEqual(got, want, delta=1e-6, msg='%s phi %s' % (name, p['phi_deg']))
            self.assertAlmostEqual(lm.area_fraction(eye, inset), case['area_fraction'], delta=1e-6, msg=name)
        self.assertEqual(json.loads(lm.fixture_text(lm.fixture())), fx, 'fixture is what lens_model.py writes')

    def test_svg(self):
        text = lm.svg()
        self.assertTrue(text.startswith('<svg'))
        self.assertEqual(text.count('<polygon'), 6, 'per eye: frustum, inset rect, lens')
        self.assertEqual(text.count('<polyline'), 4, 'per eye: two axes')
        self.assertEqual(text.count('<circle'), 2, 'per eye: centre circle')
        self.assertIn('L inset 15: temporal 45.0 nasal 30.0 up 30.0 down 35.0 deg', text)
        with tempfile.TemporaryDirectory() as directory:
            lm.REPO = Path(directory)
            try:
                lm.main(['lens_model.py', 'svg'])
            finally:
                lm.REPO = Path(__file__).resolve().parent.parent.parent
            self.assertEqual((Path(directory) / 'build' / 'lens-model.svg').read_text(), text)


if __name__ == '__main__':
    unittest.main()
