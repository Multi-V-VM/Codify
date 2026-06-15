//
//  WasminspectService.swift
//  Code
//
//  Wasminspect debugger integration via Wasmer.
//  Provides LLDB-style debugging for WebAssembly programs with DWARF support.
//

import Combine
import Foundation

// Note: wasmer_execute is declared in CodeApp/Utilities/wasm.swift
// Both DebuggerService and WasminspectService use that global declaration

class WasminspectService: ObservableObject {
    static let shared = WasminspectService()

    enum State: Equatable {
        case disconnected
        case launching
        case connected
        case running
        case stopped
        case error(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var logLines: [String] = []
    @Published private(set) var stackFrames: [StackFrame] = []
    @Published private(set) var localVariables: [Variable] = []
    @Published private(set) var globalVariables: [Variable] = []
    @Published private(set) var breakpoints: [Breakpoint] = []
    @Published private(set) var currentLocation: (file: String, line: Int)? = nil

    // Paths
    @Published var wasminspectWasmPath: String = ""
    @Published var targetWasmPath: String = ""
    @Published var targetArgs: String = ""

    private var stdinWriteFD: Int32 = -1
    private var stdoutReadFD: Int32 = -1
    private var stderrReadFD: Int32 = -1

    private var readSourceOut: DispatchSourceRead?
    private var readSourceErr: DispatchSourceRead?
    private var workerTask: Task<Void, Never>?
    private var outputBuffer: String = ""

    // Data models
    struct StackFrame {
        let id: Int
        let name: String
        let file: String?
        let line: Int
        let column: Int
    }

    struct Variable {
        let name: String
        let type: String
        let value: String
    }

    struct Breakpoint {
        let id: Int
        let file: String
        let line: Int
        var verified: Bool
    }

    private var nextBreakpointId = 1
    private var breakpointMap: [String: Breakpoint] = [:]  // "file:line" -> Breakpoint

    private init() {}

    func configureDefaultsIfNeeded() {
        if wasminspectWasmPath.isEmpty,
            let resolved = WasminspectService.resolveDebuggerWasm()
        {
            wasminspectWasmPath = resolved
        }
    }

    /// Locate wasminspect.wasm: app bundle, Documents/Tools, the wasm sysroot
    /// Tools directory, legacy VISX packages, or installed VSIX extensions.
    static func resolveDebuggerWasm() -> String? {
        if let url = Bundle.main.url(forResource: "wasminspect", withExtension: "wasm") {
            return url.path
        }

        let fileManager = FileManager.default
        var candidates: [String] = []
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("Tools/wasminspect.wasm").path)
            candidates.append(docs.appendingPathComponent("wasminspect.wasm").path)
            candidates.append(
                docs.appendingPathComponent("VISX/Packages/WASM/wasminspect/wasminspect.wasm")
                    .path)
            appendWasminspectCandidates(
                under: docs.appendingPathComponent("Extensions", isDirectory: true),
                to: &candidates)
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        {
            appendWasminspectCandidates(
                under: appSupport.appendingPathComponent("Extensions", isDirectory: true),
                to: &candidates)
        }
        candidates.append(
            wasmSysrootURL().appendingPathComponent("Tools/wasminspect.wasm").path)

        return candidates.first { fileManager.fileExists(atPath: $0) }
    }

