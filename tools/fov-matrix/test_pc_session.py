"""Tests for pc-session.py (runs in WSL on the PC; here against a temp root)."""
import importlib.util
import io
import json
import os
import tarfile
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('pc_session', os.path.join(HERE, 'pc-session.py'))
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)

def rd(path):
    with open(path) as f:
        return f.read()


SESSION = {'session_settings': {'video': {
    'preferred_fps': 72.0,
    'bitrate': {'mode': {'variant': 'Adaptive', 'ConstantMbps': 30, 'Adaptive': {'x': 1}}},
    'foveated_encoding': {'enabled': True, 'content': {'center_size_x': 0.4}},
    'encoder_config': {'nvenc': {'quality_preset': {'variant': 'P1'}, 'multi_pass': {'variant': 'QuarterResolution'},
                                 'split_encode_mode': {'variant': 'Auto'}, 'gop_length': -1}},
    'transcoding_view_resolution': {'variant': 'Absolute', 'Absolute': {'width': 100, 'height': {'enabled': True, 'content': 50}}},
}}, 'client_connections': {'x': 1}}


class PcSessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.build = 'abc123'
        d = os.path.join(self.root, 'alvr-build', 'out', self.build, 'alvr_streamer_windows')
        os.makedirs(d)
        self.session = os.path.join(d, 'session.json')
        with open(self.session, 'w') as f:
            json.dump(SESSION, f)
        self.orig_text = rd(self.session)

    def tearDown(self):
        self.tmp.cleanup()

    def live(self):
        with open(self.session) as f:
            return json.load(f)

    def test_backup_apply_restore_roundtrip(self):
        self.assertIn('backup sha=', ps.backup(self.root, self.build))
        out = ps.apply(self.root, self.build, ['video.preferred_fps=90.0', 'video.bitrate.mode.variant="ConstantMbps"', 'video.bitrate.mode.ConstantMbps=500',
                                               'video.foveated_encoding.content.center_size_x=0.6'])
        self.assertIn('written 4 sets', out)
        v = self.live()['session_settings']['video']
        self.assertEqual(v['preferred_fps'], 90.0)
        self.assertEqual(v['bitrate']['mode'], {'variant': 'ConstantMbps', 'ConstantMbps': 500, 'Adaptive': {'x': 1}})
        self.assertEqual(v['foveated_encoding']['content']['center_size_x'], 0.6)
        self.assertEqual(self.live()['client_connections'], {'x': 1})
        out = ps.restore(self.root, self.build)
        self.assertTrue(out.startswith('restore OK'), out)
        self.assertEqual(rd(self.session), self.orig_text)

    def test_apply_starts_from_backup_not_previous_point(self):
        ps.backup(self.root, self.build)
        ps.apply(self.root, self.build, ['video.preferred_fps=90.0'])
        ps.apply(self.root, self.build, ['video.foveated_encoding.enabled=false'])
        v = self.live()['session_settings']['video']
        self.assertEqual(v['preferred_fps'], 72.0)
        self.assertFalse(v['foveated_encoding']['enabled'])

    def test_strict_paths(self):
        ps.backup(self.root, self.build)
        with self.assertRaises(SystemExit) as cm:
            ps.apply(self.root, self.build, ['video.nope.x=1'])
        self.assertIn('no nope', str(cm.exception))
        with self.assertRaises(SystemExit):
            ps.apply(self.root, self.build, ['video.preferred_fpz=1'])
        self.assertEqual(rd(self.session), self.orig_text)  # nothing written on error

    def test_stale_backup_refused(self):
        ps.backup(self.root, self.build)
        with self.assertRaises(SystemExit) as cm:
            ps.backup(self.root, self.build)
        self.assertIn('stale backup', str(cm.exception))

    def with_nonce(self, nonce, fn, *args):
        old = os.environ.get('FOVMATRIX_NONCE')
        os.environ['FOVMATRIX_NONCE'] = nonce
        try:
            return fn(self.root, self.build, *args)
        finally:
            if old is None:
                del os.environ['FOVMATRIX_NONCE']
            else:
                os.environ['FOVMATRIX_NONCE'] = old

    def test_restore_only_restores_this_runs_backup(self):
        self.with_nonce('run-A', ps.backup)
        ps.apply(self.root, self.build, ['video.preferred_fps=90.0'])
        out = self.with_nonce('run-B', ps.restore)   # another run: its backup is not ours
        self.assertTrue(out.startswith('restore SKIP FOREIGN'), out)
        self.assertEqual(self.live()['session_settings']['video']['preferred_fps'], 90.0)  # live untouched
        self.assertTrue(os.path.exists(ps.paths(self.root, self.build)['orig']))             # backup untouched
        self.assertTrue(self.with_nonce('run-A', ps.restore).startswith('restore OK'))
        self.assertEqual(rd(self.session), self.orig_text)
        self.assertFalse(os.path.exists(ps.paths(self.root, self.build)['nonce']))

    def test_refused_stale_backup_keeps_its_owner(self):
        self.with_nonce('run-A', ps.backup)
        with self.assertRaises(SystemExit):
            self.with_nonce('run-B', ps.backup)
        self.assertEqual(rd(ps.paths(self.root, self.build)['nonce']).strip(), 'run-A')
        self.assertTrue(self.with_nonce('run-B', ps.restore).startswith('restore SKIP FOREIGN'))

    def test_manual_restore_without_nonce_restores_any_backup(self):
        self.with_nonce('run-A', ps.backup)
        ps.apply(self.root, self.build, ['video.preferred_fps=90.0'])
        self.assertTrue(ps.restore(self.root, self.build).startswith('restore OK'))
        self.assertEqual(rd(self.session), self.orig_text)

    def test_apply_without_backup_refused(self):
        with self.assertRaises(SystemExit):
            ps.apply(self.root, self.build, ['video.preferred_fps=90'])

    def test_restore_without_backup_is_skip(self):
        self.assertTrue(ps.restore(self.root, self.build).startswith('restore SKIP'))

    def test_restore_detects_tamper_of_backup(self):
        ps.backup(self.root, self.build)
        bak = os.path.join(self.root, 'fov-matrix', 'session.orig.json')
        with open(bak, 'a') as f:
            f.write(' ')
        with self.assertRaises(SystemExit) as cm:
            ps.restore(self.root, self.build)
        self.assertIn('restore FAILED', str(cm.exception))
        self.assertTrue(os.path.exists(bak))  # kept for the GM

    def test_flag_lifecycle_and_original_flag_restored(self):
        flag = os.path.join(os.path.dirname(self.session), 'angle_chart.enable')
        with open(flag, 'w') as f:
            f.write('on')
        ps.backup(self.root, self.build)
        ps.flag(self.root, self.build, 'dump')
        self.assertEqual(rd(flag).strip(), 'dump')
        ps.flag(self.root, self.build, 'off')
        self.assertFalse(os.path.exists(flag))
        ps.flag(self.root, self.build, 'dump')
        self.assertTrue(ps.restore(self.root, self.build).startswith('restore OK'))
        self.assertEqual(rd(flag).strip(), 'on')

    def test_flag_absent_originally_removed_on_restore(self):
        flag = os.path.join(os.path.dirname(self.session), 'angle_chart.enable')
        ps.backup(self.root, self.build)
        ps.flag(self.root, self.build, 'dump')
        ps.restore(self.root, self.build)
        self.assertFalse(os.path.exists(flag))

    def test_flag_stress_modes(self):
        flag = os.path.join(os.path.dirname(self.session), 'angle_chart.enable')
        ps.backup(self.root, self.build)
        for mode in ('stress', 'stress,dump', 'dump,stress'):
            self.assertIn(mode, ps.flag(self.root, self.build, mode))
            self.assertEqual(rd(flag), mode + '\n')
        for bad in ('stres', 'stress,', 'dump,x', ''):
            with self.assertRaises(SystemExit):
                ps.flag(self.root, self.build, bad)
        ps.flag(self.root, self.build, 'stress,dump')
        self.assertTrue(ps.restore(self.root, self.build).startswith('restore OK'))
        self.assertFalse(os.path.exists(flag))   # absent originally: removed again

    def test_flag_stress_restores_original_content(self):
        flag = os.path.join(os.path.dirname(self.session), 'angle_chart.enable')
        with open(flag, 'w') as f:
            f.write('on')
        ps.backup(self.root, self.build)
        ps.flag(self.root, self.build, 'stress')
        ps.restore(self.root, self.build)
        self.assertEqual(rd(flag), 'on')

    def test_nvenc_session_paths(self):
        # the exact paths of ALVR settings.rs: video.encoder_config.nvenc.{quality_preset,multi_pass,split_encode_mode}
        ps.backup(self.root, self.build)
        ps.apply(self.root, self.build, ['video.encoder_config.nvenc.quality_preset={"variant":"P4"}',
                                         'video.encoder_config.nvenc.multi_pass={"variant":"Disabled"}',
                                         'video.encoder_config.nvenc.split_encode_mode={"variant":"ForceTwo"}'])
        n = self.live()['session_settings']['video']['encoder_config']['nvenc']
        self.assertEqual(n, {'quality_preset': {'variant': 'P4'}, 'multi_pass': {'variant': 'Disabled'},
                             'split_encode_mode': {'variant': 'ForceTwo'}, 'gop_length': -1})
        with self.assertRaises(SystemExit):   # strict: a misspelt key is refused
            ps.apply(self.root, self.build, ['video.encoder_config.nvenc.multipass={"variant":"Disabled"}'])

    def test_fetch_dump_picks_dir_newer_than_flag(self):
        base = os.path.join(self.root, 'angle-chart')
        for stamp in ('old', 'new'):
            os.makedirs(os.path.join(base, stamp))
            with open(os.path.join(base, stamp, 'meta.json'), 'w') as f:
                f.write(stamp)
        ps.backup(self.root, self.build)
        flag = ps.flag(self.root, self.build, 'dump') and os.path.join(os.path.dirname(self.session), 'angle_chart.enable')
        now = time.time()
        os.utime(os.path.join(base, 'old'), (now - 500, now - 500))
        os.utime(flag, (now - 100, now - 100))
        os.utime(os.path.join(base, 'new'), (now, now))
        buf = io.BytesIO()
        self.assertEqual(ps.fetch_dump(self.root, self.build, buf), 'new')
        buf.seek(0)
        with tarfile.open(fileobj=buf) as t:
            self.assertEqual(t.getnames(), ['dump', 'dump/meta.json'])

    def test_fetch_dump_none_is_fatal(self):
        ps.backup(self.root, self.build)
        ps.flag(self.root, self.build, 'dump')
        with self.assertRaises(SystemExit) as cm:
            ps.fetch_dump(self.root, self.build, io.BytesIO())
        self.assertIn('no dump', str(cm.exception))


