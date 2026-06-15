use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::io::SeekFrom;
use std::os::raw::{c_char, c_void};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::Path;
use std::pin::Pin;
use std::ptr;
use std::slice;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncSeek, AsyncWrite, ReadBuf};
use wasmer::{
    ExternType, Function, FunctionEnv, FunctionEnvMut, Imports, Instance, Memory, Module, Store,
    Type, Value,
};
use wasmer_wasix::runtime::task_manager::tokio::TokioTaskManager;
use wasmer_wasix::virtual_fs::{FsError, VirtualFile};
use wasmer_wasix::{PluggableRuntime, WasiEnvBuilder, WasiFunctionEnv};

const CUDA_SUCCESS: i32 = 0;
const CUDA_ERROR_INVALID_VALUE: i32 = 1;
const CUDA_ERROR_NOT_SUPPORTED: i32 = 801;
const CUDA_MEMCPY_HOST_TO_HOST: i32 = 0;
const CUDA_MEMCPY_HOST_TO_DEVICE: i32 = 1;
const CUDA_MEMCPY_DEVICE_TO_HOST: i32 = 2;
const CUDA_MEMCPY_DEVICE_TO_DEVICE: i32 = 3;
const CUBLAS_OP_N: i32 = 0;
const HETGPU_CUDA_R_32F: i32 = 0;

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

    let mut wasi_env_builder = WasiEnvBuilder::new("wasmer").runtime(runtime);

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

    // CUDA/cuBLAS-flavored WASM needs host imports in addition to WASI. Keep
    // the standard WASIX instantiation path for normal modules, because it also
    // handles imported memories and dynamic-linking details.
    let (instance, _wasi_env) = if module_has_cuda_imports(&module) {
        instantiate_wasi_with_cuda(wasi_env_builder, module.clone(), &mut store)?
    } else {
        wasi_env_builder
            .instantiate(module.clone(), &mut store)
            .map_err(|e| format!("Failed to instantiate WASI module: {}", e))?
    };

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
                "cudaMalloc"
                    | "cudaFree"
                    | "cudaMemcpy"
                    | "cudaDeviceSynchronize"
                    | "cublasCreate_v2"
                    | "cublasDestroy_v2"
                    | "cublasSgemm_v2"
            )
    })
}

fn module_has_imported_memory(module: &Module) -> bool {
    module
        .imports()
        .any(|import| matches!(import.ty(), ExternType::Memory(_)))
}

fn instantiate_wasi_with_cuda(
    wasi_env_builder: WasiEnvBuilder,
    module: Module,
    store: &mut Store,
) -> Result<(Instance, WasiFunctionEnv), Box<dyn std::error::Error>> {
    if module_has_imported_memory(&module) {
        return Err(
            "CUDA bridge currently supports modules that export their linear memory".into(),
        );
    }

    let mut wasi_env = wasi_env_builder
        .finalize(store)
        .map_err(|e| format!("Failed to finalize WASI environment: {}", e))?;
    let mut imports = wasi_env
        .import_object_for_all_wasi_versions(store, &module)
        .map_err(|e| format!("Failed to create WASI imports: {}", e))?;

    let cuda_env = FunctionEnv::new(store, CudaBridge::new());
    define_cuda_imports(store, &mut imports, &cuda_env);

    let instance = Instance::new(store, &module, &imports)
        .map_err(|e| format!("Failed to instantiate CUDA WASI module: {}", e))?;
    let memory = instance
        .exports
        .get_memory("memory")
        .map_err(|e| format!("CUDA WASM module must export memory: {}", e))?
        .clone();

    cuda_env.as_mut(store).memory = Some(memory);
    wasi_env
        .initialize(store, instance.clone())
        .map_err(|e| format!("Failed to initialize WASI environment: {}", e))?;

    Ok((instance, wasi_env))
}

fn define_cuda_imports(store: &mut Store, imports: &mut Imports, env: &FunctionEnv<CudaBridge>) {
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

fn read_guest_f32(ctx: &mut FunctionEnvMut<CudaBridge>, ptr: i32) -> Option<f32> {
    let bytes = read_guest_memory(ctx, ptr, 4)?;
    Some(f32::from_le_bytes(bytes.try_into().ok()?))
}

fn device_allocation_bytes(ctx: &FunctionEnvMut<CudaBridge>, ptr: i32) -> Option<Vec<u8>> {
    if ptr < 0 {
        return None;
    }
    ctx.data().allocations.get(&(ptr as u32)).cloned()
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
        ctx.data_mut().allocations.remove(&ptr);
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

    ctx.data_mut().allocations.remove(&(dev_ptr as u32));
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
            if allocation.len() < size {
                return CUDA_ERROR_INVALID_VALUE;
            }
            allocation[..size].copy_from_slice(&bytes);
        }
        CUDA_MEMCPY_DEVICE_TO_HOST => {
            let Some(bytes) = device_allocation_bytes(&ctx, src) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            if bytes.len() < size {
                return CUDA_ERROR_INVALID_VALUE;
            }
            if write_guest_memory(&mut ctx, dst, &bytes[..size]).is_none() {
                return CUDA_ERROR_INVALID_VALUE;
            }
        }
        CUDA_MEMCPY_DEVICE_TO_DEVICE => {
            let Some(bytes) = device_allocation_bytes(&ctx, src) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            let Some(allocation) = ctx.data_mut().allocations.get_mut(&(dst as u32)) else {
                return CUDA_ERROR_INVALID_VALUE;
            };
            if bytes.len() < size || allocation.len() < size {
                return CUDA_ERROR_INVALID_VALUE;
            }
            allocation[..size].copy_from_slice(&bytes[..size]);
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
    if allocation.len() < bytes.len() {
        return CUDA_ERROR_INVALID_VALUE;
    }
    allocation[..bytes.len()].copy_from_slice(&bytes);

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
