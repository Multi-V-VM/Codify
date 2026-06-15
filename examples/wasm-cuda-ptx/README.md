# CodifyOne CUDA PTX WASM Probe

This example builds a tiny freestanding WebAssembly module that imports CUDA
Driver API entry points from the host, loads an embedded PTX vector-add kernel,
and launches it through `cuLaunchKernel`.

```sh
./build.sh
```

In CodifyOne, the bundled copy can be launched from the terminal with:

```sh
wasm_cuda_ptx
```

or, if you copy the module into the current directory:

```sh
wasm --gpu-backend metal cuda_ptx_probe.wasm
```

Use `--gpu-backend metal` for this probe; `--gpu` defaults to the ANE backend.

The probe treats `CUDA_ERROR_NOT_SUPPORTED` as a clean skip. That means the
WASM import and argument bridge are present, but the PTX host symbols were not
linked into the running app. Once the backend is linked, expected output ends
with:

```text
PASS: CUDA Driver PTX WASM path computed vector add
```
