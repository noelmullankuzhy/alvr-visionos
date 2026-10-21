#!/usr/bin/env python3
"""UDP rate ladder in ONE Net sink run, with one socket and continuous sequence/frame IDs.

Derived from the GM's netladder.py. JSON lines: metadata, timed steps, footer.
Usage: netprobe-ladder.py HOST PORT RATES_CSV STEP_SECONDS [FPS] [PACKET_SIZE]
Python 3.9+, standard library only.
"""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import socket
import time

spec = importlib.util.spec_from_file_location('netprobe_send', Path(__file__).with_name('netprobe-send.py'))
np = importlib.util.module_from_spec(spec)
spec.loader.exec_module(np)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('port', type=int)
    parser.add_argument('rates_csv', help='comma-separated Mb/s steps')
    parser.add_argument('step_seconds', type=float)
    parser.add_argument('fps', nargs='?', type=int, default=90)
    parser.add_argument('packet_size', nargs='?', type=int, default=1200)
    args = parser.parse_args(argv)
    try:
        rates = [float(value) for value in args.rates_csv.split(',')]
        if not rates or any(not math.isfinite(rate) or not 0 < rate <= 100000 for rate in rates):
            raise ValueError('rates must be positive finite Mb/s, at most 100000')
        if not math.isfinite(args.step_seconds) or args.step_seconds <= 0:
            raise ValueError('step seconds must be positive and finite')
        if args.fps <= 0 or not 28 <= args.packet_size <= 65507 or not 1 <= args.port <= 65535:
            raise ValueError('positive fps, port 1..65535 and packet size 28..65507 required')
        for rate in rates:
            budget = rate * 1000000 / 8 / args.fps
            for total in (math.floor(budget), math.ceil(budget)):
                np.packet_sizes(total, args.packet_size)
    except ValueError as error:
        parser.error(str(error))
    host, port = args.host, args.port
    step_s, fps, psize = args.step_seconds, args.fps, args.packet_size
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
        sock.connect((host, port))
        seq = 0
        frame = 0
        t0 = time.monotonic()
        print(json.dumps({'start_wall': time.time(), 'host': host, 'port': port, 'fps': fps, 'packet_size': psize}), flush=True)
        for rate in rates:
            s0 = time.monotonic()
            f0 = frame
            sent = 0
            late = 0
            errors = 0
            while True:
                deadline = s0 + (frame - f0) / fps
                if deadline >= s0 + step_s:
                    break
                delay = deadline - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                elif -delay > 1.0 / fps:
                    late += 1
                sizes = np.packet_sizes(np.frame_bytes(rate, fps, frame), psize)
                for i, size in enumerate(sizes):
                    try:
                        sent += sock.send(np.packet(seq, frame, i, len(sizes), time.monotonic_ns(), size))
                    except OSError:
                        errors += 1
                    seq += 1
                frame += 1
            elapsed = time.monotonic() - s0
            print(json.dumps({'t_start_s': round(s0 - t0, 3), 'mbps_req': rate, 'sent_mbps': round((sent * 8 / elapsed / 1e6 if elapsed > 0 else 0), 1),
                              'late_frames': late, 'send_errors': errors, 'frames': frame - f0, 'elapsed_s': round(elapsed, 3)}), flush=True)
        print(json.dumps({'total_s': round(time.monotonic() - t0, 3), 'packets': seq, 'frames': frame}), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
