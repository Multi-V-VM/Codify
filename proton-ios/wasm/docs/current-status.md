# Current Proton WASM Status

## Split

- CPU path: Wine/Proton C code is being compiled toward `wasm32-wasip1`.
- GPU path: native Linux GPU stacks stay out of the WASM module. GPU work is
  expected to cross the host-import boundary and route through hetGPU.

## Verified

- `proton_wasm_bridge.wasm` builds from the overlay bridge.
- Native Wine host tools build far enough to drive the WASM cross build:
  `winebuild` and `winegcc`.
- The broad Wine WASM build completes with:
  `make -C proton-wasm/build/wine-wasm/wasm32-wasi -j8`.
- The iOS bridge now resolves the WASM Wine loader from `runtime_root`, sets
  WASI/Wine prefix mounts, and calls `wasmer_execute()`.
- The Wasmer CUDA/cuBLAS import path resolves the bundled hetGPU Apple symbols:
  `hetgpu_ane_gemm`, `hetgpu_apple_metal_gemm`, and
  `hetgpu_apple_ane_gemm`.
- The Wasmer CUDA Driver import path now accepts PTX modules through
  `cuModuleLoadData`, resolves functions with `cuModuleGetFunction`, translates
  wasm32 `kernelParams` into host argument slots, and forwards launches through
  the linked hetGPU/ZLUDA PTX backend when available.
- `HetGPUAppleRuntime.xcframework` now links a narrow Rust PTX bridge exporting
  `hetgpu_apple_ptx_*`. The Apple CUDA C stub routes `cuModuleLoadData`,
  `cuModuleGetFunction`, and `cuLaunchKernel` into that bridge, and registers
  `cuMemAlloc_v2` allocations so Metal launches know buffer sizes.
- Resource-bearing DLLs no longer fail on PE RVA subtraction in wasm assembly.
- The AMD AGS Unix side is stubbed for `PROTON_WASM`; native DRM/AMDGPU is not
  part of the WASM CPU module.

## Wine Patch Carries

- `tools/winegcc/winegcc.c`
  - Prefer Homebrew LLVM clang for `wasm32-*` so Xcode clang does not select a
    missing WASI compiler-rt path.
  - Force `-nodefaultlibs` for WASM links and rely on explicit WASI libraries.
- `tools/winebuild/spec32.c`
  - Skip PE export table and PE module header emission for `CPU_WASM32`.
  - Emit a text-section RVA anchor only as a generator placeholder.
- `tools/winebuild/utils.c`
  - Emit zero for PE RVA fields on `CPU_WASM32`; these addresses are not valid
    WASM runtime addresses.
- `tools/winebuild/import.c`
  - Do not make unresolved spec exports fatal for the current WASM skeleton.
- `dlls/amd_ags_x64/*`
  - Keep AMD native Unix GPU discovery disabled under `PROTON_WASM`.
- `dlls/ntdll/unix/unix_private.h` and `include/wine/unixlib.h`
  - Add first-pass WASM compile shims for signal declarations, machine identity,
    and Unix exception macros without WASI setjmp.

## Current Blockers

The build now produces WASM binaries, but many runtime surfaces are still
explicitly degraded under `PROTON_WASM`: Unix sockets, fd passing, signals,
ptrace/procfs tracing, fsync/ntsync, serial devices, POSIX file locks, and
process spawning. The next runtime work is replacing the most important stubs
with host transports that match WASI instead of Linux.
