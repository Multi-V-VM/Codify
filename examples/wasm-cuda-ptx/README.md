# CodifyOne CUDA PTX WASM Probe

This example builds a tiny freestanding WebAssembly module that imports CUDA
Driver API entry points from the host, loads an embedded PTX vector-add kernel,
and launches it through `cuLaunchKernel`.

```sh
./build.sh
```

The probe treats `CUDA_ERROR_NOT_SUPPORTED` as a clean skip. That means the
WASM import and argument bridge are present, but no real hetGPU/ZLUDA PTX
backend is linked yet. Once the backend is linked, expected output ends with:

```text
PASS: CUDA Driver PTX WASM path computed vector add
```
