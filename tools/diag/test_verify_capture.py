import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('verify_capture', Path(__file__).with_name('verify-capture.py'))
v = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(v)

class CaptureTests(unittest.TestCase):
    def test_png_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'rgba.png'
            pixels = bytes(range(256)) * 4
            v.write_png(p, 16, 16, pixels)
            self.assertEqual(v.read_png(p), (16, 16, pixels))

    def test_empty_proof_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'capture.json').write_text(json.dumps({'corner_chart': {'mode': 'Both eyes', 'ring_percents': [100]}, 'slices': []}))
            result = subprocess.run([sys.executable, str(Path(v.__file__)), str(p)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)

    def fixture(self, directory, moved=False, centered=False, missing=False):
        # Deliberately asymmetric tangents, origin, viewport, nonlinear separable map.
        n = 500
        table = [350 * (x / n) ** 0.8 for x in range(n + 1)]
        metadata = {'corner_chart': {'mode': 'Both eyes', 'ring_percents': [100, 85, 65, 50]}, 'slices': []}
        if centered:
            metadata['corner_chart']['ring_stroke_alignment'] = 'center'
            metadata['corner_chart']['cut_percents'] = [100, 50, 30]
        for eye in ('L', 'R'):
            image = bytearray(360 * 360 * 4)
            tangents = [1.2, 0.8, 0.9, 1.1]
            viewport = [10, 10, 480, 480]
            colour = (0, 255, 255, 255) if eye == 'L' else (255, 0, 255, 255)
            for pct in metadata['corner_chart']['ring_percents']:
                if missing and eye == 'R' and pct == 65:
                    continue
                p = pct / 100
                left = v.interpolate(table, 10 + 480 * (1.2 - p * 1.2) / 2)
                right = v.interpolate(table, 10 + 480 * (1.2 + p * .8) / 2)
                top = v.interpolate(table, 10 + 480 * (1.1 - p * 1.1) / 2)
                bottom = v.interpolate(table, 10 + 480 * (1.1 + p * .9) / 2)
                if moved and eye == 'L' and pct == 85:
                    right += 3
                if centered and pct != 100:
                    left -= 2
                    right += 2
                    top -= 2
                    bottom += 2
                stroke = 4 if centered and pct != 100 else 2
                for y in range(360):
                    for x in range(360):
                        if left <= x + .5 <= right and top <= y + .5 <= bottom and (x + .5 < left + stroke or x + .5 > right - stroke or y + .5 < top + stroke or y + .5 > bottom - stroke):
                            image[(y * 360 + x) * 4:(y * 360 + x) * 4 + 4] = bytes(colour)
            name = eye + '.png'
            v.write_png(directory / name, 360, 360, image)
            metadata['slices'].append({'eye': eye, 'slice': len(metadata['slices']), 'view': len(metadata['slices']), 'png': name, 'width': 360, 'height': 360, 'viewport': viewport, 'tangents': tangents, 'rate_map': {'screen_w': n, 'screen_h': n, 'physical_x': table, 'physical_y': table}})
        (directory / 'capture.json').write_text(json.dumps(metadata))
        return metadata

    def test_tables_and_synthetic(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            m = self.fixture(p)
            for s in m['slices']:
                self.assertEqual(len(s['rate_map']['physical_x']), s['rate_map']['screen_w'] + 1)
                self.assertEqual(len(s['rate_map']['physical_y']), s['rate_map']['screen_h'] + 1)
            result = subprocess.run([sys.executable, str(Path(v.__file__)), str(p)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((p / 'L-logical.png').exists())
            self.fixture(p, moved=True)
            result = subprocess.run([sys.executable, str(Path(v.__file__)), str(p)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('L right ring=85 FAIL', result.stdout)

    def test_centered_d9_strokes_and_border(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            self.fixture(p, centered=True)
            result = subprocess.run([sys.executable, str(Path(v.__file__)), str(p)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.fixture(p, moved=True, centered=True)
            result = subprocess.run([sys.executable, str(Path(v.__file__)), str(p)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('L right ring=85 FAIL', result.stdout)

    def test_missing_ring_names_eye_axis_percent(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            self.fixture(p, centered=True, missing=True)
            result = subprocess.run([sys.executable, str(Path(v.__file__)), str(p)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('R right ring=65 FAIL', result.stdout)

if __name__ == '__main__':
    unittest.main()
