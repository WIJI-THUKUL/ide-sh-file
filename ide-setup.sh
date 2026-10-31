#!/bin/bash
# AideStudio toolchain setup — runs inside the Ubuntu (proot) container.
#
# Order:
#   A. update Ubuntu packages and install the base tools
#   B. download the chosen toolchain (SDK, build-tools, NDK)
#   C. signing keys, Gradle defaults, environment file
#
# Every step writes a marker to /root/.aide/state, so the script can be re-run
# after an interruption and only repeats what is unfinished.

set -u
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

AIDE=/root/.aide
CONF=$AIDE/toolchain.conf
STATE=$AIDE/state
LOG=$AIDE/setup.log
SDK=/root/android-sdk
mkdir -p "$STATE" /root/.android /root/.gradle/init.d

if [ ! -f "$CONF" ]; then echo "Missing $CONF"; exit 2; fi
# shellcheck disable=SC1090
. "$CONF"

C_OK=$'\e[38;5;108m'; C_WARN=$'\e[38;5;179m'; C_ERR=$'\e[38;5;167m'; C_DIM=$'\e[38;5;245m'; C_HI=$'\e[38;5;180m'; C_OFF=$'\e[0m'
say()  { printf '%s\n' "${C_HI}==>${C_OFF} $*"; }
ok()   { printf '%s\n' "${C_OK} ok${C_OFF} $*"; }
warn() { printf '%s\n' "${C_WARN} !!${C_OFF} $*"; }
die()  { printf '%s\n' "${C_ERR}ERROR${C_OFF} $*"; exit 1; }
done_() { [ -f "$STATE/$1.done" ]; }
mark()  { date +%s > "$STATE/$1.done"; }
retry() { local n=0; until "$@"; do n=$((n+1)); [ $n -ge 3 ] && return 1; warn "retrying ($n/3): $*"; sleep 3; done; }

ARCH=$(dpkg --print-architecture)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)
CORES=$(nproc 2>/dev/null || echo 4)

echo
echo "${C_HI}AideStudio setup${C_OFF}  ${C_DIM}(arch: $ARCH, RAM: ${MEM_MB} MB, cores: $CORES)${C_OFF}"
echo "${C_DIM}JDK $JDK | platforms: $PLATFORMS | build-tools $BUILD_TOOLS | NDK: ${NDK:-skip}${C_OFF}"
echo

###############################################################################
# A. Ubuntu packages
###############################################################################
if ! done_ apt-update; then
  say "A1/3  Updating package lists"
  retry apt-get update || die "apt-get update failed (check your internet connection)"
  mark apt-update
fi

if ! done_ apt-upgrade; then
  say "A2/3  Upgrading installed packages"
  retry apt-get -y -o Dpkg::Options::=--force-confold upgrade || warn "upgrade reported problems, continuing"
  mark apt-upgrade
fi

if ! done_ apt-base; then
  say "A3/3  Installing base tools (JDK $JDK, git, zip, aapt, zipalign, apksigner …)"
  PKGS="ca-certificates curl wget unzip zip xz-utils git nano less procps file openssl \
        openjdk-${JDK}-jdk-headless aapt zipalign apksigner make"
  retry apt-get install -y --no-install-recommends $PKGS || die "Base package installation failed"
  mark apt-base
fi

JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")
export JAVA_HOME
ok "Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

###############################################################################
# B. Toolchain
###############################################################################
if ! done_ cmdline-tools; then
  say "B1  Android command-line tools"
  rm -rf "$SDK/cmdline-tools"; mkdir -p "$SDK/cmdline-tools"
  CT_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip}"
  retry curl -fL --progress-bar -o /tmp/cmdline-tools.zip "$CT_URL" || die "Cannot download command-line tools"
  unzip -q -o /tmp/cmdline-tools.zip -d "$SDK/cmdline-tools" || die "Cannot unzip command-line tools"
  mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -f /tmp/cmdline-tools.zip
  mark cmdline-tools
fi
SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager"

if ! done_ licenses; then
  say "B2  Accepting SDK licenses"
  yes 2>/dev/null | "$SDKM" --sdk_root="$SDK" --licenses >/dev/null 2>&1
  mark licenses
fi

for P in $PLATFORMS; do
  if ! done_ "platform-$P"; then
    say "B3  Android platform $P"
    retry "$SDKM" --sdk_root="$SDK" "platforms;android-$P" || die "Cannot install platform $P"
    mark "platform-$P"
  fi
done

if ! done_ "build-tools-$BUILD_TOOLS"; then
  say "B4  Build-tools $BUILD_TOOLS"
  retry "$SDKM" --sdk_root="$SDK" "build-tools;$BUILD_TOOLS" || die "Cannot install build-tools $BUILD_TOOLS"
  mark "build-tools-$BUILD_TOOLS"
fi

# Google ships x86-64 binaries only. Swap the native tools for the arm64 builds from Ubuntu.
BT="$SDK/build-tools/$BUILD_TOOLS"
if ! done_ "bt-native-$BUILD_TOOLS"; then
  say "B5  Replacing x86 build-tools binaries with arm64 ones"
  for t in aapt aapt2 zipalign; do
    if [ -x "/usr/bin/$t" ]; then
      mv -f "$BT/$t" "$BT/$t.x86" 2>/dev/null
      ln -sf "/usr/bin/$t" "$BT/$t"
      ok "$t -> /usr/bin/$t"
    else
      warn "/usr/bin/$t not available. Set AAPT2_ARM64 in $CONF to a native aarch64 build."
    fi
  done
  if [ -n "${AAPT2_ARM64:-}" ] && [ -x "$AAPT2_ARM64" ]; then
    ln -sf "$AAPT2_ARM64" "$BT/aapt2"
  fi
  mark "bt-native-$BUILD_TOOLS"
