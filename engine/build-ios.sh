#!/bin/bash
# build-ios.sh -- the engine for iPhone and iPad (the `iphoneos` SDK, arm64).
#
#   engine/build-ios.sh            everything: metallib + static lib + bundle
#   engine/build-ios.sh metallib   just the kernels
#   engine/build-ios.sh lib        the static library + the metallib
#   engine/build-ios.sh bundle     the metallib, then the resources into SpektraProbe
#
# A separate script rather than a mode of `build.sh`, so the macOS build is not
# touched by any of this: same sources, same math flags, different SDK and a
# different output folder (`build/ios/`, under the already-ignored `build/`).
#
# The macOS metallib lives at `resources/spektrafilm.metallib` and is what
# `build.sh bundle` ships. This script never writes there: the iOS metallib
# stays in `build/ios/` and is copied into the probe's bundle on its own, so
# running both scripts in either order leaves each app with its own kernels.
#
# The two math flags are load-bearing for exactly the reason `build.sh` gives
# (RFC-014 §5.1 trap 1): Metal defaults to fast math, and `spk_engine_create`
# refuses to start an engine whose kernels were built with it.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$here/build/ios"
mkdir -p "$out"

IOS_MIN=18.0
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
CXX=(xcrun -sdk iphoneos clang++)
target_cxx=(-target "arm64-apple-ios$IOS_MIN" -isysroot "$sdk")
cxxflags=(-std=c++20 -O2 -Wall -Wextra)
includes=(-I"$here/include" -I"$here/src" -I"$here/src/core" -I"$here/third_party/metal-cpp")
math_flags=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)
target_metal=(-mios-version-min="$IOS_MIN")

# Without a floor the metal compiler stamps the *SDK's* iOS version, and a
# metallib stamped for a newer iOS than the device's does not load.
check_metallib_target() {
  local headers platform major
  headers=$(xcrun -sdk iphoneos metal-readobj --file-headers "$1")
  platform=$(awk '/Platform:/ && !/PlatformM/ {print $2; exit}' <<<"$headers")
  major=$(awk '/PlatformMajor:/ {print $2; exit}' <<<"$headers")
  # `metal-readobj` names it `METALLIB_PLATFORM_IOS` (macOS: `..._MACOS`).
  if [[ "$platform" != "METALLIB_PLATFORM_IOS" || "$major" != "${IOS_MIN%%.*}" ]]; then
    echo "build-ios.sh: $1 targets $platform $major, not iOS $IOS_MIN" >&2
    exit 1
  fi
}

build_metallib() {
  local airs=() m air
  shopt -s nullglob
  for m in "$here"/src/shaders/*.metal; do
    air="$out/$(basename "$m" .metal).air"
    xcrun -sdk iphoneos metal "${math_flags[@]}" "${target_metal[@]}" -Werror -c "$m" -o "$air"
    airs+=("$air")
  done
  shopt -u nullglob
  xcrun -sdk iphoneos metallib "${airs[@]}" -o "$out/spektrafilm.metallib"
  check_metallib_target "$out/spektrafilm.metallib"
  echo "metallib   -> $out/spektrafilm.metallib"
}

# The same translation units `build.sh` compiles. `gpu/vulkan_gpu.cpp` and
# `pipeline/windows_unported.cpp` are `#ifndef __APPLE__` throughout, so on
# iOS they compile to nothing, exactly as they do on macOS.
build_lib() {
  local sources=() objects=() src obj
  shopt -s nullglob
  for src in "$here"/src/core/*.cpp "$here"/src/gpu/*.cpp "$here"/src/pipeline/*.cpp; do
    sources+=("$src")
  done
  shopt -u nullglob
  for src in "${sources[@]}"; do
    obj="$out/$(basename "$src" .cpp).o"
    "${CXX[@]}" "${target_cxx[@]}" "${cxxflags[@]}" "${includes[@]}" -c "$src" -o "$obj"
    objects+=("$obj")
  done
  rm -f "$out/libspektrafilm_engine.a"
  xcrun -sdk iphoneos libtool -static -o "$out/libspektrafilm_engine.a" "${objects[@]}"
  echo "static lib -> $out/libspektrafilm_engine.a"
}

# The baked resources and the product's own profiles, as `build.sh bundle` lays
# them out for the Mac app, but with the iOS metallib in place of the macOS one.
bundle_resources() {
  local app="$here/../SpektraProbe/Resources/engine"
  if [[ ! -f "$here/resources/spektrafilm_constants.bin" ]]; then
    echo "build-ios.sh: engine/resources is missing, and it is a tracked directory." >&2
    echo "    Restore it:  git checkout -- engine/resources" >&2
    exit 1
  fi
  mkdir -p "$app"
  rsync -a --delete --exclude '*.metallib' "$here/resources/" "$app/"
  cp "$out/spektrafilm.metallib" "$app/spektrafilm.metallib"
  if [[ -d "$here/resources_product/profiles" ]]; then
    cp "$here/resources_product/profiles/"*.json "$app/profiles/"
    cp "$here/resources_product/NOTICE.md" "$app/PRODUCT_PROFILES_NOTICE.md"
  fi
  local size
  size=$(du -sh "$app" | cut -f1)
  echo "bundle     -> $app ($size)"
}

case "${1:-all}" in
  metallib) build_metallib ;;
  lib)      build_metallib; build_lib ;;
  bundle)   build_metallib; bundle_resources ;;
  all)      build_metallib; build_lib; bundle_resources ;;
  *) echo "usage: build-ios.sh [all|lib|metallib|bundle]" >&2; exit 2 ;;
esac
