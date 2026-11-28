#!/usr/bin/env sh
# Build the Uranus Android APK.
#
# Steps:
#   1. Build the native library (build/uranus.so) via build_android.sh
#   2. Compile the Java activity with javac
#   3. Compile to dex with d8
#   4. Compile resources with aapt2 compile
#   5. Link resources with aapt2 link (produces unsigned APK)
#   6. Add classes.dex and lib/uranus.so to the APK
#   7. Sign with apksigner
#
# Output: app_android/build/uranus.apk
set -e
cd "$(dirname "$0")"

NDK=third_party/android-ndk-r22b
SDK=third_party/android-sdk
BUILD_TOOLS=$SDK/build-tools/35.0.0
AAPT2=$BUILD_TOOLS/aapt2
D8_JAR=$BUILD_TOOLS/lib/d8.jar
APKSIGNER=$BUILD_TOOLS/apksigner

APP_DIR=app_android
OUT_DIR=$APP_DIR/build
RES_COMPILE=$OUT_DIR/intermediate/res-compile
CLASS_DIR=$OUT_DIR/intermediate/classes
DEX_DIR=$OUT_DIR/intermediate/dex
LIB_DIR=$OUT_DIR/intermediate/lib
APK_UNSIGNED=$OUT_DIR/uranus-unsigned.apk
APK_SIGNED=$OUT_DIR/uranus.apk
KEY=$OUT_DIR/uranus.keystore

ANDROID_JAR="$SDK/platforms/android-35/android.jar"

echo "=== Step 1: Build native library ==="
./build_android.sh
echo "Native library: build/uranus.so"

echo "=== Step 2: Compile Java ==="
rm -rf "$CLASS_DIR" "$DEX_DIR" "$LIB_DIR" "$RES_COMPILE" "$APK_UNSIGNED" "$APK_SIGNED"
mkdir -p "$CLASS_DIR" "$DEX_DIR" "$LIB_DIR" "$RES_COMPILE"
javac -d "$CLASS_DIR" -cp "$ANDROID_JAR" \
    "$APP_DIR/src/main/java/com/uranus/UranusActivity.java"
echo "Java compiled."

echo "=== Step 3: Compile to dex ==="
java -Xmx2G -cp "$D8_JAR" com.android.tools.r8.D8 \
    --output "$DEX_DIR" \
    "$CLASS_DIR/com/uranus/UranusActivity.class" 2>&1
echo "Dex compiled: $DEX_DIR/classes.dex"

echo "=== Step 4: Compile resources ==="
$AAPT2 compile \
    -o "$RES_COMPILE" \
    --dir "$APP_DIR/src/main/res" 2>&1
echo "Resources compiled."

echo "=== Step 5: Link resources ==="
$AAPT2 link \
    -o "$APK_UNSIGNED" \
    -I "$ANDROID_JAR" \
    --manifest "$APP_DIR/src/main/AndroidManifest.xml" \
    "$RES_COMPILE"/*.flat 2>&1
echo "Resources linked: $APK_UNSIGNED"

echo "=== Step 6: Add dex and lib to APK ==="
# Unpack the linked APK, add classes.dex and lib/, rezip
ABS_APK_UNSIGNED=$(pwd)/$APK_UNSIGNED
TMP_APK_DIR=$(mktemp -d)
unzip -q "$APK_UNSIGNED" -d "$TMP_APK_DIR"
cp "$DEX_DIR/classes.dex" "$TMP_APK_DIR/"
mkdir -p "$TMP_APK_DIR/lib/aarch64-linux-android"
cp build/uranus.so "$TMP_APK_DIR/lib/aarch64-linux-android/liburanus.so"
cd "$TMP_APK_DIR"
zip -q -r "$ABS_APK_UNSIGNED" .
cd - > /dev/null
rm -rf "$TMP_APK_DIR"

echo "APK assembled: $APK_UNSIGNED"

echo "=== Step 7: Sign ==="
if [ ! -f "$KEY" ]; then
    echo "Generating keystore..."
    keytool -genkeypair -alias uranus \
        -keyalg RSA -keysize 2048 \
        -validity 10000 \
        -keystore "$KEY" \
        -storepass android -keypass android \
        -dname "CN=Uranus,OU=Uranus,O=Uranus" 2>&1
fi

java -Xmx1G -jar "$BUILD_TOOLS/lib/apksigner.jar" sign \
    --ks "$KEY" \
    --ks-key-alias uranus \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$APK_SIGNED" \
    "$APK_UNSIGNED"

echo "=== Done ==="
echo "APK: $APK_SIGNED"
echo "Size: $(du -h "$APK_SIGNED" | cut -f1)"
