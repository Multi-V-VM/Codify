# Proton WASM Port

This directory is a WASI/WebAssembly port overlay for the local Proton source
tree. The split is explicit:

- CPU work runs inside WASM/WASI.
- GPU work is delegated to the host through hetGPU imports.

It intentionally does not try to make upstream Proton's Linux container build
run as-is. The first useful target is a small, reproducible WASM bridge, a
Wine configure skeleton, and a host-import contract for Apple GPU execution.

By default these scripts reuse the existing Proton checkout at
`../proton-ios/proton`. Override that with `PROTON_DIR=/path/to/proton` when
working against a different tree.

## Current Scope

The practical first milestone is not "run Windows games inside a browser". A
Proton-to-WASM port has to replace or stub Linux process semantics, dynamic
loading, executable memory, signals, sockets, Steam integration, and the
native CPU execution model used by Windows binaries. GPU acceleration should
not be compiled into the WASM module as a native Linux graphics stack; it
should cross the WASM boundary as narrow host imports that CodifyOne/Wasmer can
route to hetGPU.

The first milestone is:

1. Keep Proton source outside this overlay.
2. Build a small WASI C ABI bridge that CodifyOne/Wasmer can load. The helper
   defaults to `wasm32-wasip1` and accepts `WASI_TARGET=...`.
3. Expose a GPU backend setting where `PROTON_WASM_GPU_HETGPU` means GPU calls
   are expected to resolve through host imports.
4. Start a Wine configure pass for WASI with known unsupported host
   features disabled.
5. Record every required Proton/Wine patch as a small, named carry.

## Layout

- `include/` and `src/` - stable C ABI bridge for WASM host integration.
- `scripts/` - environment checks and build helpers.
- `docs/` - porting notes and decision records.
- `build/` - generated local output, ignored by Git.

See `docs/current-status.md` for the current verified build targets and the
next WASI portability blockers.

## Quick Start

Run the environment check:

```bash
./scripts/check_wasm_port_env.sh
```

Build the initial bridge WASM:

```bash
./scripts/build_bridge_wasm.sh
```

Check that the expected hetGPU host bridge inputs are present:

```bash
./scripts/check_hetgpu_bridge.sh
```

Start the Wine/WASI configure skeleton:

```bash
./scripts/build_wine_wasm_skeleton.sh
```

## Runtime Model

This overlay targets a WASI/WASIX host first. The bridge should return status
codes instead of calling `exit`, and it should not assume that arbitrary
process spawning, host dynamic libraries, or writable executable memory exist.

GPU runtime calls are intentionally host imports. The import contract covers
CUDA runtime memory calls, CUDA Driver PTX module calls, and the current
cuBLAS GEMM probe:

- `cudaMalloc`
- `cudaFree`
- `cudaMemcpy`
- `cudaDeviceSynchronize`
- `cuInit`
- `cuDeviceGetCount`
- `cuDeviceGet`
- `cuCtxCreate_v2`
- `cuCtxSetCurrent`
- `cuMemAlloc_v2`
- `cuMemFree_v2`
- `cuMemcpyHtoD_v2`
- `cuMemcpyDtoH_v2`
- `cuMemcpyDtoD_v2`
- `cuModuleLoadData`
- `cuModuleLoadDataEx`
- `cuModuleGetFunction`
- `cuLaunchKernel`
- `cuCtxSynchronize`
- `cublasCreate_v2`
- `cublasDestroy_v2`
- `cublasSgemm_v2`

CodifyOne's Wasmer bridge routes those imports to the bundled
`HetGPUAppleRuntime.xcframework` entry points. GEMM can use Metal/ANE directly.
PTX modules are forwarded through `hetgpu_apple_ptx_*`, a narrow Rust bridge
that lowers PTX to MSL through ZLUDA/comgr and launches it on Metal.
