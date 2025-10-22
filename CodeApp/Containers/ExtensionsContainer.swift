//
//  ExtensionsContainer.swift
//  Code
//
//  Main container view for the Extensions sidebar
//

import SwiftUI

struct ExtensionsContainer: View {
    @EnvironmentObject var App: MainApp
    @EnvironmentObject var extensionManager: ExtensionManager
    @State private var selectedSection: ExtensionSection = .installed
    @State private var searchText: String = ""
    @State private var showMarketplace: Bool = false

    // Marketplace integration
    @State private var marketplaceExtensions: [MarketplaceExtension] = []
    @State private var featuredExtensions: [MarketplaceExtension] = []
    @State private var isLoadingMarketplace: Bool = false
    @State private var marketplaceError: String? = nil
    private let marketplaceService = MarketplaceService()
    private let extensionInstaller = ExtensionInstaller()

    enum ExtensionSection: String, CaseIterable {
        case installed = "Installed"
        case marketplace = "Marketplace"
        case recommended = "Recommended"
        case updates = "Updates"

        var icon: String {
            switch self {
            case .installed: return "checkmark.circle.fill"
            case .marketplace: return "square.grid.2x2"
            case .recommended: return "star.fill"
            case .updates: return "arrow.down.circle.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search
            extensionsHeader

            // Section tabs
            sectionPicker

            Divider()

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedSection {
                    case .installed:
                        installedExtensionsView
                    case .marketplace:
                        marketplaceView
                    case .recommended:
                        recommendedView
                    case .updates:
                        updatesView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.init(id: "sideBar.background"))
    }

    // MARK: - Header

    private var extensionsHeader: some View {
        VStack(spacing: 8) {
            // Title
            HStack {
                Text("EXTENSIONS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .padding(.top, 8)

                Spacer()

                // Action buttons
                Menu {
                    Button(action: refreshExtensions) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button(action: checkForUpdates) {
                        Label("Check for Updates", systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button(action: openSettings) {
                        Label("Extension Settings", systemImage: "gear")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                TextField("Search extensions...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.init(id: "input.background"))
            .cornerRadius(4)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(ExtensionSection.allCases, id: \.self) { section in
                Button(action: {
                    selectedSection = section
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.system(size: 11))

                        Text(section.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(
                        selectedSection == section
                            ? Color.init(id: "textLink.activeForeground")
                            : Color.secondary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        selectedSection == section
                            ? Color.init(id: "list.activeSelectionBackground").opacity(0.5)
                            : Color.clear
                    )
                    .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Installed Extensions View

    private var installedExtensionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Built-in extensions section
            SectionHeader(title: "Built-in", count: builtInExtensions.count)

            ForEach(builtInExtensions, id: \.id) { ext in
                ExtensionRow(extension: ext, isBuiltIn: true)
            }

            if !installedUserExtensions.isEmpty {
                SectionHeader(title: "Installed", count: installedUserExtensions.count)
                    .padding(.top, 16)

                ForEach(installedUserExtensions, id: \.id) { ext in
                    ExtensionRow(extension: ext, isBuiltIn: false) {
                        uninstallExtension(ext.id)
                    }
                }
            }

            if installedUserExtensions.isEmpty && builtInExtensions.isEmpty {
                emptyState(
                    icon: "puzzlepiece.extension",
                    message: "No extensions installed",
                    action: "Browse Marketplace",
                    onAction: { selectedSection = .marketplace }
                )
            }
        }
    }

    // MARK: - Marketplace View

    private var marketplaceView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingMarketplace {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(.top, 60)

                    Text("Loading marketplace...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = marketplaceError {
                // Error state
                emptyState(
                    icon: "exclamationmark.triangle.fill",
                    message: error,
                    action: "Retry",
                    onAction: loadMarketplace
                )
            } else if marketplaceExtensions.isEmpty {
                // Empty state
                emptyState(
                    icon: "square.grid.2x2",
                    message: "No extensions found",
                    action: "Refresh",
                    onAction: loadMarketplace
                )
            } else {
                // Extensions list
                if !searchText.isEmpty {
                    SectionHeader(
                        title: "Search Results",
                        count: marketplaceExtensions.count
                    )
                } else {
                    SectionHeader(title: "Popular Extensions", count: nil)
                }

                ForEach(marketplaceExtensions, id: \.id) { ext in
                    RealMarketplaceExtensionRow(
                        extensionInfo: ext,
                        onInstall: {
                            installExtension(ext)
                        }
                    )
                }
            }
        }
        .onAppear {
            if marketplaceExtensions.isEmpty && !isLoadingMarketplace {
                loadMarketplace()
            }
        }
        .onChange(of: searchText) { newValue in
            // Debounced search
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
                await performSearch(query: newValue)
            }
        }
    }

    // MARK: - Recommended View

    private var recommendedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Recommended for You", count: nil)

            emptyState(
                icon: "star.fill",
                message: "No recommendations available",
                action: "Browse Marketplace",
                onAction: { selectedSection = .marketplace }
            )
        }
    }

    // MARK: - Updates View

    private var updatesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Available Updates", count: 0)

            emptyState(
                icon: "checkmark.circle.fill",
                message: "All extensions are up to date",
                action: "Check for Updates",
                onAction: checkForUpdates
            )
        }
    }

    // MARK: - Helper Views

    private func emptyState(
        icon: String,
        message: String,
        action: String,
        onAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.top, 60)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onAction) {
                Text(action)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private var builtInExtensions: [ExtensionInfo] {
        // TODO: Get from extensionManager
        [
            ExtensionInfo(
                id: "monaco-editor",
                name: "Monaco Editor",
                description: "Code editor with syntax highlighting",
                version: "1.0.0",
                author: "Code App",
                isEnabled: true
            ),
            ExtensionInfo(
                id: "terminal",
                name: "Terminal",
                description: "Integrated terminal emulator",
                version: "1.0.0",
                author: "Code App",
                isEnabled: true
            ),
            ExtensionInfo(
                id: "git",
                name: "Git",
                description: "Source control management",
                version: "1.0.0",
                author: "Code App",
                isEnabled: true
            )
        ]
        .filter { ext in
            searchText.isEmpty || ext.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var installedUserExtensions: [ExtensionInfo] {
        // Load from extension installer
        let installed = extensionInstaller.getInstalledExtensions()
        return installed.map { ext in
            ExtensionInfo(
                id: ext.id,
                name: ext.effectiveDisplayName,
                description: ext.effectiveDescription,
                version: ext.version,
                author: ext.publisher,
                isEnabled: ext.enabled
            )
        }
        .filter { ext in
            searchText.isEmpty || ext.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sampleMarketplaceExtensions: [ExtensionInfo] {
        [
            ExtensionInfo(
                id: "ms-python.python",
                name: "Python",
                description: "IntelliSense, linting, debugging for Python",
                version: "2023.1.0",
                author: "Microsoft",
                downloads: 74000000,
                rating: 4.5,
                isEnabled: false
            ),
            ExtensionInfo(
                id: "esbenp.prettier-vscode",
                name: "Prettier",
                description: "Code formatter using prettier",
                version: "10.1.0",
                author: "Prettier",
                downloads: 25000000,
                rating: 4.8,
                isEnabled: false
            )
        ]
    }

    // MARK: - Actions

    private func refreshExtensions() {
        NSLog("Refreshing extensions...")
        loadMarketplace()
    }

    private func checkForUpdates() {
        NSLog("Checking for updates...")
        // TODO: Implement update check
    }

    private func openSettings() {
        NSLog("Opening extension settings...")
        // TODO: Open settings
    }

    // MARK: - Marketplace API Integration

    private func loadMarketplace() {
        Task {
            isLoadingMarketplace = true
            marketplaceError = nil

            do {
                // Load featured/popular extensions
                let extensions = try await marketplaceService.getFeaturedExtensions(count: 50)
                await MainActor.run {
                    self.marketplaceExtensions = extensions
                    self.featuredExtensions = extensions
                    self.isLoadingMarketplace = false
                }
            } catch {
                await MainActor.run {
                    self.marketplaceError = "Failed to load marketplace: \(error.localizedDescription)"
                    self.isLoadingMarketplace = false
                }
                NSLog("Marketplace load error: \(error)")
            }
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            await MainActor.run {
                self.marketplaceExtensions = self.featuredExtensions
            }
            return
        }

        await MainActor.run {
            self.isLoadingMarketplace = true
            self.marketplaceError = nil
        }

        do {
            let results = try await marketplaceService.searchExtensions(
                query: query,
                pageSize: 50
            )

            await MainActor.run {
                self.marketplaceExtensions = results
                self.isLoadingMarketplace = false
            }
        } catch {
            await MainActor.run {
                self.marketplaceError = "Search failed: \(error.localizedDescription)"
                self.isLoadingMarketplace = false
            }
            NSLog("Search error: \(error)")
        }
    }

    private func installExtension(_ extension: MarketplaceExtension) {
        Task {
            NSLog("🔧 Installing extension: \(`extension`.displayName)")

            do {
                // 1. Download the extension .vsix file
                let vsixURL = try await marketplaceService.downloadExtension(
                    publisher: `extension`.publisher,
                    extensionName: `extension`.extensionName,
                    version: `extension`.version
                )

                NSLog("✅ Downloaded extension to: \(vsixURL.path)")

                // 2. Extract and install the extension
                let installedExt = try await extensionInstaller.install(vsixURL: vsixURL)

                NSLog("🎉 Extension installed successfully: \(installedExt.id)")

                await MainActor.run {
                    // Refresh the installed extensions view
                    if selectedSection == .installed {
                        // Force view refresh by toggling state
                        selectedSection = .marketplace
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            selectedSection = .installed
                        }
                    }

                    // Show success notification (TODO: Add proper toast/alert)
                    NSLog("✅ \(installedExt.effectiveDisplayName) v\(installedExt.version) installed!")
                }
            } catch {
                NSLog("❌ Installation error: \(error.localizedDescription)")
                await MainActor.run {
                    // Show error notification (TODO: Add proper alert)
                    marketplaceError = "Failed to install: \(error.localizedDescription)"
                }
            }
        }
    }

    private func uninstallExtension(_ extensionID: String) {
        Task {
            NSLog("🗑️ Uninstalling extension: \(extensionID)")

            do {
                // Uninstall the extension
                try await extensionInstaller.uninstall(extensionID: extensionID)

                NSLog("✅ Extension uninstalled: \(extensionID)")

                await MainActor.run {
                    // Force view refresh
                    selectedSection = .marketplace
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        selectedSection = .installed
                    }
                }
            } catch {
                NSLog("❌ Uninstall error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Supporting Views

struct SectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if let count = count {
                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ExtensionRow: View {
    let extensionInfo: ExtensionInfo
    let isBuiltIn: Bool
    let onUninstall: (() -> Void)?
    @State private var isHovered = false

    init(extension: ExtensionInfo, isBuiltIn: Bool, onUninstall: (() -> Void)? = nil) {
        self.extensionInfo = `extension`
        self.isBuiltIn = isBuiltIn
        self.onUninstall = onUninstall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                // Icon
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(extensionInfo.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.init(id: "foreground"))

                    Text(extensionInfo.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if isBuiltIn {
                            Text("Built-in")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Text("v\(extensionInfo.version)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Actions
                if isHovered {
                    Menu {
                        if !isBuiltIn {
                            Button("Disable") { /* TODO */ }
                            Divider()
                        }
                        Button("Extension Settings") { /* TODO */ }
                        if !isBuiltIn {
                            Divider()
                            Button(action: {
                                onUninstall?()
                            }) {
                                Label("Uninstall", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(
            isHovered
                ? Color.init(id: "list.hoverBackground")
                : Color.clear
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// Real marketplace extension row with async image loading
struct RealMarketplaceExtensionRow: View {
    let extensionInfo: MarketplaceExtension
    let onInstall: () -> Void
    @State private var isHovered = false
    @State private var isInstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                // Icon (async loaded or placeholder)
                if let iconURL = extensionInfo.iconURL,
                   let url = URL(string: iconURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 32, height: 32)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                                .cornerRadius(4)
                        case .failure:
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)
                                .frame(width: 32, height: 32)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(extensionInfo.displayName)
                        .font(.system(size: 13, weight: .medium))

                    Text(extensionInfo.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // Publisher
                        Text(extensionInfo.publisher)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        // Rating
                        if extensionInfo.rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                Text(extensionInfo.formattedRating)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.orange)
                        }

                        // Downloads
                        Text(extensionInfo.formattedInstallCount)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Install button
                if isInstalling {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 60, height: 24)
                } else {
                    Button(action: {
                        isInstalling = true
                        onInstall()
                        // Reset after 3 seconds (will be replaced with actual install logic)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            isInstalling = false
                        }
                    }) {
                        Text("Install")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.accentColor)
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(
            isHovered
                ? Color.init(id: "list.hoverBackground")
                : Color.clear
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// Legacy marketplace extension row (for sample data)
struct MarketplaceExtensionRow: View {
    let extensionInfo: ExtensionInfo
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                // Icon
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(extensionInfo.name)
                        .font(.system(size: 13, weight: .medium))

                    Text(extensionInfo.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let rating = extensionInfo.rating {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                Text(String(format: "%.1f", rating))
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.orange)
                        }

                        if let downloads = extensionInfo.downloads {
                            Text(formatDownloads(downloads))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                // Install button
                Button(action: {
                    NSLog("Installing \(extensionInfo.name)...")
                }) {
                    Text("Install")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.accentColor)
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(
            isHovered
                ? Color.init(id: "list.hoverBackground")
                : Color.clear
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func formatDownloads(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Data Models

struct ExtensionInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let version: String
    let author: String
    var downloads: Int?
    var rating: Double?
    var isEnabled: Bool
}