VRSETTINGS_BLOCKED = (b'{\r\n   "driver_alvr_server" : {\r\n      "blocked_by_safe_mode" : true,\r\n      "other" : 1\r\n   },\r\n'
                      b'   "driver_other" : {\r\n      "blocked_by_safe_mode" : true\r\n   },\r\n   "steamvr" : {\r\n      "x" : "\xc3\xa9"\r\n   }\r\n}\r\n')


class SafeModeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.file = os.path.join(self.tmp.name, 'steamvr.vrsettings')
        self.bdir = os.path.join(self.tmp.name, 'backups')
        self.wr(VRSETTINGS_BLOCKED)
        self.old_running = ps.vr_running
        ps.vr_running = lambda: []

    def tearDown(self):
        ps.vr_running = self.old_running
        self.tmp.cleanup()

    def wr(self, data):
        with open(self.file, 'wb') as f:
            f.write(data)

    def rb(self, path=None):
        with open(path or self.file, 'rb') as f:
            return f.read()

    def test_check_blocked_and_not(self):
        self.assertEqual(ps.safemode_check(self.file), {'blocked': True})
        self.wr(VRSETTINGS_BLOCKED.replace(b'true,\r\n      "other"', b'false,\r\n      "other"'))
        self.assertEqual(ps.safemode_check(self.file), {'blocked': False})

    def test_check_only_looks_at_the_alvr_driver(self):
        self.wr(b'{"driver_other" : {"blocked_by_safe_mode" : true}, "driver_alvr_server" : {"x" : 1}}')
        self.assertEqual(ps.safemode_check(self.file), {'blocked': False})

    def test_clear_flips_only_alvr_flag_and_keeps_every_other_byte(self):
        r = ps.safemode_clear(self.file, self.bdir, now='20261022T120000')
        self.assertTrue(r['cleared'])
        self.assertEqual(r['backup'], os.path.join(self.bdir, 'steamvr.vrsettings.20261022T120000'))
        self.assertEqual(self.rb(r['backup']), VRSETTINGS_BLOCKED)
        want = VRSETTINGS_BLOCKED.replace(b'"blocked_by_safe_mode" : true,', b'"blocked_by_safe_mode" : false,', 1)
        self.assertEqual(self.rb(), want)
        self.assertIn(b'"driver_other" : {\r\n      "blocked_by_safe_mode" : true', self.rb())  # other drivers untouched
        self.assertEqual(ps.safemode_check(self.file), {'blocked': False})

    def test_clear_when_not_blocked_changes_nothing_and_makes_no_backup(self):
        self.wr(b'{"driver_alvr_server" : {"blocked_by_safe_mode" : false}}')
        r = ps.safemode_clear(self.file, self.bdir)
        self.assertEqual(r, {'cleared': False, 'backup': None})
        self.assertFalse(os.path.exists(self.bdir))

    def test_clear_refused_while_steamvr_runs(self):
        ps.vr_running = lambda: ['vrserver.exe']
        with self.assertRaises(SystemExit) as cm:
            ps.safemode_clear(self.file, self.bdir)
        self.assertIn('vrserver.exe', str(cm.exception))
        self.assertEqual(self.rb(), VRSETTINGS_BLOCKED)
        self.assertFalse(os.path.exists(self.bdir))

    def test_vr_running_parses_tasklist(self):
        import subprocess
        real = subprocess.run

        class R:
            stdout = 'Image Name   PID\r\nvrmonitor.exe  12  Console\r\nsteam.exe  3 Console\r\nVRSERVER.EXE 5 Console\r\n'
        subprocess.run = lambda *a, **k: R()
        try:
            self.assertEqual(sorted(x.lower() for x in self.old_running()), ['vrmonitor.exe', 'vrserver.exe'])
        finally:
            subprocess.run = real

    def test_driver_check_reads_newest_lines_only(self):
        log = os.path.join(self.tmp.name, 'vrserver.txt')
        line = 'Not loading driver alvr_server because it was blocked by a previous safe mode event\n'
        with open(log, 'w') as f:
            f.write(line + 'x\n' * 300)
        self.assertEqual(ps.driver_check(log), {'not_loaded': False})   # beyond the 200-line tail
        with open(log, 'w') as f:
            f.write('x\n' * 10 + line + 'y\n' * 5)
        self.assertEqual(ps.driver_check(log), {'not_loaded': True})
        self.assertEqual(ps.driver_check(log + '.none'), {'not_loaded': False})

    def test_cli_json_line_and_file_option(self):
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ps.main(['pc-session.py', 'safemode-check', '--file', self.file])
        self.assertEqual(json.loads(buf.getvalue()), {'blocked': True})
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ps.main(['pc-session.py', 'safemode-clear', '--file', self.file, '--backup-dir', self.bdir])
        self.assertTrue(json.loads(buf.getvalue())['cleared'])


if __name__ == '__main__':
    unittest.main()
