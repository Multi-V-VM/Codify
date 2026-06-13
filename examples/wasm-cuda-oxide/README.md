# CodifyOne CUDA Oxide WASM Probe

This example builds a tiny freestanding WebAssembly module that imports CUDA
runtime and cuBLAS entry points from the host, then runs a 2x2 SGEMM:

```sh
./build.sh
```

The module does not require a WASI libc. It only imports `fd_write` for logging
plus these host functions from the `env` module:

- `cudaMalloc`
- `cudaFree`
- `cudaMemcpy`
- `cudaDeviceSynchronize`
- `cublasCreate_v2`
- `cublasDestroy_v2`
- `cublasSgemm_v2`

In CodifyOne, the bundled copy can be launched from the terminal with:

```sh
wasm_cuda_oxide
```

or, if you copy the module into the current directory:

```sh
wasm --gpu cuda_oxide_probe.wasm
```

Expected successful output ends with:

```text
PASS: CUDA/cuBLAS WASM path computed the expected SGEMM
```

Runtime note: the Wasmer runtime must provide the CUDA/cuBLAS WebAssembly host
imports and route them to the bundled HetGPU Apple runtime. Without that bridge,
Wasmer will reject the module during instantiation because the CUDA imports are
unresolved.
