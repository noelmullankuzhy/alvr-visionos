#!/usr/bin/env python3
"""Helpers for run-matrix.sh (stdlib only, Python 3.9+): points parsing, settings mapping, dump classification,
stats and the summary row. The shell runner calls the subcommands at the bottom; tests import the functions."""
import json
import math
import os
import re
import statistics
import sys

BASE_RENDER = (3648, 2912)  # per-eye render at render_scale 1.0 (the page's standard preset)
SUMMARY_COLUMNS = ['name', 'verdict', 'median_deg', 'max_deg', 'extent_err_deg', 'centre_px_deg', 'fps',
                   'bitrate_mbps', 'encode_ms', 'verdict_render', 'verdict_encoded', 'notes',
                   'encode_ms_p95', 'encode_over_budget']
NA = 'n/a'
DEFAULT_FLAG = 'dump'
FRAME_BUDGET_MS = 1000.0 / 90   # 90 Hz frame budget, 11.1 ms


def g(v):
    return '%g' % v


def valid_flag(flag):
    words = flag.split(',')
    return all(w in ('dump', 'stress') for w in words) and len(set(words)) == len(words)


def flag_has_dump(flag):
    return 'dump' in flag.split(',')


def valid_eye_tangents(text):
    """L:l,r,d,u;R:l,r,d,u, both eyes once, four positive |tan| each (the client's -ALVRDebugEyeTangents)."""
    eyes = {}
    for part in text.split(';'):
        eye, _, vals = part.strip().partition(':')
        try:
            v = [float(x) for x in vals.split(',')]
        except ValueError:
            return False
        if eye not in ('L', 'R') or eye in eyes or len(v) != 4 or not all(math.isfinite(x) and x > 0 for x in v):
            return False
        eyes[eye] = v
    return set(eyes) == {'L', 'R'}


