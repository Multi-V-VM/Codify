//
//  ExtensionSettingsView.swift
//  Code
//
//  Extension Settings configuration page
//

import SwiftUI

struct ExtensionSettingsView: View {
    @AppStorage("extensionMarketplaceURL") private var marketplaceURL: String = "https://asplos.dev/api/marketplace"
    @AppStorage("extensionAutoUpdate") private var autoUpdate: Bool = false
    @AppStorage("extensionCacheDuration") private var cacheDuration: Int = 24 // hours
    @AppStorage("extensionEnableTelemetry") private var enableTelemetry: Bool = false
    @AppStorage("extensionMaxCacheSize") private var maxCacheSize: Int = 200 // MB

    @State private var showResetAlert: Bool = false
    @State private var showClearCacheAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extension Settings")
                        .font(.system(size: 24, weight: .bold))

                    Text("Configure extension marketplace and behavior")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)

                Divider()

                // Marketplace Settings
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Marketplace", icon: "square.grid.2x2")

                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow(
                            title: "Marketplace URL",
                            description: "API endpoint for extension marketplace"
                        ) {
                            TextField("URL", text: $marketplaceURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        HStack(spacing: 8) {
                            Button(action: {
                                marketplaceURL = "https://asplos.dev/api/marketplace"
                            }) {
                                Text("Use asplos.dev")
                                    .font(.system(size: 11))
                            }

                            Button(action: {
                                marketplaceURL = "https://marketplace.visualstudio.com/_apis/public/gallery"
                            }) {
                                Text("Use Microsoft")
                                    .font(.system(size: 11))
                            }
                        }
                        .padding(.leading, 4)
                    }
                }

                Divider()

                // Update Settings
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Updates", icon: "arrow.down.circle")

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $autoUpdate) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto Update Extensions")
                                    .font(.system(size: 13))
                                Text("Automatically check and install extension updates")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                Divider()

                // Cache Settings
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Cache", icon: "doc.on.doc")

                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow(
                            title: "Cache Duration",
                            description: "How long to keep cached marketplace data (hours)"
                        ) {
                            HStack {
                                Slider(value: Binding(
                                    get: { Double(cacheDuration) },
                                    set: { cacheDuration = Int($0) }
                                ), in: 1...168, step: 1)

                                Text("\(cacheDuration)h")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 50, alignment: .trailing)
                            }
                        }

                        SettingRow(
                            title: "Max Cache Size",
                            description: "Maximum disk space for extension cache (MB)"
                        ) {
                            HStack {
                                Slider(value: Binding(
                                    get: { Double(maxCacheSize) },
                                    set: { maxCacheSize = Int($0) }
                                ), in: 50...1000, step: 50)

                                Text("\(maxCacheSize)MB")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }

                        Button(action: {
                            showClearCacheAlert = true
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("Clear Cache")
                                    .font(.system(size: 13))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .alert("Clear Cache", isPresented: $showClearCacheAlert) {
                            Button("Clear", role: .destructive) {
                                clearCache()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will clear all cached marketplace data. Extensions will be re-downloaded when needed.")
                        }
                    }
                }

                Divider()

                // Privacy Settings
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Privacy", icon: "hand.raised")

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $enableTelemetry) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Telemetry")
                                    .font(.system(size: 13))
                                Text("Send anonymous usage data to improve extensions")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                Divider()

                // Advanced Settings
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Advanced", icon: "gearshape.2")

                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: {
                            showResetAlert = true
                        }) {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12))
                                Text("Reset to Defaults")
                                    .font(.system(size: 13))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .alert("Reset Settings", isPresented: $showResetAlert) {
                            Button("Reset", role: .destructive) {
                                resetToDefaults()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will reset all extension settings to their default values.")
                        }

                        SettingRow(
                            title: "Extensions Directory",
                            description: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("Extensions").path
                        ) {
                            Button(action: {
                                openExtensionsDirectory()
                            }) {
                                HStack {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                    Text("Open")
                                        .font(.system(size: 13))
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.init(id: "sideBar.background"))
    }

    // MARK: - Actions

    private func resetToDefaults() {
        marketplaceURL = "https://asplos.dev/api/marketplace"
        autoUpdate = false
        cacheDuration = 24
        enableTelemetry = false
        maxCacheSize = 200
        NSLog("✅ Extension settings reset to defaults")
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        NSLog("✅ Extension cache cleared")
    }

    private func openExtensionsDirectory() {
        let extensionsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Extensions")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)

        #if os(macOS)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: extensionsDir.path)
        #endif

        NSLog("📂 Opening extensions directory: \(extensionsDir.path)")
    }
}

// MARK: - Supporting Views

struct SectionTitle: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
    }
}

struct SettingRow<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            content
        }
    }
}

// MARK: - Preview

struct ExtensionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ExtensionSettingsView()
    }
}
