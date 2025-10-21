//
//  executor.swift
//  Code App
//
//  Created by Ken Chung on 12/12/2020.
//

import SwiftUI
import ios_system

class Executor {

    enum State {
        case idle
        case running
        case interactive
    }

    private let persistentIdentifier = "com.thebaselab.terminal"
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
        root: URL, onStdout: @escaping ((_ data: Data) -> Void),
        onStderr: @escaping ((_ data: Data) -> Void),
        onRequestInput: @escaping ((_ prompt: String) -> Void)
    ) {
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
                        self.prompt =
                            "\(FileManager().currentDirectoryPath.split(separator: "/").last?.removingPercentEncoding ?? "") $ "
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

        if str.contains(END_OF_TRANSMISSION) {
            stdout_active = false
            return
        }

        DispatchQueue.main.async {
            if self.state == .running {
                // Interactive Commands /with control characters
                if str.contains("\u{8}") || str.contains("\u{13}") || str.contains("\r") {
                    self.receivedStdout(data)
                    return
                }
                self.requestInput(str)
                if let prom = str.components(separatedBy: "\n").last {
                    self.prompt = prom
                }
            } else {
                self.receivedStdout(data)
            }
        }
    }

    private func onStdout(_ stdout: FileHandle) {
        if !stdout_active { return }
        let data = stdout.availableData
        _onStdout(data: data)
    }

    // Called when the stderr file handle is written to
    private func onStderr(_ stderr: FileHandle) {
        let data = stderr.availableData
        DispatchQueue.main.async {
            if self.state == .running {
                let str = String(decoding: data, as: UTF8.self)
                self.requestInput(str)
                if let prom = str.components(separatedBy: "\n").last {
                    self.prompt = prom
                }
            } else {
                self.receivedStdout(data)
            }
        }
    }

    func dispatch(
        command: String, isInteractive: Bool = false, completionHandler: @escaping (Int32) -> Void
    ) {
        guard command != "" else {
            completionHandler(0)
            return
        }

        // Intercept wasm command and handle it directly
        if command.starts(with: "wasm ") || command == "wasm" {
            handleWasmCommand(command: command, completionHandler: completionHandler)
            return
        }

        // Check if executing a file directly (e.g., ./a.out)
        // If it's a WASM file, forward to wasm runtime
        if let wasmCommand = detectAndForwardWasmFile(command: command) {
            handleWasmCommand(command: wasmCommand, completionHandler: completionHandler)
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
        } else if executable.hasPrefix("./") || executable.hasPrefix("../") {
            filePath = currentWorkingDirectory.path + "/" + executable
        } else {
            // Not a direct file execution, let ios_system handle it
            return nil
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }

        // Read first 4 bytes to check for WASM magic number
        guard let fileHandle = FileHandle(forReadingAtPath: filePath),
              let magicBytes = try? fileHandle.read(upToCount: 4),
              magicBytes.count == 4 else {
            return nil
        }

        // WASM magic number: 0x00 0x61 0x73 0x6D (\0asm)
        let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]
        let fileMagic = Array(magicBytes)

        guard fileMagic == wasmMagic else {
            return nil
        }

        // It's a WASM file! Forward to wasm runtime
        // Preserve any arguments from the original command
        if components.count > 1 {
            return "wasm \(filePath) \(components[1])"
        } else {
            return "wasm \(filePath)"
        }
    }

    private func handleWasmCommand(command: String, completionHandler: @escaping (Int32) -> Void) {
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
        stdout_pipe.fileHandleForReading.readabilityHandler = self.onStdout
        stdout_active = true

        let queue = DispatchQueue(label: "wasm-command", qos: .utility)
        queue.async {
            self.state = .running
            Thread.current.name = command

            // Switch to ios_system session and set up streams
            ios_switchSession(self.persistentIdentifier.toCString())
            ios_setDirectoryURL(self.currentWorkingDirectory)
            ios_setContext(UnsafeMutableRawPointer(mutating: self.persistentIdentifier.toCString()))
            ios_setStreams(self.stdin_file, self.stdout_file, self.stdout_file)

            // Parse command into argc/argv
            let components = command.split(separator: " ").map { String($0) }
            var cStrings = components.map { strdup($0) }
            cStrings.append(nil)

            defer {
                for ptr in cStrings where ptr != nil {
                    free(ptr)
                }
            }

            let argc = Int32(components.count)
            let argv = UnsafeMutablePointer(mutating: cStrings)

            // Call wasm function
            let exitCode = wasm(argc: argc, argv: argv)

            // Close stdin pipe
            close(stdin_pipe.fileHandleForReading.fileDescriptor)
            self.stdin_file_input = nil

            // Send end-of-transmission signal
            let writeOpen = fcntl(stdout_pipe.fileHandleForWriting.fileDescriptor, F_GETFD)
            if writeOpen >= 0 {
                stdout_pipe.fileHandleForWriting.write(self.END_OF_TRANSMISSION.data(using: .utf8)!)
                while self.stdout_active {
                    fflush(thread_stdout)
                }
            }

            close(stdout_pipe.fileHandleForReading.fileDescriptor)

            // Flush output
            fflush(thread_stdout)
            fflush(thread_stderr)

            DispatchQueue.main.async {
                self.state = .idle
                completionHandler(exitCode)
            }
        }
    }
}
