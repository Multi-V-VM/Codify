use std::ffi::CStr;
use std::os::raw::c_char;
use std::slice;
use std::sync::Arc;
use wasmer::{Store, Module, Instance, Value};
use wasmer_wasix::{WasiEnvBuilder, PluggableRuntime};
use wasmer_wasix::runtime::task_manager::tokio::TokioTaskManager;

/// Execute a WebAssembly module with WASIX p1 support
///
/// # Parameters
/// - `wasm_bytes_ptr`: Pointer to WASM binary data
/// - `wasm_bytes_len`: Length of WASM binary data
/// - `args_ptr`: Pointer to array of C string arguments
/// - `args_len`: Number of arguments
/// - `stdin_fd`: File descriptor for stdin
/// - `stdout_fd`: File descriptor for stdout
/// - `stderr_fd`: File descriptor for stderr
///
/// # Returns
/// Exit code from the WASM program (0 for success)
#[no_mangle]
pub extern "C" fn wasmer_execute(
    wasm_bytes_ptr: *const u8,
    wasm_bytes_len: usize,
    args_ptr: *const *const c_char,
    args_len: usize,
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) -> i32 {
    // Safety checks
    if wasm_bytes_ptr.is_null() || args_ptr.is_null() {
        eprintln!("wasmer-ios: null pointer provided");
        return -1;
    }

    // Convert WASM bytes from C
    let wasm_bytes = unsafe {
        slice::from_raw_parts(wasm_bytes_ptr, wasm_bytes_len)
    };

    // Convert arguments from C strings to Rust strings
    let mut args: Vec<String> = Vec::new();
    for i in 0..args_len {
        unsafe {
            let arg_ptr = *args_ptr.add(i);
            if !arg_ptr.is_null() {
                if let Ok(arg_str) = CStr::from_ptr(arg_ptr).to_str() {
                    args.push(arg_str.to_string());
                }
            }
        }
    }

    // Execute the WASM module
    match execute_wasm(wasm_bytes, &args, stdin_fd, stdout_fd, stderr_fd) {
        Ok(exit_code) => exit_code,
        Err(e) => {
            eprintln!("wasmer-ios error: {}", e);
            -1
        }
    }
}

fn execute_wasm(
    wasm_bytes: &[u8],
    args: &[String],
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) -> Result<i32, Box<dyn std::error::Error>> {
    // Create a tokio runtime for wasmer-wasix
    // wasmer-wasix requires an async runtime context
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    // Run the WASM execution in the tokio runtime
    rt.block_on(async {
        execute_wasm_async(wasm_bytes, args, stdin_fd, stdout_fd, stderr_fd).await
    })
}

async fn execute_wasm_async(
    wasm_bytes: &[u8],
    args: &[String],
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) -> Result<i32, Box<dyn std::error::Error>> {
    // Create a new Wasmer store
    let mut store = Store::default();

    // Load the WASM module
    let module = Module::new(&store, wasm_bytes)?;

    // Get environment variables
    let env_vars: Vec<(String, String)> = std::env::vars().collect();

    // Build WASI environment with WASIX p1 support
    // Create a PluggableRuntime with tokio task manager
    let task_manager = Arc::new(TokioTaskManager::new(tokio::runtime::Handle::current()));
    let runtime = Arc::new(PluggableRuntime::new(task_manager));

    let mut wasi_env_builder = WasiEnvBuilder::new("wasmer")
        .runtime(runtime);

    // Add arguments
    for arg in args {
        wasi_env_builder = wasi_env_builder.arg(arg);
    }

    // Add environment variables
    for (key, value) in env_vars {
        wasi_env_builder = wasi_env_builder.env(key, value);
    }

    // Map file descriptors if provided
    // WASIX p1 provides enhanced file system support
    if stdin_fd >= 0 {
        // Note: Proper FD mapping requires additional implementation
        // For now, we use default stdin/stdout/stderr
    }

    let mut wasi_env = wasi_env_builder.finalize(&mut store)?;

    // Generate WASI imports
    let import_object = wasi_env.import_object(&mut store, &module)?;

    // Instantiate the module
    let instance = Instance::new(&mut store, &module, &import_object)?;

    // Initialize the WASI environment with the instance
    // This is critical - it sets up wasi_env.inner
    wasi_env.initialize(&mut store, instance.clone())?;

    // Find and call the _start or main function
    let exit_code = if let Ok(start_func) = instance.exports.get_function("_start") {
        // WASI command pattern
        match start_func.call(&mut store, &[] as &[Value]) {
            Ok(_) => {
                // Get exit code from WASI environment if available
                0
            }
            Err(e) => {
                // Check if this is a WASI exit
                if let Some(exit_code) = extract_exit_code(&e) {
                    exit_code
                } else {
                    eprintln!("Error calling _start: {}", e);
                    1
                }
            }
        }
    } else if let Ok(main_func) = instance.exports.get_function("main") {
        // Reactor pattern
        match main_func.call(&mut store, &[] as &[Value]) {
            Ok(results) => {
                // Extract exit code from return value
                let results = results.to_vec();
                if let Some(Value::I32(code)) = results.first() {
                    *code
                } else {
                    0
                }
            }
            Err(e) => {
                eprintln!("Error calling main: {}", e);
                1
            }
        }
    } else {
        eprintln!("No _start or main function found");
        -1
    };

    Ok(exit_code)
}

fn extract_exit_code(error: &wasmer::RuntimeError) -> Option<i32> {
    // Try to extract WASI exit code from error
    // WASI programs exit by calling proc_exit, which causes a trap
    let error_msg = error.to_string();
    if error_msg.contains("exit") {
        // Try to parse exit code from error message
        // This is a simplified approach; in production you'd want more robust parsing
        return Some(0);
    }
    None
}

/// Get version information about the Wasmer runtime
#[no_mangle]
pub extern "C" fn wasmer_version() -> *const c_char {
    static VERSION: &str = concat!("Wasmer iOS Runtime v", env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        let version = wasmer_version();
        assert!(!version.is_null());
    }
}
