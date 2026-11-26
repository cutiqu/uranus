#!/usr/bin/env python3
"""Checks the frame the synthetic BIOS produces: 320x224, alternating 8-pixel
stripes, the second stripe pure green (palette entry 2), and the first stripe
no longer the initial red (it is rewritten by the VBlank-IN interrupt handler)."""
import sys
d = open(sys.argv[1], "rb").read()
_, size, _, px = d.split(b"\n", 3)
w, h = map(int, size.split())
at = lambda x, y: tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3])
ok = (w, h) == (320, 224) and at(10, 2) == (0, 255, 0) and at(300, 200) == (0, 255, 0) \
     and at(2, 2) != (255, 0, 0) and at(2, 2) != (0, 0, 0)
if not ok:
    print(f"unexpected frame: {w}x{h} A={at(2, 2)} B={at(10, 2)}")
sys.exit(0 if ok else 1)
