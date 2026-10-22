"""Projection overlay points table: the rows compiled into ProjectionOverlay.swift match their source,
tools/fov-matrix/points-chart-avp.tsv (fov_scale 1 rows), through tools/diag/fixtures/projection-points.json."""
import json
from pathlib import Path
import re
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).with_name('fixtures') / 'projection-points.json'
SWIFT = ROOT / 'ALVRClient' / 'Diagnostics' / 'ProjectionOverlay.swift'
TSV = ROOT / 'tools' / 'fov-matrix' / 'points-chart-avp.tsv'


def fixture_rows():
    return [(row['name'], float(row['render_scale']), tuple(float(v) for v in row['foveation']))
            for row in json.loads(FIXTURE.read_text())['rows']]


def swift_rows():
    """The `ProjectionFoveation.points` literal: ("name", render_scale, [cx, cy, rx, ry, shx, shy]) per line."""
    text = SWIFT.read_text()
    table = text[text.index('static let points'):text.index('].map')]
    return [(name, float(scale), tuple(float(v) for v in values.split(',')))
            for name, scale, values in re.findall(r'\("([^"]+)", ([0-9.]+), \[([^\]]+)\]\)', table)]


DEVICE_EYES = 'eye_tangents=L:1.7321,1,1.1918,1;R:1,1.7321,1.1918,1'


def tsv_rows(text):
    """fov_scale 1 rows on the device frustum: name, fov_scale, render_scale, foveation(cx,cy,rx,ry,shx,shy|off), ...
    tab-separated. Rows with other eye_tangents (the crop rows) render a different frustum than the overlay draws."""
    rows = []
    for line in text.splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        cells = line.split('\t')
        if float(cells[1]) != 1 or cells[3] == 'off':
            continue
        if any(c.startswith('eye_tangents=') and c != DEVICE_EYES for c in cells[6:]):
            continue
        rows.append((cells[0], float(cells[2]), tuple(float(v) for v in cells[3].split(','))))
    return rows


class ProjectionPointsTableTests(unittest.TestCase):
    def test_fixture_matches_the_swift_table(self):
        swift = swift_rows()
        self.assertEqual(len(swift), 6, 'six rows parsed from {}'.format(SWIFT))
        self.assertEqual(fixture_rows(), swift)

    def test_swift_comment_pins_the_source(self):
        self.assertIn('develop 6aab8e6', SWIFT.read_text())
        self.assertIn('22 Oct 2026', SWIFT.read_text())

    def test_tsv_rows_match_the_fixture(self):
        if not TSV.exists():
            self.skipTest('{} absent on this base (present after the rebase onto develop)'.format(TSV.relative_to(ROOT)))
        self.assertEqual(tsv_rows(TSV.read_text()), fixture_rows())


if __name__ == '__main__':
    unittest.main()
