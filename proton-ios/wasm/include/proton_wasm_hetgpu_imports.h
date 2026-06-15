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

PROTON_WASM_HOST_IMPORT("env", "cuInit")
int cuInit(unsigned int flags);

PROTON_WASM_HOST_IMPORT("env", "cuDriverGetVersion")
int cuDriverGetVersion(int *driver_version);

PROTON_WASM_HOST_IMPORT("env", "cuDeviceGetCount")
int cuDeviceGetCount(int *count);

PROTON_WASM_HOST_IMPORT("env", "cuDeviceGet")
int cuDeviceGet(int *device, int ordinal);

PROTON_WASM_HOST_IMPORT("env", "cuDeviceGetName")
int cuDeviceGetName(char *name, int len, int device);

PROTON_WASM_HOST_IMPORT("env", "cuDeviceTotalMem_v2")
int cuDeviceTotalMem_v2(size_t *bytes, int device);

PROTON_WASM_HOST_IMPORT("env", "cuDeviceGetAttribute")
int cuDeviceGetAttribute(int *value, int attribute, int device);

PROTON_WASM_HOST_IMPORT("env", "cuCtxCreate_v2")
int cuCtxCreate_v2(void **context, unsigned int flags, int device);

PROTON_WASM_HOST_IMPORT("env", "cuCtxDestroy_v2")
int cuCtxDestroy_v2(void *context);

PROTON_WASM_HOST_IMPORT("env", "cuCtxSetCurrent")
int cuCtxSetCurrent(void *context);

PROTON_WASM_HOST_IMPORT("env", "cuCtxGetCurrent")
int cuCtxGetCurrent(void **context);

PROTON_WASM_HOST_IMPORT("env", "cuCtxSynchronize")
int cuCtxSynchronize(void);

PROTON_WASM_HOST_IMPORT("env", "cuMemAlloc_v2")
int cuMemAlloc_v2(void **device_ptr, size_t size);

PROTON_WASM_HOST_IMPORT("env", "cuMemFree_v2")
int cuMemFree_v2(void *device_ptr);

PROTON_WASM_HOST_IMPORT("env", "cuMemcpyHtoD_v2")
int cuMemcpyHtoD_v2(void *dst_device, const void *src_host, size_t size);

PROTON_WASM_HOST_IMPORT("env", "cuMemcpyDtoH_v2")
int cuMemcpyDtoH_v2(void *dst_host, const void *src_device, size_t size);

PROTON_WASM_HOST_IMPORT("env", "cuMemcpyDtoD_v2")
int cuMemcpyDtoD_v2(void *dst_device, const void *src_device, size_t size);

PROTON_WASM_HOST_IMPORT("env", "cuModuleLoadData")
int cuModuleLoadData(void **module, const void *image);

PROTON_WASM_HOST_IMPORT("env", "cuModuleLoadDataEx")
int cuModuleLoadDataEx(
    void **module,
    const void *image,
    unsigned int num_options,
    void *options,
    void *option_values);

PROTON_WASM_HOST_IMPORT("env", "cuModuleUnload")
int cuModuleUnload(void *module);

PROTON_WASM_HOST_IMPORT("env", "cuModuleGetFunction")
int cuModuleGetFunction(void **function, void *module, const char *name);

PROTON_WASM_HOST_IMPORT("env", "cuLaunchKernel")
int cuLaunchKernel(
    void *function,
    unsigned int grid_dim_x,
    unsigned int grid_dim_y,
    unsigned int grid_dim_z,
    unsigned int block_dim_x,
    unsigned int block_dim_y,
    unsigned int block_dim_z,
    unsigned int shared_mem_bytes,
    void *stream,
    void **kernel_params,
    void **extra);

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
