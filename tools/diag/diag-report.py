#!/usr/bin/env python3
"""Turn pulled diag-*.log files into a reproducible Markdown measurement report."""
import argparse
from collections import defaultdict
import html
import importlib.util
import json
import math
from pathlib import Path
import re
import struct
import sys
import zlib

SECTIONS = (
    'Device / OS / build and session timeline', 'M1 formats / API and codec audit',
    'M5 drawable / rasterization maps and render-quality sweep',
    'M6 cadence', 'M9 thermal / memory / GPU', 'M2 EDR ramp / thresholds',
    'M3 PQ player', 'M7 decode', 'M8 network', 'Corner chart',
    'Eye badges and Diag file health', 'Boundary dots', 'Resolution measurement',
)
RRM_DEGREES = ('-40', '-30', '-20', '-10', '-5', '0', '5', '10', '20', '30', '40')
TOKEN = re.compile(r'([A-Za-z0-9_.]+)=("(?:[^"\\\x00-\x1f]|\\["\\nrt])*"|[^\s"=]+)(?=\s|$)')
HEADER = re.compile(r'DIAG ([A-Za-z0-9_.]+) t_ms=([0-9]+)(?=\s|$)')
NO = 'no data'


def number(value):
    """Missing, nonfinite, and nonnumeric measurements never become zero."""
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError, OverflowError):
        return None


def fmt(value):
    return NO if value is None else '{:g}'.format(value)


def cell(value):
    if value is None or str(value).lower() in ('unavailable', 'nan', 'inf', '-inf'):
        return NO
    return html.escape(str(value), quote=False).replace('|', '&#124;').replace('\n', '<br>').replace('\r', '').replace('\t', '    ')


def parse_line(line, source):
    match = HEADER.match(line)
    if not match:
        raise ValueError('invalid DIAG header')
    fields = {}
    rest = line[match.end():]
    while rest:
        rest = rest.lstrip()
        if not rest:
            break
        token = TOKEN.match(rest)
        if not token or token[1] in fields or token[1] == 't_ms':
            raise ValueError('invalid or duplicate field')
        raw = token[2]
        fields[token[1]] = json.loads(raw) if raw.startswith('"') else raw
        rest = rest[token.end():]
    return dict(topic=match[1], t_ms=int(match[2]), fields=fields, source=source)


def natural_key(path):
    match = re.fullmatch(r'(diag-.+?)(?:-(\d+))?\.log', path.name)
    base = match[1] if match else path.name
    rotation = int(match[2] or 0) if match else 0
    return ([int(p) if p.isdigit() else p for p in re.split(r'(\d+)', base)], rotation)


def read_logs(directory):
    records, malformed, errors = [], [], []
    for path in sorted(directory.glob('diag-*.log'), key=natural_key):
        try:
            with path.open('rb') as stream:
                for index, raw in enumerate(stream, 1):
                    source = '{}:{}'.format(path.name, index)
                    try:
                        records.append(parse_line(raw.decode('utf-8').rstrip('\r\n'), source))
                    except (ValueError, UnicodeError):
                        malformed.append(source)
        except OSError as error:
            errors.append('{}: {}'.format(path.name, error))
    return records, malformed, errors


def reject_json_constant(value):
    raise ValueError('nonfinite JSON number: ' + value)


def read_sender(path):
    """Read netprobe-ladder's metadata -> timed steps -> footer contract."""
    records, malformed = [], []
    if path is None:
        return records, malformed
    stage, previous_end, frames = 'metadata', 0.0, 0
    with path.open('rb') as stream:
        for index, raw in enumerate(stream, 1):
            source = '{}:{}'.format(path.name, index)
            try:
                obj = json.loads(raw.decode('utf-8'), parse_constant=reject_json_constant)
                if not isinstance(obj, dict):
                    raise ValueError('expected a JSON object')
                if stage == 'metadata':
                    kind = 'metadata'
                    numeric = ('start_wall', 'port', 'fps', 'packet_size')
                    integers = ('port', 'fps', 'packet_size')
                    if not isinstance(obj.get('host'), str) or not obj['host']:
                        raise ValueError('metadata requires host')
                elif stage == 'steps' and 't_start_s' in obj:
                    kind = 'step'
                    numeric = ('t_start_s', 'mbps_req', 'sent_mbps', 'late_frames',
                               'send_errors', 'frames', 'elapsed_s')
                    integers = ('late_frames', 'send_errors', 'frames')
                elif stage == 'steps' and records[-1]['kind'] == 'step':
                    kind = 'footer'
                    numeric = ('total_s', 'packets', 'frames')
                    integers = ('packets', 'frames')
                else:
                    raise ValueError('unexpected sender record')
                for key in numeric:
                    if not isinstance(obj.get(key), (int, float)) or isinstance(obj[key], bool) or number(obj[key]) is None or obj[key] < 0:
                        raise ValueError('missing or invalid number')
                if any(not isinstance(obj[key], int) for key in integers):
                    raise ValueError('expected integer count')
                if kind == 'metadata':
                    if not 1 <= obj['port'] <= 65535 or obj['fps'] <= 0 or not 28 <= obj['packet_size'] <= 65507:
                        raise ValueError('invalid metadata')
                    stage = 'steps'
                elif kind == 'step':
                    if obj['mbps_req'] <= 0 or obj['elapsed_s'] <= 0 or obj['frames'] <= 0 or obj['t_start_s'] < previous_end - 0.002:
                        raise ValueError('invalid or overlapping step')
                    previous_end = obj['t_start_s'] + obj['elapsed_s']
                    frames += obj['frames']
                else:
                    if obj['total_s'] < previous_end - 0.002 or obj['frames'] != frames:
                        raise ValueError('footer disagrees with steps')
                    stage = 'finished'
                records.append(dict(fields=obj, source=source, kind=kind))
            except (ValueError, UnicodeError, TypeError):
                malformed.append(source)
    return records, malformed


def table(rows, columns):
    if not rows:
        return [NO]
    return ['| ' + ' | '.join(map(cell, columns)) + ' |',
            '| ' + ' | '.join('---' for _ in columns) + ' |'] + [
                '| ' + ' | '.join(cell(row.get(c)) for c in columns) + ' |' for row in rows]


def measurements(records, required=()):
    """Keep every emitted field, including fields introduced by later client builds."""
    columns = ['source', 'topic', 't_ms'] + list(required)
    for record in records:
        for key in record['fields']:
            if key not in columns:
                columns.append(key)
    rows = [dict(record['fields'], source=record['source'], topic=record['topic'],
                 t_ms=record['t_ms']) for record in records]
    return table(rows, columns)


def section(title, records, extra_sources=()):
    sources = list(dict.fromkeys([r['source'] for r in records] + list(extra_sources)))
    return ['## ' + title, '', 'Sources: ' + (', '.join(map(cell, sources)) if sources else NO), '']


def decode_status(fields, hz):
    fps, sessions = number(fields.get('fps')), number(fields.get('sessions'))
    drops = number(fields.get('dropped'))
    if fields.get('hw') == 'false' or drops is not None and drops > 0 or fields.get('err') not in (None, '0'):
        return 'FAIL'
    if fps is None or sessions is None or sessions <= 0 or drops is None or fields.get('hw') != 'true' or fields.get('err') != '0':
        return NO
    if drops != 0 or fps < 0:
        return NO
    return 'PASS' if fps / sessions >= hz else 'FAIL'


def network_runs(records):
    """Counters are cumulative; interval rates are not. Never sum final + intervals."""
    runs, current = [], []
    for record in records:
        fields = record['fields']
        if 'mbps' not in fields:
            continue
        if current:
            previous = current[-1]['fields']
            now_s, prev_s = number(fields.get('seconds')), number(previous.get('seconds'))
            if (fields.get('mode') != previous.get('mode') or
                    now_s is not None and prev_s is not None and now_s < prev_s):
                runs.append(current)
                current = []
        current.append(record)
        if fields.get('summary') == 'true':
            runs.append(current)
            current = []
    if current:
        runs.append(current)
    return runs


# All three clocks in these logs are unrelated. active_seconds is the sink's
# first-to-last receipt duration; it removes time spent listening before receipt.
# JSON times are rounded to milliseconds on both hosts. This tolerance only
# accommodates that rounding; it is not a network latency correction.
TIME_EPSILON = 0.002
COUNTERS = ('bytes', 'loss', 'reorder', 'duplicates', 'stale', 'invalid',
            'foreign', 'frame_complete', 'hist_overflow')


def network_intervals(run):
    """Difference cumulative counters on the first-receipt time axis."""
    # Percentiles/counters may change without a visible increase in the rounded
    # active_seconds (e.g. a late loss repair in the final summary). Keep the
    # latest snapshot at that endpoint before differencing, including its source.
    snapshots = []
    for record in run:
        end = number(record['fields'].get('active_seconds'))
        if snapshots and end is not None and end == number(snapshots[-1]['fields'].get('active_seconds')):
            snapshots[-1] = record
        else:
            snapshots.append(record)
    intervals, previous = [], None
    for record in snapshots:
        f = record['fields']
        end = number(f.get('active_seconds'))
        start = number(previous['fields'].get('active_seconds')) if previous else 0.0
        if end is not None and start is not None and end > start:
            deltas = {}
            for key in COUNTERS:
                before = number(previous['fields'].get(key)) if previous else 0
                after = number(f.get(key))
                value = after - before if before is not None and after is not None else None
                # Loss alone can decrease when late packets repair old gaps.
                deltas[key] = value if value is None or value >= 0 or key == 'loss' else None
            intervals.append(dict(start=start, end=end, deltas=deltas, record=record,
                                  baseline=previous['source'] if previous else 'run origin (zero counters)'))
        previous = record
    return intervals


def knee_passes(loss_pct, completion_p99_ms, fps):
    """Both independent measured thresholds must be available and pass."""
    return (loss_pct is not None and completion_p99_ms is not None and fps is not None and
            fps > 0 and 0 <= loss_pct <= 0.1 and 0 <= completion_p99_ms <= 1000 / fps)


