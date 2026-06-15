#ifndef PROTON_IOS_H
#define PROTON_IOS_H

#include <stddef.h>
#include <stdint.h>

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

typedef enum proton_ios_display_format {
    PROTON_IOS_DISPLAY_FORMAT_RGBA8 = 1
} proton_ios_display_format_t;

typedef enum proton_ios_input_event_type {
    PROTON_IOS_INPUT_NONE = 0,
    PROTON_IOS_INPUT_POINTER_DOWN = 1,
    PROTON_IOS_INPUT_POINTER_UP = 2,
    PROTON_IOS_INPUT_POINTER_MOVE = 3,
    PROTON_IOS_INPUT_WHEEL = 4,
    PROTON_IOS_INPUT_KEY_DOWN = 5,
    PROTON_IOS_INPUT_KEY_UP = 6
} proton_ios_input_event_type_t;

typedef struct proton_ios_display_frame {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format;
    const uint8_t *data;
    size_t data_len;
    uint64_t frame_id;
} proton_ios_display_frame_t;

typedef void (*proton_ios_display_frame_callback_t)(
    const proton_ios_display_frame_t *frame,
    void *user_data
);

int proton_ios_initialize(const char *runtime_root, const char *prefix_root);
int proton_ios_configure_gpu(proton_ios_gpu_backend_t backend, const char *device_hint);
int proton_ios_set_display_frame_callback(
    proton_ios_display_frame_callback_t callback,
    void *user_data);
int proton_ios_enqueue_input_event(
    proton_ios_input_event_type_t event_type,
    uint32_t code,
    int32_t x,
    int32_t y,
    int32_t value,
    uint32_t modifiers);
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
