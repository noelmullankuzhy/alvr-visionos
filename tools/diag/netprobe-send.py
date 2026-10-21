#!/usr/bin/env python3
"""Frame-burst UDP or bulk TCP. All wire integers are big endian; see README.md."""
import argparse
import json
import math
import socket
import struct
import time

HEADER = struct.Struct('!4sQQIHH')


def packet(sequence, frame, index, count, timestamp_ns, size):
    if size < HEADER.size:
        raise ValueError('packet must fit the 28-byte header')
    return HEADER.pack(b'AVPD', sequence, timestamp_ns, frame, index, count) + bytes(size - HEADER.size)


def frame_bytes(mbps, fps, frame):
    budget = mbps * 1000000 / 8 / fps
    return math.floor((frame + 1) * budget) - math.floor(frame * budget)


def packet_sizes(total, maximum):
    if maximum < HEADER.size or total < HEADER.size:
        raise ValueError('frame budget and packet size must fit a header')
    count = math.ceil(total / maximum)
    if count > 65535:
        raise ValueError("frame exceeds 65535 packets")
    if total // count < HEADER.size:
        raise ValueError('packet size leaves an undersized remainder')
    base, remainder = divmod(total, count)
    return [base + (i < remainder) for i in range(count)]


def frame_deadline(start, fps, frame):
    return start + frame / fps


def summary(mode, sent, packets, elapsed, late):
    return dict(mode=mode, bytes=sent, packets=packets, elapsed_seconds=elapsed,
                payload_mbps=sent * 8 / elapsed / 1000000 if elapsed else 0,
                late_frames=late)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('host')
    p.add_argument('--port', type=int, default=9945)
    p.add_argument('--mode', choices=['udp', 'tcp'], default='udp')
    p.add_argument('--mbps', type=float, default=100)
    p.add_argument('--fps', type=int, default=90)
    p.add_argument('--packet-size', type=int, default=1200)
    p.add_argument('--duration', type=float, default=10)
    a = p.parse_args()
    if (not math.isfinite(a.mbps) or not math.isfinite(a.duration) or
            not 0 < a.mbps <= 100000 or a.duration <= 0 or a.fps <= 0 or
            not 28 <= a.packet_size <= 65507 or not 1 <= a.port <= 65535):
        p.error('rate >0..100000 Mb/s, positive finite duration/fps, port 1..65535, packet size 28..65507 required')
    try:
        packet_sizes(frame_bytes(a.mbps, a.fps, 0), a.packet_size)
        packet_sizes(math.ceil(a.mbps * 1000000 / 8 / a.fps), a.packet_size)
    except ValueError as e:
        p.error(str(e))
    sent = sequence = late = 0
    socktype = socket.SOCK_DGRAM if a.mode == 'udp' else socket.SOCK_STREAM
    address = socket.getaddrinfo(a.host, a.port, type=socktype)[0]
    with socket.socket(address[0], socktype) as sock:
        sock.settimeout(2)
        sock.connect(address[4])
        start = time.monotonic()
        end = start + a.duration
        frame = 0
        bulk = bytes(65536)
        try:
            while time.monotonic() < end:
                if a.mode == 'tcp':
                    # TCP is deliberately unpaced bulk; stream bytes have no packet boundaries.
                    sent += sock.send(bulk)
                    sequence += 1
                    continue
                deadline = frame_deadline(start, a.fps, frame)
                delay = min(deadline, end) - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                if time.monotonic() >= end:
                    break
                if time.monotonic() > deadline + 1 / a.fps:
                    late += 1
                    # Do not send a backlog of catch-up bursts.
                    frame = int((time.monotonic() - start) * a.fps)
                sizes = packet_sizes(frame_bytes(a.mbps, a.fps, frame), a.packet_size)
                for i, size in enumerate(sizes):
                    sent += sock.send(packet(sequence, frame, i, len(sizes), time.monotonic_ns(), size))
                    sequence += 1
                frame += 1
        except (OSError, KeyboardInterrupt) as e:
            print(json.dumps(dict(error=str(e), **summary(a.mode, sent, sequence, time.monotonic() - start, late))))
            return 1
        print(json.dumps(summary(a.mode, sent, sequence, time.monotonic() - start, late), sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except OSError as error:
        print(json.dumps({'error': str(error)}))
        raise SystemExit(1)
