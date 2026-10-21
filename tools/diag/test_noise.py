"""Mac encoder integration: skip only when HEVC is unavailable in the sandbox."""
import json
import pathlib
import subprocess
import tempfile
import unittest


class NoiseTests(unittest.TestCase):
    def generate(self, scratch, name, size, fps, bitrate, stress=False):
        tool = pathlib.Path(__file__).with_name('make-hevc-clips.swift')
        directory = pathlib.Path(scratch) / name
        args = ['/usr/bin/swift', '-module-cache-path', scratch + '/cache', str(tool),
                '--out', str(directory), '--sizes', size, '--fps', str(fps), '--seconds', '2',
                '--bitrate', str(bitrate), '--content', 'noise']
        if stress:
            args += ['--stress']
        result = subprocess.run(args, capture_output=True, text=True, timeout=900)
        if result.returncode and 'create encoder: OSStatus -12908' in result.stderr:
            self.skipTest('VideoToolbox HEVC encoder unavailable (-12908)')
        self.assertEqual(result.returncode, 0, result.stderr)
        clip = json.loads((directory / 'hevc-manifest.json').read_text())['clips'][0]
        self.assertEqual(clip['width'], int(size.split('x')[0]))
        self.assertEqual(clip['height'], int(size.split('x')[1]))
        self.assertEqual(clip['fps'], fps)
        self.assertEqual(clip['achievedBitrate'], clip['bitrate'])
        self.assertEqual(clip['overload'], stress)
        self.assertGreaterEqual(clip['droppedFrames'], 0)
        self.assertEqual(clip['frames'] + clip['droppedFrames'], clip['requestedFrames'])
        return clip

    def test_stress_option(self):
        tool = pathlib.Path(__file__).with_name('make-hevc-clips.swift')
        with tempfile.TemporaryDirectory(prefix='diag-help-') as scratch:
            result = subprocess.run(['/usr/bin/swift', '-module-cache-path', scratch + '/cache',
                                     str(tool), '--help'], capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--stress', result.stdout)

    def check_target(self, bitrate):
        with tempfile.TemporaryDirectory(prefix='diag-target-') as scratch:
            clip = self.generate(scratch, 'target', '3648x2912', 90, bitrate)
            self.assertEqual(clip['rateMode'], 'targeted')
            self.assertEqual(clip['droppedFrames'], 0)
            self.assertEqual(clip['frames'], 180)
            self.assertEqual(clip['bitrateTolerance'], 0.15)
            self.assertLessEqual(abs(clip['achievedBitrate'] / bitrate - 1), 0.15)
            self.assertGreaterEqual(clip['noiseAmplitude'], 0)
            self.assertLessEqual(clip['noiseAmplitude'], 1)

    def test_target_150m(self):
        self.check_target(150000000)

    def test_target_300m(self):
        self.check_target(300000000)

    def test_uncapped_overload(self):
        with tempfile.TemporaryDirectory(prefix='diag-overload-') as scratch:
            clip = self.generate(scratch, 'overload', '640x360', 30, 20000000, stress=True)
            self.assertEqual(clip['rateMode'], 'overload')
            self.assertFalse(clip['rateLimited'])

    def test_noise_bitrate(self):
        tool = pathlib.Path(__file__).with_name('make-hevc-clips.swift')
        with tempfile.TemporaryDirectory(prefix='diag-noise-') as scratch:
            rates = []
            for content in ('default', 'noise'):
                directory = pathlib.Path(scratch) / content
                args = ['/usr/bin/swift', '-module-cache-path', scratch + '/cache', str(tool), '--out', str(directory),
                        '--sizes', '640x360', '--fps', '30', '--seconds', '1', '--bitrate', '20000000']
                if content == 'noise':
                    args += ['--content', 'noise']
                result = subprocess.run(args, capture_output=True, text=True, timeout=180)
                if result.returncode and 'create encoder: OSStatus -12908' in result.stderr:
                    self.skipTest('VideoToolbox HEVC encoder unavailable (-12908)')
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads((directory / 'hevc-manifest.json').read_text())
                clip = manifest['clips'][0]
                self.assertEqual(clip['content'], content)
                self.assertEqual(clip['achievedBitrate'], clip['bitrate'])
                self.assertGreater(clip['achievedBitrate'], 0)
                self.assertEqual(clip['requestedBitrate'], 20000000)
                rates.append(clip['achievedBitrate'])
            self.assertGreaterEqual(rates[1], 2 * rates[0], rates)


if __name__ == '__main__':
    unittest.main()
