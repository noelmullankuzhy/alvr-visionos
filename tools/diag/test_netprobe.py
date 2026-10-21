import importlib.util
import json
import contextlib
import io
import os
import pathlib
import struct
import socket
import subprocess
import sys
import threading
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('netprobe', pathlib.Path(__file__).with_name('netprobe-send.py'))
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)


class NetProbeTests(unittest.TestCase):
    def test_packet(self):
        packet = n.packet(123, 7, 2, 5, 999, 100)
        self.assertEqual(len(packet), 100)
        self.assertEqual(struct.unpack('!4sQQIHH', packet[:28]), (b'AVPD', 123, 999, 7, 2, 5))
        with self.assertRaises(ValueError):
            n.packet(0, 0, 0, 1, 0, 27)

    def test_pacing(self):
        self.assertEqual(n.frame_bytes(100, 100, 0), 125000)
        # Fractional budgets carry across frames without cumulative rounding loss.
        self.assertEqual(sum(n.frame_bytes(1, 90, f) for f in range(90)), 125000)
        sizes = n.packet_sizes(125000, 1200)
        self.assertEqual(sum(sizes), 125000)
        self.assertTrue(all(28 <= s <= 1200 for s in sizes))
        self.assertEqual(n.frame_deadline(10, 90, 5), 10 + 5 / 90)

    @unittest.skipUnless(os.environ.get("DIAG_LOOPBACK") == "1", "opt-in: DIAG_LOOPBACK=1")
    def test_loopback_udp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(('127.0.0.1', 0))
            receiver.settimeout(0.5)
            received = []

            def collect():
                try:
                    while True:
                        received.append(receiver.recv(65535))
                except socket.timeout:
                    pass

            thread = threading.Thread(target=collect)
            thread.start()
            result = subprocess.run([sys.executable, str(pathlib.Path(n.__file__)),
                                     '127.0.0.1', '--port', str(receiver.getsockname()[1]),
                                     '--mbps', '0.05', '--fps', '20', '--duration', '0.2'],
                                    capture_output=True, text=True, timeout=5)
            thread.join(timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertGreater(len(received), 0)
            self.assertEqual(report['bytes'], sum(map(len, received)))
            self.assertEqual(report['packets'], len(received))
            timestamps = []
            for sequence, data in enumerate(received):
                magic, seq, timestamp, frame, index, count = n.HEADER.unpack(data[:28])
                self.assertEqual(magic, b'AVPD')
                self.assertEqual(seq, sequence)
                self.assertLess(index, count)
                self.assertGreater(timestamp, 0)
                timestamps.append(timestamp)
            self.assertEqual(timestamps, sorted(timestamps))

    @unittest.skipUnless(os.environ.get("DIAG_LOOPBACK") == "1", "opt-in: DIAG_LOOPBACK=1")
    def test_loopback_tcp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as receiver:
            receiver.bind(('127.0.0.1', 0))
            receiver.listen(1)
            receiver.settimeout(3)
            received = []

            def collect():
                connection, _ = receiver.accept()
                with connection:
                    connection.settimeout(3)
                    while True:
                        data = connection.recv(65536)
                        if not data:
                            break
                        received.append(len(data))

            thread = threading.Thread(target=collect)
            thread.start()
            result = subprocess.run([sys.executable, str(pathlib.Path(n.__file__)),
                                     '127.0.0.1', '--port', str(receiver.getsockname()[1]),
                                     '--mode', 'tcp', '--duration', '0.05'],
                                    capture_output=True, text=True, timeout=5)
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertGreater(report['bytes'], 0)
            self.assertEqual(report['bytes'], sum(received))

    def test_invalid_budgets(self):
        for total, maximum in [(27, 1200), (100, 27), (29, 28), (65536 * 1200, 1200)]:
            with self.assertRaises(ValueError):
                n.packet_sizes(total, maximum)

    def test_sender_without_network(self):
        clock = [100.0]
        sent = []

        def monotonic():
            clock[0] += 0.00001
            return clock[0]

        def sleep(seconds):
            clock[0] += seconds

        def send(data):
            sent.append(data)
            return len(data)

        sock = mock.MagicMock()
        sock.__enter__.return_value = sock
        sock.send.side_effect = send
        output = io.StringIO()
        with mock.patch.object(sys, 'argv', ['netprobe-send.py', '127.0.0.1',
                                           '--mbps', '0.05', '--fps', '20', '--duration', '0.2']), \
                mock.patch.object(n.socket, 'getaddrinfo', return_value=[(socket.AF_INET, socket.SOCK_DGRAM, 0, '', ('127.0.0.1', 9945))]), \
                mock.patch.object(n.socket, 'socket', return_value=sock), \
                mock.patch.object(n.time, 'monotonic', side_effect=monotonic), \
                mock.patch.object(n.time, 'monotonic_ns', side_effect=lambda: int(clock[0] * 1e9)), \
                mock.patch.object(n.time, 'sleep', side_effect=sleep), contextlib.redirect_stdout(output):
            self.assertEqual(n.main(), 0)
        report = json.loads(output.getvalue())
        self.assertEqual(report['bytes'], 1250)
        self.assertEqual(len(sent), 4)
        headers = [n.HEADER.unpack(data[:28]) for data in sent]
        self.assertEqual([h[1] for h in headers], [0, 1, 2, 3])
        self.assertEqual([h[3] for h in headers], [0, 1, 2, 3])
        self.assertTrue(all(49_000_000 < b[2] - a[2] < 51_000_000 for a, b in zip(headers, headers[1:])))

    def test_summary(self):
        result = n.summary('udp', 1000000, 100, 2, 3)
        self.assertEqual(result['payload_mbps'], 4)
        self.assertEqual(result['packets'], 100)
        self.assertEqual(result['late_frames'], 3)
        json.dumps(result)


if __name__ == '__main__':
    unittest.main()
