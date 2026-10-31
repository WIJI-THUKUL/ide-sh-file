#!/bin/bash
# Gradle-free APK build for "Simple APK" projects.
#   usage: build-simple-apk.sh <project-dir> <debug|release|clean>
#
# Pipeline: aapt2 compile/link -> javac -> d8 -> zipalign -> apksigner
# Output:   <project>/build/outputs/apk/<variant>/app-<variant>.apk
set -u

PROJ="${1:-}"; MODE="${2:-debug}"
[ -n "$PROJ" ] && [ -d "$PROJ" ] || { echo "error: project directory not found: '$PROJ'"; exit 2; }
cd "$PROJ" || exit 2

if [ "$MODE" = "clean" ]; then rm -rf build; echo "Cleaned."; exit 0; fi

[ -f /root/.aide/env.sh ] && . /root/.aide/env.sh

fail() { echo "error: $*"; echo "BUILD FAILED"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is not installed. Run the toolchain setup again (Preferences)."; }
step() { echo "> $1"; }
run()  { "$@" || fail "command failed: $1"; }

for t in aapt2 javac d8 zip zipalign apksigner; do need "$t"; done

ANDROID_HOME="${ANDROID_HOME:-/root/android-sdk}"
PLATFORM=$(ls "$ANDROID_HOME/platforms" 2>/dev/null | sed 's/^android-//' | grep -E '^[0-9]+$' | sort -n | tail -1)
[ -n "$PLATFORM" ] || fail "no SDK platform installed (Preferences → SDK platforms)"
AJAR="$ANDROID_HOME/platforms/android-$PLATFORM/android.jar"
[ -f "$AJAR" ] || fail "android.jar not found for API $PLATFORM"

MINSDK=26
if [ -f .aide/project.json ]; then
  V=$(grep -o '"minSdk": *[0-9]*' .aide/project.json | grep -o '[0-9]*$' | head -1)
  [ -n "$V" ] && MINSDK="$V"
fi
[ -f AndroidManifest.xml ] || fail "AndroidManifest.xml not found in $PROJ"

B=build
OUT=$B/outputs/apk/$MODE
rm -rf $B/res.zip $B/gen $B/classes $B/dex $B/base.apk $B/aligned.apk
mkdir -p $B/gen $B/classes $B/dex "$OUT"
T0=$(date +%s)
echo "Platform android-$PLATFORM, minSdk $MINSDK, $(javac -version 2>&1)"

LINK_RES=()
if [ -d res ]; then
  step "Compiling resources (aapt2)"
  run aapt2 compile --dir res -o $B/res.zip
  LINK_RES=(-R $B/res.zip)
fi

step "Linking resources"
run aapt2 link -o $B/base.apk -I "$AJAR" --manifest AndroidManifest.xml \
  --java $B/gen --min-sdk-version "$MINSDK" --target-sdk-version "$PLATFORM" \
  --version-code 1 --version-name 1.0 --auto-add-overlay "${LINK_RES[@]}"

step "Compiling Java (javac)"
CP="$AJAR"
JARS=()
for j in libs/*.jar; do
  if [ -f "$j" ]; then CP="$CP:$j"; JARS+=("$j"); fi
done
find src $B/gen -name '*.java' 2>/dev/null > $B/sources.txt
[ -s $B/sources.txt ] || fail "no .java files found under src/"
run javac -source 11 -target 11 -encoding UTF-8 -Xlint:-options -cp "$CP" -d $B/classes @$B/sources.txt

step "Dexing (d8)"
find $B/classes -name '*.class' > $B/classes.txt
run d8 --lib "$AJAR" --min-api "$MINSDK" --output $B/dex @$B/classes.txt "${JARS[@]}"
[ -f $B/dex/classes.dex ] || fail "d8 produced no classes.dex"

step "Packaging"
(cd $B/dex && zip -q -j ../base.apk classes*.dex) || fail "zip failed"

step "Aligning (zipalign)"
run zipalign -f -p 4 $B/base.apk $B/aligned.apk

step "Signing (apksigner)"
KS=/root/.android/debug.keystore; SP=android; KA=androiddebugkey; KP=android
if [ "$MODE" = "release" ] && [ -f /root/.android/aide-signing.properties ]; then
  P=/root/.android/aide-signing.properties
  KS=$(grep '^storeFile=' $P | cut -d= -f2-);      SP=$(grep '^storePassword=' $P | cut -d= -f2-)
  KA=$(grep '^keyAlias=' $P | cut -d= -f2-);       KP=$(grep '^keyPassword=' $P | cut -d= -f2-)
fi
[ -f "$KS" ] || fail "keystore not found: $KS (run the toolchain setup again)"
run apksigner sign --ks "$KS" --ks-pass "pass:$SP" --ks-key-alias "$KA" --key-pass "pass:$KP" \
  --out "$OUT/app-$MODE.apk" $B/aligned.apk
rm -f "$OUT/app-$MODE.apk.idsig"

echo
echo "BUILD SUCCESSFUL in $(( $(date +%s) - T0 ))s"
echo "APK: $PROJ/$OUT/app-$MODE.apk"
