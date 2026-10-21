"""Mac encoder integration: skip only when HEVC is unavailable in the sandbox."""
import json
import pathlib
import subprocess
import tempfile
import unittest


class NoiseTests(unittest.TestCase):
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
