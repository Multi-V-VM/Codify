//
//  DebuggerService.swift
//  Code
//
//  GDB (WASM) integration via Wasmer + simple MI2 bridge.
//

import Foundation
import Combine

@_silgen_name("wasmer_execute")
private func wasmer_execute(
    _ wasmBytes: UnsafePointer<UInt8>,
    _ wasmBytesLen: Int,
    _ args: UnsafePointer<UnsafePointer<Int8>?>,
    _ argsLen: Int,
    _ stdinFd: Int32,
    _ stdoutFd: Int32,
    _ stderrFd: Int32
) -> Int32

class DebuggerService: ObservableObject {
    static let shared = DebuggerService()

    enum State {
        case disconnected
        case launching
        case connected
        case running
        case stopped
        case error(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var logLines: [String] = []
    @Published private(set) var stackFrames: [String] = []
    @Published private(set) var breakpoints: [String] = []
    private var bpIdByKey: [String: String] = [:] // "file:line" -> id
    private var bpKeyById: [String: String] = [:] // id -> "file:line"
    @Published private(set) var currentLocation: (file: String, line: Int)? = nil

    // Paths
    @Published var gdbWasmPath: String = ""
    @Published var targetWasmPath: String = ""
    @Published var targetArgs: String = ""

    private var stdinWriteFD: Int32 = -1
    private var stdoutReadFD: Int32 = -1
    private var stderrReadFD: Int32 = -1

    private var readSourceOut: DispatchSourceRead?
    private var readSourceErr: DispatchSourceRead?
    private var workerTask: Task<Void, Never>?

    private init() {}

    func configureDefaultsIfNeeded() {
        if gdbWasmPath.isEmpty {
            // Try common locations
            if let url = Bundle.main.url(forResource: "gdb", withExtension: "wasm") {
                gdbWasmPath = url.path
            } else if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let candidate = docs.appendingPathComponent("Tools/gdb.wasm").path
                if FileManager.default.fileExists(atPath: candidate) { gdbWasmPath = candidate }
            }
        }
    }

    func launch() {
        guard FileManager.default.fileExists(atPath: gdbWasmPath) else {
            state = .error("gdb.wasm not found at \(gdbWasmPath)")
            return
        }

        state = .launching
        log("Launching gdb.wasm…")

        // Build argv for MI mode
        var argv: [String] = ["gdb", "--quiet", "--interpreter=mi2"]
        if !targetWasmPath.isEmpty {
            argv.append(targetWasmPath)
        }

        // Create pipes
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            state = .error("Failed to create pipes")
            return
        }

        stdinWriteFD = inPipe[1]
        stdoutReadFD = outPipe[0]
        stderrReadFD = errPipe[0]

        // Start reading stdout/stderr
        startReadLoop(fd: stdoutReadFD, isErr: false)
        startReadLoop(fd: stderrReadFD, isErr: true)

        // Load wasm bytes
        let wasmURL = URL(fileURLWithPath: gdbWasmPath)
        guard let data = try? Data(contentsOf: wasmURL) else {
            state = .error("Failed to read gdb.wasm")
            return
        }

        // Convert argv -> C argv
        var cStrings: [UnsafePointer<Int8>?] = argv.map { UnsafePointer(strdup($0)) }
        cStrings.append(nil)

        workerTask = Task.detached { [weak self] in
            guard let self = self else { return }
            let exitCode: Int32 = data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return cStrings.withUnsafeBufferPointer { ptr in
                    wasmer_execute(
                        base,
                        buf.count,
                        ptr.baseAddress!,
                        argv.count,
                        inPipe[0],  // stdin read end for gdb
                        outPipe[1], // stdout write end for gdb
                        errPipe[1]  // stderr write end for gdb
                    )
                }
            }
            // Cleanup C strings
            for s in cStrings where s != nil { free(UnsafeMutablePointer(mutating: s)) }
            DispatchQueue.main.async {
                self.log("gdb.wasm exited with code \(exitCode)")
                self.state = .disconnected
                self.teardown()
            }
        }

