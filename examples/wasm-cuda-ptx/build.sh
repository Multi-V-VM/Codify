#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${1:-"$SCRIPT_DIR/cuda_ptx_probe.wasm"}
OBJ=${TMPDIR:-/tmp}/cuda_ptx_probe.$$.o

find_tool() {
    name=$1
    env_name=$2
    shift 2

    if found=$(xcrun --find "$name" 2>/dev/null) && [ -x "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi
    if found=$(command -v "$name" 2>/dev/null) && [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi
    for candidate do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'error: %s not found; install it or set %s\n' "$name" "$env_name" >&2
    return 1
}

CLANG=${CLANG:-$(find_tool clang CLANG /usr/bin/clang)}
WASM_LD=${WASM_LD:-$(find_tool wasm-ld WASM_LD /opt/homebrew/bin/wasm-ld /usr/local/bin/wasm-ld)}

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
    --initial-memory=16777216 \
    --max-memory=268435456 \
    "$OBJ" \
    -o "$OUT"

printf '%s\n' "$OUT"
