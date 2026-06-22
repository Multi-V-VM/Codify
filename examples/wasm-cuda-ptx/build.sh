#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${1:-"$SCRIPT_DIR/cuda_ptx_probe.wasm"}
CLANG=${CLANG:-$(xcrun --find clang 2>/dev/null || command -v clang || printf '%s' /usr/bin/clang)}
WASM_LD=${WASM_LD:-$(xcrun --find wasm-ld 2>/dev/null || command -v wasm-ld || printf '%s' /opt/homebrew/bin/wasm-ld)}
OBJ=${TMPDIR:-/tmp}/cuda_ptx_probe.$$.o

cleanup() {
    rm -f "$OBJ"
}
trap cleanup EXIT INT TERM

"$CLANG" \
    --target=wasm32-unknown-unknown \
    -O2 \
    -ffreestanding \
    -fno-builtin \
    -nostdlib \
    -c "$SCRIPT_DIR/cuda_ptx_probe.c" \
    -o "$OBJ"

"$WASM_LD" \
    --no-entry \
    --export=main \
    --export-memory \
    --allow-undefined \
    --import-undefined \
    --initial-memory=131072 \
    --max-memory=131072 \
    "$OBJ" \
    -o "$OUT"

printf '%s\n' "$OUT"
