//
//  wasm.swift
//  Code
//
//  Native Wasmer-based WASM execution (migrated from JavaScript)
//  Backup of old implementation saved as wasm.swift.backup
//

import Foundation
import ios_system

// Import C functions from Wasmer XCFramework
@_silgen_name("wasmer_execute")
func wasmer_execute(
    _ wasmBytes: UnsafePointer<UInt8>,
    _ wasmBytesLen: Int,
    _ args: UnsafePointer<UnsafePointer<Int8>?>,
    _ argsLen: Int,
    _ stdinFd: Int32,
    _ stdoutFd: Int32,
    _ stderrFd: Int32
) -> Int32

@_silgen_name("wasmer_version")
func wasmer_version() -> UnsafePointer<Int8>

@_cdecl("wasm")
public func wasm(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    let args = convertCArguments(argc: argc, argv: argv)
    return executeWebAssembly(arguments: args)
}

@_cdecl("wasm_cuda_oxide")
public func wasm_cuda_oxide(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    let rawArgs = convertCArguments(argc: argc, argv: argv) ?? ["wasm_cuda_oxide"]
    let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")

    guard
        let wasmURL = Bundle.main.url(
            forResource: "cuda_oxide_probe",
            withExtension: "wasm")
    else {
        fputs("wasm_cuda_oxide: bundled cuda_oxide_probe.wasm not found\n", stderr)
        return -1
    }

    let launchArgs = ["wasm", "--gpu", wasmURL.path] + Array(rawArgs.dropFirst())
    return executeWebAssembly(arguments: launchArgs)
}

private func executeWebAssembly(arguments: [String]?) -> Int32 {

    guard let arguments = arguments, arguments.count >= 2 else {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs("Usage: wasm [--gpu|--gpu-backend ane|metal] <wasm-file> [args...]\n", stderr)
        fputs("       wasm --version\n", stderr)
        return -1
    }

    // Handle --version flag
    if arguments[1] == "--version" || arguments[1] == "-v" {
        // Use stdout if available, otherwise use STDOUT_FILENO
        let stdout = thread_stdout ?? fdopen(STDOUT_FILENO, "w")

        let versionPtr = wasmer_version()
        let version = String(cString: versionPtr)
        let output = "\(version)\nNative WASM runtime powered by Wasmer with WASIX p1 support\n"
        fputs(output, stdout)
        fflush(stdout)
        return 0
    }

    guard let commandOptions = parseWASMCommandOptions(arguments) else {
        return -1
    }

    let wasmFile = arguments[commandOptions.wasmIndex]
    let currentDirectory = resolvedWASMCurrentDirectory(FileManager.default.currentDirectoryPath)
    let fileName = wasmFile.hasPrefix("/") ? wasmFile : currentDirectory + "/" + wasmFile

    setupWASMSysroot(currentDirectory: currentDirectory, gpuBackend: commandOptions.gpuBackend)

    // Load WASM file
    guard let wasmData = try? Data(contentsOf: URL(fileURLWithPath: fileName)) else {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs("wasm: file '\(wasmFile)' not found\n", stderr)
        return -1
    }

    // Prepare arguments for the WASM module
    // First argument should be the program name (wasm file)
    let wasmArgs = [arguments[0]] + Array(arguments.dropFirst(commandOptions.wasmIndex))

    // Convert Swift strings to C strings
    var cStrings: [UnsafePointer<Int8>?] = wasmArgs.map { arg in
        let cString = strdup(arg)
        return UnsafePointer(cString)
    }
    cStrings.append(nil)  // Null-terminate the array

    defer {
        // Clean up allocated C strings
        for cString in cStrings where cString != nil {
            free(UnsafeMutablePointer(mutating: cString))
        }
    }

    // Get file descriptors for stdin/stdout/stderr
    // Use safe defaults if thread_* are NULL
    let stdinFd: Int32 = (thread_stdin != nil) ? fileno(thread_stdin) : STDIN_FILENO
    let stdoutFd: Int32 = (thread_stdout != nil) ? fileno(thread_stdout) : STDOUT_FILENO
    let stderrFd: Int32 = (thread_stderr != nil) ? fileno(thread_stderr) : STDERR_FILENO

    // Execute WASM with native Wasmer
    let exitCode = wasmData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
        guard let baseAddress = bytes.baseAddress else {
            return -1
        }

        return cStrings.withUnsafeBufferPointer { argsBuffer in
            return wasmer_execute(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                argsBuffer.baseAddress!,
                wasmArgs.count,
                stdinFd,
                stdoutFd,
                stderrFd
            )
        }
    }

    return exitCode
}

