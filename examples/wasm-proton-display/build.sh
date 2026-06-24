#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${1:-"$SCRIPT_DIR/proton_display_probe.wasm"}

find_tool() {
    name=$1
    env_name=$2
    shift 2

    if found=$(xcrun --find "$name" 2>/dev/null) && [[ -x "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    if found=$(command -v "$name" 2>/dev/null) && [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    for candidate in "$@"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'error: %s not found; install it or set %s\n' "$name" "$env_name" >&2
    return 1
}

CLANG=${CLANG:-$(find_tool clang CLANG /usr/bin/clang)}
WASM_LD=${WASM_LD:-$(find_tool wasm-ld WASM_LD /opt/homebrew/bin/wasm-ld /usr/local/bin/wasm-ld)}

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