    static func normalizedDebuggerPath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path.removeFirst()
            path.removeLast()
        }
        if path.hasPrefix("'") && path.hasSuffix("'") && path.count >= 2 {
            path.removeFirst()
            path.removeLast()
        }
        if let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        return NSString(string: path).expandingTildeInPath
    }

    static func resolveTargetWasmPath(
        _ rawPath: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        let path = normalizedDebuggerPath(rawPath)
        guard !path.isEmpty else { return nil }

        let fileManager = FileManager.default
        var candidates: [String] = []
        if path.hasPrefix("/") {
            candidates.append(path)
        } else {
            candidates.append(
                URL(fileURLWithPath: currentDirectory).appendingPathComponent(path).path)
            if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                candidates.append(docs.appendingPathComponent(path).path)
            }
        }

        return candidates.first { fileManager.fileExists(atPath: $0) }
    }

    private static func appendWasminspectCandidates(under root: URL, to candidates: inout [String])
    {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for case let fileURL as URL in enumerator
        where fileURL.lastPathComponent == "wasminspect.wasm" {
            candidates.append(fileURL.path)
        }
    }

    static func debuggerWasmCompatibilityIssue(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "Failed to read wasminspect.wasm at \(path)"
        }
        guard data.count >= 8, Array(data.prefix(4)) == [0x00, 0x61, 0x73, 0x6D] else {
            return "wasminspect.wasm is not a valid WebAssembly module"
        }

        let bytes = [UInt8](data)
        var offset = 8
        var importsWasix = false
        var importsHostMemory = false

        func readULEB(_ offset: inout Int) -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        func readName(_ offset: inout Int) -> String? {
            guard let length = readULEB(&offset), offset + Int(length) <= bytes.count else {
                return nil
            }
            let nameBytes = bytes[offset..<offset + Int(length)]
            offset += Int(length)
            return String(bytes: nameBytes, encoding: .utf8)
        }

        while offset < bytes.count {
            let sectionID = bytes[offset]
            offset += 1
            guard let sectionSize = readULEB(&offset), offset + Int(sectionSize) <= bytes.count
            else {
                break
            }
            let sectionEnd = offset + Int(sectionSize)

            if sectionID == 2 {
                guard let importCount = readULEB(&offset) else { break }
                for _ in 0..<importCount {
                    guard let module = readName(&offset), readName(&offset) != nil,
                        offset < sectionEnd
                    else {
                        break
                    }
                    let kind = bytes[offset]
                    offset += 1

                    if module.hasPrefix("wasix_") {
                        importsWasix = true
                    }
                    if module == "env", kind == 2 {
                        importsHostMemory = true
                    }

                    switch kind {
                    case 0:
                        _ = readULEB(&offset)
                    case 1:
                        offset += 1
                        guard let flags = readULEB(&offset), readULEB(&offset) != nil else { break }
                        if flags & 1 != 0 { _ = readULEB(&offset) }
                    case 2:
                        guard let flags = readULEB(&offset), readULEB(&offset) != nil else { break }
                        if flags & 1 != 0 { _ = readULEB(&offset) }
                    case 3:
                        offset += 2
                    default:
                        offset = sectionEnd
                    }
                }
                break
            }

            offset = sectionEnd
        }

        if importsWasix || importsHostMemory {
            return
                "This wasminspect.wasm imports \(importsWasix ? "WASIX" : "host") runtime features that CodifyOne's iOS Wasmer bridge cannot run safely. Install a WASI preview1 command build of wasminspect.wasm."
        }

        return nil
    }

    func launch() {
        guard FileManager.default.fileExists(atPath: wasminspectWasmPath) else {
            state = .error("wasminspect.wasm not found at \(wasminspectWasmPath)")
            return
        }
        if let issue = Self.debuggerWasmCompatibilityIssue(at: wasminspectWasmPath) {
            state = .error(issue)
            return
        }

        guard let resolvedTargetWasmPath = Self.resolveTargetWasmPath(targetWasmPath) else {
            state = .error("Target WASM not found at \(targetWasmPath)")
            return
        }
        targetWasmPath = resolvedTargetWasmPath

        state = .launching
        log("Launching wasminspect for \(resolvedTargetWasmPath)…")

        // The debugger runs as a WASI guest and reads the target module (and
        // its DWARF sources) through the virtual filesystem — set up the
        // sysroot so those host paths are reachable.
        let targetDirectory = URL(fileURLWithPath: resolvedTargetWasmPath)
            .deletingLastPathComponent().path
        setupWASMSysroot(currentDirectory: targetDirectory)

        // Build argv
        var argv: [String] = ["wasminspect", resolvedTargetWasmPath]
        if !targetArgs.isEmpty {
            argv.append(contentsOf: targetArgs.split(separator: " ").map(String.init))
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
        let wasmURL = URL(fileURLWithPath: wasminspectWasmPath)
        guard let data = try? Data(contentsOf: wasmURL) else {
            state = .error("Failed to read wasminspect.wasm")
            return
        }

        // Convert argv -> C argv
        var cStrings: [UnsafePointer<Int8>?] = argv.map { UnsafePointer(strdup($0)) }
        cStrings.append(nil)

        workerTask = Task.detached { [weak self] in
            guard let self = self else { return }
            let exitCode: Int32 = data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                return cStrings.withUnsafeBufferPointer { ptr in
                    wasmer_execute(
                        base,
                        buf.count,
                        ptr.baseAddress!,
                        argv.count,
                        inPipe[0],  // stdin read end
                        outPipe[1],  // stdout write end
                        errPipe[1]  // stderr write end
                    )
                }
            }
            // Cleanup C strings
            for s in cStrings where s != nil { free(UnsafeMutablePointer(mutating: s)) }
            DispatchQueue.main.async {
                self.log("wasminspect exited with code \(exitCode)")
                self.state = .disconnected
                self.teardown()
            }
        }

        // Wait for prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.state == .launching {
                self.state = .stopped
                self.log("Debugger ready. Program stopped at entry point.")
            }
        }
    }

    func terminate() {
        sendCommand("quit")
        teardown()
        state = .disconnected
    }

    private func teardown() {
        if stdinWriteFD >= 0 {
            close(stdinWriteFD)
            stdinWriteFD = -1
        }
        if stdoutReadFD >= 0 {
            close(stdoutReadFD)
            stdoutReadFD = -1
        }
        if stderrReadFD >= 0 {
            close(stderrReadFD)
            stderrReadFD = -1
        }
        readSourceOut?.cancel()
        readSourceOut = nil
        readSourceErr?.cancel()
        readSourceErr = nil
        workerTask?.cancel()
        workerTask = nil
    }

    // MARK: - Commands

    func sendCommand(_ cmd: String) {
        guard stdinWriteFD >= 0 else { return }
        let line = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
        line.withCString { cstr in
            let len = strlen(cstr)
            _ = write(stdinWriteFD, cstr, len)
        }
        log("→ \(cmd)")
    }

    func execRun() {
        state = .running
        sendCommand("process launch")
    }

    func execContinue() {
        state = .running
        sendCommand("process continue")
    }

    func stepOver() {
        sendCommand("thread step-over")
    }

    func stepIn() {
        sendCommand("thread step-in")
    }

    func stepOut() {
        sendCommand("thread step-out")
    }

    func setBreakpoint(file: String, line: Int) {
        let key = "\(file):\(line)"
        if breakpointMap[key] != nil {
            // Already exists
            return
        }

        let bp = Breakpoint(
            id: nextBreakpointId,
            file: file,
            line: line,
            verified: false
        )
        nextBreakpointId += 1

        breakpointMap[key] = bp
        breakpoints.append(bp)

        // Try to set breakpoint in wasminspect
        sendCommand("breakpoint set --file \"\(file)\" --line \(line)")
    }

    func deleteBreakpoint(file: String, line: Int) {
        let key = "\(file):\(line)"
        guard let bp = breakpointMap[key] else { return }

        breakpointMap.removeValue(forKey: key)
        breakpoints.removeAll { $0.id == bp.id }

        // Send delete command (wasminspect uses IDs internally)
        sendCommand("breakpoint delete \(bp.id)")
    }

    func toggleBreakpoint(file: String, line: Int) {
        let key = "\(file):\(line)"
        if breakpointMap[key] != nil {
            deleteBreakpoint(file: file, line: line)
        } else {
            setBreakpoint(file: file, line: line)
        }
    }

    func requestBacktrace() {
        sendCommand("thread backtrace")
    }

    func requestLocalVariables() {
        sendCommand("frame variable")
    }

    func requestGlobalVariables() {
        sendCommand("target variable")
    }

    func disassemble() {
        sendCommand("disassemble")
    }

    func readMemory(address: String, count: Int) {
        sendCommand("memory read --size \(count) \(address)")
    }

    // MARK: - Output Parsing

    private func startReadLoop(fd: Int32, isErr: Bool) {
        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .userInitiated))
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
        src.setCancelHandler {}
        src.resume()
        if isErr { readSourceErr = src } else { readSourceOut = src }
    }

    private func handleOutput(_ text: String, isErr: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outputBuffer += text

            // Process complete lines
            let lines = self.outputBuffer.components(separatedBy: "\n")
            for i in 0..<lines.count - 1 {
                self.processLine(lines[i])
            }
            self.outputBuffer = lines.last ?? ""

            // Check for prompt
            if self.outputBuffer.contains("(wasminspect)") {
                if self.state == .running {
                    self.state = .stopped
                }
                self.outputBuffer = ""
            }
        }
    }

    private func processLine(_ line: String) {
        log(line)

        // Parse different output formats
        if line.contains("stopped") || line.contains("Process") && line.contains("stopped") {
            state = .stopped
        } else if line.contains("running") {
            state = .running
        } else if line.contains("breakpoint") && line.contains("hit") {
            state = .stopped
            parseBreakpointHit(line)
        } else if line.hasPrefix("frame #") {
            parseStackFrame(line)
        } else if line.contains("at ") && line.contains(":") {
            parseLocation(line)
        } else if line.contains("Breakpoint") && line.contains("set") {
            parseBreakpointSet(line)
        }
    }

    private func parseBreakpointHit(_ line: String) {
        // Example: "Process 1 stopped: breakpoint 1.1"
        // Or: "hit breakpoint at function:line"
        // For now, just trigger stopped state
        log("Breakpoint hit detected")
    }

    private func parseStackFrame(_ line: String) {
        // Example: "frame #0: 0x1234 main at test.c:10:5"
        let pattern = #"frame #(\d+):\s+0x[0-9a-f]+\s+(.+?)(?:\s+at\s+(.+?):(\d+):(\d+))?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
        {

            let idRange = Range(match.range(at: 1), in: line)
            let nameRange = Range(match.range(at: 2), in: line)

            if let idRange = idRange, let nameRange = nameRange {
                let id = Int(line[idRange]) ?? 0
                let name = String(line[nameRange])

                var file: String? = nil
                var lineNum = 0
                var col = 0

                if match.numberOfRanges > 3 {
                    if let fileRange = Range(match.range(at: 3), in: line) {
                        file = String(line[fileRange])
                    }
                    if let lineRange = Range(match.range(at: 4), in: line) {
                        lineNum = Int(line[lineRange]) ?? 0
                    }
                    if let colRange = Range(match.range(at: 5), in: line) {
                        col = Int(line[colRange]) ?? 0
                    }
                }

                let frame = StackFrame(id: id, name: name, file: file, line: lineNum, column: col)

                // Update stack frames list
                if id == 0 {
                    stackFrames = [frame]
                } else if id >= stackFrames.count {
                    stackFrames.append(frame)
                } else {
                    stackFrames[id] = frame
                }

                // Update current location if this is frame 0
                if id == 0, let file = file, lineNum > 0 {
                    currentLocation = (file, lineNum)
                }
            }
        }
    }

    private func parseLocation(_ line: String) {
        // Example: "at test.c:15"
        let pattern = #"at\s+(.+?):(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(
                in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
        {

            if let fileRange = Range(match.range(at: 1), in: line),
                let lineRange = Range(match.range(at: 2), in: line)
            {
                let file = String(line[fileRange])
                if let lineNum = Int(line[lineRange]) {
                    currentLocation = (file, lineNum)
                }
            }
        }
    }

    private func parseBreakpointSet(_ line: String) {
        // Example: "Breakpoint 1: where = test.wasm`main, address = 0x1234"
        // Mark breakpoints as verified
        for (_, var bp) in breakpointMap {
            if !bp.verified {
                bp.verified = true
                breakpointMap["\(bp.file):\(bp.line)"] = bp
                if let idx = breakpoints.firstIndex(where: { $0.id == bp.id }) {
                    breakpoints[idx] = bp
                }
            }
        }
    }

    private func log(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }
}
