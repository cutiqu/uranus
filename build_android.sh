#!/usr/bin/env sh
# Build the Android (aarch64) shared library for Uranus.
# Produces build/uranus.so, which can be loaded as a NativeActivity by an
# Android APK. The headless and TUI frontends are included; the SDL frontend
# is excluded (it requires an Android build of SDL2, which is not available).
#
# Requires:
#   - NDK r22b at third_party/android-ndk-r22b
#   - odin compiler on PATH
set -e
cd "$(dirname "$0")"

NDK=third_party/android-ndk-r22b
if [ ! -d "$NDK" ]; then
    echo "NDK not found at $NDK. Download and extract it here:"
    echo "  https://dl.google.com/android/repository/android-ndk-r22b-linux-x86_64.zip"
    exit 1
fi

export ODIN_ANDROID_NDK="$NDK"
LLVM_DIR="$NDK/toolchains/llvm/prebuilt/linux-x86_64"

mkdir -p build
odin build app \
    -vet -strict-style -o:speed \
    -target:linux_arm64 -subtarget:android \
    -build-mode:shared -minimum-os-version:29 \
    -out:build/uranus.so \
    -extra-linker-flags:"-fuse-ld=lld -L$LLVM_DIR/lib/gcc/aarch64-linux-android/4.9.x -lgcc"

echo "built build/uranus.so"
