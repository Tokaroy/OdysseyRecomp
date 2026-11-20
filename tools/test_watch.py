"""The test watcher: every problem a test run shows, in one report.

  python tools/test_watch.py <log> [<log> ...] [--frames build/frames] [--out build/watch]

From the logs: crashes and stops ([diag], FATAL, exceptions, device lost), freezes ([freeze]), validation messages,
shader / pipeline failures, every hitch with its cause and the stage it was in, frame-rate drops (2-s windows under
58 fps), skipped draws, in-between draws left out, the interpolation's brake and fit lines.

From the images of ODYSSEY_BURST (frame_<N>_mid<k>.png then frame_<N>.png: the order on screen): flicker - a part of the
picture that changes sharply in one image and is back in the next (A, B, A). Camera motion changes images steadily
(A, B, C), a cut changes everything: neither is flicker. Each flicker found is saved as a strip of the three images
(the spot marked) in <out>/flicker_<n>.png. Also in-betweens that repeat the image before them while the frame moves
(a stutter) or that are not between their two frames (a jump).

The report: <out>/report.md (and printed).
"""
import glob
import os
import re
import sys
from collections import Counter, defaultdict


def parse_args(argv):
    logs, frames, out = [], None, 'build/watch'
    i = 0
    while i < len(argv):
        if argv[i] == '--frames':
            frames = argv[i + 1]; i += 2
        elif argv[i] == '--out':
            out = argv[i + 1]; i += 2
        else:
            logs.append(argv[i]); i += 1
    return logs, frames, out


def scan_log(path):
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    stage, stage_at = '?', []
    found = defaultdict(list)
    hitch_causes = Counter()
    hitch_stage = defaultdict(list)
    windows = defaultdict(lambda: [0, 0])  # stage -> [windows, under 58]
    skipped = defaultdict(int)
    for ln in lines:
        m = re.match(r'\[warp\] stage scene \S+ running at frame (\d+)(?:: (\S+))?', ln)
        if m:
            stage = m.group(2) or stage
            continue
        m = re.match(r'\[travel\] arrived: (\S+)', ln)
        if m:
            stage = m.group(1)
        if ln.startswith('[diag]') or ln.startswith('FATAL') or 'exception c0' in ln or 'device lost' in ln.lower():
            found['stop / crash'].append(f'{stage}: {ln.strip()[:160]}')
        if ln.startswith('[freeze]'):
            found['freeze'].append(f'{stage}: {ln.strip()[:160]}')
        if 'VUID-' in ln or 'UNASSIGNED-' in ln:
            v = re.search(r'(VUID-[\w-]+|UNASSIGNED-[\w-]+)', ln)
            found['validation'].append(v.group(1) if v else ln[:120])
        if re.search(r'translate failed|pipeline (creation|link) failed|library .* failed', ln):
            found['shader / pipeline failure'].append(f'{stage}: {ln.strip()[:160]}')
        if ln.startswith('[travel]') and ('never' in ln or 'given up' in ln):
            found['trip not finished'].append(f'{stage}: {ln.strip()[:160]}')
        m = re.match(r'\[hitch\] frame (\d+): (\d+) ms, cause: ([^(]+)', ln)
        if m:
            ms, cause = int(m.group(2)), m.group(3).strip()
            hitch_causes[cause] += 1
            hitch_stage[stage].append((ms, int(m.group(1)), cause))
        m = re.match(r'\[vk\] t=\S+ frame (\d+) ([\d.]+) fps.*?(\d+) skipped', ln)
        if m:
            w = windows[stage]
            w[0] += 1
            w[1] += float(m.group(2)) < 58
            skipped[stage] += int(m.group(3))
        m = re.search(r'replay draws left out (\d+)', ln)
        if m and int(m.group(1)):
            found['in-between draws left out'].append(f'{stage}: {m.group(1)}')
        if ln.startswith('[interp]') and ('missed its vsync' in ln or 'fewer in-betweens' in ln):
            found['interpolation held back'].append(f'{stage}: {ln.strip()[9:140]}')
    return found, hitch_causes, hitch_stage, windows, skipped


