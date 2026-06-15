//
//  executor.swift
//  CodifyOne
//
//  Created by Ken Chung on 12/12/2020.
//

import Darwin
import SwiftUI
import ios_system

class Executor {

    enum State {
        case idle
        case running
        case interactive
    }

    private let persistentIdentifier: String
    private var pid: pid_t? = nil

    private var stdin_file: UnsafeMutablePointer<FILE>?
    private var stdout_file: UnsafeMutablePointer<FILE>?
    private var stdin_file_input: FileHandle? = nil

    private var receivedStdout: ((_ data: Data) -> Void)
    private var receivedStderr: ((_ data: Data) -> Void)
    private var requestInput: ((_ prompt: String) -> Void)
    private var lastCommand: String? = nil
    private var stdout_active = false
    private let END_OF_TRANSMISSION = "\u{04}"

    var currentWorkingDirectory: URL
    var state: State = .idle
    var prompt: String

    func setNewWorkingDirectory(url: URL) {
        currentWorkingDirectory = url
        prompt = "\(url.lastPathComponent) $ "
    }

    init(
        root: URL,
        sessionIdentifier: String = "com.thebaselab.terminal",
        onStdout: @escaping ((_ data: Data) -> Void),
        onStderr: @escaping ((_ data: Data) -> Void),
        onRequestInput: @escaping ((_ prompt: String) -> Void)
    ) {
        persistentIdentifier = sessionIdentifier
        currentWorkingDirectory = root
        prompt = "\(root.lastPathComponent) $ "
        receivedStdout = onStdout
        receivedStderr = onStderr
        requestInput = onRequestInput

        NotificationCenter.default.addObserver(
            self, selector: #selector(onNodeStdout), name: Notification.Name("node.stdout"),
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func evaluateCommands(_ cmds: [String]) {
        guard !cmds.isEmpty else {
            return
        }
        var commands = cmds
        dispatch(
            command: commands.removeFirst(),
            completionHandler: { code in
                if !commands.isEmpty && code == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.evaluateCommands(commands)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.prompt = "\(self.currentWorkingDirectory.lastPathComponent) $ "
                        self.requestInput(self.prompt)
                    }
                }
            })
    }

    func endOfTransmission() {
        try? stdin_file_input?.close()
    }

    func kill() {
        ios_switchSession(persistentIdentifier.toCString())
        ios_kill()
    }

    func setWindowSize(cols: Int, rows: Int) {
        ios_setWindowSize(Int32(cols), Int32(rows), persistentIdentifier.toCString())
    }

    func sendInput(input: String) {
        guard self.state != .idle, let data = input.data(using: .utf8) else {
            return
        }

        ios_switchSession(persistentIdentifier.toCString())

        stdin_file_input?.write(data)

        if state == .running {
            if let endData = "\n".data(using: .utf8) {
                stdin_file_input?.write(endData)
            }
        }

    }

    private func _onStdout(data: Data) {
        let str = String(decoding: data, as: UTF8.self)

        let output: String
        if let markerRange = str.range(of: END_OF_TRANSMISSION) {
            output = String(str[..<markerRange.lowerBound])
            stdout_active = false
        } else {
            output = str
        }

        guard !output.isEmpty, let outputData = output.data(using: .utf8) else {
            return
        }

        DispatchQueue.main.async {
            self.receivedStdout(outputData)
        }
    }

    private func onStdout(_ stdout: FileHandle) {
        if !stdout_active { return }
        guard fcntl(stdout.fileDescriptor, F_GETFD) >= 0 else { return }
        let data = stdout.availableData
        guard !data.isEmpty else { return }
        _onStdout(data: data)
    }

    // Called when the stderr file handle is written to
    private func onStderr(_ stderr: FileHandle) {
        guard fcntl(stderr.fileDescriptor, F_GETFD) >= 0 else { return }
        let data = stderr.availableData
        guard !data.isEmpty else { return }
        DispatchQueue.main.async {
            self.receivedStderr(data)
        }
    }