def network_report(records, senders, alignment_ok=True):
    lines = [
        'One continuous sender ladder corresponds to one UDP sink run. '
        'Step bounds are t_start_s .. t_start_s + elapsed_s, relative to the first sender step. '
        'Sink interval endpoints use active_seconds (first-to-last receipt), excluding listener idle time. '
        'This aligns relative receipt times, not host wall clocks or absolute one-way latency.', '',
        'Received rates and counter deltas below cover only wholly contained receipt intervals; '
        'coverage_s and whole_step state their scope. Boundary-crossing intervals are not prorated. '
        'Counter differences can include repairs of loss from earlier steps. '
        'Per-step jitter and cumulative p99 cannot be obtained by subtracting run snapshots. '
        'Loss percent requires a matching packet denominator; the footer only supplies a run total. '
        'Trailing loss remains unknown.', '',
    ]
    metadata = next((r for r in senders if r['kind'] == 'metadata'), None)
    steps = [r for r in senders if r['kind'] == 'step']
    footer = next((r for r in senders if r['kind'] == 'footer'), None)
    runs = network_runs(records)
    udp_runs = [run for run in runs if run[0]['fields'].get('mode') == 'udp']
    aligned = alignment_ok and metadata is not None and len(udp_runs) == 1
    if not alignment_ok:
        lines += ['sender alignment disabled: malformed sender lines.', '']
    elif metadata is not None and len(udp_runs) != 1:
        lines += ['sender alignment disabled: expected exactly one UDP sink run; found {}.'.format(len(udp_runs)), '']
    run = udp_runs[0] if aligned else []
    intervals = network_intervals(run)
    fps = number(metadata['fields'].get('fps')) if metadata else None
    origin = number(steps[0]['fields'].get('t_start_s')) if steps else 0
    passing = []
    for index, step in enumerate(steps, 1):
        sf = step['fields']
        start = sf['t_start_s'] - origin
        end = start + sf['elapsed_s']
        contained = [window for window in intervals
                     if window['start'] >= start - TIME_EPSILON and window['end'] <= end + TIME_EPSILON]
        whole = bool(contained and abs(contained[0]['start'] - start) <= TIME_EPSILON and
                     abs(contained[-1]['end'] - end) <= TIME_EPSILON and
                     all(abs(a['end'] - b['start']) <= TIME_EPSILON for a, b in zip(contained, contained[1:])))

        def delta(key):
            values = [window['deltas'][key] for window in contained]
            return sum(values) if values and all(value is not None for value in values) else None

        byte_count, loss, reorder = delta('bytes'), delta('loss'), delta('reorder')
        duration = sum(w['end'] - w['start'] for w in contained)
        rate = byte_count * 8 / duration / 1e6 if byte_count is not None and byte_count >= 0 and duration > 0 else None
        # A prefix from run origin has the same distribution scope as the first
        # step. Later steps' percentiles cannot be recovered from cumulative p99s.
        last = contained[-1]['record']['fields'] if contained else {}
        prefix = whole and abs(start) <= TIME_EPSILON
        completed = delta('frame_complete')
        tail = number(last.get('spread_p99_ms', last.get('burst_tail_p99_ms'))) if prefix else None
        if completed is None or completed <= 0 or delta('hist_overflow') != 0:
            tail = None
        packets = number(footer['fields'].get('packets')) if footer and len(steps) == 1 and whole else None
        loss_pct = 100 * loss / packets if packets is not None and packets > 0 and loss is not None and 0 <= loss <= packets else None
        final = bool(run and run[-1]['fields'].get('summary') == 'true')
        eligible = whole and final and footer is not None and sf['send_errors'] == 0 and byte_count is not None and byte_count > 0
        passed = eligible and knee_passes(loss_pct, tail, fps)
        if passed:
            passing.append((sf['mbps_req'], index))
        coverage = '{}..{}'.format(fmt(contained[0]['start']), fmt(contained[-1]['end'])) if contained else NO
        lines += ['### Step {} (UDP ladder)'.format(index), '',
                  'Sources: ' + ', '.join(map(cell, [step['source']] + [w['record']['source'] for w in contained])), '',
                  'time_s={}..{}; requested={} Mb/s; sent={} Mb/s; received={} Mb/s; '
                  'coverage_s={}; whole_step={}; loss_delta={}; reorder_delta={}; loss_pct={}; '
                  'jitter_ms=no data; completion_p99_ms={}; frame_period_ms={}; knee eligibility={}.'.format(
                      fmt(start), fmt(end), fmt(sf['mbps_req']), fmt(sf['sent_mbps']), fmt(rate),
                      coverage, str(whole).lower(), fmt(loss), fmt(reorder), fmt(loss_pct), fmt(tail),
                      fmt(1000 / fps if fps else None), 'PASS' if passed else ('FAIL' if eligible and loss_pct is not None and tail is not None else NO)), '']
        window_rows = []
        for window in contained:
            row = dict(window['deltas'], start_s=fmt(window['start']), end_s=fmt(window['end']),
                       source=window['record']['source'], baseline=window['baseline'])
            window_rows.append(row)
        lines += table(window_rows, ('start_s', 'end_s') + COUNTERS + ('source', 'baseline')) + ['']
    boundaries = [sf['fields']['t_start_s'] - origin for sf in steps[1:]]
    crossing = []
    for window in intervals:
        if any(window['start'] + TIME_EPSILON < bound < window['end'] - TIME_EPSILON for bound in boundaries):
            crossing.append(dict(source=window['record']['source'], start_s=fmt(window['start']),
                                 end_s=fmt(window['end']), note='crosses step boundary'))
    if crossing:
        lines += table(crossing, ('source', 'start_s', 'end_s', 'note')) + ['']
    best = max(passing) if passing else None
    lines += ['Knee: {}{}'.format(fmt(best[0]) + ' Mb/s' if best else NO,
                                  ' (step {})'.format(best[1]) if best else ''), '']
    if len(steps) > 1:
        lines += ['Per-step packet denominators: no data (footer packets cover the entire ladder). '
                  'Later-step completion p99: no data (only cumulative distributions are logged).', '']
    if metadata and not footer:
        lines += ['Sender footer: no data (incomplete ladder).', '']
    if run and run[-1]['fields'].get('summary') != 'true':
        lines += ['Sink final summary: no data (incomplete run).', '']
    lines += ['Sender metadata, steps and footer (original fields):', '']
    for sender in senders:
        lines += table([dict(sender['fields'], source=sender['source'])], ['source'] + list(sender['fields'])) + ['']
    lines += ['Sink run snapshots (original fields; percentiles and jitter are cumulative run state):', '']
    lines += measurements(records) + ['']
    tcp = [r for r in records if r['fields'].get('mode') == 'tcp' and 'mbps' in r['fields']]
    lines += ['TCP bulk throughput (recorded mbps):', ''] + measurements(tcp, ('mbps', 'summary')) + ['']
    return lines


def codec_rows(records):
    hardware, rows = {}, []
    for record in records:
        f = record['fields']
        if record['topic'] == 'm1':
            hardware = {}
        if record['topic'] != 'codec':
            continue
        codec = f.get('type')
        if 'hw' in f:
            hardware[codec] = record
        support = hardware.get(codec)
        row = dict(f)
        row['hw'] = f.get('hw', support['fields'].get('hw') if support else None)
        row['source'] = record['source']
        row['hardware_source'] = support['source'] if support else None
        rows.append(row)
    return rows


def corner_rows(records):
    marks, rows = {}, []
    for record in records:
        f = record['fields']
        if record['topic'] == 'm1' or record['topic'] == 'corner' and f.get('chart') == 'on':
            marks = {}
        eye = f.get('eye')
        if record['topic'] == 'corner' and 'ring_pct' in f:
            angle = number(f.get('pos_deg'))
            if angle is not None:
                marks[(eye, angle)] = record
        if record['topic'] == 'corner_summary':
            radii = f.get('r', '').split(',')
            octagon = f.get('shape') == 'octagon'
            angles = range(0, 360, 45) if octagon else [k * 22.5 for k in range(16)] if len(radii) == 16 else []
            for spoke, angle in enumerate(angles):
                mark = marks.get((eye, angle))
                rows.append(dict(eye=eye, pos_deg=fmt(angle),
                                 ring_pct=mark['fields'].get('ring_pct') if mark else None,
                                 kind=mark['fields'].get('kind') if mark else None,
                                 radius=None if octagon else radii[spoke], shape=f.get('shape'),
                                 superellipse_n=f.get('superellipse_n'), area_frac=f.get('area_frac'),
                                 sides=f.get('sides'), cuts=f.get('cuts'), visible_area_frac=f.get('visible_area_frac'),
                                 summary_source=record['source'],
                                 mark_source=mark['source'] if mark else None))
            # A completed walk must not supply rings for a later partial walk.
            marks = {key: value for key, value in marks.items() if key[0] != eye}
    return rows


def dots_coordinates(yaw, pitch, tangents):
    """Signed side percentages and affine drawable [0,1] coordinates.

    Head-frame projected angles approximate eye-origin rays, without eye cant
    correction. Separate side percentages must not be used as affine area units.
    """
    if tangents is None or len(tangents) != 4:
        return None
    values = [number(v) for v in (yaw, pitch) + tuple(tangents)]
    if any(v is None for v in values) or any(v <= 0 for v in values[2:]):
        return None
    yaw, pitch, left, right, bottom, top = values
    if abs(yaw) >= 90 or abs(pitch) >= 90:
        return None
    x, y = math.tan(math.radians(yaw)), math.tan(math.radians(pitch))
    x = 0.0 if abs(x) < 1e-12 else x
    y = 0.0 if abs(y) < 1e-12 else y
    return dict(x_pct=100 * x / (right if x >= 0 else left),
                y_pct=100 * y / (top if y >= 0 else bottom),
                u=(x + left) / (left + right), v=(y + bottom) / (bottom + top))


