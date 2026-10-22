"""Tests for the device ladder parts of fovmatrix.py: encode_nvenc_ms from StatisticsSummary, the device telemetry
(Documents/telemetry/*.jsonl stats records), the ladder row and pass rule, and points-device-ladder.tsv."""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('fovmatrix', os.path.join(HERE, 'fovmatrix.py'))
fm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fm)

CROP_TANGENTS = 'L:1.0913,0.6371,0.7674,0.6371;R:0.6371,1.0913,0.7674,0.6371'


def wj(path, obj):
    with open(path, 'w') as f:
        json.dump(obj, f)


def write_lines(path, lines):
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')


def graph(**kw):
    base = {'encoder_s': 0.009, 'bitrate_bps': 500e6, 'client_fps': 90.0, 'decoder_s': 0.005}
    base.update(kw)
    return json.dumps({'event_type': {'id': 'GraphStatistics', 'data': base}})


def summary(**kw):
    data = {'video_packets_total': 350, 'video_mbits_per_sec': 300.0, 'encode_latency_ms': 9.5, 'client_fps': 90, 'server_fps': 90}
    data.update(kw)
    return json.dumps({'timestamp': '14:51:22.853', 'event_type': {'id': 'StatisticsSummary', 'data': data}})


def dev(**kw):
    base = {'type': 'stats', 't': 1.0, 'window_s': 1.0, 'frames_received': 90, 'frames_decoded': 90, 'frames_dropped': 0,
            'dropped_before_decode': 0, 'dropped_decode_overrun': 0, 'dropped_queue_overflow': 0, 'dropped_selection_skip': 0,
            'presented_fps': 90.0, 'decode_ms_mean': 6.0, 'decode_ms_p95': 8.0}
    base.update(kw)
    return json.dumps(base)


class NvencStatsTest(unittest.TestCase):
    def test_nvenc_mean_p95_and_latency(self):
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, 'events.jsonl')   # 20 summaries: 18 x 7 ms, 2 x 10 ms; plus one without the field (old server)
            write_lines(ev, [summary(encode_nvenc_ms=7.0) for _ in range(18)] + [summary(encode_nvenc_ms=10.0)] * 2 + [summary()])
            s = fm.stats(ev, '/nonexistent')
            self.assertAlmostEqual(s['encode_nvenc_ms'], (18 * 7.0 + 20.0) / 20)
            self.assertAlmostEqual(s['encode_nvenc_p95'], 10.0)    # nearest rank: the 19th of 20
            self.assertAlmostEqual(s['encode_latency_ms'], 9.5)    # all 21 summaries
            self.assertAlmostEqual(s['server_mbps'], 300.0)

    def test_nvenc_absent_is_none(self):
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, 'events.jsonl')
            write_lines(ev, [summary(), graph()])
            s = fm.stats(ev, '/nonexistent')
            self.assertIsNone(s['encode_nvenc_ms'])
            self.assertIsNone(s['encode_nvenc_p95'])

    def test_summary_row_shows_nvenc(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, 'overlay'))
            wj(os.path.join(d, 'stats.json'), {'encode_nvenc_ms': 7.3, 'encode_nvenc_p95': 8.04})
            r = dict(zip(fm.SUMMARY_COLUMNS, fm.summary_row('a', d).split('\t')))
            self.assertEqual((r['encode_nvenc_ms'], r['encode_nvenc_p95']), ('7.30', '8.04'))


