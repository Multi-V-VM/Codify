//
//  VisxExtractor.swift
//  Code
//
//  Created by Claude on 26/10/2025.
//

import Foundation
import ZipArchive

/// Service for downloading and extracting .visx extension files
class VisxExtractor: ObservableObject {
    static let shared = VisxExtractor()

    @Published var isExtracting: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""
    @Published var error: String?

    private init() {}

    // MARK: - Public API

    /// Download and install a .visx extension
    func installExtension(
        from url: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        Task {
            do {
                await MainActor.run {
                    isExtracting = true
                    progress = 0.0
                    error = nil
                    statusMessage = "Downloading extension..."
                }

                // Download the .visx file
                let visxFile = try await downloadVisx(from: url)

                await MainActor.run {
                    progress = 0.3
                    statusMessage = "Extracting extension..."
                }

                // Extract the .visx file
                let extractedPath = try await extractVisx(at: visxFile)

                await MainActor.run {
                    progress = 0.8
                    statusMessage = "Reading manifest..."
                }

                // Validate the extension
                try validateExtension(at: extractedPath)

                await MainActor.run {
                    progress = 1.0
                    statusMessage = "Installation complete"
                    isExtracting = false
                }

                completion(.success(extractedPath))

            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.statusMessage = "Installation failed"
                    self.isExtracting = false
                }
                completion(.failure(error))
            }
        }
    }

    /// Install extension from local file
    func installLocalExtension(
        at fileURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        Task {
            do {
                await MainActor.run {
                    isExtracting = true
                    progress = 0.0
                    error = nil
                    statusMessage = "Extracting extension..."
                }

                // Extract the .visx file
                let extractedPath = try await extractVisx(at: fileURL)

                await MainActor.run {
                    progress = 0.8
                    statusMessage = "Reading manifest..."
                }

                // Validate the extension
                try validateExtension(at: extractedPath)

                await MainActor.run {
                    progress = 1.0
                    statusMessage = "Installation complete"
                    isExtracting = false
                }

                completion(.success(extractedPath))

            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.statusMessage = "Installation failed"
                    self.isExtracting = false
                }
                completion(.failure(error))
            }
        }
    }

    // MARK: - Private Helpers

    /// Download .visx file from URL
    private func downloadVisx(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw VisxError.downloadFailed
        }

        // Move to a persistent location
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let visxURL = documentsURL.appendingPathComponent("downloaded.visx")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: visxURL)
        try FileManager.default.moveItem(at: tempURL, to: visxURL)

        return visxURL
    }

    /// Extract .visx (zip) file to extensions directory
    private func extractVisx(at fileURL: URL) async throws -> URL {
        // Get extensions directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let extensionsDir = documentsURL.appendingPathComponent("Extensions")

        // Create extensions directory if needed
        try? FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)

        // Create unique directory for this extension
        let extensionID = UUID().uuidString
        let extractPath = extensionsDir.appendingPathComponent(extensionID)
        try FileManager.default.createDirectory(at: extractPath, withIntermediateDirectories: true)

        NSLog("📦 Extracting .visx file: \(fileURL.path)")
        NSLog("📂 Destination: \(extractPath.path)")

        // Extract using ZipArchive with improved error handling
        var extractionError: Error? = nil
        let success = SSZipArchive.unzipFile(
            atPath: fileURL.path,
            toDestination: extractPath.path,
            overwrite: true,
            password: nil,
            progressHandler: { [weak self] entryNumber, total, completedSize, totalSize in
                let progress = Double(completedSize) / Double(totalSize)
                Task { @MainActor in
                    self?.progress = 0.3 + (progress * 0.5) // 30-80% progress
                }
                NSLog("📊 Extracting: \(entryNumber)/\(total) files, \(completedSize)/\(totalSize) bytes")
            },
            completionHandler: { path, succeeded, error in
                if let error = error {
                    NSLog("❌ Unzip error: \(error.localizedDescription)")
                    extractionError = error
                } else if succeeded {
                    NSLog("✅ Unzip completed: \(path)")
                }
            }
        )

        if !success {
            if let error = extractionError {
                throw error
            }
            throw VisxError.extractionFailed
        }

        // Verify extraction
        let extractedContents = try FileManager.default.contentsOfDirectory(
            at: extractPath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        NSLog("📁 Extracted \(extractedContents.count) items:")
        for item in extractedContents.prefix(10) {
            NSLog("  - \(item.lastPathComponent)")
        }

        return extractPath
    }

    /// Validate extracted extension
    private func validateExtension(at path: URL) throws {
        // Check for required files
        let manifestURL = path.appendingPathComponent("manifest.json")
        let packageURL = path.appendingPathComponent("package.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw VisxError.invalidExtension("Missing manifest.json")
        }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw VisxError.invalidExtension("Missing package.json")
        }

        // Parse manifest to validate
        let manifestData = try Data(contentsOf: manifestURL)
        _ = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]

        // Parse package.json
        let packageData = try Data(contentsOf: packageURL)
        guard let package = try JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              let name = package["name"] as? String else {
            throw VisxError.invalidExtension("Invalid package.json")
        }

        print("✅ Validated extension: \(name)")
    }

    // MARK: - Extension Management

    /// List installed extensions
    func listInstalledExtensions() -> [ExtensionInfo] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let extensionsDir = documentsURL.appendingPathComponent("Extensions")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: extensionsDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents.compactMap { dir -> ExtensionInfo? in
            let packageURL = dir.appendingPathComponent("package.json")

            guard let packageData = try? Data(contentsOf: packageURL),
                  let package = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
                  let name = package["name"] as? String else {
                return nil
            }

            let version = package["version"] as? String ?? "unknown"
            let displayName = package["displayName"] as? String ?? name
            let description = package["description"] as? String ?? ""

            return ExtensionInfo(
                id: dir.lastPathComponent,
                name: name,
                displayName: displayName,
                version: version,
                description: description,
                path: dir
            )
        }
    }

    /// Remove an installed extension
    func removeExtension(_ extensionInfo: ExtensionInfo) throws {
        try FileManager.default.removeItem(at: extensionInfo.path)
    }
}

// MARK: - Supporting Types

enum VisxError: LocalizedError {
    case downloadFailed
    case extractionFailed
    case invalidExtension(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download extension"
        case .extractionFailed:
            return "Failed to extract extension archive"
        case .invalidExtension(let reason):
            return "Invalid extension: \(reason)"
        }
    }
}

struct ExtensionInfo: Identifiable {
    let id: String
    let name: String
    let displayName: String
    let version: String
    let description: String
    let path: URL
}
