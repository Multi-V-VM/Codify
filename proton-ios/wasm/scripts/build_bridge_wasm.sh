#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/bridge"
OUT="${1:-"$ROOT_DIR/build/proton_wasm_bridge.wasm"}"
TARGET="${WASI_TARGET:-wasm32-wasip1}"

resolve_cmd() {
  local candidate="$1"

  if [[ "$candidate" == */* ]]; then
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    return 1
  fi

  command -v "$candidate" 2>/dev/null
}

cc="${WASI_CC:-}"
if [[ -z "$cc" ]]; then
  for candidate in \
    wasm32-wasi-clang \
    /opt/homebrew/opt/llvm/bin/clang \
    /opt/homebrew/bin/clang \
    clang; do
    if cc="$(resolve_cmd "$candidate")"; then
      break
    fi
    cc=""
  done
fi

if [[ -z "$cc" ]]; then
  printf 'missing: clang or wasm32-wasi-clang\n' >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$(dirname "$OUT")"

"$cc" \
  --target="$TARGET" \
  -ffreestanding \
  -nostdlib \
  -Oz \
  -I"$ROOT_DIR/include" \
  "$ROOT_DIR/src/proton_wasm.c" \
  -Wl,--no-entry \
  -Wl,--export=proton_wasm_abi_version \
  -Wl,--export=proton_wasm_initialize \
  -Wl,--export=proton_wasm_configure_gpu \
  -Wl,--export=proton_wasm_gpu_backend \
  -Wl,--export=proton_wasm_gpu_backend_name \
  -Wl,--export=proton_wasm_gpu_device_hint \
  -Wl,--export=proton_wasm_run \
  -Wl,--export=proton_wasm_shutdown \
  -Wl,--export=proton_wasm_last_error \
  -Wl,--export-memory \
  -o "$OUT"

printf 'Built %s\n' "$OUT"
