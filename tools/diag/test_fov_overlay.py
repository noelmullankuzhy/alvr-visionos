import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name('fov-overlay.py')
SPEC = importlib.util.spec_from_file_location('fov_overlay', SCRIPT)
fo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fo)

STD = {'s': 1, 'rs': 1, 'cx': 0.5, 'cy': 0.45, 'r': 3, 'shx': 0, 'shy': 0}
SHC = fo.centre_shift(0.5, 0.45)


def deg(x):
    return math.degrees(math.atan(x))


class PageNumbers(unittest.TestCase):
    """The numbers printed on frustum-pixel-map.html."""

    def test_standard_preset(self):
        m = fo.page_model(STD)
        self.assertEqual((m['W'], m['H']), (3648, 2912))
        self.assertEqual((m['ax']['coded'], m['ay']['coded']), (2432, 1856))
        self.assertEqual((round(m['ax']['opt']), round(m['ay']['opt'])), (2432, 1844))
        b = m['band']
        self.assertEqual([round(-deg(b['x0']), 1), round(deg(b['x1']), 1)], [46.4, 17.6])
        self.assertEqual([round(deg(b['yTop']), 1), round(-deg(b['yBot']), 1)], [21.7, 30.5])
        self.assertEqual(round(fo.detail_h(m, 0), 1), 23.3)

    def test_fov_060_centred_axis(self):
        m = fo.page_model(dict(STD, s=0.60, shx=SHC[0], shy=SHC[1]))
        self.assertEqual(round(fo.detail_h(m, 0), 1), 38.8)

    def test_one_to_one_preset(self):
        m = fo.page_model(dict(STD, s=0.60, rs=1.03, shx=SHC[0], shy=SHC[1]))
        self.assertEqual((m['W'], m['H']), (3757, 2999))
        self.assertEqual((m['ax']['coded'], m['ay']['coded']), (2528, 1920))
        self.assertEqual(round(fo.detail_h(m, 0), 1), 40.0)

    def test_wider_band(self):
        sh = fo.centre_shift(0.6, 0.6)
        m = fo.page_model({'s': 0.60, 'rs': 1, 'cx': 0.6, 'cy': 0.6, 'r': 2.5, 'shx': sh[0], 'shy': sh[1]})
        self.assertEqual((m['ax']['coded'], m['ay']['coded']), (2784, 2240))

    def test_visible_area(self):
        self.assertEqual(round(fo.v_stats()['area'] * 100, 2), 28.34)

    def test_page_detail_matches_map_derivative(self):
        sh = fo.centre_shift(0.5, 0.45)
        m = fo.page_model(dict(STD, s=0.8, shx=sh[0], shy=sh[1]))
        for th in (-40, -10, 0, 15, 25):
            axis = fo.make_axis('h', 'encoded', m['sL'] * -1, m['sN'], m['W'], fov=m['ax'])
            h = 0.01
            slope = abs(axis.px(math.tan((th + h) * fo.D)) - axis.px(math.tan((th - h) * fo.D))) / (2 * h)
            self.assertAlmostEqual(slope, fo.detail_h(m, th), delta=slope * 0.002)

    def test_foveation_map_inverse(self):
        a = fo.fov_axis(0.5, 0.2, 3, 3648)
        for c in (0.0, 0.1, 0.3, 0.5, 0.8, 1.0):
            self.assertAlmostEqual(fo.c_of_u(fo.u_of_c(c, a), a), c, places=9)
        self.assertAlmostEqual(fo.u_of_c(0, a), 0, places=12)
        self.assertAlmostEqual(fo.u_of_c(1, a), 1, places=12)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, argv):
        code = fo.main([str(a) for a in argv])
        return code

    def measure(self, mode, image, extra=(), name='m'):
        out = self.dir / (name + '.json')
        code = self.run_main([mode, '--image', image, '--out-json', out, '--out-png', self.dir / (name + '.png')] + list(extra))
        return code, json.loads(out.read_text())


