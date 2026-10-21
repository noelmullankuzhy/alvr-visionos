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
    'Eye badges and Diag file health',
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


def read_sender(path):
    records, malformed = [], []
    if path is None:
        return records, malformed
    with path.open('rb') as stream:
        for index, raw in enumerate(stream, 1):
            source = '{}:{}'.format(path.name, index)
            try:
                obj = json.loads(raw.decode('utf-8'), parse_constant=lambda x: None)
                if not isinstance(obj, dict) or obj.get('mode') not in ('udp', 'tcp'):
                    raise ValueError('sender object requires mode=udp/tcp')
                for key in ('requested_mbps', 'mbps', 'fps', 'packets', 'payload_mbps'):
                    if key in obj and (isinstance(obj[key], bool) or number(obj[key]) is None):
                        raise ValueError('invalid sender number')
                records.append(dict(fields=obj, source=source))
            except (ValueError, UnicodeError):
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


def network_report(records, senders, alignment_ok=True):
    lines = [
        'Sender JSON objects align with sink runs by step order, including TCP. '
        'Each object uses mode, requested_mbps (or mbps), fps, packets and payload_mbps; '
        'plain netprobe-send.py summaries lack requested rate and fps.', '',
        'Completion p99 uses spread_p99_ms (first-to-last receipt of complete frames). '
        'Loss % = sink loss / sender packets × 100 for final summaries only; '
        'trailing loss is unknown. Interval loss/reorder/distributions are cumulative. '
        'A passing knee is an observed bound, not proof that trailing packets arrived.', '',
    ]
    if not alignment_ok:
        lines += ['sender alignment disabled: malformed JSON lines may hide steps; no knee inferred.', '']
    passing = []
    runs = network_runs(records)
    for index, run in enumerate(runs):
        sender = senders[index] if index < len(senders) else None
        sf = sender['fields'] if sender else {}
        last = run[-1]['fields']
        aligned = alignment_ok and (not sender or sf.get('mode') == last.get('mode'))
        requested = number(sf.get('requested_mbps', sf.get('mbps'))) if aligned else None
        fps = number(sf.get('fps')) if aligned else None
        period = 1000 / fps if fps is not None and fps > 0 else None
        final = last.get('summary') == 'true'
        packets = number(sf.get('packets')) if aligned else None
        loss = number(last.get('loss'))
        loss_pct = 100 * loss / packets if final and packets is not None and packets > 0 and loss is not None and 0 <= loss <= packets else None
        complete = number(last.get('frame_complete'))
        tail = number(last.get('spread_p99_ms', last.get('burst_tail_p99_ms')))
        valid = (last.get('mode') == 'udp' and final and aligned and
                 requested is not None and requested > 0 and period is not None and
                 loss_pct is not None and tail is not None and tail >= 0 and
                 complete is not None and complete > 0 and not sf.get('error') and
                 number(last.get('hist_overflow', '0')) == 0)
        passed = valid and loss_pct <= 0.1 and tail <= period
        if passed:
            passing.append((requested, index + 1))
        status = 'PASS' if passed else ('FAIL' if valid else NO)
        lines += ['### Step {} ({})'.format(index + 1, cell(last.get('mode'))), '',
                  'requested={} Mb/s; received={} Mb/s; loss={}{}; '
                  'frame_period_ms={}; completion_p99_ms={}; knee eligibility={}.'.format(
                      fmt(requested), fmt(number(last.get('mbps'))), fmt(loss_pct),
                      '%' if loss_pct is not None else '', fmt(period), fmt(tail), status), '']
        if not final:
            lines += ['incomplete run: no final summary; excluded from knee.', '']
        if sender and sf.get('mode') != last.get('mode'):
            lines += ['sender/sink mode mismatch; no aligned sender measurements.', '']
        if sender:
            lines += table([dict(sf, source=sender['source'])], ['source'] + list(sf)) + ['']
        lines += measurements(run, ('mode', 'mbps', 'loss', 'reorder', 'jitter_ms', 'spread_p99_ms')) + ['']
    best = max(passing) if passing else None
    lines += ['Knee: {}{}'.format(fmt(best[0]) + ' Mb/s' if best else NO,
                                  ' (step {})'.format(best[1]) if best else ''), '',
              'Unmatched sender steps: {}'.format(max(0, len(senders) - len(runs))), '']
    # Retain unpaired sender numbers and sink errors too.
    for sender in senders[len(runs):]:
        lines += table([dict(sender['fields'], source=sender['source'])],
                       ['source'] + list(sender['fields'])) + ['']
    errors = [r for r in records if 'mbps' not in r['fields']]
    if errors:
        lines += measurements(errors) + ['']
    if not records:
        lines += ['TCP bulk throughput: no data', '']
    elif not any(r['fields'].get('mode') == 'tcp' for r in records):
        lines += ['TCP bulk throughput: no data', '']
    else:
        lines += ['TCP bulk throughput is the recorded mbps in TCP steps above.', '']
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
            for spoke, radius in enumerate(radii if len(radii) == 16 else []):
                angle = spoke * 22.5
                mark = marks.get((eye, angle))
                rows.append(dict(eye=eye, pos_deg=fmt(angle),
                                 ring_pct=mark['fields'].get('ring_pct') if mark else None,
                                 radius=radius, shape=f.get('shape'),
                                 superellipse_n=f.get('superellipse_n'), area_frac=f.get('area_frac'),
                                 summary_source=record['source'],
                                 mark_source=mark['source'] if mark else None))
            # A completed walk must not supply rings for a later partial walk.
            marks = {key: value for key, value in marks.items() if key[0] != eye}
    return rows


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
    lines += table(corner_rows(records), ('eye', 'pos_deg', 'ring_pct', 'radius', 'shape', 'superellipse_n', 'area_frac', 'mark_source', 'summary_source')) + ['']
    lines += measurements(selected, ('eye', 'pos_deg', 'ring_pct', 'r', 'shape', 'superellipse_n', 'area_frac')) + ['']
    selected = topics('eye_badge', 'diag')
    known = {'m1', 'm1_config', 'codec', 'm5', 'm5_view', 'm5_vrr', 'rq', 'm6', 'm9', 'edr', 'pq', 'decode', 'net', 'corner', 'corner_summary', 'eye_badge', 'diag'}
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
    parser.add_argument('--sender-log', type=Path, help='optional sender ladder JSON lines, one object per sink run')
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
