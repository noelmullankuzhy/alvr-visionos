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


if __name__ == '__main__':
    unittest.main()
