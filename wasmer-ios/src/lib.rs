use std::ffi::CStr;
use std::os::raw::c_char;
use std::slice;
use std::sync::Arc;
use std::os::unix::io::{RawFd, FromRawFd};
use std::io::SeekFrom;
use std::pin::Pin;
use std::task::{Context, Poll};
use wasmer::{Store, Module, Instance, Value};
use wasmer_wasix::{WasiEnvBuilder, PluggableRuntime};
use wasmer_wasix::runtime::task_manager::tokio::TokioTaskManager;
use wasmer_wasix::virtual_fs::{VirtualFile, FsError};
use tokio::io::{AsyncRead, AsyncWrite, AsyncSeek, ReadBuf};

// Custom VirtualFile implementation that wraps a file descriptor
#[derive(Debug)]
struct FdFile {
    #[allow(dead_code)]
    fd: RawFd,
    file: tokio::fs::File,
}

impl FdFile {
    /// Create a new FdFile by duplicating the given file descriptor
    fn new(fd: RawFd) -> std::io::Result<Self> {
        // Duplicate the file descriptor so we don't close the original
        let dup_fd = unsafe { libc::dup(fd) };
        if dup_fd < 0 {
            return Err(std::io::Error::last_os_error());
        }

        // Create tokio File from the duplicated fd
        let std_file = unsafe { std::fs::File::from_raw_fd(dup_fd) };
        let file = tokio::fs::File::from_std(std_file);

        Ok(Self { fd: dup_fd, file })
    }
}

impl VirtualFile for FdFile {
    fn last_accessed(&self) -> u64 {
        0 // Not implemented for FDs
    }

    fn last_modified(&self) -> u64 {
        0 // Not implemented for FDs
    }

    fn created_time(&self) -> u64 {
        0 // Not implemented for FDs
    }

    fn size(&self) -> u64 {
        0 // Unknown size for FDs
    }

    fn set_len(&mut self, _new_size: u64) -> Result<(), FsError> {
        Err(FsError::PermissionDenied)
    }

    fn unlink(&mut self) -> Result<(), FsError> {
        Ok(()) // No-op for FDs
    }

    fn poll_read_ready(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<usize>> {
        std::task::Poll::Ready(Ok(1))
    }

    fn poll_write_ready(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<usize>> {
        std::task::Poll::Ready(Ok(1))
    }
}

impl AsyncRead for FdFile {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.file).poll_read(cx, buf)
    }
}

impl AsyncWrite for FdFile {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.file).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.file).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.file).poll_shutdown(cx)
    }
}

impl AsyncSeek for FdFile {
    fn start_seek(mut self: Pin<&mut Self>, position: SeekFrom) -> std::io::Result<()> {
        Pin::new(&mut self.file).start_seek(position)
    }

    fn poll_complete(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<u64>> {
        Pin::new(&mut self.file).poll_complete(cx)
    }
}

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

/// Convenience entrypoint to execute a CPython WASM runtime using Wasmer.
/// This simply forwards to `wasmer_execute` and exists to provide a stable
/// symbol tailored for Python integrations on iOS.
#[no_mangle]
pub extern "C" fn wasmer_python_execute(
    python_wasm_bytes_ptr: *const u8,
    python_wasm_bytes_len: usize,
    args_ptr: *const *const c_char,
    args_len: usize,
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) -> i32 {
    wasmer_execute(
        python_wasm_bytes_ptr,
        python_wasm_bytes_len,
        args_ptr,
        args_len,
        stdin_fd,
        stdout_fd,
        stderr_fd,
    )
}

fn execute_wasm(
    wasm_bytes: &[u8],
    args: &[String],
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) -> Result<i32, Box<dyn std::error::Error>> {
    // Create a tokio runtime for wasmer-wasix with larger stack size
    // Default stack size may be too small for some WASM programs
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .thread_stack_size(8 * 1024 * 1024) // 8MB stack (increased from default ~2MB)
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
    // Validate WASM binary first
    if wasm_bytes.len() < 8 {
        return Err("Invalid WASM binary: too small".into());
    }

    // Check WASM magic number (0x00 0x61 0x73 0x6D)
    if &wasm_bytes[0..4] != &[0x00, 0x61, 0x73, 0x6D] {
        return Err("Invalid WASM binary: missing magic number".into());
    }

    // Check WASM version (should be 1)
    if &wasm_bytes[4..8] != &[0x01, 0x00, 0x00, 0x00] {
        return Err("Invalid WASM binary: unsupported version".into());
    }

    // Create a WAMR store (interpreter-only, no JIT)
    // WAMR is set as the default backend via the "wamr-default" feature
    // This provides both validation and execution using the WAMR interpreter
    let mut store = Store::default();

    // Load the WASM module using WAMR interpreter
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

    // Map file descriptors using custom FdFile implementation
    // Each FD is duplicated to avoid closing the original
    if stdin_fd >= 0 {
        if let Ok(stdin) = FdFile::new(stdin_fd) {
            wasi_env_builder = wasi_env_builder.stdin(Box::new(stdin));
        }
    }

    if stdout_fd >= 0 {
        if let Ok(stdout) = FdFile::new(stdout_fd) {
            wasi_env_builder = wasi_env_builder.stdout(Box::new(stdout));
        }
    }

    if stderr_fd >= 0 {
        if let Ok(stderr) = FdFile::new(stderr_fd) {
            wasi_env_builder = wasi_env_builder.stderr(Box::new(stderr));
        }
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
                    // Print detailed error information for debugging
                    eprintln!("wasmer-ios: Error calling _start");
                    eprintln!("  Error: {}", e);
                    eprintln!("  Error type: {:?}", e);

                    // Check for trap information
                    let trace = e.trace();
                    if !trace.is_empty() {
                        eprintln!("  Stack trace:");
                        for frame in trace {
                            eprintln!("    {:?}", frame);
                        }
                    }
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
                eprintln!("wasmer-ios: Error calling main");
                eprintln!("  Error: {}", e);
                eprintln!("  Error type: {:?}", e);

                let trace = e.trace();
                if !trace.is_empty() {
                    eprintln!("  Stack trace:");
                    for frame in trace {
                        eprintln!("    {:?}", frame);
                    }
                }
                1
            }
        }
    } else {
        eprintln!("wasmer-ios: No _start or main function found in WASM module");
        eprintln!("  Available exports:");
        for (name, _) in instance.exports.iter() {
            eprintln!("    - {}", name);
        }
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
