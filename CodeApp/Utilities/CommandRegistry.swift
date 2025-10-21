//
//  CommandRegistry.swift
//  Code
//
//  Custom command registry to handle WASM and other commands
//  that cannot be loaded via dlsym due to iOS security restrictions
//

import Foundation
import ios_system

class CommandRegistry {
    static let shared = CommandRegistry()

    private var commandHandlers: [String: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32] = [:]

    private init() {}

    func registerCommand(_ name: String, handler: @escaping (Int32, UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32) {
        commandHandlers[name] = handler
        NSLog("📝 Registered command handler for: \(name)")
    }

    func handleCommand(_ name: String, argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32? {
        return commandHandlers[name]?(argc, argv)
    }

    func isRegistered(_ name: String) -> Bool {
        return commandHandlers[name] != nil
    }
}

// Wrapper function that ios_system can call via dlsym
@_cdecl("custom_command_handler")
public func custom_command_handler(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    // Get the command name from argv[0]
    guard argc > 0, let argv = argv, let commandName = argv[0] else {
        return -1
    }

    let name = String(cString: commandName)

    if let result = CommandRegistry.shared.handleCommand(name, argc: argc, argv: argv) {
        return result
    }

    fputs("\(name): command not found\n", thread_stderr)
    return 127
}
