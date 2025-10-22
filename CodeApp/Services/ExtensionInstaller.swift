//
//  ExtensionInstaller.swift
//  Code
//
//  Service for installing VSCode extensions from .vsix packages
//

import Foundation
import ZIPFoundation

/// Service for extracting and installing VSCode extensions
class ExtensionInstaller {

    // MARK: - Constants

    /// Directory where extensions are installed
    private static var extensionsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Extensions", isDirectory: true)
    }

    // MARK: - Errors

    enum InstallError: Error, LocalizedError {
        case invalidVsixFile
        case missingManifest
        case invalidManifest
        case extractionFailed(String)
        case installationFailed(String)
        case extensionAlreadyInstalled

        var errorDescription: String? {
            switch self {
            case .invalidVsixFile:
                return "Invalid .vsix file format"
            case .missingManifest:
                return "Extension manifest (package.json) not found"
            case .invalidManifest:
                return "Invalid extension manifest format"
            case .extractionFailed(let message):
                return "Failed to extract extension: \(message)"
            case .installationFailed(let message):
                return "Failed to install extension: \(message)"
            case .extensionAlreadyInstalled:
                return "Extension is already installed"
            }
        }
    }

    // MARK: - Installation

    /// Install an extension from a .vsix file
    /// - Parameter vsixURL: URL to the downloaded .vsix file
    /// - Returns: Installed extension metadata
    func install(vsixURL: URL) async throws -> InstalledExtension {
        NSLog("🔧 Installing extension from: \(vsixURL.path)")

        // 1. Create temporary extraction directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            // Clean up temporary directory
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 2. Extract .vsix file (it's a ZIP archive)
        try extractVsix(from: vsixURL, to: tempDir)
        NSLog("✅ Extracted .vsix to temporary directory")

        // 3. Find and parse package.json manifest
        let manifest = try parseManifest(in: tempDir)
        NSLog("✅ Parsed manifest: \(manifest.name) v\(manifest.version)")

        // 4. Check if already installed
        let extensionID = "\(manifest.publisher).\(manifest.name)"
        let targetDir = Self.extensionsDirectory.appendingPathComponent(extensionID)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            NSLog("⚠️ Extension already exists at: \(targetDir.path)")
            // Remove old version
            try FileManager.default.removeItem(at: targetDir)
        }

        // 5. Create extensions directory if needed
        try FileManager.default.createDirectory(
            at: Self.extensionsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // 6. Find extension folder inside extracted archive
        // .vsix structure: /extension/package.json and other files
        let extensionSourceDir = tempDir.appendingPathComponent("extension")

        guard FileManager.default.fileExists(atPath: extensionSourceDir.path) else {
            throw InstallError.extractionFailed("extension folder not found in .vsix")
        }

        // 7. Move extension files to permanent location
        try FileManager.default.moveItem(at: extensionSourceDir, to: targetDir)
        NSLog("✅ Installed extension to: \(targetDir.path)")

        // 8. Create installed extension metadata
        let installedExtension = InstalledExtension(
            id: extensionID,
            name: manifest.name,
            displayName: manifest.displayName,
            description: manifest.description,
            version: manifest.version,
            publisher: manifest.publisher,
            installPath: targetDir.path,
            enabled: true,
            manifest: manifest
        )

        // 9. Save to installed extensions list
        try saveInstalledExtension(installedExtension)

        NSLog("🎉 Extension installed successfully: \(extensionID)")
        return installedExtension
    }

    /// Uninstall an extension
    /// - Parameter extensionID: Extension identifier (publisher.name)
    func uninstall(extensionID: String) async throws {
        let targetDir = Self.extensionsDirectory.appendingPathComponent(extensionID)

        guard FileManager.default.fileExists(atPath: targetDir.path) else {
            NSLog("⚠️ Extension not found: \(extensionID)")
            return
        }

        // Remove extension directory
        try FileManager.default.removeItem(at: targetDir)

        // Remove from installed list
        try removeInstalledExtension(extensionID)

        NSLog("🗑️ Uninstalled extension: \(extensionID)")
    }

    /// Get list of installed extensions
    func getInstalledExtensions() -> [InstalledExtension] {
        guard let data = UserDefaults.standard.data(forKey: "InstalledExtensions"),
              let extensions = try? JSONDecoder().decode([InstalledExtension].self, from: data) else {
            return []
        }
        return extensions
    }

    // MARK: - Private Helpers

    /// Extract .vsix file (ZIP format) to directory
    private func extractVsix(from vsixURL: URL, to destinationURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // .vsix is a ZIP file, extract it using ZIPFoundation
            guard let archive = Archive(url: vsixURL, accessMode: .read) else {
                throw InstallError.invalidVsixFile
            }

            for entry in archive {
                let entryPath = destinationURL.appendingPathComponent(entry.path)

                // Create intermediate directories
                if entry.type == .directory {
                    try FileManager.default.createDirectory(
                        at: entryPath,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } else {
                    // Create parent directory if needed
                    let parentDir = entryPath.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )

                    // Extract file
                    _ = try archive.extract(entry, to: entryPath)
                }
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.extractionFailed(error.localizedDescription)
        }
    }

    /// Parse package.json manifest from extracted extension
    private func parseManifest(in directory: URL) throws -> ExtensionManifest {
        // Look for package.json in /extension/package.json
        let manifestURL = directory
            .appendingPathComponent("extension")
            .appendingPathComponent("package.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw InstallError.missingManifest
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
            return manifest
        } catch {
            NSLog("❌ Failed to parse manifest: \(error)")
            throw InstallError.invalidManifest
        }
    }

    /// Save installed extension to UserDefaults
    private func saveInstalledExtension(_ extension: InstalledExtension) throws {
        var extensions = getInstalledExtensions()

        // Remove old version if exists
        extensions.removeAll { $0.id == `extension`.id }

        // Add new version
        extensions.append(`extension`)

        // Save to UserDefaults
        let data = try JSONEncoder().encode(extensions)
        UserDefaults.standard.set(data, forKey: "InstalledExtensions")
    }

    /// Remove installed extension from UserDefaults
    private func removeInstalledExtension(_ extensionID: String) throws {
        var extensions = getInstalledExtensions()
        extensions.removeAll { $0.id == extensionID }

        let data = try JSONEncoder().encode(extensions)
        UserDefaults.standard.set(data, forKey: "InstalledExtensions")
    }
}

