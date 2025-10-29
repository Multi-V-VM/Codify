//
//  WasminspectMIAdapter.swift
//  Code
//
//  Adapter layer to convert GDB MI2 commands to Wasminspect LLDB commands
//  and parse LLDB output back to MI format
//

import Foundation
import Combine

/// Adapter that bridges GDB MI2 protocol to Wasminspect LLDB-style commands
class WasminspectMIAdapter: ObservableObject {
    static let shared = WasminspectMIAdapter()

    private let wasminspect = WasminspectService.shared
    private var cancellables = Set<AnyCancellable>()

    // Published state (MI-compatible)
    @Published private(set) var state: DebuggerState = .disconnected
    @Published private(set) var miOutput: [String] = []
    @Published private(set) var stackFrames: [String] = []
    @Published private(set) var breakpoints: [String] = []
    @Published private(set) var currentLocation: (file: String, line: Int)? = nil

    enum DebuggerState {
        case disconnected
        case launching
        case connected
        case running
        case stopped
        case error(String)
    }

    private var nextMIToken = 1
    private var breakpointIdMap: [String: Int] = [:] // "file:line" -> MI breakpoint ID

    private init() {
        // Subscribe to wasminspect state changes
        wasminspect.$state
            .sink { [weak self] wsState in
                self?.updateStateFromWasminspect(wsState)
            }
            .store(in: &cancellables)

        // Subscribe to wasminspect log output
        wasminspect.$logLines
            .sink { [weak self] lines in
                self?.processMIOutput(lines)
            }
            .store(in: &cancellables)

        // Subscribe to wasminspect stack frames
        wasminspect.$stackFrames
            .sink { [weak self] frames in
                self?.updateStackFrames(frames)
            }
            .store(in: &cancellables)

        // Subscribe to wasminspect breakpoints
        wasminspect.$breakpoints
            .sink { [weak self] bps in
                self?.updateBreakpoints(bps)
            }
            .store(in: &cancellables)

        // Subscribe to current location
        wasminspect.$currentLocation
            .sink { [weak self] location in
                self?.currentLocation = location
            }
            .store(in: &cancellables)
    }

    // MARK: - Configuration

    var wasminspectWasmPath: String {
        get { wasminspect.wasminspectWasmPath }
        set { wasminspect.wasminspectWasmPath = newValue }
    }

    var targetWasmPath: String {
        get { wasminspect.targetWasmPath }
        set { wasminspect.targetWasmPath = newValue }
    }

    var targetArgs: String {
        get { wasminspect.targetArgs }
        set { wasminspect.targetArgs = newValue }
    }

    func configureDefaultsIfNeeded() {
        wasminspect.configureDefaultsIfNeeded()
    }

    // MARK: - MI Command Interface

    /// Send a GDB MI2 command (e.g., "-exec-run", "-break-insert", etc.)
    func sendMI(_ cmd: String) {
        let token = nextMIToken
        nextMIToken += 1

        logMI("→ \(token)\(cmd)")

        // Parse and convert MI command to LLDB command
        if let lldbCmd = convertMIToLLDB(cmd, token: token) {
            wasminspect.sendCommand(lldbCmd)
        } else {
            logMI("\(token)^error,msg=\"Unknown MI command: \(cmd)\"")
        }
    }

    // MARK: - MI Command Conversion (MI -> LLDB)

    private func convertMIToLLDB(_ miCmd: String, token: Int) -> String? {
        // Remove token prefix if present
        let cmd = miCmd.hasPrefix("-") ? miCmd : "-" + miCmd

        // MI command mappings to LLDB
        switch {
        case cmd.hasPrefix("-exec-run"):
            return "process launch"

        case cmd.hasPrefix("-exec-continue"):
            return "process continue"

        case cmd.hasPrefix("-exec-next"):
            return "thread step-over"

        case cmd.hasPrefix("-exec-step"):
            return "thread step-in"

        case cmd.hasPrefix("-exec-finish"):
            return "thread step-out"

        case cmd.hasPrefix("-exec-interrupt"):
            return "process interrupt"

        case cmd.hasPrefix("-break-insert"):
            return parseBreakInsert(cmd)

        case cmd.hasPrefix("-break-delete"):
            return parseBreakDelete(cmd)

        case cmd.hasPrefix("-break-list"):
            return "breakpoint list"

        case cmd.hasPrefix("-stack-list-frames"):
            return "thread backtrace"

        case cmd.hasPrefix("-stack-list-variables"):
            return "frame variable"

        case cmd.hasPrefix("-stack-list-locals"):
            return "frame variable --no-args"

        case cmd.hasPrefix("-stack-list-arguments"):
            return "frame variable --no-locals"

        case cmd.hasPrefix("-data-list-register-names"):
            return "register read"

        case cmd.hasPrefix("-data-evaluate-expression"):
            return parseEvaluateExpression(cmd)

        case cmd.hasPrefix("-file-exec-and-symbols"):
            return parseFileExec(cmd)

        case cmd.hasPrefix("-target-select"):
            return nil // Handled internally

        case cmd.hasPrefix("-gdb-exit"):
            return "quit"

        default:
            return nil
        }
    }

