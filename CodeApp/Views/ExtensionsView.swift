//
//  ExtensionsView.swift
//  Code
//
//  Created by Claude on 26/10/2025.
//

import SwiftUI

struct ExtensionsView: View {
    @StateObject private var extractor = VisxExtractor.shared
    @State private var installedExtensions: [ExtensionInfo] = []
    @State private var showingFilePicker = false
    @State private var showingServerBrowser = false
    @State private var serverURL: String = "http://localhost:3000"

    var body: some View {
        NavigationView {
            List {
                // Status Section
                if extractor.isExtracting {
                    Section {
                        VStack(spacing: 12) {
                            ProgressView(value: extractor.progress)
                            Text(extractor.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                // Error Section
                if let error = extractor.error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                // Installation Methods
                Section(header: Text("Install Extension")) {
                    Button(action: { showingServerBrowser = true }) {
                        Label("Browse Server Extensions", systemImage: "cloud.fill")
                    }

                    Button(action: { showingFilePicker = true }) {
                        Label("Install from File", systemImage: "doc.badge.plus")
                    }

                    Button(action: installRustAnalyzer) {
                        Label("Install rust-analyzer", systemImage: "arrow.down.circle")
                    }
                    .disabled(extractor.isExtracting)
                }

                // Installed Extensions
                Section(header: Text("Installed Extensions (\(installedExtensions.count))")) {
                    if installedExtensions.isEmpty {
                        Text("No extensions installed")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(installedExtensions) { ext in
                            ExtensionRow(extension: ext, onDelete: {
                                deleteExtension(ext)
                            })
                        }
                    }
                }

                // Server Settings
                Section(header: Text("Server Settings")) {
                    HStack {
                        Text("Server URL")
                        TextField("http://localhost:3000", text: $serverURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                    }

                    Button(action: testServerConnection) {
                        Label("Test Connection", systemImage: "network")
                    }
                }
            }
            .navigationTitle("Extensions")
            .navigationBarItems(trailing: Button(action: refreshExtensions) {
                Image(systemName: "arrow.clockwise")
            })
            .sheet(isPresented: $showingFilePicker) {
                ExtensionFilePicker(onFileSelected: installFromFile)
            }
            .sheet(isPresented: $showingServerBrowser) {
                ServerExtensionBrowser(serverURL: serverURL, onInstall: installFromServer)
            }
            .onAppear {
                refreshExtensions()
            }
        }
    }

    private func refreshExtensions() {
        installedExtensions = extractor.listInstalledExtensions()
    }

    private func installFromFile(_ fileURL: URL) {
        extractor.installLocalExtension(at: fileURL) { result in
            switch result {
            case .success(let path):
                print("Extension installed at: \(path)")
                refreshExtensions()
            case .failure(let error):
                print("Installation failed: \(error)")
            }
        }
    }

    private func installFromServer(_ url: URL) {
        extractor.installExtension(from: url) { result in
            switch result {
            case .success(let path):
                print("Extension installed at: \(path)")
                refreshExtensions()
            case .failure(let error):
                print("Installation failed: \(error)")
            }
        }
    }

    private func installRustAnalyzer() {
        guard let url = URL(string: "\(serverURL)/api/extensions/rust-analyzer.visx") else {
            return
        }

        extractor.installExtension(from: url) { result in
            switch result {
            case .success(let path):
                print("rust-analyzer installed at: \(path)")
                refreshExtensions()
            case .failure(let error):
                print("Installation failed: \(error)")
            }
        }
    }

    private func deleteExtension(_ ext: ExtensionInfo) {
        do {
            try extractor.removeExtension(ext)
            refreshExtensions()
        } catch {
            print("Failed to remove extension: \(error)")
        }
    }

    private func testServerConnection() {
        guard let url = URL(string: "\(serverURL)/api/extensions") else {
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    extractor.error = "Connection failed: \(error.localizedDescription)"
                } else if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        extractor.statusMessage = "✅ Connected to server"
                    } else {
                        extractor.error = "Server returned status \(httpResponse.statusCode)"
                    }
                }
            }
        }.resume()
    }
}

// MARK: - Extension Row

struct ExtensionRow: View {
    let extension: ExtensionInfo
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(extension.displayName)
                        .font(.headline)

                    Text("\(extension.name) v\(extension.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }

            if !extension.description.isEmpty {
                Text(extension.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - File Picker

struct ExtensionFilePicker: UIViewControllerRepresentable {
    let onFileSelected: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.init(filenameExtension: "visx")!],
            asCopy: true
        )
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFileSelected: onFileSelected)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFileSelected: (URL) -> Void

        init(onFileSelected: @escaping (URL) -> Void) {
            self.onFileSelected = onFileSelected
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onFileSelected(url)
        }
    }
}

// MARK: - Server Browser

struct ServerExtensionBrowser: View {
    let serverURL: String
    let onInstall: (URL) -> Void

    @State private var extensions: [[String: Any]] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                if isLoading {
                    ProgressView("Loading...")
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                }

                ForEach(extensions, id: \.self as! [String: AnyHashable]) { ext in
                    if let filename = ext["filename"] as? String,
                       let size = ext["size"] as? Int {
                        Button(action: {
                            installExtension(filename: filename)
                        }) {
                            VStack(alignment: .leading) {
                                Text(filename)
                                    .font(.headline)
                                Text(formatBytes(size))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Server Extensions")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .onAppear {
                loadExtensions()
            }
        }
    }

    private func loadExtensions() {
        guard let url = URL(string: "\(serverURL)/api/extensions") else {
            return
        }

        isLoading = true
        errorMessage = nil

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false

                if let error = error {
                    errorMessage = error.localizedDescription
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let exts = json["extensions"] as? [[String: Any]] else {
                    errorMessage = "Failed to parse response"
                    return
                }

                extensions = exts
            }
        }.resume()
    }

    private func installExtension(filename: String) {
        guard let url = URL(string: "\(serverURL)/api/extensions/\(filename)") else {
            return
        }

        onInstall(url)
        dismiss()
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Preview

struct ExtensionsView_Previews: PreviewProvider {
    static var previews: some View {
        ExtensionsView()
    }
}
