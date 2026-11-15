#!/usr/bin/env python3
"""Quick-look converter: MIPI CSI-2 packed RAW10 Bayer -> half-size RGB JPEG.
usage: raw2jpg.py in.raw width height pattern(GRBG|RGGB|BGGR|GBRG) out.jpg [blacklevel]"""
import sys, numpy as np
from PIL import Image
f, w, h, pat, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
bl = int(sys.argv[6]) if len(sys.argv) > 6 else 64
stride = int(sys.argv[7]) if len(sys.argv) > 7 else w * 5 // 4
raw = np.fromfile(f, dtype=np.uint8); h = min(h, len(raw) // stride); d = raw[:stride * h].reshape(h, stride)[:, :w * 5 // 4]
p = d.reshape(h, w // 4, 5).astype(np.uint16)
px = np.empty((h, w), np.uint16)
for i in range(4):
    px[:, i::4] = (p[:, :, i] << 2) | ((p[:, :, 4] >> (2 * i)) & 3)
q = {'GRBG': ((0, 1), (0, 0), (1, 1), (1, 0)), 'RGGB': ((0, 0), (0, 1), (1, 0), (1, 1)),
     'BGGR': ((1, 1), (0, 1), (1, 0), (0, 0)), 'GBRG': ((1, 0), (0, 0), (1, 1), (0, 1))}[pat]
r = px[q[0][0]::2, q[0][1]::2].astype(np.float32); g1 = px[q[1][0]::2, q[1][1]::2].astype(np.float32)
g2 = px[q[2][0]::2, q[2][1]::2].astype(np.float32); b = px[q[3][0]::2, q[3][1]::2].astype(np.float32)
n = min(r.shape[0], g2.shape[0], b.shape[0]); r, g1, g2, b = r[:n], g1[:n], g2[:n], b[:n]
g = (g1 + g2) / 2
rgb = np.stack([r, g, b], -1) - bl
rgb = np.clip(rgb, 0, None)
m = rgb.reshape(-1, 3).mean(0); print('raw min/max', px.min(), px.max(), 'channel means', m)
rgb *= (m[1] / np.maximum(m, 1e-3))           # grey-world
rgb /= max(np.percentile(rgb, 99.5), 1)
img = (np.clip(rgb, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
im = Image.fromarray(img); im.thumbnail((1280, 1280)); im.save(out, quality=88)
