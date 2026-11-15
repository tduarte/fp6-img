#!/usr/bin/env python3
"""Find the colour data in a CamX tuning blob (com.qti.tuned.*.bin).

CCMs (cc13 module): 9 little-endian float32 values, row-major 3x3, followed
by 3 float32 offsets (48 bytes per entry). Each row sums to ~1.0 (white
stays white) and the diagonal is positive. Entries are grouped by lux zone
(lowest lux index = brightest light first) and, inside a zone, by CCT
region; the zone's region triggers (start, end) sit right before its
matrices, 24 bytes per region. Rows of the dimmer zones may not sum to 1
exactly (desaturated); --tol widens the match.

AWB reference points: 10 (R, 1.0, B) gain triplets. On the FP6 blobs the
order is 9500, 7504, 6504, 5000 K, three fluorescent points, 2856, 2300,
1900 K (the labels the shipped imx896.yaml uses).

The tree is not 4-byte aligned, so every byte offset is tried.
Checked against com.qti.tuned.fp6_tsp_imx896.bin (sha256 0500766f...c1a5d29f):
finds the 12 CCMs and the reference table imx896.yaml was made from.

usage: tuned_colour.py <tuned.bin> [--tol 0.01]
"""
import struct
import sys
import numpy as np

path = sys.argv[1]
tol = float(sys.argv[sys.argv.index('--tol') + 1]) if '--tol' in sys.argv else 0.01
data = open(path, 'rb').read()
raw = np.frombuffer(data, dtype=np.uint8)

print('# CCM candidates: offset, 3x3 row-major')
hits = []
with np.errstate(invalid='ignore', over='ignore'):
    for align in range(4):
        n = (len(raw) - align) // 4
        f = raw[align:align + n * 4].view('<f4').astype(np.float64)
        w = np.lib.stride_tricks.sliding_window_view(f, 9)
        rows = w.reshape(-1, 3, 3)
        ok = np.all(np.isfinite(w), axis=1) & np.all(np.abs(w) < 4, axis=1)
        ok &= np.all(np.abs(rows.sum(axis=2) - 1) < tol, axis=1)
        diag = np.stack([rows[:, 0, 0], rows[:, 1, 1], rows[:, 2, 2]], 1)
        ok &= np.all((diag > 0.8) & (diag < 4), axis=1)
        ok &= np.abs(rows - np.eye(3)).max(axis=(1, 2)) > 0.02
        hits += [(align + 4 * int(i), w[i]) for i in np.nonzero(ok)[0]]
for off, m in sorted(hits, key=lambda h: h[0]):
    print('0x%07x  ' % off + '  '.join('% .6f' % v for v in m))

print('# AWB reference tables: offset, (R, B) gains')
one = struct.pack('<f', 1.0)
for o in range(len(data) - 120):
    if data[o + 4:o + 8] != one:
        continue
    if all(data[o + 4 + 12 * k:o + 8 + 12 * k] == one for k in range(10)):
        v = struct.unpack_from('<30f', data, o)
        r, b = v[0::3], v[2::3]
        if all(0.3 < x < 6 for x in r + b) and len({round(x, 4) for x in r + b}) > 6:
            print('0x%07x  ' % o + ' '.join('(%.6f, %.6f)' % p for p in zip(r, b)))
