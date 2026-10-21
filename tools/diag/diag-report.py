#!/usr/bin/env python3
"""Turn pulled diag-*.log files into a reproducible Markdown measurement report."""
import argparse
from collections import defaultdict
import html
import json
import math
from pathlib import Path
import re
import sys

SECTIONS = (
    'Device / OS / build and session timeline', 'M1 formats / API and codec audit',
    'M5 drawable / rasterization maps and render-quality sweep',
    'M6 cadence', 'M9 thermal / memory / GPU', 'M2 EDR ramp / thresholds',
    'M3 PQ player', 'M7 decode', 'M8 network', 'Corner chart',
    'Eye badges and Diag file health', 'Boundary dots',
)
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
    """Return projected yaw/pitch for a point on the specified dot lattice."""
    ray, ecc = number(ray), number(ecc)
    if (ray is None or ecc is None or not 0 <= ray < 360 or not 10 <= ecc <= 70
            or abs(ray / 15 - round(ray / 15)) > 1e-7
            or abs((ecc - 10) / 2.5 - round((ecc - 10) / 2.5)) > 1e-7):
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
            complete = valid and len(points) == 24 and all(p['u'] is not None for p in converted)
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
            valid = valid and count is not None and count.is_integer() and len(points) <= count <= 600
            snapshot(label, sorted(points, key=lambda p: p['ray_deg']) if valid else [],
                     record['source'], count, valid)
            active.pop(label, None)
    flush()
    return rows


def dots_report(records):
    selected = [r for r in records if r['topic'] in ('dots', 'dots_summary', 'dots_session')]
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
              'Resolution: 2.5 degrees radially, 15 degrees between rays; targets are 1 degree wide. '
              'A visible dot that cannot be highlighted is a tracker limit, not a boundary. '
              'The app cannot detect or log continuous gaze or this failure; record it separately.', '']
    for boundary in dots_boundaries(records):
        lines += ['Marks={} → eye={}; source={}; tangent_source={}; confirmed_points={}; '
                  'rays={}; status={}; visible_area_frac={}'.format(
                      boundary['label'], boundary['eye'], cell(boundary['source']),
                      cell(boundary['tangent_source']), fmt(boundary['confirmed_points']),
                      len(boundary['points']), boundary['status'], fmt(boundary['visible_area_frac'])), '']
        lines += table([{k: fmt(v) for k, v in point.items()} for point in boundary['points']],
                       ('ray_deg', 'ecc_deg', 'yaw_deg', 'pitch_deg', 'x_pct', 'y_pct', 'u', 'v')) + ['']
    lines += measurements(selected, ('eye', 'action', 'ray_deg', 'ecc_deg', 'yaw_deg', 'pitch_deg', 'points', 'rays')) + ['']
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
    selected = topics('eye_badge', 'diag')
    known = {'m1', 'm1_config', 'codec', 'm5', 'm5_view', 'm5_vrr', 'rq', 'm6', 'm9', 'edr', 'pq', 'decode', 'net', 'corner', 'corner_summary', 'eye_badge', 'diag', 'dots', 'dots_summary', 'dots_session'}
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