class DeviceStatsTest(unittest.TestCase):
    def test_select_last_n_stats_of_newest_file(self):
        with tempfile.TemporaryDirectory() as d:
            write_lines(os.path.join(d, '20261022T100000Z.jsonl'), [dev(decode_ms_mean=1.0)])
            new = os.path.join(d, '20261022T110000Z.jsonl')
            write_lines(new, [json.dumps({'type': 'format', 'renderer': 'metal'})]
                        + [dev(t=float(i), decode_ms_mean=float(i)) for i in range(10)] + ['garbage'])
            self.assertEqual(fm.newest_telemetry(d), new)
            got = fm.select_device_stats(d, 4)
            self.assertEqual([r['decode_ms_mean'] for r in got], [6.0, 7.0, 8.0, 9.0])
            self.assertEqual(len(fm.select_device_stats(d, 100)), 10)   # fewer than asked: all stats, no format line
            self.assertEqual(fm.select_device_stats(os.path.join(d, 'none'), 5), [])
            os.makedirs(os.path.join(d, 'empty'))
            self.assertIsNone(fm.newest_telemetry(os.path.join(d, 'empty')))

    def test_newest_telemetry_walks_into_the_copied_directory(self):
        with tempfile.TemporaryDirectory() as d:   # devicectl copies Documents/telemetry to DEST or DEST/telemetry
            sub = os.path.join(d, 'telemetry')
            os.makedirs(sub)
            write_lines(os.path.join(sub, '20261022T100000Z.jsonl'), [dev()])
            write_lines(os.path.join(sub, 'notes.jsonl'), [dev()])   # not a telemetry file name
            self.assertEqual(fm.newest_telemetry(d), os.path.join(sub, '20261022T100000Z.jsonl'))

    def test_since_ignores_a_stale_file(self):
        with tempfile.TemporaryDirectory() as d:
            write_lines(os.path.join(d, '20261022T100000Z.jsonl'), [dev()])
            self.assertIsNone(fm.newest_telemetry(d, '20261022T100500Z'))      # the earlier rung's file only
            self.assertEqual(fm.select_device_stats(d, 5, '20261022T100500Z'), [])
            write_lines(os.path.join(d, '20261022T101000Z.jsonl'), [dev()])
            self.assertEqual(os.path.basename(fm.newest_telemetry(d, '20261022T100500Z')), '20261022T101000Z.jsonl')
            self.assertEqual(os.path.basename(fm.newest_telemetry(d, '20261022T101000Z')), '20261022T101000Z.jsonl')   # boundary included

    def test_device_summary_by_hand(self):
        rows = [json.loads(dev(decode_ms_mean=6.0, decode_ms_p95=8.0, frames_received=90, frames_dropped=0, presented_fps=90.0)),
                json.loads(dev(decode_ms_mean=8.0, decode_ms_p95=12.0, frames_received=90, frames_dropped=3, presented_fps=88.0))]
        s = fm.device_summary(rows)
        self.assertAlmostEqual(s['decode_ms_mean'], 7.0)
        self.assertAlmostEqual(s['decode_ms_p95'], 12.0)       # nearest rank over the windows' p95: the 2nd of 2
        self.assertAlmostEqual(s['decode_ms_p95_max'], 12.0)
        self.assertEqual(s['dropped_total'], 3)
        self.assertAlmostEqual(s['dropped_pct'], 100.0 * 3 / 180)
        self.assertAlmostEqual(s['device_fps'], 89.0)
        self.assertEqual(s['device_n'], 2)

    def test_dropped_falls_back_to_the_four_counters(self):
        r = json.loads(dev(dropped_before_decode=1, dropped_decode_overrun=2, dropped_queue_overflow=3, dropped_selection_skip=4))
        del r['frames_dropped']
        self.assertEqual(fm.device_summary([r])['dropped_total'], 10)

    def test_optional_decode_fields_missing(self):
        r = json.loads(dev())
        del r['decode_ms_mean'], r['decode_ms_p95']
        s = fm.device_summary([r])
        self.assertIsNone(s['decode_ms_mean'])
        self.assertIsNone(s['decode_ms_p95'])
        self.assertEqual(fm.device_summary([])['device_n'], 0)
        self.assertIsNone(fm.device_summary([])['dropped_total'])