class RoundTrip(Base):
    RENDER = ['--render', '1824x1456']
    FOV = ['--foveation', '0.5,0.45,3,3,0,0']

    def synth(self, kind, extra=()):
        png = self.dir / (kind + '.png')
        self.assertEqual(self.run_main(['synth', '--kind', kind, '--out-png', png] + list(extra)), 0)
        return png

    def check_pass(self, summary):
        s = summary['summary']
        self.assertEqual(s['verdict'], 'PASS', s)
        self.assertLessEqual(s['median_abs_residual_deg'], 0.05)
        self.assertGreaterEqual(s['n_found'], 0.9 * s['n_predicted'])

    def test_render_left_and_right(self):
        for eye in ('L', 'R'):
            png = self.synth('render', self.RENDER + ['--fov-scale', '0.8', '--eye', eye])
            code, j = self.measure('render', png, self.RENDER + ['--fov-scale', '0.8', '--eye', eye])
            self.assertEqual(code, 0)
            self.check_pass(j)
            self.assertTrue((self.dir / 'm.png').exists())

    def test_render_wrong_fov_scale_fails(self):
        png = self.synth('render', self.RENDER + ['--fov-scale', '0.65'])
        code, j = self.measure('render', png, self.RENDER + ['--fov-scale', '0.6'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')
        self.assertNotEqual(code, 0)

    def test_encoded(self):
        extra = self.RENDER + self.FOV + ['--fov-scale', '0.7']
        png = self.synth('encoded', extra)
        code, j = self.measure('encoded', png, extra)
        self.assertEqual(code, 0)
        self.check_pass(j)
        zones = j['summary']['zones']
        self.assertIn('band', zones)
        self.assertIn('edge', zones)

    def test_encoded_wrong_fov_scale_fails(self):
        png = self.synth('encoded', self.RENDER + self.FOV + ['--fov-scale', '0.65'])
        code, j = self.measure('encoded', png, self.RENDER + self.FOV + ['--fov-scale', '0.6'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')

    def test_encoded_wrong_foveation_fails(self):
        png = self.synth('encoded', self.RENDER + self.FOV)
        code, j = self.measure('encoded', png, self.RENDER + ['--foveation', '0.6,0.45,2.5,3,0,0'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')

    def test_encoded_shifted_band(self):
        extra = self.RENDER + ['--foveation', '0.5,0.45,3,3,0.3,-0.2', '--fov-scale', '0.9']
        png = self.synth('encoded', extra)
        code, j = self.measure('encoded', png, extra)
        self.check_pass(j)

    def synth_drawable(self, extra=()):
        d = self.dir / 'cap'
        self.assertEqual(self.run_main(['synth', '--kind', 'drawable', '--out-dir', d] + list(extra)), 0)
        return d

    def measure_drawable(self, d, extra=(), name='d'):
        out = self.dir / (name + '.json')
        code = self.run_main(['drawable', '--capture-dir', d, '--out-json', out, '--out-png', self.dir / (name + '.png')] + list(extra))
        return code, json.loads(out.read_text())

    def test_drawable(self):
        extra = ['--render', '3648x2912', '--fov-scale', '0.65', '--phys', '1216x1184']
        d = self.synth_drawable(extra)
        code, j = self.measure_drawable(d, extra)
        self.assertEqual(code, 0)
        self.check_pass(j)
        ext = j['summary']['stream_extent_deg']
        for side in ('left', 'right', 'down', 'up'):
            self.assertIsNotNone(ext[side]['measured_deg'], side)
            self.assertLessEqual(abs(ext[side]['error_deg']), 0.5, side)

    def test_drawable_wrong_fov_scale_fails(self):
        d = self.synth_drawable(['--render', '3648x2912', '--fov-scale', '0.6', '--phys', '1216x1184'])
        code, j = self.measure_drawable(d, ['--render', '3648x2912', '--fov-scale', '0.65'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')
        self.assertNotEqual(code, 0)

    def test_drawable_right_eye(self):
        extra = ['--render', '3648x2912', '--fov-scale', '0.7', '--phys', '1216x1184', '--eye', 'R']
        d = self.synth_drawable(extra)
        code, j = self.measure_drawable(d, extra)
        self.check_pass(j)

    def test_region_crop_of_side_by_side(self):
        png = self.synth('render', self.RENDER)
        w, h, pix = fo.vc.read_png(png)
        big_w, big_h, ox, oy = w + 200, h + 60, 137, 21
        canvas = bytearray(big_w * big_h * 4)
        for y in range(h):
            canvas[((y + oy) * big_w + ox) * 4:((y + oy) * big_w + ox + w) * 4] = pix[y * w * 4:(y + 1) * w * 4]
        big = self.dir / 'big.png'
        fo.vc.write_png(big, big_w, big_h, bytes(canvas))
        code, j = self.measure('render', big, self.RENDER + ['--region', '%d,%d,%d,%d' % (ox, oy, w, h)])
        self.assertEqual(code, 0)
        self.check_pass(j)
        first = j['lines'][0]
        self.assertGreater(first['predicted_px'], ox)

    def test_line_record_fields(self):
        png = self.synth('render', self.RENDER)
        code, j = self.measure('render', png, self.RENDER)
        keys = {'kind', 'angle_deg', 'predicted_px', 'measured_px', 'residual_px', 'residual_deg', 'fwhm_px', 'fwhm_deg', 'contrast', 'zone'}
        for line in j['lines']:
            self.assertTrue(keys <= set(line), line)
        self.assertEqual({l['kind'] for l in j['lines']}, {'vertical', 'horizontal'})
        for key in ('n_predicted', 'n_found', 'median_abs_residual_deg', 'max_abs_residual_deg', 'stream_extent_deg', 'zones', 'verdict'):
            self.assertIn(key, j['summary'])
        # 0-degree line is 7 px wide; its FWHM is ~7 render px
        zero = [l for l in j['lines'] if l['kind'] == 'vertical' and l['angle_deg'] == 0][0]
        self.assertAlmostEqual(zero['fwhm_px'], 7, delta=1.0)

    def test_blank_image_fails(self):
        blank = self.dir / 'blank.png'
        fo.vc.write_png(blank, 400, 300, bytes([20, 20, 40, 255]) * (400 * 300))
        code, j = self.measure('render', blank, ['--render', '400x300'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')
        self.assertEqual(j['summary']['n_found'], 0)
        self.assertNotEqual(code, 0)


class Spec(unittest.TestCase):
    def test_pattern_widths_and_colours(self):
        img = fo.synth_render(1824, 1456, (1.7321, 1.0, 1.1918, 1.0), 1.0, 'L')
        w, h = 1824, 1456
        tanl, tanr = -1.7321, 1.0
        # 0 degrees: 7 px wide, green; away from horizontal lines
        i0 = round((0 - tanl) / (tanr - tanl) * w - 0.5)
        row = 100
        run = [i for i in range(w) if img[(row * w + i) * 4:(row * w + i) * 4 + 3] == bytes([0, 255, 0])]
        self.assertIn(i0, run)
        widths = []
        cur = []
        for i in run:
            if cur and i != cur[-1] + 1:
                widths.append(len(cur))
                cur = []
            cur.append(i)
        widths.append(len(cur))
        self.assertIn(7, widths)
        self.assertIn(5, widths)
        self.assertIn(3, widths)
        self.assertEqual(img[3:4], b'\xff')
        self.assertEqual(bytes(img[0:3]), bytes([round(0.06 * 255), round(0.06 * 255), round(0.12 * 255)]))
        r = fo.synth_render(400, 300, (1.7321, 1.0, 1.1918, 1.0), 1.0, 'R')
        self.assertEqual(bytes(r[0:3]), bytes([round(0.12 * 255), round(0.06 * 255), round(0.06 * 255)]))


class Performance(Base):
    def test_full_size_image_under_60_s(self):
        png = self.dir / 'big.png'
        argv = ['--render', '2432x2368']
        start = time.time()
        self.assertEqual(fo.main(['synth', '--kind', 'render', '--out-png', str(png)] + argv), 0)
        code, j = self.measure('render', png, argv)
        elapsed = time.time() - start
        self.assertEqual(code, 0)
        self.assertLess(elapsed, 60)
        png.unlink()


class Cli(Base):
    def test_subprocess_roundtrip(self):
        png = self.dir / 'r.png'
        out = self.dir / 'r.json'
        subprocess.run([sys.executable, str(SCRIPT), 'synth', '--kind', 'render', '--render', '912x728', '--out-png', str(png)], check=True)
        p = subprocess.run([sys.executable, str(SCRIPT), 'render', '--image', str(png), '--render', '912x728', '--out-json', str(out)],
                           check=False, stdout=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('PASS', p.stdout)
        self.assertEqual(json.loads(out.read_text())['summary']['verdict'], 'PASS')

    def test_bad_input_exits_2(self):
        p = subprocess.run([sys.executable, str(SCRIPT), 'render', '--image', str(self.dir / 'missing.png')],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 2)


if __name__ == '__main__':
    unittest.main()
