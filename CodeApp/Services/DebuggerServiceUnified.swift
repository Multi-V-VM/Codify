//
//  DebuggerServiceUnified.swift
//  Code
//
//  Unified debugger interface supporting both GDB MI2 and Wasminspect backends.
//  Executes gdb.wasm or wasminspect.wasm via Wasmer and provides MI-compatible API.
//
//  USAGE: Rename this file to DebuggerService.swift to replace the original
//

import Foundation
import Combine

// Note: wasmer_execute is declared in CodeApp/Utilities/wasm.swift

class DebuggerService: ObservableObject {
    static let shared = DebuggerService()

    enum DebuggerBackend: String, CaseIterable, Identifiable {
        case gdb = "GDB (MI2)"
        case wasminspect = "Wasminspect (LLDB→MI)"

        var id: String { rawValue }
    }

    enum State: Equatable {
        case disconnected
        case launching
        case connected
        case running
        case stopped
        case error(String)
    }

    // Backend selection
    @Published var selectedBackend: DebuggerBackend = .wasminspect {
        didSet {
            if state != .disconnected {
                NSLog("⚠️ Backend changed while debugger is active. Please disconnect first.")
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var logLines: [String] = []
    @Published private(set) var stackFrames: [String] = []
    @Published private(set) var breakpoints: [String] = []
    @Published private(set) var currentLocation: (file: String, line: Int)? = nil

    // Paths
    @Published var gdbWasmPath: String = ""
    @Published var targetWasmPath: String = ""
    @Published var targetArgs: String = ""

    // GDB backend state
    private var bpIdByKey: [String: String] = [:] // "file:line" -> id
    private var bpKeyById: [String: String] = [:] // id -> "file:line"
    private var stdinWriteFD: Int32 = -1
    private var stdoutReadFD: Int32 = -1
    private var stderrReadFD: Int32 = -1
    private var readSourceOut: DispatchSourceRead?
    private var readSourceErr: DispatchSourceRead?
    private var workerTask: Task<Void, Never>?

    // Wasminspect backend
    private let wasminspectAdapter = WasminspectMIAdapter.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupWasminspectSubscriptions()
    }

    // MARK: - Wasminspect Backend Integration

    private func setupWasminspectSubscriptions() {
        wasminspectAdapter.$state
            .sink { [weak self] adapterState in
                guard let self = self, self.selectedBackend == .wasminspect else { return }
                self.updateStateFromAdapter(adapterState)
            }
            .store(in: &cancellables)

        wasminspectAdapter.$miOutput
            .sink { [weak self] output in
                guard let self = self, self.selectedBackend == .wasminspect else { return }
                self.logLines = output
            }
            .store(in: &cancellables)

        wasminspectAdapter.$stackFrames
            .sink { [weak self] frames in
                guard let self = self, self.selectedBackend == .wasminspect else { return }
                self.stackFrames = frames
            }
            .store(in: &cancellables)

        wasminspectAdapter.$breakpoints
            .sink { [weak self] bps in
                guard let self = self, self.selectedBackend == .wasminspect else { return }
                self.breakpoints = bps
            }
            .store(in: &cancellables)

        wasminspectAdapter.$currentLocation
            .sink { [weak self] location in
                guard let self = self, self.selectedBackend == .wasminspect else { return }
                self.currentLocation = location
            }
            .store(in: &cancellables)
    }

    private func updateStateFromAdapter(_ adapterState: WasminspectMIAdapter.DebuggerState) {
        switch adapterState {
        case .disconnected: state = .disconnected
        case .launching: state = .launching
        case .connected: state = .connected
        case .running: state = .running
        case .stopped: state = .stopped
        case .error(let msg): state = .error(msg)
        }
    }

    // MARK: - Configuration

    func configureDefaultsIfNeeded() {
        switch selectedBackend {
        case .gdb:
            if gdbWasmPath.isEmpty {
                if let url = Bundle.main.url(forResource: "gdb", withExtension: "wasm") {
                    gdbWasmPath = url.path
                } else if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let candidate = docs.appendingPathComponent("Tools/gdb.wasm").path
                    if FileManager.default.fileExists(atPath: candidate) { gdbWasmPath = candidate }
                }
            }

        case .wasminspect:
            wasminspectAdapter.configureDefaultsIfNeeded()
            // Sync paths back
            if wasminspectAdapter.wasminspectWasmPath.isEmpty && !gdbWasmPath.isEmpty {
                wasminspectAdapter.wasminspectWasmPath = gdbWasmPath
            } else if !wasminspectAdapter.wasminspectWasmPath.isEmpty {
                gdbWasmPath = wasminspectAdapter.wasminspectWasmPath
            }

            wasminspectAdapter.targetWasmPath = targetWasmPath
            wasminspectAdapter.targetArgs = targetArgs
        }
    }

    // MARK: - Launch & Terminate

    func launch() {
        switch selectedBackend {
        case .gdb:
            launchGDB()
        case .wasminspect:
            launchWasminspect()
        }
    }

    private func launchGDB() {
        guard FileManager.default.fileExists(atPath: gdbWasmPath) else {
            state = .error("gdb.wasm not found at \(gdbWasmPath)")
            return
        }

        state = .launching
        log("Launching gdb.wasm…")

        var argv: [String] = ["gdb", "--quiet", "--interpreter=mi2"]
        if !targetWasmPath.isEmpty { argv.append(targetWasmPath) }

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

        startReadLoop(fd: stdoutReadFD, isErr: false)
        startReadLoop(fd: stderrReadFD, isErr: true)

        let wasmURL = URL(fileURLWithPath: gdbWasmPath)
        guard let data = try? Data(contentsOf: wasmURL) else {
            state = .error("Failed to read gdb.wasm")
            return
        }

        var cStrings: [UnsafePointer<Int8>?] = argv.map { UnsafePointer(strdup($0)) }
        cStrings.append(nil)

        workerTask = Task.detached { [weak self] in
            guard let self = self else { return }
            let exitCode: Int32 = data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return cStrings.withUnsafeBufferPointer { ptr in
                    wasmer_execute(base, buf.count, ptr.baseAddress!, argv.count, inPipe[0], outPipe[1], errPipe[1])
                }
            }
            for s in cStrings where s != nil { free(UnsafeMutablePointer(mutating: s)) }
            DispatchQueue.main.async {
                self.log("gdb.wasm exited with code \(exitCode)")
                self.state = .disconnected
                self.teardownGDB()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.state = .connected
        }
    }

    private func launchWasminspect() {
        wasminspectAdapter.wasminspectWasmPath = gdbWasmPath
        wasminspectAdapter.targetWasmPath = targetWasmPath
        wasminspectAdapter.targetArgs = targetArgs

        NSLog("🐛 Launching wasminspect backend via MI adapter")
        wasminspectAdapter.launch()
    }

    func terminate() {
        switch selectedBackend {
        case .gdb:
            sendMI("-gdb-exit")
            teardownGDB()
            state = .disconnected
        case .wasminspect:
            wasminspectAdapter.terminate()
        }
    }

    private func teardownGDB() {
        if stdinWriteFD >= 0 { close(stdinWriteFD); stdinWriteFD = -1 }
        if stdoutReadFD >= 0 { close(stdoutReadFD); stdoutReadFD = -1 }
        if stderrReadFD >= 0 { close(stderrReadFD); stderrReadFD = -1 }
        readSourceOut?.cancel(); readSourceOut = nil
        readSourceErr?.cancel(); readSourceErr = nil
        workerTask?.cancel(); workerTask = nil
    }

    // MARK: - MI Commands (Unified Interface)

    func sendMI(_ cmd: String) {
        switch selectedBackend {
        case .gdb:
            sendGDBMI(cmd)
        case .wasminspect:
            wasminspectAdapter.sendMI(cmd)
        }
    }

    private func sendGDBMI(_ cmd: String) {
        guard stdinWriteFD >= 0 else { return }
        let line = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
        line.withCString { cstr in
            let len = strlen(cstr)
            _ = write(stdinWriteFD, cstr, len)
        }
        log("→ \(cmd)")
    }

    func execRun() {
        if selectedBackend == .gdb { state = .running }
        sendMI("-exec-run")
    }

    func execContinue() {
        if selectedBackend == .gdb { state = .running }
        sendMI("-exec-continue")
    }

    func execNext() { sendMI("-exec-next") }
    func execStep() { sendMI("-exec-step") }
    func execFinish() { sendMI("-exec-finish") }

    func fileExecAndSymbols(_ path: String) {
        targetWasmPath = path
        sendMI("-file-exec-and-symbols \"\(path)\"")
    }

    func breakInsert(file: String, line: Int) {
        sendMI("-break-insert \"\(file):\(line)\"")
    }

    func breakDelete(id: String) {
        sendMI("-break-delete \(id)")
    }

    func toggleBreakpoint(file: String, line: Int) {
        switch selectedBackend {
        case .gdb:
            let key = "\(file):\(line)"
            if let id = bpIdByKey[key] {
                breakDelete(id: id)
            } else {
                breakInsert(file: file, line: line)
            }
        case .wasminspect:
            wasminspectAdapter.toggleBreakpoint(file: file, line: line)
        }
    }

    // MARK: - GDB Output Parsing

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
            if let file = extractValue(line, key: "file"), let lineStr = extractValue(line, key: "line"), let ln = Int(lineStr) {
                currentLocation = (file, ln)
            }
        } else if line.hasPrefix("^done") {
            if state == .launching { state = .connected }
        } else if line.contains("=breakpoint-created") {
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
                breakpoints.removeAll { $0.contains("#\(id)") }
            }
        } else if line.hasPrefix("^running") {
            state = .running
        }
    }

    private func extractValue(_ s: String, key: String) -> String? {
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
