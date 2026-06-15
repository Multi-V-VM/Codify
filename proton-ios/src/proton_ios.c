#include "proton_ios.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PROTON_IOS_PATH_MAX 1024

extern int32_t wasmer_execute(
    const uint8_t *wasm_bytes_ptr,
    size_t wasm_bytes_len,
    const char **args_ptr,
    size_t args_len,
    int32_t stdin_fd,
    int32_t stdout_fd,
    int32_t stderr_fd);

static int g_initialized;
static char g_last_error[256];
static char g_runtime_root[PROTON_IOS_PATH_MAX];
static char g_prefix_root[PROTON_IOS_PATH_MAX];
static proton_ios_gpu_backend_t g_gpu_backend = PROTON_IOS_GPU_DISABLED;
static char g_gpu_device_hint[64];

static const char *gpu_backend_name(proton_ios_gpu_backend_t backend)
{
    switch (backend) {
    case PROTON_IOS_GPU_DISABLED:
        return "disabled";
    case PROTON_IOS_GPU_HETGPU:
        return "hetgpu";
    default:
        return "unknown";
    }
}

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

static int set_error(proton_ios_status_t status, const char *message)
{
    copy_cstr(g_last_error, sizeof(g_last_error), message ? message : "unknown error");
    return (int)status;
}

static int set_errno_error(proton_ios_status_t status, const char *prefix, const char *path)
{
    char message[sizeof(g_last_error)];

    snprintf(message, sizeof(message), "%s: %s: %s", prefix, path ? path : "", strerror(errno));
    return set_error(status, message);
}

static int has_suffix(const char *value, const char *suffix)
{
    size_t value_len;
    size_t suffix_len;

    if (!value || !suffix) {
        return 0;
    }

    value_len = strlen(value);
    suffix_len = strlen(suffix);
    return value_len >= suffix_len && strcmp(value + value_len - suffix_len, suffix) == 0;
}

