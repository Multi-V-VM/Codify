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

private func executeWebAssembly(arguments: [String]?) -> Int32 {
    
    guard let arguments = arguments, arguments.count >= 2 else {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs("Usage: wasm <wasm-file> [args...]\n", stderr)
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

    let wasmFile = arguments[1]
    let currentDirectory = resolvedWASMCurrentDirectory(FileManager.default.currentDirectoryPath)
    let fileName = wasmFile.hasPrefix("/") ? wasmFile : currentDirectory + "/" + wasmFile

    setupWASMSysroot(currentDirectory: currentDirectory)

    // Load WASM file
    guard let wasmData = try? Data(contentsOf: URL(fileURLWithPath: fileName)) else {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs("wasm: file '\(wasmFile)' not found\n", stderr)
        return -1
    }

    // Prepare arguments for the WASM module
    // First argument should be the program name (wasm file)
    let wasmArgs = Array(arguments.dropFirst())

    // Convert Swift strings to C strings
    var cStrings: [UnsafePointer<Int8>?] = wasmArgs.map { arg in
        let cString = strdup(arg)
        return UnsafePointer(cString)
    }
    cStrings.append(nil) // Null-terminate the array

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

/// Root of the persistent guest filesystem skeleton (/tmp, /home, /etc, Tools)
/// exposed to every WASM program.
func wasmSysrootURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/wasm-sysroot")
}

func resolvedWASMCurrentDirectory(_ currentDirectory: String) -> String {
    let fileManager = FileManager.default
    let home = NSHomeDirectory()
    let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: home).appendingPathComponent("Documents")

    try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: currentDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
        return currentDirectory
    }

    if currentDirectory == home || currentDirectory.hasPrefix(home + "/") {
        try? fileManager.createDirectory(
            at: URL(fileURLWithPath: currentDirectory), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: currentDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
            return currentDirectory
        }
    }

    if fileManager.fileExists(atPath: documentsURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
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
func setupWASMSysroot(currentDirectory: String) {
    let fileManager = FileManager.default
    let home = NSHomeDirectory()
    let sysroot = wasmSysrootURL()
    let resolvedCurrentDirectory = resolvedWASMCurrentDirectory(currentDirectory)

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
    let mapDirs = [
        "/tmp::\(sysroot.appendingPathComponent("tmp").path)",
        "/usr::\(usrHost)",
    ]
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
