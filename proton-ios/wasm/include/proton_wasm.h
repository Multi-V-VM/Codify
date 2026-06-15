#ifndef PROTON_WASM_H
#define PROTON_WASM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum proton_wasm_status {
    PROTON_WASM_OK = 0,
    PROTON_WASM_ERROR_NOT_INITIALIZED = 1,
    PROTON_WASM_ERROR_INVALID_ARGUMENT = 2,
    PROTON_WASM_ERROR_UNSUPPORTED = 3
} proton_wasm_status_t;

typedef enum proton_wasm_gpu_backend {
    PROTON_WASM_GPU_DISABLED = 0,
    PROTON_WASM_GPU_HETGPU = 1
} proton_wasm_gpu_backend_t;

int proton_wasm_abi_version(void);
int proton_wasm_initialize(const char *runtime_root, const char *prefix_root);
int proton_wasm_configure_gpu(proton_wasm_gpu_backend_t backend, const char *device_hint);
proton_wasm_gpu_backend_t proton_wasm_gpu_backend(void);
const char *proton_wasm_gpu_backend_name(void);
const char *proton_wasm_gpu_device_hint(void);
int proton_wasm_run(const char *exe_path, int argc, const char * const *argv);
void proton_wasm_shutdown(void);
const char *proton_wasm_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
