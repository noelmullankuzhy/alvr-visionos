#!/usr/bin/env python3
"""Predicted stream sharpness (px/deg) on the Vision Pro's per-eye frustum; writes points-chart-avp.tsv and
docs/lumen/avp-frustum-sharpness.md from one parameter file (tools/fov-matrix/avp-field.json: device frustum tangents,
visible field, fov scales, foveation sizes). Replace the visible field there (e.g. a seal-off measurement) and rerun:

  python3 tools/diag/avp-sharpness.py points > tools/fov-matrix/points-chart-avp.tsv
  python3 tools/diag/avp-sharpness.py doc > docs/lumen/avp-frustum-sharpness.md

Variants: asrun (fixed size, no shift); axis (fixed size, band centred on the eye axis); centred (fixed size, band centred
on the visible field); wider (band spans the whole visible field, centred on it); off. Each candidate's render is the
largest at the 3648:2912 aspect whose foveated coded size fits the per-eye budget; px/deg is fov-overlay.py's page
prediction (render px per degree over the foveation squeeze). Standard library only; `--field FILE` overrides the file."""
import importlib.util
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fov_overlay', HERE / 'fov-overlay.py')
fo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fo)

FIELD_FILE = HERE.parent / 'fov-matrix' / 'avp-field.json'
ASPECT = (3648, 2912)
BUDGETS = {'A': (2432, 1856), 'B': (2528, 1920), 'C': (2784, 2240)}            # per-eye coded (w6-encoder-plan.md:63-67)
ANGLES = (10, 20, 30)
GAME_PX_PER_TAN = 989                     # R.E.A.L. render density (GOAL.md:366)
VARIANTS = ('off', 'asrun', 'axis', 'centred', 'wider')


def load(path=FIELD_FILE):
    p = json.loads(Path(path).read_text())
    for eye in 'LR':
        t = p['frustum_tan_LRDU'][eye]
        if len(t) != 4 or not all(v > 0 for v in t):
            raise ValueError('frustum_tan_LRDU.%s: need four positive |tan| L,R,D,U' % eye)
    return p


def sides(p, eye, s):
    """Scaled frustum |tan| (temporal, nasal, up, down) of one eye."""
    l, r, d, u = (s * v for v in p['frustum_tan_LRDU'][eye])
    return (l, r, u, d) if eye == 'L' else (r, l, u, d)


def field_tan(p):
    f = p['visible_field_deg']
    return {k: math.tan(math.radians(f[k])) for k in ('temporal', 'nasal', 'up', 'down')}


def field_fractions(p, eye, s):
    """Visible field edges and centre as fractions of the scaled frustum: x from the temporal edge, y from the top."""
    t, n, u, d = sides(p, eye, s)
    f = field_tan(p)
    if f['temporal'] > t or f['nasal'] > n or f['up'] > u or f['down'] > d:
        raise ValueError('visible field exceeds the %s frustum at fov scale %g' % (eye, s))
    x0, x1 = (t - f['temporal']) / (t + n), (t + f['nasal']) / (t + n)
    y0, y1 = (u - f['up']) / (u + d), (u + f['down']) / (u + d)
    return (x0, x1), (y0, y1)


def device_density(p):
    """visionOS logical px per tan unit (x, y) and px/deg on the axis: the viewport over the left eye's |tan| spans."""
    l, r, d, u = p['frustum_tan_LRDU']['L']
    vw, vh = p['frustum_tan_LRDU']['viewport']
    return vw / (l + r), vh / (d + u), vw / (l + r) * math.pi / 180


def shift_for(frac, c):
    """ALVR center_shift for a band centred at `frac` of the eye: the band spans [c0(1 + s), 1 - c0(1 - s)] with
    c0 = (1 - c)/2, so its centre is 0.5 + s c0 (ALVRClient/Shaders.metal:152-157; FFR.swift:88-89 only rounds s)."""
    return (frac - 0.5) / (((1 - c) / 2) or 1)