def parse_points(lines):
    pts, seen = [], set()
    for no, raw in enumerate(lines, 1):
        line = raw.rstrip('\r\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        c = line.split('\t')
        where = 'line %d' % no
        if len(c) < 6:
            raise ValueError('%s: need at least 6 tab-separated columns, got %d' % (where, len(c)))
        name = c[0].strip()
        if not re.match(r'^[A-Za-z0-9._-]+$', name):
            raise ValueError('%s: bad name %r (letters, digits, . _ - only)' % (where, name))
        if name in seen:
            raise ValueError('%s: duplicate name %s' % (where, name))
        seen.add(name)

        def num(i, label, positive=True):
            try:
                v = float(c[i])
            except ValueError:
                raise ValueError('%s: %s %r is not a number' % (where, label, c[i]))
            if positive and v <= 0:
                raise ValueError('%s: %s must be > 0, got %s' % (where, label, c[i]))
            return v

        fov = num(1, 'fov_scale')
        render = num(2, 'render_scale')
        fv = c[3].strip()
        if fv == 'off':
            foveation = None
        else:
            try:
                foveation = tuple(float(x) for x in fv.split(','))
            except ValueError:
                foveation = ()
            if len(foveation) != 6:
                raise ValueError('%s: foveation %r must be cx,cy,rx,ry,shx,shy or off' % (where, fv))
        extra = [x.strip() for x in c[6:] if x.strip()]
        for x in extra:
            if '=' not in x:
                raise ValueError('%s: extra %r must be path=json' % (where, x))
        flag = DEFAULT_FLAG
        for x in [x for x in extra if x.startswith('flag=')]:   # the chart flag is not a session path
            flag = x[5:]
            if not valid_flag(flag):
                raise ValueError('%s: flag %r must be dump, stress or stress,dump' % (where, flag))
            extra.remove(x)
        eye_tangents = None
        for x in [x for x in extra if x.startswith('eye_tangents=')]:   # a client launch argument, not a session path
            eye_tangents = x[len('eye_tangents='):]
            if not valid_eye_tangents(eye_tangents):
                raise ValueError('%s: eye_tangents %r must be L:l,r,d,u;R:l,r,d,u (|tan| > 0)' % (where, eye_tangents))
            extra.remove(x)
        pts.append({'name': name, 'fov_scale': fov, 'render_scale': render, 'foveation': foveation,
                    'bitrate_mbps': num(4, 'bitrate_mbps'), 'fps': num(5, 'fps'), 'extra': extra, 'flag': flag,
                    'eye_tangents': eye_tangents})
    if not pts:
        raise ValueError('no points')
    return pts


def render_size(scale):
    return int(round(BASE_RENDER[0] * scale)), int(round(BASE_RENDER[1] * scale))


def session_sets(p):
    """Strict dotted path=json lines for pc-session.py apply (it fails loudly on an unknown path)."""
    w, h = render_size(p['render_scale'])
    sets = []
    for key in ('transcoding_view_resolution', 'emulated_headset_view_resolution'):
        sets.append('video.%s.variant="Absolute"' % key)
        sets.append('video.%s.Absolute.width=%d' % (key, w))
        sets.append('video.%s.Absolute.height.content=%d' % (key, h))
    f = 'video.foveated_encoding'
    if p['foveation'] is None:
        sets.append(f + '.enabled=false')
    else:
        cx, cy, rx, ry, shx, shy = p['foveation']
        sets.append(f + '.enabled=true')
        for k, v in (('center_size_x', cx), ('center_size_y', cy), ('edge_ratio_x', rx), ('edge_ratio_y', ry),
                     ('center_shift_x', shx), ('center_shift_y', shy)):
            sets.append('%s.content.%s=%s' % (f, k, g(v)))
    sets.append('video.bitrate.mode.variant="ConstantMbps"')
    sets.append('video.bitrate.mode.ConstantMbps=%d' % int(round(p['bitrate_mbps'])))
    sets.append('video.preferred_fps=%r' % float(p['fps']))
    return sets + list(p['extra'])


def client_settings(p):
    return {'fovRenderScale': p['fov_scale'], 'streamFullImmersion': True, 'captureDiagnosticFrames': True}


def overlay_args(p):
    w, h = render_size(p['render_scale'])
    fv = 'off' if p['foveation'] is None else ','.join(g(x) for x in p['foveation'])
    return ['--fov-scale', g(p['fov_scale']), '--render', '%dx%d' % (w, h), '--foveation', fv]


def merge_client_settings(path, updates):
    d = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                d = json.load(f)
            if not isinstance(d, dict):
                d = {}
        except ValueError:
            d = {}
    d.update(updates)
    with open(path, 'w') as f:
        json.dump(d, f)
    return d


def classify_dump(names):
    """Server chart dump PNGs -> (mode, eye, name). File names are not fixed by the contract, so match words:
    foveated/encoder/encoded/coded -> encoded, everything else -> render; eye from L/R/left/right tokens."""
    out = []
    for n in sorted(names):
        if not n.lower().endswith('.png'):
            continue
        tokens = [t for t in re.split(r'[^a-z0-9]+', os.path.splitext(n)[0].lower()) if t]
        eye = 'L' if ('l' in tokens or 'left' in tokens) else 'R' if ('r' in tokens or 'right' in tokens) else None
        if eye is None:
            continue
        enc = any(t in ('foveated', 'encoder', 'encoded', 'coded', 'enc') for t in tokens)
        out.append(('encoded' if enc else 'render', eye, n))
    out.sort(key=lambda x: (x[0] != 'render', x[1], x[2]))
    return out


def _median(v):
    return statistics.median(v) if v else None


def stats(events_path, console_path):
    graph = []
    try:
        with open(events_path, errors='replace') as f:
            for line in f:
                try:
                    e = json.loads(line)
                    et = e.get('event_type') or {}
                    if et.get('id') == 'GraphStatistics' and isinstance(et.get('data'), dict):
                        graph.append(et['data'])
                except (ValueError, AttributeError):
                    pass
    except OSError:
        pass
    client = []
    try:
        with open(console_path, errors='replace') as f:
            for line in f:
                i = line.find('ALVRSTATS {')
                if i < 0:
                    continue
                try:
                    client.append(json.loads(line[i + 10:]))
                except ValueError:
                    pass
    except OSError:
        pass

    def col(rows, key, scale=1.0):
        return _median([r[key] * scale for r in rows if isinstance(r.get(key), (int, float))])

    enc = sorted(r['encoder_s'] * 1000.0 for r in graph if isinstance(r.get('encoder_s'), (int, float)))
    fps = col(client, 'presented_fps')
    dec = col(client, 'decode_ms_mean')
    return {'graph_n': len(graph), 'client_stats_n': len(client),
            'encode_ms': col(graph, 'encoder_s', 1000.0), 'bitrate_mbps': col(graph, 'bitrate_bps', 1e-6),
            'encode_ms_p95': enc[math.ceil(0.95 * len(enc)) - 1] if enc else None,   # nearest rank
            'encode_over_budget': sum(1 for e in enc if e > FRAME_BUDGET_MS) / len(enc) if enc else None,
            'client_fps': fps if fps is not None else col(graph, 'client_fps'),
            'decode_ms': dec if dec is not None else col(graph, 'decoder_s', 1000.0)}


def _find(obj, key):
    """First value for `key` anywhere in a nested JSON structure (breadth first)."""
    queue = [obj]
    while queue:
        o = queue.pop(0)
        if isinstance(o, dict):
            if key in o:
                return o[key]
            queue.extend(o.values())
        elif isinstance(o, list):
            queue.extend(o)
    return None


def _verdict(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    v = _find(d, 'verdict')
    return str(v) if v is not None else None


def _combine(verdicts):
    verdicts = [v for v in verdicts if v]
    if not verdicts:
        return NA
    return 'FAIL' if any(v != 'PASS' for v in verdicts) else 'PASS'


def _num(v, fmt):
    return fmt % v if isinstance(v, (int, float)) and not isinstance(v, bool) else NA


def _extent_err(summary):
    """Max |measured - predicted| over the sides of summary.stream_extent_deg ({side: {measured, predicted}})."""
    ext = _find(summary, 'stream_extent_deg')
    errs = []
    if isinstance(ext, dict):
        for side in ext.values():
            if isinstance(side, dict) and isinstance(side.get('measured'), (int, float)) \
                    and isinstance(side.get('predicted'), (int, float)):
                errs.append(abs(side['measured'] - side['predicted']))
    return max(errs) if errs else None


def _centre(summary):
    """Band (centre) px/deg: measured 'implied_px_per_deg' vs 'predicted_px_per_deg' (scalar or {band, edge})."""
    out = []
    for key in ('implied_px_per_deg', 'predicted_px_per_deg'):
        v = _find(summary, key)
        if isinstance(v, dict):
            v = v.get('band')
        out.append(v if isinstance(v, (int, float)) and not isinstance(v, bool) else None)
    if None in out:
        return NA
    return '%.1f/%.1f' % tuple(out)


def summary_row(name, point_dir):
    ov = os.path.join(point_dir, 'overlay')
    r = dict.fromkeys(SUMMARY_COLUMNS, NA)
    r['name'] = name
    try:
        with open(os.path.join(ov, 'drawable.json')) as f:
            d = json.load(f)
    except (OSError, ValueError):
        d = None
    if d is None:
        r['verdict'] = 'NO_OVERLAY'
    else:
        s = d.get('summary', d) if isinstance(d, dict) else {}
        v = _find(s, 'verdict')
        r['verdict'] = str(v) if v is not None else NA
        r['median_deg'] = _num(_find(s, 'median_abs_residual_deg'), '%.3f')
        r['max_deg'] = _num(_find(s, 'max_abs_residual_deg'), '%.3f')
        r['extent_err_deg'] = _num(_extent_err(s), '%.3f')
        r['centre_px_deg'] = _centre(s)
    try:
        listing = sorted(os.listdir(ov))
    except OSError:
        listing = []
    for mode in ('render', 'encoded'):
        r['verdict_' + mode] = _combine([_verdict(os.path.join(ov, n)) for n in listing
                                         if n.startswith(mode + '-') and n.endswith('.json')])
    try:
        with open(os.path.join(point_dir, 'stats.json')) as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    r['fps'] = _num(st.get('client_fps'), '%.1f')
    r['bitrate_mbps'] = _num(st.get('bitrate_mbps'), '%.1f')
    r['encode_ms'] = _num(st.get('encode_ms'), '%.2f')
    r['encode_ms_p95'] = _num(st.get('encode_ms_p95'), '%.2f')
    r['encode_over_budget'] = _num(st.get('encode_over_budget'), '%.3f')
    try:
        with open(os.path.join(point_dir, 'ERROR')) as f:
            r['verdict'] = 'ERROR'
            r['notes'] = ' '.join(f.read().split())[:300] or 'error'
    except OSError:
        pass
    return '\t'.join(r[k].replace('\t', ' ') for k in SUMMARY_COLUMNS)


def json_get(path, dotted):
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return ''
    for k in dotted.split('.'):
        if not isinstance(d, dict) or k not in d:
            return ''
        d = d[k]
    return d if isinstance(d, str) else json.dumps(d)


def _points(path):
    with open(path) as f:
        return parse_points(f.read().splitlines())


def _one(path, name):
    for p in _points(path):
        if p['name'] == name:
            return p
    raise ValueError('no point named %s in %s' % (name, path))


def main(argv):
    usage = ('usage: fovmatrix.py names|check POINTS | sets|flag|eye-tangents|client|overlay-args POINTS NAME | merge-client FILE JSON | '
             'dump-files DIR | stats EVENTS CONSOLE | header | row NAME DIR | json-get FILE a.b')
    try:
        cmd, a = argv[1], argv[2:]
        if cmd == 'names':
            print('\n'.join(p['name'] for p in _points(a[0])))
        elif cmd == 'check':
            print('ok %d points' % len(_points(a[0])))
        elif cmd == 'sets':
            print('\n'.join(session_sets(_one(a[0], a[1]))))
        elif cmd == 'flag':
            print(_one(a[0], a[1])['flag'])
        elif cmd == 'eye-tangents':
            print(_one(a[0], a[1])['eye_tangents'] or '')
        elif cmd == 'client':
            print(json.dumps(client_settings(_one(a[0], a[1]))))
        elif cmd == 'overlay-args':
            print(' '.join(overlay_args(_one(a[0], a[1]))))
        elif cmd == 'merge-client':
            d = merge_client_settings(a[0], json.loads(a[1]))
            print('client settings', json.dumps({k: d[k] for k in json.loads(a[1])}))
        elif cmd == 'dump-files':
            for m, e, n in classify_dump(os.listdir(a[0])):
                print('%s %s %s' % (m, e, n))
        elif cmd == 'stats':
            print(json.dumps(stats(a[0], a[1])))
        elif cmd == 'header':
            print('\t'.join(SUMMARY_COLUMNS))
        elif cmd == 'row':
            print(summary_row(a[0], a[1]))
        elif cmd == 'json-get':
            print(json_get(a[0], a[1]))
        else:
            raise IndexError(cmd)
    except (IndexError, ValueError, OSError) as e:
        sys.stderr.write('fovmatrix: %s\n%s\n' % (e, usage))
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
