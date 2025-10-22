//
//  MarketplaceService.swift
//  Code
//
//  Service for integrating with VSCode Extension Marketplace
//

import Foundation

/// Service for fetching extensions from VSCode Marketplace
class MarketplaceService {

    // MARK: - Constants

    // Using asplos.dev as proxy for VSCode Marketplace
    // This provides caching and reduces load on Microsoft's servers
    private let baseURL = "https://asplos.dev/api/marketplace"
    private let fallbackURL = "https://marketplace.visualstudio.com/_apis/public/gallery"
    private let apiVersion = "7.2-preview.1"

    // Shared URL session with caching
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,    // 50 MB memory cache
            diskCapacity: 200 * 1024 * 1024,     // 200 MB disk cache
            diskPath: "marketplace-cache"
        )
        return URLSession(configuration: config)
    }()

    // Flags for API request (controls what data is returned)
    private enum QueryFlags: Int {
        case none = 0x0
        case includeVersions = 0x1
        case includeFiles = 0x2
        case includeCategoryAndTags = 0x4
        case includeStatistics = 0x20
        case includeLatestVersionOnly = 0x200

        static let all: Int = 0x914  // Common combination used by VSCode
    }

    // MARK: - Public API

    /// Search for extensions in the marketplace
    /// - Parameters:
    ///   - query: Search query string
    ///   - pageSize: Number of results per page (default: 50)
    ///   - sortBy: Sort order (default: relevance)
    /// - Returns: Array of marketplace extensions
    func searchExtensions(
        query: String,
        pageSize: Int = 50,
        sortBy: SortBy = .relevance
    ) async throws -> [MarketplaceExtension] {
        let requestBody = buildSearchRequest(
            query: query,
            pageSize: pageSize,
            sortBy: sortBy
        )

        // Try asplos.dev first, fallback to Microsoft if needed
        var data: Data
        var response: URLResponse

        do {
            let url = URL(string: "\(baseURL)/extensionquery")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiVersion, forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(requestBody)

            (data, response) = try await urlSession.data(for: request)
        } catch {
            // Fallback to Microsoft's official API
            NSLog("asplos.dev failed, using fallback: \(error)")
            let url = URL(string: "\(fallbackURL)/extensionquery")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiVersion, forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(requestBody)

            (data, response) = try await urlSession.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MarketplaceError.networkError("Invalid response")
        }

        let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        return parseExtensions(from: searchResponse)
    }

    /// Get detailed information about a specific extension
    /// - Parameters:
    ///   - publisher: Extension publisher name
    ///   - extensionName: Extension identifier
    /// - Returns: Detailed extension information
    func getExtensionDetails(
        publisher: String,
        extensionName: String
    ) async throws -> MarketplaceExtension {
        let query = "\(publisher).\(extensionName)"
        let results = try await searchExtensions(query: query, pageSize: 1)

        guard let ext = results.first else {
            throw MarketplaceError.extensionNotFound
        }

        return ext
    }

    /// Download an extension package (.vsix file)
    /// - Parameters:
    ///   - publisher: Extension publisher name
    ///   - extensionName: Extension identifier
    ///   - version: Specific version to download (optional, latest if nil)
    /// - Returns: Local file URL of downloaded .vsix
    func downloadExtension(
        publisher: String,
        extensionName: String,
        version: String? = nil
    ) async throws -> URL {
        let versionString = version ?? "latest"

        // Try asplos.dev proxy first
        var downloadURL = "\(baseURL)/publishers/\(publisher)/vsextensions/\(extensionName)/\(versionString)/vspackage"

        guard var url = URL(string: downloadURL) else {
            throw MarketplaceError.invalidURL
        }

        var tempURL: URL
        var response: URLResponse

        do {
            (tempURL, response) = try await urlSession.download(from: url)
        } catch {
            // Fallback to Microsoft
            NSLog("Download from asplos.dev failed, using fallback")
            downloadURL = "\(fallbackURL)/publishers/\(publisher)/vsextensions/\(extensionName)/\(versionString)/vspackage"
            guard let fallbackUrl = URL(string: downloadURL) else {
                throw MarketplaceError.invalidURL
            }
            url = fallbackUrl
            (tempURL, response) = try await urlSession.download(from: url)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MarketplaceError.downloadFailed
        }

        // Move to permanent location
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(publisher).\(extensionName).vsix")

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        return destinationURL
    }

    /// Get popular/featured extensions
    /// - Parameter count: Number of extensions to fetch
    /// - Returns: Array of popular extensions
    func getFeaturedExtensions(count: Int = 20) async throws -> [MarketplaceExtension] {
        // Use empty query with InstallCount sort to get popular extensions
        return try await searchExtensions(query: "", pageSize: count, sortBy: .installs)
    }

    // MARK: - Private Helpers

    private func buildSearchRequest(
        query: String,
        pageSize: Int,
        sortBy: SortBy
    ) -> SearchRequest {
        SearchRequest(
            filters: [
                Filter(
                    criteria: [
                        Criterion(filterType: .searchText, value: query)
                    ],
                    pageSize: pageSize,
                    sortBy: sortBy.rawValue
                )
            ],
            flags: QueryFlags.all
        )
    }

    private func parseExtensions(from response: SearchResponse) -> [MarketplaceExtension] {
        guard let results = response.results.first?.extensions else {
            return []
        }

        return results.compactMap { ext in
            guard let publisher = ext.publisher?.publisherName,
                  let extensionName = ext.extensionName,
                  let displayName = ext.displayName else {
                return nil
            }

            let version = ext.versions?.first
            let versionString = version?.version ?? "unknown"
            let description = ext.shortDescription ?? ""

            // Extract statistics
            let statistics = ext.statistics ?? []
            let installCount = statistics.first(where: { $0.statisticName == "install" })?.value ?? 0
            let rating = statistics.first(where: { $0.statisticName == "averagerating" })?.value ?? 0

            return MarketplaceExtension(
                id: "\(publisher).\(extensionName)",
                publisher: publisher,
                extensionName: extensionName,
                displayName: displayName,
                description: description,
                version: versionString,
                installCount: Int(installCount),
                rating: rating,
                iconURL: version?.files?.first(where: { $0.assetType == "Microsoft.VisualStudio.Services.Icons.Default" })?.source
            )
        }
    }
}