def axis_shift(t_lo, t_hi, c):
    """center_shift that centres the band on the eye axis (tan 0) of an axis spanning |tan| t_lo at eye UV 0 to t_hi at
    UV 1: (t_lo - t_hi) / (t_lo + t_hi) / (1 - c). Eye UV x runs from the temporal edge (R mirrored, Shaders.metal:136-140),
    y from the top (texture row 0), so t_lo is temporal for x and up for y; negative y moves the band up."""
    return shift_for(t_lo / (t_lo + t_hi), c)


def mean(v):
    return sum(v) / len(v)


def derive(p, s, variant):
    """(cx, cy, rx, ry, shx, shy) or None. One shift for both eyes (ALVR mirrors x for R): the mean of the per-eye ones."""
    if variant == 'off':
        return None
    if variant == 'asrun':
        (cx, cy), (rx, ry) = p['asrun']['size'], p['asrun']['edge_ratio']
        return (cx, cy, rx, ry, 0.0, 0.0)
    if variant == 'axis':                   # eye axis = tan 0
        (cx, cy), (rx, ry) = p['centred']['size'], p['centred']['edge_ratio']
        shx = mean([axis_shift(*sides(p, e, s)[:2], cx) for e in 'LR'])     # temporal, nasal
        shy = mean([axis_shift(*sides(p, e, s)[2:], cy) for e in 'LR'])     # up, down
        return (cx, cy, rx, ry, round(shx, 3), round(shy, 3))
    fr = [field_fractions(p, e, s) for e in 'LR']
    fx, fy = mean([mean(x) for x, _ in fr]), mean([mean(y) for _, y in fr])
    if variant == 'centred':
        (cx, cy), (rx, ry) = p['centred']['size'], p['centred']['edge_ratio']
        return (cx, cy, rx, ry, round(shift_for(fx, cx), 3), round(shift_for(fy, cy), 3))
    rx, ry = p['wider']['edge_ratio']
    out = []
    for k, (r, n, frac) in enumerate(((rx, ASPECT[0], fx), (ry, ASPECT[1], fy))):
        need = max(x[k][1] - x[k][0] for x in fr)
        c = math.ceil(need * 1000) / 1000
        while True:                         # ALVR rounds the band to 2r px steps: widen until the field is inside it
            sh = round(shift_for(frac, c), 3)
            b0, b1 = fo.band_fractions(fo.fov_axis(c, sh, r, n))
            if all(b0 <= x[k][0] and x[k][1] <= b1 for x in fr) or c >= 1:
                break
            c = round(c + 0.001, 3)
        out.append((c, r, sh))
    (cx, rx, shx), (cy, ry, shy) = out
    return (cx, cy, rx, ry, shx, shy)


def axes_for(fv, w, h):
    if fv is None:
        return fo.fov_off(w), fo.fov_off(h)
    cx, cy, rx, ry, shx, shy = fv
    return fo.fov_axis(cx, shx, rx, w), fo.fov_axis(cy, shy, ry, h)


def max_render(fv, budget):
    """Largest W (multiple of 16) at the render aspect whose coded size fits the per-eye budget."""
    best = None
    for w in range(16, 8192, 16):
        h = int(round(w * ASPECT[1] / ASPECT[0] / 2)) * 2
        ax, ay = axes_for(fv, w, h)
        if ax['coded'] > budget[0] or ay['coded'] > budget[1]:
            break
        best = (w, h, ax['coded'], ay['coded'])
    return best