        // Initial MI greeting parsing will set connected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.state = .connected
        }
    }

    func terminate() {
        // Send quit command via MI
        sendMI("-gdb-exit")
        teardown()
        state = .disconnected
    }

    private func teardown() {
        if stdinWriteFD >= 0 { close(stdinWriteFD); stdinWriteFD = -1 }
        if stdoutReadFD >= 0 { close(stdoutReadFD); stdoutReadFD = -1 }
        if stderrReadFD >= 0 { close(stderrReadFD); stderrReadFD = -1 }
        readSourceOut?.cancel(); readSourceOut = nil
        readSourceErr?.cancel(); readSourceErr = nil
        workerTask?.cancel(); workerTask = nil
    }

    // MARK: - MI Commands

    func sendMI(_ cmd: String) {
        guard stdinWriteFD >= 0 else { return }
        let line = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
        line.withCString { cstr in
            let len = strlen(cstr)
            _ = write(stdinWriteFD, cstr, len)
        }
        log("→ \(cmd)")
    }

    func execRun() { state = .running; sendMI("-exec-run") }
    func execContinue() { state = .running; sendMI("-exec-continue") }
    func execNext() { sendMI("-exec-next") }
    func execStep() { sendMI("-exec-step") }
    func execFinish() { sendMI("-exec-finish") }

    func fileExecAndSymbols(_ path: String) {
        sendMI("-file-exec-and-symbols \"\(path)\"")
    }

    func breakInsert(file: String, line: Int) {
        sendMI("-break-insert \"\(file):\(line)\"")
    }

    func breakDelete(id: String) {
        sendMI("-break-delete \(id)")
    }

    func toggleBreakpoint(file: String, line: Int) {
        let key = "\(file):\(line)"
        if let id = bpIdByKey[key] {
            breakDelete(id: id)
        } else {
            breakInsert(file: file, line: line)
        }
    }

    // MARK: - Reading & Parsing

    private func startReadLoop(fd: Int32, isErr: Bool) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let estimated = Int(src.data)
            var buffer = [UInt8](repeating: 0, count: max(estimated, 1024))
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                if let text = String(data: data, encoding: .utf8) {
                    self.handleOutput(text, isErr: isErr)
                }
            }
        }
        src.setCancelHandler { }
        src.resume()
        if isErr { readSourceErr = src } else { readSourceOut = src }
    }

    private func handleOutput(_ text: String, isErr: Bool) {
        DispatchQueue.main.async { [weak self] in
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { lineSub in
                let line = String(lineSub)
                self?.log(line)
                self?.parseMI(line)
            }
        }
    }

    private func log(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func parseMI(_ line: String) {
        if line.hasPrefix("*stopped") {
            state = .stopped
            // Try to extract file:line
            if let file = extractValue(line, key: "file"), let lineStr = extractValue(line, key: "line"), let ln = Int(lineStr) {
                currentLocation = (file, ln)
            }
        } else if line.hasPrefix("^done") {
            if state == .launching { state = .connected }
        } else if line.contains("=breakpoint-created") {
            // Try extract id and location
            let id = extractValue(line, key: "bkpt\\.number") ?? extractValue(line, key: "number")
            let fullname = extractValue(line, key: "fullname") ?? extractValue(line, key: "file")
            let ln = extractValue(line, key: "line")
            if let id = id {
                var display = "bkpt #\(id)"
                if let f = fullname, let l = ln { display += " @ \(f):\(l)" }
                breakpoints.append(display)
                if let f = fullname, let l = ln { let key = "\(f):\(l)"; bpIdByKey[key] = id; bpKeyById[id] = key }
            }
        } else if line.contains("=breakpoint-deleted") {
            if let id = extractValue(line, key: "id") ?? extractValue(line, key: "number") {
                if let key = bpKeyById[id] { bpIdByKey.removeValue(forKey: key) }
                bpKeyById.removeValue(forKey: id)
                // Trim list entry
                breakpoints.removeAll { $0.contains("#\(id)") }
            }
        } else if line.hasPrefix("^running") {
            state = .running
        }
    }

    private func extractValue(_ s: String, key: String) -> String? {
        // simple key="value" or key=value extractor
        let patterns = ["\(key)=\\\"([^\\\"]*)\\\"", "\(key)=([^,}]+)"]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: []) {
                if let m = regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) {
                    if let r = Range(m.range(at: 1), in: s) { return String(s[r]) }
                }
            }
        }
        return nil
    }
}
