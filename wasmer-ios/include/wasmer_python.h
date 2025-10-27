#ifndef WASMER_PYTHON_H
#define WASMER_PYTHON_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Execute a CPython (WASI/WASIX) WebAssembly module using the embedded Wasmer runtime.
 *
 * This is a convenience wrapper over `wasmer_execute` specialized for Python runtimes.
 * The caller supplies the bytes of a Python WASM runtime (e.g., CPython WASI build)
 * and arguments to pass to it (e.g., "-c", script string, or a .py file path if your
 * runtime supports filesystem access).
 *
 * Typical usage is to ensure argv[0] is "python". If the provided argument vector
 * does not include a program name, many callers prepend "python" to match expectations.
 *
 * @param python_wasm_bytes_ptr Pointer to the Python WASM binary data
 * @param python_wasm_bytes_len Length of the Python WASM binary data
 * @param args_ptr Pointer to array of C string arguments (argv)
 * @param args_len Number of arguments
 * @param stdin_fd File descriptor for stdin (use -1 to inherit default pipe)
 * @param stdout_fd File descriptor for stdout (use -1 to inherit default pipe)
 * @param stderr_fd File descriptor for stderr (use -1 to inherit default pipe)
 * @return Exit code from the Python process (0 for success, negative for errors)
 */
int32_t wasmer_python_execute(
    const uint8_t *python_wasm_bytes_ptr,
    size_t python_wasm_bytes_len,
    const char **args_ptr,
    size_t args_len,
    int32_t stdin_fd,
    int32_t stdout_fd,
    int32_t stderr_fd
);

#ifdef __cplusplus
}
#endif

#endif /* WASMER_PYTHON_H */

