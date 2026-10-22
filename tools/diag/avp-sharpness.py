#!/usr/bin/env python3
"""Predicted stream sharpness (px/deg) on the Vision Pro's recorded per-eye frustum, for docs/lumen/avp-frustum-sharpness.md.

For each candidate (fov scale x foveation x per-eye coded budget) the render is the largest at the AVP aspect (3648:2912)
whose foveated coded size fits the budget; px/deg is fov-overlay.py's page prediction (render px per degree over the
foveation squeeze) on the eye axis (tan 0) and 10/20/30 deg off it, per eye, horizontal (temporal, nasal) and vertical
(up, down). Usage: python3 tools/diag/avp-sharpness.py [--full]. Standard library only."""
import importlib.util
import math
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('fov_overlay', Path(__file__).with_name('fov-overlay.py'))
fo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fo)

AVP = {'L': (1.782, 1.019, 1.019, 1.217), 'R': (1.032, 1.820, 1.033, 1.236)}   # |tan| L,R,D,U (GOAL.md:365)
ASPECT = (3648, 2912)
BUDGETS = {'A': (2432, 1856), 'B': (2528, 1920), 'C': (2784, 2240)}            # per-eye coded (w6-encoder-plan.md:63-67)
SCALES = (1.0, 0.85, 0.7)
ANGLES = (10, 20, 30)
GAME_PX_PER_TAN = 989                     # R.E.A.L. (GOAL.md:366)


def axis_shift(near, far, c):
    """ALVR centre_shift that puts the 1:1 band's centre on the eye axis (fov-overlay centre_shift, any tangents)."""
    return (near / (near + far) - 0.5) / (((1 - c) / 2) or 1)


def avp_shift(cx, cy):
    """One shift for both eyes (ALVR mirrors x for the right eye; y is shared): the mean of the per-eye shifts."""
    sx = [axis_shift(AVP['L'][0], AVP['L'][1], cx), axis_shift(AVP['R'][1], AVP['R'][0], cx)]   # temporal share
    sy = [axis_shift(AVP[e][3], AVP[e][2], cy) for e in 'LR']                                  # up share
    return round(sum(sx) / 2, 3), round(sum(sy) / 2, 3)


def foveations():
    out = {'off': None, 'asrun': (0.5, 0.45, 3, 3, 0, 0), 'centred-sim': (0.5, 0.45, 3, 3, 0.536, -0.159),
           'wider-sim': (0.6, 0.6, 2.5, 2.5, 0.536, -0.159)}
    out['centred-avp'] = (0.5, 0.45, 3, 3) + avp_shift(0.5, 0.45)
    out['wider-avp'] = (0.6, 0.6, 2.5, 2.5) + avp_shift(0.6, 0.6)
    return out


def axes_for(fv, w, h):
    if fv is None:
        return fo.fov_off(w), fo.fov_off(h)
    cx, cy, rx, ry, shx, shy = fv
    return fo.fov_axis(cx, shx, rx, w), fo.fov_axis(cy, shy, ry, h)


def max_render(fv, budget):
    """Largest W (multiple of 16) at the AVP aspect whose coded size fits the per-eye budget."""
    best = None
    for w in range(16, 8192, 16):
        h = int(round(w * ASPECT[1] / ASPECT[0] / 2)) * 2
        ax, ay = axes_for(fv, w, h)
        if ax['coded'] > budget[0] or ay['coded'] > budget[1]:
            break
        best = (w, h, ax['coded'], ay['coded'])
    return best


def eye_detail(eye, s, fv, w, h):
    """{'h0','v0', 'T10','N10','U10','D10', ...} px/deg for one eye."""
    l, r, d, u = (s * v for v in AVP[eye])
    ax, ay = axes_for(fv, w, h)
    x = fo.make_axis('h', 'render', -l, r, w, fov=None if fv is None else ax, mirror=eye == 'R')
    y = fo.make_axis('v', 'render', -u, d, h, fov=None if fv is None else ay)
    out = {'h0': x.page_px_per_deg(0.0), 'v0': y.page_px_per_deg(0.0)}
    temporal = -1 if eye == 'L' else 1
    for a in ANGLES:
        t = math.tan(math.radians(a))
        out['T%d' % a] = x.page_px_per_deg(temporal * t)
        out['N%d' % a] = x.page_px_per_deg(-temporal * t)
        out['U%d' % a] = y.page_px_per_deg(-t)            # rows: tau = -y tangent, up is negative
        out['D%d' % a] = y.page_px_per_deg(t)
    return out


def game(a):
    return GAME_PX_PER_TAN * (1 + math.tan(math.radians(a)) ** 2) * math.pi / 180


def candidates():
    for bname, budget in BUDGETS.items():
        for s in SCALES:
            for fname, fv in foveations().items():
                w, h, cw, ch = max_render(fv, budget)
                det = {e: eye_detail(e, s, fv, w, h) for e in 'LR'}
                yield {'budget': bname, 's': s, 'fov': fname, 'fv': fv, 'render': (w, h), 'coded': (cw, ch), 'det': det,
                       'centre': min(det[e][k] for e in 'LR' for k in ('h0', 'v0')),
                       'worst': {a: min(det[e][k + str(a)] for e in 'LR' for k in 'TNUD') for a in ANGLES}}


def main(argv):
    rows = list(candidates())
    print('Game (R.E.A.L. 989 px/tan): centre %.1f, 10 deg %.1f, 20 deg %.1f, 30 deg %.1f px/deg' % ((game(0),) + tuple(game(a) for a in ANGLES)))
    print('AVP-centred shifts: centred %s, wider %s' % (foveations()['centred-avp'][4:], foveations()['wider-avp'][4:]))
    print()
    print('| budget | s | foveation | render | coded/eye | centre min | L h/v | R h/v | worst 10 | worst 20 | worst 30 | full frustum |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|')
    for c in rows:
        L, R = c['det']['L'], c['det']['R']
        print('| %s | %g | %s | %dx%d | %dx%d | %.1f | %.1f/%.1f | %.1f/%.1f | %.1f | %.1f | %.1f | %s |' % (
            c['budget'], c['s'], c['fov'], c['render'][0], c['render'][1], c['coded'][0], c['coded'][1], c['centre'],
            L['h0'], L['v0'], R['h0'], R['v0'], c['worst'][10], c['worst'][20], c['worst'][30], 'yes' if c['s'] == 1.0 else 'no'))
    if '--full' in argv:
        keys = ['h0', 'v0'] + ['%s%d' % (k, a) for k in 'TNUD' for a in ANGLES]
        print()
        print('| budget | s | foveation | eye | ' + ' | '.join(keys) + ' |')
        print('|---|---|---|---|' + '---|' * len(keys))
        for c in rows:
            for e in 'LR':
                print('| %s | %g | %s | %s | ' % (c['budget'], c['s'], c['fov'], e) +
                      ' | '.join('%.1f' % c['det'][e][k] for k in keys) + ' |')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
