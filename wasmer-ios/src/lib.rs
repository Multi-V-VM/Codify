use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::Path;
use std::slice;
use std::sync::Arc;
use std::os::unix::io::{RawFd, FromRawFd};
use std::io::SeekFrom;
use std::pin::Pin;
use std::task::{Context, Poll};
use wasmer::{Store, Module, Value};
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

fn execute_wasm(
    wasm_bytes: &[u8],
    args: &[String],
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) -> Result<i32, Box<dyn std::error::Error>> {
    // Create a tokio runtime for wasmer-wasix with larger stack size
    // Default stack size may be too small for some WASM programs
    let rt = tokio::runtime::Builder::new_multi_thread()
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

    // Engine selection:
    // - When JIT is possible (RWX pages allowed: simulator, macOS, or a device
    //   with the JIT entitlement) use the Cranelift compiling engine and cache
    //   the compiled artifact for AOT-style instant reloads.
    // - Otherwise fall back to the default interpreter (WAMR via the
    //   "wamr-default" feature), the only App Store-legal option on devices.
    let (mut store, jit_enabled) = create_store();

    // Load the WASM module, going through the AOT cache when compiling
    let module = load_module(&store, wasm_bytes, jit_enabled)?;

    // Get environment variables, applying guest-only overrides
    let guest_home = std::env::var("WASM_GUEST_HOME").ok();
    let env_vars: Vec<(String, String)> = std::env::vars()
        .map(|(key, value)| {
            if key == "HOME" {
                if let Some(home) = &guest_home {
                    return (key, home.clone());
                }
            }
            (key, value)
        })
        .collect();

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

    // --- Sysroot ---

    // Preopen host directories listed in WASM_PREOPENS (colon-separated);
    // the guest sees them under their host paths, so absolute paths into the
    // app sandbox resolve.
    if let Ok(preopens) = std::env::var("WASM_PREOPENS") {
        for dir in preopens.split(':') {
            if !dir.is_empty() && Path::new(dir).is_dir() {
                wasi_env_builder = wasi_env_builder.preopen_dir(dir)?;
            }
        }
    }

    // Map standard Unix locations onto host sysroot directories.
    // WASM_MAP_DIRS is ;-separated "guest::host" pairs. The host must not
    // request guest paths the wasix root fs pre-creates (/etc, /home): the
    // mount fails with "file exists" and aborts the run.
    if let Ok(map_dirs) = std::env::var("WASM_MAP_DIRS") {
        for pair in map_dirs.split(';') {
            if let Some((guest, host)) = pair.split_once("::") {
                if !guest.is_empty() && Path::new(host).is_dir() {
                    wasi_env_builder = wasi_env_builder.map_dir(guest, host)?;
                }
            }
        }
    }

    // Start the guest in the host working directory so relative paths behave
    // like a normal binary launched from the shell.
    if let Ok(cwd) = std::env::var("WASM_CWD") {
        if Path::new(&cwd).is_dir() {
            wasi_env_builder = wasi_env_builder.current_dir(cwd);
        }
    }

    // Use the high-level instantiate() which handles:
    // - Memory creation for imported memories (e.g., env.memory)
    // - Import generation for ALL WASI/WASIX versions the module needs
    //   (import_object() only generates for a single detected version,
    //    missing wasix_32v1 functions like fd_dup)
    // - Proper WasiEnv initialization
    let (instance, _wasi_env) = wasi_env_builder.instantiate(module.clone(), &mut store)
        .map_err(|e| format!("Failed to instantiate WASI module: {}", e))?;

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

/// Whether the process can map writable+executable pages. True on the
/// simulator, macOS, and devices running with the JIT entitlement; false on
/// normal iOS devices, where only the interpreter is allowed.
fn jit_available() -> bool {
    unsafe {
        let page = libc::mmap(
            std::ptr::null_mut(),
            4096,
            libc::PROT_READ | libc::PROT_WRITE | libc::PROT_EXEC,
            libc::MAP_PRIVATE | libc::MAP_ANON,
            -1,
            0,
        );
        if page == libc::MAP_FAILED {
            return false;
        }
        libc::munmap(page, 4096);
        true
    }
}

/// Pick the execution engine. Returns the store and whether a compiling
/// (JIT-capable) engine was selected, which also enables the AOT cache.
fn create_store() -> (Store, bool) {
    if std::env::var_os("WASM_FORCE_INTERPRETER").is_some() {
        return (Store::default(), false);
    }

    #[cfg(feature = "cranelift")]
    {
        if jit_available() {
            use wasmer::sys::{Cranelift, EngineBuilder};
            let engine = EngineBuilder::new(Cranelift::default()).engine();
            return (Store::new(engine), true);
        }
    }

    (Store::default(), false)
}

/// FNV-1a 64-bit hash, used to key AOT cache artifacts by module content.
fn hash_bytes(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &byte in bytes {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Load a module. With a compiling engine, compiled artifacts are cached in
/// WASM_AOT_CACHE so subsequent runs deserialize the native code (AOT) instead
/// of recompiling. Cache failures fall back to a fresh compile; deserializing
/// is only attempted on artifacts this runtime wrote itself.
fn load_module(
    store: &Store,
    wasm_bytes: &[u8],
    jit_enabled: bool,
) -> Result<Module, Box<dyn std::error::Error>> {
    if jit_enabled {
        if let Ok(cache_dir) = std::env::var("WASM_AOT_CACHE") {
            let cache_path = Path::new(&cache_dir).join(format!(
                "{:016x}-{}.wasmu",
                hash_bytes(wasm_bytes),
                wasm_bytes.len()
            ));

            if cache_path.is_file() {
                // SAFETY: the artifact was serialized by this same runtime for
                // an identical module (content-hash keyed).
                match unsafe { Module::deserialize_from_file(store, &cache_path) } {
                    Ok(module) => return Ok(module),
                    Err(_) => {
                        // Stale or corrupt artifact (e.g. runtime upgrade):
                        // drop it and recompile.
                        let _ = std::fs::remove_file(&cache_path);
                    }
                }
            }

            let module = Module::new(store, wasm_bytes)?;
            if let Ok(serialized) = module.serialize() {
                let _ = std::fs::create_dir_all(&cache_dir);
                let _ = std::fs::write(&cache_path, serialized);
            }
            return Ok(module);
        }
    }

    Ok(Module::new(store, wasm_bytes)?)
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
