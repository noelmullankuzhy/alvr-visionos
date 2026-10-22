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

    def test_zero_duration_final_update_is_not_lost(self):
        sender = self.ladder([(0, 2, 50)])
        lines = (self.sink(1, 5000000, 0, 0) + self.sink(2, 10000000, 0, 0) +
                 self.sink(2, 10000000, 2, 1, summary=True))
        out = self.render(lines, sender)
        self.assertIn('loss_delta=2', out)
        self.assertIn('reorder_delta=1', out)
        self.assertIn('Knee: no data', out)

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

    def test_ladder_send_errors_preserve_sequence_and_json_contract(self):
        from unittest import mock
        import contextlib
        import io
        ladder_spec = importlib.util.spec_from_file_location('netprobe_ladder', SCRIPT.with_name('netprobe-ladder.py'))
        ladder = importlib.util.module_from_spec(ladder_spec)
        ladder_spec.loader.exec_module(ladder)
        clock, attempted = [0.0], []
        sock = mock.MagicMock()
        sock.__enter__.return_value = sock

        def failed_send(data):
            attempted.append(data)
            raise OSError('synthetic send failure')

        sock.send.side_effect = failed_send
        output = io.StringIO()
        with mock.patch.object(ladder.socket, 'socket', return_value=sock),                 mock.patch.object(ladder.time, 'monotonic', side_effect=lambda: clock[0]),                 mock.patch.object(ladder.time, 'monotonic_ns', return_value=0),                 mock.patch.object(ladder.time, 'time', return_value=123),                 mock.patch.object(ladder.time, 'sleep', side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)),                 contextlib.redirect_stdout(output):
            ladder.main(['headset', '9944', '0.032,0.064', '1', '4', '1200'])
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([row['send_errors'] for row in rows[1:-1]], [4, 8])
        self.assertTrue(all(row['sent_mbps'] == 0 for row in rows[1:-1]))
        self.assertEqual(rows[-1]['packets'], 12)
        self.assertEqual([ladder.np.HEADER.unpack(data[:28])[1] for data in attempted], list(range(12)))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sender.jsonl'
            path.write_text(output.getvalue())
            parsed, bad = report.read_sender(path)
        self.assertEqual(bad, [])
        self.assertEqual(len(parsed), 4)

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

    def test_octagon_walk_and_raw_summary(self):
        lines = 'DIAG corner t_ms=1 chart=on\n'
        for eye in ('L', 'R'):
            for spoke in range(8):
                lines += ('DIAG corner t_ms=2 eye={} pos_deg={} ring_pct={} kind={} '
                          'tan_x=0.7 tan_y=0.7\n').format(eye, spoke * 45,
                            100 if spoke % 2 == 0 else 75, 'side' if spoke % 2 == 0 else 'cut')
            lines += ('DIAG corner_summary t_ms=3 eye={} shape=octagon marks=8 '
                      'sides=100,100,100,100 cuts=75,75,75,75 visible_area_frac=0.8750\n').format(eye)
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(lines)
            records, bad, errors = report.read_logs(Path(directory))
            rows = report.corner_rows(records)
        self.assertEqual(len(rows), 16)
        for eye in ('L', 'R'):
            walk = [r for r in rows if r['eye'] == eye]
            self.assertEqual([r['pos_deg'] for r in walk], [str(k * 45) for k in range(8)])
            self.assertEqual([r['kind'] for r in walk], ['side', 'cut'] * 4)
            self.assertTrue(all(r['sides'] == '100,100,100,100' and r['cuts'] == '75,75,75,75'
                                and r['visible_area_frac'] == '0.8750' for r in walk))
        out = self.render(lines)
        self.assertIn('| L | 315 | 75 |', out)
        self.assertIn('| R | 315 | 75 |', out)
        self.assertIn('kind', out)
        self.assertIn('cut', out)
        self.assertIn('100,100,100,100', out)
        self.assertIn('75,75,75,75', out)
        self.assertIn('0.8750', out)

    @staticmethod
    def rrm_lines(peaks, hashes=None, rq='1.000', fov='on', eye='L'):
        """One 20 s sweep: peaks maps fixation name -> (h_peak_deg, v_peak_deg)."""
        degrees = (-40, -30, -20, -10, -5, 0, 5, 10, 20, 30, 40)
        rates = ','.join('{}:{:.4f}'.format(d, 1 if abs(d) <= 10 else 0.5) for d in degrees)
        ppd = ','.join('{}:{:.2f}'.format(d, 40 if abs(d) <= 10 else 20 + d / 100) for d in degrees)
        fixes = [('centre', 0, 0), ('left20', -20, 0), ('right20', 20, 0), ('up15', 0, 15), ('down15', 0, -15)]
        lines = ''
        for s in range(20):
            name, x, y = fixes[s // 4]
            h, v = peaks[name]
            lines += ('DIAG rrm t_ms={t} phase=sweep s={s} fix={n} fix_x_deg={x} fix_y_deg={y} eye={e} drawable=0 view=0 '
                      'layer=0 rq={rq} fov={fov} map=ok screen=6261x5023 physical=2432x2368 viewport=0,0,6261,5023 '
                      'tan_left=1.7321 tan_right=1.0000 tan_bottom=1.1918 tan_top=1.0000 axis_x=3969.4 axis_y=2291.7 '
                      'logical_ppd_x=39.997 logical_ppd_y=39.998 h_rate={r} h_ppd={p} v_rate={r} v_ppd={p} '
                      'h_peak_deg={h} v_peak_deg={v} map_hash={hash}\n').format(
                          t=1000 + s * 1000, s=s, n=name, x=x, y=y, e=eye, rq=rq, fov=fov, r=rates, p=ppd,
                          h=h, v=v, hash=(hashes or {}).get(name, 'aaaa0001'))
        return lines

    def test_rate_map_profile_and_fixed_map_verdict(self):
        fixed = {name: (0.0, 0.0) for name in ('centre', 'left20', 'right20', 'up15', 'down15')}
        lines = 'DIAG grating t_ms=1 chart=on mode="Both eyes" foveation=on\n' + self.rrm_lines(fixed)
        lines += self.rrm_lines(fixed, eye='R')
        lines += ('DIAG rrm t_ms=30000 phase=quality s=0 fix=none fix_x_deg=0 fix_y_deg=0 eye=L drawable=0 view=0 layer=0 '
                  'rq=0.500 fov=on map=ok screen=4696x3767 physical=1952x1888 viewport=0,0,4696,3767 '
                  'h_rate=0:0.6000 h_ppd=0:18.00 v_rate=0:0.6000 v_ppd=0:18.00 h_peak_deg=0.0 v_peak_deg=0.0 map_hash=bbbb\n')
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(lines)
            records, bad, errors = report.read_logs(Path(directory))
            profiles = report.rrm_profiles(records)
            verdicts = report.rrm_gaze(records)
        self.assertEqual(bad, [])
        left = [r for r in profiles if r['eye'] == 'L' and r['rq'] == '1.000']
        self.assertEqual([r['line'] for r in left], ['h', 'v'])
        self.assertEqual(left[0]['0'], '40.00')
        self.assertEqual(left[0]['-40'], '19.60')
        self.assertEqual(left[0]['physical'], '2432x2368')
        half = [r for r in profiles if r['eye'] == 'L' and r['rq'] == '0.500']
        self.assertEqual(half[0]['0'], '18.00')
        self.assertEqual(half[0]['physical'], '1952x1888')
        self.assertEqual([v['eye'] for v in verdicts], ['L', 'R'])
        self.assertTrue(all(v['verdict'] == 'fixed' for v in verdicts))
        self.assertEqual(verdicts[0]['hashes'], 1)
        out = self.render(lines)
        self.assertIn('## Resolution measurement', out)
        self.assertIn('| L | 1.000 | on | h |', out)
        self.assertIn('fixed', out)

    def test_rate_map_follows_gaze_and_changes_without_gaze(self):
        follows = {'centre': (0.0, 0.0), 'left20': (-19.0, 0.0), 'right20': (21.0, 0.0),
                   'up15': (0.0, 14.0), 'down15': (0.0, -15.0)}
        hashes = {name: 'h' + name for name in follows}
        rows = None
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(self.rrm_lines(follows, hashes))
            records, _, _ = report.read_logs(Path(directory))
            rows = report.rrm_gaze(records)
        self.assertEqual(rows[0]['verdict'], 'follows gaze')
        self.assertEqual(rows[0]['hashes'], 5)
        self.assertIn('left20:-19/0', rows[0]['peaks'])
        unrelated = {name: (3.0 if name == 'up15' else 0.0, 0.0) for name in follows}
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(self.rrm_lines(unrelated, hashes))
            records, _, _ = report.read_logs(Path(directory))
            self.assertEqual(report.rrm_gaze(records)[0]['verdict'], 'changes, not with gaze')
            (Path(directory) / 'diag-a.log').write_text(self.rrm_lines(unrelated, hashes).replace('fix=left20', 'fix=centre')
                                                       .replace('fix=right20', 'fix=centre').replace('fix=up15', 'fix=centre')
                                                       .replace('fix=down15', 'fix=centre'))
            records, _, _ = report.read_logs(Path(directory))
            self.assertEqual(report.rrm_gaze(records)[0]['verdict'], 'no data')

    @staticmethod
    def grating_line(cpd, seen, rq, pos='axis', orient='V', fov='on', eye='both', nyquist=None, t=2):
        """nyquist None: a line without the Nyquist fields; else logical Nyquist with above_nyquist derived."""
        extra = ''
        if nyquist is not None:
            extra = 'nyquist_logical_cpd={:.2f} above_nyquist={} '.format(nyquist, 'yes' if cpd > nyquist * 1.001 else 'no')
        return ('DIAG grating t_ms={} eye={} pos={} cpd={} orient={} seen={} rq={} rq_set={} fov={} {}'
                'temporal_deg=0.0 up_deg=1.0 size_deg=1.5\n').format(t, eye, pos, cpd, orient, seen, rq, rq, fov, extra)

    def test_grating_finest_seen_per_quality_and_foveation(self):
        lines = 'DIAG grating t_ms=1 chart=on mode="Both eyes" foveation=on\n'
        for rq, nyquist in (('0.500', 15.0), ('1.000', 20.0)):
            for cpd in (8, 10, 12, 14, 17, 20):
                seen = 'yes' if cpd <= (12 if rq == '0.500' else 14) else 'no'
                lines += self.grating_line(cpd, seen, rq, nyquist=nyquist)
        # A redo of the same patch replaces the earlier judgment.
        lines += self.grating_line(17, 'yes', '1.000', nyquist=20.0, t=3)
        lines += self.grating_line(8, 'no', '1.000', pos='temporal20', orient='H', fov='off', nyquist=22.6, t=4)
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(lines)
            records, _, _ = report.read_logs(Path(directory))
            rows = report.grating_rows(records)
        key = {(r['rq'], r['fov'], r['pos'], r['orient']): r for r in rows}
        self.assertEqual(key[('0.500', 'on', 'axis', 'V')]['finest_seen_cpd'], 12)
        self.assertEqual(key[('1.000', 'on', 'axis', 'V')]['finest_seen_cpd'], 17)
        self.assertEqual(key[('1.000', 'on', 'axis', 'V')]['judged'], 6)
        self.assertEqual(key[('1.000', 'on', 'axis', 'V')]['nyquist_logical_cpd'], '20.00')
        self.assertIsNone(key[('1.000', 'off', 'temporal20', 'H')]['finest_seen_cpd'])
        out = self.render(lines)
        self.assertIn('| both | 1.000 | on | axis | V | 17 |', out)
        self.assertIn('| both | 1.000 | off | temporal20 | H | no data |', out)

    def test_grating_above_nyquist_listed_separately_never_finest(self):
        lines = 'DIAG grating t_ms=1 chart=on mode="Both eyes" foveation=on\n'
        for cpd in (8, 10, 12, 14, 17, 20):
            lines += self.grating_line(cpd, 'yes', '0.500', nyquist=15.0)
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(lines)
            records, _, _ = report.read_logs(Path(directory))
            rows = report.grating_rows(records)
            above = report.grating_above_nyquist(records)
        self.assertEqual(rows[0]['finest_seen_cpd'], 14)
        self.assertEqual(rows[0]['judged'], 4)
        self.assertEqual(rows[0]['above_nyquist_cpd'], '17,20')
        self.assertEqual([(a['cpd'], a['seen']) for a in above], [(17, 'yes'), (20, 'yes')])
        self.assertEqual(above[0]['nyquist_logical_cpd'], '15.00')
        out = self.render(lines)
        self.assertIn('Above the logical Nyquist', out)
        self.assertIn('| both | 0.500 | on | axis | V | 17 | yes | 15.00 |', out)

    def test_grating_physical_nyquist_and_limit_classification(self):
        # Rate map at 1.0 / fov on: h_ppd 40 on axis, 30 at -20 (left temporal), 36 at +20; v_ppd 34 on axis.
        def rrm(t, rq, fov, h0=40, hl=30, hr=36, v0=34, eye='L'):
            return ('DIAG rrm t_ms={} phase=quality s=0 fix=none fix_x_deg=0 fix_y_deg=0 eye={} drawable=0 view=0 layer=0 '
                    'rq={} fov={} map=ok screen=6261x5023 physical=2432x2368 viewport=0,0,6261,5023 '
                    'h_rate=0:1 h_ppd=-20:{:.2f},0:{:.2f},20:{:.2f} v_rate=0:1 v_ppd=0:{:.2f} '
                    'h_peak_deg=0.0 v_peak_deg=0.0 map_hash=a\n').format(t, eye, rq, fov, hl, h0, hr, v0)
        lines = 'DIAG grating t_ms=1 chart=on mode="Both eyes" foveation=on\n'
        lines += rrm(5, '1.000', 'on', h0=20)       # older sample, superseded by the nearer one
        lines += rrm(100, '1.000', 'on')
        lines += rrm(110, '1.000', 'on', h0=30, hl=20, eye='R')   # right eye: not used for eye=both / L
        lines += rrm(120, '0.500', 'on', h0=24, hl=16, v0=24)
        judged = {('1.000', 'axis', 'V'): 17,      # phys 20 -> 17 = 20 - one step: render-grid limited
                  ('1.000', 'axis', 'H'): 12,      # phys 17 -> needs 14: lens/eye limited
                  ('1.000', 'temporal20', 'V'): 14,  # phys 15 (h_ppd -20 = 30) -> needs 12: render-grid limited
                  ('1.000', 'temporal20', 'H'): 14,  # phys 34/cos20/2 = 18.09 -> needs 14: render-grid limited
                  ('0.500', 'axis', 'V'): 8}       # phys 12 -> needs 10: lens/eye limited
        for (rq, pos, orient), finest in judged.items():
            for cpd in (8, 10, 12, 14, 17):
                lines += self.grating_line(cpd, 'yes' if cpd <= finest else 'no', rq, pos=pos, orient=orient,
                                           nyquist=20.0 if rq == '1.000' else 15.0, t=200)
        lines += self.grating_line(8, 'yes', '0.750', nyquist=17.5, t=300)   # no rate map at 0.75: undetermined
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(lines)
            records, _, _ = report.read_logs(Path(directory))
            rows = report.grating_rows(records)
        key = {(r['rq'], r['pos'], r['orient']): r for r in rows}
        self.assertEqual(key[('1.000', 'axis', 'V')]['nyquist_physical_cpd'], '20.00')
        self.assertEqual(key[('1.000', 'axis', 'H')]['nyquist_physical_cpd'], '17.00')
        self.assertEqual(key[('1.000', 'temporal20', 'V')]['nyquist_physical_cpd'], '15.00')
        self.assertEqual(key[('1.000', 'temporal20', 'H')]['nyquist_physical_cpd'], '18.09')
        self.assertEqual(key[('0.500', 'axis', 'V')]['nyquist_physical_cpd'], '12.00')
        self.assertEqual(key[('1.000', 'axis', 'V')]['limit'], 'render-grid limited')
        self.assertEqual(key[('1.000', 'axis', 'H')]['limit'], 'lens/eye limited')
        self.assertEqual(key[('1.000', 'temporal20', 'V')]['limit'], 'render-grid limited')
        self.assertEqual(key[('1.000', 'temporal20', 'H')]['limit'], 'render-grid limited')
        self.assertEqual(key[('0.500', 'axis', 'V')]['limit'], 'lens/eye limited')
        self.assertIsNone(key[('0.750', 'axis', 'V')]['nyquist_physical_cpd'])
        self.assertEqual(key[('0.750', 'axis', 'V')]['limit'], 'undetermined')
        # Right-eye judgments read the right eye's map, temporal = +20.
        right = self.grating_line(14, 'yes', '1.000', pos='temporal20', eye='R', nyquist=22.6, t=200)
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'diag-a.log').write_text(lines + right)
            records, _, _ = report.read_logs(Path(directory))
            r = [r for r in report.grating_rows(records) if r['eye'] == 'R'][0]
        self.assertEqual(r['nyquist_physical_cpd'], '18.00')
        out = self.render(lines)
        self.assertIn('| both | 1.000 | on | axis | V | 17 | 20.00 | 20.00 | render-grid limited |', out)

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


