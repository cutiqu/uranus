#!/usr/bin/env python3
"""Builds a synthetic 512 KiB 'BIOS' that draws a striped NBG0 screen and
changes a palette entry from a VBlank-IN interrupt handler. Not a real BIOS:
it exists only so the Saturn core can be smoke-tested without Sega's ROM.

  python3 make_synth_bios.py out.bin
"""
import struct, sys

code, labels, fixups, pool = bytearray(), {}, [], []
BASE = 0x200

def here(): return BASE + len(code)
def emit(op): code.extend(struct.pack(">H", op))
def label(n): labels[n] = here()
def lit(value):                       # returns pool label name
    for n, v in pool:
        if v == value: return n
    n = f"_lit{len(pool)}"; pool.append((n, value)); return n

def mov_imm(r, v): emit(0xE000 | r << 8 | v & 0xFF)
def mov_l_lit(r, value): fixups.append(("pc", here(), lit(value), r)); emit(0)
def mov_l_st(m, n): emit(0x2002 | n << 8 | m << 4)       # mov.l Rm,@Rn
def mov_w_st(m, n): emit(0x2001 | n << 8 | m << 4)       # mov.w Rm,@Rn
def mov_l_ld(m, n): emit(0x6002 | n << 8 | m << 4)       # mov.l @Rm,Rn
def add_imm(r, v): emit(0x7000 | r << 8 | v & 0xFF)
def dt(r): emit(0x4010 | r << 8)
def bf(lbl): fixups.append(("bf", here(), lbl, 0)); emit(0)
def bra(lbl): fixups.append(("bra", here(), lbl, 0)); emit(0); emit(0x0009)
def ldc_sr(r): emit(0x400E | r << 8)
def ldc_vbr(r): emit(0x402E | r << 8)
def shll8(r): emit(0x4018 | r << 8)
def nop(): emit(0x0009)
def rte(): emit(0x002B); nop()

# ---- main --------------------------------------------------------------
CRAM, REGS, VRAM = 0x25F00000, 0x25F80000, 0x25E00000
mov_l_lit(5, CRAM + 2); mov_l_lit(1, 0x001F); mov_w_st(1, 5)        # CRAM[1] = red
mov_l_lit(5, CRAM + 4); mov_l_lit(1, 0x03E0); mov_w_st(1, 5)        # CRAM[2] = green
# tiles: char 0x200 = solid colour 1, char 0x201 = solid colour 2 (4 bpp, 8x8)
mov_l_lit(6, VRAM + 0x4000); mov_l_lit(7, VRAM + 0x4020)
mov_l_lit(1, 0x11111111); mov_l_lit(2, 0x22222222); mov_imm(3, 8)
label("tiles"); mov_l_st(1, 6); add_imm(6, 4); mov_l_st(2, 7); add_imm(7, 4); dt(3); bf("tiles")
# pattern name table: 2048 longs of (0x0200, 0x0201) -> alternating columns
mov_l_lit(8, VRAM); mov_l_lit(1, 0x02000201); mov_l_lit(3, 2048)
label("pn"); mov_l_st(1, 8); add_imm(8, 4); dt(3); bf("pn")
# VDP2 registers
mov_l_lit(0, 0x8000)
mov_l_lit(1, REGS + 0x30); mov_w_st(0, 1)                            # PNCN0: one-word pattern names
mov_imm(0, 1)
mov_l_lit(1, REGS + 0x20); mov_w_st(0, 1)                            # BGON: NBG0 on
mov_l_lit(1, REGS + 0xF8); mov_w_st(0, 1)                            # PRINA: NBG0 priority 1
# interrupt setup
mov_l_lit(0, 0x06001000); ldc_vbr(0)
mov_l_lit(0, 0x400); mov_l_lit(1, 0x06001100); mov_l_st(0, 1)       # vector 0x40 -> isr
mov_l_lit(1, 0x25FE00A0); mov_l_lit(0, 0xBFFE); mov_l_st(0, 1)      # SCU IMS: VBlank-IN unmasked
mov_imm(0, 0); ldc_sr(0)                                             # SR.I = 0
mov_l_lit(0, 0x8000); mov_l_lit(1, REGS); mov_w_st(0, 1)            # TVMD: display on
label("idle"); bra("idle")

# ---- VBlank-IN handler at 0x400 -----------------------------------------
code.extend(b"\0" * (0x400 - here()))
mov_l_lit(1, 0x06000000); mov_l_ld(1, 0); add_imm(0, 1); mov_l_st(0, 1)   # counter++
shll8(0); mov_l_lit(2, CRAM + 2); mov_w_st(0, 2)                          # CRAM[1] = counter << 8
mov_l_lit(3, 0x25FE00A0); mov_l_lit(4, 0xBFFE); mov_l_st(4, 3)           # SCU re-masks on ack; unmask again
rte()

# ---- literal pool + fixups ----------------------------------------------
while len(code) % 4: code.append(0)
for n, v in pool:
    labels[n] = here(); code.extend(struct.pack(">I", v))
for kind, at, lbl, r in fixups:
    off = at - BASE
    if kind == "pc":
        disp = (labels[lbl] - ((at + 4) & ~3)) // 4
        assert 0 <= disp < 256, (lbl, disp)
        code[off:off + 2] = struct.pack(">H", 0xD000 | r << 8 | disp)
    elif kind == "bf":
        disp = (labels[lbl] - (at + 4)) // 2
        code[off:off + 2] = struct.pack(">H", 0x8B00 | disp & 0xFF)
    elif kind == "bra":
        disp = (labels[lbl] - (at + 4)) // 2
        code[off:off + 2] = struct.pack(">H", 0xA000 | disp & 0xFFF)

rom = bytearray(0x80000)
rom[0:8] = struct.pack(">II", BASE, 0x060FFFF0)
rom[BASE:BASE + len(code)] = code
open(sys.argv[1], "wb").write(rom)
print(f"wrote {sys.argv[1]}: {len(code)} bytes of code")
