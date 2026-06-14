//
//  AppExtensionService.swift
//  CodifyOne
//
//  Created by Ken Chung on 02/07/2024.
//

import Dynamic
import Foundation
import ios_system

class AppExtensionService: NSObject {
    static let PORT = 50002
    static let shared = AppExtensionService()
    private var task: URLSessionWebSocketTask? = nil
    private var isStartingServer = false

    private var canStartExtensionServer: Bool {
        #if targetEnvironment(macCatalyst)
            return false
        #else
            if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
                return false
            }
            return true
        #endif
    }

    func startServer() {
        guard canStartExtensionServer else {
            NSLog("AppExtensionService: extension server disabled on this platform")
            return
        }
        guard !isStartingServer else { return }
        isStartingServer = true
        defer { isStartingServer = false }
        guard let className = "TlNFeHRlbnNpb24=".base64Decoded(),
            let BLE: AnyClass = NSClassFromString(className)
        else {
            NSLog("AppExtensionService: NSExtension class unavailable, extension server disabled")
            return
        }
        guard let mainBundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let ext = Dynamic(BLE).extensionWithIdentifier(
            "\(mainBundleIdentifier).extension", error: nil)
        guard let frameworkDir = Bundle.main.privateFrameworksPath,
            let frameworkDirBookmark = try? URL(fileURLWithPath: frameworkDir).bookmarkData()
        else {
            NSLog("AppExtensionService: unable to bookmark frameworks directory")
            return
        }
        let pythonLibraryDirBookmark = try? FileManager().url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("lib/python3.9/site-packages").bookmarkData()
        let item = NSExtensionItem()
        item.userInfo = [
            "frameworksDirectoryBookmark": frameworkDirBookmark,
            "port": AppExtensionService.PORT,
        ]
        item.attachments = [
            NSItemProvider(item: Data() as NSData, typeIdentifier: "com.thebaselab.source")
        ]
        if let pythonLibraryDirBookmark {
            item.userInfo?["pythonLibraryDirectoryBookmark"] = pythonLibraryDirBookmark
        }
        ext.setRequestInterruptionBlock(
            { uuid in
                print("Extension server crashed, attempting to restart")
                self.startServer()
            } as RequestInterruptionBlock)

        do {
            try ObjCExceptionCatcher.catchException(in: {
                ext.beginExtensionRequestWithInputItems(
                    [item],
                    completion: { uuid in
                        let pid = ext.pid(forRequestIdentifier: uuid)
                        if let uuid = uuid {
                            print("Started extension request: \(uuid). Extension PID is \(pid)")
                        }
                        print("Extension server listening on 127.0.0.1:\(AppExtensionService.PORT)")
                    } as RequestBeginBlock)
            })
        } catch {
            NSLog(
                "AppExtensionService: failed to start extension server: \(error.localizedDescription)"
            )
        }

    }

    func stopServer() {
        let notificationName = CFNotificationName(
            "com.thebaselab.code.node.stop" as CFString)
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            notificationCenter, notificationName, nil, nil, false)
    }

    func terminate() {
        self.task?.cancel()
    }

    func prepareServer() async {
        if LanguageService.shared.candidateLanguageIdentifier == nil { return }
        stopServer()

        try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
    }

    func call(
        args: [String],
        t_stdin: UnsafeMutablePointer<FILE>,
        t_stdout: UnsafeMutablePointer<FILE>
    ) async throws {
        guard canStartExtensionServer else {
            fputs("App extension server is not available on this platform.\n", t_stdout)
            return
        }
        await prepareServer()

        defer {
            self.task = nil
            signal(SIGINT, SIG_DFL)
        }

        let signalCallback: sig_t = { signal in
            // TODO: send real signal instead
            AppExtensionService.shared.terminate()
        }
        signal(SIGINT, signalCallback)

        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(String(AppExtensionService.PORT))/websocket")!)
        self.task = task
        task.resume()

        let handle = FileHandle(fileDescriptor: fileno(t_stdin), closeOnDealloc: false)
        handle.readabilityHandler = { fileHandle in
            if let str = String(data: fileHandle.availableData, encoding: .utf8) {
                Task {
                    try await task.send(.string(str))
                    print("Sending -> \(str)")
                }
            }
        }

        let frame = ExecutionRequestFrame(
            args: args,
            redirectStderr: true,
            workingDirectoryBookmark: try? URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).bookmarkData(),
            isLanguageService: false
        )

        try await task.send(.string(frame.stringRepresentation))

        print("Sending -> \(frame.stringRepresentation)")

        while let message = try? await task.receive() {
            switch message {
            case .string(let text):
                print("Receiving <- \(text)")
                fputs(text, t_stdout)
            default:
                continue
            }
        }
    }
}