class LadderTest(unittest.TestCase):
    def test_pass_rule(self):
        self.assertEqual(fm.ladder_verdict(10.9, 0.99), 'PASS')
        self.assertEqual(fm.ladder_verdict(11.0, 0.0), 'FAIL')     # decode p95 must be < 11 ms
        self.assertEqual(fm.ladder_verdict(8.0, 1.0), 'FAIL')      # dropped must be < 1 %
        self.assertEqual(fm.ladder_verdict(None, 0.0), 'NO_DEVICE_STATS')
        self.assertEqual(fm.ladder_verdict(8.0, None), 'NO_DEVICE_STATS')

    def make(self, d, nvenc=True, device=True):
        write_lines(os.path.join(d, 'events.jsonl'),
                    [summary(encode_nvenc_ms=7.0 + i % 2, video_mbits_per_sec=298.0) if nvenc else summary(video_mbits_per_sec=298.0)
                     for i in range(10)] + [graph(encoder_s=0.011)])
        if device:   # 60 windows, p95 9.0 .. 14.9
            write_lines(os.path.join(d, 'device-stats.jsonl'), [dev(decode_ms_mean=6.0, decode_ms_p95=9.0 + i * 0.1) for i in range(60)])

    def test_row(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d)
            cols = fm.ladder_row('dC-p1-300', d).split('\t')
            self.assertEqual(len(cols), len(fm.LADDER_COLUMNS))
            r = dict(zip(fm.LADDER_COLUMNS, cols))
            self.assertEqual(r['name'], 'dC-p1-300')
            self.assertEqual(r['verdict'], 'FAIL')                  # p95 of the windows' p95 is the 57th: 14.6 ms
            self.assertEqual((r['encode_nvenc_ms'], r['encode_nvenc_p95']), ('7.50', '8.00'))
            self.assertEqual(r['encode_latency_ms'], '9.50')
            self.assertEqual(r['encode_ms'], '11.00')
            self.assertEqual((r['decode_ms_mean'], r['decode_ms_p95'], r['decode_ms_p95_max']), ('6.00', '14.60', '14.90'))
            self.assertEqual((r['dropped_total'], r['dropped_pct']), ('0', '0.00'))
            self.assertEqual((r['device_fps'], r['bitrate_mbps'], r['device_n']), ('90.0', '298.0', '60'))

    def test_row_pass(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d)
            write_lines(os.path.join(d, 'device-stats.jsonl'), [dev(decode_ms_p95=9.5) for _ in range(5)])
            self.assertEqual(dict(zip(fm.LADDER_COLUMNS, fm.ladder_row('x', d).split('\t')))['verdict'], 'PASS')

    def test_row_without_nvenc_or_device_stats(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, nvenc=False, device=False)
            r = dict(zip(fm.LADDER_COLUMNS, fm.ladder_row('x', d).split('\t')))
            self.assertEqual(r['verdict'], 'NO_DEVICE_STATS')
            self.assertEqual((r['encode_nvenc_ms'], r['decode_ms_p95'], r['dropped_total'], r['device_n']), ('n/a', 'n/a', 'n/a', '0'))

    def test_row_error_marker(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d)
            with open(os.path.join(d, 'ERROR'), 'w') as f:
                f.write('client never connected')
            r = dict(zip(fm.LADDER_COLUMNS, fm.ladder_row('x', d).split('\t')))
            self.assertEqual((r['verdict'], r['notes']), ('ERROR', 'client never connected'))

    def test_client_connected(self):
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, 'e.jsonl')
            write_lines(ev, [graph(), summary(client_fps=0, video_packets_total=0)])
            self.assertFalse(fm.client_connected(ev))
            write_lines(ev, [summary(client_fps=0), summary(client_fps=88)])
            self.assertTrue(fm.client_connected(ev))
            self.assertFalse(fm.client_connected('/nonexistent'))


class LadderPointsTest(unittest.TestCase):
    def test_points_file(self):
        pts = fm._points(os.path.join(HERE, 'points-device-ladder.tsv'))
        self.assertEqual([p['name'] for p in pts], ['dC-p1-100', 'dC-p1-300', 'dC-p1-500', 'dT-p1-100', 'dT-p1-300', 'dT-p1-500'])
        self.assertEqual([p['bitrate_mbps'] for p in pts], [100, 300, 500] * 2)
        for p in pts:
            self.assertEqual((p['fps'], p['render_scale'], p['fov_scale'], p['flag']), (90, 1.0877, 1, 'dump'))
            self.assertEqual(p['eye_tangents'], CROP_TANGENTS)
            sets = fm.session_sets(p)
            for want in ('video.encoder_config.nvenc.quality_preset={"variant":"P1"}',
                         'video.encoder_config.nvenc.multi_pass={"variant":"Disabled"}',
                         'video.encoder_config.nvenc.split_encode_mode={"variant":"ForceTwo"}',
                         'video.encoder_config.use_10bit=true', 'video.encoder_config.server_overrides_use_10bit=true', 'video.preferred_codec={"variant":"Hevc"}',
                         'video.transcoding_view_resolution.variant="Scale"',
                         'video.emulated_headset_view_resolution.variant="Scale"',
                         'video.transcoding_view_resolution.Scale=1.0', 'video.emulated_headset_view_resolution.Scale=1.0'):
                self.assertIn(want, sets, p['name'])
            for key in ('transcoding_view_resolution', 'emulated_headset_view_resolution'):   # apply order: the later set wins
                self.assertGreater(sets.index('video.%s.variant="Scale"' % key), sets.index('video.%s.variant="Absolute"' % key))
        self.assertEqual(pts[0]['foveation'], (0.5, 0.45, 3, 3, 0.526, -0.169))
        self.assertEqual(pts[3]['foveation'], (0.7026, 0.7431, 3, 3, 1, -0.053))
        self.assertEqual(pts[0]['foveation'], pts[2]['foveation'])
        self.assertEqual(pts[3]['foveation'], pts[5]['foveation'])


if __name__ == '__main__':
    unittest.main()