// MARK: - Data Models

/// Extension package.json manifest structure
struct ExtensionManifest: Codable {
    let name: String
    let displayName: String?
    let description: String?
    let version: String
    let publisher: String
    let engines: Engines?
    let categories: [String]?
    let activationEvents: [String]?
    let main: String?
    let contributes: Contributes?
    let icon: String?

    struct Engines: Codable {
        let vscode: String?
    }

    struct Contributes: Codable {
        let commands: [Command]?
        let keybindings: [Keybinding]?
        let languages: [Language]?
        let grammars: [Grammar]?
        let themes: [Theme]?

        struct Command: Codable {
            let command: String
            let title: String
            let category: String?
        }

        struct Keybinding: Codable {
            let command: String
            let key: String
            let mac: String?
            let when: String?
        }

        struct Language: Codable {
            let id: String
            let extensions: [String]?
            let aliases: [String]?
        }

        struct Grammar: Codable {
            let language: String?
            let scopeName: String
            let path: String
        }

        struct Theme: Codable {
            let label: String
            let uiTheme: String
            let path: String
        }
    }
}

/// Installed extension metadata
struct InstalledExtension: Codable, Identifiable {
    let id: String  // publisher.name
    let name: String
    let displayName: String?
    let description: String?
    let version: String
    let publisher: String
    let installPath: String
    var enabled: Bool
    let manifest: ExtensionManifest

    var effectiveDisplayName: String {
        displayName ?? name
    }

    var effectiveDescription: String {
        description ?? ""
    }
}

// MARK: - Usage Example

/*
 // Install extension
 let installer = ExtensionInstaller()
 let vsixURL = URL(fileURLWithPath: "/tmp/ms-python.python.vsix")
 let installedExt = try await installer.install(vsixURL: vsixURL)

 // Get installed extensions
 let installed = installer.getInstalledExtensions()

 // Uninstall extension
 try await installer.uninstall(extensionID: "ms-python.python")
 */