def eye_detail(p, eye, s, fv, w, h):
    """px/deg on the eye axis (h0, v0), at 10/20/30 deg (T10.. N.. U.. D..) and at the visible-field edges (Tf Nf Uf Df)."""
    l, r, d, u = (s * v for v in p['frustum_tan_LRDU'][eye])
    ax, ay = axes_for(fv, w, h)
    x = fo.make_axis('h', 'render', -l, r, w, fov=None if fv is None else ax, mirror=eye == 'R')
    y = fo.make_axis('v', 'render', -u, d, h, fov=None if fv is None else ay)
    temporal = -1 if eye == 'L' else 1
    out = {'h0': x.page_px_per_deg(0.0), 'v0': y.page_px_per_deg(0.0)}
    f = p['visible_field_deg']
    for a, tag in [(a, str(a)) for a in ANGLES] + [(None, 'f')]:
        deg = {k: (a if a is not None else f[k]) for k in ('temporal', 'nasal', 'up', 'down')}
        tan = {k: math.tan(math.radians(v)) for k, v in deg.items()}
        out['T' + tag] = x.page_px_per_deg(temporal * tan['temporal'])
        out['N' + tag] = x.page_px_per_deg(-temporal * tan['nasal'])
        out['U' + tag] = y.page_px_per_deg(-tan['up'])          # rows: tau = -y tangent, up is negative
        out['D' + tag] = y.page_px_per_deg(tan['down'])
    return out


def game(a):
    return GAME_PX_PER_TAN * (1 + math.tan(math.radians(a)) ** 2) * math.pi / 180


def candidates(p):
    for bname, budget in BUDGETS.items():
        for s in p['fov_scales']:
            for v in VARIANTS:
                fv = derive(p, s, v)
                w, h, cw, ch = max_render(fv, budget)
                det = {e: eye_detail(p, e, s, fv, w, h) for e in 'LR'}
                f = p['visible_field_deg']
                game_ok = all(det[e][k + str(a)] >= game(a) - 1e-9 for e in 'LR' for k in 'TNUD' for a in ANGLES) and \
                    all(det[e][k + 'f'] >= game(f[n]) - 1e-9 for e in 'LR' for k, n in zip('TNUD', ('temporal', 'nasal', 'up', 'down')))
                yield {'budget': bname, 's': s, 'fov': v, 'fv': fv, 'render': (w, h), 'coded': (cw, ch), 'det': det,
                       'centre': min(det[e][k] for e in 'LR' for k in ('h0', 'v0')),
                       'worst': {a: min(det[e][k + str(a)] for e in 'LR' for k in 'TNUD') for a in ANGLES},
                       'edge': min(det[e][k + 'f'] for e in 'LR' for k in 'TNUD'), 'game_ok': game_ok}


def recommend(rows):
    """Full frustum (s = 1.0): 1 sharpest centre at any budget; 2 sharpest centre at budget A; 3 at budget A, the sharpest
    centre that stays at or above the game's density to 30 deg and at the field edge (else the best field edge). Ties go
    to the better field edge."""
    full = [r for r in rows if r['s'] == 1.0 and r['fov'] != 'off']
    key = lambda r: (round(r['centre'], 1), r['edge'])
    first = max(full, key=key)
    second = max([r for r in full if r['budget'] == 'A'], key=key)
    a = [r for r in full if r['budget'] == 'A' and r is not second]
    ok = [r for r in a if r['game_ok']]
    third = max(ok, key=key) if ok else max(a, key=lambda r: r['edge'])
    return [first, second, third]


def fvtext(fv):
    return 'off' if fv is None else ','.join('%g' % v for v in fv)


def points(p):
    pt, e = p['points'], p['frustum_tan_LRDU']
    eyes = 'L:%s;R:%s' % tuple(','.join('%g' % v for v in e[k]) for k in 'LR')
    out = ['# name\tfov_scale\trender_scale\tfoveation(cx,cy,rx,ry,shx,shy|off)\tbitrate_mbps\tfps\textra session key=value (one per column)',
           '# Generated by tools/diag/avp-sharpness.py points from tools/fov-matrix/avp-field.json (device frustum, visible field',
           '# %(nasal)g/%(temporal)g/%(up)g/%(down)g deg nasal/temporal/up/down); the client reports eye_tangents x fov_scale.' % p['visible_field_deg']]
    for s in p['fov_scales']:
        for v in ('asrun', 'centred', 'wider'):
            out.append('a%03d-%s\t%g\t%g\t%s\t%g\t%g\teye_tangents=%s' % (round(s * 100), v, s, pt['render_scale'], fvtext(derive(p, s, v)),
                                                                      pt['bitrate_mbps'], pt['fps'], eyes))
    out.append('# The three recommended settings (doc "Recommendation"): render scale = the budget\'s render width / 3648.')
    for r in recommend(list(candidates(p))):
        out.append('a%03d-%s-%s\t%g\t%g\t%s\t%g\t%g\teye_tangents=%s' % (round(r['s'] * 100), r['fov'], r['budget'], r['s'], round(r['render'][0] / ASPECT[0], 4),
                                                                         fvtext(r['fv']), pt['bitrate_mbps'], pt['fps'], eyes))
    return '\n'.join(out) + '\n'