    private func parseBreakInsert(_ cmd: String) -> String? {
        // MI: -break-insert "file:line" or -break-insert --source file --line line

        // Pattern 1: -break-insert "file.c:42"
        if let range = cmd.range(of: #""([^"]+):(\d+)""#, options: .regularExpression) {
            let match = String(cmd[range])
            let parts = match.dropFirst().dropLast().split(separator: ":")
            if parts.count == 2, let line = Int(parts[1]) {
                let file = String(parts[0])
                breakpointIdMap["\(file):\(line)"] = breakpointIdMap.count + 1
                return "breakpoint set --file \"\(file)\" --line \(line)"
            }
        }

        // Pattern 2: -break-insert --source file.c --line 42
        let sourcePattern = #"--source\s+(\S+)"#
        let linePattern = #"--line\s+(\d+)"#

        var file: String?
        var line: Int?

        if let sourceMatch = cmd.range(of: sourcePattern, options: .regularExpression) {
            let parts = String(cmd[sourceMatch]).split(separator: " ")
            if parts.count >= 2 {
                file = String(parts[1])
            }
        }

        if let lineMatch = cmd.range(of: linePattern, options: .regularExpression) {
            let parts = String(cmd[lineMatch]).split(separator: " ")
            if parts.count >= 2, let l = Int(parts[1]) {
                line = l
            }
        }

        if let file = file, let line = line {
            breakpointIdMap["\(file):\(line)"] = breakpointIdMap.count + 1
            return "breakpoint set --file \"\(file)\" --line \(line)"
        }

        return nil
    }

    private func parseBreakDelete(_ cmd: String) -> String? {
        // MI: -break-delete N
        let pattern = #"-break-delete\s+(\d+)"#
        if let match = cmd.range(of: pattern, options: .regularExpression) {
            let parts = String(cmd[match]).split(separator: " ")
            if parts.count >= 2, let id = Int(parts[1]) {
                return "breakpoint delete \(id)"
            }
        }
        return nil
    }

    private func parseEvaluateExpression(_ cmd: String) -> String? {
        // MI: -data-evaluate-expression "expr"
        let pattern = #"-data-evaluate-expression\s+"(.+)""#
        if let match = cmd.range(of: pattern, options: .regularExpression) {
            let expr = String(cmd[match])
                .replacingOccurrences(of: "-data-evaluate-expression", with: "")
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return "expression \(expr)"
        }
        return nil
    }

    private func parseFileExec(_ cmd: String) -> String? {
        // MI: -file-exec-and-symbols /path/to/file.wasm
        let parts = cmd.split(separator: " ")
        if parts.count >= 2 {
            let path = String(parts[1])
            targetWasmPath = path
            return nil // Will be handled by launch
        }
        return nil
    }

    // MARK: - LLDB Output Parsing (LLDB -> MI)

    private func processMIOutput(_ lines: [String]) {
        // Convert LLDB output to MI format
        for line in lines.suffix(10) { // Process recent lines
            if !miOutput.contains(line) {
                let miLine = convertLLDBToMI(line)
                if !miLine.isEmpty {
                    miOutput.append(miLine)
                    if miOutput.count > 500 {
                        miOutput.removeFirst(miOutput.count - 500)
                    }
                }
            }
        }
    }

