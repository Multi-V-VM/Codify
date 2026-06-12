#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTON_DIR="$ROOT_DIR/proton"

missing=0

check_cmd() {
  local cmd="$1"
  local hint="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'missing: %s (%s)\n' "$cmd" "$hint" >&2
    missing=1
  else
    printf 'found:   %s -> %s\n' "$cmd" "$(command -v "$cmd")"
  fi
}

check_cmd git "required for Proton submodules"
check_cmd make "required by Proton/Wine build scripts"
check_cmd xcrun "required to locate iOS SDKs"
check_cmd xcodebuild "required to create XCFrameworks"
check_cmd clang "required for native compile checks"

if command -v xcode-select >/dev/null 2>&1; then
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$developer_dir" ]]; then
    printf 'found:   developer dir -> %s\n' "$developer_dir"
    if [[ "$developer_dir" == "/Library/Developer/CommandLineTools" ]]; then
      printf 'warning: xcode-select is pointing at CommandLineTools, which does not include iOS SDKs.\n' >&2
      printf '         Install/open full Xcode, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\n' >&2
    fi
  fi
fi

if [[ ! -d "$PROTON_DIR/.git" && ! -f "$PROTON_DIR/.git" ]]; then
  printf 'missing: Proton submodule checkout at %s\n' "$PROTON_DIR" >&2
  missing=1
fi

if command -v xcrun >/dev/null 2>&1; then
  iphoneos_error="$ROOT_DIR/build/check-iphoneos-sdk.err"
  simulator_error="$ROOT_DIR/build/check-iphonesimulator-sdk.err"
  mkdir -p "$ROOT_DIR/build"

  iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-path 2>"$iphoneos_error" || true)"
  simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>"$simulator_error" || true)"

  if [[ -z "$iphoneos_sdk" ]]; then
    printf 'missing: iphoneos SDK\n' >&2
    sed 's/^/         /' "$iphoneos_error" >&2
    missing=1
  else
    printf 'found:   iphoneos SDK -> %s\n' "$iphoneos_sdk"
  fi

  if [[ -z "$simulator_sdk" ]]; then
    printf 'missing: iphonesimulator SDK\n' >&2
    sed 's/^/         /' "$simulator_error" >&2
    missing=1
  else
    printf 'found:   iphonesimulator SDK -> %s\n' "$simulator_sdk"
  fi
fi

if [[ -d "$PROTON_DIR" ]]; then
  uninitialized="$(
    git -C "$PROTON_DIR" submodule status --recursive 2>/dev/null \
      | awk '/^-/{print $2}' \
      | head -20 || true
  )"

  if [[ -n "$uninitialized" ]]; then
    printf '\nProton has uninitialized submodules. Initialize them with:\n'
    printf '  git -C %s submodule update --init --recursive\n' "$PROTON_DIR"
    printf '\nFirst uninitialized entries:\n%s\n' "$uninitialized"
  fi
fi

if [[ "$missing" -ne 0 ]]; then
  printf '\nEnvironment check failed.\n' >&2
  exit 1
fi

printf '\nEnvironment check passed. Next step: initialize submodules, then start the Wine core build skeleton.\n'
