#ifndef WASMER_IOS_H
#define WASMER_IOS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Execute a WebAssembly module with WASIX p1 support.
 *
 * @param wasm_bytes_ptr Pointer to the WASM binary data
 * @param wasm_bytes_len Length of the WASM binary data
 * @param args_ptr Pointer to array of C string arguments
 * @param args_len Number of arguments
 * @param stdin_fd File descriptor for stdin (use -1 for default)
 * @param stdout_fd File descriptor for stdout (use -1 for default)
 * @param stderr_fd File descriptor for stderr (use -1 for default)
 * @return Exit code from the WASM program (0 for success, negative for errors)
 */
int32_t wasmer_execute(
    const uint8_t *wasm_bytes_ptr,
    size_t wasm_bytes_len,
    const char **args_ptr,
    size_t args_len,
    int32_t stdin_fd,
    int32_t stdout_fd,
    int32_t stderr_fd
);

/**
 * Get version information about the Wasmer runtime.
 *
 * @return A C string containing version information
 */
const char* wasmer_version(void);

#ifdef __cplusplus
}
#endif

#endif /* WASMER_IOS_H */
