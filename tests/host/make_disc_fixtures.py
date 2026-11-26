#!/usr/bin/env python3
"""Builds the disc fixtures used by tests/host/disc_test.odin.

The disc: track 1 is 16 MODE1/2352 sectors (valid sync, header, EDC and ECC, so
chdman strips them and the reader must put them back); track 2 is AUDIO with a
16-sector pregap stored in the file (INDEX 00) followed by 24 sectors of data.
Contents are formulae, so tests can recompute any sector:

  data sector n  : user byte i = (n * 31 + i * 7) & 0xFF   (sector 0 = IP.BIN-like header)
  audio sector m : byte i      = (m * 5 + i) & 0xFF          (the pregap is zeros)

  make_disc_fixtures.py OUTDIR      writes disc.cue/track0N.bin and disc_{cdlz,cdzl,none,default}.chd
"""
import os, struct, subprocess, sys

DATA_SECTORS, PREGAP, AUDIO_SECTORS = 16, 16, 6

# ---- ECMA-130 mode 1 EDC/ECC ----
edc_t = []
for i in range(256):
    j = i
    for _ in range(8):
        j = (j >> 1) ^ (0xD8018001 if j & 1 else 0)
    edc_t.append(j)
ecc_f, ecc_b = [0] * 256, [0] * 256
for i in range(256):
    j = ((i << 1) ^ (0x11D if i & 0x80 else 0)) & 0xFF
    ecc_f[i] = j
    ecc_b[i ^ j] = i

def edc(data):
    c = 0
    for b in data:
        c = (c >> 8) ^ edc_t[(c ^ b) & 0xFF]
    return c

def ecc_block(src, major_count, minor_count, major_mult, minor_inc, dest, doff):
    size = major_count * minor_count
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minor_count):
            t = src[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= t
            b ^= t
            a = ecc_f[a]
        a = ecc_b[ecc_f[a] ^ b]
        dest[doff + major] = a
        dest[doff + major + major_count] = a ^ b

def msf(lba):
    f = lba + 150
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    return bytes([bcd(f // 4500), bcd(f // 75 % 60), bcd(f % 75)])

# ecc_block indexes from the start of the *address field* (offset 12), so
# rebuild with a view that starts there.
def data_sector(n):
    user = bytes(((n * 31 + i * 7) & 0xFF) for i in range(2048))
    if n == 0:
        user = b"SEGA SEGASATURN " + b"TEST DISC".ljust(0x70, b" ") + user[0x80:]
    s = bytearray(b"\x00" + b"\xFF" * 10 + b"\x00" + msf(n) + b"\x01" + user + bytes(288))
    struct.pack_into("<I", s, 0x810, edc(s[:0x810]))
    view = s[12:]
    ecc_block(view, 86, 24, 2, 86, view, 0x81C - 12)
    ecc_block(view, 52, 43, 86, 88, view, 0x8C8 - 12)
    s[12:] = view
    return bytes(s)

def audio_sector(m):
    return bytes(((m * 5 + i) & 0xFF) for i in range(2352))

def main(out):
    os.makedirs(out, exist_ok=True)
    t1 = b"".join(data_sector(n) for n in range(DATA_SECTORS))
    t2 = bytes(PREGAP * 2352) + b"".join(audio_sector(m) for m in range(AUDIO_SECTORS))
    open(f"{out}/track01.bin", "wb").write(t1)
    open(f"{out}/track02.bin", "wb").write(t2)
    open(f"{out}/disc.cue", "w", newline="\r\n").write(
        'FILE "track01.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'
        'FILE "track02.bin" BINARY\n  TRACK 02 AUDIO\n    INDEX 00 00:00:00\n'
        f'    INDEX 01 {PREGAP // 4500:02d}:{PREGAP // 75 % 60:02d}:{PREGAP % 75:02d}\n')
    for name, codecs in (("cdlz", "cdlz"), ("cdzl", "cdzl"), ("none", "none"), ("default", None)):
        path = f"{out}/disc_{name}.chd"
        if os.path.exists(path):
            os.remove(path)
        cmd = ["chdman", "createcd", "-i", f"{out}/disc.cue", "-o", path]
        if codecs:
            cmd += ["-c", codecs]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)

if __name__ == "__main__":
    main(sys.argv[1])