func parseWASMCommandOptions(_ arguments: [String]) -> (gpuBackend: String?, wasmIndex: Int)? {
    let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
    var gpuBackend: String?
    var index = 1

    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--gpu" {
            gpuBackend = "ane"
            index += 1
            continue
        }
        if arg == "--no-gpu" {
            gpuBackend = nil
            index += 1
            continue
        }
        if arg == "--gpu-backend" {
            guard index + 1 < arguments.count else {
                fputs("wasm: --gpu-backend requires ane or metal\n", stderr)
                return nil
            }
            let backend = arguments[index + 1]
            guard backend == "ane" || backend == "metal" else {
                fputs("wasm: --gpu-backend must be ane or metal\n", stderr)
                return nil
            }
            gpuBackend = backend
            index += 2
            continue
        }
        if arg.hasPrefix("--gpu-backend=") {
            let backend = String(arg.dropFirst("--gpu-backend=".count))
            guard backend == "ane" || backend == "metal" else {
                fputs("wasm: --gpu-backend must be ane or metal\n", stderr)
                return nil
            }
            gpuBackend = backend
            index += 1
            continue
        }
        if arg == "--" {
            index += 1
            break
        }
        break
    }

    guard index < arguments.count else {
        fputs("Usage: wasm [--gpu|--gpu-backend ane|metal] <wasm-file> [args...]\n", stderr)
        return nil
    }
    return (gpuBackend, index)
}

/// Root of the persistent guest filesystem skeleton (/tmp, /home, /etc, Tools)
/// exposed to every WASM program.
func wasmSysrootURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/wasm-sysroot")
}

func resolvedWASMCurrentDirectory(_ currentDirectory: String) -> String {
    let fileManager = FileManager.default
    let home = NSHomeDirectory()
    let documentsURL =
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: home).appendingPathComponent("Documents")

    try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: currentDirectory, isDirectory: &isDirectory),
        isDirectory.boolValue
    {
        return currentDirectory
    }

    if currentDirectory == home || currentDirectory.hasPrefix(home + "/") {
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: currentDirectory), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: currentDirectory, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return currentDirectory
        }
    }

    if fileManager.fileExists(atPath: documentsURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    {
        return documentsURL.path
    }

    return home
}

