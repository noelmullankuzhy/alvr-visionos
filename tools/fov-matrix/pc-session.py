"""Runs on the PC inside WSL (python3, stdlib): back up, edit, restore and verify the ALVR streamer session.json,
and drive the angle-chart flag file next to it. Writes only under /mnt/c/Users/noelm/claude-tmp.
usage: pc-session.py backup|apply SETSFILE|restore|flag off|on|dump|fetch-dump BUILD   (BUILD = 12-char commit dir)
Every failure exits non-zero with a precise message; apply is strict (an unknown settings path aborts, nothing written)."""
import base64
import hashlib
import io
import json
import os
import shutil
import sys
import tarfile

ROOT = os.environ.get('FOVMATRIX_PC_ROOT', '/mnt/c/Users/noelm/claude-tmp')  # env override is for the local stub test only


def rd(path):
    with open(path) as f:
        return f.read()


def sha(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def paths(root, build):
    d = os.path.join(root, 'alvr-build', 'out', build, 'alvr_streamer_windows')
    w = os.path.join(root, 'fov-matrix')
    return {'live': os.path.join(d, 'session.json'), 'flag': os.path.join(d, 'angle_chart.enable'),
            'work': w, 'orig': os.path.join(w, 'session.orig.json'), 'sha': os.path.join(w, 'session.orig.sha256'),
            'flagorig': os.path.join(w, 'flag.orig.json'), 'nonce': os.path.join(w, 'session.orig.nonce'), 'dumps': os.path.join(root, 'angle-chart')}


def backup(root, build):
    p = paths(root, build)
    if not os.path.isfile(p['live']):
        raise SystemExit('backup FAILED: no session at %s' % p['live'])
    if os.path.exists(p['orig']):
        raise SystemExit('backup FAILED: stale backup %s (sha %s) from an earlier run that did not restore; '
                         'run run-matrix.sh --restore first' % (p['orig'], rd(p['sha']).strip() if os.path.exists(p['sha']) else '?'))
    os.makedirs(p['work'], exist_ok=True)
    # Per-run owner tag (FOVMATRIX_NONCE from run-matrix.sh), written before the backup file exists: restore with the
    # same env only touches a backup this run created.
    with open(p['nonce'], 'w') as f:
        f.write(os.environ.get('FOVMATRIX_NONCE', '') + '\n')
    shutil.copyfile(p['live'], p['orig'])
    digest = sha(p['orig'])
    if digest != sha(p['live']):
        raise SystemExit('backup FAILED: copy hash differs from live session')
    with open(p['sha'], 'w') as f:
        f.write(digest + '\n')
    flag = {'present': os.path.exists(p['flag'])}
    flag['content'] = rd(p['flag']) if flag['present'] else ''
    with open(p['flagorig'], 'w') as f:
        json.dump(flag, f)
    return 'backup sha=%s path=%s flag_present=%s' % (digest, p['orig'], flag['present'])


def apply(root, build, sets):
    p = paths(root, build)
    if not os.path.exists(p['orig']):
        raise SystemExit('apply FAILED: no backup; run backup first')
    with open(p['orig']) as f:
        s = json.load(f)
    for arg in sets:
        path, val = arg.split('=', 1)
        node = s['session_settings']
        keys = path.split('.')
        for k in keys[:-1]:
            if k not in node:
                raise SystemExit('apply FAILED: no %s in %s' % (k, path))
            node = node[k]
        if keys[-1] not in node:
            raise SystemExit('apply FAILED: no %s in %s' % (keys[-1], path))
        node[keys[-1]] = json.loads(val)
    tmp = p['live'] + '.fovmatrix.tmp'
    with open(tmp, 'w') as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, p['live'])
    return 'written %d sets sha=%s' % (len(sets), sha(p['live']))