    private func convertLLDBToMI(_ lldbOutput: String) -> String {
        // Convert LLDB output to MI format

        // Breakpoint hit
        if lldbOutput.contains("stopped") && lldbOutput.contains("breakpoint") {
            return "*stopped,reason=\"breakpoint-hit\",thread-id=\"1\""
        }

        // Step complete
        if lldbOutput.contains("stopped") && !lldbOutput.contains("breakpoint") {
            return "*stopped,reason=\"end-stepping-range\",thread-id=\"1\""
        }

        // Running
        if lldbOutput.contains("Process") && lldbOutput.contains("launched") {
            return "*running,thread-id=\"all\""
        }

        // Breakpoint created
        if lldbOutput.contains("Breakpoint") && lldbOutput.contains("set") {
            return "^done,bkpt={number=\"1\",type=\"breakpoint\"}"
        }

        // Stack frame
        if lldbOutput.hasPrefix("frame #") {
            return convertStackFrameToMI(lldbOutput)
        }

        // Default: stream output
        return "~\"\(lldbOutput.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func convertStackFrameToMI(_ frame: String) -> String {
        // Example: frame #0: 0x1234 main at test.c:10:5
        // MI: ^done,stack=[frame={level="0",addr="0x1234",func="main",file="test.c",line="10"}]

        let pattern = #"frame #(\d+):\s+0x([0-9a-f]+)\s+(.+?)(?:\s+at\s+(.+?):(\d+))?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: frame, options: [], range: NSRange(location: 0, length: frame.utf16.count)) {

            var level = "0"
            var addr = "0x0"
            var func = "??"
            var file = ""
            var line = "0"

            if let r = Range(match.range(at: 1), in: frame) { level = String(frame[r]) }
            if let r = Range(match.range(at: 2), in: frame) { addr = "0x" + String(frame[r]) }
            if let r = Range(match.range(at: 3), in: frame) { func = String(frame[r]) }
            if match.numberOfRanges > 4, let r = Range(match.range(at: 4), in: frame) {
                file = String(frame[r])
            }
            if match.numberOfRanges > 5, let r = Range(match.range(at: 5), in: frame) {
                line = String(frame[r])
            }

            return "frame={level=\"\(level)\",addr=\"\(addr)\",func=\"\(func)\",file=\"\(file)\",line=\"\(line)\"}"
        }

        return "~\"\(frame)\""
    }

    // MARK: - State Updates

    private func updateStateFromWasminspect(_ wsState: WasminspectService.State) {
        switch wsState {
        case .disconnected:
            state = .disconnected
            logMI("*stopped,reason=\"exited\"")
        case .launching:
            state = .launching
        case .connected:
            state = .connected
            logMI("^connected")
        case .running:
            state = .running
            logMI("*running,thread-id=\"all\"")
        case .stopped:
            state = .stopped
            logMI("*stopped,reason=\"end-stepping-range\"")
        case .error(let msg):
            state = .error(msg)
            logMI("^error,msg=\"\(msg)\"")
        }
    }

    private func updateStackFrames(_ frames: [WasminspectService.StackFrame]) {
        stackFrames = frames.map { frame in
            "frame={level=\"\(frame.id)\",func=\"\(frame.name)\",file=\"\(frame.file ?? "")\",line=\"\(frame.line)\"}"
        }
    }

    private func updateBreakpoints(_ bps: [WasminspectService.Breakpoint]) {
        breakpoints = bps.map { bp in
            "bkpt={number=\"\(bp.id)\",type=\"breakpoint\",disp=\"keep\",enabled=\"y\",addr=\"0x0\",file=\"\(bp.file)\",line=\"\(bp.line)\",verified=\"\(bp.verified ? "y" : "n")\"}"
        }
    }

    private func logMI(_ line: String) {
        miOutput.append(line)
        if miOutput.count > 500 {
            miOutput.removeFirst(miOutput.count - 500)
        }
    }

    // MARK: - Public API (MI-compatible)

    func launch() {
        wasminspect.launch()
    }

    func terminate() {
        wasminspect.terminate()
        logMI("^exit")
    }

    // MI-style execution commands
    func execRun() {
        sendMI("-exec-run")
    }

    func execContinue() {
        sendMI("-exec-continue")
    }

    func execNext() {
        sendMI("-exec-next")
    }

    func execStep() {
        sendMI("-exec-step")
    }

    func execFinish() {
        sendMI("-exec-finish")
    }

    // MI-style breakpoint commands
    func breakInsert(file: String, line: Int) {
        sendMI("-break-insert \"\(file):\(line)\"")
    }

    func breakDelete(id: Int) {
        sendMI("-break-delete \(id)")
    }

    func toggleBreakpoint(file: String, line: Int) {
        let key = "\(file):\(line)"
        if let id = breakpointIdMap[key] {
            breakDelete(id: id)
            breakpointIdMap.removeValue(forKey: key)
        } else {
            breakInsert(file: file, line: line)
        }
    }

    // MI-style stack commands
    func stackListFrames() {
        sendMI("-stack-list-frames")
    }

    func stackListLocals() {
        sendMI("-stack-list-locals --simple-values")
    }

    // File loading
    func fileExecAndSymbols(_ path: String) {
        targetWasmPath = path
        logMI("^done")
    }
}
