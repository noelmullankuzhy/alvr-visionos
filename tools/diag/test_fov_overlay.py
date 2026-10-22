import contextlib
import importlib.util
import io
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


def flip_png(src, dst):
    w, h, pix = fo.vc.read_png(src)
    out = bytearray()
    for y in range(h):
        row = pix[y * w * 4:(y + 1) * w * 4]
        out += b''.join(row[i * 4:i * 4 + 4] for i in range(w - 1, -1, -1))
    fo.vc.write_png(dst, w, h, bytes(out))


def blur_png(src, dst, width):
    """Box blur of `width` px along both axes (stands in for a soft decode/resample)."""
    w, h, pix = fo.vc.read_png(src)

    def blur_line(vals):
        n, half = len(vals), width // 2
        acc = [0]
        for v in vals:
            acc.append(acc[-1] + v)
        return [(acc[min(n, i + half + 1)] - acc[max(0, i - half)]) / (min(n, i + half + 1) - max(0, i - half)) for i in range(n)]

    out = bytearray(w * h * 4)
    for c in range(3):
        rows = [blur_line(list(pix[(y * w) * 4 + c:(y + 1) * w * 4:4])) for y in range(h)]
        for x in range(w):
            col = blur_line([rows[y][x] for y in range(h)])
            for y in range(h):
                out[(y * w + x) * 4 + c] = int(round(col[y]))
    out[3::4] = b'\xff' * (w * h)
    fo.vc.write_png(dst, w, h, bytes(out))