// MARK: - Data Models

extension MarketplaceService {

    enum SortBy: Int {
        case relevance = 0
        case installs = 4
        case rating = 6
        case name = 2
        case publishedDate = 10
        case updatedDate = 1
    }

    enum MarketplaceError: Error, LocalizedError {
        case networkError(String)
        case extensionNotFound
        case downloadFailed
        case invalidURL
        case decodingError

        var errorDescription: String? {
            switch self {
            case .networkError(let message):
                return "Network error: \(message)"
            case .extensionNotFound:
                return "Extension not found in marketplace"
            case .downloadFailed:
                return "Failed to download extension package"
            case .invalidURL:
                return "Invalid marketplace URL"
            case .decodingError:
                return "Failed to decode marketplace response"
            }
        }
    }

    // MARK: - Request Models

    struct SearchRequest: Codable {
        let filters: [Filter]
        let flags: Int
    }

    struct Filter: Codable {
        let criteria: [Criterion]
        let pageSize: Int
        let sortBy: Int
    }

    struct Criterion: Codable {
        let filterType: FilterType
        let value: String

        enum FilterType: Int, Codable {
            case tag = 1
            case displayName = 2
            case searchText = 8
            case category = 5
        }
    }

    // MARK: - Response Models

    struct SearchResponse: Codable {
        let results: [ResultContainer]
    }

    struct ResultContainer: Codable {
        let extensions: [Extension]?
    }

    struct Extension: Codable {
        let publisher: Publisher?
        let extensionName: String?
        let displayName: String?
        let shortDescription: String?
        let versions: [Version]?
        let statistics: [Statistic]?
    }

    struct Publisher: Codable {
        let publisherName: String?
        let displayName: String?
    }

    struct Version: Codable {
        let version: String?
        let files: [File]?
    }

    struct File: Codable {
        let assetType: String?
        let source: String?
    }

    struct Statistic: Codable {
        let statisticName: String?
        let value: Double?
    }
}

// MARK: - Public Extension Model

/// Represents an extension from the marketplace
struct MarketplaceExtension: Identifiable, Codable {
    let id: String  // publisher.extensionName
    let publisher: String
    let extensionName: String
    let displayName: String
    let description: String
    let version: String
    let installCount: Int
    let rating: Double
    let iconURL: String?

    var formattedInstallCount: String {
        if installCount >= 1_000_000 {
            return String(format: "%.1fM", Double(installCount) / 1_000_000)
        } else if installCount >= 1_000 {
            return String(format: "%.1fK", Double(installCount) / 1_000)
        }
        return "\(installCount)"
    }

    var formattedRating: String {
        return String(format: "%.1f", rating)
    }
}

// MARK: - Usage Example

/*
 // Search for extensions
 let service = MarketplaceService()
 let results = try await service.searchExtensions(query: "python")

 // Get extension details
 let pythonExt = try await service.getExtensionDetails(
     publisher: "ms-python",
     extensionName: "python"
 )

 // Download extension
 let vsixURL = try await service.downloadExtension(
     publisher: "ms-python",
     extensionName: "python"
 )

 // Get popular extensions
 let featured = try await service.getFeaturedExtensions(count: 20)
 */
