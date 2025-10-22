//
//  ModelSettingsView.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct ModelSettingsView: View {
    @StateObject private var llmService = CoreMLLLMService.shared
    @State private var showingFilePicker = false
    @State private var showingConversionGuide = false
    @State private var isLoading = false
    @State private var statusMessage: String = ""

    var body: some View {
        NavigationView {
            List {
                // Model Status Section
                Section(header: Text("Model Status")) {
                    HStack {
                        Image(systemName: llmService.modelLoaded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(llmService.modelLoaded ? .green : .red)
                        Text(llmService.modelLoaded ? "Model Loaded" : "No Model Loaded")
                        Spacer()
                        if isLoading {
                            ProgressView()
                        }
                    }

                    if let error = llmService.error {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                }

                // Recommended Models Section
                Section(header: Text("Recommended Models")) {
                    ModelRecommendationRow(
                        name: "DeepSeek-R1-Distill-Llama-8B",
                        description: "Latest reasoning model, 8B parameters",
                        size: "~4-8 GB",
                        recommended: true
                    )

                    ModelRecommendationRow(
                        name: "Llama 3.1 8B",
                        description: "Meta's latest model for general tasks",
                        size: "~4-8 GB",
                        recommended: true
                    )

                    ModelRecommendationRow(
                        name: "Phi-3 Mini",
                        description: "Lightweight model from Microsoft",
                        size: "~2-4 GB",
                        recommended: false
                    )

                    ModelRecommendationRow(
                        name: "CodeLlama 7B",
                        description: "Specialized for coding tasks",
                        size: "~4-7 GB",
                        recommended: false
                    )
                }

                // Actions Section
                Section(header: Text("Actions")) {
                    Button(action: {
                        showingFilePicker = true
                    }) {
                        Label("Load Local Model", systemImage: "folder")
                    }

                    Button(action: {
                        showingConversionGuide = true
                    }) {
                        Label("Model Conversion Guide", systemImage: "info.circle")
                    }

                    Button(action: loadDeepSeekModel) {
                        Label("Load DeepSeek R1 (Demo)", systemImage: "arrow.down.circle")
                    }

                    if llmService.modelLoaded {
                        Button(action: unloadModel) {
                            Label("Unload Current Model", systemImage: "xmark.circle")
                        }
                        .foregroundColor(.red)
                    }
                }

                // System Info Section
                Section(header: Text("System Information")) {
                    HStack {
                        Text("Available Models")
                        Spacer()
                        Text("\(llmService.discoverModels().count)")
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Model Location")
                        Spacer()
                        Text("Documents/Models/")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }

                    Button(action: createModelsDirectory) {
                        Label("Create Models Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle("AI Model Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingFilePicker) {
                ModelFilePicker(onModelSelected: handleModelSelection)
            }
            .sheet(isPresented: $showingConversionGuide) {
                ModelConversionGuideView()
            }
        }
    }

    private func loadDeepSeekModel() {
        isLoading = true
        statusMessage = "Preparing DeepSeek R1 model..."

        Task {
            do {
                // This will load the demo/simulated version
                try await llmService.loadModel(named: "DeepSeek-R1-Distill-Llama-8B")

                await MainActor.run {
                    statusMessage = "DeepSeek R1 model ready (demo mode)"
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func unloadModel() {
        llmService.clearConversation()
        statusMessage = "Model unloaded"
    }

    private func handleModelSelection(_ url: URL) {
        isLoading = true
        statusMessage = "Loading model from \(url.lastPathComponent)..."

        Task {
            do {
                try await llmService.loadModel(at: url)

                await MainActor.run {
                    statusMessage = "Model loaded successfully"
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Failed to load: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func createModelsDirectory() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsURL = documentsURL.appendingPathComponent("Models")

        do {
            try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
            statusMessage = "Models folder created at: \(modelsURL.path)"
        } catch {
            statusMessage = "Error creating folder: \(error.localizedDescription)"
        }
    }
}

// MARK: - Model Recommendation Row

struct ModelRecommendationRow: View {
    let name: String
    let description: String
    let size: String
    let recommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.headline)

                if recommended {
                    Text("RECOMMENDED")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.gray)

            Text("Size: \(size)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Model File Picker

struct ModelFilePicker: UIViewControllerRepresentable {
    let onModelSelected: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [
                UTType(filenameExtension: "mlmodelc")!,
                UTType(filenameExtension: "mlpackage")!,
                UTType(filenameExtension: "mlmodel")!
            ],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onModelSelected: onModelSelected)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onModelSelected: (URL) -> Void

        init(onModelSelected: @escaping (URL) -> Void) {
            self.onModelSelected = onModelSelected
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onModelSelected(url)
        }
    }
}

// MARK: - Model Conversion Guide View

struct ModelConversionGuideView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GuideSection(
                        title: "📱 Option 1: Use Pre-Converted Models",
                        content: """
                        The easiest way is to download pre-converted Core ML models:

                        1. Visit Hugging Face: https://huggingface.co
                        2. Search for "coreml" + your model name
                        3. Look for .mlmodelc or .mlpackage files
                        4. Download and import into CodeApp

                        Recommended searches:
                        • "llama coreml"
                        • "phi coreml"
                        • "mistral coreml"
                        """
                    )

                    GuideSection(
                        title: "🔧 Option 2: Convert DeepSeek R1 Yourself",
                        content: """
                        Requirements:
                        • Mac with Python 3.8+
                        • 16GB+ RAM
                        • ~20GB free space

                        Steps:
                        1. Install coremltools:
                           pip install coremltools torch transformers

                        2. Download the conversion script from:
                           https://github.com/apple/ml-stable-diffusion
                           (Look for similar Llama conversion examples)

                        3. Run conversion:
                           python convert_deepseek_to_coreml.py

                        4. The output will be a .mlpackage file
                        """
                    )

                    GuideSection(
                        title: "🚀 Option 3: Use MLX (Apple Silicon Only)",
                        content: """
                        For Mac users with Apple Silicon:

                        1. Install MLX:
                           pip install mlx mlx-lm

                        2. Convert model:
                           python -m mlx_lm.convert \\
                               --hf-path deepseek-ai/DeepSeek-R1-Distill-Llama-8B \\
                               --quantize

                        3. Export to Core ML:
                           python export_to_coreml.py

                        Note: MLX models are optimized for Apple Silicon
                        """
                    )

                    GuideSection(
                        title: "📦 Option 4: Use GGUF Models",
                        content: """
                        GGUF is a popular quantized format for mobile:

                        1. Download GGUF version:
                           https://huggingface.co/unsloth/DeepSeek-R1-Distill-Llama-8B-GGUF

                        2. Choose quantization:
                           • Q4_K_M (4-bit, ~4.5 GB) - Recommended
                           • Q5_K_M (5-bit, ~5.5 GB) - Better quality
                           • Q8_0 (8-bit, ~8 GB) - Best quality

                        3. Use llama.cpp or similar runtime

                        Note: Requires additional integration
                        """
                    )

                    Divider()

                    Text("For more detailed instructions, see the conversion script at:")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Button(action: {
                        if let url = URL(string: "https://machinelearning.apple.com/research/core-ml-on-device-llama") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Text("Apple's Official Llama Conversion Guide")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding()
            }
            .navigationTitle("Model Conversion")
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
}

struct GuideSection: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            Text(content)
                .font(.body)
                .foregroundColor(.secondary)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
        }
    }
}

// MARK: - Preview

struct ModelSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ModelSettingsView()
    }
}
