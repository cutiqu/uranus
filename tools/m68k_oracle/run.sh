#!/bin/bash
# Differential test of core/m68k.odin against Musashi (MIT licence).
#
#   MUSASHI=/path/to/Musashi tools/m68k_oracle/run.sh [cases] [seed] [opcode-top-nibble]
#
# Musashi is only a test oracle; nothing from it is built into the emulator.
# Needs: gcc, python3, odin.
set -e
: "${MUSASHI:?set MUSASHI to a Musashi checkout (https://github.com/kstenerud/Musashi)}"
N=${1:-200000}; SEED=${2:-1}; NIB=$3
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
W=${WORKDIR:-/tmp/m68k_oracle}; mkdir -p "$W"; cd "$W"
if [ ! -x oracle ]; then
  cp -r "$MUSASHI" musashi
  (cd musashi && gcc -o m68kmake m68kmake.c && ./m68kmake >/dev/null)
  gcc -O2 -w -Imusashi -o oracle "$HERE/oracle.c" musashi/m68kcpu.c musashi/m68kops.c \
      musashi/m68kdasm.c musashi/softfloat/softfloat.c -lm
fi
(cd "$ROOT" && odin build tools/m68k_oracle/harness -o:speed -out:"$W/harness")
python3 "$HERE/gen.py" "$N" "$SEED" $NIB > cases.txt
./oracle < cases.txt > ref.txt
./harness < cases.txt > mine.txt
python3 "$HERE/cmp.py"
