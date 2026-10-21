"""Synthetic contract tests; no headset, network, or third-party modules."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name('diag-report.py')
spec = importlib.util.spec_from_file_location('diag_report', SCRIPT)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def render(self, lines, sender=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'diag-a.log').write_text(lines, encoding='utf-8')
            path = None
            if sender is not None:
                path = root / 'sender.jsonl'
                path.write_text(sender, encoding='utf-8')
            return report.generate(root, path)

    def test_every_section_and_contract_numbers(self):
        lines = '''DIAG m1 t_ms=10 os="Version 27 (Build X)" model=VisionPro app=42 eligible_for_hdr_playback=true
DIAG m1_config t_ms=11 color_formats=rgba16Float,rgb10a2Unorm chosen_color=rgba16Float default_render_quality=0.75 max_render_quality=1
DIAG codec t_ms=12 type=hevc hw=true
DIAG codec t_ms=13 type=hevc chroma=422 bit_depth=10 session=-12909
DIAG m5 t_ms=14 drawables=1 render_quality=0.75 max_render_quality=1
DIAG m5_view t_ms=15 drawable=0 view=1 tex_w=3648 tex_h=2912 tex_array=2 tex_format=rgba16Float
DIAG m5_vrr t_ms=16 drawable=0 map=0 screen=3648x2912 physical=2000x1800
DIAG rq t_ms=17 default=0.75 max=1
DIAG rq t_ms=18 step=0.5 actual=0.5 drawable=0 view=1 tex_w=1824 tex_h=1456 gpu_ms_p50=3 gpu_ms_p99=6 missed_deadlines=2 footprint_mb=512
DIAG m6 t_ms=20 target_interval_p50_ms=11.111 target_interval_p95_ms=11.112 frames=90 fresh=80 repeated=9 blank=1 missed_render_deadline=2
DIAG m9 t_ms=21 thermal=nominal phys_footprint=1024 gpu_p50_ms=3 gpu_p95_ms=5
DIAG m9 t_ms=22 thermal=serious phys_footprint=2048 gpu_p50_ms=4 gpu_p95_ms=7
DIAG edr t_ms=23 step=7 value=2 layout=10% mode=auto hold_s=60
DIAG edr t_ms=24 mark=true value=2 layout=10%
DIAG pq t_ms=25 clip=pq-steps.mov path=window current_s=2 step=1 rate=1 waiting=none
DIAG decode t_ms=26 clip=packed.mov sessions=2 mode=max width=7296 height=2912 source_fps=90 fps=180 mpix_s=3824 lat_p50_ms=3 lat_p95_ms=7 dropped=0 hw=true err=0
DIAG net t_ms=27 mode=tcp summary=true seconds=10 active_seconds=8 mbps=701 bytes=701000000
DIAG corner t_ms=28 eye=L pos_deg=22.5 ring_pct=95 tan_x=0.9 tan_y=0.4
DIAG corner_summary t_ms=29 eye=L r=1,1.1,1.2 axis_r=1 diag_r=1.2 shape=rounded_rectangle superellipse_n=4 area_frac=0.87
DIAG eye_badge t_ms=30 mismatch=1 view=0 x=0.03
DIAG diag t_ms=31 file_recovered=true dropped_lines=7
'''
        out = self.render(lines)
        for title in report.SECTIONS:
            self.assertIn('## ' + title, out)
        for value in ['Version 27 (Build X)', 'rgb10a2Unorm', '-12909', '3648',
                      '2000x1800', '512', '11.111', 'serious', '2048',
                      'pq-steps.mov', '3824', '701', '22.5', 'rounded_rectangle',
                      '0.87', 'dropped_lines=7', 'diag-a.log:1']:
            self.assertIn(value, out)
        self.assertIn('footprint bytes min=1024 max=2048', out)
        self.assertIn('hold_s=60 (from diag-a.log:13)', out)
        self.assertIn('90 Hz: PASS', out)
        self.assertIn('96 Hz: FAIL', out)
        self.assertIn('100 Hz: FAIL', out)
        self.assertIn('Highest passing', out)
        self.assertIn('histogram: no data', out)
        self.assertIn('GPU p99: no data', out)

    def test_empty_and_partial(self):
        out = self.render('')
        self.assertEqual(out.count('Sources: no data'), len(report.SECTIONS))
        self.assertNotIn('PASS', out)
        out = self.render('DIAG decode t_ms=1 clip=a err="session failed"\n')
        self.assertIn('session failed', out)
        self.assertIn('90 Hz: FAIL', out)
        self.assertIn('Highest passing: no data', out)

    def test_escaping_and_malformed_count(self):
        out = self.render('DIAG pq t_ms=1 clip="a b.mov" error="a\\\\b\\nline\\t\\\"q\\\"=x|y"\n'
                          'noise\nDIAG pq t_ms=x clip=a\nDIAG pq t_ms=2 x="open\n'
                          'DIAG pq t_ms=3 x=1 x=2\nDIAG pq t_ms=4 broken\n')
        self.assertIn('a b.mov', out)
        self.assertIn('malformed lines skipped=5', out)
        self.assertIn('diag-a.log:6', out)
        self.assertIn('x&#124;y', out)

    @staticmethod
    def ladder(steps, packets=1000, fps=100):
        metadata = dict(start_wall=1792589933.874, host='headset', port=9944,
                        fps=fps, packet_size=1200)
        records = [metadata]
        for start, duration, rate in steps:
            records.append(dict(t_start_s=start, mbps_req=rate, sent_mbps=rate - 1,
                                late_frames=0, send_errors=0, frames=round(duration * fps),
                                elapsed_s=duration))
        records.append(dict(total_s=steps[-1][0] + steps[-1][1], packets=packets,
                            frames=sum(row['frames'] for row in records[1:])))
        return '\n'.join(json.dumps(row) for row in records)

    @staticmethod
    def sink(end, byte_count, loss, reorder, tail=1, summary=False, listener_idle=5):
        return ('DIAG net t_ms={} mode=udp summary={} seconds={} active_seconds={} '
                'bytes={} mbps=999 loss={} reorder={} duplicates=0 stale=0 invalid=0 '
                'foreign=0 frame_complete={} jitter_ms=0.2 hist_overflow=0 '
                'spread_p99_ms={}\n').format(
                    round((listener_idle + end) * 1000), str(summary).lower(),
                    listener_idle + end, end, byte_count, loss, reorder, round(end * 100), tail)

    def test_actual_sender_sample_is_accepted(self):
        path = SCRIPT.with_name('fixtures') / 'netladder-sample.jsonl'
        records, bad = report.read_sender(path)
        self.assertEqual(bad, [])
        self.assertEqual(len(records), 5)
        self.assertEqual([row['fields'].get('mbps_req') for row in records[1:-1]], [100, 200, 300])
        out = self.render('', path.read_text())
        self.assertIn('Step 3', out)
        self.assertIn('malformed sender lines skipped=0', out)
        self.assertIn('62640', out)
        self.assertIn('1792589933.8743958', out)

    def test_continuous_ladder_differences_counters_and_aligns_time(self):
        # Five seconds of listener idle must not shift step 1 to step 3.
        sender = self.ladder([(0, 2, 50), (2, 2, 100)])
        lines = (self.sink(1, 5000000, 1, 2) + self.sink(2, 10000000, 3, 5) +
                 self.sink(3, 20000000, 4, 6) + self.sink(4, 30000000, 7, 10) +
                 self.sink(4, 30000000, 7, 10, summary=True))
        out = self.render(lines, sender)
        first = out.split('### Step 1')[1].split('### Step 2')[0]
        second = out.split('### Step 2')[1].split('Knee:')[0]
        self.assertIn('requested=50 Mb/s', first)
        self.assertIn('received=40 Mb/s', first)
        self.assertIn('loss_delta=3', first)
        self.assertIn('reorder_delta=5', first)
        self.assertIn('requested=100 Mb/s', second)
        self.assertIn('received=80 Mb/s', second)
        self.assertIn('loss_delta=4', second)
        self.assertIn('reorder_delta=5', second)
        self.assertIn('completion_p99_ms=no data', second)
        self.assertIn('loss_pct=no data', second)
        self.assertIn('jitter_ms=no data', second)
        self.assertNotIn('Step 3', out)
        self.assertIn('Knee: no data', out)

    def test_crossing_intervals_are_not_prorated(self):
        lines = (self.sink(1, 5000000, 1, 2) + self.sink(2, 10000000, 3, 5) +
                 self.sink(3, 20000000, 4, 6) + self.sink(4, 30000000, 7, 10, summary=True))
        out = self.render(lines, self.ladder([(0, 1.5, 50), (1.5, 2.5, 100)]))
        self.assertIn('crosses step boundary', out)
        self.assertIn('coverage_s=0..1', out)
        self.assertIn('coverage_s=2..4', out)
        self.assertIn('whole_step=false', out)
        self.assertIn('Knee: no data', out)

    def test_m8_knee_loss_threshold_in_isolation(self):
        # A single-step ladder has the footer packet denominator and a matching
        # cumulative percentile scope. Keep the other criterion passing.
        for loss, expected in [(0, '50 Mb/s'), (1, '50 Mb/s'), (2, 'no data')]:
            with self.subTest(loss=loss):
                out = self.render(self.sink(2, 10000000, loss, 0, tail=1, summary=True),
                                  self.ladder([(0, 2, 50)]))
                self.assertIn('Knee: ' + expected, out)

    def test_m8_knee_deadline_threshold_in_isolation(self):
        # Zero loss, 100 Hz: <=10 ms passes; 10.001 ms alone must fail.
        for tail, expected in [(9, '50 Mb/s'), (10, '50 Mb/s'), (10.001, 'no data')]:
            with self.subTest(tail=tail):
                out = self.render(self.sink(2, 10000000, 0, 0, tail=tail, summary=True),
                                  self.ladder([(0, 2, 50)]))
                self.assertIn('Knee: ' + expected, out)

    def test_missing_data_and_ambiguous_runs_do_not_pass(self):
        sender = self.ladder([(0, 2, 50)])
        baseline = self.sink(2, 10000000, 0, 0, summary=True)
        for line in [baseline.replace('spread_p99_ms=1', 'spread_p99_ms=nan'),
                     baseline.replace('hist_overflow=0', 'hist_overflow=1'),
                     baseline.replace('summary=true', 'summary=false'),
                     baseline.replace('frame_complete=200', 'frame_complete=0'),
                     baseline.replace('active_seconds=2', 'active_seconds=unavailable'),
                     baseline + baseline]:
            with self.subTest(line=line):
                self.assertIn('Knee: no data', self.render(line, sender))
        self.assertIn('Knee: no data', self.render(baseline, sender.replace('"send_errors": 0', '"send_errors": 1')))
        self.assertIn('Knee: no data', self.render(baseline, '\n'.join(sender.splitlines()[:-1])))
        self.assertIn('Knee: no data', self.render(baseline))

    def test_sender_malformed_and_wrong_schema(self):
        sender = self.ladder([(0, 2, 50)])
        out = self.render('', sender + '\ngarbage\n[]\n{"fps": NaN}\n{"mode":"udp","mbps":50}\n')
        self.assertIn('malformed sender lines skipped=4', out)
        self.assertIn('sender alignment disabled', out)

    def test_ladder_sender_schedule_and_json_without_network(self):
        from unittest import mock
        import contextlib
        import io
        ladder_path = SCRIPT.with_name('netprobe-ladder.py')
        ladder_spec = importlib.util.spec_from_file_location('netprobe_ladder', ladder_path)
        ladder = importlib.util.module_from_spec(ladder_spec)
        ladder_spec.loader.exec_module(ladder)
        clock, sent, sent_at = [0.0], [], []
        sock = mock.MagicMock()
        sock.__enter__.return_value = sock

        def send(data):
            sent.append(data)
            sent_at.append(clock[0])
            return len(data)

        sock.send.side_effect = send
        output = io.StringIO()
        with mock.patch.object(ladder.socket, 'socket', return_value=sock) as factory, \
                mock.patch.object(ladder.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(ladder.time, 'monotonic_ns', side_effect=lambda: round(clock[0] * 1e9)), \
                mock.patch.object(ladder.time, 'time', return_value=123), \
                mock.patch.object(ladder.time, 'sleep', side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)), \
                contextlib.redirect_stdout(output):
            self.assertEqual(ladder.main(['headset', '9944', '0.032,0.064', '1', '4', '1200']), 0)
        factory.assert_called_once()
        sock.connect.assert_called_once_with(('headset', 9944))
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(rows[0], dict(start_wall=123, host='headset', port=9944, fps=4, packet_size=1200))
        self.assertEqual([row['t_start_s'] for row in rows[1:-1]], [0, 0.75])
        self.assertEqual([row['frames'] for row in rows[1:-1]], [4, 4])
        self.assertEqual([row['elapsed_s'] for row in rows[1:-1]], [0.75, 0.75])
        self.assertEqual([row['mbps_req'] for row in rows[1:-1]], [0.032, 0.064])
        self.assertTrue(all(row['send_errors'] == 0 and row['late_frames'] == 0 for row in rows[1:-1]))
        self.assertEqual(rows[-1], dict(total_s=1.5, packets=12, frames=8))
        self.assertEqual(rows[1]['sent_mbps'], round(4000 * 8 / 0.75 / 1e6, 1))
        self.assertEqual(rows[2]['sent_mbps'], round(8000 * 8 / 0.75 / 1e6, 1))
        headers = [ladder.np.HEADER.unpack(data[:28]) for data in sent]
        self.assertEqual([h[1] for h in headers], list(range(12)))
        self.assertEqual([h[3] for h in headers], [0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 7, 7])
        self.assertEqual(sent_at, [0, 0.25, 0.5, 0.75, 0.75, 0.75, 1, 1, 1.25, 1.25, 1.5, 1.5])

    def test_decode_no_false_pass_and_aggregate_sessions(self):
        template = ('DIAG decode t_ms=1 clip=a sessions=2 mode=paced width=10 height=20 '
                    'source_fps=100 fps=190 mpix_s=0.038 lat_p50_ms=1 lat_p95_ms=2 '
                    'dropped={} hw={} err={}\n')
        out = self.render(template.format(0, 'true', 0))
        self.assertIn('90 Hz: PASS', out)
        self.assertIn('96 Hz: FAIL', out)
        for values in [(1, 'true', 0), (0, 'false', 0), (0, 'true', -3)]:
            out = self.render(template.format(*values))
            self.assertNotIn('90 Hz: PASS', out)
            self.assertIn('Highest passing: no data', out)

    def test_corner_spokes_and_codec_hardware_attribution(self):
        lines = ('DIAG codec t_ms=1 type=hevc hw=true\n'
                 'DIAG codec t_ms=2 type=hevc chroma=420 bit_depth=10 session=ok\n')
        for eye in ('L', 'R'):
            for spoke in range(16):
                lines += 'DIAG corner t_ms=3 eye={} pos_deg={} ring_pct=90\n'.format(eye, spoke * 22.5)
            lines += ('DIAG corner_summary t_ms=4 eye={} r={} shape=ellipse '
                      'superellipse_n=2 area_frac=0.78\n').format(eye, ','.join(['1'] * 16))
        out = self.render(lines)
        self.assertIn('| hevc | 420 | 10 | true | ok |', out)
        self.assertIn('| L | 337.5 | 90 | 1 | ellipse | 2 | 0.78 |', out)
        self.assertIn('| R | 337.5 | 90 | 1 | ellipse | 2 | 0.78 |', out)

    def test_no_inference_across_sessions_or_bad_sender_alignment(self):
        lines = ('DIAG edr t_ms=1 step=1 value=2 layout=10% hold_s=60\n'
                 'DIAG m1 t_ms=2 app=2\n'
                 'DIAG edr t_ms=3 mark=true value=2 layout=10%\n'
                 'DIAG net t_ms=4 mode=udp summary=true mbps=50 loss=0 '
                 'frame_complete=100 spread_p99_ms=1\n')
        out = self.render(lines, 'broken\n' + self.ladder([(0, 2, 50)]))
        self.assertIn('Threshold diag-a.log:3: value=2 layout=10% hold_s=no data', out)
        self.assertIn('Knee: no data', out)
        self.assertIn('sender alignment disabled', out)

    def test_rotation_order_and_invalid_utf8(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for suffix, timestamp in [('', 1), ('-1', 2), ('-2', 3), ('-10', 4)]:
                (root / ('diag-20261021T120000Z' + suffix + '.log')).write_text(
                    'DIAG pq t_ms={} clip=x step={}\n'.format(timestamp, timestamp))
            parsed, bad, errors = report.read_logs(root)
            self.assertEqual([r['t_ms'] for r in parsed], [1, 2, 3, 4])
            self.assertEqual(bad, [])
            (root / 'diag-z.log').write_bytes(b'\xff\nDIAG pq t_ms=5 clip="valid = clip.mov"\n')
            out = report.generate(root)
            self.assertIn('malformed lines skipped=1', out)
            self.assertIn('valid = clip.mov', out)

    def test_multiple_files_cli_and_determinism(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'diag-b.log').write_text('DIAG m1 t_ms=30 app=2\n')
            (root / 'diag-a.log').write_text('DIAG m1 t_ms=10 app=1\n')
            (root / 'ignore.log').write_text('bad\n')
            self.assertEqual(report.generate(root), report.generate(root))
            out = subprocess.check_output([sys.executable, str(SCRIPT), directory], text=True)
            self.assertIn('| m1 | 10 | 30 | 2 |', out)
            target = root / 'report.md'
            subprocess.check_call([sys.executable, str(SCRIPT), directory, '-o', str(target)])
            self.assertEqual(out, target.read_text())
            subprocess.check_call([sys.executable, str(SCRIPT), '--help'], stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    unittest.main()
