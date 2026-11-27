# 68000 differential test

`core/m68k.odin` (the Saturn's sound CPU) is checked against
[Musashi](https://github.com/kstenerud/Musashi) (MIT licence), the standard 68000
reference, one random instruction at a time.

    git clone https://github.com/kstenerud/Musashi /tmp/Musashi
    MUSASHI=/tmp/Musashi tools/m68k_oracle/run.sh 200000 1       # 200k cases, seed 1
    MUSASHI=/tmp/Musashi tools/m68k_oracle/run.sh 200000 7 4     # only opcodes 0x4xxx

Each case is a random register file, status register and five random opcode/extension
words at PC=0x1000, over a 16 MiB memory whose contents are a hash of the address
(identical in both harnesses). The comparison covers every register, the stack pointers,
the PC, SR and the bytes written. Cycle counts are not compared (ours is a bus-cycle
estimate). Known deliberate differences are listed at the top of `cmp.py`.

Last result: 2.8 million cases (200k per opcode group 0-9, B-E) plus several 300k runs
with other seeds: no mismatches beyond the listed differences.

Not covered by this test: interrupt acknowledge, STOP, and multi-instruction sequences;
those are in `tests/saturn/m68k_test.odin` and `scsp_test.odin`.