def raster(ppd, cpd, offset=0.3, size_deg=1.5, mirror=False):
    """A square-wave patch rendered at pixel centres, as the rasteriser does: one bar per cycle from the patch's low
    edge (offset px into the first pixel), 255 white bars on 0 black."""
    length = size_deg * ppd
    out = []
    for i in range(int(round(offset + length))):
        d = i + 0.5 - offset
        out.append(255 if 0 <= d < length and (d * cpd / ppd) % 1 < 0.5 else 0)
    return out[::-1] if mirror else out


class ChartCaptureCounterTests(unittest.TestCase):
    def classify(self, profile, cpd, size_deg=1.5):
        result = report.count_bars(profile, len(profile) / (size_deg * cpd))
        return result, report.classify_bars(result, report.expected_bars(cpd))

    def test_square_waves_count_exactly_within_physical_nyquist(self):
        for ppd in (40, 35, 34.5, 30, 20):
            for cpd in (8, 10, 12, 14, 17, 20):
                if cpd > ppd / 2:
                    continue
                for offset in (0.0, 0.3, 0.49):
                    for mirror in (False, True):
                        result, verdict = self.classify(raster(ppd, cpd, offset, mirror=mirror), cpd)
                        label = 'ppd {} cpd {} offset {} mirror {}'.format(ppd, cpd, offset, mirror)
                        self.assertEqual(result['count'], report.expected_bars(cpd), label)
                        self.assertLessEqual(result['bar_spread_px'], 1, label)
                        self.assertEqual(verdict, 'correct', label)
        self.assertEqual([report.expected_bars(c) for c in (8, 10, 12, 14, 17, 20)], [12, 15, 18, 21, 26, 30])

    def test_uneven_bars_with_the_right_count(self):
        profile = []
        for k in range(12):
            bar = 1 if k % 2 == 0 else 4
            profile += [255] * bar + [0] * (5 - bar)
        result, verdict = self.classify(profile, 8)
        self.assertEqual(result['count'], 12)
        self.assertEqual(result['bar_spread_px'], 3)
        self.assertEqual(verdict, 'uneven')

    def test_aliased_beats(self):
        for ppd, cpd in ((30, 20), (20, 17), (25, 14)):
            result, verdict = self.classify(raster(ppd, cpd), cpd)
            self.assertNotEqual(result['count'], report.expected_bars(cpd), (ppd, cpd))
            self.assertEqual(verdict, 'aliased', (ppd, cpd, result))

    def test_missing_bars_merge_to_grey(self):
        full = raster(40, 20, 0.0)
        half = full[:len(full) // 2] + [128] * (len(full) - len(full) // 2)
        result, verdict = self.classify(half, 20)
        self.assertEqual(result['count'], 15)
        self.assertEqual(verdict, 'missing')
        result, verdict = self.classify([200] * 60, 8)
        self.assertEqual((result['count'], verdict), (0, 'missing'))

    @staticmethod
    def capture_dir(root):
        """One left-eye capture at rq 1.000: an 8 cpd V patch drawn at 40 px/deg (60 px) and a 20 cpd H patch at 30 px/deg
        (45 px: beats, aliased); a 12 cpd V patch at 40 px/deg drawn with every other bar merged (count low, flat)."""
        vc_spec = importlib.util.spec_from_file_location('verify_capture', SCRIPT.with_name('verify-capture.py'))
        vc = importlib.util.module_from_spec(vc_spec)
        vc_spec.loader.exec_module(vc)
        width, height = 240, 100
        pix = bytearray([0, 0, 0, 255] * width * height)

        def put(x, y, v):
            pix[(y * width + x) * 4:(y * width + x) * 4 + 3] = bytes([v, v, v])
        v8 = raster(40, 8, 0.0)
        for y in range(20, 80):
            for i, v in enumerate(v8):
                put(10 + i, y, v)
        h20 = raster(30, 20, 0.0)
        for i, v in enumerate(h20):
            for x in range(100, 130):
                put(x, 20 + i, v)
        for y in range(20, 80):
            for i in range(60):
                put(150 + i, y, 128)
        capture = root / 'captures' / 'chart-20261022T100000Z-rq1.00-fovon'
        capture.mkdir(parents=True)
        vc.write_png(capture / 'drawable-0-texture-0-slice-0.png', width, height, pix)

        def patch(pos, cpd, orient, rect, nyq_l, nyq_p):
            return dict(position=pos, cpd=cpd, orientation=orient, temporal_deg=0.0, up_deg=1.0, expected_bars=report.expected_bars(cpd),
                        logical_rect=[r * 2 for r in rect], physical_rect=rect, nyquist_logical_cpd=nyq_l, nyquist_physical_cpd=nyq_p)
        meta = dict(trigger=dict(reason='chartcap'), t_ms=500,
                    slices=[dict(eye='L', view=0, slice=0, texture_index=0, png='drawable-0-texture-0-slice-0.png', width=width, height=height)],
                    chart_capture=dict(mode='auto', rq='1.000', rq_set='1.000', rq_confirmed=True, fov='on', settle_frames=30, patch_deg=1.5,
                                       views=[dict(eye='L', view=0, slice=0, texture_index=0, tangents=[1.7321, 1, 1.1918, 1],
                                                   viewport=[0, 0, 6261, 5023], screen=[6261, 5023], physical=[2432, 2368], mapped=True,
                                                   patches=[patch('axis', 8, 'V', [10.0, 20.0, 70.0, 80.0], 20.0, 20.0),
                                                            patch('axis', 20, 'H', [100.0, 20.0, 130.0, 65.0], 20.0, 15.0),
                                                            patch('axis', 12, 'V', [150.0, 20.0, 210.0, 80.0], 20.0, 20.0)])]))
        (capture / 'capture.json').write_text(json.dumps(meta))
        (root / 'diag-a.log').write_text(
            'DIAG grating t_ms=1 chart=on mode=auto foveation=on\n'
            'DIAG rrm t_ms=400 phase=quality s=0 fix=none fix_x_deg=0 fix_y_deg=0 eye=L drawable=0 view=0 layer=0 rq=1.000 fov=on '
            'map=ok screen=6261x5023 physical=2432x2368 viewport=0,0,6261,5023 h_rate=0:1 h_ppd=-20:34.50,0:40.00,20:34.50 '
            'v_rate=0:1 v_ppd=0:40.00 h_peak_deg=0.0 v_peak_deg=0.0 map_hash=a\n'
            'DIAG chartcap t_ms=500 eye=L rq=1.000 rq_set=1.000 confirmed=yes fov=on dir=chart-20261022T100000Z-rq1.00-fovon '
            'slice=0 physical=2432x2368 patches=24\n'
            'DIAG chartcap t_ms=900 step=done captures=1 failed=0 fov=on fov_off=unavailable restore=0.750\n')

    def test_capture_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.capture_dir(root)
            records, _, _ = report.read_logs(root)
            patches = report.chart_capture_patches(root)
            summary = report.chart_capture_summary(patches, records)
            out = report.generate(root)
        key = {(p['orient'], p['cpd']): p for p in patches}
        self.assertEqual((key[('V', 8)]['count'], key[('V', 8)]['class']), (12, 'correct'))
        self.assertEqual(key[('H', 20)]['class'], 'aliased')
        self.assertEqual((key[('V', 12)]['count'], key[('V', 12)]['class']), (0, 'missing'))
        rows = {r['orient']: r for r in summary}
        self.assertEqual(rows['V']['finest_correct_cpd'], 8)
        self.assertEqual(rows['V']['finest_count_correct_cpd'], 8)
        self.assertEqual(rows['V']['nyquist_logical_cpd'], '20.00')
        self.assertEqual(rows['V']['nyquist_physical_cpd'], '20.00')   # nearest rrm: h_ppd 40 on axis
        self.assertIsNone(rows['H']['finest_correct_cpd'])
        self.assertEqual(rows['H']['nyquist_physical_capture_cpd'], '15.00')
        # Exactly one pixel per cycle: every pixel centre at the same phase, the patch renders flat.
        result = report.count_bars(raster(20, 20, 0.0), 1.0)
        self.assertEqual(report.classify_bars(result, 30), 'missing')
        self.assertEqual(rows['V']['grid_verdict'], 'below grid Nyquist')
        self.assertIn('Auto capture', out)
        self.assertIn('| L | 1.000 | on | axis | V | 8 | 8 | 20.00 | 20.00 | 20.00 | below grid Nyquist |', out)
        self.assertIn('| L | 1.000 | on | axis | V | 8 | 12 | 12 |', out)


if __name__ == '__main__':
    unittest.main()
