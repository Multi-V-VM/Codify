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

@_cdecl("wasm_cuda_ptx")
public func wasm_cuda_ptx(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
    let rawArgs = convertCArguments(argc: argc, argv: argv) ?? ["wasm_cuda_ptx"]
    let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")

    guard
        let wasmURL = Bundle.main.url(
            forResource: "cuda_ptx_probe",
            withExtension: "wasm")
    else {
        fputs("wasm_cuda_ptx: bundled cuda_ptx_probe.wasm not found\n", stderr)
        return -1
    }

    let launchArgs = ["wasm", "--gpu-backend", "metal", wasmURL.path] + Array(rawArgs.dropFirst())
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
    let hostCurrentDirectory = resolvedWASMCurrentDirectory(
        FileManager.default.currentDirectoryPath)
    let fileName = wasmFile.hasPrefix("/") ? wasmFile : hostCurrentDirectory + "/" + wasmFile
    let wasmCurrentDirectory = safeWASMCurrentDirectory(hostCurrentDirectory)

    setupWASMSysroot(currentDirectory: wasmCurrentDirectory, gpuBackend: commandOptions.gpuBackend)

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

func wasmHostDirectoryExists(_ path: String) -> Bool {
    var info = stat()
    return path.withCString { stat($0, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR }
}

@discardableResult
func wasmEnsureHostDirectory(_ path: String) -> Bool {
    if wasmHostDirectoryExists(path) {
        return true
    }

    let isAbsolute = path.hasPrefix("/")
    var current = isAbsolute ? "/" : ""
    for component in path.split(separator: "/").map(String.init) {
        if current == "/" {
            current += component
        } else if current.isEmpty {
            current = component
        } else {
            current += "/" + component
        }

        if wasmHostDirectoryExists(current) {
            continue
        }

        let result = current.withCString { mkdir($0, S_IRWXU) }
        if result != 0 && errno != EEXIST {
            return false
        }
    }

    return wasmHostDirectoryExists(path)
}

func wasmHostHomeURL(fileManager: FileManager = .default) -> URL {
    if let libraryURL = try? fileManager.url(
        for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    {
        let homeURL = libraryURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: homeURL.path) {
            return homeURL
        }
    }

    let fallbackURL = URL(fileURLWithPath: NSHomeDirectory())
    try? fileManager.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
    return fallbackURL
}

func wasmTemporaryRuntimeURL(fileManager: FileManager = .default) -> URL {
    let uid = getuid()
    var candidates = [URL]()

    if let applicationSupportURL = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    {
        candidates.append(
            applicationSupportURL.appendingPathComponent("CodifyOne-wasm", isDirectory: true))
    }
    if let libraryURL = try? fileManager.url(
        for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    {
        candidates.append(libraryURL.appendingPathComponent("CodifyOne-wasm", isDirectory: true))
    }

    candidates.append(
        wasmSysrootURL().appendingPathComponent("runtime", isDirectory: true))
    candidates.append(
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("CodifyOne-wasm-\(uid)", isDirectory: true))
    candidates.append(
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("CodifyOne-wasm-\(uid)", isDirectory: true))

    for candidate in candidates {
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard wasmEnsureHostDirectory(canonicalCandidate.path) else { continue }
        return canonicalCandidate
    }

    let fallbackURL = wasmHostHomeURL(fileManager: fileManager)
        .appendingPathComponent("Library/CodifyOne-wasm", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    _ = wasmEnsureHostDirectory(fallbackURL.path)
    return fallbackURL
}

/// Root of the persistent guest filesystem skeleton (/tmp, /home, /etc, Tools)
/// exposed to every WASM program.
func wasmSysrootURL() -> URL {
    wasmHostHomeURL().appendingPathComponent("Library/wasm-sysroot")
}

func safeWASMCurrentDirectory(_ currentDirectory: String) -> String {
    let fileManager = FileManager.default
    let runtimeRootURL = wasmTemporaryRuntimeURL(fileManager: fileManager)
    let runtimeRootPath = runtimeRootURL.path
    let runtimeHomeURL = runtimeRootURL.appendingPathComponent("home", isDirectory: true)
    let runtimeFallbackPath =
        wasmEnsureHostDirectory(runtimeHomeURL.path) ? runtimeHomeURL.path : runtimeRootPath

    if wasmHostPathIsAppContainer(currentDirectory)
        && currentDirectory.hasSuffix("/Data/Documents")
    {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs(
            "wasm: using internal cwd because container Documents is not valid for Wasmer\n",
            stderr)
        return runtimeFallbackPath
    }

    if wasmHostDirectoryExists(currentDirectory),
        !wasmHostPathIsAppContainer(currentDirectory)
            || currentDirectory == runtimeRootPath
            || currentDirectory.hasPrefix(runtimeRootPath + "/")
    {
        return currentDirectory
    }

    let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
    fputs(
        "wasm: using temporary cwd because requested cwd is unavailable to Wasmer: \(currentDirectory)\n",
        stderr)
    return runtimeFallbackPath
}

func wasmHostPathIsAppContainer(_ path: String) -> Bool {
    path.contains("/Library/Containers/")
        || path.contains("/Containers/Data/Application/")
        || path.contains("/Bundle/Application/")
        || path.contains("/Wrapper/") && path.contains(".app/")
        || path.contains(".app/")
        || path.hasPrefix("/var/mobile/Containers/")
        || path.hasPrefix("/private/var/mobile/Containers/")
        || path.hasPrefix("/var/containers/Bundle/Application/")
        || path.hasPrefix("/private/var/containers/Bundle/Application/")
}

func wasmHostPathIsUsableByWasmer(_ path: String) -> Bool {
    wasmHostDirectoryExists(path) && !wasmHostPathIsAppContainer(path)
}

func wasmGuestPath(forHostPath hostPath: String, hostRoot: String, guestRoot: String) -> String? {
    if hostPath == hostRoot {
        return guestRoot
    }
    guard hostPath.hasPrefix(hostRoot + "/") else {
        return nil
    }

    let suffix = String(hostPath.dropFirst(hostRoot.count))
    if guestRoot == "/" {
        return suffix.isEmpty ? "/" : suffix
    }
    return guestRoot + suffix
}

func resolvedWASMCurrentDirectory(_ currentDirectory: String) -> String {
    let fileManager = FileManager.default
    let homeURL = wasmHostHomeURL(fileManager: fileManager)
    let home = homeURL.path
    let sysrootHomeURL = homeURL.appendingPathComponent("Library/wasm-sysroot/home")
    try? fileManager.createDirectory(at: sysrootHomeURL, withIntermediateDirectories: true)

    if wasmHostDirectoryExists(currentDirectory) {
        return currentDirectory
    }

    if currentDirectory == home || currentDirectory.hasPrefix(home + "/") {
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: currentDirectory), withIntermediateDirectories: true)
        if wasmHostDirectoryExists(currentDirectory) {
            return currentDirectory
        }
    }

    let documentCandidates = [
        homeURL.appendingPathComponent("Documents"),
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
    ].compactMap { $0 }

    for documentsURL in documentCandidates {
        try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        if wasmHostDirectoryExists(documentsURL.path) {
            return documentsURL.path
        }
    }

    if wasmHostDirectoryExists(sysrootHomeURL.path) {
        return sysrootHomeURL.path
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
    let homeURL = wasmHostHomeURL(fileManager: fileManager)
    let sysroot = wasmSysrootURL()
    let resolvedCurrentDirectory = safeWASMCurrentDirectory(currentDirectory)
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

    // Preopen only directories that exist. Wasmer validates metadata for every
    // preopen at instantiation time, so a stale sandbox home path aborts WASI setup.
    let runtimeRootURL = wasmTemporaryRuntimeURL(fileManager: fileManager)
    let runtimeRootPath = runtimeRootURL.path
    let tempURL = runtimeRootURL.appendingPathComponent("tmp", isDirectory: true)
    _ = wasmEnsureHostDirectory(tempURL.path)
    let runtimeHomeURL = runtimeRootURL.appendingPathComponent("home", isDirectory: true)
    let runtimeHomePath =
        wasmEnsureHostDirectory(runtimeHomeURL.path) ? runtimeHomeURL.path : runtimeRootPath
    let wasmCWDHost = safeWASMCurrentDirectory(resolvedCurrentDirectory)

    var preopens = [String]()

    // Map standard Unix locations only when the host path is outside the app
    // container. The Wasmer iOS bridge cannot stat container paths reliably at
    // WASI setup time, so /tmp and /home are left as guest memfs by default.
    let libraryURL = homeURL.appendingPathComponent("Library")
    let runtimeUsrURL = runtimeRootURL.appendingPathComponent("usr", isDirectory: true)
    for dir in ["include", "lib", "bin"] {
        _ = wasmEnsureHostDirectory(
            runtimeUsrURL.appendingPathComponent(dir, isDirectory: true).path)
    }
    let usrHost =
        [
            libraryURL.appendingPathComponent("wasix-usr"),
            libraryURL.appendingPathComponent("usr"),
            Resources.wasiSysroot,
            runtimeUsrURL,
        ]
        .first { wasmHostPathIsUsableByWasmer($0.path) }?
        .path

    var mapEntries: [(guest: String, host: String)] = []
    if let usrHost {
        mapEntries.append(("/usr", usrHost))
    }
    if wasmHostPathIsUsableByWasmer(tempURL.path) {
        mapEntries.append(("/tmp", tempURL.path))
        preopens.append(tempURL.path)
    }

    let wasmCWD: String
    if let guestPath = wasmGuestPath(
        forHostPath: wasmCWDHost, hostRoot: runtimeHomePath, guestRoot: "/home")
    {
        wasmCWD = guestPath
    } else if let guestPath = wasmGuestPath(
        forHostPath: wasmCWDHost, hostRoot: tempURL.path, guestRoot: "/tmp")
    {
        wasmCWD = guestPath
    } else if let guestPath = wasmGuestPath(
        forHostPath: wasmCWDHost, hostRoot: runtimeRootPath, guestRoot: "/")
    {
        wasmCWD = guestPath
    } else if wasmHostPathIsUsableByWasmer(wasmCWDHost) {
        wasmCWD = "/workspace"
        mapEntries.append(("/workspace", wasmCWDHost))
        preopens.append(wasmCWDHost)
    } else {
        wasmCWD = "/"
    }

    if let gpuRuntime, wasmHostPathIsUsableByWasmer(gpuRuntime.path) {
        preopens.append(gpuRuntime.path)
        mapEntries.append(("/opt/hetgpu", gpuRuntime.path))
    }
    preopens = preopens.reduce(into: [String]()) { result, path in
        guard wasmHostPathIsUsableByWasmer(path), !result.contains(path) else { return }
        result.append(path)
    }
    if preopens.isEmpty {
        unsetenv("WASM_PREOPENS")
    } else {
        setenv("WASM_PREOPENS", preopens.joined(separator: ":"), 1)
    }

    let mapDirs = mapEntries.compactMap { entry -> String? in
        guard wasmHostPathIsUsableByWasmer(entry.host) else { return nil }
        return "\(entry.guest)::\(entry.host)"
    }
    if mapDirs.isEmpty {
        unsetenv("WASM_MAP_DIRS")
    } else {
        setenv("WASM_MAP_DIRS", mapDirs.joined(separator: ";"), 1)
    }

    setenv("WASM_CWD", wasmCWD, 1)
    setenv("PWD", wasmCWD, 1)
    // Guest-only HOME override, applied by the runtime so the host HOME
    // (used by node/npm and ios_system commands) is left untouched.
    setenv("WASM_GUEST_HOME", wasmCWD == "/" ? "/" : "/home", 1)

    // AOT artifact cache, used when the runtime selects a compiling engine.
    let aotCache = homeURL.appendingPathComponent("Library/Caches/wasmer-aot")
    try? fileManager.createDirectory(at: aotCache, withIntermediateDirectories: true)
    setenv("WASM_AOT_CACHE", aotCache.path, 1)
}

func configureWASMGPURuntime(backend explicitBackend: String?) -> URL? {
    guard let selectedBackend = explicitBackend else {
        clearWASMGPURuntimeEnv()
        return nil
    }
    guard selectedBackend == "ane" || selectedBackend == "metal" else {
        clearWASMGPURuntimeEnv()
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
        unsetenv("CODIFYONE_HETGPU_ROOT")
        setenv("HETGPU_APPLE_BACKEND", selectedBackend, 1)
        setenv("WASM_CUDA_ACCEL", "1", 1)
        setenv("WASM_CUDA_BACKEND", selectedBackend, 1)
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

func clearWASMGPURuntimeEnv() {
    unsetenv("WASM_CUDA_ACCEL")
    unsetenv("WASM_CUDA_BACKEND")
    unsetenv("HETGPU_APPLE_BACKEND")
    unsetenv("CODIFYONE_HETGPU_ROOT")
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
