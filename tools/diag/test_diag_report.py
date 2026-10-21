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

    def test_m8_knee_boundaries_and_step_alignment(self):
        lines = []
        senders = []
        for i, (rate, loss, tail) in enumerate([(50, 1, 10), (100, 1, 10.001),
                                                (150, 2, 9), (200, 0, 9)]):
            # Interval and final records belong to one step, not two steps.
            for summary in ('false', 'true'):
                lines.append('DIAG net t_ms={} mode=udp summary={} seconds=2 bytes=1000 '
                             'mbps={} loss={} reorder=3 jitter_ms=0.2 '
                             'frame_complete=100 spread_p99_ms={}\n'.format(
                                 i * 10 + (summary == 'true'), summary, rate - 1, loss, tail))
            senders.append(json.dumps(dict(mode='udp', requested_mbps=rate, fps=100,
                                           packets=1000, payload_mbps=rate)))
        out = self.render(''.join(lines), '\n'.join(senders))
        self.assertIn('Knee: 200 Mb/s', out)
        self.assertIn('loss=0.1%', out)
        self.assertIn('loss=0.2%', out)
        self.assertIn('completion_p99_ms=10.001', out)
        self.assertIn('sender.jsonl:4', out)
        self.assertIn('Step 4', out)
        self.assertNotIn('Step 5', out)

    def test_m8_missing_denominator_fps_incomplete_and_nan(self):
        line = ('DIAG net t_ms=1 mode=udp summary=true seconds=1 mbps=49 loss=0 '
                'spread_p99_ms=nan frame_complete=0\n')
        out = self.render(line)
        self.assertIn('Knee: no data', out)
        self.assertIn('loss=no data', out)
        self.assertIn('frame_period_ms=no data', out)
        out = self.render(line, '{"mode":"udp","mbps":50,"fps":90,"packets":100}\n')
        self.assertIn('Knee: no data', out)
        out = self.render(line.replace('summary=true', 'summary=false').replace('nan', '1'),
                          '{"mode":"udp","mbps":50,"fps":90,"packets":100}\n')
        self.assertIn('incomplete run', out)
        self.assertIn('Knee: no data', out)

    def test_sender_malformed_and_unmatched(self):
        out = self.render('', 'garbage\n[]\n{"fps": NaN}\n{"mode":"udp","mbps":50}\n')
        self.assertIn('malformed sender lines skipped=3', out)
        self.assertIn('Unmatched sender steps: 1', out)

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
        out = self.render(lines, 'broken\n{"mode":"udp","mbps":100,"fps":100,"packets":100}\n')
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
