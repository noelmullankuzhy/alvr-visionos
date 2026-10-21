"""Tests for fovmatrix.py (settings mapping, points parsing, dump classification, stats, summary row)."""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('fovmatrix', os.path.join(HERE, 'fovmatrix.py'))
fm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fm)

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

    def test_missing_files(self):
        s = fm.stats('/nonexistent/a', '/nonexistent/b')
        self.assertIsNone(s['encode_ms'])
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
            wj(os.path.join(d, 'stats.json'), {'encode_ms': 9.0, 'bitrate_mbps': 498.4, 'client_fps': 89.5, 'decode_ms': 7.0})

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
