#!/bin/bash
# build-ios.sh -- the engine for iPhone and iPad, and for the iOS Simulator.
#
#   engine/build-ios.sh            device: metallib + static lib + bundle
#   engine/build-ios.sh metallib   device: just the kernels
#   engine/build-ios.sh lib        device: the static library + the metallib
#   engine/build-ios.sh bundle     the resources into SpektraProbe (no metallib)
#   engine/build-ios.sh sim        Simulator: metallib + static lib
#
# A separate script rather than a mode of `build.sh`, so the macOS build is not
# touched by any of this: same sources, same math flags, different SDKs and
# different output folders under the already-ignored `build/`:
#
#   build/ios/       iphoneos (arm64 devices)
#   build/ios-sim/   iphonesimulator (arm64 Macs)
#
# **The Simulator build compiles one engine file from a patched copy**, never
# from the source: `ios-simulator-metal_gpu.patch` is applied to a copy of
# `src/gpu/metal_gpu.cpp` in build/ios-sim/patched/. The Simulator's Metal
# refuses a linear texture over a shared buffer (an assertion that ends the
# process on the first render), so there the result is copied into a texture
# of its own. Every engine source file stays exactly the original's, and the
# device and Mac builds never see the patch.
#
# The macOS metallib lives at `resources/spektrafilm.metallib` and is what
# `build.sh bundle` ships. This script never writes there. Nor does it put a
# metallib into SpektraProbe's resources: a device and a Simulator need
# different ones, so the app's "Copy the engine's metallib" build phase copies
# the one for the platform being built, from the folders above.
#
# The two math flags are load-bearing for exactly the reason `build.sh` gives
# (RFC-014 §5.1 trap 1): Metal defaults to fast math, and `spk_engine_create`
# refuses to start an engine whose kernels were built with it.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IOS_MIN=18.0
cxxflags=(-std=c++20 -O2 -Wall -Wextra)
includes=(-I"$here/include" -I"$here/src" -I"$here/src/core" -I"$here/third_party/metal-cpp")
math_flags=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)

# One platform at a time. Everything below reads these five.
use_platform() {
  case "$1" in
    device)
      sdk_name=iphoneos
      out="$here/build/ios"
      target_cxx=(-target "arm64-apple-ios$IOS_MIN")
      target_metal=(-mios-version-min="$IOS_MIN")
      metallib_platform=METALLIB_PLATFORM_IOS ;;
    sim)
      sdk_name=iphonesimulator
      out="$here/build/ios-sim"
      target_cxx=(-target "arm64-apple-ios$IOS_MIN-simulator")
      target_metal=(-mios-simulator-version-min="$IOS_MIN")
      metallib_platform=METALLIB_PLATFORM_IOS_SIMULATOR ;;
  esac
  target_cxx+=(-isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)")
  mkdir -p "$out"
}

# Without a floor the metal compiler stamps the *SDK's* iOS version, and a
# metallib stamped for a newer iOS than the device's does not load.
check_metallib_target() {
  local headers platform major
  headers=$(xcrun -sdk "$sdk_name" metal-readobj --file-headers "$1")
  platform=$(awk '/Platform:/ && !/PlatformM/ {print $2; exit}' <<<"$headers")
  major=$(awk '/PlatformMajor:/ {print $2; exit}' <<<"$headers")
  # `metal-readobj` names it `METALLIB_PLATFORM_IOS` (macOS: `..._MACOS`).
  if [[ "$platform" != "$metallib_platform" || "$major" != "${IOS_MIN%%.*}" ]]; then
    echo "build-ios.sh: $1 targets $platform $major, not $metallib_platform $IOS_MIN" >&2
    exit 1
  fi
}

build_metallib() {
  local airs=() m air
  shopt -s nullglob
  for m in "$here"/src/shaders/*.metal; do
    air="$out/$(basename "$m" .metal).air"
    xcrun -sdk "$sdk_name" metal "${math_flags[@]}" "${target_metal[@]}" -Werror -c "$m" -o "$air"
    airs+=("$air")
  done
  shopt -u nullglob
  xcrun -sdk "$sdk_name" metallib "${airs[@]}" -o "$out/spektrafilm.metallib"
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
  local extra=()
  if [[ "$sdk_name" == iphonesimulator ]]; then
    # The patched copy, in place of the original (see the header). The copy
    # includes "gpu.hpp" from the original's folder.
    mkdir -p "$out/patched"
    cp "$here/src/gpu/metal_gpu.cpp" "$out/patched/metal_gpu.cpp"
    patch --quiet --forward -p4 -d "$out/patched" < "$here/ios-simulator-metal_gpu.patch"
    extra=(-I"$here/src/gpu")
    for i in "${!sources[@]}"; do
      [[ "${sources[$i]}" == "$here/src/gpu/metal_gpu.cpp" ]] && sources[$i]="$out/patched/metal_gpu.cpp"
    done
  fi
  for src in "${sources[@]}"; do
    obj="$out/$(basename "$src" .cpp).o"
    xcrun -sdk "$sdk_name" clang++ "${target_cxx[@]}" "${cxxflags[@]}" "${includes[@]}" ${extra[@]+"${extra[@]}"} -c "$src" -o "$obj"
    objects+=("$obj")
  done
  rm -f "$out/libspektrafilm_engine.a"
  xcrun -sdk "$sdk_name" libtool -static -o "$out/libspektrafilm_engine.a" "${objects[@]}"
  echo "static lib -> $out/libspektrafilm_engine.a"
}

# The baked resources and the product's own profiles, as `build.sh bundle` lays
# them out for the Mac app. No metallib: see the header.
bundle_resources() {
  local app="$here/../SpektraProbe/Resources/engine"
  if [[ ! -f "$here/resources/spektrafilm_constants.bin" ]]; then
    echo "build-ios.sh: engine/resources is missing, and it is a tracked directory." >&2
    echo "    Restore it:  git checkout -- engine/resources" >&2
    exit 1
  fi
  mkdir -p "$app"
  # `--delete-excluded`, so a metallib an earlier version of this script put
  # here goes too, rather than being shipped stale beside the right one.
  rsync -a --delete --delete-excluded --exclude '*.metallib' "$here/resources/" "$app/"
  if [[ -d "$here/resources_product/profiles" ]]; then
    cp "$here/resources_product/profiles/"*.json "$app/profiles/"
    cp "$here/resources_product/NOTICE.md" "$app/PRODUCT_PROFILES_NOTICE.md"
    # Multigrade grades 00–5 as a neutral pack and print exposure. The engine
    # does not read this file; the app does, for its Grade control.
    cp "$here/resources_product/paper_grades.json" "$app/paper_grades.json"
  fi
  local size
  size=$(du -sh "$app" | cut -f1)
  echo "bundle     -> $app ($size)"
}

case "${1:-all}" in
  metallib) use_platform device; build_metallib ;;
  lib)      use_platform device; build_metallib; build_lib ;;
  bundle)   bundle_resources ;;
  all)      use_platform device; build_metallib; build_lib; bundle_resources ;;
  sim)      use_platform sim; build_metallib; build_lib ;;
  *) echo "usage: build-ios.sh [all|lib|metallib|bundle|sim]" >&2; exit 2 ;;
esac
