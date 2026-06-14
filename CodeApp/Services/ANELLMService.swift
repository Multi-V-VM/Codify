//
//  ANELLMService.swift
//  Code
//
//  ANE-accelerated LLM service using GGUF models on Apple Neural Engine
//  Mirrors CoreMLLLMService API for drop-in usage
//

import Combine
import Foundation

class ANELLMService: ObservableObject {
    static let shared = ANELLMService()

    // Published state (mirrors CoreMLLLMService)
    @Published var messages: [LLMMessage] = []
    @Published var isGenerating: Bool = false
    @Published var modelLoaded: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadingProgress: Float = 0
    @Published var loadingStatus: String = ""
    @Published var currentResponse: String = ""
    @Published var error: String?

    // Internal state
    private var loader: GGUFLoader?
    private var compiler: ANEModelCompiler?
    private var engine: ANEInferenceEngine?
    private var tokenizer: GGUFTokenizer?
    private var currentTask: Task<Void, Never>?
    private var conversationHistory: [LLMMessage] = []

    private init() {
        conversationHistory.append(
            LLMMessage(
                role: .system,
                content:
                    "You are a helpful coding assistant. Provide concise, accurate code and explanations."
            ))
    }

    // MARK: - Model Loading

    /// Load the bundled GGUF model from app resources
    func loadBundledModel() async throws {
        guard let url = Resources.ggufModel else {
            await MainActor.run {
                self.error = "Bundled GGUF model not found in app bundle"
            }
            throw NSError(
                domain: "ANELLMService", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Qwen3.5-0.8B-Q8_0.gguf not found in app bundle"
                ])
        }
        try await loadModel(at: url)
    }

    /// Load a GGUF model file
    func loadModel(at url: URL) async throws {
        await MainActor.run {
            isLoading = true
            loadingProgress = 0
            loadingStatus = "Parsing GGUF file..."
            error = nil
            modelLoaded = false
        }

        do {
            // Step 1: Parse GGUF
            let ggufLoader = GGUFLoader(url: url)
            try ggufLoader.load()

            await MainActor.run {
                loadingProgress = 0.05
                loadingStatus =
                    "GGUF parsed: \(ggufLoader.config.architecture) (\(ggufLoader.config.nLayers) layers, dim=\(ggufLoader.config.dim))"
            }

            // Step 2: Initialize tokenizer
            let tok = GGUFTokenizer()
            tok.loadFromGGUF(metadata: ggufLoader.metadata)

            await MainActor.run {
                loadingProgress = 0.1
                loadingStatus = "Tokenizer loaded (vocab: \(tok.vocabSize))"
            }

            // Step 3: Compile ANE kernels
            let comp = ANEModelCompiler(loader: ggufLoader)
            try comp.compile { [weak self] progress, status in
                Task { @MainActor in
                    self?.loadingProgress = 0.1 + progress * 0.85
                    self?.loadingStatus = status
                }
            }

            // Step 4: Initialize inference engine
            let eng = ANEInferenceEngine(compiler: comp)

            await MainActor.run {
                self.loader = ggufLoader
                self.compiler = comp
                self.engine = eng
                self.tokenizer = tok
                self.loadingProgress = 1.0
                self.loadingStatus = "Model ready"
                self.modelLoaded = true
                self.isLoading = false
            }

        } catch {
            await MainActor.run {
                self.error = "Failed to load GGUF model: \(error.localizedDescription)"
                self.isLoading = false
                self.modelLoaded = false
            }
            throw error
        }
    }

    /// Unload the current model
    func unloadModel() {
        compiler?.cleanup()
        loader = nil
        compiler = nil
        engine = nil
        tokenizer = nil
        modelLoaded = false
        loadingProgress = 0
        loadingStatus = ""
    }

    // MARK: - Chat Operations

    /// Send a message and get a streaming response
    @discardableResult
    func sendMessage(_ content: String, includeCode: String? = nil) async -> String {
        await MainActor.run {
            isGenerating = true
            error = nil
            currentResponse = ""
        }

        defer {
            Task { @MainActor in
                isGenerating = false
            }
        }

        // Prepare message
        var messageContent = content
        if let code = includeCode {
            messageContent += "\n\nCode:\n```\n\(code)\n```"
        }

        // Add user message
        let userMessage = LLMMessage(role: .user, content: messageContent)
        await MainActor.run {
            conversationHistory.append(userMessage)
            messages.append(userMessage)
        }

        // Generate response
        let response = await generateResponse()

        // Add assistant message
        let assistantMessage = LLMMessage(role: .assistant, content: response)
        await MainActor.run {
            conversationHistory.append(assistantMessage)
            messages.append(assistantMessage)
        }

        return response
    }

    /// Generate a response using ANE inference
    private func generateResponse() async -> String {
        guard modelLoaded, let engine = engine, let tokenizer = tokenizer else {
            return "No ANE model loaded. Please load a GGUF model first."
        }

        // Encode conversation
        let inputTokens = tokenizer.encodeChat(messages: conversationHistory)

        // Reset engine state for fresh generation
        engine.resetCache()

        // Generate with streaming
        var fullResponse = ""

        let _ = engine.generate(promptTokens: inputTokens, tokenizer: tokenizer) {
            [weak self] tokenId, tokenText in
            fullResponse += tokenText
            Task { @MainActor in
                self?.currentResponse = fullResponse
            }
            return true  // Continue generating
        }

        return fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generation Control

    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil
        Task { @MainActor in
            isGenerating = false
        }
    }

    func updateGenerationParameters(
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        topK: Int? = nil,
        topP: Float? = nil
    ) {
        if let maxTokens = maxTokens { engine?.maxTokens = maxTokens }
        if let temperature = temperature { engine?.temperature = temperature }
        if let topK = topK { engine?.topK = topK }
        if let topP = topP { engine?.topP = topP }
    }

    // MARK: - Conversation Management

    func clearConversation() {
        conversationHistory = [
            LLMMessage(
                role: .system,
                content:
                    "You are a helpful coding assistant. Provide concise, accurate code and explanations."
            )
        ]
        messages = []
        currentResponse = ""
        engine?.resetCache()
    }

    func exportConversation() -> String {
        var markdown = "# ANE LLM Conversation\n\n"
        markdown += "Model: Qwen3.5-0.8B (ANE)\n"
        markdown += "Exported: \(Date())\n\n---\n\n"
        for message in messages {
            let role = message.role.rawValue.capitalized
            markdown += "## \(role)\n\n\(message.content)\n\n---\n\n"
        }
        return markdown
    }

    // MARK: - Model Discovery

    /// Find GGUF models (bundled + Documents directory)
    func discoverGGUFModels() -> [URL] {
        var modelURLs: [URL] = []

        // Bundled model first
        if let bundled = Resources.ggufModel {
            modelURLs.append(bundled)
        }

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first
        {
            let modelsDir = documentsURL.appendingPathComponent("Models")
            if let enumerator = FileManager.default.enumerator(
                at: modelsDir, includingPropertiesForKeys: nil)
            {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "gguf" {
                        modelURLs.append(fileURL)
                    }
                }
            }

            // Also check Documents root
            if let enumerator = FileManager.default.enumerator(
                at: documentsURL, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "gguf" && !modelURLs.contains(fileURL) {
                        modelURLs.append(fileURL)
                    }
                }
            }
        }

        return modelURLs
    }
}
