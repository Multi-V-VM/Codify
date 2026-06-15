#ifndef PROTON_WASM_HETGPU_IMPORTS_H
#define PROTON_WASM_HETGPU_IMPORTS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__wasm__)
#define PROTON_WASM_HOST_IMPORT(module_name, import_name_value) \
    __attribute__((import_module(module_name), import_name(import_name_value)))
#else
#define PROTON_WASM_HOST_IMPORT(module_name, import_name_value)
#endif

typedef enum proton_wasm_cuda_memcpy_kind {
    PROTON_WASM_CUDA_MEMCPY_HOST_TO_DEVICE = 1,
    PROTON_WASM_CUDA_MEMCPY_DEVICE_TO_HOST = 2
} proton_wasm_cuda_memcpy_kind_t;

typedef enum proton_wasm_cublas_operation {
    PROTON_WASM_CUBLAS_OP_N = 0,
    PROTON_WASM_CUBLAS_OP_T = 1,
    PROTON_WASM_CUBLAS_OP_C = 2
} proton_wasm_cublas_operation_t;

PROTON_WASM_HOST_IMPORT("env", "cudaMalloc")
int cudaMalloc(void **dev_ptr, size_t size);

PROTON_WASM_HOST_IMPORT("env", "cudaFree")
int cudaFree(void *dev_ptr);

PROTON_WASM_HOST_IMPORT("env", "cudaMemcpy")
int cudaMemcpy(void *dst, const void *src, size_t size, int kind);

PROTON_WASM_HOST_IMPORT("env", "cudaDeviceSynchronize")
int cudaDeviceSynchronize(void);

PROTON_WASM_HOST_IMPORT("env", "cublasCreate_v2")
int cublasCreate_v2(void **handle);

PROTON_WASM_HOST_IMPORT("env", "cublasDestroy_v2")
int cublasDestroy_v2(void *handle);

PROTON_WASM_HOST_IMPORT("env", "cublasSgemm_v2")
int cublasSgemm_v2(
    void *handle,
    int transa,
    int transb,
    int m,
    int n,
    int k,
    const float *alpha,
    const float *a,
    int lda,
    const float *b,
    int ldb,
    const float *beta,
    float *c,
    int ldc);

#ifdef __cplusplus
}
#endif

#endif
