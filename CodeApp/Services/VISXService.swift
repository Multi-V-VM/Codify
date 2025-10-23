///
//  VISXService.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import Foundation
import Compression
import ZIPFoundation

/// VISX Package Manifest
struct VISXManifest: Codable {
    let visx_version: String
    let package: PackageInfo
    let created_at: String
    let stats: Stats
    let files: [FileInfo]
    let dependencies: [String: String]
    let metadata: Metadata

    struct PackageInfo: Codable {
        let name: String
        let version: String
        let description: String
        let type: String
    }

    struct Stats: Codable {
        let total_files: Int
        let total_size: Int
        let compressed_size: Int
    }

    struct FileInfo: Codable {
        let path: String
        let size: Int
        let checksum: String
    }

    struct Metadata: Codable {
        let platform: String
        let minimum_version: String
        let requires: [String]
    }
}

/// VISX Service - Download and decompress .visx packages
class VISXService: NSObject, ObservableObject {
    static let shared = VISXService()

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentOperation: String = ""
    @Published var error: String?

    private var downloadTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let cacheDirectory: URL
    private let packagesDirectory: URL

    private override init() {
        // Setup directories
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDirectory = documentsURL.appendingPathComponent("VISX/Cache")
        packagesDirectory = documentsURL.appendingPathComponent("VISX/Packages")

        super.init()

        // Create directories if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Download

    /// Download a .visx package from a remote URL
    func downloadPackage(from url: URL) async throws -> VISXManifest {
        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
            currentOperation = "Downloading \(url.lastPathComponent)..."
            error = nil
        }

        defer {
            Task { @MainActor in
                isDownloading = false
                currentOperation = ""
            }
        }

        // Download file
        let localURL = try await download(from: url)

        // Decompress and install
        let manifest = try await decompressAndInstall(visxFile: localURL)

        // Clean up cache
        try? FileManager.default.removeItem(at: localURL)

        return manifest
    }

    private func download(from url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url) { localURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let localURL = localURL else {
                    continuation.resume(throwing: VISXError.downloadFailed("No local URL"))
                    return
                }

                // Move to cache directory
                let cacheURL = self.cacheDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: cacheURL)

                do {
                    try FileManager.default.moveItem(at: localURL, to: cacheURL)
                    continuation.resume(returning: cacheURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            self.downloadTask = task
            task.resume()
        }
    }

    /// Cancel current download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil

        Task { @MainActor in
            isDownloading = false
            currentOperation = ""
            error = "Download cancelled"
        }
    }

    // MARK: - Decompression

    /// Decompress and install a .visx package
    func decompressAndInstall(visxFile: URL) async throws -> VISXManifest {
        await MainActor.run {
            currentOperation = "Decompressing package..."
        }

        // Create temporary directory for extraction
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Decompress tar.gz archive
        try await decompressTarGz(from: visxFile, to: tempDir)

        // Read manifest
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw VISXError.invalidPackage("No manifest.json found")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(VISXManifest.self, from: manifestData)

        await MainActor.run {
            currentOperation = "Verifying package..."
        }

        // Verify files
        try verifyPackageIntegrity(manifest: manifest, extractedDir: tempDir)

        await MainActor.run {
            currentOperation = "Installing package..."
        }

        // Install package
        try installPackage(manifest: manifest, sourceDir: tempDir)

        await MainActor.run {
            currentOperation = "Complete!"
        }

        return manifest
    }

    private func decompressTarGz(from sourceURL: URL, to destinationURL: URL) async throws {
        // Use ZIPFoundation for decompression
        // Note: VISX packages should be created as ZIP files, not tar.gz
        try FileManager.default.unzipItem(at: sourceURL, to: destinationURL)
    }

    private func verifyPackageIntegrity(manifest: VISXManifest, extractedDir: URL) throws {
        for fileInfo in manifest.files {
            let filePath = extractedDir.appendingPathComponent(fileInfo.path)

            guard FileManager.default.fileExists(atPath: filePath.path) else {
                throw VISXError.verificationFailed("Missing file: \(fileInfo.path)")
            }

            // Verify checksum
            let calculatedChecksum = try calculateSHA256(of: filePath)
            guard calculatedChecksum == fileInfo.checksum else {
                throw VISXError.verificationFailed(
                    "Checksum mismatch for \(fileInfo.path): expected \(fileInfo.checksum), got \(calculatedChecksum)"
                )
            }
        }
    }

    private func calculateSHA256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func installPackage(manifest: VISXManifest, sourceDir: URL) throws {
        let packageName = manifest.package.name
        let packageVersion = manifest.package.version
        let packageType = manifest.package.type

        // Determine installation directory based on package type
        let installDir: URL
        switch packageType {
        case "wasm":
            installDir = packagesDirectory.appendingPathComponent("WASM/\(packageName)")
        case "node":
            installDir = packagesDirectory.appendingPathComponent("Node/\(packageName)")
        default:
            installDir = packagesDirectory.appendingPathComponent("Generic/\(packageName)")
        }

        // Remove existing installation
        try? FileManager.default.removeItem(at: installDir)

        // Create installation directory
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        // Copy files
        for fileInfo in manifest.files {
            let sourcePath = sourceDir.appendingPathComponent(fileInfo.path)
            let destPath = installDir.appendingPathComponent(fileInfo.path)

            // Create parent directory if needed
            let parentDir = destPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Copy file
            try FileManager.default.copyItem(at: sourcePath, to: destPath)
        }

        // Save manifest
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: installDir.appendingPathComponent("manifest.json"))

        print("✅ Installed \(packageName) v\(packageVersion) to \(installDir.path)")
    }

    // MARK: - Package Management

    /// Get list of installed packages
    func getInstalledPackages() -> [VISXManifest] {
        var packages: [VISXManifest] = []

        let packageTypes = ["WASM", "Node", "Generic"]

        for type in packageTypes {
            let typeDir = packagesDirectory.appendingPathComponent(type)

            guard let enumerator = FileManager.default.enumerator(
                at: typeDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let packageDir as URL in enumerator {
                let manifestURL = packageDir.appendingPathComponent("manifest.json")

                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    if let data = try? Data(contentsOf: manifestURL),
                       let manifest = try? JSONDecoder().decode(VISXManifest.self, from: data) {
                        packages.append(manifest)
                    }
                }
            }
        }

        return packages
    }

    /// Uninstall a package
    func uninstallPackage(name: String) throws {
        let packageTypes = ["WASM", "Node", "Generic"]

        for type in packageTypes {
            let packageDir = packagesDirectory.appendingPathComponent("\(type)/\(name)")

            if FileManager.default.fileExists(atPath: packageDir.path) {
                try FileManager.default.removeItem(at: packageDir)
                print("✅ Uninstalled \(name)")
                return
            }
        }

        throw VISXError.packageNotFound(name)
    }

    /// Get package installation path
    func getPackagePath(name: String) -> URL? {
        let packageTypes = ["WASM", "Node", "Generic"]

        for type in packageTypes {
            let packageDir = packagesDirectory.appendingPathComponent("\(type)/\(name)")

            if FileManager.default.fileExists(atPath: packageDir.path) {
                return packageDir
            }
        }

        return nil
    }
}

// MARK: - URLSessionDownloadDelegate

extension VISXService: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled in download task completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        Task { @MainActor in
            self.downloadProgress = progress
        }
    }
}

// MARK: - Errors

enum VISXError: Error, LocalizedError {
    case downloadFailed(String)
    case decompressionFailed(String)
    case invalidPackage(String)
    case verificationFailed(String)
    case installationFailed(String)
    case packageNotFound(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .decompressionFailed(let message):
            return "Decompression failed: \(message)"
        case .invalidPackage(let message):
            return "Invalid package: \(message)"
        case .verificationFailed(let message):
            return "Verification failed: \(message)"
        case .installationFailed(let message):
            return "Installation failed: \(message)"
        case .packageNotFound(let name):
            return "Package not found: \(name)"
        }
    }
}

// MARK: - Helper for SHA256 (requires CommonCrypto)
import CommonCrypto

private func CC_SHA256(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? {
    return CommonCrypto.CC_SHA256(data, len, md)
}
