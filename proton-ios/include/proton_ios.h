#ifndef PROTON_IOS_H
#define PROTON_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum proton_ios_status {
    PROTON_IOS_OK = 0,
    PROTON_IOS_ERROR_NOT_INITIALIZED = 1,
    PROTON_IOS_ERROR_INVALID_ARGUMENT = 2,
    PROTON_IOS_ERROR_UNSUPPORTED = 3,
    PROTON_IOS_ERROR_RUNTIME = 4
} proton_ios_status_t;

typedef enum proton_ios_gpu_backend {
    PROTON_IOS_GPU_DISABLED = 0,
    PROTON_IOS_GPU_HETGPU = 1
} proton_ios_gpu_backend_t;

int proton_ios_initialize(const char *runtime_root, const char *prefix_root);
int proton_ios_configure_gpu(proton_ios_gpu_backend_t backend, const char *device_hint);
proton_ios_gpu_backend_t proton_ios_gpu_backend(void);
const char *proton_ios_gpu_backend_name(void);
const char *proton_ios_gpu_device_hint(void);
int proton_ios_run(const char *exe_path, int argc, const char * const *argv);
void proton_ios_shutdown(void);
const char *proton_ios_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
