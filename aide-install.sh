#!/bin/bash
# Installs one toolchain component from Preferences.
#   aide-install.sh platform <api>
#   aide-install.sh buildtools <version>
#   aide-install.sh ndk <version>
#   aide-install.sh cmake
#   aide-install.sh jdk <version>
#   aide-install.sh cmd <shell command>      (language servers etc.)
set -u
export DEBIAN_FRONTEND=noninteractive
. /root/.aide/env.sh 2>/dev/null
SDK=${ANDROID_HOME:-/root/android-sdk}
SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager"
KIND="${1:-}"; ARG="${2:-}"

C_HI=$'\e[38;5;180m'; C_OK=$'\e[38;5;108m'; C_ERR=$'\e[38;5;167m'; C_OFF=$'\e[0m'
say() { printf '%s\n' "${C_HI}==>${C_OFF} $*"; }
fail() { printf '%s\n' "${C_ERR}ERROR${C_OFF} $*"; exit 1; }

swap_native() {  # $1 = build-tools dir
  for t in aapt aapt2 zipalign; do
    if [ -x "/usr/bin/$t" ]; then
      [ -L "$1/$t" ] || mv -f "$1/$t" "$1/$t.x86" 2>/dev/null
      ln -sf "/usr/bin/$t" "$1/$t"
    fi
  done
}

case "$KIND" in
  platform)
    say "Installing platform android-$ARG"
    "$SDKM" --sdk_root="$SDK" "platforms;android-$ARG" || fail "platform install failed" ;;
  buildtools)
    say "Installing build-tools $ARG"
    "$SDKM" --sdk_root="$SDK" "build-tools;$ARG" || fail "build-tools install failed"
    swap_native "$SDK/build-tools/$ARG"
    say "Replaced x86 binaries with arm64 ones" ;;
  ndk)
    say "Installing NDK $ARG (large download)"
    apt-get install -y --no-install-recommends clang lld llvm cmake ninja-build || fail "native tools failed"
    "$SDKM" --sdk_root="$SDK" "ndk;$ARG" || fail "NDK install failed"
    LLVMV=$(ls /usr/bin/clang-[0-9]* 2>/dev/null | sed 's/.*clang-//' | sort -n | tail -1)
    for d in "$SDK/ndk/$ARG/toolchains/llvm/prebuilt/linux-x86_64/bin" "$SDK/ndk/$ARG/prebuilt/linux-x86_64/bin"; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
        [ "$(od -An -tx1 -j18 -N1 "$f" | tr -d ' ')" = "3e" ] || continue
        n=$(basename "$f"); tgt=""
        case "$n" in
          clang-[0-9]*) tgt="/usr/bin/clang-$LLVMV" ;;
          *) for c in "/usr/bin/$n-$LLVMV" "/usr/lib/llvm-$LLVMV/bin/$n" "/usr/bin/$n"; do [ -x "$c" ] && tgt="$c" && break; done ;;
        esac
        [ -n "$tgt" ] && { mv -f "$f" "$f.x86"; ln -s "$tgt" "$f"; }
      done
    done
    sed -i '/ANDROID_NDK_HOME/d' /root/.aide/env.sh
    sed -i "1i export ANDROID_NDK_HOME=$SDK/ndk/$ARG" /root/.aide/env.sh
    say "NDK ready (arm64 host tools)" ;;
  cmake)
    apt-get install -y --no-install-recommends cmake ninja-build || fail "cmake failed" ;;
  jdk)
    apt-get update && apt-get install -y --no-install-recommends "openjdk-$ARG-jdk-headless" || fail "JDK install failed" ;;
  cmd)
    bash -c "$ARG" || fail "install command failed" ;;
  *) fail "unknown kind '$KIND'" ;;
esac
echo
echo "${C_OK}Done.${C_OFF}"
