//
//  CodeApp.swift
//  CodifyOne
//
//  Created by Ken Chung on 17/11/2020.
//

import SwiftGit2
import SwiftUI
import ios_system

@main
struct CodeApp: App {
    @StateObject var themeManager = ThemeManager()
    let wasmService = WASMService()
    let editorService = EditorService()

    init() {
        setup()
    }

    var body: some Scene {
        WindowGroup {
            MainScene()
                .preferredColorScheme(themeManager.colorSchemePreference)
                .environmentObject(themeManager)
        }
    }
}

private func setup() {
    refreshNodeCommands()
    setupExtensionListener()
    if versionNumberIncreased() || needToUpdateCFiles() {
        createCSDK()
    }
    if versionNumberIncreased() || needToUpdateWasixSysroot() {
        createWasixSysroot()
    }
    // wasmWebView.loadWorker() - Removed: Now using native Wasmer instead of JavaScript
    initializeEnvironment()
    // Must call setupEnvironment AFTER initializeEnvironment to register custom commands
    setupEnvironment()
    Repository.initialize_libgit2()
    AppExtensionService.shared.startServer()
}

private func versionNumberIncreased() -> Bool {
    if let lastReadVersion = UserDefaults.standard.string(forKey: "changelog.lastread") {
        let currentVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        if lastReadVersion != currentVersion {
            return true
        }
    } else {
        return true
    }
    print("Version Number not increased")
    return false
}

private func needToUpdateCFiles() -> Bool {
    // Check that the C SDK files are present. Every library the default
    // clang link line needs must exist — checking a single sentinel lets a
    // partially-failed creation pass forever, leaving clang with
    // "unable to find library -lc" until the app version changes.
    let libraryURL = try! FileManager().url(
        for: .libraryDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true)
    let requiredFiles = [
        "usr/include/stdio.h",
        "usr/lib/wasm32-wasi/crt1.o",
        "usr/lib/wasm32-wasi/libc.a",
        "usr/lib/wasm32-wasi/libc-printscan-long-double.a",
        "usr/lib/wasm32-wasi/libwasi-emulated-mman.a",
        "usr/lib/clang/14.0.0/lib/wasi/libclang_rt.builtins-wasm32.a",
    ]
    return !requiredFiles.allSatisfy {
        FileManager().fileExists(atPath: libraryURL.appendingPathComponent($0).path)
    }
}

// Single serial queue for all on-device SDK materialization.
private let sdkInstallQueue = DispatchQueue(label: "installFiles", qos: .utility)

private func arField(_ value: String, width: Int) -> Data {
    var bytes = Array(value.utf8)
    if bytes.count > width {
        bytes = Array(bytes.prefix(width))
    }
    if bytes.count < width {
        bytes.append(contentsOf: Array(repeating: 0x20, count: width - bytes.count))
    }
    return Data(bytes)
}

private func appendArMember(to archive: inout Data, name: String, contents: Data) {
    let nameBytes = Data(name.utf8)
    let useExtendedName = nameBytes.count > 15 || nameBytes.contains(0x20)
    let headerName = useExtendedName ? "#1/\(nameBytes.count)" : "\(name)/"
    let payloadSize = contents.count + (useExtendedName ? nameBytes.count : 0)

    archive.append(arField(headerName, width: 16))
    archive.append(arField("0", width: 12))
    archive.append(arField("0", width: 6))
    archive.append(arField("0", width: 6))
    archive.append(arField("100644", width: 8))
    archive.append(arField("\(payloadSize)", width: 10))
    archive.append(Data("`\n".utf8))
    if useExtendedName {
        archive.append(nameBytes)
    }
    archive.append(contents)
    if payloadSize % 2 != 0 {
        archive.append(contentsOf: [0x0A])
    }
}

private func writeArMember(to handle: FileHandle, name: String, contents: Data) {
    let nameBytes = Data(name.utf8)
    let useExtendedName = nameBytes.count > 15 || nameBytes.contains(0x20)
    let headerName = useExtendedName ? "#1/\(nameBytes.count)" : "\(name)/"
    let payloadSize = contents.count + (useExtendedName ? nameBytes.count : 0)

    handle.write(arField(headerName, width: 16))
    handle.write(arField("0", width: 12))
    handle.write(arField("0", width: 6))
    handle.write(arField("0", width: 6))
    handle.write(arField("100644", width: 8))
    handle.write(arField("\(payloadSize)", width: 10))
    handle.write(Data("`\n".utf8))
    if useExtendedName {
        handle.write(nameBytes)
    }
    handle.write(contents)
    if payloadSize % 2 != 0 {
        handle.write(Data([0x0A]))
    }
}