def dots_direction(ray, ecc):
    """Return projected yaw/pitch for a point on the specified dot lattice.

    Main rays every 15 degrees start at 10 degrees; intermediate rays (odd multiples
    of 7.5 degrees) start at 20 degrees.
    """
    ray, ecc = number(ray), number(ecc)
    if (ray is None or ecc is None or not 0 <= ray < 360 or not 10 <= ecc <= 70
            or abs(ray / 7.5 - round(ray / 7.5)) > 1e-7
            or abs((ecc - 10) / 2.5 - round((ecc - 10) / 2.5)) > 1e-7
            or round(ray / 7.5) % 2 == 1 and ecc < 20):
        return None
    r, e = math.radians(ray), math.radians(ecc)
    return dict(ray_deg=ray, ecc_deg=ecc,
                yaw_deg=math.degrees(math.atan2(math.sin(e) * math.cos(r), math.cos(e))),
                pitch_deg=math.degrees(math.atan2(math.sin(e) * math.sin(r), math.cos(e))))


def dots_boundaries(records):
    """Replay marks, preserving separate L/R/Both labels and each measurement walk.

    A summary is authoritative (even if earlier marks were rotated out of logs).
    Use the latest preceding M5 per eye in this app session, never future views.
    """
    tangents, active, rows = {}, {}, []

    def snapshot(label, points, source, count, valid=True):
        for eye in (('L', 'R') if label == 'Both' else (label,)):
            view = tangents.get(eye)
            values = None
            if view:
                values = tuple(number(v) for v in view['fields'].get('tangents', '').split(','))
            converted = []
            for point in points:
                coords = dots_coordinates(point['yaw_deg'], point['pitch_deg'], values)
                converted.append(dict(point, **(coords or dict(x_pct=None, y_pct=None, u=None, v=None))))
            main_rays = {p['ray_deg'] for p in points if round(p['ray_deg'] / 7.5) % 2 == 0}
            complete = valid and len(main_rays) == 24 and all(p['u'] is not None for p in converted)
            area = None
            if complete:
                area = abs(sum(a['u'] * b['v'] - b['u'] * a['v']
                               for a, b in zip(converted, converted[1:] + converted[:1]))) / 2
            rows.append(dict(label=label, eye=eye, points=converted, confirmed_points=count,
                             visible_area_frac=area, source=source,
                             tangent_source=view['source'] if view else None,
                             status='complete' if complete else ('incomplete or missing tangents' if valid else 'invalid summary')))

    def flush():
        for label, state in active.items():
            outer = {}
            for point in state['marks'].values():
                ray = point['ray_deg']
                if ray not in outer or point['ecc_deg'] > outer[ray]['ecc_deg']:
                    outer[ray] = point
            snapshot(label, [outer[r] for r in sorted(outer)], state['source'], len(state['marks']))
        active.clear()

    for record in records:
        f, topic = record['fields'], record['topic']
        if topic == 'm1':
            flush()
            tangents.clear()
        elif topic == 'dots_session' and f.get('event') == 'begin':
            flush()
        elif topic == 'm5_view':
            eye = f.get('eye', {'0': 'L', '1': 'R'}.get(f.get('view')))
            if eye in ('L', 'R'):
                tangents[eye] = record
        elif topic == 'dots' and f.get('eye') in ('L', 'R', 'Both'):
            point = dots_direction(f.get('ray_deg'), f.get('ecc_deg'))
            yaw, pitch = number(f.get('yaw_deg')), number(f.get('pitch_deg'))
            if point is None or yaw is None or pitch is None or abs(yaw) >= 90 or abs(pitch) >= 90:
                continue
            label, action = f['eye'], f.get('action')
            if action not in ('confirm', 'clear'):
                continue
            state = active.setdefault(label, dict(marks={}, source=record['source']))
            key = (point['ray_deg'], point['ecc_deg'])
            state['source'] = record['source']
            if action == 'confirm':
                # Stepping logs have one boundary per ray; legacy D11 logs
                # omit via and retain their multiple-mark/outermost semantics.
                if f.get('via') in ('gaze', 'step'):
                    state['marks'] = {k: v for k, v in state['marks'].items() if k[0] != key[0]}
                state['marks'][key] = dict(point, yaw_deg=yaw, pitch_deg=pitch)
            else:
                state['marks'].pop(key, None)
        elif topic == 'dots_summary' and f.get('eye') in ('L', 'R', 'Both'):
            label, points, valid = f['eye'], [], True
            count = number(f.get('points'))
            raw = f.get('rays', '')
            if raw != 'none':
                for pair in raw.split(','):
                    parts = pair.split(':')
                    point = dots_direction(*parts) if len(parts) == 2 else None
                    if point is None or any(p['ray_deg'] == point['ray_deg'] for p in points):
                        valid = False
                        break
                    points.append(point)
            valid = valid and count is not None and count.is_integer() and len(points) <= count <= DOTS_LAYOUT_COUNT
            snapshot(label, sorted(points, key=lambda p: p['ray_deg']) if valid else [],
                     record['source'], count, valid)
            active.pop(label, None)
    flush()
    return rows


DOTS_LAYOUT_COUNT = 24 * 25 + 24 * 21
# Device m5_view tangents (left,right,bottom,top), 21 Oct, used by the app until a Metal session logs its own.
OUTLINE_DEVICE_TANGENTS = {'L': (1.7321, 1.0, 1.1918, 1.0), 'R': (1.0, 1.7321, 1.1918, 1.0)}


def outline_edge_ecc(ray, tangents):
    """Eccentricity (degrees) where the ray at `ray` degrees (CCW from right) meets the frustum edge."""
    left, right, bottom, top = tangents
    c, s = math.cos(math.radians(ray)), math.sin(math.radians(ray))
    reach = [right / c if c > 1e-12 else None, left / -c if c < -1e-12 else None,
             top / s if s > 1e-12 else None, bottom / -s if s < -1e-12 else None]
    return math.degrees(math.atan(min(r for r in reach if r is not None)))


def outline_ecc(ray, inset, tangents):
    return max(0.0, outline_edge_ecc(ray, tangents) - inset)


def outline_points(inset, tangents):
    """The app's closed polygon: rays every 5 degrees plus the four corner rays, inset along each ray."""
    left, right, bottom, top = tangents
    corners = [math.degrees(math.atan2(y, x)) % 360 for x, y in
               ((right, top), (-left, top), (-left, -bottom), (right, -bottom))]
    rays = []
    for ray in sorted(list(range(0, 360, 5)) + corners):
        if not rays or ray - rays[-1] > 1e-9:
            rays.append(ray)
    return [(ray, outline_ecc(ray, inset, tangents)) for ray in rays]


def outline_area_frac(inset, tangents):
    """Outline polygon area in tangent space over the frustum area."""
    left, right, bottom, top = tangents
    xy = [(math.tan(math.radians(e)) * math.cos(math.radians(r)), math.tan(math.radians(e)) * math.sin(math.radians(r)))
          for r, e in outline_points(inset, tangents)]
    twice = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))
    return abs(twice) / 2 / ((left + right) * (bottom + top))


def outline_limits(eye, inset, tangents):
    """(nasal, temporal, up, down) degrees: frustum side minus inset, clamped at 0. L nasal is its right side."""
    left, right, bottom, top = tangents

    def side(t):
        return max(0.0, math.degrees(math.atan(t)) - inset)
    nasal, temporal = (right, left) if eye == 'L' else (left, right)
    return side(nasal), side(temporal), side(top), side(bottom)


def outline_rays(text):
    """'0:37.5,15:35' -> {0.0: 37.5, 15.0: 35.0}; None if empty, nonfinite, out of range or repeated."""
    rays = {}
    for pair in (text or '').split(','):
        parts = pair.split(':')
        values = [number(v) for v in parts] if len(parts) == 2 else [None]
        if any(v is None for v in values) or not 0 <= values[0] < 360 or not 0 <= values[1] < 90 or values[0] in rays:
            return None
        rays[values[0]] = values[1]
    return rays or None


def lens_ecc(ray, rays):
    """Linear in eccentricity between the nearest logged rays on either side (circular), as the app draws."""
    ray = ray % 360
    if ray in rays:
        return rays[ray]
    keys = sorted(rays)
    below = max([k for k in keys if k < ray], default=keys[-1])
    above = min([k for k in keys if k > ray], default=keys[0])
    span = (above - below) % 360
    if span == 0:
        return rays[below]
    return rays[below] + ((ray - below) % 360) / span * (rays[above] - rays[below])


def lens_area_frac(rays, tangents):
    """Lens outline area in tangent space (rays every 5 degrees, interpolated) over the frustum area."""
    left, right, bottom, top = tangents
    xy = [(math.tan(math.radians(lens_ecc(r, rays))) * math.cos(math.radians(r)),
           math.tan(math.radians(lens_ecc(r, rays))) * math.sin(math.radians(r))) for r in range(0, 360, 5)]
    twice = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))
    return abs(twice) / 2 / ((left + right) * (bottom + top))


PROJECTION_BASE_RENDER = (3648, 2912)    # per-eye render at render_scale 1.0 (tools/fov-matrix/fovmatrix.py)
_FOV_OVERLAY = []