    func dispatch(
        command: String, isInteractive: Bool = false, completionHandler: @escaping (Int32) -> Void
    ) {
        guard command != "" else {
            completionHandler(0)
            return
        }

        let cmdName = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command

        // Intercept wasm command and handle it directly
        if command.starts(with: "wasm ") || command == "wasm" {
            handleWasmCommand(command: command, completionHandler: completionHandler)
            return
        }

        if ["wasm_cuda_oxide", "cuda_oxide", "cuda-oxide"].contains(cmdName) {
            handleWasmCudaOxideCommand(command: command, completionHandler: completionHandler)
            return
        }

        if ["wasm_cuda_ptx", "cuda_ptx", "cuda-ptx"].contains(cmdName) {
            handleWasmCudaPTXCommand(command: command, completionHandler: completionHandler)
            return
        }

        if ["wasm_proton_display", "proton_display", "proton-display"].contains(cmdName) {
            handleWasmProtonDisplayCommand(command: command, completionHandler: completionHandler)
            return
        }

        // Check if executing a file directly (e.g., ./a.out, a.out, build/main.wasm)
        // If it's a WASM file, forward to wasm runtime
        if let wasmCommand = detectAndForwardWasmFile(command: command) {
            handleWasmCommand(command: wasmCommand, completionHandler: completionHandler)
            return
        }

        // gdb / wasminspect: debug a wasm binary with the wasminspect debugger
        if ["gdb", "wasminspect"].contains(cmdName) {
            handleDebuggerCommand(command: command, completionHandler: completionHandler)
            return
        }

        // Intercept node/npm/npx directly to avoid iOS dlsym limitations
        // (replaceCommand can't find @_cdecl functions via dlsym on iOS)
        if ["node", "npm", "npx", "nodeg"].contains(cmdName) {
            handleNodeCommand(
                command: command, cmdName: cmdName, completionHandler: completionHandler)
            return
        }

        var stdin_pipe = Pipe()
        stdin_file = fdopen(stdin_pipe.fileHandleForReading.fileDescriptor, "r")
        while stdin_file == nil {
            stdin_pipe = Pipe()
            stdin_file = fdopen(stdin_pipe.fileHandleForReading.fileDescriptor, "r")
        }
        stdin_file_input = stdin_pipe.fileHandleForWriting

        var stdout_pipe = Pipe()
        stdout_file = fdopen(stdout_pipe.fileHandleForWriting.fileDescriptor, "w")
        while stdout_file == nil {
            stdout_pipe = Pipe()
            stdout_file = fdopen(stdout_pipe.fileHandleForWriting.fileDescriptor, "w")
        }
        setvbuf(stdout_file, nil, _IONBF, 0)
        stdout_pipe.fileHandleForReading.readabilityHandler = self.onStdout

        stdout_active = true

        let queue = DispatchQueue(label: "\(command)", qos: .utility)

        queue.async {
            if isInteractive {
                self.state = .interactive
            } else {
                self.state = .running
            }

            self.lastCommand = command
            Thread.current.name = command

            ios_switchSession(self.persistentIdentifier.toCString())
            ios_setDirectoryURL(self.currentWorkingDirectory)
            ios_setContext(UnsafeMutableRawPointer(mutating: self.persistentIdentifier.toCString()))
            ios_setStreams(self.stdin_file, self.stdout_file, self.stdout_file)

            let code = self.run(command: command)

            close(stdin_pipe.fileHandleForReading.fileDescriptor)
            self.stdin_file_input = nil

            // Send info to the stdout handler that the command has finished:
            let writeOpen = fcntl(stdout_pipe.fileHandleForWriting.fileDescriptor, F_GETFD)
            if writeOpen >= 0 {
                // Pipe is still open, send information to close it, once all output has been processed.
                stdout_pipe.fileHandleForWriting.write(self.END_OF_TRANSMISSION.data(using: .utf8)!)
                while self.stdout_active {
                    fflush(thread_stdout)
                }
            }

            close(stdout_pipe.fileHandleForReading.fileDescriptor)

            DispatchQueue.main.async {
                self.state = .idle
            }

            var url = URL(fileURLWithPath: FileManager().currentDirectoryPath)

            // Sometimes pip would change the working directory to an inaccesible location,
            // we need to verify that the current directory is readable.
            if (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) == nil
            {
                url = self.currentWorkingDirectory
            }

            ios_setMiniRootURL(url)

            DispatchQueue.main.async {
                self.prompt =
                    "\(FileManager().currentDirectoryPath.split(separator: "/").last?.removingPercentEncoding ?? "") $ "
                self.currentWorkingDirectory = url
            }

            completionHandler(code)
        }
    }

