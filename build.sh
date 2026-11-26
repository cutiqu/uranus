#!/usr/bin/env sh
# One executable: the Saturn core and every frontend are compiled in.
# (Optional convenience: this is a single `odin build`.)
set -e
cd "$(dirname "$0")"
mkdir -p build
odin build app -vet -strict-style -o:speed -out:build/uranus
echo "built build/uranus   (needs libSDL2 at runtime)"