def restore(root, build):
    p = paths(root, build)
    if not os.path.exists(p['orig']):
        return 'restore SKIP no backup (nothing was changed by this tool)'
    ours = os.environ.get('FOVMATRIX_NONCE')
    if ours:  # a run-matrix.sh run: never restore a backup another run (or a crashed one) left behind
        theirs = rd(p['nonce']).strip() if os.path.exists(p['nonce']) else ''
        if theirs != ours:
            return 'restore SKIP FOREIGN backup %s (owner %r, this run %r): left untouched; run run-matrix.sh --restore' % (p['orig'], theirs, ours)
    want = rd(p['sha']).strip() if os.path.exists(p['sha']) else ''
    if sha(p['orig']) != want:
        raise SystemExit('restore FAILED: backup %s hash %s != recorded %s; backup kept' % (p['orig'], sha(p['orig']), want))
    shutil.copyfile(p['orig'], p['live'])
    got = sha(p['live'])
    if got != want:
        raise SystemExit('restore FAILED: live hash %s != backup %s' % (got, want))
    if os.path.exists(p['flagorig']):
        flag = json.loads(rd(p['flagorig']))
        if flag['present']:
            with open(p['flag'], 'w') as f:
                f.write(flag['content'])
        elif os.path.exists(p['flag']):
            os.remove(p['flag'])
    for k in ('orig', 'sha', 'flagorig', 'nonce'):
        if os.path.exists(p[k]):
            os.remove(p[k])
    return 'restore OK sha=%s' % got


def flag(root, build, mode):
    p = paths(root, build)
    if mode == 'off':
        if os.path.exists(p['flag']):
            os.remove(p['flag'])
    elif mode in ('on', 'dump'):
        with open(p['flag'], 'w') as f:
            f.write(mode + '\n')
    else:
        raise SystemExit('flag FAILED: mode must be off|on|dump')
    return 'flag %s %s' % (mode, p['flag'])


def fetch_dump(root, build, out):
    """Tar (arc name 'dump') the newest dump dir not older than the flag file onto `out`; returns its stamp."""
    p = paths(root, build)
    if not os.path.exists(p['flag']):
        raise SystemExit('no dump: flag file missing')
    since = os.path.getmtime(p['flag']) - 1
    found = []
    if os.path.isdir(p['dumps']):
        for n in os.listdir(p['dumps']):
            d = os.path.join(p['dumps'], n)
            if os.path.isdir(d) and os.path.getmtime(d) >= since:
                found.append((os.path.getmtime(d), n))
    if not found:
        raise SystemExit('no dump: nothing under %s newer than the flag file (server did not write one; is the build '
                         'the angle-chart build and the stream up?)' % p['dumps'])
    stamp = sorted(found)[-1][1]
    with tarfile.open(fileobj=out, mode='w|') as t:
        t.add(os.path.join(p['dumps'], stamp), arcname='dump')
    return stamp


def main(argv):
    try:
        action, build = argv[1], argv[-1]
        if action == 'backup':
            print(backup(ROOT, build))
        elif action == 'apply':
            with open(argv[2]) as f:
                sets = [l.strip() for l in f if l.strip()]
            print('\n'.join('set ' + s for s in sets))
            print(apply(ROOT, build, sets))
        elif action == 'restore':
            print(restore(ROOT, build))
        elif action == 'flag':
            print(flag(ROOT, build, argv[2]))
        elif action == 'fetch-dump':
            buf = io.BytesIO()  # base64 on stdout: ssh/cmd.exe text handling cannot corrupt it
            stamp = fetch_dump(ROOT, build, buf)
            sys.stdout.write(base64.b64encode(buf.getvalue()).decode() + '\n')
            sys.stderr.write('dump %s\n' % stamp)
        else:
            raise SystemExit('unknown action %s' % action)
    except (IndexError, ValueError, OSError) as e:
        raise SystemExit('%s FAILED: %s' % (argv[1] if len(argv) > 1 else 'usage', e))


if __name__ == '__main__':
    main(sys.argv)