    private func run(command: String) -> Int32 {
        NSLog("Running command: \(command)")

        // ios_system requires these to be set to nil before command execution
        thread_stdin = nil
        thread_stdout = nil
        thread_stderr = nil

        pid = ios_fork()
        let returnCode = ios_system(command)
        ios_waitpid(pid!)
        ios_releaseThreadId(pid!)
        pid = nil

        // Flush pipes to make sure all data is read
        fflush(thread_stdout)
        fflush(thread_stderr)

        return returnCode
    }

    @objc private func onNodeStdout(_ notification: Notification) {
        guard let content = notification.userInfo?["content"] as? String else {
            return
        }
        if let data = content.data(using: .utf8) {
            _onStdout(data: data)
        }
    }

    private func detectAndForwardWasmFile(command: String) -> String? {
        // Parse the command to get the executable path
        let components = command.split(separator: " ", maxSplits: 1).map { String($0) }
        guard let executable = components.first else { return nil }

        // Resolve the file path
        let filePath: String
        if executable.hasPrefix("/") {
            filePath = executable
        } else if executable.hasPrefix("./") || executable.hasPrefix("../")
            || executable.contains("/")
        {
            filePath = currentWorkingDirectory.path + "/" + executable
        } else {
            // Bare name (e.g. `a.out`, `main.wasm`): prefer a WASM file in the
            // current directory. Otherwise leave normal PATH commands alone.
            filePath = currentWorkingDirectory.path + "/" + executable
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }

        // Read first 4 bytes to check for WASM magic number
        guard let fileHandle = FileHandle(forReadingAtPath: filePath),
            let magicBytes = try? fileHandle.read(upToCount: 4),
            magicBytes.count == 4
        else {
            return nil
        }

        // WASM magic number: 0x00 0x61 0x73 0x6D (\0asm)
        let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]
        let fileMagic = Array(magicBytes)

        guard fileMagic == wasmMagic else {
            return nil
        }