static const char *basename_ptr(const char *path)
{
    const char *slash;

    if (!path || path[0] == '\0') {
        return "";
    }

    slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static int dirname_copy(char *dst, size_t dst_size, const char *path)
{
    const char *slash;
    size_t len;

    if (!path || path[0] == '\0') {
        return 0;
    }

    slash = strrchr(path, '/');
    if (!slash) {
        copy_cstr(dst, dst_size, ".");
        return 1;
    }
    if (slash == path) {
        copy_cstr(dst, dst_size, "/");
        return 1;
    }

    len = (size_t)(slash - path);
    if (len + 1 > dst_size) {
        return 0;
    }
    memcpy(dst, path, len);
    dst[len] = '\0';
    return 1;
}

static int path_join(char *dst, size_t dst_size, const char *lhs, const char *rhs)
{
    size_t lhs_len;

    if (!lhs || !rhs || lhs[0] == '\0' || rhs[0] == '\0') {
        return 0;
    }

    if (rhs[0] == '/') {
        if (strlen(rhs) + 1 > dst_size) {
            return 0;
        }
        copy_cstr(dst, dst_size, rhs);
        return 1;
    }

    lhs_len = strlen(lhs);
    if (lhs_len + 1 + strlen(rhs) + 1 > dst_size) {
        return 0;
    }

    copy_cstr(dst, dst_size, lhs);
    if (lhs_len > 0 && lhs[lhs_len - 1] != '/') {
        append_cstr(dst, dst_size, "/");
    }
    append_cstr(dst, dst_size, rhs);
    return 1;
}

static int stat_path(const char *path, struct stat *st)
{
    return path && path[0] != '\0' && stat(path, st) == 0;
}

static int file_exists(const char *path)
{
    struct stat st;
    return stat_path(path, &st) && S_ISREG(st.st_mode);
}

static int dir_exists(const char *path)
{
    struct stat st;
    return stat_path(path, &st) && S_ISDIR(st.st_mode);
}

static int ensure_dir(const char *path)
{
    char tmp[PROTON_IOS_PATH_MAX];
    char *p;

    if (!path || path[0] == '\0') {
        return 0;
    }
    if (dir_exists(path)) {
        return 1;
    }
    if (strlen(path) + 1 > sizeof(tmp)) {
        errno = ENAMETOOLONG;
        return 0;
    }

    copy_cstr(tmp, sizeof(tmp), path);
    for (p = tmp + 1; *p != '\0'; ++p) {
        if (*p != '/') {
            continue;
        }
        *p = '\0';
        if (tmp[0] != '\0' && !dir_exists(tmp) && mkdir(tmp, 0700) != 0 && errno != EEXIST) {
            *p = '/';
            return 0;
        }
        *p = '/';
    }

    if (mkdir(tmp, 0700) != 0 && errno != EEXIST) {
        return 0;
    }
    return dir_exists(path);
}

static int append_path_list(char *dst, size_t dst_size, const char *path, char separator)
{
    if (!path || path[0] == '\0') {
        return 1;
    }
    if (dst[0] != '\0') {
        char sep[2] = { separator, '\0' };
        append_cstr(dst, dst_size, sep);
    }
    append_cstr(dst, dst_size, path);
    return dst[dst_size - 1] == '\0';
}

static int append_map_dir(char *dst, size_t dst_size, const char *guest, const char *host)
{
    if (!guest || !host || guest[0] == '\0' || host[0] == '\0') {
        return 1;
    }
    if (dst[0] != '\0') {
        append_cstr(dst, dst_size, ";");
    }
    append_cstr(dst, dst_size, guest);
    append_cstr(dst, dst_size, "::");
    append_cstr(dst, dst_size, host);
    return dst[dst_size - 1] == '\0';
}

static void prepend_env_path(const char *name, const char *value)
{
    char next[PROTON_IOS_PATH_MAX * 2];
    const char *current;

    if (!value || value[0] == '\0') {
        return;
    }

    current = getenv(name);
    copy_cstr(next, sizeof(next), value);
    if (current && current[0] != '\0') {
        append_cstr(next, sizeof(next), ":");
        append_cstr(next, sizeof(next), current);
    }
    setenv(name, next, 1);
}

static int resolve_wine_module(char *module_path, size_t module_path_size, const char *exe_path, int *direct_wasm)
{
    const char *candidates[] = {
        "loader/wine",
        "wine",
        "wine.wasm",
    };
    size_t i;

    *direct_wasm = 0;
    if (has_suffix(exe_path, ".wasm") && file_exists(exe_path)) {
        copy_cstr(module_path, module_path_size, exe_path);
        *direct_wasm = 1;
        return 1;
    }

    if (file_exists(g_runtime_root)) {
        copy_cstr(module_path, module_path_size, g_runtime_root);
        *direct_wasm = has_suffix(g_runtime_root, ".wasm");
        return 1;
    }

    for (i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        if (!path_join(module_path, module_path_size, g_runtime_root, candidates[i])) {
            continue;
        }
        if (file_exists(module_path)) {
            return 1;
        }
    }

    return 0;
}

static int load_file(const char *path, uint8_t **bytes, size_t *len)
{
    FILE *file;
    long size;
    uint8_t *buffer;

    *bytes = NULL;
    *len = 0;

    file = fopen(path, "rb");
    if (!file) {
        return 0;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return 0;
    }
    size = ftell(file);
    if (size < 0) {
        fclose(file);
        return 0;
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return 0;
    }

    buffer = (uint8_t *)malloc((size_t)size);
    if (!buffer) {
        fclose(file);
        errno = ENOMEM;
        return 0;
    }
    if (size > 0 && fread(buffer, 1, (size_t)size, file) != (size_t)size) {
        free(buffer);
        fclose(file);
        return 0;
    }
    fclose(file);

    *bytes = buffer;
    *len = (size_t)size;
    return 1;
}

static void configure_gpu_env(void)
{
    const char *backend = "metal";
    char runtime_gpu_root[PROTON_IOS_PATH_MAX];

    if (g_gpu_backend != PROTON_IOS_GPU_HETGPU) {
        setenv("PROTON_WASM_GPU_BACKEND", "disabled", 1);
        unsetenv("WASM_CUDA_ACCEL");
        unsetenv("WASM_CUDA_BACKEND");
        unsetenv("HETGPU_APPLE_BACKEND");
        unsetenv("CODIFYONE_HETGPU_ROOT");
        return;
    }

    if (strcmp(g_gpu_device_hint, "ane") == 0 || strcmp(g_gpu_device_hint, "metal") == 0) {
        backend = g_gpu_device_hint;
    }

    setenv("PROTON_WASM_GPU_BACKEND", "hetgpu", 1);
    setenv("WASM_CUDA_ACCEL", "1", 1);
    setenv("WASM_CUDA_BACKEND", backend, 1);
    setenv("HETGPU_APPLE_BACKEND", backend, 1);

    if (g_gpu_device_hint[0] == '/') {
        setenv("CODIFYONE_HETGPU_ROOT", g_gpu_device_hint, 1);
        prepend_env_path("LD_LIBRARY_PATH", g_gpu_device_hint);
        prepend_env_path("DYLD_LIBRARY_PATH", g_gpu_device_hint);
        prepend_env_path("DYLD_FALLBACK_LIBRARY_PATH", g_gpu_device_hint);
    } else if (path_join(runtime_gpu_root, sizeof(runtime_gpu_root), g_runtime_root, "hetgpu") &&
               dir_exists(runtime_gpu_root)) {
        setenv("CODIFYONE_HETGPU_ROOT", runtime_gpu_root, 1);
        prepend_env_path("LD_LIBRARY_PATH", runtime_gpu_root);
        prepend_env_path("DYLD_LIBRARY_PATH", runtime_gpu_root);
        prepend_env_path("DYLD_FALLBACK_LIBRARY_PATH", runtime_gpu_root);
    }
}

static int configure_wasm_env(const char *module_path, const char *exe_path, char *guest_exe_path,
                              size_t guest_exe_path_size, int direct_wasm)
{
    char preopens[PROTON_IOS_PATH_MAX * 4] = "";
    char map_dirs[PROTON_IOS_PATH_MAX * 4] = "";
    char exe_dir[PROTON_IOS_PATH_MAX] = "";
    char dll_path[PROTON_IOS_PATH_MAX] = "";
    char aot_cache[PROTON_IOS_PATH_MAX] = "";

    if (!ensure_dir(g_prefix_root)) {
        return set_errno_error(PROTON_IOS_ERROR_RUNTIME, "failed to create prefix_root", g_prefix_root);
    }

    if (path_join(aot_cache, sizeof(aot_cache), g_prefix_root, "wasmer-aot")) {
        (void)ensure_dir(aot_cache);
        setenv("WASM_AOT_CACHE", aot_cache, 1);
    }

    setenv("PROTON_IOS_RUNTIME_ROOT", g_runtime_root, 1);
    setenv("PROTON_IOS_PREFIX_ROOT", g_prefix_root, 1);
    setenv("PROTON_WASM_RUNTIME_ROOT", g_runtime_root, 1);
    setenv("PROTON_WASM_PREFIX_ROOT", g_prefix_root, 1);
    setenv("WINEPREFIX", "/wineprefix", 1);
    setenv("WASM_GUEST_HOME", "/wineprefix", 1);
    setenv("HOME", g_prefix_root, 0);

    if (path_join(dll_path, sizeof(dll_path), "/proton", "dlls")) {
        setenv("WINEDLLPATH", dll_path, 1);
    }
    setenv("WINELOADER", "/proton/loader/wine", 1);

    append_path_list(preopens, sizeof(preopens), g_runtime_root, ':');
    append_path_list(preopens, sizeof(preopens), g_prefix_root, ':');

    append_map_dir(map_dirs, sizeof(map_dirs), "/proton", g_runtime_root);
    append_map_dir(map_dirs, sizeof(map_dirs), "/wineprefix", g_prefix_root);

    copy_cstr(guest_exe_path, guest_exe_path_size, exe_path);
    if (!direct_wasm && dirname_copy(exe_dir, sizeof(exe_dir), exe_path) && dir_exists(exe_dir)) {
        append_path_list(preopens, sizeof(preopens), exe_dir, ':');
        append_map_dir(map_dirs, sizeof(map_dirs), "/workspace", exe_dir);

        copy_cstr(guest_exe_path, guest_exe_path_size, "/workspace/");
        append_cstr(guest_exe_path, guest_exe_path_size, basename_ptr(exe_path));
        setenv("WASM_CWD", "/workspace", 1);
        setenv("PWD", "/workspace", 1);
    } else if (direct_wasm && dirname_copy(exe_dir, sizeof(exe_dir), module_path) && dir_exists(exe_dir)) {
        append_path_list(preopens, sizeof(preopens), exe_dir, ':');
        setenv("WASM_CWD", exe_dir, 1);
        setenv("PWD", exe_dir, 1);
    } else {
        setenv("WASM_CWD", "/wineprefix", 1);
        setenv("PWD", "/wineprefix", 1);
    }

    setenv("WASM_PREOPENS", preopens, 1);
    setenv("WASM_MAP_DIRS", map_dirs, 1);
    configure_gpu_env();
    return PROTON_IOS_OK;
}

int proton_ios_initialize(const char *runtime_root, const char *prefix_root)
{
    if (runtime_root == NULL || runtime_root[0] == '\0') {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "runtime_root is required");
    }

    if (prefix_root == NULL || prefix_root[0] == '\0') {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "prefix_root is required");
    }

    copy_cstr(g_runtime_root, sizeof(g_runtime_root), runtime_root);
    copy_cstr(g_prefix_root, sizeof(g_prefix_root), prefix_root);
    g_initialized = 1;
    g_last_error[0] = '\0';
    return PROTON_IOS_OK;
}

