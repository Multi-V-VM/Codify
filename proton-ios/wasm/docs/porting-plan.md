# WASM Porting Plan

## Milestone 0: Repo Hygiene

- Keep Proton in `proton-ios/proton` or another checkout selected with
  `PROTON_DIR`.
- Keep WASM glue outside the Proton submodule unless a patch must be carried
  against Wine or Proton.
- Put generated artifacts under `proton-wasm/build/`.

## Milestone 1: WASI Bridge

- Build `src/proton_wasm.c` to a WASI module. The bridge helper defaults to
  `wasm32-wasip1` and accepts `WASI_TARGET=...`.
- Export a small C ABI:

```c
int proton_wasm_abi_version(void);
int proton_wasm_initialize(const char *runtime_root, const char *prefix_root);
int proton_wasm_configure_gpu(proton_wasm_gpu_backend_t backend, const char *device_hint);
proton_wasm_gpu_backend_t proton_wasm_gpu_backend(void);
const char *proton_wasm_gpu_backend_name(void);
int proton_wasm_run(const char *exe_path, int argc, const char * const *argv);
void proton_wasm_shutdown(void);
const char *proton_wasm_last_error(void);
```

- Keep initialization and execution separate so the host owns filesystem
  mappings, package paths, logging, and UI lifecycle.
- Treat CPU and GPU as separate contracts: CPU code is compiled to WASM/WASI,
  and GPU calls leave the module as host imports.

## Milestone 2: Wine Configure Skeleton

- Build native Wine tools on the host first.
- Configure Wine with `--host=wasm32-wasi`.
- Disable features that are not available in the initial WASI runtime:
  - Linux display stacks: X11 and Wayland.
  - Native audio/server integrations: ALSA, PulseAudio, OSS.
  - Device managers: udev, USB, v4l2, pcsc-lite.
  - Native Linux graphics acceleration: OpenGL, Vulkan, OpenCL.
  - Dynamic loading and process features until explicit shims exist.

## Milestone 3: Runtime Shims

The first runnable target should be controlled failure, not compatibility:

- Prefix directory creation and validation.
- Deterministic error reporting for unsupported Win32 APIs.
- Filesystem-only tests with no child process or dynamic loader dependency.
- WASIX-specific shims for clocks, sockets, threads, and signals only after a
  configure/build failure proves they are needed.

## Milestone 4: Execution Model

Proton normally runs native Windows binaries. A WASM host cannot execute x86 or
x64 code by itself. Choose one of these tracks before attempting real programs:

- Recompile narrow Windows-side test programs to a supported architecture.
- Integrate a CPU emulator/interpreter as an explicit dependency.
- Target a headless Wine service subset rather than arbitrary Windows EXEs.

## Milestone 5: GPU Through hetGPU

GPU execution is not part of the WASM CPU port. The initial GPU contract is a
host-provided hetGPU backend, selected with `PROTON_WASM_GPU_HETGPU`, and a
small import surface compatible with the existing Wasmer CUDA/cuBLAS bridge:

- `cudaMalloc`
- `cudaFree`
- `cudaMemcpy`
- `cudaDeviceSynchronize`
- `cublasCreate_v2`
- `cublasDestroy_v2`
- `cublasSgemm_v2`

That import surface lets the host route GPU work to
`HetGPUAppleRuntime.xcframework`, currently through Metal or ANE GEMM entry
points. Larger graphics work should be staged behind this boundary:

- Keep software rendering available for CPU-only smoke tests.
- Lower narrow compute-heavy paths to the CUDA/cuBLAS import surface first.
- Add D3D/Vulkan translation only after the host exposes a matching hetGPU
  bridge. Do not compile Proton's native Linux GPU stack into the WASM module
  and expect it to run unchanged.

## Milestone 6: Patch Carries

## Patch Policy

Patch upstream only when necessary. Name carried patches by layer:

- `wasm-build-*`
- `wasm-runtime-*`
- `wasm-graphics-*`

Each patch should say whether it is a local carry or intended to be upstreamed.