        // It's a WASM file. Forward to the runtime and preserve arguments.
        if components.count > 1 {
            let rest = components.dropFirst().joined(separator: " ")
            return "wasm \(filePath) \(rest)"
        } else {
            return "wasm \(filePath)"
        }
    }

    /// Rewrite `gdb [flags] <target.wasm> [args...]` / `wasminspect <target.wasm> [args...]`
    /// into a wasminspect debugger session running on the wasm runtime.
    private func handleDebuggerCommand(
        command: String, completionHandler: @escaping (Int32) -> Void
    ) {
        let fail: (String) -> Void = { message in
            DispatchQueue.main.async {
                self.receivedStderr((message + "\r\n").data(using: .utf8)!)
                completionHandler(127)
            }
        }

        guard let inspectorPath = WasminspectService.resolveDebuggerWasm() else {
            fail(
                "wasminspect.wasm not found. Place it in Documents/Tools/wasminspect.wasm "
                    + "or install the wasminspect extension.")
            return
        }
        if let issue = WasminspectService.debuggerWasmCompatibilityIssue(at: inspectorPath) {
            fail(issue)
            return
        }

        // Drop the command name and common gdb flags (-q, --quiet, -nx, --args);
        // what remains is the target wasm binary and its arguments.
        let tokens = command.split(separator: " ").map(String.init).dropFirst()
            .filter { !["-q", "-quiet", "--quiet", "-nx", "--nx", "--args"].contains($0) }

        guard let target = tokens.first else {
            fail("Usage: gdb <file.wasm> [args...]")
            return
        }

        let targetPath =
            target.hasPrefix("/") ? target : currentWorkingDirectory.path + "/" + target
        guard FileManager.default.fileExists(atPath: targetPath) else {
            fail("gdb: \(target): No such file or directory")
            return
        }

        let rest = tokens.dropFirst().joined(separator: " ")
        let wasmCommand = "wasm \(inspectorPath) \(targetPath)" + (rest.isEmpty ? "" : " \(rest)")
        handleWasmCommand(command: wasmCommand, completionHandler: completionHandler)
    }

    private func handleWasmCudaOxideCommand(
        command: String,
        completionHandler: @escaping (Int32) -> Void
    ) {
        handleBundledWasmCudaProbeCommand(
            command: command,
            resourceName: "cuda_oxide_probe",
            commandName: "wasm_cuda_oxide",
            backendFlag: "--gpu",
            completionHandler: completionHandler)
    }

    private func handleWasmCudaPTXCommand(
        command: String,
        completionHandler: @escaping (Int32) -> Void
    ) {
        handleBundledWasmCudaProbeCommand(
            command: command,
            resourceName: "cuda_ptx_probe",
            commandName: "wasm_cuda_ptx",
            backendFlag: "--gpu-backend metal",
            completionHandler: completionHandler)
    }

    private func handleWasmProtonDisplayCommand(
        command: String,
        completionHandler: @escaping (Int32) -> Void
    ) {
        handleBundledWasmCudaProbeCommand(
            command: command,
            resourceName: "proton_display_probe",
            commandName: "wasm_proton_display",
            backendFlag: "",
            completionHandler: completionHandler)
    }

    private func handleBundledWasmCudaProbeCommand(
        command: String,
        resourceName: String,
        commandName: String,
        backendFlag: String,
        completionHandler: @escaping (Int32) -> Void
    ) {
        guard
            let wasmURL = Bundle.main.url(
                forResource: resourceName,
                withExtension: "wasm")
        else {
            DispatchQueue.main.async {
                self.receivedStderr(
                    "\(commandName): bundled \(resourceName).wasm not found\r\n"
                        .data(using: .utf8)!)
                completionHandler(127)
            }
            return
        }

        let tokens = command.split(separator: " ").map(String.init)
        let rest = tokens.dropFirst().joined(separator: " ")
        let wasmCommand =
            backendFlag.isEmpty
            ? "wasm \(wasmURL.path)" + (rest.isEmpty ? "" : " \(rest)")
            : "wasm \(backendFlag) \(wasmURL.path)" + (rest.isEmpty ? "" : " \(rest)")
        handleWasmCommand(command: wasmCommand, completionHandler: completionHandler)
    }

    private func normalizedWasmCommand(_ command: String) -> String {
        var components = command.split(separator: " ").map(String.init)
        guard components.first == "wasm" else { return command }

        var wasmIndex = 1
        while wasmIndex < components.count {
            let token = components[wasmIndex]
            if token == "--gpu" || token == "--no-gpu" {
                wasmIndex += 1
                continue
            }
            if token == "--gpu-backend" {
                wasmIndex += 2
                continue
            }
            break
        }

        guard wasmIndex < components.count else { return command }
        let wasmPath = components[wasmIndex]
        if !wasmPath.hasPrefix("/") {
            components[wasmIndex] = currentWorkingDirectory.appendingPathComponent(wasmPath).path
        }
        return components.joined(separator: " ")
    }

    private func handleWasmCommand(command: String, completionHandler: @escaping (Int32) -> Void) {
        let command = normalizedWasmCommand(command)

        // Set up stdin pipe
        var stdin_pipe = Pipe()
        stdin_file = fdopen(stdin_pipe.fileHandleForReading.fileDescriptor, "r")
        while stdin_file == nil {
            stdin_pipe = Pipe()
            stdin_file = fdopen(stdin_pipe.fileHandleForReading.fileDescriptor, "r")
        }
        stdin_file_input = stdin_pipe.fileHandleForWriting

        // Set up stdout/stderr pipes
        var stdout_pipe = Pipe()
        stdout_file = fdopen(stdout_pipe.fileHandleForWriting.fileDescriptor, "w")
        while stdout_file == nil {
            stdout_pipe = Pipe()
            stdout_file = fdopen(stdout_pipe.fileHandleForWriting.fileDescriptor, "w")
        }
        let stderr_pipe = Pipe()
        let stderr_file = fdopen(stderr_pipe.fileHandleForWriting.fileDescriptor, "w")
        setvbuf(stdout_file, nil, _IONBF, 0)
        if stderr_file != nil {
            setvbuf(stderr_file, nil, _IONBF, 0)
        }
        stdout_pipe.fileHandleForReading.readabilityHandler = self.onStdout
        stderr_pipe.fileHandleForReading.readabilityHandler = self.onStderr
        stdout_active = true

        let queue = DispatchQueue(label: "wasm-command", qos: .utility)
        queue.async {
            self.state = .running
            Thread.current.name = command

            // Switch to ios_system session and set up streams. Wasmer cannot use
            // the app container Documents directory as its host cwd, so run the
            // bridge from a stable runtime directory while passing the module by
            // absolute path.
            ios_switchSession(self.persistentIdentifier.toCString())
            let wasmHostCWD = URL(
                fileURLWithPath: safeWASMCurrentDirectory(self.currentWorkingDirectory.path))
            ios_setDirectoryURL(wasmHostCWD)
            ios_setContext(UnsafeMutableRawPointer(mutating: self.persistentIdentifier.toCString()))
            ios_setStreams(self.stdin_file, self.stdout_file, stderr_file ?? self.stdout_file)
            let previousStdin = thread_stdin
            let previousStdout = thread_stdout
            let previousStderr = thread_stderr
            thread_stdin = self.stdin_file
            thread_stdout = self.stdout_file
            thread_stderr = stderr_file ?? self.stdout_file

            fputs("wasm runner: \(command)\n", self.stdout_file)
            fflush(self.stdout_file)

            // Parse command into argc/argv
            let components = command.split(separator: " ").map { String($0) }
            var cStrings = components.map { strdup($0) }
            cStrings.append(nil)

            defer {
                ios_setDirectoryURL(self.currentWorkingDirectory)
                thread_stdin = previousStdin
                thread_stdout = previousStdout
                thread_stderr = previousStderr
                for ptr in cStrings where ptr != nil {
                    free(ptr)
                }
            }

            let argc = Int32(components.count)

            // Wasmer installs its own SIGBUS/SIGSEGV trap handlers. Do not wrap this
            // call with process-wide handlers, or WASM memory traps become app crashes.
            let exitCode = cStrings.withUnsafeMutableBufferPointer { buffer in
                wasm(argc: argc, argv: buffer.baseAddress)
            }

            // Close stdin pipe
            close(stdin_pipe.fileHandleForReading.fileDescriptor)
            self.stdin_file_input = nil

            // Flush terminal output before sending the end-of-transmission marker.
            // Short wasm diagnostics such as usage text otherwise remain buffered
            // until after the terminal reader has already stopped.
            fflush(thread_stdout)
            fflush(thread_stderr)

            if fcntl(stderr_pipe.fileHandleForWriting.fileDescriptor, F_GETFD) >= 0 {
                try? stderr_pipe.fileHandleForWriting.close()
            }

            let writeOpen = fcntl(stdout_pipe.fileHandleForWriting.fileDescriptor, F_GETFD)
            if writeOpen >= 0 {
                stdout_pipe.fileHandleForWriting.write(self.END_OF_TRANSMISSION.data(using: .utf8)!)
                while self.stdout_active {
                    fflush(thread_stdout)
                    fflush(thread_stderr)
                }
            }

            stdout_pipe.fileHandleForReading.readabilityHandler = nil
            stderr_pipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                self.state = .idle
                completionHandler(exitCode)
            }
        }
    }

    private func handleNodeCommand(
        command: String, cmdName: String, completionHandler: @escaping (Int32) -> Void
    ) {
        // Set up stdin pipe
        var stdin_pipe = Pipe()
        stdin_file = fdopen(stdin_pipe.fileHandleForReading.fileDescriptor, "r")
        while stdin_file == nil {
            stdin_pipe = Pipe()
            stdin_file = fdopen(stdin_pipe.fileHandleForReading.fileDescriptor, "r")
        }
        stdin_file_input = stdin_pipe.fileHandleForWriting

        // Set up stdout/stderr pipes
        var stdout_pipe = Pipe()
        stdout_file = fdopen(stdout_pipe.fileHandleForWriting.fileDescriptor, "w")
        while stdout_file == nil {
            stdout_pipe = Pipe()
            stdout_file = fdopen(stdout_pipe.fileHandleForWriting.fileDescriptor, "w")
        }
        setvbuf(stdout_file, nil, _IONBF, 0)
        stdout_pipe.fileHandleForReading.readabilityHandler = self.onStdout
        stdout_active = true

        let queue = DispatchQueue(label: "node-command", qos: .utility)
        queue.async {
            self.state = .running
            Thread.current.name = command

            ios_switchSession(self.persistentIdentifier.toCString())
            ios_setDirectoryURL(self.currentWorkingDirectory)
            ios_setContext(UnsafeMutableRawPointer(mutating: self.persistentIdentifier.toCString()))
            ios_setStreams(self.stdin_file, self.stdout_file, self.stdout_file)

            // Parse command into argc/argv and call the corresponding @_cdecl function
            let components = command.split(separator: " ").map { String($0) }
            var cStrings = components.map { strdup($0) }
            cStrings.append(nil)

            defer {
                for ptr in cStrings where ptr != nil {
                    free(ptr)
                }
            }

            let argc = Int32(components.count)
            self.stdin_file_input = nil
            try? stdin_pipe.fileHandleForWriting.close()

            // Wasmer installs its own SIGBUS/SIGSEGV trap handlers. Do not wrap this
            // call with process-wide handlers, or WASM memory traps become app crashes.
            let exitCode: Int32 = cStrings.withUnsafeMutableBufferPointer { buffer in
                switch cmdName {
                case "node":
                    return node(argc: argc, argv: buffer.baseAddress)
                case "npm":
                    return npm(argc: argc, argv: buffer.baseAddress)
                case "npx":
                    return npx(argc: argc, argv: buffer.baseAddress)
                case "nodeg":
                    return nodeg(argc: argc, argv: buffer.baseAddress)
                default:
                    return 1
                }
            }

            close(stdin_pipe.fileHandleForReading.fileDescriptor)
            self.stdin_file_input = nil

            let writeOpen = fcntl(stdout_pipe.fileHandleForWriting.fileDescriptor, F_GETFD)
            if writeOpen >= 0 {
                stdout_pipe.fileHandleForWriting.write(self.END_OF_TRANSMISSION.data(using: .utf8)!)
                while self.stdout_active {
                    fflush(thread_stdout)
                }
            }

            close(stdout_pipe.fileHandleForReading.fileDescriptor)

            fflush(thread_stdout)
            fflush(thread_stderr)

            DispatchQueue.main.async {
                self.state = .idle
                completionHandler(exitCode)
            }
        }
    }
}

extension Executor.State {
    var displayName: String {
        switch self {
        case .idle:
            return NSLocalizedString("Idle", comment: "Executor state label")
        case .running:
            return NSLocalizedString("Running", comment: "Executor state label")
        case .interactive:
            return NSLocalizedString("Interactive", comment: "Executor state label")
        }
    }
}
