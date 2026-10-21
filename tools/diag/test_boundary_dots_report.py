"""Boundary dots geometry and log replay contract (both supported Pythons)."""
import importlib.util
import math
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('dots_report', Path(__file__).with_name('diag-report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class BoundaryDotsReportTests(unittest.TestCase):
    @staticmethod
    def records(text):
        return [report.parse_line(line, 'diag-dots.log:{}'.format(i))
                for i, line in enumerate(text.splitlines(), 1)]

    def test_asymmetric_tangent_percentages_and_drawable_coordinates(self):
        for yaw, pitch, expected in [(45, 45, (50, 25, .75, .625)),
                                     (-45, -45, (-100, -25, 0, .375))]:
            actual = report.dots_coordinates(yaw, pitch, (1, 2, 4, 4))
            for key, value in zip(('x_pct', 'y_pct', 'u', 'v'), expected):
                self.assertAlmostEqual(actual[key], value)
        self.assertIsNone(report.dots_coordinates(45, 0, (0, 1, 1, 1)))
        self.assertIsNone(report.dots_coordinates(float('nan'), 0, (1, 1, 1, 1)))
        self.assertIsNone(report.dots_coordinates(90, 0, (1, 1, 1, 1)))

    def test_confirm_clear_replay_and_latest_eye_tangents(self):
        rows = report.dots_boundaries(self.records('''DIAG m5_view t_ms=1 view=0 tangents=1,1,1,1
DIAG m5_view t_ms=2 view=1 tangents=2,2,2,2
DIAG dots_session t_ms=3 event=begin
DIAG dots t_ms=4 eye=L action=confirm ray_deg=0 ecc_deg=30 yaw_deg=30 pitch_deg=0
DIAG dots t_ms=5 eye=L action=confirm ray_deg=0 ecc_deg=45 yaw_deg=45 pitch_deg=0
DIAG dots t_ms=6 eye=L action=clear ray_deg=0 ecc_deg=45 yaw_deg=45 pitch_deg=0
DIAG dots t_ms=7 eye=R action=confirm ray_deg=90 ecc_deg=45 yaw_deg=0 pitch_deg=45
DIAG m5_view t_ms=8 view=0 tangents=1,2,3,4'''))
        self.assertEqual(len(rows), 2)
        left, right = rows
        self.assertEqual((left['label'], left['eye']), ('L', 'L'))
        self.assertEqual(left['points'][0]['ecc_deg'], 30)
        self.assertAlmostEqual(left['points'][0]['x_pct'], 100 * math.tan(math.pi / 6) / 2)
        self.assertEqual(left['tangent_source'], 'diag-dots.log:8')
        self.assertAlmostEqual(right['points'][0]['y_pct'], 50)
        self.assertIsNone(left['visible_area_frac'], 'missing rays cannot imply a boundary')

    def test_both_expands_per_eye_summary_reproduces_polygon_without_marks(self):
        rays = ','.join('{}:45'.format(ray) for ray in range(0, 360, 15))
        records = self.records('''DIAG m5_view t_ms=1 view=0 tangents=1,1,1,1
DIAG m5_view t_ms=2 view=1 tangents=1,2,3,4
DIAG dots_summary t_ms=3 eye=Both points=26 rays={}'''.format(rays))
        rows = report.dots_boundaries(records)
        self.assertEqual([(r['label'], r['eye']) for r in rows], [('Both', 'L'), ('Both', 'R')])
        expected_area = 24 * math.sin(math.pi / 12) / 2
        self.assertAlmostEqual(rows[0]['visible_area_frac'], expected_area / 4)
        self.assertAlmostEqual(rows[1]['visible_area_frac'], expected_area / 21)
        self.assertEqual(len(rows[0]['points']), 24)
        self.assertAlmostEqual(rows[0]['points'][3]['yaw_deg'], 35.264389682754654)
        self.assertAlmostEqual(rows[0]['points'][3]['pitch_deg'], 35.264389682754654)
        self.assertEqual(rows[0]['confirmed_points'], 26)

    def test_summary_is_authoritative_and_sessions_never_share_marks(self):
        records = self.records('''DIAG m5_view t_ms=1 view=0 tangents=1,1,1,1
DIAG dots t_ms=2 eye=L action=confirm ray_deg=0 ecc_deg=45 yaw_deg=45 pitch_deg=0
DIAG dots_summary t_ms=3 eye=L points=0 rays=none
DIAG dots_session t_ms=4 event=begin
DIAG dots t_ms=5 eye=L action=confirm ray_deg=90 ecc_deg=30 yaw_deg=0 pitch_deg=30
DIAG m1 t_ms=6 model=new_session
DIAG dots_summary t_ms=7 eye=L points=1 rays=0:45
DIAG m5_view t_ms=8 view=0 tangents=1,2,1,1''')
        rows = report.dots_boundaries(records)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]['points'], [])
        self.assertEqual(rows[1]['points'][0]['ray_deg'], 90)
        self.assertIsNone(rows[2]['points'][0]['x_pct'], 'future/previous app-session tangents are not used')

    def test_missing_invalid_or_partial_data_is_not_zero_area(self):
        for suffix in ['rays=none', 'rays=0:30,90:30,180:30', 'rays=0:nan',
                       'rays=0:30,0:40', 'rays=361:30', 'rays=0:100']:
            rows = report.dots_boundaries(self.records('DIAG dots_summary t_ms=1 eye=L points=3 ' + suffix))
            self.assertIsNone(rows[0]['visible_area_frac'])
        rows = report.dots_boundaries(self.records('''DIAG dots t_ms=1 eye=L action=confirm ray_deg=0 ecc_deg=30 yaw_deg=nan pitch_deg=0
DIAG dots t_ms=2 eye=L action=clear ray_deg=0 ecc_deg=30 yaw_deg=30 pitch_deg=0'''))
        self.assertTrue(not rows or not rows[0]['points'])

    def test_report_retains_logs_sources_and_accuracy_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'diag-dots.log').write_text('''DIAG m5_view t_ms=1 view=0 tangents=1,2,3,4
DIAG dots t_ms=2 eye=L action=confirm ray_deg=0 ecc_deg=30 yaw_deg=30 pitch_deg=0
DIAG dots_summary t_ms=3 eye=L points=1 rays=0:30
''')
            output = report.generate(directory)
        for text in ['## Boundary dots', 'visible_area_frac', 'x_pct', 'y_pct',
                     'head-vs-eye-origin approximation', 'tracker limit', '2.5',
                     'diag-dots.log:3', 'confirm', 'rays', 'L']:
            self.assertIn(text, output)


if __name__ == '__main__':
    unittest.main()
