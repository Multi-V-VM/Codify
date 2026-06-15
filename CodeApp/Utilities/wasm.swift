//
//  wasm.swift
//  Code
//
//  Native Wasmer-based WASM execution (migrated from JavaScript)
//  Backup of old implementation saved as wasm.swift.backup
//

import Darwin
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

@_silgen_name("_NSGetEnviron")
func codifyNSGetEnviron() -> UnsafeMutablePointer<
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
>

private struct WASMImportEntry {
    let module: String
    let name: String
    let kind: UInt8
}

private struct WASMMemoryEntry {
    let minimumPages: UInt64
    let maximumPages: UInt64?
    let isShared: Bool
}

private struct WASMModuleSummary {
    let imports: [WASMImportEntry]
    let memories: [WASMMemoryEntry]
    let hasStart: Bool
    let exports: [String]
}

private func readWASMULEB(_ bytes: [UInt8], _ offset: inout Int, end: Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while offset < end {
        let byte = bytes[offset]
        offset += 1
        result |= UInt64(byte & 0x7F) << shift
        if byte < 0x80 { return result }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}

private func readWASMName(_ bytes: [UInt8], _ offset: inout Int, end: Int) -> String? {
    guard let length = readWASMULEB(bytes, &offset, end: end) else { return nil }
    let nameEnd = offset + Int(length)
    guard nameEnd <= end else { return nil }
    defer { offset = nameEnd }
    return String(bytes: bytes[offset..<nameEnd], encoding: .utf8)
}

private func readWASMLimits(_ bytes: [UInt8], _ offset: inout Int, end: Int) -> WASMMemoryEntry? {
    guard let flags = readWASMULEB(bytes, &offset, end: end),
        let minimum = readWASMULEB(bytes, &offset, end: end)
    else { return nil }
    let maximum = (flags & 1) != 0 ? readWASMULEB(bytes, &offset, end: end) : nil
    return WASMMemoryEntry(minimumPages: minimum, maximumPages: maximum, isShared: (flags & 2) != 0)
}

private func readWASMModuleSummary(from data: Data) -> WASMModuleSummary? {
    let bytes = [UInt8](data)
    guard bytes.count >= 8,
        bytes[0] == 0x00, bytes[1] == 0x61, bytes[2] == 0x73, bytes[3] == 0x6D
    else { return nil }

    var offset = 8
    var imports = [WASMImportEntry]()
    var memories = [WASMMemoryEntry]()
    var hasStart = false
    var exports = [String]()

    while offset < bytes.count {
        let sectionID = bytes[offset]
        offset += 1
        guard let sectionSize = readWASMULEB(bytes, &offset, end: bytes.count) else { return nil }
        let sectionEnd = offset + Int(sectionSize)
        guard sectionEnd <= bytes.count else { return nil }

        switch sectionID {
        case 2:
            guard let importCount = readWASMULEB(bytes, &offset, end: sectionEnd) else {
                return nil
            }
            for _ in 0..<importCount {
                guard let module = readWASMName(bytes, &offset, end: sectionEnd),
                    let name = readWASMName(bytes, &offset, end: sectionEnd),
                    offset < sectionEnd
                else { return nil }
                let kind = bytes[offset]
                offset += 1
                imports.append(WASMImportEntry(module: module, name: name, kind: kind))

                switch kind {
                case 0:
                    _ = readWASMULEB(bytes, &offset, end: sectionEnd)
                case 1:
                    offset += 1
                    guard readWASMLimits(bytes, &offset, end: sectionEnd) != nil else { return nil }
                case 2:
                    guard let memory = readWASMLimits(bytes, &offset, end: sectionEnd) else {
                        return nil
                    }
                    memories.append(memory)
                case 3:
                    offset += 2
                    guard offset <= sectionEnd else { return nil }
                default:
                    return nil
                }
            }
        case 5:
            guard let memoryCount = readWASMULEB(bytes, &offset, end: sectionEnd) else {
                return nil
            }
            for _ in 0..<memoryCount {
                guard let memory = readWASMLimits(bytes, &offset, end: sectionEnd) else {
                    return nil
                }
                memories.append(memory)
            }
        case 7:
            guard let exportCount = readWASMULEB(bytes, &offset, end: sectionEnd) else {
                return nil
            }
            for _ in 0..<exportCount {
                guard let name = readWASMName(bytes, &offset, end: sectionEnd), offset < sectionEnd
                else { return nil }
                offset += 1
                _ = readWASMULEB(bytes, &offset, end: sectionEnd)
                exports.append(name)
            }
        case 8:
            hasStart = true
        default:
            break
        }

        offset = sectionEnd
    }

    return WASMModuleSummary(
        imports: imports, memories: memories, hasStart: hasStart, exports: exports)
}

private func wasmRuntimeCompatibilityIssue(_ summary: WASMModuleSummary) -> String? {
    for entry in summary.imports {
        if entry.module.hasPrefix("wasix_") {
            return
                "module imports WASIX runtime feature \(entry.module).\(entry.name); rebuild it as WASI preview1"
        }
        if entry.module == "env", entry.name.hasPrefix("__wasi_") {
            return
                "module imports \(entry.module).\(entry.name); clang linked WASI syscalls with the wrong import ABI"
        }
        if entry.module == "env", entry.kind == 2 {
            return
                "module imports host memory env.\(entry.name), which this Wasmer bridge does not provide"
        }
    }

    if summary.memories.isEmpty {
        return "module defines no linear memory"
    }

    if summary.imports.contains(where: { $0.module == "wasi_snapshot_preview1" })
        && summary.exports.contains("_start")
        && summary.memories.allSatisfy({ $0.minimumPages < 16 })
    {
        return
            "module initial memory is too small for WASI startup (\(summary.memories.map { String($0.minimumPages) }.joined(separator: ",")) pages); rebuild it with clang so --initial-memory is applied"
    }

    return nil
}

private func wasmModuleDiagnostic(_ summary: WASMModuleSummary) -> String {
    let importModules = Set(summary.imports.map(\.module)).sorted().joined(separator: ",")
    let memories = summary.memories.map { memory -> String in
        let maximum = memory.maximumPages.map(String.init) ?? "none"
        let shared = memory.isShared ? ",shared" : ""
        return "\(memory.minimumPages)..\(maximum)\(shared)"
    }.joined(separator: ",")
    let hasStartExport = summary.exports.contains("_start")
    return
        "imports=[\(importModules)] memory=[\(memories)] startSection=\(summary.hasStart) exportsStart=\(hasStartExport)"
}

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

    guard let moduleSummary = readWASMModuleSummary(from: wasmData) else {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs("wasm: input is not a valid WebAssembly module\n", stderr)
        return -1
    }

    let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
    fputs("wasm: module \(wasmModuleDiagnostic(moduleSummary))\n", stderr)
    fflush(stderr)
    if let issue = wasmRuntimeCompatibilityIssue(moduleSummary) {
        fputs("wasm: \(issue)\n", stderr)
        fflush(stderr)
        return -1
    }

    // Prepare arguments for the WASM module. WASI argv[0] is a guest-visible
    // program name; keep host container paths out of argv because the Wasmer
    // bridge writes these strings into guest memory during args_get.
    let userArgs = Array(arguments.dropFirst(commandOptions.wasmIndex + 1))
    let wasmProgramName = URL(fileURLWithPath: fileName).lastPathComponent
    let wasmArgs = [wasmProgramName] + userArgs
    fputs("wasm: argvCount=\(wasmArgs.count) argv0=\(wasmProgramName)\n", stderr)
    fflush(stderr)

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
    // Avoid installing a custom stdin VirtualFile for non-interactive WASI runs.
    // The bridge's FD wrapper is intentionally minimal; libc startup probes can
    // fail on stdin metadata even when the program does not read input.
    let stdinFd: Int32 = -1
    let stdoutFd: Int32 = (thread_stdout != nil) ? fileno(thread_stdout) : STDOUT_FILENO
    let stderrFd: Int32 = (thread_stderr != nil) ? fileno(thread_stderr) : STDERR_FILENO
    fputs("wasm: fds stdin=\(stdinFd) stdout=\(stdoutFd) stderr=\(stderrFd)\n", stderr)
    fflush(stderr)

    // Execute WASM with native Wasmer. The iOS bridge inherits process
    // environment into WASI, so keep it tiny while the module starts.
    let exitCode = withMinimalWASMProcessEnvironment(stderr: stderr) {
        withProcessStderrRedirected(to: stderrFd) {
            wasmData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
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
        }
    }

    fputs("wasm: exitCode=\(exitCode)\n", stderr)
    if exitCode != 0 {
        fputs("wasm: nonzero exit from Wasmer/WASI execution\n", stderr)
    }
    fflush(stderr)

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

    candidates.append(
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("CodifyOne-wasm-\(uid)", isDirectory: true))
    candidates.append(
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("CodifyOne-wasm-\(uid)", isDirectory: true))

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

    if wasmHostDirectoryExists(currentDirectory), wasmHostPathIsWasmRuntime(currentDirectory) {
        return currentDirectory
    }

    if wasmHostPathIsAppContainer(currentDirectory)
        && (currentDirectory.hasSuffix("/Documents")
            || currentDirectory.hasSuffix("/Data/Documents"))
    {
        let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
        fputs(
            "wasm: using internal cwd because container Documents is not valid for Wasmer\n",
            stderr)
        fflush(stderr)
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

func wasmHostPathIsWasmRuntime(_ path: String) -> Bool {
    path.contains("/CodifyOne-wasm/")
        || path.hasSuffix("/CodifyOne-wasm")
        || path.contains("/CodifyOne-wasm-")
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

    if wasmCWD == "/" {
        unsetenv("WASM_CWD")
    } else {
        setenv("WASM_CWD", wasmCWD, 1)
    }
    setenv("PWD", wasmCWD, 1)
    // Guest-only HOME override, applied by the runtime so the host HOME
    // (used by node/npm and ios_system commands) is left untouched.
    setenv("WASM_GUEST_HOME", wasmCWD == "/" ? "/" : "/home", 1)

    // AOT artifact cache, used when the runtime selects a compiling engine.
    // Keep the env value short: the iOS bridge copies env strings into guest
    // memory during startup and long app-container paths can trap there.
    let aotCacheName = "aot-cache"
    let aotCache = runtimeHomeURL.appendingPathComponent(aotCacheName, isDirectory: true)
    try? fileManager.createDirectory(at: aotCache, withIntermediateDirectories: true)
    if gpuBackend != nil {
        setenv("WASM_AOT_CACHE", aotCacheName, 1)
    } else {
        unsetenv("WASM_AOT_CACHE")
    }

    logWASMRuntimeEnvironment(
        wasmCWD: wasmCWD,
        runtimeRootPath: runtimeRootPath,
        preopens: preopens,
        mapDirs: mapDirs,
        aotCachePath: aotCacheName)
}

func logWASMRuntimeEnvironment(
    wasmCWD: String,
    runtimeRootPath: String,
    preopens: [String],
    mapDirs: [String],
    aotCachePath: String
) {
    let stderr = thread_stderr ?? fdopen(STDERR_FILENO, "w")
    let preopenLength = preopens.joined(separator: ":").utf8.count
    let mapDirsLength = mapDirs.joined(separator: ";").utf8.count
    fputs(
        "wasm: env cwd=\(wasmCWD) runtime=\(runtimeRootPath) preopens=\(preopens.count)/\(preopenLength) mapDirs=\(mapDirs.count)/\(mapDirsLength) aotLen=\(aotCachePath.utf8.count)\n",
        stderr)
    fflush(stderr)
}

private func snapshotProcessEnvironment() -> [String: String] {
    var snapshot = [String: String]()
    guard let environment = codifyNSGetEnviron().pointee else { return snapshot }

    var index = 0
    while let entry = environment[index] {
        let pair = String(cString: entry)
        if let separator = pair.firstIndex(of: "=") {
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            snapshot[key] = value
        }
        index += 1
    }
    return snapshot
}

private func setEnvironmentValue(_ name: String, _ value: String?) {
    if let value {
        setenv(name, value, 1)
    } else {
        unsetenv(name)
    }
}

private func withProcessStderrRedirected<T>(to stderrFd: Int32, _ body: () -> T) -> T {
    guard stderrFd >= 0, stderrFd != STDERR_FILENO else {
        return body()
    }

    let savedStderr = dup(STDERR_FILENO)
    if savedStderr >= 0 {
        fflush(stderr)
        _ = dup2(stderrFd, STDERR_FILENO)
    }

    defer {
        if savedStderr >= 0 {
            fflush(stderr)
            _ = dup2(savedStderr, STDERR_FILENO)
            close(savedStderr)
        }
    }

    return body()
}

private func withMinimalWASMProcessEnvironment<T>(
    stderr: UnsafeMutablePointer<FILE>?,
    _ body: () -> T
) -> T {
    let snapshot = snapshotProcessEnvironment()
    let retainedKeys = [
        "CODIFYONE_HETGPU_ROOT",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "HETGPU_APPLE_BACKEND",
        "LD_LIBRARY_PATH",
        "PROTON_WASM_DISPLAY",
        "PROTON_WASM_DISPLAY_FORMAT",
        "PROTON_WASM_PREFIX_ROOT",
        "PROTON_WASM_RUNTIME_ROOT",
        "WASM_CUDA_ACCEL",
        "WASM_CUDA_BACKEND",
        "WASM_PREOPENS",
        "WASM_MAP_DIRS",
        "WASM_CWD",
        "WASM_GUEST_HOME",
        "WASM_AOT_CACHE",
        "PWD",
    ]
    let retained = retainedKeys.reduce(into: [String: String]()) { result, key in
        if let value = snapshot[key], !value.isEmpty {
            result[key] = value
        }
    }

    for key in snapshot.keys {
        unsetenv(key)
    }
    for (key, value) in retained {
        setenv(key, value, 1)
    }

    let retainedLength = retained.reduce(0) { partial, entry in
        partial + entry.key.utf8.count + entry.value.utf8.count + 2
    }
    if let stderr {
        let retainedNames = retained.keys.sorted().joined(separator: ",")
        fputs(
            "wasm: minimal env kept=\(retained.count)/\(retainedLength) original=\(snapshot.count) keys=[\(retainedNames)]\n",
            stderr)
        fflush(stderr)
    }

    defer {
        for key in snapshot.keys {
            unsetenv(key)
        }
        for (key, value) in snapshot {
            setenv(key, value, 1)
        }
    }

    return body()
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