def flicker_scan(frames_dir, out):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return ['(PIL missing: no image check)']
    files = glob.glob(os.path.join(frames_dir, 'frame_*.png'))
    seq = []
    for f in files:
        m = re.match(r'frame_(\d+)(?:_mid(\d+))?\.png$', os.path.basename(f))
        if m:
            n, k = int(m.group(1)), m.group(2)
            seq.append(((n, int(k) if k else 99), f))  # (the in-betweens before their frame)
    seq.sort()
    if len(seq) < 3:
        return []
    W, H, B = 160, 90, 10  # (each image in 16 x 9 blocks of 10 x 10 at 160 x 90)
    small = {}

    def lum(f):
        if f not in small:
            try:
                small[f] = Image.open(f).convert('L').resize((W, H), Image.BILINEAR)
            except Exception:  # (an image cut off when the run ended: left out)
                small[f] = None
        return small[f]

    def blocks(im):
        px = im.load()
        return [[sum(px[x, y] for x in range(bx * B, bx * B + B) for y in range(by * B, by * B + B)) / (B * B)
                 for bx in range(W // B)] for by in range(H // B)]
    events = []
    os.makedirs(out, exist_ok=True)
    for i in range(len(seq) - 2):
        (ka, fa), (kb, fb), (kc, fc) = seq[i], seq[i + 1], seq[i + 2]
        if kc[0] - ka[0] > 2:  # (not consecutive: another burst)
            continue
        la, lb, lc = lum(fa), lum(fb), lum(fc)
        if la is None or lb is None or lc is None:
            continue
        a, b, c = blocks(la), blocks(lb), blocks(lc)
        diffs = [abs(b[y][x] - a[y][x]) for y in range(len(a)) for x in range(len(a[0]))]
        if sum(d > 25 for d in diffs) > len(diffs) * 0.5:  # (a cut or a fast turn: everything changed)
            continue
        for y in range(len(a)):
            for x in range(len(a[0])):
                d1, d2, d0 = abs(b[y][x] - a[y][x]), abs(c[y][x] - b[y][x]), abs(c[y][x] - a[y][x])
                if d1 > 30 and d2 > 30 and d0 < 0.25 * min(d1, d2):
                    events.append((fa, fb, fc, x, y, d1, d2))
    # In-betweens that don't move (0.2.8: the 2nd and 3rd in-betweens at 240 repeated the 1st - the replays ran the next
    # frame's command lists): within a frame's images (frame N-1, its in-betweens, frame N), one identical to the image
    # before it while the frame as a whole moved is a stutter; one that is farther from both frames than they are from
    # each other went somewhere neither frame shows.
    by_frame = defaultdict(dict)
    for (n, k), f in seq:
        by_frame[n][k] = f
    stalls = []
    for n in sorted(by_frame):
        mids = sorted(k for k in by_frame[n] if k != 99)
        if not mids or 99 not in by_frame[n] or 99 not in by_frame.get(n - 1, {}):
            continue
        chain = [by_frame[n - 1][99]] + [by_frame[n][k] for k in mids] + [by_frame[n][99]]
        ims = [lum(f) for f in chain]
        if any(im is None for im in ims):
            continue
        def dist(a, b):
            pa, pb = a.load(), b.load()
            return sum(abs(pa[x, y] - pb[x, y]) for x in range(0, W, 2) for y in range(0, H, 2)) / ((W // 2) * (H // 2))
        whole = dist(ims[0], ims[-1])
        if whole < 1.0:  # (a still picture: nothing to see)
            continue
        steps = [dist(a, b) for a, b in zip(ims, ims[1:])]
        same = [i for i, s in enumerate(steps[:-1]) if s < 0.02 * whole and i > 0]
        if same:
            stalls.append(f'frame {n}: in-between(s) {", ".join(str(mids[i]) for i in same)} repeat the image before '
                          f'(the frame moved {whole:.1f}/255; steps {", ".join(f"{s:.1f}" for s in steps)})')
        for i, im in enumerate(ims[1:-1], 1):
            if dist(im, ims[0]) > whole * 1.5 and dist(im, ims[-1]) > whole * 1.5:
                stalls.append(f'frame {n}: in-between {mids[i - 1]} is not between its frames ({dist(im, ims[0]):.1f} '
                              f'and {dist(im, ims[-1]):.1f} from them, they {whole:.1f} apart)')
    # one strip per image triple (its blocks marked), the worst first
    by_triple = defaultdict(list)
    for e in events:
        by_triple[(e[0], e[1], e[2])].append(e)
    report = []
    for n, (key, es) in enumerate(sorted(by_triple.items(), key=lambda kv: -max(e[5] + e[6] for e in kv[1]))[:30]):
        fa, fb, fc = key
        ims = [Image.open(f).convert('RGB').resize((640, 360)) for f in key]
        strip = Image.new('RGB', (1920, 360))
        for j, im in enumerate(ims):
            d = ImageDraw.Draw(im)
            for e in es:
                x0, y0 = e[3] * 40, e[4] * 40
                d.rectangle([x0, y0, x0 + 40, y0 + 40], outline=(255, 0, 255), width=3)
            strip.paste(im, (j * 640, 0))
        p = os.path.join(out, f'flicker_{n:02d}.png')
        strip.save(p)
        report.append(f'{os.path.basename(fb)} (between {os.path.basename(fa)} and {os.path.basename(fc)}): '
                      f'{len(es)} spot(s), strongest change {max(e[5] for e in es):.0f}/255 -> {p}')
    return report + [f'in-between stall / jump: {s}' for s in stalls[:30]]


def main():
    logs, frames, out = parse_args(sys.argv[1:])
    os.makedirs(out, exist_ok=True)
    md = ['# Test watcher report', '']
    total = 0
    for log in logs:
        found, causes, hstage, windows, skipped = scan_log(log)
        md += [f'## {log}', '']
        for kind in ('stop / crash', 'freeze', 'validation', 'shader / pipeline failure', 'trip not finished',
                     'in-between draws left out', 'interpolation held back'):
            items = found.get(kind)
            if items:
                total += len(items)
                uniq = list(dict.fromkeys(items))
                md.append(f'- **{kind}** ({len(items)}):')
                md += [f'  - {x}' for x in uniq[:12]]
        if causes:
            md.append('- **hitches by cause**: ' + ', '.join(f'{c} {n}' for c, n in causes.most_common()))
        for st, hs in hstage.items():
            worst = sorted(hs, reverse=True)[:3]
            md.append(f'  - {st}: {len(hs)} hitches, worst ' + ', '.join(f'{ms} ms at {fr} ({c})' for ms, fr, c in worst))
        drops = [(st, w) for st, w in windows.items() if w[1]]
        if drops:
            md.append('- **frame-rate drops** (2-s windows under 58 fps): ' +
                      ', '.join(f'{st} {w[1]}/{w[0]}' for st, w in drops))
            total += sum(w[1] for _, w in drops)
        sk = [(st, n) for st, n in skipped.items() if n]
        if sk:
            md.append('- **skipped draws**: ' + ', '.join(f'{st} {n}' for st, n in sk))
        md.append('')
    if frames:
        fl = flicker_scan(frames, out)
        md += ['## Flicker (images)', '']
        md += [f'- {x}' for x in fl] if fl else ['- none found']
        total += len(fl)
        md.append('')
    md.insert(1, f'Problems found: {total}')
    text = '\n'.join(md)
    open(os.path.join(out, 'report.md'), 'w', encoding='utf-8').write(text)
    print(text)


if __name__ == '__main__':
    main()
