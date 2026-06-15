#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$ROOT_DIR/.." && pwd)"

HETGPU_HEADER="$PROJECT_DIR/Resources/HetGPUAppleRuntime.xcframework/ios-arm64/Headers/hetgpu_apple_runtime.h"
WASMER_GPU_RS="$PROJECT_DIR/wasmer-ios/wasmer/lib/cli/src/commands/run/gpu.rs"
WASMER_IOS_RS="$PROJECT_DIR/wasmer-ios/src/lib.rs"
CUDA_PROBE="$PROJECT_DIR/examples/wasm-cuda-oxide/cuda_oxide_probe.c"
PROTON_IOS_BRIDGE="$PROJECT_DIR/proton-ios/src/proton_ios.c"

missing=0

check_file() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    printf 'missing: %s\n' "$path" >&2
    missing=1
  else
    printf 'found:   %s\n' "$path"
  fi
}

check_text() {
  local path="$1"
  local needle="$2"

  if [[ ! -f "$path" ]]; then
    return
  fi

  if ! grep -q "$needle" "$path"; then
    printf 'missing: %s in %s\n' "$needle" "$path" >&2
    missing=1
  else
    printf 'found:   %s in %s\n' "$needle" "$path"
  fi
}

check_file "$HETGPU_HEADER"
check_file "$WASMER_GPU_RS"
check_file "$WASMER_IOS_RS"
check_file "$CUDA_PROBE"
check_file "$PROTON_IOS_BRIDGE"

check_text "$HETGPU_HEADER" "hetgpu_apple_metal_gemm"
check_text "$HETGPU_HEADER" "hetgpu_apple_ane_gemm"
check_text "$WASMER_GPU_RS" "cublasSgemm_v2"
check_text "$WASMER_GPU_RS" "hetgpu_apple_metal_gemm"
check_text "$WASMER_IOS_RS" "hetgpu_apple_metal_gemm"
check_text "$CUDA_PROBE" "cudaMalloc"
check_text "$CUDA_PROBE" "cublasSgemm_v2"
check_text "$PROTON_IOS_BRIDGE" "wasmer_execute"
check_text "$PROTON_IOS_BRIDGE" "WASM_CUDA_ACCEL"

if [[ "$missing" -ne 0 ]]; then
  printf '\nhetGPU bridge check failed.\n' >&2
  exit 1
fi

printf '\nhetGPU bridge inputs are present.\n'