private func fileExistsAndNonEmpty(at url: URL, fileManager: FileManager = FileManager()) -> Bool {
    guard
        let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber
    else {
        return false
    }
    return size.int64Value > 8
}

private func writeEmptyArArchive(at archiveURL: URL, fileManager: FileManager = FileManager())
    throws
{
    try fileManager.createDirectory(
        at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("!<arch>\n".utf8).write(to: archiveURL, options: .atomic)
}

private func writeArArchive(
    at archiveURL: URL,
    objectDirectory: URL,
    fileManager: FileManager = FileManager()
) throws {
    let members =
        (try fileManager.contentsOfDirectory(
            at: objectDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]))
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    try fileManager.createDirectory(
        at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let tempURL = archiveURL.deletingLastPathComponent()
        .appendingPathComponent(".\(archiveURL.lastPathComponent).tmp")
    try? fileManager.removeItem(at: tempURL)
    fileManager.createFile(atPath: tempURL.path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var didCloseHandle = false
    defer {
        if !didCloseHandle {
            handle.closeFile()
        }
        try? fileManager.removeItem(at: tempURL)
    }

    handle.write(Data("!<arch>\n".utf8))
    for member in members {
        writeArMember(
            to: handle,
            name: member.lastPathComponent,
            contents: try Data(contentsOf: member))
    }

    handle.closeFile()
    didCloseHandle = true
    try? fileManager.removeItem(at: archiveURL)
    try fileManager.moveItem(at: tempURL, to: archiveURL)
}

private func createCSDK() {
    let installQueue = sdkInstallQueue

    // This operation copies the C SDK from $APPDIR to $HOME/Library and creates the *.a libraries
    // (we can't ship with .a libraries because of the AppStore rules, but we can ship with *.o
    // object files, provided they are in WASM format.
    installQueue.async {
        // Use a queue so it does not take time at startup:
        NSLog("Starting creating C SDK")
        let libraryURL = try! FileManager().url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        // usr/lib/wasm32-wasi
        var localURL = libraryURL.appendingPathComponent("usr/lib/wasm32-wasi")
        do {
            if FileManager().fileExists(atPath: localURL.path) && !localURL.isDirectory {
                try FileManager().removeItem(at: localURL)
            }
            if !FileManager().fileExists(atPath: localURL.path) {
                try FileManager().createDirectory(
                    atPath: localURL.path, withIntermediateDirectories: true)
            }
        } catch {
            NSLog("Error in creating C SDK directory \(localURL): \(error)")
            return
        }
        // usr/lib/clang/14.0.0/lib/wasi/
        localURL = libraryURL.appendingPathComponent("usr/lib/clang/14.0.0/lib/wasi/")
        do {
            if FileManager().fileExists(atPath: localURL.path) && !localURL.isDirectory {
                try FileManager().removeItem(at: localURL)
            }
            if !FileManager().fileExists(atPath: localURL.path) {
                try FileManager().createDirectory(
                    atPath: localURL.path, withIntermediateDirectories: true)
            }
        } catch {
            NSLog("Error in creating C SDK directory \(localURL): \(error)")
            return
        }
        let linkedCDirectories = [
            "usr/include",
            "usr/share",
            "usr/lib/wasm32-wasi/crt1.o",
            "usr/lib/wasm32-wasi/libc.imports",
            "usr/lib/clang/14.0.0/include",
        ]

        for linkedObject in linkedCDirectories {
            let bundleFile = Resources.clangLib.appendingPathComponent(linkedObject)
            if !FileManager().fileExists(atPath: bundleFile.path) {
                NSLog("createCSDK: requested file \(bundleFile.path) does not exist")
                continue
            }
            // Symbolic links are both faster to create and use less disk space.
            // We just have to make sure the destination exists
            let homeFile = libraryURL.appendingPathComponent(linkedObject)
            do {
                let firstFileAttribute = try FileManager().attributesOfItem(
                    atPath: homeFile.path)
                if firstFileAttribute[FileAttributeKey.type] as? String
                    == FileAttributeType.typeSymbolicLink.rawValue
                {
                    // It's a symbolic link, does the destination exist?
                    let destination = try! FileManager().destinationOfSymbolicLink(
                        atPath: homeFile.path)
                    if !FileManager().fileExists(atPath: destination) {
                        try! FileManager().removeItem(at: homeFile)
                        try! FileManager().createSymbolicLink(
                            at: homeFile, withDestinationURL: bundleFile)
                    }
                } else {
                    // Not a symbolic link, replace:
                    try! FileManager().removeItem(at: homeFile)
                    try! FileManager().createSymbolicLink(
                        at: homeFile, withDestinationURL: bundleFile)
                }
            } catch {
                // The file does not exist, and maybe the directory doesn't either:
                let localDirectory = homeFile.deletingLastPathComponent()
                if !FileManager().fileExists(atPath: localDirectory.path) {
                    try! FileManager().createDirectory(
                        atPath: localDirectory.path, withIntermediateDirectories: true)
                }
                do {
                    try FileManager().createSymbolicLink(
                        at: homeFile, withDestinationURL: bundleFile)
                } catch {
                    NSLog("Can't create file: \(homeFile.path): \(error)")
                }
            }
        }
        // Now create the empty libraries:
        let emptyLibraries = [
            // m rt pthread crypt util xnet resolv dl
            "lib/wasm32-wasi/libcrypt.a",
            "lib/wasm32-wasi/libdl.a",
            "lib/wasm32-wasi/libm.a",
            "lib/wasm32-wasi/libpthread.a",
            "lib/wasm32-wasi/libresolv.a",
            "lib/wasm32-wasi/librt.a",
            "lib/wasm32-wasi/libutil.a",
            "lib/wasm32-wasi/libxnet.a",
        ]
        for library in emptyLibraries {
            let libraryFileURL = libraryURL.appendingPathComponent("/usr/" + library)
            if !FileManager().fileExists(atPath: libraryFileURL.path) {
                do {
                    try writeEmptyArArchive(at: libraryFileURL)
                } catch {
                    NSLog("Can't create empty archive \(libraryFileURL.path): \(error)")
                }
            }
        }
        // One of the libraries is in a different folder:
        let libraryFileURL = libraryURL.appendingPathComponent(
            "/usr/lib/clang/14.0.0/lib/wasi/libclang_rt.builtins-wasm32.a")
        let rootDir = Bundle.main.resourcePath! + "/ClangLib"
        if !fileExistsAndNonEmpty(at: libraryFileURL) {
            do {
                try writeArArchive(
                    at: libraryFileURL,
                    objectDirectory: URL(
                        fileURLWithPath: rootDir + "/usr/src/libclang_rt.builtins-wasm32"))
            } catch {
                NSLog("Can't create archive \(libraryFileURL.path): \(error)")
            }
        }
        let libraries = [
            "libc", "libc++", "libc++abi", "libc-printscan-long-double",
            "libc-printscan-no-floating-point", "libwasi-emulated-mman",
            "libwasi-emulated-signal", "libwasi-emulated-process-clocks",
        ]
        for library in libraries {
            let libraryFileURL = libraryURL.appendingPathComponent(
                "usr/lib/wasm32-wasi/" + library + ".a")
            if fileExistsAndNonEmpty(at: libraryFileURL) {
                continue
            }
            do {
                try writeArArchive(
                    at: libraryFileURL,
                    objectDirectory: URL(fileURLWithPath: rootDir + "/usr/src/" + library))
            } catch {
                NSLog("Can't create archive \(libraryFileURL.path): \(error)")
            }
        }
        NSLog("Finished creating C SDK")  // Approx 2 seconds
    }
}

private func needToUpdateWasixSysroot() -> Bool {
    guard
        let libraryURL = try? FileManager().url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return false }
    return !FileManager().fileExists(
        atPath: libraryURL.appendingPathComponent("wasix-usr/lib/wasm32-wasi/libc.a").path)
}

// Materialize the bundled WASIX sysroot (wasi-sdk 29) into $HOME/Library/wasix-usr.
// Read-only content (headers, crt objects) is symlinked into place; static
// libraries are rebuilt directly from the shipped *.o files without invoking
// ios_system commands during app startup.
// The wasm runtime maps this directory to the guest /usr.
private func createWasixSysroot() {
    let installQueue = sdkInstallQueue

    installQueue.async {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: Resources.wasiSysroot.path) else {
            NSLog("createWasixSysroot: bundled WasiSysroot not found, skipping")
            return
        }
        guard
            let libraryURL = try? fileManager.url(
                for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }

        NSLog("Starting creating WASIX sysroot")
        let destURL = libraryURL.appendingPathComponent("wasix-usr")
        let libDir = destURL.appendingPathComponent("lib/wasm32-wasi")
        do {
            try fileManager.createDirectory(
                atPath: libDir.path, withIntermediateDirectories: true)
        } catch {
            NSLog("createWasixSysroot: cannot create \(libDir.path): \(error)")
            return
        }

        // Symbolic links for read-only content. Always recreated: the bundle
        // path changes on every app update, leaving old links dangling.
        let linkedItems = [
            "include", "share",
            "lib/wasm32-wasi/crt1.o",
            "lib/wasm32-wasi/crt1-command.o",
            "lib/wasm32-wasi/crt1-reactor.o",
            "lib/wasm32-wasi/scrt1.o",
            "lib/wasm32-wasi/libc.imports",
            "lib/wasm32-wasi/libc++.modules.json",
        ]
        for item in linkedItems {
            let source = Resources.wasiSysroot.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = destURL.appendingPathComponent(item)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.createSymbolicLink(
                    at: destination, withDestinationURL: source)
            } catch {
                NSLog("createWasixSysroot: can't link \(destination.path): \(error)")
            }
        }

        // Build missing static libraries from the shipped object files. Existing
        // archives are kept so app updates can refresh symlinks without spending
        // startup time re-packing large libraries like libc.a.
        let srcRoot = Resources.wasiSysroot.appendingPathComponent("src")
        if let libs = try? fileManager.contentsOfDirectory(atPath: srcRoot.path) {
            for lib in libs.sorted() {
                let libFile = libDir.appendingPathComponent("\(lib).a")
                if fileExistsAndNonEmpty(at: libFile, fileManager: fileManager) {
                    continue
                }
                do {
                    try writeArArchive(
                        at: libFile,
                        objectDirectory: srcRoot.appendingPathComponent(lib),
                        fileManager: fileManager)
                } catch {
                    NSLog("createWasixSysroot: can't create \(libFile.path): \(error)")
                }
            }
        }

        // Empty stub archives shipped by wasi-sdk for link compatibility.
        let emptyLibraries = [
            "libcommon-tag-stubs", "libcrypt", "libdl", "libm", "libpthread",
            "libresolv", "librt", "libutil", "libwasi-emulated-getpid", "libxnet",
        ]
        for stub in emptyLibraries {
            let libFile = libDir.appendingPathComponent("\(stub).a")
            if !fileManager.fileExists(atPath: libFile.path) {
                do {
                    try writeEmptyArArchive(at: libFile, fileManager: fileManager)
                } catch {
                    NSLog("createWasixSysroot: can't create \(libFile.path): \(error)")
                }
            }
        }
        NSLog("Finished creating WASIX sysroot")
    }
}