def table(rows):
    out = ['| budget | s | foveation | cx,cy,rx,ry,shx,shy | render | coded/eye | centre min | L h/v | R h/v | worst 10 | worst 20 | worst 30 | field edge | game met | full frustum |',
           '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|']
    for c in rows:
        L, R = c['det']['L'], c['det']['R']
        out.append('| %s | %g | %s | %s | %dx%d | %dx%d | %.1f | %.1f/%.1f | %.1f/%.1f | %.1f | %.1f | %.1f | %.1f | %s | %s |' % (
            c['budget'], c['s'], c['fov'], fvtext(c['fv']), c['render'][0], c['render'][1], c['coded'][0], c['coded'][1],
            c['centre'], L['h0'], L['v0'], R['h0'], R['v0'], c['worst'][10], c['worst'][20], c['worst'][30], c['edge'],
            'yes' if c['game_ok'] else 'no', 'yes' if c['s'] == 1.0 else 'no'))
    return out


def full_table(rows):
    keys = ['h0', 'v0'] + ['%s%s' % (k, a) for k in 'TNUD' for a in list(ANGLES) + ['f']]
    out = ['| budget | s | foveation | eye | ' + ' | '.join(keys) + ' |', '|---|---|---|---|' + '---|' * len(keys)]
    for c in rows:
        for e in 'LR':
            out.append('| %s | %g | %s | %s | ' % (c['budget'], c['s'], c['fov'], e) + ' | '.join('%.1f' % c['det'][e][k] for k in keys) + ' |')
    return out


