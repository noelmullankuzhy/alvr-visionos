#!/usr/bin/env python3
"""Verify app-submitted corner chart pixels; Python 3.9+, standard library only."""
import argparse
import bisect
import json
import math
from pathlib import Path
import struct
import sys
import zlib


def write_png(path, width, height, rgba):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    if len(rgba) != width * height * 4:
        raise ValueError('RGBA size mismatch')
    rows = b''.join(b'\0' + bytes(rgba[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def read_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not PNG')
    pos, packed = 8, bytearray()
    while pos < len(data):
        length = struct.unpack_from('!I', data, pos)[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        crc = struct.unpack_from('!I', data, pos + 8 + length)[0]
        if zlib.crc32(kind + body) & 0xffffffff != crc:
            raise ValueError('PNG CRC mismatch')
        if kind == b'IHDR':
            w, h, depth, colour, compression, filtering, interlace = struct.unpack('!2I5B', body)
            if (depth, colour, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError('requires non-interlaced 8-bit RGBA PNG')
        elif kind == b'IDAT':
            packed.extend(body)
        pos += length + 12
        if kind == b'IEND':
            break
    raw = zlib.decompress(packed)
    stride = w * 4
    if len(raw) != h * (stride + 1):
        raise ValueError('PNG decoded size mismatch')
    out, previous = bytearray(), bytearray(stride)
    for y in range(h):
        start = y * (stride + 1)
        filt, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if filt > 4:
            raise ValueError('invalid PNG filter')
        if filt == 0:
            out.extend(row)
            previous = row
            continue
        for x in range(stride):
            a, b, c = (row[x - 4] if x >= 4 else 0), previous[x], (previous[x - 4] if x >= 4 else 0)
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            predictor = [0, a, b, (a + b) // 2, a if pa <= pb and pa <= pc else b if pb <= pc else c][filt]
            row[x] = (row[x] + predictor) & 255
        out.extend(row)
        previous = row
    return w, h, bytes(out)


def interpolate(table, x):
    x = min(max(x, 0), len(table) - 1)
    i = min(int(x), len(table) - 2)
    return table[i] + (table[i + 1] - table[i]) * (x - i)


def inverse(table, p):
    i = min(max(bisect.bisect_right(table, p) - 1, 0), len(table) - 2)
    return i + (p - table[i]) / (table[i + 1] - table[i])


def tables(s):
    m = s['rate_map']
    for axis, size in [('x', 'w'), ('y', 'h')]:
        a = m['physical_' + axis]
        if len(a) != m['screen_' + size] + 1 or not all(math.isfinite(x) for x in a) or not all(b > a for a, b in zip(a, a[1:])):
            raise ValueError('invalid rate table ' + axis)
    return m['physical_x'], m['physical_y']


def verify(directory):
    metadata = json.loads((directory / 'capture.json').read_text())
    chart = metadata['corner_chart']
    rings = chart['ring_percents']
    centered = chart.get('ring_stroke_alignment') == 'center'
    if not rings or not metadata['slices'] or len(set(rings)) != len(rings) or not all(0 < r <= 100 for r in rings):
        raise ValueError('requires slices and distinct ring percentages in (0,100]')
    failed = False
    verified = 0
    for s in metadata['slices']:
        eye = s['eye']
        if metadata['corner_chart']['mode'] == 'Off':
            raise ValueError('corner chart was off; no ring proof available')
        if metadata['corner_chart']['mode'] in ('Left only', 'Right only') and eye != ('L' if metadata['corner_chart']['mode'] == 'Left only' else 'R'):
            print(eye + ' unlit: skipped')
            continue
        verified += 1
        w, h, pixels = read_png(directory / s['png'])
        if (w, h) != (s['width'], s['height']):
            raise ValueError('texture/PNG size mismatch')
        xt, yt = tables(s)
        vx, vy, vw, vh = s['viewport']
        left, right, bottom, top = s['tangents']
        cx, cy = vx + vw * left / (left + right), vy + vh * top / (bottom + top)
        px, py = interpolate(xt, cx), interpolate(yt, cy)
        def coloured(x, y):
            if not (0 <= x < w and 0 <= y < h):
                return False
            r, g, b, a = pixels[(y * w + x) * 4:(y * w + x) * 4 + 4]
            return a > 200 and b > 200 and ((g > 200 and r < 80) if eye == 'L' else (r > 200 and g < 80))
        for axis, table, centre, fixed, limit, sign, extent in [
                ('right', xt, px, py, w, 1, right), ('left', xt, px, py, w, -1, left),
                ('up', yt, py, px, h, -1, top), ('down', yt, py, px, h, 1, bottom)]:
            horizontal = axis in ('left', 'right')
            indices = range(max(0, min(limit - 1, int(centre))), limit if sign > 0 else -1, sign)
            crossings, run = [], []
            for i in indices:
                hit = coloured(i, int(fixed)) if horizontal else coloured(int(fixed), i)
                if hit:
                    run.append(i)
                elif run:
                    crossings.append((min(run), max(run) + 1))
                    run = []
            if run:
                crossings.append((min(run), max(run) + 1))
            used = set()
            for ring in sorted(rings):
                tangent = sign * extent * ring / 100
                expected_l = (vx + vw * (left + tangent) / (left + right)) if horizontal else (vy + vh * (top + tangent) / (bottom + top))
                expected_p = interpolate(table, expected_l)
                candidates = []
                for i, (lo, hi) in enumerate(crossings):
                    if i in used:
                        continue
                    # Interior D9 strokes straddle the mathematical ring; the 100% border
                    # is shifted inward by clipping. Older charts used inward strokes everywhere.
                    p = (lo + hi) / 2 if centered and ring != 100 else (hi if sign > 0 else lo)
                    candidates.append((abs(p - expected_p), i, p))
                best = min(candidates) if candidates else None
                ok = best is not None and best[0] <= 1.5
                failed |= not ok
                prefix = '{} {} ring={} {}'.format(eye, axis, ring, 'OK' if ok else 'FAIL')
                if best:
                    err, index, found_p = best
                    # Only consume plausible crossings, so a missing ring doesn't steal the next one.
                    if err < 6:
                        used.add(index)
                    found_l = inverse(table, found_p)
                    found_t = ((found_l - vx) / vw * (left + right) - left) if horizontal else (top - (found_l - vy) / vh * (bottom + top))
                    print('{} expected physical={:.3f} logical={:.3f} found physical={:.3f} logical={:.3f} tan_norm={:.6f} error_px={:.3f}'.format(prefix, expected_p, expected_l, found_p, found_l, abs(found_t) / extent, err))
                else:
                    print('{} missing expected physical={:.3f} logical={:.3f}'.format(prefix, expected_p, expected_l))
        scale = min(1, 1600 / vw)
        pw, ph = max(1, round(vw * scale)), max(1, round(vh * scale))
        preview = bytearray(pw * ph * 4)
        xs = [min(w - 1, max(0, int(interpolate(xt, vx + (x + .5) / scale)))) for x in range(pw)]
        for y in range(ph):
            sy = min(h - 1, max(0, int(interpolate(yt, vy + (y + .5) / scale))))
            for x, sx in enumerate(xs):
                preview[(y * pw + x) * 4:(y * pw + x + 1) * 4] = pixels[(sy * w + sx) * 4:(sy * w + sx + 1) * 4]
        write_png(directory / (Path(s['png']).stem + '-logical.png'), pw, ph, preview)
    if not verified:
        raise ValueError('no lit chart slices to verify')
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        return verify(args.directory)
    except (ValueError, KeyError, OSError, struct.error, zlib.error) as error:
        print('capture invalid: ' + str(error), file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
