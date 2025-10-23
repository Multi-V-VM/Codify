//
//  CoreMLModelHandler.swift
//  Code
//
//  Helper for handling Core ML model files (.mlpackage, .mlmodelc, .mlmodel)
//

import Foundation
import CoreML
import UniformTypeIdentifiers

/// Handles Core ML model file detection and loading
class CoreMLModelHandler {

    /// Compile and cache a Core ML model
    /// Returns the URL to the compiled model (.mlmodelc)
    static func compileModel(at url: URL) throws -> URL {
        let modelType = getModelType(url: url)

        // If already compiled, return as-is
        if modelType == .compiled {
            return url
        }

        // Check if we already have a compiled version cached
        let compiledCacheURL = getCachedCompiledModelURL(for: url)
        if FileManager.default.fileExists(atPath: compiledCacheURL.path) {
            // Check if the compiled version is newer than the source
            if let sourceDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
               let compiledDate = try? FileManager.default.attributesOfItem(atPath: compiledCacheURL.path)[.modificationDate] as? Date,
               compiledDate > sourceDate {
                return compiledCacheURL
            }
        }

        // Compile the model
        do {
            let tempCompiledURL = try MLModel.compileModel(at: url)

            // Move to our cache directory
            try? FileManager.default.removeItem(at: compiledCacheURL)
            try? FileManager.default.createDirectory(
                at: compiledCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try FileManager.default.moveItem(at: tempCompiledURL, to: compiledCacheURL)

            return compiledCacheURL
        } catch {
            throw CoreMLModelError.loadingFailed("Model compilation failed: \(error.localizedDescription)")
        }
    }

    /// Get the cached compiled model URL
    private static func getCachedCompiledModelURL(for sourceURL: URL) -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelsCache = cacheDir.appendingPathComponent("CompiledModels")

        // Create a unique name based on the source file
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let compiledName = "\(sourceName).mlmodelc"

        return modelsCache.appendingPathComponent(compiledName)
    }

    /// Clear all cached compiled models
    static func clearCompiledModelsCache() throws {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelsCache = cacheDir.appendingPathComponent("CompiledModels")

        if FileManager.default.fileExists(atPath: modelsCache.path) {
            try FileManager.default.removeItem(at: modelsCache)
        }
    }

    /// Get the size of the compiled models cache
    static func getCompiledModelsCacheSize() -> Int64 {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelsCache = cacheDir.appendingPathComponent("CompiledModels")

        guard let enumerator = FileManager.default.enumerator(at: modelsCache, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }

    /// Check if a URL points to a Core ML model
    static func isCoreMLModel(url: URL) -> Bool {
        let path = url.path

        // Check for .mlpackage bundle
        if path.hasSuffix(".mlpackage") {
            return true
        }

        // Check for compiled model
        if path.hasSuffix(".mlmodelc") {
            return true
        }

        // Check for uncompiled model
        if path.hasSuffix(".mlmodel") {
            return true
        }

        return false
    }

    /// Get the model bundle URL (handles being inside a package)
    static func getModelBundleURL(from url: URL) -> URL? {
        var currentURL = url

        // Walk up the directory tree to find the .mlpackage or .mlmodelc bundle
        while currentURL.path != "/" {
            let path = currentURL.path

            if path.hasSuffix(".mlpackage") || path.hasSuffix(".mlmodelc") {
                return currentURL
            }

            currentURL = currentURL.deletingLastPathComponent()
        }

        // If the URL itself is a model file, return it
        if isCoreMLModel(url: url) {
            return url
        }

        return nil
    }

    /// Get model type from URL
    static func getModelType(url: URL) -> CoreMLModelType? {
        let path = url.path

        if path.hasSuffix(".mlpackage") {
            return .mlpackage
        } else if path.hasSuffix(".mlmodelc") {
            return .compiled
        } else if path.hasSuffix(".mlmodel") {
            return .source
        }

        return nil
    }

    /// Load a Core ML model from URL (handles all types)
    static func loadModel(from url: URL) throws -> MLModel {
        // Get the actual model bundle URL if we're inside a package
        guard let modelURL = getModelBundleURL(from: url) else {
            throw CoreMLModelError.invalidModelPath
        }

        let config = MLModelConfiguration()

        // Use CPU and Neural Engine for best performance on iOS
        if #available(iOS 16.0, *) {
            config.computeUnits = .cpuAndNeuralEngine
        } else {
            config.computeUnits = .cpuAndGPU
        }

        // Compile the model if needed (this will cache it)
        let compiledURL = try compileModel(at: modelURL)

        // Load the compiled model
        return try MLModel(contentsOf: compiledURL, configuration: config)
    }

    /// Get model info without fully loading it
    static func getModelInfo(from url: URL) async throws -> CoreMLModelInfo {
        guard let modelURL = getModelBundleURL(from: url) else {
            throw CoreMLModelError.invalidModelPath
        }

        let config = MLModelConfiguration()
        if #available(iOS 16.0, *) {
            config.computeUnits = .cpuAndNeuralEngine
        } else {
            config.computeUnits = .cpuAndGPU
        }

        // Compile the model if needed (this will cache it)
        let compiledURL = try compileModel(at: modelURL)

        let model = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        let modelDescription = model.modelDescription

        // Convert metadata dictionary to [String: Any]
        var metadataDict: [String: Any] = [:]
        for (key, value) in modelDescription.metadata {
            metadataDict[key.rawValue] = value
        }

        let modelType = getModelType(url: modelURL)

        return CoreMLModelInfo(
            url: modelURL,
            type: modelType ?? .unknown,
            inputDescription: modelDescription.inputDescriptionsByName.map { $0.key },
            outputDescription: modelDescription.outputDescriptionsByName.map { $0.key },
            metadata: metadataDict
        )
    }
}

// MARK: - Supporting Types

enum CoreMLModelType {
    case mlpackage      // .mlpackage (iOS 15+, bundle directory)
    case compiled       // .mlmodelc (compiled model directory)
    case source         // .mlmodel (source model file)
    case unknown

    var displayName: String {
        switch self {
        case .mlpackage: return "ML Package"
        case .compiled: return "Compiled Model"
        case .source: return "Source Model"
        case .unknown: return "Unknown"
        }
    }
}

enum CoreMLModelError: Error, LocalizedError {
    case invalidModelPath
    case modelNotFound
    case loadingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelPath:
            return "Invalid Core ML model path. Expected .mlpackage, .mlmodelc, or .mlmodel"
        case .modelNotFound:
            return "Core ML model file not found"
        case .loadingFailed(let reason):
            return "Failed to load Core ML model: \(reason)"
        }
    }
}

struct CoreMLModelInfo {
    let url: URL
    let type: CoreMLModelType
    let inputDescription: [String]
    let outputDescription: [String]
    let metadata: [String: Any]

    var displayName: String {
        (metadata[MLModelMetadataKey.description.rawValue] as? String) ??
        (metadata[MLModelMetadataKey.author.rawValue] as? String) ??
        url.lastPathComponent
    }
}