fi
"$BT/aapt2" version 2>&1 | head -1 || warn "aapt2 does not run"

if [ -n "${NDK:-}" ] && ! done_ "ndk-$NDK"; then
  say "B6  NDK $NDK (large download)"
  retry "$SDKM" --sdk_root="$SDK" "ndk;$NDK" || die "Cannot install NDK $NDK"
  mark "ndk-$NDK"
fi

if [ "${CMAKE:-0}" = "1" ] && ! done_ native-tools; then
  say "B7  clang, lld, cmake, ninja (arm64)"
  retry apt-get install -y --no-install-recommends clang lld llvm cmake ninja-build || die "Native tool installation failed"
  mark native-tools
fi

# Re-host the (x86) NDK on arm64: replace host binaries by Ubuntu's LLVM.
if [ -n "${NDK:-}" ] && ! done_ "ndk-rehost-$NDK"; then
  say "B8  Re-hosting NDK $NDK for arm64 (experimental)"
  NDKDIR="$SDK/ndk/$NDK"
  LLVMV=$(ls /usr/bin/clang-[0-9]* 2>/dev/null | sed 's/.*clang-//' | sort -n | tail -1)
  rehost_dir() {
    local d="$1"
    [ -d "$d" ] || return 0
    for f in "$d"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      # ELF with e_machine == 0x3E (x86-64)?
      [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
      [ "$(od -An -tx1 -j18 -N1 "$f" | tr -d ' ')" = "3e" ] || continue
      n=$(basename "$f")
      tgt=""
      case "$n" in
        clang-[0-9]*) tgt="/usr/bin/clang-$LLVMV" ;;
        *) for c in "/usr/bin/$n-$LLVMV" "/usr/lib/llvm-$LLVMV/bin/$n" "/usr/bin/$n"; do [ -x "$c" ] && tgt="$c" && break; done ;;
      esac
      if [ -n "$tgt" ]; then mv -f "$f" "$f.x86"; ln -s "$tgt" "$f"; else warn "no arm64 replacement for $n"; fi
    done
  }
  rehost_dir "$NDKDIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
  rehost_dir "$NDKDIR/prebuilt/linux-x86_64/bin"
  mark "ndk-rehost-$NDK"
fi

###############################################################################
# C. Signing keys, Gradle defaults, environment
###############################################################################
if ! done_ keystores; then
  say "C1  Creating signing keys"
  KT="$JAVA_HOME/bin/keytool"
  if [ ! -f /root/.android/debug.keystore ]; then
    "$KT" -genkeypair -keystore /root/.android/debug.keystore -storepass android -keypass android \
      -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1 && ok "debug.keystore"
  fi
  if [ ! -f /root/.android/aide-release.jks ]; then
    PASS=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    "$KT" -genkeypair -keystore /root/.android/aide-release.jks -storepass "$PASS" -keypass "$PASS" \
      -alias aide -keyalg RSA -keysize 2048 -validity 36500 \
      -dname "CN=AideStudio,O=AideStudio,C=ID" >/dev/null 2>&1 \
      && printf 'storeFile=/root/.android/aide-release.jks\nstorePassword=%s\nkeyAlias=aide\nkeyPassword=%s\n' "$PASS" "$PASS" \
         > /root/.android/aide-signing.properties \
      && chmod 600 /root/.android/aide-signing.properties \
      && ok "aide-release.jks (back it up from Preferences → Signing)"
  fi
  mark keystores
fi

# Gradle defaults tuned to this device
if ! done_ gradle-defaults; then
  say "C2  Gradle defaults"
  XMX=$(( MEM_MB / 3 )); [ $XMX -gt 3072 ] && XMX=3072; [ $XMX -lt 1024 ] && XMX=1024
  cat > /root/.gradle/gradle.properties <<EOF
org.gradle.jvmargs=-Xmx${XMX}m -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.workers.max=$CORES
org.gradle.vfs.watch=false
org.gradle.configuration-cache=true
org.gradle.configuration-cache.problems=warn
kotlin.compiler.execution.strategy=in-process
kotlin.incremental=true
android.aapt2FromMavenOverride=$BT/aapt2
EOF
  mark gradle-defaults
fi
# always refresh the signing init script (it ships with the app)
cp "$AIDE/aide-signing.gradle" /root/.gradle/init.d/aide-signing.gradle 2>/dev/null

# Environment used by every shell and build
cat > "$AIDE/env.sh" <<EOF
export JAVA_HOME=$JAVA_HOME
export ANDROID_HOME=$SDK
export ANDROID_SDK_ROOT=$SDK
export GRADLE_USER_HOME=/root/.gradle
export AIDE_BUILD_TOOLS=$BUILD_TOOLS
export AIDE_PLATFORMS="$PLATFORMS"
$( [ -n "${NDK:-}" ] && echo "export ANDROID_NDK_HOME=$SDK/ndk/$NDK" )
export PATH=\$JAVA_HOME/bin:$SDK/cmdline-tools/latest/bin:$BT:\$PATH
EOF

date +%s > "$AIDE/setup.done"
echo
echo "${C_OK}Setup finished.${C_OFF}  Toolchain is ready."
exit 0