/// Prepare the WASI sysroot for a WASM program and expose it through the
/// environment variables the Wasmer runtime reads:
///   WASM_PREOPENS  - colon-separated host directories preopened for the guest
///   WASM_MAP_DIRS  - ;-separated guest::host mappings (e.g. /tmp::<host tmp>)
///   WASM_CWD       - guest working directory
///   WASM_AOT_CACHE - directory for AOT-compiled module artifacts
///
/// The sandbox home directory is preopened so absolute paths into Documents
/// and Library resolve, and a persistent skeleton (/tmp, /home, /etc) gives
/// libc-based binaries the files they expect.
func setupWASMSysroot(currentDirectory: String, gpuBackend: String? = nil) {
    let fileManager = FileManager.default
    let home = NSHomeDirectory()
    let sysroot = wasmSysrootURL()
    let resolvedCurrentDirectory = resolvedWASMCurrentDirectory(currentDirectory)
    let gpuRuntime = configureWASMGPURuntime(backend: gpuBackend)

    // Build the skeleton once; subsequent runs reuse it so guest state persists.
    let skeletonDirs = ["tmp", "home", "etc", "usr", "Tools"]
    for dir in skeletonDirs {
        try? fileManager.createDirectory(
            at: sysroot.appendingPathComponent(dir), withIntermediateDirectories: true)
    }

    let etcFiles: [String: String] = [
        "etc/passwd": "root:x:0:0:root:/home:/bin/sh\nmobile:x:501:501:mobile:/home:/bin/sh\n",
        "etc/group": "root:x:0:\nmobile:x:501:\n",
        "etc/hosts": "127.0.0.1 localhost\n::1 localhost\n",
        "etc/resolv.conf": "nameserver 1.1.1.1\nnameserver 8.8.8.8\n",
    ]
    for (path, content) in etcFiles {
        let url = sysroot.appendingPathComponent(path)
        if !fileManager.fileExists(atPath: url.path) {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // Preopen the entire app sandbox plus the working directory (which can sit
    // outside the sandbox when a folder is opened via a security-scoped URL).
    var preopens = [home, NSTemporaryDirectory()]
    if !resolvedCurrentDirectory.hasPrefix(home) {
        preopens.append(resolvedCurrentDirectory)
    }
    if let gpuRuntime {
        preopens.append(gpuRuntime.path)
    }
    setenv("WASM_PREOPENS", preopens.joined(separator: ":"), 1)

    // Map standard Unix locations onto the persistent skeleton. Only /tmp and
    // /usr: the wasix root fs pre-creates /etc and /home, and mounting over
    // those fails with "file exists" (verified against the wasmer CLI). The
    // guest /etc is writable memfs, and the skeleton etc/ stays reachable via
    // its host path through the sandbox preopen.
    //
    // The guest /usr is a real wasi-sysroot so compilers and tools running as
    // wasm guests see complete headers and wasm32-wasi libraries. Prefer the
    // WASIX sysroot (wasi-sdk 29, matches the wasmer-wasix runtime) that
    // createWasixSysroot() materializes, then the clang-14 C SDK from
    // createCSDK(), then the empty skeleton until either exists.
    let libraryURL = URL(fileURLWithPath: home).appendingPathComponent("Library")
    let usrHost =
        [
            libraryURL.appendingPathComponent("wasix-usr"),
            libraryURL.appendingPathComponent("usr"),
        ]
        .first { fileManager.fileExists(atPath: $0.appendingPathComponent("include").path) }?
        .path ?? sysroot.appendingPathComponent("usr").path
    var mapDirs = [
        "/tmp::\(sysroot.appendingPathComponent("tmp").path)",
        "/usr::\(usrHost)",
    ]
    if let gpuRuntime {
        mapDirs.append("/opt/hetgpu::\(gpuRuntime.path)")
    }
    setenv("WASM_MAP_DIRS", mapDirs.joined(separator: ";"), 1)

    setenv("WASM_CWD", resolvedCurrentDirectory, 1)
    setenv("PWD", resolvedCurrentDirectory, 1)
    // Guest-only HOME override, applied by the runtime so the host HOME
    // (used by node/npm and ios_system commands) is left untouched. Points at
    // the persistent skeleton home (visible via the sandbox preopen) rather
    // than the ephemeral wasix memfs /home.
    setenv("WASM_GUEST_HOME", sysroot.appendingPathComponent("home").path, 1)

    // AOT artifact cache, used when the runtime selects a compiling engine.
    let aotCache = URL(fileURLWithPath: home)
        .appendingPathComponent("Library/Caches/wasmer-aot")
    try? fileManager.createDirectory(at: aotCache, withIntermediateDirectories: true)
    setenv("WASM_AOT_CACHE", aotCache.path, 1)
}

func configureWASMGPURuntime(backend explicitBackend: String?) -> URL? {
    guard let selectedBackend = explicitBackend else {
        unsetenv("WASM_CUDA_ACCEL")
        unsetenv("WASM_CUDA_BACKEND")
        unsetenv("HETGPU_APPLE_BACKEND")
        unsetenv("CODIFYONE_HETGPU_ROOT")
        return nil
    }
    guard selectedBackend == "ane" || selectedBackend == "metal" else {
        fputs("wasm: GPU backend must be ane or metal\n", thread_stderr)
        return nil
    }

    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent("hetgpu-apple-ane"),
        Bundle.main.bundleURL.appendingPathComponent("hetgpu-apple-ane"),
    ].compactMap { $0 }

    guard
        let runtime = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("libcuda.so.1").path)
        })
    else {
        fputs("wasm: bundled hetGPU Apple runtime not found\n", thread_stderr)
        return nil
    }

    setenv("CODIFYONE_HETGPU_ROOT", runtime.path, 1)
    setenv("HETGPU_APPLE_BACKEND", selectedBackend, 1)
    setenv("WASM_CUDA_ACCEL", "1", 1)
    setenv("WASM_CUDA_BACKEND", selectedBackend, 1)
    prependEnvPath("LD_LIBRARY_PATH", runtime.path)
    prependEnvPath("DYLD_LIBRARY_PATH", runtime.path)
    prependEnvPath("DYLD_FALLBACK_LIBRARY_PATH", runtime.path)
    prependEnvPath("DYLD_INSERT_LIBRARIES", runtime.appendingPathComponent("libcuda.so.1").path)
    return runtime
}

func prependEnvPath(_ name: String, _ value: String) {
    let current = getenv(name).map { String(cString: $0) } ?? ""
    let parts = current.split(separator: ":").map(String.init)
    if parts.contains(value) {
        return
    }
    let next = current.isEmpty ? value : "\(value):\(current)"
    setenv(name, next, 1)
}

/*
 * MIGRATION NOTES:
 * ================
 * This file previously used a JavaScript/WebKit-based approach with WKWebView
 * to execute WebAssembly modules. That implementation had several limitations:
 *
 * - Required JavaScript bridge for WASI calls (700+ lines of code)
 * - Slower due to JS overhead
 * - Custom WASI implementation with limited functionality
 * - Complex code with wasmWebViewDelegate and message handlers
 * - Required wasmWebView.loadWorker() at app startup
 *
 * The new implementation uses native Wasmer runtime with:
 * - Direct C ABI calls (no JavaScript) - now only ~100 lines
 * - Full WASIX p1 support
 * - Better performance
 * - Simpler, more maintainable code
 * - Proper file descriptor mapping
 * - No WebView required
 *
 * The old JavaScript-based implementation has been backed up to:
 * wasm.swift.backup
 *
 * You can also find it in git history before this migration.
 */
