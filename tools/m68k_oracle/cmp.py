#!/usr/bin/env python3
"""Compares ref.txt (Musashi) with mine.txt (our core) case by case.

Known, deliberate differences are excluded:
  * odd word/long accesses (the 68000 takes an address error; our core does not),
  * line F opcodes (Musashi routes some through coprocessor stubs),
  * DIVU/DIVS overflow: the manual clears C, Musashi leaves it alone,
  * DIVS 0x80000000 / -1: hardware overflows, Musashi special-cases it,
  * NBCD: Musashi skips writing back an unchanged byte.
"""
import re, sys, collections

cases = open('cases.txt').read().split('\n')
ref = open('ref.txt').read().split('\n')
mine = open('mine.txt').read().split('\n')

def canon(line):
    m = re.match(r'(.*?) \|(.*?)\| (odd=.*)', line)
    head, wr, tail = m.group(1), m.group(2), m.group(3)
    mem = {}
    for w in wr.split():
        a, rest = w.split('/'); sz, val = rest.split('=')
        a, sz, val = int(a, 16), int(sz, 16), int(val, 16)
        for i in range(sz): mem[a + i] = (val >> (8 * (sz - 1 - i))) & 0xFF
    return head, tuple(sorted(mem.items())), tail.split(' cyc=')[0]

bad = collections.Counter(); ex = {}; total = skipped = 0
for i, (a, b) in enumerate(zip(ref, mine)):
    if not a: continue
    total += 1
    if 'odd=1' in a: skipped += 1; continue
    op = int(cases[i].split()[20], 16)
    if op >> 12 == 15: continue
    ca, cb = canon(a), canon(b)
    if op >> 12 == 8 and (op >> 6) & 7 in (3, 7):
        ca = (ca[0][:-1] + '0',) + ca[1:]; cb = (cb[0][:-1] + '0',) + cb[1:]
        if (op >> 6) & 7 == 7 and int(cases[i].split()[1 + ((op >> 9) & 7)], 16) == 0x80000000: continue
    if op & 0xFFC0 == 0x4800:
        ca = (ca[0], (), ca[2]); cb = (cb[0], (), cb[2])
    if ca != cb:
        bad[op >> 12] += 1
        ex.setdefault(op, (cases[i], a, b))
print("compared", total - skipped, "skipped(odd)", skipped, "mismatches", sum(bad.values()))
for op in sorted(ex)[:int(sys.argv[1]) if len(sys.argv) > 1 else 4]:
    c, a, b = ex[op]
    print("OP %04x" % op); print(" case:", c); print(" ref :", a); print(" mine:", b)
sys.exit(1 if bad else 0)
