use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString};
use std::io::SeekFrom;
use std::os::raw::{c_char, c_void};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncSeek, AsyncWrite, AsyncWriteExt, ReadBuf};
use wasmer_wasix::runtime::task_manager::tokio::TokioTaskManager;
use wasmer_wasix::virtual_fs::{FileSystem, FsError, TmpFileSystem, VirtualFile};
use wasmer_wasix::wasmer::{
    ExternType, Function, FunctionEnv, FunctionEnvMut, Imports, Instance, Memory, Module, Store,
    Type, Value,
};
use wasmer_wasix::{
    PluggableRuntime, WasiEnvBuilder, WasiFunctionEnv, WasiModuleInstanceHandles,
    WasiModuleTreeHandles,
};

pub mod atomic_lowering;

const CUDA_SUCCESS: i32 = 0;
const CUDA_ERROR_INVALID_VALUE: i32 = 1;
const CUDA_ERROR_NOT_SUPPORTED: i32 = 801;
const CUDA_MEMCPY_HOST_TO_HOST: i32 = 0;
const CUDA_MEMCPY_HOST_TO_DEVICE: i32 = 1;
const CUDA_MEMCPY_DEVICE_TO_HOST: i32 = 2;
const CUDA_MEMCPY_DEVICE_TO_DEVICE: i32 = 3;
const CUBLAS_OP_N: i32 = 0;
const HETGPU_CUDA_R_32F: i32 = 0;
const PROTON_WASM_DISPLAY_FORMAT_RGBA8: i32 = 1;
const PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE: i32 = 1;

#[repr(C)]
pub struct WasmerDisplayFrame {
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    data: *const u8,
    data_len: usize,
    frame_id: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WasmerDisplayInputEvent {
    event_type: u32,
    code: u32,
    x: i32,
    y: i32,
    value: i32,
    modifiers: u32,
}

type WasmerDisplayFrameCallback = unsafe extern "C" fn(*const WasmerDisplayFrame, *mut c_void);

#[derive(Clone, Copy)]
struct DisplayCallbackState {
    callback: Option<WasmerDisplayFrameCallback>,
    user_data: usize,
}

static DISPLAY_CALLBACK: Mutex<DisplayCallbackState> = Mutex::new(DisplayCallbackState {
    callback: None,
    user_data: 0,
});
static DISPLAY_INPUT_EVENTS: OnceLock<Mutex<VecDeque<WasmerDisplayInputEvent>>> = OnceLock::new();

fn display_input_events() -> &'static Mutex<VecDeque<WasmerDisplayInputEvent>> {
    DISPLAY_INPUT_EVENTS.get_or_init(|| Mutex::new(VecDeque::new()))
}

type LegacyAppleSgemmFn = unsafe extern "C" fn(
    *const f32,
    *const f32,
    *const f32,
    *mut f32,
    i32,
    i32,
    i32,
    i32,
    i32,
    i32,
    f32,
    f32,
) -> i32;

type HetgpuGemmFn = unsafe extern "C" fn(
    i32,
    i32,
    i32,
    i32,
    i32,
    f32,
    *const c_void,
    i32,
    i32,
    *const c_void,
    i32,
    i32,
    f32,
    *mut c_void,
    i32,
    i32,
) -> i32;

type HostCuModuleLoadDataFn = unsafe extern "C" fn(*mut *mut c_void, *const c_void) -> i32;
type HostCuModuleGetFunctionFn =
    unsafe extern "C" fn(*mut *mut c_void, *mut c_void, *const c_char) -> i32;
type HostCuModuleUnloadFn = unsafe extern "C" fn(*mut c_void) -> i32;
type HostCuLaunchKernelFn = unsafe extern "C" fn(
    *mut c_void,
    u32,
    u32,
    u32,
    u32,
    u32,
    u32,
    u32,
    *mut c_void,
    *mut *mut c_void,
    *mut *mut c_void,
) -> i32;
type HostCuMemAllocFn = unsafe extern "C" fn(*mut *mut c_void, usize) -> i32;
type HostCuMemFreeFn = unsafe extern "C" fn(*mut c_void) -> i32;
type HostCuMemcpyHtoDFn = unsafe extern "C" fn(*mut c_void, *const c_void, usize) -> i32;
type HostCuMemcpyDtoHFn = unsafe extern "C" fn(*mut c_void, *const c_void, usize) -> i32;
type HostCuMemcpyDtoDFn = unsafe extern "C" fn(*mut c_void, *const c_void, usize) -> i32;

#[derive(Debug, Clone)]
struct DeviceAllocation {
    bytes: Vec<u8>,
    host_device_ptr: Option<usize>,
}

#[derive(Debug, Clone)]
struct PtxKernelParam {
    size: usize,
}

#[derive(Debug, Clone)]
struct PtxModule {
    ptx: String,
    host_module: Option<usize>,
}

#[derive(Debug, Clone)]
struct PtxFunction {
    module: u32,
    name: String,
    params: Vec<PtxKernelParam>,
    host_function: Option<usize>,
}

#[derive(Debug)]
struct CudaBridge {
    memory: Option<Memory>,
    allocations: HashMap<u32, DeviceAllocation>,
    next_device_ptr: u32,
    next_cublas_handle: u32,
    next_context_handle: u32,
    next_module_handle: u32,
    modules: HashMap<u32, PtxModule>,
    next_function_handle: u32,
    functions: HashMap<u32, PtxFunction>,
    next_display_frame_id: u64,
}

impl CudaBridge {
    fn new() -> Self {
        Self {
            memory: None,
            allocations: HashMap::new(),
            next_device_ptr: 0x10000,
            next_cublas_handle: 0xc0010000,
            next_context_handle: 0xc7a00000,
            next_module_handle: 0xc0da0000,
            modules: HashMap::new(),
            next_function_handle: 0xf00d0000,
            functions: HashMap::new(),
            next_display_frame_id: 1,
        }
    }

    fn allocate_device_ptr(&mut self, size: usize) -> Option<u32> {
        let ptr = self.next_device_ptr;
        let step = ((size.max(1) + 15) & !15).max(16);
        let step = u32::try_from(step).ok()?;
        self.next_device_ptr = self.next_device_ptr.checked_add(step)?;
        self.allocations.insert(
            ptr,
            DeviceAllocation {
                bytes: vec![0; size],
                host_device_ptr: try_host_mem_alloc(size),
            },
        );
        Some(ptr)
    }

    fn allocate_cublas_handle(&mut self) -> Option<u32> {
        let handle = self.next_cublas_handle;
        self.next_cublas_handle = self.next_cublas_handle.checked_add(1)?;
        Some(handle)
    }

    fn allocate_context_handle(&mut self) -> Option<u32> {
        let handle = self.next_context_handle;
        self.next_context_handle = self.next_context_handle.checked_add(1)?;
        Some(handle)
    }

    fn allocate_module_handle(&mut self, module: PtxModule) -> Option<u32> {
        let handle = self.next_module_handle;
        self.next_module_handle = self.next_module_handle.checked_add(1)?;
        self.modules.insert(handle, module);
        Some(handle)
    }

    fn allocate_function_handle(&mut self, function: PtxFunction) -> Option<u32> {
        let handle = self.next_function_handle;
        self.next_function_handle = self.next_function_handle.checked_add(1)?;
        self.functions.insert(handle, function);
        Some(handle)
    }

    fn allocate_display_frame_id(&mut self) -> u64 {
        let frame_id = self.next_display_frame_id;
        self.next_display_frame_id = self.next_display_frame_id.wrapping_add(1).max(1);
        frame_id
    }
}

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

    fn poll_read_ready(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::task::Poll::Ready(Ok(1))
    }

    fn poll_write_ready(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::task::Poll::Ready(Ok(1))
    }
}

async fn write_embedded_file(
    fs: &TmpFileSystem,
    guest_path: &Path,
    host_path: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let bytes = std::fs::read(host_path)
        .map_err(|e| format!("failed to read embedded file '{}': {}", host_path.display(), e))?;

    if let Some(parent) = guest_path.parent() {
        create_vfs_dir_all(fs, parent)?;
    }

    let mut file = fs
        .new_open_options()
        .write(true)
        .create(true)
        .truncate(true)
        .open(guest_path)
        .map_err(|e| format!("failed to create embedded guest file '{}': {}", guest_path.display(), e))?;
    file.write_all(&bytes).await?;
    file.flush().await?;
    Ok(())
}

