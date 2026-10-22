"""Boundary dots outline slider: geometry and report contract (both supported Pythons)."""
import importlib.util
import math
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('outline_report', Path(__file__).with_name('diag-report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

LEFT = (1.7321, 1.0, 1.1918, 1.0)
RIGHT = (1.0, 1.7321, 1.1918, 1.0)
LOG = '''DIAG dots_session t_ms=1 event=begin radius_m=10.000 pose=device angles=projected_tangent
DIAG dots t_ms=2 eye=L action=confirm ray_deg=0.000 ecc_deg=32.500 yaw_deg=32.500 pitch_deg=0.000 via=step
DIAG dots t_ms=3 eye=L action=confirm ray_deg=180.000 ecc_deg=40.000 yaw_deg=-40.000 pitch_deg=0.000 via=step
DIAG dots t_ms=4 eye=L action=confirm ray_deg=7.500 ecc_deg=30.000 yaw_deg=29.799 pitch_deg=3.857 via=step
DIAG dots_outline t_ms=5 eye=L inset_deg=20.000 nasal_deg=25.000 temporal_deg=40.001 up_deg=25.000 down_deg=30.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000
DIAG dots_outline t_ms=6 eye=L inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000
DIAG dots_outline t_ms=7 eye=R inset_deg=30.000 nasal_deg=15.000 temporal_deg=30.001 up_deg=15.000 down_deg=20.001 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000
'''


class BoundaryOutlineReportTests(unittest.TestCase):
    @staticmethod
    def records(text):
        return [report.parse_line(line, 'diag-outline.log:{}'.format(i))
                for i, line in enumerate(text.splitlines(), 1)]

    def test_outline_geometry_matches_the_app(self):
        self.assertAlmostEqual(report.outline_edge_ecc(0, LEFT), 45)
        self.assertAlmostEqual(report.outline_edge_ecc(180, LEFT), math.degrees(math.atan(1.7321)))
        self.assertAlmostEqual(report.outline_edge_ecc(270, LEFT), math.degrees(math.atan(1.1918)))
        points = report.outline_points(0, LEFT)
        rays = [ray for ray, _ in points]
        self.assertEqual(rays, sorted(set(rays)))
        self.assertTrue(set(range(0, 360, 5)) <= set(rays))
        tangents = [(math.tan(math.radians(e)) * math.cos(math.radians(r)),
                     math.tan(math.radians(e)) * math.sin(math.radians(r))) for r, e in points]
        for corner in [(1, 1), (-1.7321, 1), (-1.7321, -1.1918), (1, -1.1918)]:
            self.assertTrue(any(math.hypot(x - corner[0], y - corner[1]) < 1e-9 for x, y in tangents), corner)
        self.assertAlmostEqual(report.outline_area_frac(0, LEFT), 1)
        self.assertAlmostEqual(report.outline_area_frac(0, RIGHT), 1)
        limits = report.outline_limits('L', 15, LEFT)
        for got, want in zip(limits, (30, 45, 30, 35)):
            self.assertAlmostEqual(got, want, places=2)
        self.assertEqual(report.outline_limits('R', 15, RIGHT), limits)
        self.assertEqual(report.outline_limits('L', 30, (0.2, 0.2, 0.2, 0.2)), (0, 0, 0, 0))
        self.assertTrue(all(e == 0 for _, e in report.outline_points(30, (0.2, 0.2, 0.2, 0.2))))
        self.assertAlmostEqual(report.outline_ecc(0, 15, LEFT), 30)
        self.assertLess(report.outline_area_frac(20, LEFT), report.outline_area_frac(15, LEFT))
        # Hand check, L device frustum (l=1.7321, r=1, b=1.1918, t=1) at inset 15. Vertices: rays every 5 deg plus
        # the corner rays 45, 150.0007, 214.5306, 309.9989; radius rho = tan(edge_ecc - 15), e.g. ray 0: tan(45-15)=0.57735.
        # Polygon area by fan sectors, 1/2 * sum(rho_i * rho_i+1 * sin(dphi_i)), grouped by the quadrant of phi_i:
        #   [0,90) 0.341113 + [90,180) 0.576945 + [180,270) 0.685372 + [270,360) 0.409327 = 2.012757
        # Frustum area (l+r)(b+t) = 2.7321 * 2.1918 = 5.988217; fraction 2.012757 / 5.988217 = 0.336120.
        self.assertAlmostEqual(report.outline_area_frac(15, LEFT), 2.012757 / 5.988217, places=6)
        self.assertAlmostEqual(report.outline_area_frac(15, LEFT), 0.336120, places=6)

    def test_outline_rows_with_area_and_dot_deviation(self):
        rows = report.dots_outlines(self.records(LOG))
        self.assertEqual([(r['eye'], r['inset_deg']) for r in rows], [('L', 20), ('L', 15), ('R', 30)])
        left = rows[1]
        self.assertEqual((left['nasal_deg'], left['temporal_deg'], left['up_deg'], left['down_deg']),
                         (30, 45.001, 30, 35.001))
        self.assertAlmostEqual(left['area_frac'], report.outline_area_frac(15, LEFT))
        self.assertEqual(left['tangent_source'], 'device_default')
        self.assertEqual(left['source'], 'diag-outline.log:6')
        deviations = {d['ray_deg']: d for d in left['deviations']}
        self.assertEqual(sorted(deviations), [0, 7.5, 180])
        self.assertAlmostEqual(deviations[0]['deviation_deg'], 2.5)
        self.assertAlmostEqual(deviations[180]['deviation_deg'], 40 - (math.degrees(math.atan(1.7321)) - 15))
        self.assertAlmostEqual(left['max_dev_deg'], abs(deviations[180]['deviation_deg']))
        self.assertEqual(left['max_dev_ray'], 180)
        self.assertEqual(rows[2]['deviations'], [], 'no R confirmations')
        self.assertIsNone(rows[2]['max_dev_deg'])

    def test_missing_tangents_fall_back_to_device_defaults_and_bad_lines_are_skipped(self):
        rows = report.dots_outlines(self.records('''DIAG dots_outline t_ms=1 eye=R inset_deg=15.000 tangent_source=device_default
DIAG dots_outline t_ms=2 eye=Both inset_deg=15.000
DIAG dots_outline t_ms=3 eye=L inset_deg=nan
DIAG dots_outline t_ms=4 eye=L inset_deg=15 tangents=0,1,1,1'''))
        self.assertEqual([(r['eye'], r['tangents']) for r in rows], [('R', RIGHT), ('L', LEFT)])
        self.assertEqual(rows[1]['tangent_note'], 'invalid tangents: device default')
        self.assertAlmostEqual(rows[0]['area_frac'], report.outline_area_frac(15, RIGHT))

    def test_report_section_has_a_table_per_eye(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'diag-outline.log').write_text(LOG)
            output = report.generate(directory)
        for text in ['Outline eye=L', 'Outline eye=R', 'inset_deg', 'nasal_deg', 'temporal_deg', 'up_deg',
                     'down_deg', 'area_frac', 'max_dev_deg', 'deviation_deg', 'diag-outline.log:6', 'dots_outline']:
            self.assertIn(text, output)
        unknown = output.split('## Eye badges')[1]
        self.assertNotIn('dots_outline', unknown, 'dots_outline is a known topic')


LENS_LOG = LOG + '''DIAG dots_outline t_ms=8 eye=L shape=lens offset_deg=5.000 nasal_deg=42.500 temporal_deg=45.000 up_deg=35.000 down_deg=37.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays=0:42.5,15:40,30:40,45:40,60:35,75:35,90:35,105:37.5,120:37.5,135:40,150:42.5,165:42.5,180:45,195:47.5,210:45,225:45,240:35,255:37.5,270:37.5,285:35,300:37.5,315:37.5,330:37.5,345:42.5
DIAG dots_outline t_ms=9 eye=R shape=lens offset_deg=0.000 nasal_deg=37.500 temporal_deg=40.000 up_deg=30.000 down_deg=32.500 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000 reference=device-20261021 rays=0:40,90:30,180:37.5,270:32.5
DIAG dots_outline t_ms=10 eye=L shape=lens offset_deg=0.000 rays=0:nan
DIAG dots_outline t_ms=11 eye=L shape=lens offset_deg=0.000
'''


class LensOutlineReportTests(unittest.TestCase):
    records = staticmethod(BoundaryOutlineReportTests.records)

    def test_lens_rays_interpolate_linearly_in_eccentricity(self):
        rays = report.outline_rays('''0:37.5,15:35,30:35,45:35,60:30,75:30,90:30,105:32.5,120:32.5,135:35,150:37.5,165:37.5,180:40,195:42.5,210:40,225:40,240:30,255:32.5,270:32.5,285:30,300:32.5,315:32.5,330:32.5,345:37.5''')
        self.assertEqual(len(rays), 24)
        self.assertEqual(rays[0], 37.5)
        self.assertAlmostEqual(report.lens_ecc(7.5, rays), 36.25)
        self.assertAlmostEqual(report.lens_ecc(185, rays), 40 + 2.5 / 3)
        self.assertAlmostEqual(report.lens_ecc(240, rays), 30)
        sparse = {0: 30, 90: 40}
        self.assertAlmostEqual(report.lens_ecc(45, sparse), 35)
        self.assertAlmostEqual(report.lens_ecc(270, sparse), 40 - 10 * 2 / 3)
        self.assertIsNone(report.outline_rays('0:nan'))
        self.assertIsNone(report.outline_rays('0:30,0:31'))
        self.assertIsNone(report.outline_rays(''))
        # Lens L offset 0, by hand: 72 sectors of 5 deg, rho = tan(ecc) with ecc linear between the 15-deg rays,
        # area = 1/2 * sin(5 deg) * sum(rho_i * rho_i+1) = 1.533787; frustum (1.7321+1)(1.1918+1) = 5.988217;
        # fraction 1.533787 / 5.988217 = 0.256134 (offset +5: 2.206352 / 5.988217 = 0.368449).
        self.assertAlmostEqual(report.lens_area_frac(rays, LEFT), 1.533787 / 5.988217, places=6)
        plus5 = {ray: ecc + 5 for ray, ecc in rays.items()}
        self.assertAlmostEqual(report.lens_area_frac(plus5, LEFT), 0.368449, places=6)

    def test_lens_rows_limits_rays_area_and_deviation(self):
        rows = report.dots_outlines(self.records(LENS_LOG))
        self.assertEqual([(r['eye'], r['shape']) for r in rows],
                         [('L', 'rect'), ('L', 'rect'), ('R', 'rect'), ('L', 'lens'), ('R', 'lens')], 'bad lens lines skipped')
        lens = rows[3]
        self.assertEqual(lens['offset_deg'], 5)
        self.assertIsNone(lens['inset_deg'])
        self.assertEqual((lens['nasal_deg'], lens['temporal_deg'], lens['up_deg'], lens['down_deg']), (42.5, 45, 35, 37.5))
        self.assertEqual(len(lens['rays']), 24)
        self.assertEqual(lens['rays'][195], 47.5)
        self.assertAlmostEqual(lens['area_frac'], 0.368449, places=6)
        deviations = {d['ray_deg']: d['deviation_deg'] for d in lens['deviations']}
        self.assertAlmostEqual(deviations[0], 32.5 - 42.5)
        self.assertAlmostEqual(deviations[7.5], 30 - (36.25 + 5))
        self.assertAlmostEqual(deviations[180], 40 - 45)
        self.assertAlmostEqual(lens['max_dev_deg'], 11.25)
        self.assertEqual(lens['max_dev_ray'], 7.5)
        self.assertEqual(sorted(rows[4]['rays']), [0, 90, 180, 270], 'sparse logged rays are kept as logged')

    def test_report_lists_the_lens_rays(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'diag-outline.log').write_text(LENS_LOG)
            output = report.generate(directory)
        for text in ['shape', 'offset_deg', 'lens', 'Per-ray outline', 'outline_ecc_deg', '47.5', 'diag-outline.log:8']:
            self.assertIn(text, output)


FIXTURE = Path(__file__).with_name('fixtures') / 'projection-overlay.json'
L_RAYS = ('0:37.5,15:35,30:35,45:35,60:30,75:30,90:30,105:32.5,120:32.5,135:35,150:37.5,165:37.5,180:40,195:42.5,'
          '210:40,225:40,240:30,255:32.5,270:32.5,285:30,300:32.5,315:32.5,330:32.5,345:37.5')
PROJECTION = ('bbox_deg=41.512,37.500,31.607,32.500 bbox_tan=0.8851,0.7673,0.6154,0.6371 fov_source=a100-axis-C fov_live=no '
              'foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 '
              'pxdeg_frustum=26.541 pxdeg_bbox=44.108')
PROJECTION_LOG = '''DIAG dots_session t_ms=1 event=begin radius_m=10.000 pose=device angles=projected_tangent
DIAG dots_outline t_ms=2 eye=L shape=lens offset_deg=0.000 nasal_deg=37.500 temporal_deg=40.000 up_deg=30.000 down_deg=32.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays={rays} {projection}
DIAG dots_outline t_ms=3 eye=L shape=rect inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000
DIAG dots_session t_ms=4 event=begin radius_m=10.000 pose=device angles=projected_tangent
DIAG dots_outline t_ms=5 eye=L shape=lens offset_deg=0.000 nasal_deg=37.500 temporal_deg=40.000 up_deg=30.000 down_deg=32.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays={rays} {projection}
DIAG dots_outline t_ms=6 eye=L shape=lens offset_deg=0.000 nasal_deg=37.500 temporal_deg=40.000 up_deg=30.000 down_deg=32.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays={rays} {wrong}
'''.format(rays=L_RAYS, projection=PROJECTION, wrong=PROJECTION.replace('pxdeg_bbox=44.108', 'pxdeg_bbox=45.000'))


class ProjectionReportTests(unittest.TestCase):
    records = staticmethod(BoundaryOutlineReportTests.records)

    def test_fixture_matches_the_swift_overlay(self):
        """Same inputs and expected numbers as tests/swift/ProjectionOverlayTests.swift (tan 0.001, px/deg 0.1)."""
        import json
        cases = json.loads(FIXTURE.read_text())['cases']
        self.assertEqual(len(cases), 3)
        for case in cases:
            tangents, want = tuple(case['tangents']), case['expect']
            if case['shape'] == 'lens':
                rays = report.outline_rays(case['rays'])
                points = [(r, report.lens_ecc(r, rays)) for r in range(0, 360, 5)]
            else:
                points = report.outline_points(case['inset_deg'], tangents)
            box = report.outline_bbox(points)
            for got, value in zip(box, want['bbox_tan']):
                self.assertAlmostEqual(got, value, delta=1e-3, msg=case['name'])
            rect = report.foveation_rect(case['eye'], tangents, case['foveation'], case['render_px'])
            for got, value in zip(rect, want['fov_rect_tan']):
                self.assertAlmostEqual(got, value, delta=1e-3, msg=case['name'])
            left, right, bottom, top = tangents
            self.assertAlmostEqual(report.pxdeg_axis(case['render_px'], (left, right, top, bottom)), want['pxdeg_frustum'],
                                   delta=0.1, msg=case['name'])
            self.assertAlmostEqual(report.pxdeg_axis(case['render_px'], box), want['pxdeg_bbox'], delta=0.1, msg=case['name'])

    def test_hand_values_a100_axis_c(self):
        # Hand values as in ProjectionOverlayTests: bbox extremes at rays 195/0/105/270, render 4176x3333.
        rays = report.outline_rays(L_RAYS)
        box = report.outline_bbox([(r, report.lens_ecc(r, rays)) for r in range(0, 360, 5)])
        for got, want in zip(box, (0.885108, 0.767327, 0.615363, 0.637070)):
            self.assertAlmostEqual(got, want, places=6)
        self.assertAlmostEqual(report.pxdeg_axis((4176, 3333), (1.7321, 1.0, 1.0, 1.1918)), 26.541, places=3)
        self.assertAlmostEqual(report.pxdeg_axis((4176, 3333), box), 44.108, places=3)
        rect = report.foveation_rect('L', LEFT, (0.5, 0.45, 3, 3, 0.536, -0.159), (4176, 3333))
        for got, want in zip(rect, (0.682047, 0.684003, 0.491013, 0.493423)):
            self.assertAlmostEqual(got, want, delta=2e-6)
        self.assertEqual(report.render_size(1.1447), (4176, 3333))

    def test_outline_rows_carry_and_check_the_projection(self):
        rows = report.dots_outlines(self.records(PROJECTION_LOG))
        self.assertEqual(len(rows), 4)
        first = rows[0]
        self.assertEqual(first['bbox_deg'], (41.512, 37.5, 31.607, 32.5))
        self.assertEqual(first['fov_rect_deg'], (34.296, 34.372, 26.152, 26.263))
        self.assertEqual(first['fov_source'], 'a100-axis-C')
        self.assertEqual(first['fov_live'], 'no')
        self.assertEqual(first['render_px'], (4176, 3333))
        self.assertEqual((first['pxdeg_frustum'], first['pxdeg_bbox']), (26.541, 44.108))
        self.assertEqual(first['projection_check'], 'ok')
        self.assertEqual(first['session'], 'diag-outline.log:1')
        self.assertEqual(rows[1]['projection_check'], 'not logged', 'older lines have no projection fields')
        self.assertEqual(rows[2]['session'], 'diag-outline.log:4')
        self.assertEqual(rows[3]['projection_check'], 'mismatch: pxdeg_bbox')

    def test_report_has_projection_columns_and_a_summary_per_session(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'diag-outline.log').write_text(PROJECTION_LOG)
            output = report.generate(directory)
        for text in ['bbox_deg', 'fov_rect_deg', 'pxdeg_frustum', 'pxdeg_bbox', 'projection_check', '41.512,37.5,31.607,32.5']:
            self.assertIn(text, output)
        summary = [line for line in output.splitlines() if line.startswith('projection ')]
        self.assertEqual(summary, [
            'projection session=diag-outline.log:1 eye=L source=diag-outline.log:2 fov_source=a100-axis-C fov_live=no '
            'bbox_deg=41.512,37.5,31.607,32.5 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 '
            'pxdeg_frustum=26.541 pxdeg_bbox=44.108 gain=1.66 check=ok; eye=R no data',
            'projection session=diag-outline.log:4 eye=L source=diag-outline.log:6 fov_source=a100-axis-C fov_live=no '
            'bbox_deg=41.512,37.5,31.607,32.5 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 '
            'pxdeg_frustum=26.541 pxdeg_bbox=45 gain=1.70 check=mismatch: pxdeg_bbox; eye=R no data',
        ])


if __name__ == '__main__':
    unittest.main()