def fov_overlay():
    """fov-overlay.py (same directory), loaded once: ALVR's foveation model (fov_axis, band_fractions)."""
    if not _FOV_OVERLAY:
        import importlib.util
        spec = importlib.util.spec_from_file_location('fov_overlay', Path(__file__).with_name('fov-overlay.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _FOV_OVERLAY.append(module)
    return _FOV_OVERLAY[0]


def render_size(scale):
    """Per-eye render (w, h) at a points row's render_scale, rounded per side as fovmatrix.py render_size."""
    return int(round(PROJECTION_BASE_RENDER[0] * scale)), int(round(PROJECTION_BASE_RENDER[1] * scale))


def outline_bbox(points):
    """Tangent box (left, right, up, down; positive away from the eye axis) of a closed (ray, ecc) polygon:
    its vertices bound the drawn shape (ProjectionOverlay.bbox)."""
    xy = [(math.tan(math.radians(e)) * math.cos(math.radians(r)), math.tan(math.radians(e)) * math.sin(math.radians(r)))
          for r, e in points]
    return -min(x for x, _ in xy), max(x for x, _ in xy), max(y for _, y in xy), -min(y for _, y in xy)


def foveation_rect(eye, tangents, foveation, render):
    """ALVR's 1:1 foveation band (cx, cy, rx, ry, shx, shy at render (w, h)) as a tangent box (left, right, up, down)
    of the eye's frustum (left, right, bottom, top): eye UV x from the temporal edge (R mirrored), y from the top."""
    fo = fov_overlay()
    left, right, bottom, top = tangents
    cx, cy, rx, ry, shx, shy = foveation
    u0, u1 = fo.band_fractions(fo.fov_axis(cx, shx, rx, render[0]))
    v0, v1 = fo.band_fractions(fo.fov_axis(cy, shy, ry, render[1]))
    span_x, span_y = left + right, top + bottom
    up, down = top - v0 * span_y, v1 * span_y - top
    if eye == 'L':
        return left - u0 * span_x, u1 * span_x - left, up, down
    return u1 * span_x - right, right - u0 * span_x, up, down


def pxdeg_axis(render, box):
    """Predicted px/deg on the eye axis if `render` (w, h) pixels span `box` (left, right, up, down tangents):
    avp-sharpness.py's "centre", render px over the tan span x pi/180 inside the 1:1 band, the lower of h and v.
    The Swift twin is ProjectionOverlay.pxPerDegAxis; fixtures/projection-overlay.json pins both."""
    left, right, up, down = box
    return min(render[0] / (left + right), render[1] / (up + down)) * math.pi / 180


def number_list(text, count):
    values = [number(v) for v in (text or '').split(',')]
    return tuple(values) if len(values) == count and all(v is not None for v in values) else None


def projection_fields(f, points, tangents, eye):
    """The logged projection readout of a `dots_outline` line and its check against this file's formulas
    (bbox from the drawn polygon, px/deg from render_px, the foveation rect from the logged setting)."""
    out = dict(bbox_deg=number_list(f.get('bbox_deg'), 4), bbox_tan=number_list(f.get('bbox_tan'), 4),
               fov_source=f.get('fov_source'), fov_live=f.get('fov_live'), foveation=number_list(f.get('foveation'), 6),
               fov_rect_deg='off' if f.get('fov_rect_deg') == 'off' else number_list(f.get('fov_rect_deg'), 4),
               render_px=number_list(f.get('render_px'), 2),
               pxdeg_frustum=number(f.get('pxdeg_frustum')), pxdeg_bbox=number(f.get('pxdeg_bbox')))
    if out['render_px']:
        out['render_px'] = tuple(int(v) for v in out['render_px'])
    if any(out[k] is None for k in ('bbox_tan', 'render_px', 'pxdeg_frustum', 'pxdeg_bbox')):
        out['projection_check'] = 'not logged'
        return out
    left, right, bottom, top = tangents
    wrong = []
    if any(abs(a - b) > 1e-3 for a, b in zip(outline_bbox(points), out['bbox_tan'])):
        wrong.append('bbox')
    if abs(pxdeg_axis(out['render_px'], (left, right, top, bottom)) - out['pxdeg_frustum']) > 0.05:
        wrong.append('pxdeg_frustum')
    if abs(pxdeg_axis(out['render_px'], out['bbox_tan']) - out['pxdeg_bbox']) > 0.05:
        wrong.append('pxdeg_bbox')
    if out['foveation'] and isinstance(out['fov_rect_deg'], tuple):
        rect = foveation_rect(eye, tangents, out['foveation'], out['render_px'])
        if any(abs(math.degrees(math.atan(a)) - b) > 0.01 for a, b in zip(rect, out['fov_rect_deg'])):
            wrong.append('fov_rect')
    out['projection_check'] = 'mismatch: ' + ','.join(wrong) if wrong else 'ok'
    return out


def dots_outlines(records):
    """One row per `dots_outline` line (shape=lens: logged rays = reference + offset; shape=rect or
    absent: frustum minus inset), with the area it implies and, when the same log has confirmed
    dots for that eye (latest walk), the per-ray deviation dot minus outline. `session` is the latest
    `dots_session` begin in the same file; the projection fields are checked by `projection_fields`."""
    boundaries = {}
    for boundary in dots_boundaries(records):
        if boundary['label'] == boundary['eye']:
            boundaries[boundary['eye']] = boundary
    rows = []
    session, session_file = None, None
    for record in records:
        f = record['fields']
        source_file = record['source'].rsplit(':', 1)[0]
        if source_file != session_file:
            session, session_file = '{} (no dots_session begin)'.format(source_file), source_file
        if record['topic'] == 'dots_session' and f.get('event') == 'begin':
            session = record['source']
        if record['topic'] != 'dots_outline' or f.get('eye') not in ('L', 'R'):
            continue
        eye, shape = f['eye'], f.get('shape', 'rect')
        inset, offset, rays = number(f.get('inset_deg')), number(f.get('offset_deg')), None
        if shape == 'lens':
            rays = outline_rays(f.get('rays'))
            if offset is None or rays is None:
                continue
            inset = None
        elif shape != 'rect' or inset is None:
            continue
        tangents = tuple(number(v) for v in f.get('tangents', '').split(','))
        note = None
        if len(tangents) != 4 or any(v is None or v <= 0 for v in tangents):
            note = 'invalid tangents: device default' if 'tangents' in f else 'tangents not logged: device default'
            tangents = OUTLINE_DEVICE_TANGENTS[eye]

        def expected(ray):
            return lens_ecc(ray, rays) if rays else outline_ecc(ray, inset, tangents)
        deviations = []
        for point in (boundaries.get(eye) or {}).get('points', []):
            deviations.append(dict(ray_deg=point['ray_deg'], dot_ecc_deg=point['ecc_deg'],
                                   outline_ecc_deg=expected(point['ray_deg']),
                                   deviation_deg=point['ecc_deg'] - expected(point['ray_deg'])))
        worst = max(deviations, key=lambda d: abs(d['deviation_deg'])) if deviations else None
        points = [(r, lens_ecc(r, rays)) for r in range(0, 360, 5)] if rays else outline_points(inset, tangents)
        rows.append(dict(projection_fields(f, points, tangents, eye), session=session,
                         eye=eye, shape=shape, source=record['source'], inset_deg=inset, offset_deg=offset,
                         reference=f.get('reference'), rays=rays,
                         nasal_deg=number(f.get('nasal_deg')), temporal_deg=number(f.get('temporal_deg')),
                         up_deg=number(f.get('up_deg')), down_deg=number(f.get('down_deg')),
                         tangent_source=f.get('tangent_source'), tangents=tangents, tangent_note=note,
                         area_frac=lens_area_frac(rays, tangents) if rays else outline_area_frac(inset, tangents),
                         deviations=deviations,
                         max_dev_deg=abs(worst['deviation_deg']) if worst else None,
                         max_dev_ray=worst['ray_deg'] if worst else None))
    return rows


def outline_report(records):
    lines = ['### Outline slider', '',
             'Each `dots_outline` line is one LEFT slider step (0.5 deg), the settled value at a slider '
             'release, or a RIGHT hold with no cursor. shape=lens (default): the measured '
             'seal-on visible field of that eye (reference) moved radially by offset_deg (positive outward); rays '
             'lists the drawn eccentricity per measured ray and rays between them interpolate linearly in '
             'eccentricity. shape=rect (or no shape, older lines): the rendered frustum inset by inset_deg along '
             'every ray. Limits are the logged values at the 0/90/180/270 rays (rect: frustum sides minus the '
             'inset, clamped at 0), in degrees from the head axis. area_frac is the outline polygon area in tangent '
             'space over the frustum area (lens: 5-degree rays; rect: 5-degree rays plus corners, as drawn). '
             'deviation_deg is the confirmed dot eccentricity minus the outline on that ray (positive: the dot was '
             'seen outside the outline), against the latest walk of the same eye in these logs.', '',
             'Projection overlay columns (lines since the overlay): bbox_deg is the axis-aligned tangent box of the drawn '
             'outline, left,right,up,down degrees from the eye axis (head-frame sides, as the client reports fov '
             'tangents). It contains the outline, so its corners lie outside the visible field: it is the FOV to send so '
             'that every visible direction is rendered. fov_rect_deg is the 1:1 band of the foveated encoding '
             '(fov_source: a points-chart-avp.tsv row, fov_live=no, a preset shown when not streaming; or live, '
             'fov_live=yes) on the rendered frustum. pxdeg_frustum and '
             'pxdeg_bbox are the predicted px/deg on the eye axis at render_px over the frustum and over the bbox '
             '(avp-sharpness.py centre: the lower of h and v). projection_check recomputes bbox, px/deg and the '
             'foveation rect from the logged inputs (ok, mismatch: <fields>, or not logged).', '']
    rows = dots_outlines(records)

    def values(v):
        return v if isinstance(v, str) or v is None else ','.join(fmt(x) for x in v)
    for eye in ('L', 'R'):
        mine = [r for r in rows if r['eye'] == eye]
        lines += ['Outline eye={}'.format(eye), '']
        lines += table([dict({k: fmt(r[k]) for k in ('inset_deg', 'offset_deg', 'nasal_deg', 'temporal_deg', 'up_deg',
                                                    'down_deg', 'area_frac', 'max_dev_deg', 'max_dev_ray',
                                                    'pxdeg_frustum', 'pxdeg_bbox')},
                             source=r['source'], shape=r['shape'], reference=r['reference'],
                             tangent_source=r['tangent_source'],
                             tangents=','.join('{:g}'.format(t) for t in r['tangents']) +
                             (' ({})'.format(r['tangent_note']) if r['tangent_note'] else ''),
                             bbox_deg=values(r['bbox_deg']), fov_source=r['fov_source'], fov_live=r['fov_live'],
                             fov_rect_deg=values(r['fov_rect_deg']), projection_check=r['projection_check']) for r in mine],
                       ('source', 'shape', 'inset_deg', 'offset_deg', 'nasal_deg', 'temporal_deg', 'up_deg', 'down_deg',
                        'area_frac', 'max_dev_deg', 'max_dev_ray', 'reference', 'tangent_source', 'tangents',
                        'bbox_deg', 'fov_source', 'fov_live', 'fov_rect_deg', 'pxdeg_frustum', 'pxdeg_bbox', 'projection_check')) + ['']
        lens = [r for r in mine if r['rays']]
        if lens:
            lines += ['Per-ray outline, latest lens line ({}; reference + offset):'.format(cell(lens[-1]['source'])), '']
            lines += table([dict(ray_deg=fmt(ray), outline_ecc_deg=fmt(ecc)) for ray, ecc in sorted(lens[-1]['rays'].items())],
                           ('ray_deg', 'outline_ecc_deg')) + ['']
        if mine and mine[-1]['deviations']:
            lines += ['Per-ray deviation, latest outline ({}):'.format(cell(mine[-1]['source'])), '']
            lines += table([{k: fmt(v) for k, v in d.items()} for d in mine[-1]['deviations']],
                           ('ray_deg', 'dot_ecc_deg', 'outline_ecc_deg', 'deviation_deg')) + ['']
    return lines + projection_summary(rows)


def projection_summary(rows):
    """One `projection` line per Boundary dots session: the last logged projection readout per eye."""
    sessions = {}
    for row in rows:
        last = sessions.setdefault(row['session'], {})
        if row['projection_check'] != 'not logged':
            last[row['eye']] = row
    lines = ['### Projection', '', 'Last projection readout per eye in each session (gain = pxdeg_bbox / pxdeg_frustum).', '']
    for session, last in sessions.items():
        eyes = []
        for eye in ('L', 'R'):
            r = last.get(eye)
            if r is None:
                eyes.append('eye={} no data'.format(eye))
                continue
            rect = r['fov_rect_deg']
            eyes.append('eye={} source={} fov_source={} fov_live={} bbox_deg={} fov_rect_deg={} render_px={} pxdeg_frustum={} '
                        'pxdeg_bbox={} gain={:.2f} check={}'.format(
                            eye, r['source'], r['fov_source'], r['fov_live'] or '-', ','.join(fmt(v) for v in r['bbox_deg'] or ()),
                            rect if isinstance(rect, str) or rect is None else ','.join(fmt(v) for v in rect),
                            ','.join(str(v) for v in r['render_px']), fmt(r['pxdeg_frustum']), fmt(r['pxdeg_bbox']),
                            r['pxdeg_bbox'] / r['pxdeg_frustum'], r['projection_check']))
        lines += ['projection session={} {}'.format(session, '; '.join(eyes)), '']
    return lines if sessions else []


def dots_report(records):
    selected = [r for r in records if r['topic'] in ('dots', 'dots_summary', 'dots_session', 'dots_outline')]
    lines = section(SECTIONS[11], selected)
    lines += ['Angles use a head-vs-eye-origin approximation: head-frame projected yaw/pitch '
              '(tan(yaw)=x/-z, tan(pitch)=y/-z), without correcting eye position or cant. '
              'At 10 m and 64 mm IPD the per-eye offset is about 0.183 degrees. '
              'M5 view 0 is L, view 1 is R unless explicitly labelled; missing eyes are no data. '
              'Use the latest preceding m5_view tangents in the same app session. Both marks are '
              'converted separately for each eye; they are not two monocular measurements.', '',
              'x_pct/y_pct are signed percentages of the corresponding side tangent. '
              'u=(tan(yaw)+left)/(left+right), v=(tan(pitch)+bottom)/(bottom+top) '
              'are affine normalised drawable units. visible_area_frac is the shoelace area in '
              'these units, only with all 24 rays. Values are not clamped to the drawable. '
              'Missing rays are not interpolated. Summaries contain the outermost confirmed point '
              'on each ray and are authoritative; unsummarised marks are labelled by their last source.', '',
              'Resolution: 2.5 degrees radially, 7.5 degrees between rays (15 before the outline slider; '
              'intermediate rays start at 20 degrees); dots are 0.5 degree wide (1 degree before), gaze targets 2.2. '
              'Use cursor stepping to reach visible dots beyond gaze targeting. '
              'If no starting dot on a ray can be highlighted, record that tracker limit separately.', '']
    for boundary in dots_boundaries(records):
        lines += ['Marks={} → eye={}; source={}; tangent_source={}; confirmed_points={}; '
                  'rays={}; status={}; visible_area_frac={}'.format(
                      boundary['label'], boundary['eye'], cell(boundary['source']),
                      cell(boundary['tangent_source']), fmt(boundary['confirmed_points']),
                      len(boundary['points']), boundary['status'], fmt(boundary['visible_area_frac'])), '']
        lines += table([{k: fmt(v) for k, v in point.items()} for point in boundary['points']],
                       ('ray_deg', 'ecc_deg', 'yaw_deg', 'pitch_deg', 'x_pct', 'y_pct', 'u', 'v')) + ['']
    lines += outline_report(records)
    lines += measurements(selected, ('eye', 'action', 'ray_deg', 'ecc_deg', 'yaw_deg', 'pitch_deg', 'points', 'rays')) + ['']
    return lines


def deg_values(text):
    """'-40:19.60,0:40.00' -> {'-40': '19.60', '0': '40.00'} (logged text kept as is)."""
    values = {}
    for pair in (text or '').split(','):
        parts = pair.split(':')
        if len(parts) == 2 and number(parts[0]) is not None:
            values['{:g}'.format(number(parts[0]))] = parts[1]
    return values


def rrm_profiles(records):
    """Rendered physical px/deg per eye, render quality and foveation: the last centre-fixation sweep sample,
    else the last quality-step sample. One row per line through the eye axis (h: + right, v: + up)."""
    chosen = {}
    for record in records:
        f = record['fields']
        if record['topic'] != 'rrm' or f.get('eye') not in ('L', 'R'):
            continue
        key = (f.get('eye'), f.get('rq'), f.get('fov'))
        centre = f.get('phase') == 'sweep' and f.get('fix') == 'centre'
        if centre or key not in chosen or not chosen[key][0]:
            chosen[key] = (centre, record)
    rows = []
    for key in sorted(chosen, key=lambda k: tuple(str(v) for v in k)):
        record = chosen[key][1]
        f = record['fields']
        for line in ('h', 'v'):
            row = dict(eye=f.get('eye'), rq=f.get('rq'), fov=f.get('fov'), line=line, phase=f.get('phase'),
                       fix=f.get('fix'), map=f.get('map'), screen=f.get('screen'), physical=f.get('physical'),
                       peak_deg=f.get(line + '_peak_deg'), source=record['source'])
            row.update(deg_values(f.get(line + '_ppd')))
            rows.append(row)
    return rows


def rrm_gaze(records):
    """Per eye and 20 s sweep: does the rate map follow the fixation dot?

    fixed: one map hash and peaks within 1 degree across fixations. follows gaze: the horizontal peak moves
    at least 5 degrees towards left20 / right20 and the vertical one towards up15 / down15 (each pair logged).
    Otherwise: changes, not with gaze. Fewer than two fixations, or no rate map: no data.
    """
    runs, current = [], {}
    for record in records:
        f = record['fields']
        if record['topic'] == 'm1':
            current = {}
        if record['topic'] != 'rrm' or f.get('phase') != 'sweep' or f.get('eye') not in ('L', 'R'):
            continue
        eye, second = f['eye'], number(f.get('s'))
        run = current.get(eye)
        if run is None or second is None or second <= run['last']:
            run = dict(eye=eye, rq=f.get('rq'), fov=f.get('fov'), samples=[], last=-1, source=record['source'])
            current[eye] = run
            runs.append(run)
        run['last'] = second if second is not None else run['last']
        run['samples'].append(record)
    rows = []
    for run in runs:
        groups = defaultdict(list)
        for record in run['samples']:
            groups[record['fields'].get('fix')].append(record['fields'])
        peaks = {}
        for name, items in groups.items():
            h = [number(i.get('h_peak_deg')) for i in items]
            v = [number(i.get('v_peak_deg')) for i in items]
            h, v = [x for x in h if x is not None], [x for x in v if x is not None]
            peaks[name] = (sum(h) / len(h) if h else None, sum(v) / len(v) if v else None)
        hashes = {s['fields'].get('map_hash') for s in run['samples']} - {None, 'none'}
        mapped = any(s['fields'].get('map') == 'ok' for s in run['samples'])
        order = [n for n in ('centre', 'left20', 'right20', 'up15', 'down15') if n in peaks]
        verdict = 'no data'
        if mapped and len(peaks) >= 2 and 'centre' in peaks:
            ch, cv = peaks['centre']
            values = [p for p in peaks.values()]
            spread = max((max(xs) - min(xs) for xs in ([p[0] for p in values if p[0] is not None],
                                                         [p[1] for p in values if p[1] is not None]) if xs), default=0)

            def moved(name, axis, sign, centre):
                value = peaks.get(name, (None, None))[axis]
                return None if value is None or centre is None else sign * (value - centre) >= 5
            checks = [moved('left20', 0, -1, ch), moved('right20', 0, 1, ch), moved('up15', 1, 1, cv), moved('down15', 1, -1, cv)]
            checks = [c for c in checks if c is not None]
            if len(hashes) <= 1 and spread <= 1:
                verdict = 'fixed'
            elif checks and all(checks):
                verdict = 'follows gaze'
            else:
                verdict = 'changes, not with gaze'
        rows.append(dict(eye=run['eye'], rq=run['rq'], fov=run['fov'], samples=len(run['samples']), hashes=len(hashes),
                         peaks=', '.join('{}:{}/{}'.format(n, fmt(peaks[n][0]), fmt(peaks[n][1])) for n in order) or None,
                         verdict=verdict, source=run['source']))
    return rows


GRATING_CPD = (8, 10, 12, 14, 17, 20)


def grating_judgments(records):
    """Per run, eye label, rq, fov, position and orientation: the last judgment of each patch (cpd -> fields)."""
    groups, run = {}, 0
    for record in records:
        f = record['fields']
        if record['topic'] == 'm1' or record['topic'] == 'grating' and f.get('chart') == 'on':
            run += 1
        if record['topic'] != 'grating' or 'cpd' not in f or f.get('seen') not in ('yes', 'no'):
            continue
        cpd = number(f.get('cpd'))
        if cpd is None:
            continue
        key = (run, f.get('eye'), f.get('rq'), f.get('fov'), f.get('pos'), f.get('orient'))
        group = groups.setdefault(key, dict(judgments={}, source=record['source'], t_ms=None))
        group['judgments'][int(cpd)] = f
        group['source'] = record['source']
        group['t_ms'] = record['t_ms']
    return groups


def grating_physical_nyquist(records, source, eye, rq, fov, pos, orient, t_ms):
    """Physical Nyquist (ppd / 2) at the patch set from the rrm sample nearest in time with the same eye
    (both -> L), render quality and foveation in the same log. V bars: h_ppd at 0 / temporal 20 (L -20, R +20). H bars: v_ppd at 0;
    at temporal 20 the separable rate map gives v_ppd(0) / cos 20° (logical vertical ppd grows by sec(az))."""
    eye = 'R' if eye == 'R' else 'L'
    samples = [r for r in records if r['topic'] == 'rrm' and r['source'].rsplit(':', 1)[0] == source.rsplit(':', 1)[0] and r['fields'].get('eye') == eye
               and r['fields'].get('rq') == rq and r['fields'].get('fov') == fov]
    if not samples:
        return None
    nearest = min(samples, key=lambda r: abs(r['t_ms'] - t_ms))['fields']
    temporal = pos == 'temporal20'
    if orient == 'V':
        ppd = number(deg_values(nearest.get('h_ppd')).get(('20' if eye == 'R' else '-20') if temporal else '0'))
    else:
        ppd = number(deg_values(nearest.get('v_ppd')).get('0'))
        if ppd is not None and temporal:
            ppd /= math.cos(math.radians(20))
    return ppd / 2 if ppd is not None else None


def grating_limit(finest, physical):
    """render-grid limited: finest seen >= the level one step below the finest level the physical grid can carry
    (the coarsest level when none fits); lens/eye limited: below that; undetermined: no rate map or nothing seen."""
    if finest is None or physical is None:
        return 'undetermined'
    fits = [i for i, c in enumerate(GRATING_CPD) if c <= physical * 1.001]
    threshold = GRATING_CPD[max(fits[-1] - 1, 0)] if fits else GRATING_CPD[0]
    return 'render-grid limited' if finest >= threshold else 'lens/eye limited'


def grating_rows(records):
    """Finest seen cycles/deg per eye label, render quality (read back), foveation, position and orientation.
    The last judgment of a patch wins; patches logged above_nyquist=yes are listed apart and never count."""
    rows = []
    for key, group in grating_judgments(records).items():
        judged = {c: f['seen'] == 'yes' for c, f in group['judgments'].items() if f.get('above_nyquist') != 'yes'}
        above = sorted(c for c, f in group['judgments'].items() if f.get('above_nyquist') == 'yes')
        logical = [number(f.get('nyquist_logical_cpd')) for f in group['judgments'].values()]
        logical = [n for n in logical if n is not None]
        seen = sorted(c for c, s in judged.items() if s)
        finest = max(seen) if seen else None
        physical = grating_physical_nyquist(records, group['source'], key[1], key[2], key[3], key[4], key[5], group['t_ms'])
        rows.append(dict(eye=key[1], rq=key[2], fov=key[3], pos=key[4], orient=key[5], finest_seen_cpd=finest,
                         nyquist_logical_cpd='{:.2f}'.format(min(logical)) if logical else None,
                         nyquist_physical_cpd='{:.2f}'.format(physical) if physical is not None else None,
                         limit=grating_limit(finest, physical), judged=len(judged),
                         seen_cpd=','.join(map(str, seen)) or None,
                         not_seen_cpd=','.join(str(c) for c in sorted(judged) if not judged[c]) or None,
                         above_nyquist_cpd=','.join(map(str, above)) or None,
                         run=key[0], source=group['source']))
    return rows


def grating_above_nyquist(records):
    """Judgments of patches logged above their logical Nyquist (aliased on the render grid): reported, never counted."""
    rows = []
    for key, group in grating_judgments(records).items():
        for cpd in sorted(group['judgments']):
            f = group['judgments'][cpd]
            if f.get('above_nyquist') == 'yes':
                rows.append(dict(eye=key[1], rq=key[2], fov=key[3], pos=key[4], orient=key[5], cpd=cpd, seen=f['seen'],
                                 nyquist_logical_cpd=f.get('nyquist_logical_cpd'), run=key[0], source=group['source']))
    return rows


CHART_PATCH_DEG = 1.5
BAR_MIN_CONTRAST = 32     # 8-bit levels: a flatter patch has no bars
BAR_HYSTERESIS = 0.15     # of the patch's contrast, either side of the local mean
BAR_GREY = (64, 192)      # a sample strictly inside is grey (bars merged), not a bar or a gap
BAR_MISSING_GREY = 0.25   # fraction of grey samples above which a low count is missing, not aliased


def expected_bars(cpd, size_deg=CHART_PATCH_DEG):
    """One white bar per cycle, the last one clipped: ceil(1.5 * cpd), as GratingChart.bars draws."""
    return int(math.ceil(size_deg * cpd - 1e-9))


def count_bars(profile, period_px):
    """Bars in a 1-D luminance profile (0-255) across a patch: a run above the local mean (moving mean over two
    expected periods, clipped at the ends) by BAR_HYSTERESIS of the contrast starts a bar; one as far below ends it.
    Widths are run lengths in px; spreads (max - min) leave out runs touching either end (clipped by the patch)."""
    n = len(profile)
    result = dict(count=0, bar_widths=[], gap_widths=[], bar_spread_px=None, gap_spread_px=None,
                  contrast=(max(profile) - min(profile)) if profile else 0,
                  grey_fraction=sum(BAR_GREY[0] < v < BAR_GREY[1] for v in profile) / n if n else 0)
    if n < 2 or result['contrast'] < BAR_MIN_CONTRAST:
        return result
    half = max(1, int(round(period_px)))
    prefix = [0]
    for v in profile:
        prefix.append(prefix[-1] + v)
    band = BAR_HYSTERESIS * result['contrast']
    runs, high, start = [], None, 0
    for i, v in enumerate(profile):
        lo, hi = max(0, i - half), min(n, i + half + 1)
        mean = (prefix[hi] - prefix[lo]) / (hi - lo)
        if high is None:
            high = v > mean
        elif not high and v > mean + band or high and v < mean - band:
            runs.append((high, start, i))
            high, start = not high, i
    runs.append((high, start, n))
    bars = [(b - a, a == 0 or b == n) for h, a, b in runs if h]
    gaps = [(b - a, a == 0 or b == n) for h, a, b in runs if not h]
    result['count'] = len(bars)
    result['bar_widths'] = [w for w, _ in bars]
    result['gap_widths'] = [w for w, _ in gaps]
    for name, items in (('bar_spread_px', bars), ('gap_spread_px', gaps)):
        inner = [w for w, edge in items if not edge] or [w for w, _ in items]
        result[name] = max(inner) - min(inner) if inner else None
    return result


def classify_bars(result, expected):
    """correct: count as drawn, widths within one pixel (rasterisation quantises edges to whole px); uneven: count
    right, widths spread more; missing: count low where the bars merged to grey (or the patch is flat); aliased:
    any other wrong count (full-contrast beats)."""
    if result['count'] == expected:
        spreads = [s for s in (result['bar_spread_px'], result['gap_spread_px']) if s is not None]
        return 'correct' if all(s <= 1 for s in spreads) else 'uneven'
    if result['contrast'] < BAR_MIN_CONTRAST or result['count'] < expected and result['grey_fraction'] > BAR_MISSING_GREY:
        return 'missing'
    return 'aliased'


def patch_profile(width, height, pixels, rect, orientation):
    """Mean RGB across the centre band (middle half) of the physical rect, along the axis that crosses the bars
    (V: x, H: y). rect is [x0, y0, x1, y1] in physical px; pixel i is inside when its centre is."""
    x0, y0, x1, y1 = [int(math.floor(v + 0.5)) for v in rect]
    x0, x1 = max(0, x0), min(width, x1)
    y0, y1 = max(0, y0), min(height, y1)
    if x1 <= x0 or y1 <= y0:
        return []

    def level(x, y):
        i = (y * width + x) * 4
        return (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3
    if orientation == 'V':
        quarter = (y1 - y0) // 4
        rows = range(y0 + quarter, max(y1 - quarter, y0 + quarter + 1))
        return [sum(level(x, y) for y in rows) / len(rows) for x in range(x0, x1)]
    quarter = (x1 - x0) // 4
    cols = range(x0 + quarter, max(x1 - quarter, x0 + quarter + 1))
    return [sum(level(x, y) for x in cols) / len(cols) for y in range(y0, y1)]


def read_capture_png(path):
    spec = importlib.util.spec_from_file_location('verify_capture', Path(__file__).with_name('verify-capture.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.read_png(path)


def chart_captures(directory):
    """capture.json files with a chart_capture key under the pulled directory (captures/ or diag/captures/)."""
    found = []
    for path in sorted(Path(directory).rglob('capture.json')):
        try:
            data = json.loads(path.read_text(encoding='utf-8'), parse_constant=reject_json_constant)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and isinstance(data.get('chart_capture'), dict):
            found.append((path.parent, data))
    return found


def chart_capture_patches(directory):
    """Per captured patch: bars counted in the physical texture and classified (count_bars, classify_bars)."""
    rows = []
    for folder, data in chart_captures(directory):
        chart = data['chart_capture']
        images = {}
        for view in chart.get('views', []):
            png = next((s.get('png') for s in data.get('slices', []) if s.get('texture_index') == view.get('texture_index')
                        and s.get('slice') == view.get('slice')), None)
            if png is None:
                continue
            if png not in images:
                try:
                    images[png] = read_capture_png(folder / png)
                except (OSError, ValueError, struct.error, zlib.error):
                    images[png] = None
            if images[png] is None:
                continue
            width, height, pixels = images[png]
            for patch in view.get('patches', []):
                cpd = number(patch.get('cpd'))
                rect = patch.get('physical_rect')
                if cpd is None or not isinstance(rect, list) or len(rect) != 4:
                    continue
                profile = patch_profile(width, height, pixels, rect, patch.get('orientation'))
                result = count_bars(profile, len(profile) / (CHART_PATCH_DEG * cpd))
                expected = expected_bars(cpd)
                logical = number(patch.get('nyquist_logical_cpd'))
                rows.append(dict(eye=view.get('eye'), rq=chart.get('rq'), rq_set=chart.get('rq_set'), fov=chart.get('fov'),
                                 pos=patch.get('position'),
                                 above_nyquist='unknown' if logical is None else 'yes' if cpd > logical * 1.001 else 'no',
                                 orient=patch.get('orientation'), cpd=int(cpd), expected=expected, count=result['count'],
                                 bar_spread_px=result['bar_spread_px'], gap_spread_px=result['gap_spread_px'],
                                 period_px='{:.2f}'.format(len(profile) / (CHART_PATCH_DEG * cpd)),
                                 **{'class': classify_bars(result, expected)},
                                 nyquist_logical_cpd=logical,
                                 nyquist_physical_capture_cpd=number(patch.get('nyquist_physical_cpd')),
                                 dir=folder.name, t_ms=number(data.get('t_ms'))))
    return rows


def chart_capture_summary(patches, records):
    """Per capture, eye, position and orientation: the finest correct and finest count-correct cpd, both Nyquists
    and the grid verdict (grating_limit on the finest count-correct level). Patches above their logical Nyquist
    (above_nyquist=yes, 0.1 % slack as grating_rows) are listed apart and never count as finest. A patch counting right
    above either physical Nyquist (its own capture value, or the rrm value of the set) is suspect: the grid cannot carry
    it, so the count is a coincidence or the rect is wrong; listed in suspect_cpd and never the finest."""
    groups = {}
    for p in patches:
        groups.setdefault((p['dir'], p['eye'], p['rq'], p['rq_set'], p['fov'], p['pos'], p['orient']), []).append(p)
    rows = []
    for (folder, eye, rq, rq_set, fov, pos, orient), items in groups.items():
        logical = [p['nyquist_logical_cpd'] for p in items if p['nyquist_logical_cpd'] is not None]
        captured = [p['nyquist_physical_capture_cpd'] for p in items if p['nyquist_physical_capture_cpd'] is not None]
        line = next((r for r in records if r['topic'] == 'chartcap' and r['fields'].get('dir') == folder
                     and r['fields'].get('eye') == eye), None)
        physical = grating_physical_nyquist(records, line['source'], eye, rq, fov, pos, orient, line['t_ms']) if line else None

        def above_physical(p):
            return any(n is not None and p['cpd'] > n * 1.001 for n in (p['nyquist_physical_capture_cpd'], physical))
        suspect = [p for p in items if p['above_nyquist'] != 'yes' and p['count'] == p['expected'] and above_physical(p)]
        within = [p for p in items if p['above_nyquist'] != 'yes' and p not in suspect]
        correct = [p['cpd'] for p in within if p['class'] == 'correct']
        counted = [p['cpd'] for p in within if p['count'] == p['expected']]
        reference = physical if physical is not None else (min(captured) if captured else None)
        limit = grating_limit(max(counted) if counted else None, reference)
        rows.append(dict(eye=eye, rq=rq, rq_set=rq_set, fov=fov, pos=pos, orient=orient,
                         above_nyquist_cpd=','.join(str(p['cpd']) for p in sorted(items, key=lambda p: p['cpd'])
                                                    if p['above_nyquist'] == 'yes') or None,
                         finest_correct_cpd=max(correct) if correct else None,
                         finest_count_correct_cpd=max(counted) if counted else None,
                         nyquist_logical_cpd='{:.2f}'.format(min(logical)) if logical else None,
                         nyquist_physical_cpd='{:.2f}'.format(physical) if physical is not None else None,
                         nyquist_physical_capture_cpd='{:.2f}'.format(min(captured)) if captured else None,
                         grid_verdict={'render-grid limited': 'carries to grid Nyquist',
                                       'lens/eye limited': 'below grid Nyquist'}.get(limit, limit),
                         suspect_cpd=','.join(str(c) for c in sorted(p['cpd'] for p in suspect)) or None,
                         classes=','.join('{}:{}'.format(p['cpd'], p['class']) for p in sorted(items, key=lambda p: p['cpd'])),
                         dir=folder))
    return sorted(rows, key=lambda r: tuple(str(r[k]) for k in ('eye', 'rq', 'rq_set', 'fov', 'pos', 'orient', 'dir')))


def resolution_report(records, directory=None):
    selected = [r for r in records if r['topic'] in ('rrm', 'grating', 'chartcap')]
    lines = section(SECTIONS[12], selected)
    lines += ['Rendered density: physical px per degree from the rasterization rate map (finite difference of '
              'physicalCoordinates(screenCoordinates:layer:) times logical px/deg, which grows as sec² off axis), '
              'along the horizontal (h, + right) and vertical (v, + up) lines through the eye axis. '
              'Rows use the last centre-fixation sweep sample, else the quality-step sample. No map: rate 1.', '']
    lines += table(rrm_profiles(records), ('eye', 'rq', 'fov', 'line') + RRM_DEGREES +
                   ('peak_deg', 'phase', 'map', 'screen', 'physical', 'source')) + ['']
    lines += ['Gaze follow (per eye and 20 s sweep; peaks are mean plateau centres h/v in degrees per fixation): '
              'fixed = one map hash and peaks within 1°; follows gaze = peaks move ≥5° towards each logged fixation.', '']
    lines += table(rrm_gaze(records), ('eye', 'rq', 'fov', 'samples', 'hashes', 'peaks', 'verdict', 'source')) + ['']
    lines += ['Grating limit: finest cycles/deg judged seen (square wave, 1.5° patches sized by the view tangents). '
              'rq is the render quality read back; the last judgment of a patch wins. nyquist_logical_cpd: half the '
              'logical px/deg at the patch (lowest logged in the set); nyquist_physical_cpd: half the rate-map px/deg '
              'from the nearest rrm sample of the same eye, rq and fov. limit: render-grid limited = finest seen within '
              'one level of the physical Nyquist (the grid stops it); lens/eye limited = finer levels the grid carries '
              'were not seen; undetermined = no rate map or nothing seen.', '']
    lines += table(grating_rows(records), ('eye', 'rq', 'fov', 'pos', 'orient', 'finest_seen_cpd', 'nyquist_logical_cpd',
                                           'nyquist_physical_cpd', 'limit', 'judged', 'seen_cpd', 'not_seen_cpd',
                                           'above_nyquist_cpd', 'run', 'source')) + ['']
    lines += ['Above the logical Nyquist (aliased on the render grid; not counted as seen):', '']
    lines += table(grating_above_nyquist(records), ('eye', 'rq', 'fov', 'pos', 'orient', 'cpd', 'seen',
                                                    'nyquist_logical_cpd', 'run', 'source')) + ['']
    patches = chart_capture_patches(directory) if directory is not None else []
    lines += ['Auto capture (chart read back from each eye\'s physical texture; bars counted per patch across the centre '
              'band of its physical rect). finest_correct_cpd: count as drawn and widths within 1 px; '
              'finest_count_correct_cpd: count as drawn. nyquist_physical_cpd: nearest rrm sample (as above); '
              'nyquist_physical_capture_cpd: the capture\'s own rate map at each patch, lowest in the set (temporal20 '
              'patches sit 16-26° out on a steep falloff, so this is the outermost patch, not the 20° rrm value). '
              'suspect_cpd: counted right above either physical Nyquist (its own capture value or the rrm value): '
              'listed, never the finest. grid_verdict: '
              'carries to grid Nyquist = finest count-correct within one level of the physical Nyquist; below grid '
              'Nyquist = it fails earlier; undetermined = no Nyquist or nothing counted. rq_set: the quality requested '
              '(rq=unavailable without read-back). Patches above their logical Nyquist (above_nyquist_cpd) are '
              'counted and listed but never the finest.', '']
    lines += table(chart_capture_summary(patches, records),
                   ('eye', 'rq', 'rq_set', 'fov', 'pos', 'orient', 'finest_correct_cpd', 'finest_count_correct_cpd',
                    'nyquist_logical_cpd', 'nyquist_physical_cpd', 'nyquist_physical_capture_cpd', 'grid_verdict',
                    'suspect_cpd', 'above_nyquist_cpd', 'classes', 'dir')) + ['']
    lines += ['Auto capture patches (correct / uneven: count right, widths within 1 px or not; missing: count low, bars '
              'merged to grey or flat; aliased: count wrong at full contrast):', '']
    lines += table(patches, ('eye', 'rq', 'fov', 'pos', 'orient', 'cpd', 'expected', 'count', 'bar_spread_px', 'gap_spread_px',
                             'period_px', 'class', 'above_nyquist', 'nyquist_physical_capture_cpd', 'dir')) + ['']
    lines += measurements(selected, ('phase', 's', 'fix', 'eye', 'rq', 'fov', 'cpd', 'orient', 'seen')) + ['']
    return lines


def generate(directory, sender_path=None):
    directory = Path(directory)
    records, malformed, errors = read_logs(directory)
    senders, bad_sender = read_sender(Path(sender_path) if sender_path else None)
    by_topic = defaultdict(list)
    for record in records:
        by_topic[record['topic']].append(record)

    def topics(*names):
        return [r for r in records if r['topic'] in names]

    lines = ['# Headset diagnostic report', '',
             'Times are logged monotonic t_ms, not wall-clock or photon presentation times. '
             'Source references are filename:line. Missing measurements say no data; '
             'reported p95 is never substituted for p99. All input fields are retained.', '']
    selected = topics('m1')
    lines += section(SECTIONS[0], records)
    lines += measurements(selected, ('model', 'os', 'app')) + ['']
    timeline = []
    for topic, items in sorted(by_topic.items()):
        times = [r['t_ms'] for r in items]
        timeline.append(dict(topic=topic, first_t_ms=min(times), last_t_ms=max(times), lines=len(items)))
    lines += table(timeline, ('topic', 'first_t_ms', 'last_t_ms', 'lines')) + ['']
    starts = [r for r in records if r['topic'] == 'm1']
    lines += ['Session starts: ' + (', '.join('{} at {} ms'.format(cell(r['source']), r['t_ms']) for r in starts) or NO), '',
              'Timeline bounds are per topic across supplied files; reboots can reset the monotonic clock.', '']

    selected = topics('m1', 'm1_config', 'codec')
    lines += section(SECTIONS[1], selected)
    lines += measurements(topics('m1', 'm1_config'), ('color_formats', 'chosen_color', 'eligible_for_hdr_playback')) + ['']
    lines += table(codec_rows(records), ('type', 'chroma', 'bit_depth', 'hw', 'session', 'source', 'hardware_source')) + ['']
    lines += measurements(topics('codec')) + ['']

    selected = topics('m1_config', 'm5', 'm5_view', 'm5_vrr', 'rq')
    lines += section(SECTIONS[2], selected)
    lines += measurements(topics('m1_config', 'm5', 'm5_view', 'm5_vrr')) + ['']
    lines += ['Render-quality sweep (footprint_mb is MiB):', '']
    lines += measurements(topics('rq'), ('step', 'actual', 'tex_w', 'tex_h', 'gpu_ms_p50', 'gpu_ms_p99', 'missed_deadlines', 'footprint_mb')) + ['']

    selected = topics('m6')
    lines += section(SECTIONS[3], selected)
    lines += ['Cadence interval ms histogram: no data (current logger emits window percentiles, not interval samples).', '',
              'Achieved Hz: no data (window duration / interval count not logged). '
              '1000 / target_interval_p50_ms below is a median target cadence estimate; '
              'actual presentation is unavailable.', '']
    cadence = []
    for record in selected:
        median = number(record['fields'].get('target_interval_p50_ms'))
        cadence.append(dict(source=record['source'], median_target_hz=fmt(1000 / median if median and median > 0 else None)))
    lines += table(cadence, ('source', 'median_target_hz')) + ['']
    lines += measurements(selected, ('fresh', 'repeated', 'blank', 'missed_render_deadline')) + ['']

    selected = topics('m9')
    lines += section(SECTIONS[4], selected)
    footprints = [number(r['fields'].get('phys_footprint')) for r in selected]
    footprints = [n for n in footprints if n is not None and n >= 0]
    lines += ['footprint bytes min={} max={}'.format(fmt(min(footprints) if footprints else None), fmt(max(footprints) if footprints else None)), '']
    transitions, previous = [], None
    for record in selected:
        thermal = record['fields'].get('thermal')
        if thermal is not None and thermal != previous:
            transitions.append(dict(source=record['source'], t_ms=record['t_ms'], thermal=thermal))
            previous = thermal
    lines += table(transitions, ('source', 't_ms', 'thermal')) + ['']
    if not any(number(r['fields'].get('gpu_p99_ms')) is not None for r in selected):
        lines += ['GPU p99: no data (current M9 logger supplies p50/p95 only).', '']
    lines += measurements(selected, ('gpu_p50_ms', 'gpu_p95_ms', 'gpu_p99_ms')) + ['']

    selected = topics('edr')
    lines += section(SECTIONS[5], selected)
    lines += measurements(selected, ('step', 'value', 'layout', 'hold_s', 'mark')) + ['']
    previous = None
    for record in records:
        if record['topic'] == 'm1':
            previous = None
        if record['topic'] != 'edr':
            continue
        fields = record['fields']
        if 'step' in fields:
            previous = record
        if fields.get('mark') == 'true':
            hold = NO
            if previous and all(previous['fields'].get(k) == fields.get(k) for k in ('value', 'layout')):
                value = previous['fields'].get('hold_s')
                if value is not None:
                    hold = '{} (from {})'.format(cell(value), cell(previous['source']))
            lines += ['Threshold {}: value={} layout={} hold_s={}'.format(
                cell(record['source']), cell(fields.get('value')), cell(fields.get('layout')), hold), '']
    if not any(r['fields'].get('mark') == 'true' for r in selected):
        lines += ['Recorded thresholds: no data', '']

    selected = topics('pq')
    lines += section(SECTIONS[6], selected)
    lines += measurements(selected, ('clip', 'path', 'step')) + ['']

    selected = topics('decode')
    lines += section(SECTIONS[7], selected)
    lines += ['fps and Mpix/s aggregate all sessions. Real-time flags require achieved fps / sessions ≥ Hz, '
              'zero drops, hw=true and err=0. These are throughput checks; latency p99 and backlog '
              'stability remain no data when unlogged. Highest passing ranks source_fps × sessions '
              'among trials meeting their source cadence; it is a measured configuration, not a device limit.', '']
    lines += measurements(selected, ('clip', 'sessions', 'mode', 'width', 'height', 'source_fps', 'fps', 'mpix_s', 'lat_p50_ms', 'lat_p95_ms', 'lat_p99_ms', 'dropped', 'hw', 'err')) + ['']
    best = {}
    for record in selected:
        fields = record['fields']
        lines += ['{}: {}'.format(cell(record['source']), '; '.join('{} Hz: {}'.format(hz, decode_status(fields, hz)) for hz in (90, 96, 100))), '']
        source_fps, sessions = number(fields.get('source_fps')), number(fields.get('sessions'))
        if source_fps is not None and source_fps > 0 and decode_status(fields, source_fps) == 'PASS' and all(number(fields.get(k)) is not None and number(fields.get(k)) > 0 for k in ('width', 'height')):
            size = '{}x{}'.format(fields['width'], fields['height'])
            score = source_fps * sessions
            if size not in best or score > best[size][0]:
                best[size] = (score, record)
    if not best:
        lines += ['Highest passing: no data', '']
    for size, (_, record) in sorted(best.items()):
        lines += ['Highest passing {}: {} ({}; sessions={}; mode={}; source_fps={})'.format(
            cell(size), cell(record['source']), cell(record['fields'].get('clip')),
            cell(record['fields'].get('sessions')), cell(record['fields'].get('mode')),
            cell(record['fields'].get('source_fps'))), '']

    selected = topics('net')
    lines += section(SECTIONS[8], selected, [r['source'] for r in senders])
    lines += network_report(selected, senders, alignment_ok=not bad_sender)
    selected = topics('corner', 'corner_summary')
    lines += section(SECTIONS[9], selected)
    lines += ['Per-spoke radii are the logged normalised r entries, ordered 0–337.5 degrees in 22.5-degree steps. No missing rings are inferred.', '']
    lines += table(corner_rows(records), ('eye', 'pos_deg', 'ring_pct', 'radius', 'shape', 'superellipse_n', 'area_frac', 'kind', 'sides', 'cuts', 'visible_area_frac', 'mark_source', 'summary_source')) + ['']
    lines += measurements(selected, ('eye', 'pos_deg', 'ring_pct', 'r', 'shape', 'superellipse_n', 'area_frac')) + ['']
    lines += dots_report(records)
    lines += resolution_report(records, directory)
    selected = topics('eye_badge', 'diag')
    known = {'m1', 'm1_config', 'codec', 'm5', 'm5_view', 'm5_vrr', 'rq', 'm6', 'm9', 'edr', 'pq', 'decode', 'net', 'corner', 'corner_summary', 'eye_badge', 'diag', 'dots', 'dots_summary', 'dots_session', 'dots_outline', 'rrm', 'grating', 'chartcap'}
    unknown = [r for r in records if r['topic'] not in known]
    lines += section(SECTIONS[10], selected + unknown, malformed + bad_sender + errors)
    lines += ['malformed lines skipped={}; malformed sender lines skipped={}; input file errors={}'.format(len(malformed), len(bad_sender), len(errors)), '',
              'Malformed diagnostic sources: ' + (', '.join(map(cell, malformed)) or NO), '',
              'Malformed sender sources: ' + (', '.join(map(cell, bad_sender)) or NO), '',
              'Input file errors: ' + ('; '.join(map(cell, errors)) or NO), '']
    drops = [number(r['fields'].get('dropped_lines')) for r in topics('diag') if 'dropped_lines' in r['fields']]
    drops = [n for n in drops if n is not None and n >= 0]
    lines += ['Reported dropped_lines=' + (fmt(sum(drops)) if drops else NO), '',
              'Eye badge mismatch records=' + (str(sum(r['fields'].get('mismatch') in ('1', 'true') for r in topics('eye_badge'))) if topics('eye_badge') else NO), '']
    lines += measurements(selected + unknown) + ['']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='directory of pulled diag-*.log files')
    parser.add_argument('--sender-log', type=Path, help='netprobe-ladder.py JSON lines: metadata, timed steps, footer')
    parser.add_argument('-o', '--output', type=Path, help='write Markdown here (default: stdout)')
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error('diagnostic directory does not exist: {}'.format(args.directory))
    if args.output and (args.output.resolve() in [p.resolve() for p in args.directory.glob('diag-*.log')] or
                        args.sender_log and args.output.resolve() == args.sender_log.resolve()):
        parser.error('output must not overwrite an input log')
    try:
        markdown = generate(args.directory, args.sender_log)
        if args.output:
            args.output.write_text(markdown, encoding='utf-8')
        else:
            sys.stdout.write(markdown)
    except OSError as error:
        parser.exit(1, 'diag-report: {}\n'.format(error))


if __name__ == '__main__':
    main()
