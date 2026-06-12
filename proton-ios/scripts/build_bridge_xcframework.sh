#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/bridge"
OUT_DIR="$ROOT_DIR/build/ProtonIOSBridge.xcframework"

build_static_lib() {
  local sdk_name="$1"
  local target="$2"
  local name="$3"
  local sdk_path
  local clang_path
  local ar_path

  sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
  clang_path="$(xcrun --sdk "$sdk_name" --find clang)"
  ar_path="$(xcrun --sdk "$sdk_name" --find ar)"

  mkdir -p "$BUILD_DIR/$name"

  "$clang_path" \
    -target "$target" \
    -isysroot "$sdk_path" \
    -I"$ROOT_DIR/include" \
    -fembed-bitcode-marker \
    -c "$ROOT_DIR/src/proton_ios.c" \
    -o "$BUILD_DIR/$name/proton_ios.o"

  "$ar_path" rcs "$BUILD_DIR/$name/libproton_ios_bridge.a" "$BUILD_DIR/$name/proton_ios.o"
}

rm -rf "$OUT_DIR"

build_static_lib iphoneos arm64-apple-ios iphoneos-arm64
build_static_lib iphonesimulator arm64-apple-ios-simulator iphonesimulator-arm64

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/iphoneos-arm64/libproton_ios_bridge.a" \
  -headers "$ROOT_DIR/include" \
  -library "$BUILD_DIR/iphonesimulator-arm64/libproton_ios_bridge.a" \
  -headers "$ROOT_DIR/include" \
  -output "$OUT_DIR"

printf 'Created %s\n' "$OUT_DIR"