int proton_ios_configure_gpu(proton_ios_gpu_backend_t backend, const char *device_hint)
{
    switch (backend) {
    case PROTON_IOS_GPU_DISABLED:
    case PROTON_IOS_GPU_HETGPU:
        break;
    default:
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "unsupported GPU backend");
    }

    g_gpu_backend = backend;
    copy_cstr(g_gpu_device_hint, sizeof(g_gpu_device_hint), device_hint);
    g_last_error[0] = '\0';
    return PROTON_IOS_OK;
}

proton_ios_gpu_backend_t proton_ios_gpu_backend(void)
{
    return g_gpu_backend;
}

const char *proton_ios_gpu_backend_name(void)
{
    return gpu_backend_name(g_gpu_backend);
}

const char *proton_ios_gpu_device_hint(void)
{
    return g_gpu_device_hint;
}

int proton_ios_run(const char *exe_path, int argc, const char * const *argv)
{
    char module_path[PROTON_IOS_PATH_MAX];
    char guest_exe_path[PROTON_IOS_PATH_MAX];
    const char **wasm_argv;
    uint8_t *wasm_bytes;
    size_t wasm_len;
    size_t wasm_argc;
    int direct_wasm;
    int32_t result;
    int i;

    if (!g_initialized) {
        return set_error(PROTON_IOS_ERROR_NOT_INITIALIZED, "proton_ios_initialize must be called first");
    }
    if (exe_path == NULL || exe_path[0] == '\0') {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "exe_path is required");
    }
    if (argc < 0) {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "argc must be non-negative");
    }
    if (argc > 0 && argv == NULL) {
        return set_error(PROTON_IOS_ERROR_INVALID_ARGUMENT, "argv is required when argc is non-zero");
    }
    if (!resolve_wine_module(module_path, sizeof(module_path), exe_path, &direct_wasm)) {
        return set_error(PROTON_IOS_ERROR_RUNTIME, "failed to find Wine WASM loader under runtime_root");
    }
    if (!load_file(module_path, &wasm_bytes, &wasm_len)) {
        return set_errno_error(PROTON_IOS_ERROR_RUNTIME, "failed to read WASM module", module_path);
    }

    result = configure_wasm_env(module_path, exe_path, guest_exe_path, sizeof(guest_exe_path), direct_wasm);
    if (result != PROTON_IOS_OK) {
        free(wasm_bytes);
        return result;
    }

    wasm_argc = (size_t)argc + (direct_wasm ? 1u : 2u);
    wasm_argv = (const char **)calloc(wasm_argc + 1, sizeof(*wasm_argv));
    if (!wasm_argv) {
        free(wasm_bytes);
        return set_error(PROTON_IOS_ERROR_RUNTIME, "failed to allocate WASM argv");
    }

    if (direct_wasm) {
        wasm_argv[0] = basename_ptr(module_path);
        for (i = 0; i < argc; ++i) {
            wasm_argv[(size_t)i + 1] = argv[i];
        }
    } else {
        wasm_argv[0] = "wine";
        wasm_argv[1] = guest_exe_path;
        for (i = 0; i < argc; ++i) {
            wasm_argv[(size_t)i + 2] = argv[i];
        }
    }

    result = wasmer_execute(wasm_bytes, wasm_len, wasm_argv, wasm_argc, STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO);

    free(wasm_argv);
    free(wasm_bytes);

    if (result < 0) {
        return set_error(PROTON_IOS_ERROR_RUNTIME, "wasmer_execute failed");
    }

    g_last_error[0] = '\0';
    return result;
}

void proton_ios_shutdown(void)
{
    g_initialized = 0;
    g_runtime_root[0] = '\0';
    g_prefix_root[0] = '\0';
    g_last_error[0] = '\0';
    g_gpu_backend = PROTON_IOS_GPU_DISABLED;
    g_gpu_device_hint[0] = '\0';
}

const char *proton_ios_last_error(void)
{
    if (g_last_error[0] == '\0') {
        return "";
    }

    return g_last_error;
}
