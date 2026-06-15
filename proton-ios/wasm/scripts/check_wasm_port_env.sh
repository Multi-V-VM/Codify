#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTON_DIR="${PROTON_DIR:-"$ROOT_DIR/../proton-ios/proton"}"
WINE_DIR="$PROTON_DIR/wine"
WASI_TARGET="${WASI_TARGET:-wasm32-wasip1}"

for tool_bin in /opt/homebrew/opt/bison/bin /opt/homebrew/opt/flex/bin; do
  if [[ -d "$tool_bin" ]]; then
    PATH="$tool_bin:$PATH"
  fi
done
export PATH

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

resolve_wasi_sysroot() {
  if [[ -n "${WASI_SYSROOT:-}" ]]; then
    printf '%s\n' "$WASI_SYSROOT"
    return
  fi

  local candidates=()
  if [[ -n "${WASI_SDK_PATH:-}" ]]; then
    candidates+=("$WASI_SDK_PATH/share/wasi-sysroot")
  fi
  candidates+=(
    "/opt/wasi-sdk/share/wasi-sysroot"
    "/opt/homebrew/share/wasi-sysroot"
    "/usr/local/share/wasi-sysroot"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

check_cmd git "required for Proton submodules"
check_cmd make "required by Proton/Wine build scripts"
check_cmd awk "required by environment checks"
check_cmd bison "required to generate Wine build files"

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
  printf 'missing: clang or wasm32-wasi-clang (required for WASI builds)\n' >&2
  missing=1
else
  printf 'found:   WASI C compiler -> %s\n' "$cc"
  printf 'found:   WASI target -> %s\n' "$WASI_TARGET"
fi

if command -v wasm-ld >/dev/null 2>&1; then
  printf 'found:   wasm-ld -> %s\n' "$(command -v wasm-ld)"
else
  printf 'warning: wasm-ld not found on PATH; clang may still find its linker internally.\n' >&2
fi

sysroot="$(resolve_wasi_sysroot || true)"
if [[ -z "$sysroot" ]]; then
  printf 'missing: WASI sysroot\n' >&2
  printf '         Set WASI_SYSROOT or WASI_SDK_PATH before building.\n' >&2
  missing=1
else
  printf 'found:   WASI sysroot -> %s\n' "$sysroot"
fi

if [[ -n "$cc" && -n "$sysroot" ]]; then
  check_dir="$ROOT_DIR/build/check"
  mkdir -p "$check_dir"
  if printf 'int main(void) { return 0; }\n' | "$cc" \
    --target="$WASI_TARGET" \
    --sysroot="$sysroot" \
    -x c - \
    -o "$check_dir/wasi_link_check.wasm" \
    >/dev/null 2>"$check_dir/wasi_link_check.err"; then
    printf 'found:   WASI libc link path works\n'
  elif printf 'int main(void) { return 0; }\n' | "$cc" \
    --target="$WASI_TARGET" \
    --sysroot="$sysroot" \
    -nodefaultlibs \
    -lc \
    -x c - \
    -o "$check_dir/wasi_link_check.wasm" \
    >/dev/null 2>"$check_dir/wasi_link_check_fallback.err"; then
    printf 'found:   WASI libc link path works with -nodefaultlibs -lc\n'
  else
    printf 'missing: WASI libc link path failed for %s\n' "$cc" >&2
    sed 's/^/         /' "$check_dir/wasi_link_check.err" >&2
    sed 's/^/         fallback: /' "$check_dir/wasi_link_check_fallback.err" >&2
    missing=1
  fi
fi

if [[ ! -d "$PROTON_DIR/.git" && ! -f "$PROTON_DIR/.git" ]]; then
  printf 'missing: Proton checkout at %s\n' "$PROTON_DIR" >&2
  missing=1
else
  printf 'found:   Proton checkout -> %s\n' "$PROTON_DIR"
fi

if [[ ! -x "$WINE_DIR/configure" && ! -x "$WINE_DIR/autogen.sh" ]]; then
  printf 'missing: initialized Wine submodule at %s\n' "$WINE_DIR" >&2
  printf '         Run: git -C %s submodule update --init --recursive wine\n' "$PROTON_DIR" >&2
  missing=1
fi

printf '\nChecking hetGPU host bridge inputs...\n'
if ! bash "$ROOT_DIR/scripts/check_hetgpu_bridge.sh"; then
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  printf '\nWASM port environment check failed.\n' >&2
  exit 1
fi

printf '\nWASM port environment check passed.\n'