fn create_vfs_dir_all(fs: &TmpFileSystem, path: &Path) -> Result<(), FsError> {
    let mut current = PathBuf::from("/");
    for component in path.components() {
        match component {
            std::path::Component::RootDir => continue,
            std::path::Component::Normal(part) => {
                current.push(part);
                match fs.create_dir(&current) {
                    Ok(()) | Err(FsError::AlreadyExists) => {}
                    Err(err) => return Err(err),
                }
            }
            _ => {}
        }
    }
    Ok(())
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
    let wasm_bytes = unsafe { slice::from_raw_parts(wasm_bytes_ptr, wasm_bytes_len) };

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
    // - Otherwise fall back to the default interpreter (Wasmi via the
    //   "wasmi-default" feature), which avoids executable memory on devices.
    let lowered_wasm;
    let wasm_bytes = if module_uses_shared_memory(wasm_bytes) {
        eprintln!("wasmer-ios: lowering shared-memory atomics for single-threaded iOS execution");
        lowered_wasm = atomic_lowering::lower_threads_to_single_thread(wasm_bytes)?;
        lowered_wasm.as_slice()
    } else {
        wasm_bytes
    };
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

    let program_name = args.first().map(String::as_str).unwrap_or("wasmer");
    let mut wasi_env_builder = WasiEnvBuilder::new(program_name).runtime(runtime);

    // Add arguments after argv[0]. WasiEnvBuilder::new() already sets the
    // command name, so adding args[0] again shifts argv and can corrupt WASI
    // startup expectations in libc-built command modules.
    for arg in args.iter().skip(1) {
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
    let uses_embedded_files = std::env::var("WASM_EMBED_FILES")
        .map(|value| !value.is_empty())
        .unwrap_or(false);

    if uses_embedded_files {
        let fs = TmpFileSystem::new();
        let embed_files = std::env::var("WASM_EMBED_FILES")?;
        for pair in embed_files.split(';') {
            if let Some((guest, host)) = pair.split_once("::") {
                if !guest.is_empty() && !host.is_empty() {
                    write_embedded_file(&fs, Path::new(guest), Path::new(host)).await?;
                }
            }
        }
        wasi_env_builder = wasi_env_builder.sandbox_fs(fs);
        wasi_env_builder.preopen_vfs_dirs(vec!["/workspace".to_string()])?;
    }

    // Preopen host directories listed in WASM_PREOPENS (colon-separated);
    // the guest sees them under their host paths, so absolute paths into the
    // app sandbox resolve.
    if !uses_embedded_files {
        if let Ok(preopens) = std::env::var("WASM_PREOPENS") {
            for dir in preopens.split(':') {
                if !dir.is_empty() && Path::new(dir).is_dir() {
                    wasi_env_builder = wasi_env_builder.preopen_dir(dir)?;
                }
            }
        }
    }

    // Map standard Unix locations onto host sysroot directories.
    // WASM_MAP_DIRS is ;-separated "guest::host" pairs. The host must not
    // request guest paths the wasix root fs pre-creates (/etc, /home): the
    // mount fails with "file exists" and aborts the run.
    if !uses_embedded_files {
        if let Ok(map_dirs) = std::env::var("WASM_MAP_DIRS") {
            for pair in map_dirs.split(';') {
                if let Some((guest, host)) = pair.split_once("::") {
                    if !guest.is_empty() && Path::new(host).is_dir() {
                        wasi_env_builder = wasi_env_builder.map_dir(guest, host)?;
                    }
                }
            }
        }
    }

    // Start the guest in a mapped guest directory only. "/" is the guest root,
    // but Path::new("/") is also a valid host path on iOS; passing it through
    // here makes the runtime use the host root as cwd, which is not intended.
    if let Ok(cwd) = std::env::var("WASM_CWD") {
        if cwd != "/" && Path::new(&cwd).is_dir() {
            wasi_env_builder = wasi_env_builder.current_dir(cwd);
        }
    }

    // CUDA/cuBLAS/display-flavored WASM needs host imports in addition to WASI.
    // Normal WASI modules can use the standard instantiation path, but still
    // need an explicit Wasmer-WASIX bootstrap before _start runs.
    let needs_host_imports = module_needs_host_imports(&module);
    eprintln!(
        "wasmer-ios: execution path={}",
        if needs_host_imports {
            "host-import-direct-bootstrap"
        } else {
            "direct-bootstrap"
        }
    );
    let (instance, wasi_env) = if needs_host_imports {
        instantiate_wasi_with_host_imports(wasi_env_builder, module.clone(), &mut store)?
    } else {
        wasi_env_builder
            .instantiate(module.clone(), &mut store)
            .map_err(|e| format!("Failed to instantiate WASI module: {}", e))?
    };

    unsafe { wasi_env.bootstrap(&mut store) }
        .map_err(|e| format!("Failed to bootstrap WASI module: {}", e))?;

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
        let main_type = main_func.ty(&store);
        let main_args = match main_type.params() {
            [] => Vec::new(),
            [Type::I32, Type::I32] => vec![Value::I32(args.len() as i32), Value::I32(0)],
            params => {
                eprintln!(
                    "wasmer-ios: unsupported main signature {:?} -> {:?}",
                    params,
                    main_type.results()
                );
                return Ok(-1);
            }
        };

        match main_func.call(&mut store, &main_args) {
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

fn module_has_cuda_imports(module: &Module) -> bool {
    module.imports().any(|import| {
        import.module() == "env"
            && matches!(
                import.name(),
                "cuInit"
                    | "cuDriverGetVersion"
                    | "cuDeviceGetCount"
                    | "cuDeviceGet"
                    | "cuDeviceGetName"
                    | "cuDeviceTotalMem_v2"
                    | "cuDeviceGetAttribute"
                    | "cuCtxCreate_v2"
                    | "cuCtxDestroy_v2"
                    | "cuCtxSetCurrent"
                    | "cuCtxGetCurrent"
                    | "cuCtxSynchronize"
                    | "cuMemAlloc_v2"
                    | "cuMemFree_v2"
                    | "cuMemcpyHtoD_v2"
                    | "cuMemcpyDtoH_v2"
                    | "cuMemcpyDtoD_v2"
                    | "cuModuleLoadData"
                    | "cuModuleLoadDataEx"
                    | "cuModuleUnload"
                    | "cuModuleGetFunction"
                    | "cuLaunchKernel"
                    | "cuLaunchKernel_ptsz"
                    | "cudaMalloc"
                    | "cudaFree"
                    | "cudaMemcpy"
                    | "cudaDeviceSynchronize"
                    | "cublasCreate_v2"
                    | "cublasDestroy_v2"
                    | "cublasSgemm_v2"
            )
    })
}

fn module_has_display_imports(module: &Module) -> bool {
    module.imports().any(|import| {
        import.module() == "env"
            && matches!(
                import.name(),
                "proton_wasm_display_configure"
                    | "proton_wasm_present_rgba"
                    | "proton_wasm_set_window_title"
                    | "proton_wasm_poll_input_event"
            )
    })
}

fn module_has_rust_codegen_imports(module: &Module) -> bool {
    module.imports().any(|import| {
        import.module() == "env" && import.name() == "codifyone_rust_codegen"
    })
}

fn module_needs_host_imports(module: &Module) -> bool {
    module_has_cuda_imports(module)
        || module_has_display_imports(module)
        || module_has_rust_codegen_imports(module)
        || module_has_imported_memory(module)
}

fn module_has_imported_memory(module: &Module) -> bool {
    module
        .imports()
        .any(|import| matches!(import.ty(), ExternType::Memory(_)))
}

fn instantiate_wasi_with_host_imports(
    wasi_env_builder: WasiEnvBuilder,
    module: Module,
    store: &mut Store,
) -> Result<(Instance, WasiFunctionEnv), Box<dyn std::error::Error>> {
    let mut wasi_env = wasi_env_builder
        .finalize(store)
        .map_err(|e| format!("Failed to finalize WASI environment: {}", e))?;
    let mut imports = wasi_env
        .import_object_for_all_wasi_versions(store, &module)
        .map_err(|e| format!("Failed to create WASI imports: {}", e))?;

    let cuda_env = FunctionEnv::new(store, CudaBridge::new());
    let mut bridge_memory = None;
    for import in module.imports() {
        if let ExternType::Memory(memory_type) = import.ty() {
            let memory = Memory::new(store, *memory_type)
                .map_err(|e| format!(
                    "Failed to allocate imported memory {}.{} ({}): {}",
                    import.module(), import.name(), memory_type, e
                ))?;
            imports.define(import.module(), import.name(), memory.clone());
            if bridge_memory.is_none() {
                bridge_memory = Some(memory);
            }
        }
    }
    // Start sections can call host functions while Instance::new is running,
    // so expose imported memory to the bridge before instantiation.
    cuda_env.as_mut(store).memory = bridge_memory;
    if module_has_cuda_imports(&module) {
        define_cuda_imports(store, &mut imports, &cuda_env);
    }
    if module_has_display_imports(&module) {
        define_display_imports(store, &mut imports, &cuda_env);
    }
    if module_has_rust_codegen_imports(&module) {
        define_rust_codegen_imports(store, &mut imports, &cuda_env);
    }

    let instance = Instance::new(store, &module, &imports)
        .map_err(|e| format!("Failed to instantiate host-import WASI module: {}", e))?;
    if cuda_env.as_ref(store).memory.is_none() {
        let memory = instance
            .exports
            .get_memory("memory")
            .map_err(|e| format!("host-import WASM module must export or import memory: {}", e))?
            .clone();
        cuda_env.as_mut(store).memory = Some(memory);
    }
    let wasi_memory = cuda_env
        .as_ref(store)
        .memory
        .clone()
        .ok_or("host-import WASM module has no linear memory")?;
    wasi_env
        .initialize_handles_and_layout(
            store,
            instance.clone(),
            WasiModuleTreeHandles::Static(WasiModuleInstanceHandles::new(
                wasi_memory,
                store,
                instance.clone(),
                None,
            )),
            None,
            true,
        )
        .map_err(|e| format!("Failed to initialize WASI environment: {}", e))?;

    Ok((instance, wasi_env))
}

fn define_rust_codegen_imports(
    store: &mut Store,
    imports: &mut Imports,
    env: &FunctionEnv<CudaBridge>,
) {
    imports.define(
        "env",
        "codifyone_rust_codegen",
        Function::new_typed_with_env(store, env, codifyone_rust_codegen),
    );
}

fn define_display_imports(store: &mut Store, imports: &mut Imports, env: &FunctionEnv<CudaBridge>) {
    imports.define(
        "env",
        "proton_wasm_display_configure",
        Function::new_typed_with_env(store, env, proton_wasm_display_configure),
    );
    imports.define(
        "env",
        "proton_wasm_present_rgba",
        Function::new_typed_with_env(store, env, proton_wasm_present_rgba),
    );
    imports.define(
        "env",
        "proton_wasm_set_window_title",
        Function::new_typed_with_env(store, env, proton_wasm_set_window_title),
    );
    imports.define(
        "env",
        "proton_wasm_poll_input_event",
        Function::new_typed_with_env(store, env, proton_wasm_poll_input_event),
    );
}

fn define_cuda_imports(store: &mut Store, imports: &mut Imports, env: &FunctionEnv<CudaBridge>) {
    imports.define(
        "env",
        "cuInit",
        Function::new_typed_with_env(store, env, cu_init),
    );
    imports.define(
        "env",
        "cuDriverGetVersion",
        Function::new_typed_with_env(store, env, cu_driver_get_version),
    );
    imports.define(
        "env",
        "cuDeviceGetCount",
        Function::new_typed_with_env(store, env, cu_device_get_count),
    );
    imports.define(
        "env",
        "cuDeviceGet",
        Function::new_typed_with_env(store, env, cu_device_get),
    );
    imports.define(
        "env",
        "cuDeviceGetName",
        Function::new_typed_with_env(store, env, cu_device_get_name),
    );
    imports.define(
        "env",
        "cuDeviceTotalMem_v2",
        Function::new_typed_with_env(store, env, cu_device_total_mem_v2),
    );
    imports.define(
        "env",
        "cuDeviceGetAttribute",
        Function::new_typed_with_env(store, env, cu_device_get_attribute),
    );
    imports.define(
        "env",
        "cuCtxCreate_v2",
        Function::new_typed_with_env(store, env, cu_ctx_create_v2),
    );
    imports.define(
        "env",
        "cuCtxDestroy_v2",
        Function::new_typed_with_env(store, env, cu_ctx_destroy_v2),
    );
    imports.define(
        "env",
        "cuCtxSetCurrent",
        Function::new_typed_with_env(store, env, cu_ctx_set_current),
    );
    imports.define(
        "env",
        "cuCtxGetCurrent",
        Function::new_typed_with_env(store, env, cu_ctx_get_current),
    );
    imports.define(
        "env",
        "cuCtxSynchronize",
        Function::new_typed_with_env(store, env, cu_ctx_synchronize),
    );
    imports.define(
        "env",
        "cuMemAlloc_v2",
        Function::new_typed_with_env(store, env, cu_mem_alloc_v2),
    );
    imports.define(
        "env",
        "cuMemFree_v2",
        Function::new_typed_with_env(store, env, cu_mem_free_v2),
    );
    imports.define(
        "env",
        "cuMemcpyHtoD_v2",
        Function::new_typed_with_env(store, env, cu_memcpy_hto_d_v2),
    );
    imports.define(
        "env",
        "cuMemcpyDtoH_v2",
        Function::new_typed_with_env(store, env, cu_memcpy_dto_h_v2),
    );
    imports.define(
        "env",
        "cuMemcpyDtoD_v2",
        Function::new_typed_with_env(store, env, cu_memcpy_dto_d_v2),
    );
    imports.define(
        "env",
        "cuModuleLoadData",
        Function::new_typed_with_env(store, env, cu_module_load_data),
    );
    imports.define(
        "env",
        "cuModuleLoadDataEx",
        Function::new_typed_with_env(store, env, cu_module_load_data_ex),
    );
    imports.define(
        "env",
        "cuModuleUnload",
        Function::new_typed_with_env(store, env, cu_module_unload),
    );
    imports.define(
        "env",
        "cuModuleGetFunction",
        Function::new_typed_with_env(store, env, cu_module_get_function),
    );
    imports.define(
        "env",
        "cuLaunchKernel",
        Function::new_typed_with_env(store, env, cu_launch_kernel),
    );
    imports.define(
        "env",
        "cuLaunchKernel_ptsz",
        Function::new_typed_with_env(store, env, cu_launch_kernel),
    );
    imports.define(
        "env",
        "cudaMalloc",
        Function::new_typed_with_env(store, env, cuda_malloc),
    );
    imports.define(
        "env",
        "cudaFree",
        Function::new_typed_with_env(store, env, cuda_free),
    );
    imports.define(
        "env",
        "cudaMemcpy",
        Function::new_typed_with_env(store, env, cuda_memcpy),
    );
    imports.define(
        "env",
        "cudaDeviceSynchronize",
        Function::new_typed_with_env(store, env, cuda_device_synchronize),
    );
    imports.define(
        "env",
        "cublasCreate_v2",
        Function::new_typed_with_env(store, env, cublas_create_v2),
    );
    imports.define(
        "env",
        "cublasDestroy_v2",
        Function::new_typed_with_env(store, env, cublas_destroy_v2),
    );
    imports.define(
        "env",
        "cublasSgemm_v2",
        Function::new_typed_with_env(store, env, cublas_sgemm_v2),
    );
}

fn read_guest_memory(
    ctx: &mut FunctionEnvMut<CudaBridge>,
    ptr: i32,
    len: usize,
) -> Option<Vec<u8>> {
    if ptr < 0 {
        return None;
    }
    let memory = ctx.data().memory.clone()?;
    let view = memory.view(&*ctx);
    let mut bytes = vec![0; len];
    view.read(ptr as u64, &mut bytes).ok()?;
    Some(bytes)
}

fn write_guest_memory(ctx: &mut FunctionEnvMut<CudaBridge>, ptr: i32, bytes: &[u8]) -> Option<()> {
    if ptr < 0 {
        return None;
    }
    let memory = ctx.data().memory.clone()?;
    let view = memory.view(&*ctx);
    view.write(ptr as u64, bytes).ok()?;
    Some(())
}

fn write_guest_u32(ctx: &mut FunctionEnvMut<CudaBridge>, ptr: i32, value: u32) -> Option<()> {
    write_guest_memory(ctx, ptr, &value.to_le_bytes())
}

fn read_guest_u32(ctx: &mut FunctionEnvMut<CudaBridge>, ptr: i32) -> Option<u32> {
    let bytes = read_guest_memory(ctx, ptr, 4)?;
    Some(u32::from_le_bytes(bytes.try_into().ok()?))
}

fn read_guest_c_string(
    ctx: &mut FunctionEnvMut<CudaBridge>,
    ptr: i32,
    max_len: usize,
) -> Option<Vec<u8>> {
    if ptr < 0 {
        return None;
    }
    let memory = ctx.data().memory.clone()?;
    let view = memory.view(&*ctx);
    let mut bytes = Vec::new();
    for offset in 0..max_len {
        let mut byte = [0u8; 1];
        view.read((ptr as u64).checked_add(offset as u64)?, &mut byte)
            .ok()?;
        if byte[0] == 0 {
            return Some(bytes);
        }
        bytes.push(byte[0]);
    }
    None
}

type IosSystemFn = unsafe extern "C" fn(*const c_char) -> i32;

fn codifyone_rust_codegen(mut ctx: FunctionEnvMut<CudaBridge>, command_ptr: i32) -> i32 {
    let Some(command) = read_guest_c_string(&mut ctx, command_ptr, 1024 * 1024) else {
        eprintln!("wasmer-ios: invalid rust codegen command pointer");
        return -1;
    };
    let Ok(mut command) = String::from_utf8(command) else {
        eprintln!("wasmer-ios: rust codegen command is not UTF-8");
        return -1;
    };
    if let Ok(host_root) = std::env::var("CODIFYONE_RUST_HOST_ROOT") {
        command = command.replace("/usr/share/codifyone-rust", &host_root);
    }
    if let Ok(host_cwd) = std::env::var("CODIFYONE_WASM_HOST_CWD") {
        command = command.replace("/home/workspace", &host_cwd);
    }
    let Ok(command) = CString::new(command) else {
        eprintln!("wasmer-ios: rust codegen command contains an embedded NUL");
        return -1;
    };
    let Some(symbol) = resolve_symbol(b"ios_system\0") else {
        eprintln!("wasmer-ios: ios_system is unavailable for rust codegen");
        return -1;
    };
    let ios_system = unsafe { std::mem::transmute::<*mut c_void, IosSystemFn>(symbol) };
    eprintln!("wasmer-ios: rust codegen via embedded clang");
    unsafe { ios_system(command.as_ptr()) }
}

fn read_guest_f32(ctx: &mut FunctionEnvMut<CudaBridge>, ptr: i32) -> Option<f32> {
    let bytes = read_guest_memory(ctx, ptr, 4)?;
    Some(f32::from_le_bytes(bytes.try_into().ok()?))
}

fn emit_display_frame(
    data: &[u8],
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    frame_id: u64,
) -> i32 {
    let callback_state = match DISPLAY_CALLBACK.lock() {
        Ok(state) => *state,
        Err(_) => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };

    if let Some(callback) = callback_state.callback {
        let frame = WasmerDisplayFrame {
            width,
            height,
            stride,
            format,
            data: data.as_ptr(),
            data_len: data.len(),
            frame_id,
        };
        unsafe {
            callback(&frame, callback_state.user_data as *mut c_void);
        }
    }

    0
}

fn proton_wasm_display_configure(
    _ctx: FunctionEnvMut<CudaBridge>,
    width: i32,
    height: i32,
    format: i32,
) -> i32 {
    if width <= 0 || height <= 0 || format != PROTON_WASM_DISPLAY_FORMAT_RGBA8 {
        return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE;
    }
    0
}

fn proton_wasm_present_rgba(
    mut ctx: FunctionEnvMut<CudaBridge>,
    data_ptr: i32,
    width: i32,
    height: i32,
    stride: i32,
) -> i32 {
    let width = match checked_positive_i32(width) {
        Some(width) if width > 0 => width,
        _ => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let height = match checked_positive_i32(height) {
        Some(height) if height > 0 => height,
        _ => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let stride = match checked_positive_i32(stride) {
        Some(stride) if stride >= width.saturating_mul(4) => stride,
        _ => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let byte_len = match stride.checked_mul(height) {
        Some(len) if len <= 64 * 1024 * 1024 => len,
        _ => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let bytes = match read_guest_memory(&mut ctx, data_ptr, byte_len) {
        Some(bytes) => bytes,
        None => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let frame_id = ctx.data_mut().allocate_display_frame_id();

    emit_display_frame(
        &bytes,
        width as u32,
        height as u32,
        stride as u32,
        PROTON_WASM_DISPLAY_FORMAT_RGBA8 as u32,
        frame_id,
    )
}

fn proton_wasm_set_window_title(
    mut ctx: FunctionEnvMut<CudaBridge>,
    title_ptr: i32,
    title_len: i32,
) -> i32 {
    let title_len = match checked_positive_i32(title_len) {
        Some(title_len) if title_len <= 4096 => title_len,
        _ => return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let Some(title) = read_guest_memory(&mut ctx, title_ptr, title_len) else {
        return PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE;
    };

    if let Ok(title) = String::from_utf8(title) {
        eprintln!("wasmer-ios: proton display title: {}", title);
    }
    0
}

fn proton_wasm_poll_input_event(
    mut ctx: FunctionEnvMut<CudaBridge>,
    event_ptr: i32,
    event_size: i32,
) -> i32 {
    let event_size = match checked_positive_i32(event_size) {
        Some(size) if size >= std::mem::size_of::<WasmerDisplayInputEvent>() => size,
        _ => return -PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };

    let event = match display_input_events().lock() {
        Ok(mut queue) => queue.pop_front(),
        Err(_) => return -PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE,
    };
    let Some(event) = event else {
        return 0;
    };

    let bytes = unsafe {
        std::slice::from_raw_parts(
            (&event as *const WasmerDisplayInputEvent).cast::<u8>(),
            std::mem::size_of::<WasmerDisplayInputEvent>(),
        )
    };
    if write_guest_memory(&mut ctx, event_ptr, bytes).is_none() {
        return -PROTON_WASM_DISPLAY_ERROR_INVALID_VALUE;
    }
    let _ = event_size;
    1
}

fn device_allocation_bytes(ctx: &FunctionEnvMut<CudaBridge>, ptr: i32) -> Option<Vec<u8>> {
    if ptr < 0 {
        return None;
    }
    ctx.data()
        .allocations
        .get(&(ptr as u32))
        .map(|allocation| allocation.bytes.clone())
}

fn device_allocation_f32s(ctx: &FunctionEnvMut<CudaBridge>, ptr: i32) -> Option<Vec<f32>> {
    let bytes = device_allocation_bytes(ctx, ptr)?;
    if bytes.len() % 4 != 0 {
        return None;
    }

    let mut values = Vec::with_capacity(bytes.len() / 4);
    for chunk in bytes.chunks_exact(4) {
        values.push(f32::from_le_bytes(chunk.try_into().ok()?));
    }
    Some(values)
}

fn f32s_to_bytes(values: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(values.len() * 4);
    for value in values {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    bytes
}

fn resolve_legacy_apple_sgemm(symbol: &[u8]) -> Option<LegacyAppleSgemmFn> {
    let resolved = unsafe { libc::dlsym(libc::RTLD_DEFAULT, symbol.as_ptr() as *const c_char) };
    if resolved.is_null() {
        return None;
    }

    Some(unsafe { std::mem::transmute::<*mut c_void, LegacyAppleSgemmFn>(resolved) })
}

fn resolve_hetgpu_gemm(symbol: &[u8]) -> Option<HetgpuGemmFn> {
    let resolved = unsafe { libc::dlsym(libc::RTLD_DEFAULT, symbol.as_ptr() as *const c_char) };
    if resolved.is_null() {
        return None;
    }

    Some(unsafe { std::mem::transmute::<*mut c_void, HetgpuGemmFn>(resolved) })
}

fn resolve_symbol(symbol: &[u8]) -> Option<*mut c_void> {
    let resolved = unsafe { libc::dlsym(libc::RTLD_DEFAULT, symbol.as_ptr() as *const c_char) };
    if resolved.is_null() {
        None
    } else {
        Some(resolved)
    }
}

fn ptx_host_enabled() -> bool {
    std::env::var("WASM_CUDA_ACCEL").ok().as_deref() == Some("1")
}

fn resolve_host_module_load_data() -> Option<HostCuModuleLoadDataFn> {
    for symbol in [
        b"hetgpu_apple_ptx_module_load_data\0".as_slice(),
        b"cuModuleLoadData\0".as_slice(),
    ] {
        if let Some(resolved) = resolve_symbol(symbol) {
            return Some(unsafe {
                std::mem::transmute::<*mut c_void, HostCuModuleLoadDataFn>(resolved)
            });
        }
    }
    None
}

fn resolve_host_module_get_function() -> Option<HostCuModuleGetFunctionFn> {
    for symbol in [
        b"hetgpu_apple_ptx_module_get_function\0".as_slice(),
        b"cuModuleGetFunction\0".as_slice(),
    ] {
        if let Some(resolved) = resolve_symbol(symbol) {
            return Some(unsafe {
                std::mem::transmute::<*mut c_void, HostCuModuleGetFunctionFn>(resolved)
            });
        }
    }
    None
}

fn resolve_host_module_unload() -> Option<HostCuModuleUnloadFn> {
    for symbol in [
        b"hetgpu_apple_ptx_module_unload\0".as_slice(),
        b"cuModuleUnload\0".as_slice(),
    ] {
        if let Some(resolved) = resolve_symbol(symbol) {
            return Some(unsafe {
                std::mem::transmute::<*mut c_void, HostCuModuleUnloadFn>(resolved)
            });
        }
    }
    None
}

fn resolve_host_launch_kernel() -> Option<HostCuLaunchKernelFn> {
    for symbol in [
        b"hetgpu_apple_ptx_launch_kernel\0".as_slice(),
        b"cuLaunchKernel\0".as_slice(),
    ] {
        if let Some(resolved) = resolve_symbol(symbol) {
            return Some(unsafe {
                std::mem::transmute::<*mut c_void, HostCuLaunchKernelFn>(resolved)
            });
        }
    }
    None
}

fn resolve_host_mem_alloc() -> Option<HostCuMemAllocFn> {
    resolve_symbol(b"cuMemAlloc_v2\0")
        .map(|resolved| unsafe { std::mem::transmute::<*mut c_void, HostCuMemAllocFn>(resolved) })
}

fn resolve_host_mem_free() -> Option<HostCuMemFreeFn> {
    resolve_symbol(b"cuMemFree_v2\0")
        .map(|resolved| unsafe { std::mem::transmute::<*mut c_void, HostCuMemFreeFn>(resolved) })
}

fn resolve_host_memcpy_hto_d() -> Option<HostCuMemcpyHtoDFn> {
    resolve_symbol(b"cuMemcpyHtoD_v2\0")
        .map(|resolved| unsafe { std::mem::transmute::<*mut c_void, HostCuMemcpyHtoDFn>(resolved) })
}

fn resolve_host_memcpy_dto_h() -> Option<HostCuMemcpyDtoHFn> {
    resolve_symbol(b"cuMemcpyDtoH_v2\0")
        .map(|resolved| unsafe { std::mem::transmute::<*mut c_void, HostCuMemcpyDtoHFn>(resolved) })
}

fn resolve_host_memcpy_dto_d() -> Option<HostCuMemcpyDtoDFn> {
    resolve_symbol(b"cuMemcpyDtoD_v2\0")
        .map(|resolved| unsafe { std::mem::transmute::<*mut c_void, HostCuMemcpyDtoDFn>(resolved) })
}

fn try_host_mem_alloc(size: usize) -> Option<usize> {
    if !ptx_host_enabled() {
        return None;
    }
    let alloc = resolve_host_mem_alloc()?;
    let mut host_ptr = ptr::null_mut();
    let rc = unsafe { alloc(&mut host_ptr, size) };
    if rc == CUDA_SUCCESS && !host_ptr.is_null() {
        Some(host_ptr as usize)
    } else {
        None
    }
}

fn try_host_mem_free(ptr_value: usize) {
    if ptr_value == 0 {
        return;
    }
    if let Some(free) = resolve_host_mem_free() {
        unsafe {
            let _ = free(ptr_value as *mut c_void);
        }
    }
}

fn sync_bytes_to_host(allocation: &DeviceAllocation) -> bool {
    let Some(host_device_ptr) = allocation.host_device_ptr else {
        return true;
    };
    let Some(copy) = resolve_host_memcpy_hto_d() else {
        return false;
    };
    let rc = unsafe {
        copy(
            host_device_ptr as *mut c_void,
            allocation.bytes.as_ptr().cast::<c_void>(),
            allocation.bytes.len(),
        )
    };
    rc == CUDA_SUCCESS
}

fn sync_host_to_bytes(allocation: &mut DeviceAllocation) -> bool {
    let Some(host_device_ptr) = allocation.host_device_ptr else {
        return true;
    };
    let Some(copy) = resolve_host_memcpy_dto_h() else {
        return false;
    };
    let rc = unsafe {
        copy(
            allocation.bytes.as_mut_ptr().cast::<c_void>(),
            host_device_ptr as *const c_void,
            allocation.bytes.len(),
        )
    };
    rc == CUDA_SUCCESS
}

fn try_hetgpu_sgemm(
    backend: &str,
    m: i32,
    n: i32,
    k: i32,
    lda: i32,
    ldb: i32,
    ldc: i32,
    alpha: f32,
    a: &[f32],
    b: &[f32],
    beta: f32,
    c: &[f32],
) -> Option<Vec<f32>> {
    let candidates: &[&[u8]] = match backend {
        "ane" => &[
            b"hetgpu_ane_gemm\0",
            b"hetgpu_apple_ane_gemm\0",
            b"hetgpu_apple_metal_gemm\0",
        ],
        "metal" => &[b"hetgpu_apple_metal_gemm\0", b"hetgpu_ane_gemm\0"],
        "hetgpu" => &[
            b"hetgpu_ane_gemm\0",
            b"hetgpu_apple_metal_gemm\0",
            b"hetgpu_apple_ane_gemm\0",
        ],
        _ => return None,
    };

    for candidate in candidates {
        let Some(gemm) = resolve_hetgpu_gemm(candidate) else {
            continue;
        };

        let mut output = c.to_vec();
        let rc = unsafe {
            gemm(
                CUBLAS_OP_N,
                CUBLAS_OP_N,
                m,
                n,
                k,
                alpha,
                a.as_ptr().cast::<c_void>(),
                HETGPU_CUDA_R_32F,
                lda,
                b.as_ptr().cast::<c_void>(),
                HETGPU_CUDA_R_32F,
                ldb,
                beta,
                output.as_mut_ptr().cast::<c_void>(),
                HETGPU_CUDA_R_32F,
                ldc,
            )
        };

        if rc == CUDA_SUCCESS {
            return Some(output);
        }
    }

    None
}

fn try_legacy_apple_sgemm(
    backend: &str,
    m: i32,
    n: i32,
    k: i32,
    lda: i32,
    ldb: i32,
    ldc: i32,
    alpha: f32,
    a: &[f32],
    b: &[f32],
    beta: f32,
    c: &[f32],
) -> Option<Vec<f32>> {
    let candidates: &[&[u8]] = match backend {
        "ane" => &[b"codifyone_ane_sgemm\0", b"codifyone_metal_sgemm\0"],
        "metal" | "hetgpu" => &[b"codifyone_metal_sgemm\0"],
        _ => return None,
    };

    for candidate in candidates {
        let Some(sgemm) = resolve_legacy_apple_sgemm(candidate) else {
            continue;
        };

        let mut output = c.to_vec();
        let rc = unsafe {
            sgemm(
                a.as_ptr(),
                b.as_ptr(),
                c.as_ptr(),
                output.as_mut_ptr(),
                m,
                n,
                k,
                lda,
                ldb,
                ldc,
                alpha,
                beta,
            )
        };

        if rc == CUDA_SUCCESS {
            return Some(output);
        }
    }

    None
}

fn try_apple_sgemm(
    m: usize,
    n: usize,
    k: usize,
    lda: usize,
    ldb: usize,
    ldc: usize,
    alpha: f32,
    a: &[f32],
    b: &[f32],
    beta: f32,
    c: &[f32],
) -> Option<Vec<f32>> {
    if std::env::var("WASM_CUDA_ACCEL").ok().as_deref() != Some("1") {
        return None;
    }

    let m_i32 = i32::try_from(m).ok()?;
    let n_i32 = i32::try_from(n).ok()?;
    let k_i32 = i32::try_from(k).ok()?;
    let lda_i32 = i32::try_from(lda).ok()?;
    let ldb_i32 = i32::try_from(ldb).ok()?;
    let ldc_i32 = i32::try_from(ldc).ok()?;

    let backend = std::env::var("WASM_CUDA_BACKEND").unwrap_or_else(|_| "metal".to_string());
    try_hetgpu_sgemm(
        &backend, m_i32, n_i32, k_i32, lda_i32, ldb_i32, ldc_i32, alpha, a, b, beta, c,
    )
    .or_else(|| {
        try_legacy_apple_sgemm(
            &backend, m_i32, n_i32, k_i32, lda_i32, ldb_i32, ldc_i32, alpha, a, b, beta, c,
        )
    })
}

fn checked_positive_i32(value: i32) -> Option<usize> {
    if value < 0 {
        return None;
    }
    usize::try_from(value).ok()
}

fn ptx_param_decl_size(decl: &str) -> Option<usize> {
    let scalar_size = [
        (".pred", 1usize),
        (".b8", 1),
        (".u8", 1),
        (".s8", 1),
        (".b16", 2),
        (".u16", 2),
        (".s16", 2),
        (".f16", 2),
        (".b32", 4),
        (".u32", 4),
        (".s32", 4),
        (".f32", 4),
        (".b64", 8),
        (".u64", 8),
        (".s64", 8),
        (".f64", 8),
    ]
    .iter()
    .find_map(|(needle, size)| decl.contains(needle).then_some(*size))?;

    let array_len = decl
        .split_once('[')
        .and_then(|(_, tail)| tail.split_once(']'))
        .and_then(|(len, _)| len.trim().parse::<usize>().ok())
        .unwrap_or(1);
    scalar_size.checked_mul(array_len)
}

fn matching_paren_index(text: &str, open_index: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (offset, byte) in text.as_bytes().get(open_index..)?.iter().enumerate() {
        match *byte {
            b'(' => depth = depth.checked_add(1)?,
            b')' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(open_index + offset);
                }
            }
            _ => {}
        }
    }
    None
}

fn parse_ptx_kernel_params(ptx: &str, kernel_name: &str) -> Vec<PtxKernelParam> {
    let mut search_from = 0usize;
    while let Some(entry_rel) = ptx[search_from..].find(".entry") {
        let entry_index = search_from + entry_rel;
        let after_entry = &ptx[entry_index + ".entry".len()..];
        let trimmed = after_entry.trim_start();
        let name_end = trimmed
            .find(|ch: char| ch.is_whitespace() || ch == '(')
            .unwrap_or(trimmed.len());
        let name = &trimmed[..name_end];
        if name == kernel_name {
            let open_rel = trimmed[name_end..].find('(');
            let Some(open_rel) = open_rel else {
                return Vec::new();
            };
            let open_index = entry_index
                + ".entry".len()
                + (after_entry.len() - trimmed.len())
                + name_end
                + open_rel;
            let Some(close_index) = matching_paren_index(ptx, open_index) else {
                return Vec::new();
            };
            return ptx[open_index + 1..close_index]
                .split(',')
                .filter_map(|decl| ptx_param_decl_size(decl).map(|size| PtxKernelParam { size }))
                .collect();
        }
        search_from = entry_index + ".entry".len();
    }
    Vec::new()
}

struct HostKernelParams {
    storage: Vec<Vec<u8>>,
    pointers: Vec<*mut c_void>,
}

impl HostKernelParams {
    fn new() -> Self {
        Self {
            storage: Vec::new(),
            pointers: Vec::new(),
        }
    }

    fn push(&mut self, mut bytes: Vec<u8>) {
        if bytes.is_empty() {
            bytes.push(0);
        }
        self.storage.push(bytes);
        let ptr = self
            .storage
            .last_mut()
            .expect("just pushed kernel parameter")
            .as_mut_ptr()
            .cast::<c_void>();
        self.pointers.push(ptr);
    }
}

fn build_host_kernel_params(
    ctx: &mut FunctionEnvMut<CudaBridge>,
    params: &[PtxKernelParam],
    kernel_params: i32,
) -> Result<HostKernelParams, i32> {
    if params.is_empty() {
        if kernel_params == 0 {
            return Ok(HostKernelParams::new());
        }
        return Err(CUDA_ERROR_NOT_SUPPORTED);
    }
    if kernel_params == 0 {
        return Err(CUDA_ERROR_INVALID_VALUE);
    }

    let mut host_params = HostKernelParams::new();
    for (idx, param) in params.iter().enumerate() {
        let offset = i32::try_from(idx.checked_mul(4).ok_or(CUDA_ERROR_INVALID_VALUE)?)
            .map_err(|_| CUDA_ERROR_INVALID_VALUE)?;
        let slot_ptr_addr = kernel_params
            .checked_add(offset)
            .ok_or(CUDA_ERROR_INVALID_VALUE)?;
        let slot_ptr = read_guest_u32(ctx, slot_ptr_addr).ok_or(CUDA_ERROR_INVALID_VALUE)? as i32;
        if slot_ptr == 0 {
            return Err(CUDA_ERROR_INVALID_VALUE);
        }

        let raw4 = read_guest_memory(ctx, slot_ptr, 4).ok_or(CUDA_ERROR_INVALID_VALUE)?;
        let possible_device_handle = u32::from_le_bytes(
            raw4.as_slice()
                .try_into()
                .map_err(|_| CUDA_ERROR_INVALID_VALUE)?,
        );

        if let Some(allocation) = ctx.data_mut().allocations.get_mut(&possible_device_handle) {
            if !sync_bytes_to_host(allocation) {
                return Err(CUDA_ERROR_NOT_SUPPORTED);
            }
            let host_ptr = allocation
                .host_device_ptr
                .unwrap_or_else(|| allocation.bytes.as_mut_ptr() as usize);
            host_params.push(host_ptr.to_ne_bytes().to_vec());
            continue;
        }

        let size = param.size.clamp(1, 256);
        let mut bytes = read_guest_memory(ctx, slot_ptr, size).ok_or(CUDA_ERROR_INVALID_VALUE)?;
        if bytes.len() < size {
            bytes.resize(size, 0);
        }
        host_params.push(bytes);
    }

    Ok(host_params)
}

fn cu_init(_ctx: FunctionEnvMut<CudaBridge>, _flags: i32) -> i32 {
    CUDA_SUCCESS
}

fn cu_driver_get_version(mut ctx: FunctionEnvMut<CudaBridge>, version_ptr: i32) -> i32 {
    if write_guest_u32(&mut ctx, version_ptr, 12000).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_device_get_count(mut ctx: FunctionEnvMut<CudaBridge>, count_ptr: i32) -> i32 {
    if write_guest_u32(&mut ctx, count_ptr, 1).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_device_get(mut ctx: FunctionEnvMut<CudaBridge>, device_ptr: i32, ordinal: i32) -> i32 {
    if ordinal != 0 {
        return CUDA_ERROR_INVALID_VALUE;
    }
    if write_guest_u32(&mut ctx, device_ptr, 0).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_device_get_name(
    mut ctx: FunctionEnvMut<CudaBridge>,
    name_ptr: i32,
    len: i32,
    _device: i32,
) -> i32 {
    let len = match checked_positive_i32(len) {
        Some(len) if len > 0 => len,
        _ => return CUDA_ERROR_INVALID_VALUE,
    };
    let mut name = b"hetGPU Apple PTX".to_vec();
    if name.len() >= len {
        name.truncate(len.saturating_sub(1));
    }
    name.push(0);
    if write_guest_memory(&mut ctx, name_ptr, &name).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_device_total_mem_v2(
    mut ctx: FunctionEnvMut<CudaBridge>,
    bytes_ptr: i32,
    _device: i32,
) -> i32 {
    if write_guest_u32(&mut ctx, bytes_ptr, 512 * 1024 * 1024).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_device_get_attribute(
    mut ctx: FunctionEnvMut<CudaBridge>,
    value_ptr: i32,
    _attribute: i32,
    _device: i32,
) -> i32 {
    if write_guest_u32(&mut ctx, value_ptr, 1).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_ctx_create_v2(
    mut ctx: FunctionEnvMut<CudaBridge>,
    context_ptr: i32,
    _flags: i32,
    device: i32,
) -> i32 {
    if device != 0 {
        return CUDA_ERROR_INVALID_VALUE;
    }
    let handle = match ctx.data_mut().allocate_context_handle() {
        Some(handle) => handle,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    if write_guest_u32(&mut ctx, context_ptr, handle).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_ctx_destroy_v2(_ctx: FunctionEnvMut<CudaBridge>, _context: i32) -> i32 {
    CUDA_SUCCESS
}

fn cu_ctx_set_current(_ctx: FunctionEnvMut<CudaBridge>, _context: i32) -> i32 {
    CUDA_SUCCESS
}

fn cu_ctx_get_current(mut ctx: FunctionEnvMut<CudaBridge>, context_ptr: i32) -> i32 {
    if write_guest_u32(&mut ctx, context_ptr, 1).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_ctx_synchronize(_ctx: FunctionEnvMut<CudaBridge>) -> i32 {
    CUDA_SUCCESS
}

fn cu_mem_alloc_v2(ctx: FunctionEnvMut<CudaBridge>, device_ptr: i32, bytesize: i32) -> i32 {
    cuda_malloc(ctx, device_ptr, bytesize)
}

fn cu_mem_free_v2(ctx: FunctionEnvMut<CudaBridge>, device_ptr: i32) -> i32 {
    cuda_free(ctx, device_ptr)
}

fn cu_memcpy_hto_d_v2(
    ctx: FunctionEnvMut<CudaBridge>,
    dst_device: i32,
    src_host: i32,
    byte_count: i32,
) -> i32 {
    cuda_memcpy(
        ctx,
        dst_device,
        src_host,
        byte_count,
        CUDA_MEMCPY_HOST_TO_DEVICE,
    )
}

fn cu_memcpy_dto_h_v2(
    ctx: FunctionEnvMut<CudaBridge>,
    dst_host: i32,
    src_device: i32,
    byte_count: i32,
) -> i32 {
    cuda_memcpy(
        ctx,
        dst_host,
        src_device,
        byte_count,
        CUDA_MEMCPY_DEVICE_TO_HOST,
    )
}

fn cu_memcpy_dto_d_v2(
    ctx: FunctionEnvMut<CudaBridge>,
    dst_device: i32,
    src_device: i32,
    byte_count: i32,
) -> i32 {
    cuda_memcpy(
        ctx,
        dst_device,
        src_device,
        byte_count,
        CUDA_MEMCPY_DEVICE_TO_DEVICE,
    )
}

fn cu_module_load_data(
    mut ctx: FunctionEnvMut<CudaBridge>,
    module_ptr: i32,
    image_ptr: i32,
) -> i32 {
    let ptx_bytes = match read_guest_c_string(&mut ctx, image_ptr, 16 * 1024 * 1024) {
        Some(bytes) if !bytes.is_empty() => bytes,
        _ => return CUDA_ERROR_INVALID_VALUE,
    };
    let ptx = String::from_utf8_lossy(&ptx_bytes).into_owned();
    let ptx_c_string = match CString::new(ptx_bytes) {
        Ok(value) => value,
        Err(_) => return CUDA_ERROR_INVALID_VALUE,
    };

    let host_module = if ptx_host_enabled() {
        let Some(load_data) = resolve_host_module_load_data() else {
            return CUDA_ERROR_NOT_SUPPORTED;
        };
        let mut host_module = ptr::null_mut();
        let rc = unsafe { load_data(&mut host_module, ptx_c_string.as_ptr().cast::<c_void>()) };
        if rc != CUDA_SUCCESS {
            return rc;
        }
        if host_module.is_null() {
            return CUDA_ERROR_INVALID_VALUE;
        }
        Some(host_module as usize)
    } else {
        None
    };

    let handle = match ctx
        .data_mut()
        .allocate_module_handle(PtxModule { ptx, host_module })
    {
        Some(handle) => handle,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    if write_guest_u32(&mut ctx, module_ptr, handle).is_none() {
        if let Some(module) = ctx.data_mut().modules.remove(&handle) {
            if let Some(host_module) = module.host_module {
                if let Some(unload) = resolve_host_module_unload() {
                    unsafe {
                        let _ = unload(host_module as *mut c_void);
                    }
                }
            }
        }
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_module_load_data_ex(
    ctx: FunctionEnvMut<CudaBridge>,
    module_ptr: i32,
    image_ptr: i32,
    _num_options: i32,
    _options: i32,
    _option_values: i32,
) -> i32 {
    cu_module_load_data(ctx, module_ptr, image_ptr)
}

fn cu_module_unload(mut ctx: FunctionEnvMut<CudaBridge>, module: i32) -> i32 {
    if module == 0 {
        return CUDA_SUCCESS;
    }
    let module_handle = module as u32;
    let Some(removed) = ctx.data_mut().modules.remove(&module_handle) else {
        return CUDA_ERROR_INVALID_VALUE;
    };
    ctx.data_mut()
        .functions
        .retain(|_, function| function.module != module_handle);

    if let Some(host_module) = removed.host_module {
        if let Some(unload) = resolve_host_module_unload() {
            let rc = unsafe { unload(host_module as *mut c_void) };
            if rc != CUDA_SUCCESS {
                return rc;
            }
        }
    }
    CUDA_SUCCESS
}

fn cu_module_get_function(
    mut ctx: FunctionEnvMut<CudaBridge>,
    function_ptr: i32,
    module: i32,
    name_ptr: i32,
) -> i32 {
    let name_bytes = match read_guest_c_string(&mut ctx, name_ptr, 4096) {
        Some(bytes) if !bytes.is_empty() => bytes,
        _ => return CUDA_ERROR_INVALID_VALUE,
    };
    let name = String::from_utf8_lossy(&name_bytes).into_owned();
    let module_handle = module as u32;
    let Some(module_data) = ctx.data().modules.get(&module_handle).cloned() else {
        return CUDA_ERROR_INVALID_VALUE;
    };

    let host_function = if let Some(host_module) = module_data.host_module {
        let Some(get_function) = resolve_host_module_get_function() else {
            return CUDA_ERROR_NOT_SUPPORTED;
        };
        let c_name = match CString::new(name.as_str()) {
            Ok(value) => value,
            Err(_) => return CUDA_ERROR_INVALID_VALUE,
        };
        let mut host_function = ptr::null_mut();
        let rc = unsafe {
            get_function(
                &mut host_function,
                host_module as *mut c_void,
                c_name.as_ptr(),
            )
        };
        if rc != CUDA_SUCCESS {
            return rc;
        }
        if host_function.is_null() {
            return CUDA_ERROR_INVALID_VALUE;
        }
        Some(host_function as usize)
    } else {
        None
    };

    let params = parse_ptx_kernel_params(&module_data.ptx, &name);
    let handle = match ctx.data_mut().allocate_function_handle(PtxFunction {
        module: module_handle,
        name,
        params,
        host_function,
    }) {
        Some(handle) => handle,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    if write_guest_u32(&mut ctx, function_ptr, handle).is_none() {
        ctx.data_mut().functions.remove(&handle);
        return CUDA_ERROR_INVALID_VALUE;
    }
    CUDA_SUCCESS
}

fn cu_launch_kernel(
    mut ctx: FunctionEnvMut<CudaBridge>,
    function: i32,
    grid_dim_x: i32,
    grid_dim_y: i32,
    grid_dim_z: i32,
    block_dim_x: i32,
    block_dim_y: i32,
    block_dim_z: i32,
    shared_mem_bytes: i32,
    _stream: i32,
    kernel_params: i32,
    extra: i32,
) -> i32 {
    if function == 0 || extra != 0 {
        return CUDA_ERROR_INVALID_VALUE;
    }

    let dims = match (
        checked_positive_i32(grid_dim_x),
        checked_positive_i32(grid_dim_y),
        checked_positive_i32(grid_dim_z),
        checked_positive_i32(block_dim_x),
        checked_positive_i32(block_dim_y),
        checked_positive_i32(block_dim_z),
        checked_positive_i32(shared_mem_bytes),
    ) {
        (Some(gx), Some(gy), Some(gz), Some(bx), Some(by), Some(bz), Some(shared)) => {
            (gx, gy, gz, bx, by, bz, shared)
        }
        _ => return CUDA_ERROR_INVALID_VALUE,
    };
    if dims.0 == 0 || dims.1 == 0 || dims.2 == 0 || dims.3 == 0 || dims.4 == 0 || dims.5 == 0 {
        return CUDA_ERROR_INVALID_VALUE;
    }

    let Some(function_data) = ctx.data().functions.get(&(function as u32)).cloned() else {
        return CUDA_ERROR_INVALID_VALUE;
    };
    let Some(host_function) = function_data.host_function else {
        return CUDA_ERROR_NOT_SUPPORTED;
    };
    let Some(launch) = resolve_host_launch_kernel() else {
        return CUDA_ERROR_NOT_SUPPORTED;
    };

    let mut host_params =
        match build_host_kernel_params(&mut ctx, &function_data.params, kernel_params) {
            Ok(params) => params,
            Err(rc) => return rc,
        };
    let params_ptr = if host_params.pointers.is_empty() {
        ptr::null_mut()
    } else {
        host_params.pointers.as_mut_ptr()
    };

    let rc = unsafe {
        launch(
            host_function as *mut c_void,
            dims.0 as u32,
            dims.1 as u32,
            dims.2 as u32,
            dims.3 as u32,
            dims.4 as u32,
            dims.5 as u32,
            dims.6 as u32,
            ptr::null_mut(),
            params_ptr,
            ptr::null_mut(),
        )
    };
    if rc != CUDA_SUCCESS {
        return rc;
    }

    for allocation in ctx.data_mut().allocations.values_mut() {
        if !sync_host_to_bytes(allocation) {
            return CUDA_ERROR_NOT_SUPPORTED;
        }
    }
    CUDA_SUCCESS
}

fn cuda_malloc(mut ctx: FunctionEnvMut<CudaBridge>, dev_ptr: i32, size: i32) -> i32 {
    let size = match checked_positive_i32(size) {
        Some(size) => size,
        None => return CUDA_ERROR_INVALID_VALUE,
    };

    let ptr = match ctx.data_mut().allocate_device_ptr(size) {
        Some(ptr) => ptr,
        None => return CUDA_ERROR_INVALID_VALUE,
    };

    if write_guest_u32(&mut ctx, dev_ptr, ptr).is_none() {
        if let Some(allocation) = ctx.data_mut().allocations.remove(&ptr) {
            if let Some(host_device_ptr) = allocation.host_device_ptr {
                try_host_mem_free(host_device_ptr);
            }
        }
        return CUDA_ERROR_INVALID_VALUE;
    }

    CUDA_SUCCESS
}

fn cuda_free(mut ctx: FunctionEnvMut<CudaBridge>, dev_ptr: i32) -> i32 {
    if dev_ptr == 0 {
        return CUDA_SUCCESS;
    }
    if dev_ptr < 0 {
        return CUDA_ERROR_INVALID_VALUE;
    }

    if let Some(allocation) = ctx.data_mut().allocations.remove(&(dev_ptr as u32)) {
        if let Some(host_device_ptr) = allocation.host_device_ptr {
            try_host_mem_free(host_device_ptr);
        }
    }
    CUDA_SUCCESS
}

fn cuda_memcpy(
    mut ctx: FunctionEnvMut<CudaBridge>,
    dst: i32,
    src: i32,
    size: i32,
    kind: i32,
) -> i32 {
    let size = match checked_positive_i32(size) {
        Some(size) => size,
        None => return CUDA_ERROR_INVALID_VALUE,
    };

    match kind {
        CUDA_MEMCPY_HOST_TO_HOST => {
            let bytes = match read_guest_memory(&mut ctx, src, size) {
                Some(bytes) => bytes,
                None => return CUDA_ERROR_INVALID_VALUE,
            };
            if write_guest_memory(&mut ctx, dst, &bytes).is_none() {
                return CUDA_ERROR_INVALID_VALUE;
            }
        }
        CUDA_MEMCPY_HOST_TO_DEVICE => {
            let bytes = match read_guest_memory(&mut ctx, src, size) {
                Some(bytes) => bytes,
                None => return CUDA_ERROR_INVALID_VALUE,
            };
            let Some(allocation) = ctx.data_mut().allocations.get_mut(&(dst as u32)) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            if allocation.bytes.len() < size {
                return CUDA_ERROR_INVALID_VALUE;
            }
            allocation.bytes[..size].copy_from_slice(&bytes);
            if !sync_bytes_to_host(allocation) {
                return CUDA_ERROR_NOT_SUPPORTED;
            }
        }
        CUDA_MEMCPY_DEVICE_TO_HOST => {
            let Some(allocation) = ctx.data_mut().allocations.get_mut(&(src as u32)) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            if !sync_host_to_bytes(allocation) {
                return CUDA_ERROR_NOT_SUPPORTED;
            }
            if allocation.bytes.len() < size {
                return CUDA_ERROR_INVALID_VALUE;
            }
            let bytes = allocation.bytes[..size].to_vec();
            if write_guest_memory(&mut ctx, dst, &bytes).is_none() {
                return CUDA_ERROR_INVALID_VALUE;
            }
        }
        CUDA_MEMCPY_DEVICE_TO_DEVICE => {
            let Some(bytes) = device_allocation_bytes(&ctx, src) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            let src_host = ctx
                .data()
                .allocations
                .get(&(src as u32))
                .and_then(|allocation| allocation.host_device_ptr);
            let Some(allocation) = ctx.data_mut().allocations.get_mut(&(dst as u32)) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            if bytes.len() < size || allocation.bytes.len() < size {
                return CUDA_ERROR_INVALID_VALUE;
            }
            allocation.bytes[..size].copy_from_slice(&bytes[..size]);
            if let (Some(dst_host), Some(src_host)) = (allocation.host_device_ptr, src_host) {
                if let Some(copy) = resolve_host_memcpy_dto_d() {
                    let rc =
                        unsafe { copy(dst_host as *mut c_void, src_host as *const c_void, size) };
                    if rc != CUDA_SUCCESS {
                        return rc;
                    }
                } else if !sync_bytes_to_host(allocation) {
                    return CUDA_ERROR_NOT_SUPPORTED;
                }
            } else if !sync_bytes_to_host(allocation) {
                return CUDA_ERROR_NOT_SUPPORTED;
            }
        }
        _ => return CUDA_ERROR_INVALID_VALUE,
    }

    CUDA_SUCCESS
}

fn cuda_device_synchronize(_ctx: FunctionEnvMut<CudaBridge>) -> i32 {
    CUDA_SUCCESS
}

fn cublas_create_v2(mut ctx: FunctionEnvMut<CudaBridge>, handle_ptr: i32) -> i32 {
    let handle = match ctx.data_mut().allocate_cublas_handle() {
        Some(handle) => handle,
        None => return CUDA_ERROR_INVALID_VALUE,
    };

    if write_guest_u32(&mut ctx, handle_ptr, handle).is_none() {
        return CUDA_ERROR_INVALID_VALUE;
    }

    CUDA_SUCCESS
}

fn cublas_destroy_v2(_ctx: FunctionEnvMut<CudaBridge>, _handle: i32) -> i32 {
    CUDA_SUCCESS
}

fn cublas_sgemm_v2(
    mut ctx: FunctionEnvMut<CudaBridge>,
    handle: i32,
    transa: i32,
    transb: i32,
    m: i32,
    n: i32,
    k: i32,
    alpha_ptr: i32,
    a_ptr: i32,
    lda: i32,
    b_ptr: i32,
    ldb: i32,
    beta_ptr: i32,
    c_ptr: i32,
    ldc: i32,
) -> i32 {
    if handle == 0 || transa != CUBLAS_OP_N || transb != CUBLAS_OP_N {
        return CUDA_ERROR_INVALID_VALUE;
    }

    let (m, n, k, lda, ldb, ldc) = match (
        checked_positive_i32(m),
        checked_positive_i32(n),
        checked_positive_i32(k),
        checked_positive_i32(lda),
        checked_positive_i32(ldb),
        checked_positive_i32(ldc),
    ) {
        (Some(m), Some(n), Some(k), Some(lda), Some(ldb), Some(ldc)) => (m, n, k, lda, ldb, ldc),
        _ => return CUDA_ERROR_INVALID_VALUE,
    };

    if lda < m || ldb < k || ldc < m {
        return CUDA_ERROR_INVALID_VALUE;
    }

    let alpha = match read_guest_f32(&mut ctx, alpha_ptr) {
        Some(alpha) => alpha,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    let beta = match read_guest_f32(&mut ctx, beta_ptr) {
        Some(beta) => beta,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    let a = match device_allocation_f32s(&ctx, a_ptr) {
        Some(a) => a,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    let b = match device_allocation_f32s(&ctx, b_ptr) {
        Some(b) => b,
        None => return CUDA_ERROR_INVALID_VALUE,
    };
    let mut c = match device_allocation_f32s(&ctx, c_ptr) {
        Some(c) => c,
        None => return CUDA_ERROR_INVALID_VALUE,
    };

    if let Some(accelerated) = try_apple_sgemm(m, n, k, lda, ldb, ldc, alpha, &a, &b, beta, &c) {
        c = accelerated;
    } else {
        for col in 0..n {
            for row in 0..m {
                let mut sum = 0.0f32;
                for q in 0..k {
                    let Some(a_index) = row.checked_add(q.saturating_mul(lda)) else {
                        return CUDA_ERROR_INVALID_VALUE;
                    };
                    let Some(b_index) = q.checked_add(col.saturating_mul(ldb)) else {
                        return CUDA_ERROR_INVALID_VALUE;
                    };
                    if a_index >= a.len() || b_index >= b.len() {
                        return CUDA_ERROR_INVALID_VALUE;
                    }
                    sum += a[a_index] * b[b_index];
                }

                let Some(c_index) = row.checked_add(col.saturating_mul(ldc)) else {
                    return CUDA_ERROR_INVALID_VALUE;
                };
                if c_index >= c.len() {
                    return CUDA_ERROR_INVALID_VALUE;
                }
                c[c_index] = alpha.mul_add(sum, beta * c[c_index]);
            }
        }
    }

    let bytes = f32s_to_bytes(&c);
    let Some(allocation) = ctx.data_mut().allocations.get_mut(&(c_ptr as u32)) else {
        return CUDA_ERROR_INVALID_VALUE;
    };
    if allocation.bytes.len() < bytes.len() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    allocation.bytes[..bytes.len()].copy_from_slice(&bytes);
    if !sync_bytes_to_host(allocation) {
        return CUDA_ERROR_NOT_SUPPORTED;
    }

    CUDA_SUCCESS
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
fn module_uses_shared_memory(wasm_bytes: &[u8]) -> bool {
    use wasmparser::{Parser, Payload, TypeRef};

    for payload in Parser::new(0).parse_all(wasm_bytes) {
        match payload {
            Ok(Payload::ImportSection(reader)) => {
                for group in reader {
                    let Ok(group) = group else { return false };
                    for import in group.into_iter().flatten().map(|(_, import)| import) {
                        if matches!(import.ty, TypeRef::Memory(memory) if memory.shared) {
                            return true;
                        }
                    }
                }
            }
            Ok(Payload::MemorySection(reader)) => {
                if reader.into_iter().flatten().any(|memory| memory.shared) {
                    return true;
                }
            }
            Err(_) => return false,
            _ => {}
        }
    }
    false
}

fn create_store() -> (Store, bool) {
    if std::env::var_os("WASM_FORCE_INTERPRETER").is_some() {
        // Select Wasmi explicitly.  Store::default() is sensitive to feature
        // unification and older XCFramework builds selected the Sys/Cranelift
        // backend here, producing HeapAccessOutOfBounds traps on iOS devices.
        return (
            Store::new(wasmer_wasix::wasmer::wasmi::Wasmi::default()),
            false,
        );
    }

    #[cfg(feature = "cranelift")]
    {
        if jit_available() {
            use wasmer_wasix::wasmer::sys::{Cranelift, EngineBuilder};
            let engine = EngineBuilder::new(Cranelift::default()).engine();
            return (Store::new(engine), true);
        }
    }

    (
        Store::new(wasmer_wasix::wasmer::wasmi::Wasmi::default()),
        false,
    )
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

fn extract_exit_code(error: &wasmer_wasix::wasmer::RuntimeError) -> Option<i32> {
    if let Some(wasi_error) = error.downcast_ref::<wasmer_wasix::WasiError>() {
        return match wasi_error {
            wasmer_wasix::WasiError::Exit(code) => Some(code.raw()),
            wasmer_wasix::WasiError::ThreadExit => Some(0),
            _ => None,
        };
    }
    // Fallback for backends that flatten the typed error into text.
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
    static VERSION: &str = concat!(
        "Wasmer iOS Runtime v",
        env!("CARGO_PKG_VERSION"),
        " direct-bootstrap-20260615",
        "\0"
    );
    VERSION.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn wasmer_set_display_frame_callback(
    callback: Option<WasmerDisplayFrameCallback>,
    user_data: *mut c_void,
) {
    if let Ok(mut state) = DISPLAY_CALLBACK.lock() {
        state.callback = callback;
        state.user_data = user_data as usize;
    }
}

#[no_mangle]
pub extern "C" fn wasmer_display_enqueue_input_event(
    event_type: u32,
    code: u32,
    x: i32,
    y: i32,
    value: i32,
    modifiers: u32,
) -> i32 {
    let event = WasmerDisplayInputEvent {
        event_type,
        code,
        x,
        y,
        value,
        modifiers,
    };

    match display_input_events().lock() {
        Ok(mut queue) => {
            if queue.len() >= 1024 {
                queue.pop_front();
            }
            queue.push_back(event);
            0
        }
        Err(_) => -1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        let version = wasmer_version();
        assert!(!version.is_null());
    }

    #[test]
    #[ignore = "requires building examples/wasm-cuda-oxide/cuda_oxide_probe.wasm"]
    fn test_cuda_oxide_probe() {
        let wasm_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../examples/wasm-cuda-oxide/cuda_oxide_probe.wasm");
        let wasm = std::fs::read(&wasm_path).expect("read cuda_oxide_probe.wasm");
        let args = vec!["cuda_oxide_probe".to_string()];
        let exit_code = execute_wasm(&wasm, &args, -1, 1, 2).expect("execute CUDA probe");

        assert_eq!(exit_code, 0);
    }
}
