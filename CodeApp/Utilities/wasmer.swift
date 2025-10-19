//
//  wasmer.swift
//  Code
//
//  Native Wasmer integration with WASIX p1 support
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

// Command entry point for "wasmer" command
@_cdecl("wasmer")
public func wasmer(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    let args = convertCArguments(argc: argc, argv: argv)
    return executeWasmerNative(arguments: args)
}

private func executeWasmerNative(arguments: [String]?) -> Int32 {
    guard let arguments = arguments, arguments.count >= 2 else {
        fputs("Usage: wasmer <wasm-file> [args...]\n", thread_stderr)
        fputs("       wasmer --version\n", thread_stderr)
        return -1
    }

    // Handle --version flag
    if arguments[1] == "--version" || arguments[1] == "-v" {
        let version = String(cString: wasmer_version())
        fputs("\(version)\n", thread_stdout)
        return 0
    }

    let wasmFile = arguments[1]
    let currentDirectory = FileManager.default.currentDirectoryPath
    let fileName = wasmFile.hasPrefix("/") ? wasmFile : currentDirectory + "/" + wasmFile

    // Load WASM file
    guard let wasmData = try? Data(contentsOf: URL(fileURLWithPath: fileName)) else {
        fputs("wasmer: file '\(wasmFile)' not found\n", thread_stderr)
        return -1
    }

    // Prepare arguments for the WASM module
    // First argument should be the program name (wasm file)
    let wasmArgs = Array(arguments.dropFirst())

    // Convert Swift strings to C strings
    var cStrings: [UnsafeMutablePointer<Int8>?] = wasmArgs.map { arg in
        let cString = strdup(arg)
        return cString
    }
    cStrings.append(nil) // Null-terminate the array

    defer {
        // Clean up allocated C strings
        for cString in cStrings where cString != nil {
            free(cString)
        }
    }

    // Get file descriptors for stdin/stdout/stderr
    let stdinFd = fileno(thread_stdin)
    let stdoutFd = fileno(thread_stdout)
    let stderrFd = fileno(thread_stderr)

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
