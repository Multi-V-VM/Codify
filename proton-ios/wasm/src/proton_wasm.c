#include "proton_wasm.h"

#include <stddef.h>

#define PROTON_WASM_ABI_VERSION 1

static int g_initialized;
static char g_last_error[256];
static char g_runtime_root[1024];
static char g_prefix_root[1024];
static proton_wasm_gpu_backend_t g_gpu_backend = PROTON_WASM_GPU_DISABLED;
static char g_gpu_device_hint[64];

static const char *gpu_backend_name(proton_wasm_gpu_backend_t backend);

static void copy_cstr(char *dst, size_t dst_size, const char *src)
{
    size_t i;

    if (dst_size == 0) {
        return;
    }

    if (src == NULL) {
        src = "";
    }

    for (i = 0; i + 1 < dst_size && src[i] != '\0'; ++i) {
        dst[i] = src[i];
    }
    dst[i] = '\0';
}

static void append_cstr(char *dst, size_t dst_size, const char *src)
{
    size_t len = 0;

    if (dst_size == 0) {
        return;
    }

    while (len < dst_size && dst[len] != '\0') {
        ++len;
    }

    if (len >= dst_size) {
        dst[dst_size - 1] = '\0';
        return;
    }

    copy_cstr(dst + len, dst_size - len, src);
}

static int set_error(proton_wasm_status_t status, const char *message)
{
    if (message == NULL) {
        message = "unknown error";
    }

    copy_cstr(g_last_error, sizeof(g_last_error), message);
    return (int)status;
}

static int set_run_unsupported_error(void)
{
    copy_cstr(
        g_last_error,
        sizeof(g_last_error),
        "Wine execution is not wired into the WASM CPU bridge yet; CPU target=WASI GPU backend=");
    append_cstr(g_last_error, sizeof(g_last_error), gpu_backend_name(g_gpu_backend));

    if (g_gpu_device_hint[0] != '\0') {
        append_cstr(g_last_error, sizeof(g_last_error), " device=");
        append_cstr(g_last_error, sizeof(g_last_error), g_gpu_device_hint);
    }

    return (int)PROTON_WASM_ERROR_UNSUPPORTED;
}

static const char *gpu_backend_name(proton_wasm_gpu_backend_t backend)
{
    switch (backend) {
    case PROTON_WASM_GPU_DISABLED:
        return "disabled";
    case PROTON_WASM_GPU_HETGPU:
        return "hetgpu";
    default:
        return "unknown";
    }
}

int proton_wasm_abi_version(void)
{
    return PROTON_WASM_ABI_VERSION;
}

int proton_wasm_initialize(const char *runtime_root, const char *prefix_root)
{
    if (runtime_root == NULL || runtime_root[0] == '\0') {
        return set_error(PROTON_WASM_ERROR_INVALID_ARGUMENT, "runtime_root is required");
    }

    if (prefix_root == NULL || prefix_root[0] == '\0') {
        return set_error(PROTON_WASM_ERROR_INVALID_ARGUMENT, "prefix_root is required");
    }

    copy_cstr(g_runtime_root, sizeof(g_runtime_root), runtime_root);
    copy_cstr(g_prefix_root, sizeof(g_prefix_root), prefix_root);
    g_initialized = 1;
    g_last_error[0] = '\0';
    return PROTON_WASM_OK;
}

int proton_wasm_configure_gpu(proton_wasm_gpu_backend_t backend, const char *device_hint)
{
    switch (backend) {
    case PROTON_WASM_GPU_DISABLED:
    case PROTON_WASM_GPU_HETGPU:
        break;
    default:
        return set_error(PROTON_WASM_ERROR_INVALID_ARGUMENT, "unsupported GPU backend");
    }

    g_gpu_backend = backend;
    if (device_hint == NULL) {
        g_gpu_device_hint[0] = '\0';
    } else {
        copy_cstr(g_gpu_device_hint, sizeof(g_gpu_device_hint), device_hint);
    }
    g_last_error[0] = '\0';
    return PROTON_WASM_OK;
}

proton_wasm_gpu_backend_t proton_wasm_gpu_backend(void)
{
    return g_gpu_backend;
}

const char *proton_wasm_gpu_backend_name(void)
{
    return gpu_backend_name(g_gpu_backend);
}

const char *proton_wasm_gpu_device_hint(void)
{
    return g_gpu_device_hint;
}

int proton_wasm_run(const char *exe_path, int argc, const char * const *argv)
{
    if (!g_initialized) {
        return set_error(PROTON_WASM_ERROR_NOT_INITIALIZED, "proton_wasm_initialize must be called first");
    }

    if (exe_path == NULL || exe_path[0] == '\0') {
        return set_error(PROTON_WASM_ERROR_INVALID_ARGUMENT, "exe_path is required");
    }

    if (argc < 0) {
        return set_error(PROTON_WASM_ERROR_INVALID_ARGUMENT, "argc must be non-negative");
    }

    if (argc > 0 && argv == NULL) {
        return set_error(PROTON_WASM_ERROR_INVALID_ARGUMENT, "argv is required when argc is non-zero");
    }

    if (g_runtime_root[0] == '\0' || g_prefix_root[0] == '\0') {
        return set_error(PROTON_WASM_ERROR_NOT_INITIALIZED, "runtime roots are not initialized");
    }

    return set_run_unsupported_error();
}

void proton_wasm_shutdown(void)
{
    g_initialized = 0;
    g_runtime_root[0] = '\0';
    g_prefix_root[0] = '\0';
    g_last_error[0] = '\0';
    g_gpu_backend = PROTON_WASM_GPU_DISABLED;
    g_gpu_device_hint[0] = '\0';
}

const char *proton_wasm_last_error(void)
{
    if (g_last_error[0] == '\0') {
        return "";
    }

    return g_last_error;
}