private func setupEnvironment() {
    NSLog("🔧 Setting up environment - registering custom commands")

    // Note: wasm command is intercepted in Executor.dispatch()
    // to avoid iOS dlsym limitations

    // Use replaceCommand for extension-based commands
    replaceCommand("node", "node", true)
    replaceCommand("npm", "npm", true)
    replaceCommand("npx", "npx", true)
    replaceCommand("java", "java", true)
    replaceCommand("javac", "javac", true)
    // Map Python commands to Wasmer-backed implementations
    replaceCommand("python", "python", true)
    replaceCommand("python3", "python", true)
    replaceCommand("pip", "pip", true)
    NSLog("✅ Custom commands registered")

    joinMainThread = false
    numPythonInterpreters = 2

    let libraryURL = try! FileManager().url(
        for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let bundleUrl = Resources.pythonLibrary
    setenv("PYTHONHOME", bundleUrl.path.toCString(), 1)
    setenv(
        "PYTHONPYCACHEPREFIX",
        (libraryURL.appendingPathComponent("__pycache__")).path.toCString(), 1)
    setenv("PYTHONUSERBASE", libraryURL.path.toCString(), 1)
    setenv("SSL_CERT_FILE", Resources.carcert.path.toCString(), 1)
    setenv("YARL_NO_EXTENSIONS", "1", 1)
    setenv("MULTIDICT_NO_EXTENSIONS", "1", 1)
    setenv("SYSROOT", libraryURL.path + "/usr", 1)
    setenv(
        "CCC_OVERRIDE_OPTIONS",
        "#^--target=wasm32-wasi +-fno-exceptions +-lc-printscan-long-double", 1)
    setenv("MAKESYSPATH", Bundle.main.resourcePath! + "ClangLib/usr/share/mk", 1)
    setenv("PHPRC", bundleUrl.path.toCString(), 1)
    setenv("GIT_EXEC_PATH", bundleUrl.appendingPathComponent("bin").path.toCString(), 1)
}

private func setupExtensionListener() {
    let notificationName = "com.thebaselab.code.node.stdout" as CFString
    let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

    CFNotificationCenterAddObserver(
        notificationCenter, nil,
        {
            (
                center: CFNotificationCenter?,
                observer: UnsafeMutableRawPointer?,
                name: CFNotificationName?,
                object: UnsafeRawPointer?,
                userInfo: CFDictionary?
            ) in

            guard
                let sharedURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: "group.com.thebaselab.code")
            else {
                return
            }
            let stdoutURL = sharedURL.appendingPathComponent("stdout")

            guard let data = try? Data(contentsOf: stdoutURL),
                let str = String(data: data, encoding: .utf8)
            else {
                return
            }

            let nc = NotificationCenter.default
            nc.post(
                name: Notification.Name("node.stdout"), object: nil, userInfo: ["content": str])

        },
        notificationName,
        nil,
        CFNotificationSuspensionBehavior.deliverImmediately)
}
