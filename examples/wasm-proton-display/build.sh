#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${1:-"$SCRIPT_DIR/proton_display_probe.wasm"}
CLANG=${CLANG:-$(xcrun --find clang 2>/dev/null || command -v clang || printf '%s' /usr/bin/clang)}
WASM_LD=${WASM_LD:-$(xcrun --find wasm-ld 2>/dev/null || command -v wasm-ld || printf '%s' /opt/homebrew/bin/wasm-ld)}

"$CLANG" \
    --target=wasm32-unknown-unknown \
    -ffreestanding \
    -nostdlib \
    -Oz \
    -Wl,--no-entry \
    -Wl,--allow-undefined \
    -Wl,--export=main \
    -Wl,--export-memory \
    -fuse-ld="$WASM_LD" \
    "$SCRIPT_DIR/display_probe.c" \
    -o "$OUT"

printf 'Built %s\n' "$OUT"
