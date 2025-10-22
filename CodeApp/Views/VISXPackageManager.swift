//
//  VISXPackageManager.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

struct VISXPackageManagerView: View {
    @StateObject private var visxService = VISXService.shared
    @State private var showingDownloadSheet = false
    @State private var downloadURL: String = ""
    @State private var installedPackages: [VISXManifest] = []
    @State private var selectedPackage: VISXManifest?
    @State private var showingPackageDetails = false

    var body: some View {
        NavigationView {
            List {
                // Download Progress Section
                if visxService.isDownloading {
                    Section(header: Text("Current Download")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(visxService.currentOperation)
                                .font(.subheadline)

                            ProgressView(value: visxService.downloadProgress)

                            Text("\(Int(visxService.downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.gray)

                            Button("Cancel") {
                                visxService.cancelDownload()
                            }
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Error Section
                if let error = visxService.error {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.subheadline)
                        }
                    }
                }

                // Installed Packages Section
                Section(header: Text("Installed Packages (\(installedPackages.count))")) {
                    if installedPackages.isEmpty {
                        Text("No packages installed")
                            .foregroundColor(.gray)
                            .italic()
                    } else {
                        ForEach(installedPackages, id: \.package.name) { package in
                            PackageRow(package: package)
                                .onTapGesture {
                                    selectedPackage = package
                                    showingPackageDetails = true
                                }
                        }
                    }
                }

                // Actions Section
                Section(header: Text("Actions")) {
                    Button(action: {
                        showingDownloadSheet = true
                    }) {
                        Label("Download from URL", systemImage: "arrow.down.circle")
                    }

                    Button(action: refreshPackages) {
                        Label("Refresh Package List", systemImage: "arrow.clockwise")
                    }
                }

                // Examples Section
                Section(header: Text("Example Packages")) {
                    ExamplePackageRow(
                        name: "WASM Hello World",
                        description: "Simple WASM module example",
                        url: "https://example.com/packages/hello-wasm.visx"
                    )

                    ExamplePackageRow(
                        name: "Node.js Utilities",
                        description: "Common Node.js utilities",
                        url: "https://example.com/packages/node-utils.visx"
                    )
                }
            }
            .navigationTitle("VISX Packages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: refreshPackages) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingDownloadSheet) {
                DownloadPackageSheet(
                    downloadURL: $downloadURL,
                    onDownload: downloadPackage
                )
            }
            .sheet(isPresented: $showingPackageDetails) {
                if let package = selectedPackage {
                    PackageDetailsView(
                        package: package,
                        onUninstall: {
                            uninstallPackage(package)
                        }
                    )
                }
            }
            .onAppear {
                refreshPackages()
            }
        }
    }

    private func refreshPackages() {
        installedPackages = visxService.getInstalledPackages()
    }

    private func downloadPackage() {
        guard let url = URL(string: downloadURL), url.scheme != nil else {
            visxService.error = "Invalid URL"
            return
        }

        showingDownloadSheet = false

        Task {
            do {
                _ = try await visxService.downloadPackage(from: url)
                await MainActor.run {
                    refreshPackages()
                    downloadURL = ""
                }
            } catch {
                await MainActor.run {
                    visxService.error = error.localizedDescription
                }
            }
        }
    }

    private func uninstallPackage(_ package: VISXManifest) {
        do {
            try visxService.uninstallPackage(name: package.package.name)
            refreshPackages()
            showingPackageDetails = false
        } catch {
            visxService.error = error.localizedDescription
        }
    }
}

// MARK: - Package Row

struct PackageRow: View {
    let package: VISXManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: packageIcon)
                    .foregroundColor(packageColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.package.name)
                        .font(.headline)

                    Text("v\(package.package.version) • \(package.package.type)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Text(formatSize(package.stats.total_size))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !package.package.description.isEmpty {
                Text(package.package.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var packageIcon: String {
        switch package.package.type {
        case "wasm": return "cube.box"
        case "node": return "leaf"
        case "javascript": return "curlybraces"
        default: return "shippingbox"
        }
    }

    private var packageColor: Color {
        switch package.package.type {
        case "wasm": return .purple
        case "node": return .green
        case "javascript": return .yellow
        default: return .blue
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Example Package Row

struct ExamplePackageRow: View {
    let name: String
    let description: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)

            Text(description)
                .font(.caption)
                .foregroundColor(.gray)

            Text(url)
                .font(.caption2)
                .foregroundColor(.blue)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Download Sheet

struct DownloadPackageSheet: View {
    @Binding var downloadURL: String
    let onDownload: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Package URL")) {
                    TextField("https://example.com/package.visx", text: $downloadURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }

                Section {
                    Button("Download", action: {
                        onDownload()
                        dismiss()
                    })
                    .disabled(downloadURL.isEmpty)
                }
            }
            .navigationTitle("Download Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Package Details View

struct PackageDetailsView: View {
    let package: VISXManifest
    let onUninstall: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Package Information")) {
                    LabeledRow(label: "Name", value: package.package.name)
                    LabeledRow(label: "Version", value: package.package.version)
                    LabeledRow(label: "Type", value: package.package.type)
                    LabeledRow(label: "Platform", value: package.metadata.platform)

                    if !package.package.description.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(package.package.description)
                                .font(.subheadline)
                        }
                    }
                }

                Section(header: Text("Statistics")) {
                    LabeledRow(label: "Files", value: "\(package.stats.total_files)")
                    LabeledRow(label: "Total Size", value: formatSize(package.stats.total_size))
                    LabeledRow(label: "Installed", value: formatDate(package.created_at))
                }

                if !package.dependencies.isEmpty {
                    Section(header: Text("Dependencies (\(package.dependencies.count))")) {
                        ForEach(Array(package.dependencies.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                Spacer()
                                Text(package.dependencies[key] ?? "")
                                    .foregroundColor(.gray)
                            }
                            .font(.caption)
                        }
                    }
                }

                Section {
                    Button(role: .destructive, action: {
                        onUninstall()
                        dismiss()
                    }) {
                        Label("Uninstall Package", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Package Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return dateString
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

// MARK: - Preview

struct VISXPackageManagerView_Previews: PreviewProvider {
    static var previews: some View {
        VISXPackageManagerView()
    }
}