def doc(p):
    rows = list(candidates(p))
    rec = recommend(rows)
    e, f = p['frustum_tan_LRDU'], p['visible_field_deg']
    fdeg = lambda t: math.degrees(math.atan(t))
    t = e['L']
    w = ASPECT[0] / (t[0] + t[1]) * math.pi / 180
    lines = [
        '# AVP frustum sharpness: fov scale x foveation x stream size', '',
        'Generated by `python3 tools/diag/avp-sharpness.py doc` from `tools/fov-matrix/avp-field.json`; edit that file '
        '(e.g. a seal-off visible field), not this one. Predicted stream detail (px/deg) per eye, using `fov-overlay.py`\'s '
        'ALVR foveation model (FFR.cpp, float32) and page prediction. These are predictions; the `points-chart-avp.tsv` '
        'matrix checks line positions in the simulator, and sharpness on the device is unmeasured.', '',
        '## Inputs', '',
        '| Input | Value | Source |', '|---|---|---|',
        '| Frustum \\|tan\\| L,R,D,U | L %s; R %s (L: temporal %.0f, nasal %.0f, down %.0f, up %.0f deg; R mirrored) | %s |' % (
            ', '.join('%g' % v for v in e['L']), ', '.join('%g' % v for v in e['R']), fdeg(t[0]), fdeg(t[1]), fdeg(t[2]), fdeg(t[3]),
            e['source']),
        '| Visible field per eye | nasal %g, temporal %g, up %g, down %g deg | %s |' % (f['nasal'], f['temporal'], f['up'], f['down'], f['source']),
        '| Render aspect | 3648:2912 at render scale 1.0 (%.1f px/deg on the axis horizontally at 3648) | page standard preset |' % w,
        '| Per-eye coded budget A / B / C | 2432x1856 (today, coded 4864x1856) / 2528x1920 / 2784x2240 (5568x2240, 12.47 MP: the largest '
        'judged viable, only at NVENC P4, multi-pass off, split2; estimate) | w6-encoder-plan.md:63-67, :91 |',
        '| HEVC level | All three exceed Level 5.x (8.9 MP), so Level 6.x; 500 Mbps needs 6.2 High tier (recalled from H.265 Annex A, '
        'not checked against the SPS) | w6-encoder-plan.md:123-125 |',
        '| Game density | R.E.A.L. renders 989 px/tan: %.1f px/deg at the centre; 989 x (1 + tan^2) x pi/180 = %.1f / %.1f / %.1f at '
        '10 / 20 / 30 deg | GOAL.md:366 |' % ((game(0),) + tuple(game(a) for a in ANGLES)),
        '| AVP display density | visionOS asks for %.1f logical px/deg on the axis (%dx%d = %.1f px per tan unit at render '
        'quality 1.0). That it reaches the eye is **not established** (physical texture 2432x2368 under a rate map not logged). '
        'Panel ~36 PPD is **unverified** | avp-frustum-reference.md; GOAL.md:230 |' % (
            device_density(p)[2], e['viewport'][0], e['viewport'][1], device_density(p)[0]), '',
        'The R.E.A.L. log tangents (L U1.217 D1.019 L1.782 R1.019, R mirrored) are not used: they are what our client sent before '
        'the W32 fix (up and down swapped, below) after the per-eye canting circumscription (L x1.0118, R x1.0205), not the device '
        'frustum (W32 report, logs/w32-report.md).', '',
        '## FOV up/down correction', '',
        '- Before W32 (`bugfix/fov-updown` 78bf427, merged to develop in 45f0079) the client sent CompositorServices\' bottom tangent as '
        '`Fov.up`: every stream so far was rendered %.0f deg up / %.0f deg down. With the fix it is %.0f up / %.0f down, the device\'s, '
        'and the eye axis sits %.1f deg above the frame\'s centre.' % (fdeg(t[2]), fdeg(t[3]), fdeg(t[3]), fdeg(t[2]),
                                                                       fdeg((t[2] - t[3]) / 2)),
        '- ALVR\'s convention: the 1:1 band spans eye UV [c0(1 + s), 1 - c0(1 - s)], c0 = (1 - c)/2, centre 0.5 + s c0 '
        '(`ALVRClient/Shaders.metal:152-157`; `FFR.swift:88-89` only rounds s to 2r px). Eye UV x runs from the temporal edge '
        '(R mirrored, `Shaders.metal:136-140`) and y from the top row, so a negative `center_shift_y` moves the band up. '
        'The axis-centred shift is (t_lo - t_hi)/(t_lo + t_hi)/(1 - c) with t_lo the temporal (x) or up (y) |tan| '
        '(`axis_shift` in the generator).',
        '- `center_shift_y` for the axis variant (c %g): pre-W32 stream (up %g, down %g) %+.3f; corrected stream (up %g, down %g) '
        '%+.3f. This analysis has always used the device frustum, so its -0.159 is unchanged, but it suits only a client with the '
        'W32 fix; on a pre-W32 client (axis below the centre) it centres the band above the axis by twice the axis offset. '
        '`center_shift_x` is unaffected (%+.3f).' % (
            p['centred']['size'][1], t[2], t[3], axis_shift(t[2], t[3], p['centred']['size'][1]), t[3], t[2],
            axis_shift(t[3], t[2], p['centred']['size'][1]), derive(p, 1.0, 'axis')[4]),
        '- The simulator emulation assumes the W32 fix is on the client: `-ALVRDebugEyeTangents "L:<l>,<r>,<d>,<u>;R:..."` fills '
        'the gimmeTangents slots (left, right, bottom, top), which W32\'s `ViewLayout.fovAngles` packs as up = .w, down = .z. '
        'Without the fix the client sends d as up.', '',
        '## Variants (derived from the visible field per fov scale)', '',
        '- `asrun`: c %s, r %s, no shift. `off`: no foveation (coded = render).' % (
            '/'.join('%g' % v for v in p['asrun']['size']), '/'.join('%g' % v for v in p['asrun']['edge_ratio'])),
        '- `axis`: c and r as `centred`, band centre on the eye axis (tan 0): shift %g/%g at s = 1, from the tangents '
        '(see "FOV up/down correction").' % derive(p, 1.0, 'axis')[4:],
        '- `centred`: c %s, r %s, band centre on the visible field\'s centre (midpoint of its edge tangents), shift = '
        '(fraction - 0.5)/((1 - c)/2), x from the temporal edge, y from the top.' % (
            '/'.join('%g' % v for v in p['centred']['size']), '/'.join('%g' % v for v in p['centred']['edge_ratio'])),
        '- `wider`: r %s; c = the field\'s share of the frustum, widened in 0.001 steps until ALVR\'s rounded band holds the whole field; '
        'centred on it like `centred`.' % '/'.join('%g' % v for v in p['wider']['edge_ratio']),
        '- ALVR has one shift for both eyes (x mirrored for R); the shift is the mean of the per-eye values (equal for mirrored eyes).',
        '- Coverage: only s = 1.0 covers the full frustum; every listed s still covers the visible field.', '',
        '## Recommendation (full frustum, s = 1.0)', '',
        'Rule: 1 the sharpest centre at any budget; 2 the sharpest centre at today\'s budget A; 3 at budget A, the sharpest centre '
        'that stays at or above the game\'s density to 30 deg and at the field edges (else the best field edge). Ties go to the '
        'better field edge.', '',
        '| # | Setting | Render / coded per eye | Centre px/deg (L h/v, R h/v) | Worst at 10 / 20 / 30 deg | Worst at the field edge | Game met |',
        '|---|---|---|---|---|---|---|']
    for i, c in enumerate(rec, 1):
        L, R = c['det']['L'], c['det']['R']
        lines.append('| %d | budget %s, `%s` %s | %dx%d / %dx%d | %.1f/%.1f, %.1f/%.1f | %.1f / %.1f / %.1f | %.1f | %s |' % (
            i, c['budget'], c['fov'], fvtext(c['fv']), c['render'][0], c['render'][1], c['coded'][0], c['coded'][1],
            L['h0'], L['v0'], R['h0'], R['v0'], c['worst'][10], c['worst'][20], c['worst'][30], c['edge'], 'yes' if c['game_ok'] else 'no'))
    lines += ['', 'The simulator matrix runs these as `%s` in `points-chart-avp.tsv`.' % '`, `'.join(
        'a%03d-%s-%s' % (round(c['s'] * 100), c['fov'], c['budget']) for c in rec)]
    lines += ['', 'With RDR2 at 989 px/tan, centre detail above %.1f px/deg is resampling margin, not new detail. None of these '
              'reaches the 40 logical px/deg that visionOS asks for.' % game(0), '',
              '## All candidates (min over both eyes)', '',
              '`centre min` = the lowest of L h, L v, R h, R v on the axis. `worst N` = the lowest of temporal, nasal, up and down at N deg. '
              '`field edge` = the lowest at the visible-field edges. `game met` = at or above the game\'s density at every one of those points.', '']
    lines += table(rows)
    lines += ['', '## Per eye and direction (px/deg)', '',
              '`h0`/`v0` = eye axis horizontal/vertical; T temporal, N nasal, U up, D down at 10/20/30 deg; `f` = at the visible-field edge.', '']
    lines += full_table(rows)
    return '\n'.join(lines) + '\n'


def main(argv):
    args = list(argv)
    path = FIELD_FILE
    if '--field' in args:
        i = args.index('--field')
        path = args[i + 1]
        del args[i:i + 2]
    cmd = args[0] if args else 'tables'
    p = load(path)
    if cmd == 'points':
        sys.stdout.write(points(p))
    elif cmd == 'doc':
        sys.stdout.write(doc(p))
    elif cmd == 'tables':
        rows = list(candidates(p))
        print('\n'.join(table(rows)))
        print('\nrecommended: ' + '; '.join('%s %g %s %.1f' % (r['budget'], r['s'], r['fov'], r['centre']) for r in recommend(rows)))
    else:
        sys.stderr.write('usage: avp-sharpness.py [--field FILE] points|doc|tables\n')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
