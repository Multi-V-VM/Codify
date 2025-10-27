//
//  python.swift
//  Code
//
//  Swift wrappers for running CPython (WASI/WASIX) via Wasmer.
//

import Foundation
import ios_system

// Link to C symbols from Wasmer XCFramework without a bridging header
@_silgen_name("wasmer_python_execute")
func wasmer_python_execute(
    _ pythonBytes: UnsafePointer<UInt8>,
    _ pythonBytesLen: Int,
    _ args: UnsafePointer<UnsafePointer<Int8>?>?,
    _ argsLen: Int,
    _ stdinFd: Int32,
    _ stdoutFd: Int32,
    _ stderrFd: Int32
) -> Int32

private func loadPythonWasm() -> Data? {
    // Allow override via env var for testing
    if let overridePath = getenv("PYTHON_WASM_PATH") {
        let path = String(cString: overridePath)
        if FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
    }

    // Default: load python.wasm from app bundle Resources
    if let url = Bundle.main.url(forResource: "python", withExtension: "wasm"),
       let data = try? Data(contentsOf: url) {
        return data
    }

    fputs("python.wasm not found. Place it in the app bundle or set PYTHON_WASM_PATH.\n", thread_stderr)
    return nil
}

// Entry point for the `python` command in the terminal
@_cdecl("python")
public func swift_python(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    guard let pythonData = loadPythonWasm() else { return -1 }

    // Use original argv as-is (first element typically "python" or "python3")
    // Convert to a null-terminated buffer of C string pointers
    let argsArray = convertCArguments(argc: argc, argv: argv) ?? []
    var cStrings: [UnsafePointer<Int8>?] = argsArray.map { strdup($0) }.map { UnsafePointer($0) }
    cStrings.append(nil)

    defer { cStrings.forEach { if let s = $0 { free(UnsafeMutablePointer(mutating: s)) } } }

    // Forward iOS system pipes
    let stdinFD = fileno(thread_stdin)
    let stdoutFD = fileno(thread_stdout)
    let stderrFD = fileno(thread_stderr)

    return pythonData.withUnsafeBytes { buf -> Int32 in
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return cStrings.withUnsafeBufferPointer { ptr in
            wasmer_python_execute(base, buf.count, ptr.baseAddress, argsArray.count, stdinFD, stdoutFD, stderrFD)
        }
    }
}

// Entry point for the `pip` command, forwards to `python -m pip ...`
@_cdecl("pip")
public func swift_pip(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    guard let pythonData = loadPythonWasm() else { return -1 }

    // Build argv: ["python", "-m", "pip", <original args after argv[0]>]
    var args = [String]()
    args.append("python")
    args.append("-m")
    args.append("pip")
    if let orig = convertCArguments(argc: argc, argv: argv) {
        if orig.count > 1 {
            args.append(contentsOf: orig.dropFirst())
        }
    }

    var cStrings: [UnsafePointer<Int8>?] = args.map { strdup($0) }.map { UnsafePointer($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { if let s = $0 { free(UnsafeMutablePointer(mutating: s)) } } }

    let stdinFD = fileno(thread_stdin)
    let stdoutFD = fileno(thread_stdout)
    let stderrFD = fileno(thread_stderr)

    return pythonData.withUnsafeBytes { buf -> Int32 in
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        return cStrings.withUnsafeBufferPointer { ptr in
            wasmer_python_execute(base, buf.count, ptr.baseAddress, args.count, stdinFD, stdoutFD, stderrFD)
        }
    }
}

