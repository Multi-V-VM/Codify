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
        "usr/lib/wasm32-wasi/libc.imports",
        "usr/lib/wasm32-wasi/libc.a",
        "usr/lib/wasm32-wasi/libc-printscan-long-double.a",
        "usr/lib/wasm32-wasi/libwasi-emulated-mman.a",
        "usr/lib/clang/14.0.0/lib/wasi/libclang_rt.builtins-wasm32.a",
        "usr/share/wasm32-wasi/defined-symbols.txt",
    ]
    return !requiredFiles.allSatisfy {
        fileExistsAndNonEmpty(at: libraryURL.appendingPathComponent($0))
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

private func appendArRawMember(to archive: inout Data, headerName: String, contents: Data) {
    archive.append(arField(headerName, width: 16))
    archive.append(arField("0", width: 12))
    archive.append(arField("0", width: 6))
    archive.append(arField("0", width: 6))
    archive.append(arField("100644", width: 8))
    archive.append(arField("\(contents.count)", width: 10))
    archive.append(Data("`\n".utf8))
    archive.append(contents)
    if contents.count % 2 != 0 {
        archive.append(contentsOf: [0x0A])
    }
}

private func appendArMember(to archive: inout Data, name: String, contents: Data) {
    let nameBytes = Data(name.utf8)
    let useExtendedName = nameBytes.count > 15 || nameBytes.contains(0x20)
    let headerName = useExtendedName ? "#1/\(nameBytes.count)" : "\(name)/"
    var payload = Data()
    if useExtendedName {
        payload.append(nameBytes)
    }
    payload.append(contents)
    appendArRawMember(to: &archive, headerName: headerName, contents: payload)
}

private func arMemberSize(name: String, contentsCount: Int) -> Int {
    let nameBytes = Data(name.utf8)
    let payloadSize =
        contentsCount + (nameBytes.count > 15 || nameBytes.contains(0x20) ? nameBytes.count : 0)
    return 60 + payloadSize + (payloadSize % 2)
}

private func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func readULEB128(_ bytes: [UInt8], _ offset: inout Int, end: Int) -> UInt32? {
    var result: UInt32 = 0
    var shift: UInt32 = 0
    while offset < end && shift < 35 {
        let byte = bytes[offset]
        offset += 1
        result |= UInt32(byte & 0x7f) << shift
        if byte & 0x80 == 0 {
            return result
        }
        shift += 7
    }
    return nil
}

private func readWasmName(_ bytes: [UInt8], _ offset: inout Int, end: Int) -> String? {
    guard let length = readULEB128(bytes, &offset, end: end) else { return nil }
    let nameEnd = offset + Int(length)
    guard nameEnd <= end else { return nil }
    defer { offset = nameEnd }
    return String(bytes: bytes[offset..<nameEnd], encoding: .utf8)
}

private func wasmDefinedSymbols(in data: Data) -> [String] {
    let bytes = Array(data)
    guard bytes.count >= 8, bytes[0] == 0x00, bytes[1] == 0x61, bytes[2] == 0x73,
        bytes[3] == 0x6d
    else { return [] }

    let symbolTableSubsection: UInt8 = 8
    let undefinedFlag: UInt32 = 0x10
    let explicitNameFlag: UInt32 = 0x40
    var offset = 8
    var symbols = [String]()

    while offset < bytes.count {
        let sectionID = bytes[offset]
        offset += 1
        guard let sectionSize = readULEB128(bytes, &offset, end: bytes.count) else { break }
        let sectionEnd = offset + Int(sectionSize)
        guard sectionEnd <= bytes.count else { break }

        if sectionID == 0, let sectionName = readWasmName(bytes, &offset, end: sectionEnd),
            sectionName == "linking"
        {
            _ = readULEB128(bytes, &offset, end: sectionEnd)
            while offset < sectionEnd {
                let subsectionID = bytes[offset]
                offset += 1
                guard let subsectionSize = readULEB128(bytes, &offset, end: sectionEnd) else {
                    break
                }
                let subsectionEnd = offset + Int(subsectionSize)
                guard subsectionEnd <= sectionEnd else { break }

                if subsectionID == symbolTableSubsection,
                    let count = readULEB128(bytes, &offset, end: subsectionEnd)
                {
                    for _ in 0..<count {
                        guard let kind = readULEB128(bytes, &offset, end: subsectionEnd),
                            let flags = readULEB128(bytes, &offset, end: subsectionEnd)
                        else { break }
                        let isUndefined = flags & undefinedFlag != 0

                        switch kind {
                        case 0, 2, 4, 5:
                            _ = readULEB128(bytes, &offset, end: subsectionEnd)
                            if isUndefined {
                                if flags & explicitNameFlag != 0 {
                                    _ = readWasmName(bytes, &offset, end: subsectionEnd)
                                }
                            } else if let name = readWasmName(bytes, &offset, end: subsectionEnd) {
                                symbols.append(name)
                            }
                        case 1:
                            if let name = readWasmName(bytes, &offset, end: subsectionEnd),
                                !isUndefined
                            {
                                symbols.append(name)
                                _ = readULEB128(bytes, &offset, end: subsectionEnd)
                                _ = readULEB128(bytes, &offset, end: subsectionEnd)
                                _ = readULEB128(bytes, &offset, end: subsectionEnd)
                            }
                        case 3:
                            _ = readULEB128(bytes, &offset, end: subsectionEnd)
                        default:
                            offset = subsectionEnd
                        }
                    }
                }
                offset = subsectionEnd
            }
            return symbols
        }

        offset = sectionEnd
    }

    return symbols
}

private func arSymbolTable(for members: [(name: String, contents: Data, symbols: [String])]) -> Data
{
    let symbolCount = members.reduce(0) { $0 + $1.symbols.count }
    var payloadSize = 4 + (symbolCount * 4)
    for member in members {
        payloadSize += member.symbols.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    let symbolTableMemberSize = 60 + payloadSize + (payloadSize % 2)
    var memberOffsets = [UInt32]()
    var nextOffset = 8 + symbolTableMemberSize
    for member in members {
        memberOffsets.append(UInt32(nextOffset))
        nextOffset += arMemberSize(name: member.name, contentsCount: member.contents.count)
    }

    var symbolTable = Data()
    appendBigEndianUInt32(UInt32(symbolCount), to: &symbolTable)
    for (index, member) in members.enumerated() {
        for _ in member.symbols {
            appendBigEndianUInt32(memberOffsets[index], to: &symbolTable)
        }
    }
    for member in members {
        for symbol in member.symbols {
            symbolTable.append(Data(symbol.utf8))
            symbolTable.append(0)
        }
    }
    return symbolTable
}

private func arArchiveIndexStats(at url: URL) -> (symbolCount: Int, memberCount: Int)? {
    guard let data = try? Data(contentsOf: url), data.count >= 68 else {
        return nil
    }
    guard data.starts(with: Data("!<arch>\n".utf8)) else {
        return nil
    }

    var offset = 8
    var symbolCount: Int?
    var memberCount = 0
    while offset + 60 <= data.count {
        let headerStart = offset
        let rawName = String(bytes: data[offset..<(offset + 16)], encoding: .utf8) ?? ""
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let rawSize = String(bytes: data[(offset + 48)..<(offset + 58)], encoding: .utf8) ?? ""
        guard let size = Int(rawSize.trimmingCharacters(in: .whitespaces)) else { break }
        let payloadStart = offset + 60
        let payloadEnd = payloadStart + size
        guard payloadEnd <= data.count else { break }

        if headerStart == 8 && name == "/" {
            guard size >= 4 else { return nil }
            symbolCount =
                Int(data[payloadStart]) << 24
                | Int(data[payloadStart + 1]) << 16
                | Int(data[payloadStart + 2]) << 8
                | Int(data[payloadStart + 3])
        } else if !name.hasPrefix("/") && !name.hasPrefix("__.") {
            memberCount += 1
        }

        offset = payloadEnd + (size % 2)
    }

    guard let symbolCount else { return nil }
    return (symbolCount, memberCount)
}

private func arArchiveIndexedSymbols(at url: URL) -> Set<String>? {
    guard let data = try? Data(contentsOf: url), data.count >= 72 else {
        return nil
    }
    guard data.starts(with: Data("!<arch>\n".utf8)) else {
        return nil
    }

    let rawName = String(bytes: data[8..<24], encoding: .utf8) ?? ""
    guard rawName.trimmingCharacters(in: .whitespaces) == "/" else {
        return nil
    }
    let rawSize = String(bytes: data[56..<66], encoding: .utf8) ?? ""
    guard let size = Int(rawSize.trimmingCharacters(in: .whitespaces)), size >= 4 else {
        return nil
    }
    let payloadStart = 68
    let payloadEnd = payloadStart + size
    guard payloadEnd <= data.count else {
        return nil
    }

    let symbolCount =
        Int(data[payloadStart]) << 24
        | Int(data[payloadStart + 1]) << 16
        | Int(data[payloadStart + 2]) << 8
        | Int(data[payloadStart + 3])
    var offset = payloadStart + 4 + (symbolCount * 4)
    var symbols = Set<String>()
    while offset < payloadEnd {
        let start = offset
        while offset < payloadEnd && data[offset] != 0 {
            offset += 1
        }
        if offset > start, let symbol = String(bytes: data[start..<offset], encoding: .utf8) {
            symbols.insert(symbol)
        }
        offset += 1
    }
    return symbols
}

private func arArchiveHasUsableSymbolTable(at url: URL) -> Bool {
    guard let stats = arArchiveIndexStats(at: url), stats.symbolCount > 0 else {
        return false
    }
    guard stats.memberCount == 0 || stats.symbolCount >= max(1, stats.memberCount / 2) else {
        return false
    }
    if url.lastPathComponent == "libc.a" {
        guard let symbols = arArchiveIndexedSymbols(at: url) else {
            return false
        }
        return symbols.contains("__wasi_proc_exit") && symbols.contains("__wasi_fd_write")
    }
    return true
}

private func fileExistsAndNonEmpty(at url: URL, fileManager: FileManager = FileManager()) -> Bool {
    guard
        let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber
    else {
        return false
    }
    guard size.int64Value > 8 else {
        return false
    }
    if url.pathExtension == "a" {
        return arArchiveHasUsableSymbolTable(at: url)
    }
    return true
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
    let members = try fileManager.contentsOfDirectory(
        at: objectDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    .filter { url in
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { member in
        let contents = try Data(contentsOf: member)
        return (
            name: member.lastPathComponent,
            contents: contents,
            symbols: wasmDefinedSymbols(in: contents)
        )
    }

    try fileManager.createDirectory(
        at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    var archive = Data("!<arch>\n".utf8)
    appendArRawMember(to: &archive, headerName: "/", contents: arSymbolTable(for: members))
    for member in members {
        appendArMember(to: &archive, name: member.name, contents: member.contents)
    }

    let tempURL = archiveURL.deletingLastPathComponent()
        .appendingPathComponent(".\(archiveURL.lastPathComponent).tmp")
    try? fileManager.removeItem(at: tempURL)
    try archive.write(to: tempURL, options: .atomic)
    try? fileManager.removeItem(at: archiveURL)
    try fileManager.moveItem(at: tempURL, to: archiveURL)
}

private func createCSDK() {
    let installQueue = sdkInstallQueue

    // This operation copies the C SDK from $APPDIR to $HOME/Library and creates the *.a libraries
    // (we can't ship with .a libraries because of the AppStore rules, but we can ship with *.o
    // object files, provided they are in WASM format.
    installQueue.sync {
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
    return !fileExistsAndNonEmpty(
        at: libraryURL.appendingPathComponent("wasix-usr/lib/wasm32-wasi/libc.a"))
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
    let wasiImports = libraryURL.appendingPathComponent(
        "usr/lib/wasm32-wasi/libc.imports"
    ).path
    setenv(
        "CCC_OVERRIDE_OPTIONS",
        "#^--target=wasm32-wasi +-fno-exceptions +-lc-printscan-long-double +-Wl,--allow-undefined-file=\(wasiImports)",
        1)
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
