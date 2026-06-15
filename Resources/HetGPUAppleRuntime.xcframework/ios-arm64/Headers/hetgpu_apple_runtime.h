#ifndef HETGPU_APPLE_RUNTIME_H
#define HETGPU_APPLE_RUNTIME_H

#include <stddef.h>
#include <stdint.h>
#include "ane_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

int hetgpu_ane_gemm(int transa, int transb,
                    int m, int n, int k,
                    float alpha,
                    const void *A, int Atype, int lda,
                    const void *B, int Btype, int ldb,
                    float beta,
                    void *C, int Ctype, int ldc);

int hetgpu_apple_ane_gemm(int transa, int transb,
                          int m, int n, int k,
                          float alpha,
                          const void *A, int Atype, int lda,
                          const void *B, int Btype, int ldb,
                          float beta,
                          void *C, int Ctype, int ldc);

int hetgpu_apple_metal_gemm(int transa, int transb,
                            int m, int n, int k,
                            float alpha,
                            const void *A, int Atype, int lda,
                            const void *B, int Btype, int ldb,
                            float beta,
                            void *C, int Ctype, int ldc);

enum {
    HETGPU_METAL_BUFFER_COPY_IN = 1,
    HETGPU_METAL_BUFFER_COPY_OUT = 2
};

typedef struct HetGpuMetalBufferBinding {
    void *host_ptr;
    size_t size;
    uint32_t flags;
} HetGpuMetalBufferBinding;

typedef int CUresult;
typedef int CUdevice;
typedef void *CUcontext;
typedef void *CUdeviceptr;
typedef void *CUmodule;
typedef void *CUfunction;
typedef void *CUstream;

CUresult cuInit(unsigned int flags);
CUresult cuDriverGetVersion(int *driver_version);
CUresult cuDeviceGetCount(int *count);
CUresult cuDeviceGet(CUdevice *device, int ordinal);
CUresult cuDeviceGetName(char *name, int len, CUdevice device);
CUresult cuDeviceTotalMem_v2(size_t *bytes, CUdevice device);
CUresult cuDeviceGetAttribute(int *value, int attribute, CUdevice device);
CUresult cuCtxCreate_v2(CUcontext *context, unsigned int flags, CUdevice device);
CUresult cuCtxDestroy_v2(CUcontext context);
CUresult cuCtxSetCurrent(CUcontext context);
CUresult cuCtxGetCurrent(CUcontext *context);
CUresult cuCtxSynchronize(void);
CUresult cuMemAlloc_v2(CUdeviceptr *device_ptr, size_t size);
CUresult cuMemFree_v2(CUdeviceptr device_ptr);
CUresult cuMemcpyHtoD_v2(CUdeviceptr dst_device, const void *src_host, size_t size);
CUresult cuMemcpyDtoH_v2(void *dst_host, CUdeviceptr src_device, size_t size);
CUresult cuMemcpyDtoD_v2(CUdeviceptr dst_device, CUdeviceptr src_device, size_t size);
CUresult cuModuleLoadData(CUmodule *module, const void *image);
CUresult cuModuleLoadDataEx(CUmodule *module,
                            const void *image,
                            unsigned int num_options,
                            void *options,
                            void *option_values);
CUresult cuModuleUnload(CUmodule module);
CUresult cuModuleGetFunction(CUfunction *function, CUmodule module, const char *name);
CUresult cuLaunchKernel(CUfunction function,
                        unsigned int grid_dim_x,
                        unsigned int grid_dim_y,
                        unsigned int grid_dim_z,
                        unsigned int block_dim_x,
                        unsigned int block_dim_y,
                        unsigned int block_dim_z,
                        unsigned int shared_mem_bytes,
                        CUstream stream,
                        void **kernel_params,
                        void **extra);

CUresult hetgpu_apple_ptx_register_allocation(void *ptr, size_t size);
CUresult hetgpu_apple_ptx_unregister_allocation(void *ptr);
CUresult hetgpu_apple_ptx_module_load_data(CUmodule *module, const void *image);
CUresult hetgpu_apple_ptx_module_unload(CUmodule module);
CUresult hetgpu_apple_ptx_module_get_function(CUfunction *function,
                                              CUmodule module,
                                              const char *name);
CUresult hetgpu_apple_ptx_function_release(CUfunction function);
CUresult hetgpu_apple_ptx_launch_kernel(CUfunction function,
                                        unsigned int grid_dim_x,
                                        unsigned int grid_dim_y,
                                        unsigned int grid_dim_z,
                                        unsigned int block_dim_x,
                                        unsigned int block_dim_y,
                                        unsigned int block_dim_z,
                                        unsigned int shared_mem_bytes,
                                        CUstream stream,
                                        void **kernel_params,
                                        void **extra);

int hetgpu_apple_metal_compile_msl(const char *source,
                                   const char *label,
                                   void **out_module,
                                   char **out_log);

int hetgpu_apple_metal_get_function(void *module,
                                    const char *name,
                                    void **out_function,
                                    char **out_log);

int hetgpu_apple_metal_launch_raw(void *function,
                                  const HetGpuMetalBufferBinding *buffers,
                                  size_t buffer_count,
                                  uint32_t grid_x,
                                  uint32_t grid_y,
                                  uint32_t grid_z,
                                  uint32_t block_x,
                                  uint32_t block_y,
                                  uint32_t block_z,
                                  char **out_log);

int hetgpu_apple_metal_release_module(void *module);
int hetgpu_apple_metal_release_function(void *function);
void hetgpu_apple_metal_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
