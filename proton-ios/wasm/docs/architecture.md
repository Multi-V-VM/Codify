# Proton WASM Architecture

## CPU Path

The CPU side of Proton/Wine is compiled to WASI. The bridge helper defaults to
`wasm32-wasip1`, while the Wine configure skeleton keeps its target explicit so
older upstream build logic can be handled separately. The WASM module owns
portable CPU work and exposes a small C ABI to the host. The host owns app
lifecycle, filesystem mounts, logging, UI, and runtime selection.

The bridge must not depend on Linux-only process semantics until explicit
WASI/WASIX shims exist for that behavior.

## GPU Path

GPU work is not executed inside the WASM sandbox. GPU calls cross the WASM
boundary as host imports, and CodifyOne/Wasmer routes those imports to hetGPU
on Apple platforms.

The first supported import surface intentionally matches the existing
`wasm-cuda-oxide` probe:

- `cudaMalloc`
- `cudaFree`
- `cudaMemcpy`
- `cudaDeviceSynchronize`
- `cublasCreate_v2`
- `cublasDestroy_v2`
- `cublasSgemm_v2`

On the host side, this maps to `HetGPUAppleRuntime.xcframework` entry points
such as `hetgpu_apple_metal_gemm` and `hetgpu_apple_ane_gemm`.

## Boundary Rule

The WASM port should not pull Proton's native Linux GPU stack into the CPU
module. Any accelerated path should either:

- use the CUDA/cuBLAS-compatible hetGPU import surface, or
- define a new narrow host-import ABI before adding Wine/Proton patches that
  depend on it.

This keeps CPU portability and Apple GPU acceleration independently testable.