class ReviewFixes(Base):
    RENDER = ['--render', '1824x1456']
    SMALL = ['--render', '912x728']
    PAD = ['--foveation', '0.55,0.45,3,3,0.4,-0.2']

    def synth(self, kind, extra, name=None):
        png = self.dir / ((name or kind) + '.png')
        self.assertEqual(self.run_main(['synth', '--kind', kind, '--out-png', png] + list(extra)), 0)
        return png

    def reasons(self, j):
        return ' | '.join(j['summary']['verdict_reasons'])

    # 1. right eye encoded mapping mirrors per ALVR
    def test_right_eye_is_flipped_left_eye(self):
        left = self.synth('encoded', self.RENDER + self.PAD + ['--eye', 'L'], 'encL')
        coded = fo.fov_axis(0.55, 0.4, 3, 1824)
        self.assertGreater(coded['coded'], coded['opt'] + 1)   # padding present, as on the 1:1 preset
        right = self.dir / 'encR.png'
        flip_png(left, right)
        code, j = self.measure('encoded', right, self.RENDER + self.PAD + ['--eye', 'R'])
        self.assertEqual(code, 0, self.reasons(j))
        self.assertLessEqual(j['summary']['median_abs_residual_deg'], 0.05)
        code, j = self.measure('encoded', right, self.RENDER + self.PAD + ['--eye', 'L'], 'wrongeye')
        self.assertEqual(j['summary']['verdict'], 'FAIL')

    def test_right_eye_synth_round_trip(self):
        png = self.synth('encoded', self.RENDER + self.PAD + ['--eye', 'R'])
        code, j = self.measure('encoded', png, self.RENDER + self.PAD + ['--eye', 'R'])
        self.assertEqual(code, 0, self.reasons(j))

    def test_right_eye_band_is_mirrored(self):
        fv = fo.fov_axis(0.5, 0.4, 3, 1824)
        left = fo.make_axis('h', 'encoded', -1.7, 1.0, 1824, fov=fv)
        right = fo.make_axis('h', 'encoded', -1.0, 1.7, 1824, fov=fv, mirror=True)
        u0, u1 = fo.band_fractions(fv)
        self.assertEqual(left.band_t(), (u0, u1))
        self.assertAlmostEqual(right.band_t()[0], 1 - u1)
        self.assertAlmostEqual(right.band_t()[1], 1 - u0)
        for tau in (-0.9, -0.2, 0.3, 1.2):
            self.assertAlmostEqual(right.tau(right.px(tau)), tau, places=6)

    # 2. edge lines must be verified; contrast threshold is relative
    def test_blurred_edges_are_unverified(self):
        extra = self.SMALL + ['--foveation', '0.5,0.45,5,5,0,0']
        sharp = self.synth('encoded', extra, 'sharp')
        code, j = self.measure('encoded', sharp, extra, 'sharp')
        self.assertEqual(code, 0, self.reasons(j))
        # the squeezed side columns lose their lines (aliased away, or dropped by the pipeline)
        w, h, pix = fo.vc.read_png(sharp)
        gone = bytearray(pix)
        bg = bytes([15, 15, 31, 255])
        for y in range(h):
            for x in list(range(int(0.2 * w))) + list(range(int(0.8 * w), w)):
                gone[(y * w + x) * 4:(y * w + x) * 4 + 4] = bg
        edgeless = self.dir / 'edgeless.png'
        fo.vc.write_png(edgeless, w, h, bytes(gone))
        code, j = self.measure('encoded', edgeless, extra, 'edgeless')
        self.assertNotEqual(j['summary']['verdict'], 'PASS')
        self.assertIn('x edge unverified', self.reasons(j))
        self.assertNotEqual(code, 0)

    def test_contrast_threshold_is_relative_to_background(self):
        prof = [0.0] * 60
        for i in (29, 30, 31):
            prof[i] = 0.08
        self.assertIsNotNone(fo.find_line(prof, 15, 45))          # clean, faint line: a fixed 0.15 floor lost it
        noisy = [0.05 * ((i * 7919) % 11 - 5) / 5 + 0.05 for i in range(60)]
        self.assertIsNone(fo.find_line(noisy, 15, 45))            # same amplitude as the noise: rejected

    # 3. sharpness takes the line's own width out and goes the right way
    def test_sharpness_drops_with_blur(self):
        extra = self.SMALL + ['--foveation', '0.5,0.45,3,3,0,0']
        sharp = self.synth('encoded', extra, 'sharp')
        code, a = self.measure('encoded', sharp, extra, 'a')
        soft = self.dir / 'soft.png'
        blur_png(sharp, soft, 7)
        code, b = self.measure('encoded', soft, extra, 'b')
        za, zb = a['summary']['zones']['band'], b['summary']['zones']['band']
        self.assertAlmostEqual(za['sharpness_px_per_deg'] / za['predicted_px_per_deg'], 1.0, delta=0.2)
        self.assertLess(zb['sharpness_px_per_deg'], 0.8 * za['sharpness_px_per_deg'])
        self.assertGreater(zb['psf_deg'], za['psf_deg'] or 0)
        self.assertLess(zb['resolved_px_per_deg'], zb['predicted_px_per_deg'])

    def test_narrow_lines_are_unresolvable(self):
        extra = self.SMALL + ['--foveation', '0.5,0.45,5,5,0,0']
        png = self.synth('encoded', extra)
        code, j = self.measure('encoded', png, extra)
        edge = [l for l in j['lines'] if l['zone'] == 'edge']
        self.assertTrue(edge)
        narrow = [l for l in edge if l['nominal_width_px'] < 2]
        self.assertTrue(narrow)
        self.assertTrue(all(not l['resolvable'] for l in narrow))
        self.assertTrue(all(l['resolvable'] for l in j['lines'] if l['nominal_width_px'] >= 2 and l['fwhm_px'] is not None))

    # 4. drawable mode carries the page prediction
    def test_drawable_uses_page_prediction(self):
        extra = ['--render', '3648x2912', '--fov-scale', '0.65', '--phys', '1216x1184', '--foveation', '0.5,0.45,3,3,0,0']
        d = self.dir / 'cap'
        self.assertEqual(self.run_main(['synth', '--kind', 'drawable', '--out-dir', d] + extra), 0)
        out = self.dir / 'd.json'
        self.run_main(['drawable', '--capture-dir', d, '--out-json', out] + extra)
        j = json.loads(out.read_text())
        m = fo.page_model(dict(STD, s=0.65))
        for l in j['lines']:
            fn = fo.detail_h if l['kind'] == 'vertical' else fo.detail_v
            want = fn(m, l['angle_deg'])
            self.assertAlmostEqual(l['predicted_px_per_deg'], want, delta=want * 0.01, msg=str(l))
        self.assertIsNotNone(j['summary']['zones']['band']['predicted_px_per_deg'])

    # 5. verdict per axis
    def test_flipped_shift_sign_fails_on_x(self):
        extra = self.RENDER + ['--foveation', '0.5,0.45,3,3,0.3,0']
        png = self.synth('encoded', extra)
        code, j = self.measure('encoded', png, self.RENDER + ['--foveation', '0.5,0.45,3,3,-0.3,0'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')
        r = j['summary']['verdict_reasons']
        self.assertTrue(any(x.startswith('x ') for x in r), r)
        self.assertFalse(any(x.startswith('y ') for x in r), r)

    def test_one_axis_error_is_not_hidden_by_the_other(self):
        extra = self.RENDER + ['--foveation', '0.5,0.45,3,3,0,0.2']
        png = self.synth('encoded', extra)
        code, j = self.measure('encoded', png, self.RENDER + ['--foveation', '0.5,0.45,3,3,0,0'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')
        r = j['summary']['verdict_reasons']
        self.assertTrue(any(x.startswith('y ') and 'median' in x for x in r), r)
        self.assertFalse(any(x.startswith('x ') for x in r), r)
        self.assertGreater(j['summary']['axes']['y']['median_abs_residual_deg'], 0.1)
        self.assertLess(j['summary']['axes']['x']['median_abs_residual_deg'], 0.05)

    def test_right_eye_wrong_shift_fails(self):
        png = self.synth('encoded', self.RENDER + self.PAD + ['--eye', 'R'])
        code, j = self.measure('encoded', png, self.RENDER + ['--foveation', '0.55,0.45,3,3,-0.4,-0.2', '--eye', 'R'])
        self.assertEqual(j['summary']['verdict'], 'FAIL')
        self.assertTrue(any(x.startswith('x ') for x in j['summary']['verdict_reasons']))

    # 7. NITs
    def test_foveation_off_has_no_padding_and_shift_not_clamped(self):
        off = fo.fov_off(1830)
        self.assertEqual(off['coded'], 1830)
        self.assertGreater(fo.fov_axis(0.5, 1.4, 3, 3648)['s'], 1.0)

    def test_float32_parameters(self):
        a = fo.fov_axis(0.449999988, 0, 3, 2912)
        self.assertEqual(a['coded'], 1856)
        self.assertEqual(round(a['opt']), 1844)


class MetaOption(Base):
    def meta(self, extra=None):
        m = {'tangents': [[-1.0, 1.0, -0.5625, 0.5625], [-1.0, 1.0, -0.5625, 0.5625]], 'renderEyeSize': [912, 728],
             'foveation': True, 'centerSize': [0.5, 0.449999988], 'centerShift': [0.25, -0.1], 'edgeRatio': [3, 3],
             'codedSize': [1216, 480]}
        m.update(extra or {})
        p = self.dir / 'meta.json'
        p.write_text(json.dumps(m))
        return p

    def test_render_with_meta(self):
        meta = self.meta()
        png = self.dir / 'r.png'
        self.assertEqual(fo.main(['synth', '--kind', 'render', '--render', '912x728', '--tangents', '1,1,0.5625,0.5625', '--eye', 'R', '--out-png', str(png)]), 0)
        code, j = self.measure('render', png, ['--meta', meta, '--eye', 'R'])
        self.assertEqual(code, 0)
        self.assertEqual(j['summary']['params']['render'], [912, 728])
        self.assertEqual(j['summary']['params']['fov_scale'], 1.0)

    def test_encoded_packed_both_eyes(self):
        args = ['--render', '912x728', '--tangents', '1,1,0.5625,0.5625', '--foveation', '0.5,0.449999988,3,3,0.25,-0.1']
        files = {}
        for eye in 'LR':
            files[eye] = self.dir / (eye + '.png')
            self.assertEqual(fo.main(['synth', '--kind', 'encoded', '--eye', eye, '--out-png', str(files[eye])] + args), 0)
        wl, hl, pl = fo.vc.read_png(files['L'])
        wr, hr, pr = fo.vc.read_png(files['R'])
        self.assertEqual((wl, hl), (wr, hr))
        packed = bytearray()
        for y in range(hl):
            packed += pl[y * wl * 4:(y + 1) * wl * 4] + pr[y * wl * 4:(y + 1) * wl * 4]
        pk = self.dir / 'encoder-input.png'
        fo.vc.write_png(pk, 2 * wl, hl, bytes(packed))
        meta = self.meta({'codedSize': [2 * wl, hl]})
        for eye in 'LR':
            code, j = self.measure('encoded', pk, ['--meta', meta, '--eye', eye], 'p' + eye)
            self.assertEqual(code, 0, j['summary']['verdict_reasons'])
            self.assertEqual(j['summary']['params']['region'], [0 if eye == 'L' else wl, 0, wl, hl])

    def test_meta_foveation_off(self):
        meta = self.meta({'foveation': False, 'codedSize': [1824, 728]})
        png = self.dir / 'r.png'
        self.assertEqual(fo.main(['synth', '--kind', 'render', '--render', '912x728', '--tangents', '1,1,0.5625,0.5625', '--out-png', str(png)]), 0)
        code, j = self.measure('encoded', png, ['--meta', meta])
        self.assertEqual(code, 0)
        self.assertEqual(j['summary']['params']['foveation'], 'off')


class Fix2(Base):
    RENDER = ['--render', '1824x1456']
    PAD = ['--foveation', '0.6,0.6,2.5,2.5,0.3,0.3']
    TAN = ['--tangents', '1.7321,1.0,0.3839,1.0']       # bottom edge 21 deg: the -20 deg line sits next to the padding

    def synth(self, kind, extra, name=None):
        png = self.dir / ((name or kind) + '.png')
        self.assertEqual(self.run_main(['synth', '--kind', kind, '--out-png', png] + list(extra)), 0)
        return png

    def test_padding_artefact_is_not_searched(self):
        for eye in 'LR':
            args = self.RENDER + self.PAD + self.TAN + ['--eye', eye]
            png = self.synth('encoded', args, 'pad' + eye)
            w, h, pix = fo.vc.read_png(png)
            yx = fo.parse_foveation(self.PAD[1], (1824, 1456))
            self.assertGreater(h, yx[1]['opt'] + 3)               # padding exists
            cy = int(yx[1]['opt']) + 8
            self.assertEqual(bytes(pix[(cy * w + 5) * 4:(cy * w + 5) * 4 + 3]), b'\xff\x00\xff')  # artefact present
            code, j = self.measure('encoded', png, args, 'pad' + eye)
            self.assertEqual(code, 0, (eye, j['summary']['verdict_reasons']))
            self.assertLess(j['summary']['axes']['y']['max_abs_residual_deg'], 0.5)

    def test_foveation_enabled_at_c1_pads(self):
        a = fo.fov_axis(1.0, 0.0, 3.0, 1824)
        self.assertEqual(a['coded'] % 32, 0)
        self.assertEqual(fo.fov_off(1830)['coded'], 1830)
        self.assertEqual(fo.parse_foveation('off', (1830, 1456))[0]['coded'], 1830)
        self.assertEqual(fo.parse_foveation('1,1,3,3,0,0', (1830, 1456))[0]['coded'], 1856)

    def test_stream_tangents_override(self):
        extra = ['--render', '912x728', '--fov-scale', '0.65', '--phys', '1216x1184']
        d = self.dir / 'cap'
        self.assertEqual(self.run_main(['synth', '--kind', 'drawable', '--out-dir', d] + extra), 0)
        base = ['--capture-dir', d, '--fov-scale', '0.9', '--render', '912x728']
        out = self.dir / 'w.json'
        self.run_main(['drawable', '--out-json', out] + base)
        self.assertEqual(json.loads(out.read_text())['summary']['verdict'], 'FAIL')
        tg = json.loads((d / 'capture.json').read_text())['slices'][0]['tangents']
        st = ','.join(repr(0.65 * v) for v in tg)
        self.run_main(['drawable', '--out-json', out, '--stream-tangents', st] + base)
        j = json.loads(out.read_text())
        self.assertEqual(j['summary']['verdict'], 'PASS', j['summary']['verdict_reasons'])



class DrawableExtent(Base):
    """Drawable mode is a valid check only when the stream extent is measured (r3 blocker 1) on sRGB-encoded pixels (W16)."""
    EXTRA = ['--render', '912x728', '--fov-scale', '0.65', '--phys', '1216x1184']
    BLACK, BG_L = bytes([0, 0, 0, 255]), bytes([15, 15, 31, 255])

    def capture(self, extra=None, repaint=(), encoding=None):
        d = self.dir / 'cap'
        self.assertEqual(self.run_main(['synth', '--kind', 'drawable', '--out-dir', d] + list(extra or self.EXTRA)), 0)
        cap = json.loads((d / 'capture.json').read_text())
        if encoding is not None:
            cap['encoding'] = encoding
        (d / 'capture.json').write_text(json.dumps(cap))
        png = d / cap['slices'][0]['png']
        w, h, pix = fo.vc.read_png(png)
        pix = bytes(pix)
        for a, b in repaint:
            pix = pix.replace(a, b)
        fo.vc.write_png(png, w, h, pix)
        return d

    def run_drawable(self, d, s='0.65', name='d'):
        out = self.dir / (name + '.json')
        code = self.run_main(['drawable', '--capture-dir', d, '--out-json', out, '--render', '912x728', '--fov-scale', s])
        return code, json.loads(out.read_text())['summary']

    def measured(self, s):
        return {k: v['measured_deg'] for k, v in s['stream_extent_deg'].items()}

    def test_lifted_surround_extents_are_measured_and_wrong_s_fails(self):
        d = self.capture(repaint=[(self.BLACK, bytes([10, 10, 10, 255]))])
        code, s = self.run_drawable(d)
        self.assertEqual(s['verdict'], 'PASS', s['verdict_reasons'])
        self.assertEqual(code, 0)
        for side, v in self.measured(s).items():
            self.assertIsNotNone(v, side)
            self.assertLessEqual(abs(s['stream_extent_deg'][side]['error_deg']), 0.5, side)
        for wrong in ('0.6', '0.7'):
            code, s = self.run_drawable(d, wrong, 'w' + wrong)
            self.assertEqual(s['verdict'], 'FAIL', wrong)
            self.assertNotEqual(code, 0)
            self.assertTrue(all(v is not None for v in self.measured(s).values()), (wrong, self.measured(s)))
            self.assertIn('stream extent', ' '.join(s['verdict_reasons']))

    def test_background_not_separable_is_unverified(self):
        d = self.capture(repaint=[(self.BLACK, self.BG_L)])
        code, s = self.run_drawable(d)
        self.assertEqual(s['verdict'], 'FAIL')
        self.assertIn('stream extent unverified', ' '.join(s['verdict_reasons']))
        self.assertTrue(all(v is None for v in self.measured(s).values()))
        self.assertNotEqual(code, 0)

    def test_extent_touching_the_crop_is_unverified(self):
        d = self.capture(['--render', '912x728', '--fov-scale', '1.2', '--phys', '1216x1184'])
        code, s = self.run_drawable(d, '1.2')
        self.assertEqual(s['verdict'], 'FAIL')
        self.assertIn('stream extent unverified', ' '.join(s['verdict_reasons']))

    def test_linear_capture_is_srgb_encoded_before_measuring(self):
        dim = [(self.BG_L, bytes([2, 2, 4, 255]))]       # a dim chart background as a linear-light capture holds it
        for enc in (None, 'linear'):
            d = self.capture(repaint=dim, encoding=enc)
            code, s = self.run_drawable(d)
            self.assertEqual(s['verdict'], 'PASS', (enc, s['verdict_reasons']))
            self.assertTrue(all(v is not None for v in self.measured(s).values()), enc)
            self.assertEqual(s['params']['encoding'], 'linear')
        d = self.capture(repaint=dim, encoding='srgb')   # the same counts declared sRGB are used as is: 4 counts, no separation
        code, s = self.run_drawable(d)
        self.assertEqual(s['verdict'], 'FAIL')
        self.assertIn('stream extent unverified', ' '.join(s['verdict_reasons']))
        self.assertEqual(s['params']['encoding'], 'srgb')

    def test_srgb_capture_round_trip(self):
        d = self.capture(self.EXTRA + ['--encoding', 'srgb'])
        self.assertEqual(json.loads((d / 'capture.json').read_text())['encoding'], 'srgb')
        code, s = self.run_drawable(d)
        self.assertEqual(s['verdict'], 'PASS', s['verdict_reasons'])
        self.assertTrue(all(v is not None for v in self.measured(s).values()))

    def test_bad_encoding_exits_2(self):
        d = self.capture(encoding='gamma')
        self.assertEqual(self.run_main(['drawable', '--capture-dir', d, '--render', '912x728', '--fov-scale', '0.65']), 2)


class ZoneStats(Base):
    """W16 defects A and B: one line set for measured and predicted; drawable resolvability in stream px; no mixed quantities."""
    EDGE = ['--render', '912x728', '--fov-scale', '0.6', '--phys', '2432x2368', '--foveation', '0.5,0.45,5,5,0,0']

    @staticmethod
    def line(resolvable, predicted):
        return {'resolvable': resolvable, 'psf_deg': 0.01 if resolvable else None, 'fwhm_deg': 0.1, 'nominal_width_deg': 0.08,
                'sharpness_px_per_deg': predicted * 0.9 if resolvable else None, 'measured_px': 1.0,
                'predicted_px_per_deg': predicted, 'local_px_per_deg': predicted * 2}

    def test_measured_and_predicted_share_the_line_set(self):
        z = fo.zone_stats([self.line(True, 10), self.line(True, 12), self.line(False, 100)])
        self.assertEqual(z['predicted_px_per_deg'], 11)            # the resolvable lines only; over all three it is 12
        self.assertAlmostEqual(z['sharpness_px_per_deg'], 9.9)
        self.assertEqual(z['predicted_px_per_deg_all'], 12)
        none = fo.zone_stats([self.line(False, 10), self.line(False, 12)])
        self.assertIsNone(none['predicted_px_per_deg'])
        self.assertIsNone(none['sharpness_px_per_deg'])

    def drawable(self):
        d = self.dir / 'cap'
        self.assertEqual(self.run_main(['synth', '--kind', 'drawable', '--out-dir', d] + self.EDGE), 0)
        out = self.dir / 'd.json'
        self.run_main(['drawable', '--capture-dir', d, '--out-json', out] + self.EDGE)
        return json.loads(out.read_text())

    def test_drawable_resolvability_is_judged_in_stream_pixels(self):
        lines = self.drawable()['lines']
        wide_in_drawable = [l for l in lines if l['fwhm_px'] is not None and l['nominal_width_px'] >= fo.MIN_RESOLVABLE_PX
                            and l['nominal_width_deg'] * l['predicted_px_per_deg'] < fo.MIN_RESOLVABLE_PX]
        self.assertTrue(wide_in_drawable)                          # lines the old drawable-pixel rule admitted
        self.assertTrue(all(not l['resolvable'] for l in wide_in_drawable))
        resolvable = [l for l in lines if l['resolvable']]
        self.assertTrue(resolvable)
        for l in resolvable:
            self.assertGreaterEqual(l['nominal_width_deg'] * l['predicted_px_per_deg'], fo.MIN_RESOLVABLE_PX)
        self.assertIn('nominal_width_stream_px', lines[0])

    def test_drawable_px_per_deg_is_labelled_and_kept_apart(self):
        j = self.drawable()
        for zone, z in j['summary']['zones'].items():
            if not z['n_predicted']:
                continue
            vals = sorted(l['local_px_per_deg'] for l in j['lines'] if l['zone'] == zone)
            self.assertAlmostEqual(z['drawable_px_per_deg'], (vals[(len(vals) - 1) // 2] + vals[len(vals) // 2]) / 2, places=6)
        png = self.dir / 'r.png'
        self.assertEqual(self.run_main(['synth', '--kind', 'render', '--render', '912x728', '--out-png', png]), 0)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.run_main(['render', '--image', png, '--render', '912x728', '--out-json', self.dir / 'r.json'])
        self.assertNotIn('drawable px/deg', buf.getvalue())
        self.assertIsNone(json.loads((self.dir / 'r.json').read_text())['summary']['zones']['band']['drawable_px_per_deg'])
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.run_main(['drawable', '--capture-dir', self.dir / 'cap', '--out-json', self.dir / 'd2.json'] + self.EDGE)
        self.assertIn('drawable px/deg', buf.getvalue())
        self.assertIn('stream px/deg', buf.getvalue())


class PoseDelta(Base):
    """capture.json pose.delta_deg (display minus render, right-handed, yaw +Y, pitch +X, roll +Z, intrinsic Y-X-Z)."""
    EXTRA = ['--render', '912x728', '--fov-scale', '0.65', '--phys', '1216x1184']

    def test_conventions(self):
        yaw = fo.Pose(10, 0, 0)
        self.assertAlmostEqual(yaw.warp('x', 0.0), math.tan(math.radians(10)), places=9)     # straight ahead shows to the right
        self.assertAlmostEqual(yaw.warp('x', math.tan(math.radians(20))), math.tan(math.radians(30)), places=9)
        pitch = fo.Pose(0, 10, 0)
        self.assertAlmostEqual(pitch.warp('y', 0.0), math.tan(math.radians(10)), places=9)   # display pitched up: ahead shows lower
        for p in (fo.Pose(3, -2, 1), fo.Pose(0.4, 0.2, 0.3)):
            for axis in 'xy':
                for tau in (-1.2, -0.3, 0.0, 0.7):
                    self.assertAlmostEqual(p.warp(axis, p.warp(axis, tau), inverse=True), tau, places=9)
        m = fo.Pose(90, 90, 0).matrix                      # intrinsic Y-X-Z: Ry(90) Rx(90) applied to forward (0, 0, -1)
        v = [sum(m[i][j] * (0, 0, -1)[j] for j in range(3)) for i in range(3)]
        self.assertEqual([round(c, 9) for c in v], [0.0, 1.0, 0.0])

    def synth(self, pose, drop=False):
        d = self.dir / 'cap'
        self.assertEqual(self.run_main(['synth', '--kind', 'drawable', '--out-dir', d, '--pose-delta', pose] + self.EXTRA), 0)
        cap = json.loads((d / 'capture.json').read_text())
        if drop:
            del cap['pose']
            (d / 'capture.json').write_text(json.dumps(cap))
        return d

    def measure(self, d, name='p'):
        out = self.dir / (name + '.json')
        code = self.run_main(['drawable', '--capture-dir', d, '--out-json', out, '--render', '912x728', '--fov-scale', '0.65'])
        return code, json.loads(out.read_text())['summary']

    def test_pose_in_capture_json_is_compensated(self):
        d = self.synth('0.4,0.25,0.3')
        self.assertEqual(json.loads((d / 'capture.json').read_text())['pose']['delta_deg'], {'yaw': 0.4, 'pitch': 0.25, 'roll': 0.3})
        code, s = self.measure(d)
        self.assertEqual(s['verdict'], 'PASS', s['verdict_reasons'])
        self.assertEqual(code, 0)
        self.assertLessEqual(s['median_abs_residual_deg'], 0.05)
        self.assertEqual(s['params']['pose']['source'], 'capture.json')
        self.assertIsNone(s.get('fitted_yaw_deg'))

    def test_wrong_pose_fails(self):
        d = self.synth('0.4,0,0')
        cap = json.loads((d / 'capture.json').read_text())
        cap['pose']['delta_deg']['yaw'] = 0.0                  # the capture claims no pose difference but the image carries 0.4 deg
        (d / 'capture.json').write_text(json.dumps(cap))
        code, s = self.measure(d)
        self.assertEqual(s['verdict'], 'FAIL')
        self.assertIn('x median residual', ' '.join(s['verdict_reasons']))
        self.assertNotEqual(code, 0)

    def test_no_pose_falls_back_to_fitted_yaw_and_says_so(self):
        d = self.synth('0.4,0,0', drop=True)
        code, s = self.measure(d)
        self.assertEqual(s['verdict'], 'PASS-after-fitted-yaw', s['verdict_reasons'])
        self.assertEqual(code, 0)
        self.assertAlmostEqual(s['fitted_yaw_deg'], 0.4, delta=0.05)
        self.assertEqual(s['params']['pose']['source'], 'fitted-yaw')
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.run_main(['drawable', '--capture-dir', d, '--render', '912x728', '--fov-scale', '0.65'])
        self.assertIn('PASS-after-fitted-yaw', buf.getvalue())
        self.assertRegex(buf.getvalue(), r'fitted yaw 0\.[34]\d* deg')

    def test_fitted_yaw_does_not_hide_a_wrong_s(self):
        d = self.synth('0.4,0,0', drop=True)
        out = self.dir / 'w.json'
        code = self.run_main(['drawable', '--capture-dir', d, '--out-json', out, '--render', '912x728', '--fov-scale', '0.6'])
        self.assertEqual(json.loads(out.read_text())['summary']['verdict'], 'FAIL')
        self.assertNotEqual(code, 0)

    def test_bad_pose_exits_2(self):
        d = self.synth('0,0,0')
        cap = json.loads((d / 'capture.json').read_text())
        cap['pose'] = {'delta_deg': {'yaw': 'left', 'pitch': 0, 'roll': 0}}
        (d / 'capture.json').write_text(json.dumps(cap))
        self.assertEqual(self.run_main(['drawable', '--capture-dir', d, '--render', '912x728', '--fov-scale', '0.65']), 2)


REAL = Path('/Users/noel/Projects/Management/goals/rdr2-vr/evidence/chart-matrix-20261022/m1/f100-asrun/dump')


@unittest.skipUnless((REAL / 'meta.json').exists(), 'real sample not present')
class RealSample(Base):
    def check(self, point):
        d = REAL.parent.parent / point / 'dump'
        if not (d / 'meta.json').exists():
            self.skipTest('no ' + point)
        for eye in 'LR':
            code, j = self.measure('render', d / ('chart-%s.png' % eye), ['--meta', d / 'meta.json', '--eye', eye], point + 'r' + eye)
            self.assertEqual(code, 0, (point, eye, j['summary']['verdict_reasons']))
            code, j = self.measure('encoded', d / 'encoder-input.png', ['--meta', d / 'meta.json', '--eye', eye], point + 'e' + eye)
            self.assertEqual(code, 0, (point, eye, j['summary']['verdict_reasons']))
            self.assertLessEqual(j['summary']['median_abs_residual_deg'], 0.05)

    def test_render_and_encoded_both_eyes_pass(self):
        self.check('f100-asrun')

    def test_f070_wider(self):
        self.check('f070-wider')

    def test_f060_centred(self):
        self.check('f060-centred')

    def test_oneone(self):
        self.check('oneone')


M5 = REAL.parents[2] / 'm5' / 'f100-asrun'


@unittest.skipUnless((M5 / 'dump' / 'meta.json').exists() and (M5 / 'capture' / 'capture.json').exists(), 'm5 sample not present')
class RealM5(Base):
    """W16 on the simulator proof data (read only): the encoder edge zone matches its prediction, the drawable extents are
    measured or unverified, never a chart line mistaken for the border."""

    def test_encoder_edge_zone_ratio(self):
        for eye in 'LR':
            code, j = self.measure('encoded', M5 / 'dump' / 'encoder-input.png', ['--meta', M5 / 'dump' / 'meta.json', '--eye', eye], eye)
            edge = j['summary']['zones']['edge']
            self.assertTrue(edge['n_resolvable'], eye)
            self.assertAlmostEqual(edge['sharpness_px_per_deg'] / edge['predicted_px_per_deg'], 1.0, delta=0.1, msg=eye)

    def test_drawable_extent_is_measured_or_unverified(self):
        out = self.dir / 'd.json'
        args = ['drawable', '--capture-dir', M5 / 'capture', '--fov-scale', '1.0', '--render', '3648x2912', '--foveation', '0.5,0.449999988,3,3,0,0',
                '--out-json', out]
        self.run_main(args)
        s = json.loads(out.read_text())['summary']
        for side, e in s['stream_extent_deg'].items():
            self.assertTrue(e['measured_deg'] is None or abs(e['error_deg']) <= 0.5, (side, e))
        if any(e['measured_deg'] is None for e in s['stream_extent_deg'].values()):
            self.assertIn('stream extent unverified', ' '.join(s['verdict_reasons']))
        self.assertAlmostEqual(s['fitted_yaw_deg'], -0.385, delta=0.05)


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
