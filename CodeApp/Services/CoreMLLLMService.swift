//
//  CoreMLLLMService.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import Foundation
import CoreML
import Combine

/// Message for LLM conversation
struct LLMMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Core ML LLM Service
/// This service manages LLM inference using Core ML models
class CoreMLLLMService: ObservableObject {
    static let shared = CoreMLLLMService()

    @Published var messages: [LLMMessage] = []
    @Published var isGenerating: Bool = false
    @Published var modelLoaded: Bool = false
    @Published var error: String?
    @Published var currentResponse: String = ""

    private var model: MLModel?
    private var conversationHistory: [LLMMessage] = []
    private var tokenizer: LLMTokenizer
    private var inferenceEngine: CoreMLInferenceEngine?
    private var currentTask: Task<Void, Never>?

    private init() {
        // Initialize tokenizer
        tokenizer = LLMTokenizer()

        // Initialize with system message
        conversationHistory.append(LLMMessage(
            role: .system,
            content: "You are a helpful coding assistant integrated into a code editor. Provide concise, accurate, and helpful responses."
        ))
    }

    // MARK: - Model Loading

    /// Load a Core ML model from the app bundle or documents directory
    func loadModel(named modelName: String) async throws {
        await MainActor.run {
            isGenerating = true
            error = nil
        }

        defer {
            Task { @MainActor in
                isGenerating = false
            }
        }

        // Try to load the model
        // Note: For a real implementation, you would need to:
        // 1. Download or bundle a Core ML LLM model (e.g., from Hugging Face)
        // 2. Convert it to Core ML format if needed
        // 3. Load it here

        // For now, we'll simulate model loading
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        await MainActor.run {
            modelLoaded = true
            error = nil
        }
    }

    /// Load model from a custom URL
    func loadModel(at url: URL) async throws {
        do {
            await MainActor.run {
                isGenerating = true
                error = nil
            }

            // Load tokenizer vocabulary if available
            let vocabURL = url.deletingLastPathComponent().appendingPathComponent("vocab.json")
            if FileManager.default.fileExists(atPath: vocabURL.path) {
                try? tokenizer.loadVocabulary(from: vocabURL)
            }

            // Initialize inference engine
            inferenceEngine = CoreMLInferenceEngine(tokenizer: tokenizer)

            // Load the model
            try inferenceEngine?.loadModel(from: url)

            await MainActor.run {
                modelLoaded = true
                isGenerating = false
                error = nil
            }
        } catch {
            await MainActor.run {
                self.error = "Failed to load model: \(error.localizedDescription)"
                modelLoaded = false
                isGenerating = false
            }
            throw error
        }
    }

    // MARK: - Chat Operations

    /// Send a message and get a response
    func sendMessage(_ content: String, includeCode: String? = nil) async -> String {
        await MainActor.run {
            isGenerating = true
            error = nil
        }

        defer {
            Task { @MainActor in
                isGenerating = false
            }
        }

        // Prepare the message content
        var messageContent = content
        if let code = includeCode {
            messageContent += "\n\nCode:\n```\n\(code)\n```"
        }

        // Add user message to history
        let userMessage = LLMMessage(role: .user, content: messageContent)
        await MainActor.run {
            conversationHistory.append(userMessage)
            messages.append(userMessage)
        }

        // Generate response
        let response = await generateResponse(for: conversationHistory)

        // Add assistant message to history
        let assistantMessage = LLMMessage(role: .assistant, content: response)
        await MainActor.run {
            conversationHistory.append(assistantMessage)
            messages.append(assistantMessage)
        }

        return response
    }

    /// Generate a response using the loaded model
    private func generateResponse(for conversation: [LLMMessage]) async -> String {
        // If no model is loaded, use a fallback
        guard modelLoaded, let engine = inferenceEngine else {
            return await generateFallbackResponse(for: conversation)
        }

        do {
            // Format the conversation into a prompt
            let prompt = tokenizer.formatDeepSeekPrompt(messages: conversation)

            // Tokenize the prompt
            let inputTokens = tokenizer.encode(prompt, addSpecialTokens: true)

            // Reset current response
            await MainActor.run {
                currentResponse = ""
            }

            // Generate with streaming
            let outputTokens = try await engine.generateStreaming(
                inputTokens: inputTokens,
                stopTokens: [tokenizer.eosTokenId],
                onToken: { [weak self] tokenId, tokenText in
                    guard let self = self else { return }
                    self.currentResponse += tokenText
                }
            )

            // Decode the full response
            let response = tokenizer.decode(outputTokens, skipSpecialTokens: true)

            return response.trimmingCharacters(in: .whitespacesAndNewlines)

        } catch {
            await MainActor.run {
                self.error = "Inference failed: \(error.localizedDescription)"
            }
            return "I encountered an error while generating a response. Please try again."
        }
    }

    /// Generate a simulated response (for demo purposes)
    private func generateSimulatedResponse(for conversation: [LLMMessage]) async -> String {
        // Simulate thinking time
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        guard let lastMessage = conversation.last(where: { $0.role == .user }) else {
            return "I'm sorry, I didn't receive a message."
        }

        let content = lastMessage.content.lowercased()

        // Simple pattern matching for demo
        if content.contains("explain") && content.contains("```") {
            return "I'd be happy to explain this code! This appears to be a code snippet. To provide a detailed explanation, I would analyze:\n\n1. The overall purpose and functionality\n2. Key algorithms or patterns used\n3. Potential improvements or best practices\n\nNote: This is a demo response. Connect a real Core ML LLM model for actual code analysis."
        }

        if content.contains("generate") || content.contains("write") {
            return "I can help you generate code! However, this is currently a demo response. To generate actual code, you'll need to:\n\n1. Load a Core ML LLM model (e.g., CodeLlama, StarCoder)\n2. Configure the model for code generation\n3. Provide specific requirements\n\nWould you like help setting up a real LLM model?"
        }

        if content.contains("fix") || content.contains("error") || content.contains("bug") {
            return "I'm analyzing the code for potential issues. Common things to check:\n\n1. Syntax errors\n2. Type mismatches\n3. Null pointer dereferences\n4. Logic errors\n\nNote: Load a real Core ML model for actual code analysis and debugging assistance."
        }

        return "I'm a demo AI assistant. To use real AI capabilities:\n\n1. **Load a Core ML Model**: Use the Settings to load a compatible LLM model\n2. **Supported Models**: Look for Core ML versions of CodeLlama, GPT-style models, or other LLMs\n3. **Model Sources**: Models can be downloaded from Hugging Face or the Apple Model Gallery\n\nHow can I help you with your code today?"
    }

    /// Fallback response when no model is loaded
    private func generateFallbackResponse(for conversation: [LLMMessage]) async -> String {
        return """
        ⚠️ No AI model is currently loaded.

        To use AI features:
        1. Download a Core ML compatible LLM model
        2. Load it in Settings > AI Model
        3. Restart the chat

        Recommended models:
        - CodeLlama (Core ML version)
        - Mistral (Core ML version)
        - Llama 2 (Core ML version)

        Visit the Apple ML Gallery or Hugging Face for compatible models.
        """
    }

    /// Explain code using AI
    func explainCode(_ code: String) async -> String {
        return await sendMessage("Please explain this code:", includeCode: code)
    }

    /// Generate code based on description
    func generateCode(description: String) async -> String {
        return await sendMessage("Generate code for: \(description)")
    }

    /// Fix or improve code
    func improveCode(_ code: String, instruction: String) async -> String {
        return await sendMessage(instruction, includeCode: code)
    }

    // MARK: - Generation Control

    /// Cancel current generation
    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil

        Task { @MainActor in
            isGenerating = false
            currentResponse = ""
        }
    }

    /// Update generation parameters
    func updateGenerationParameters(
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        topK: Int? = nil,
        topP: Float? = nil
    ) {
        if let maxTokens = maxTokens {
            inferenceEngine?.maxTokens = maxTokens
        }
        if let temperature = temperature {
            inferenceEngine?.temperature = temperature
        }
        if let topK = topK {
            inferenceEngine?.topK = topK
        }
        if let topP = topP {
            inferenceEngine?.topP = topP
        }
    }

    // MARK: - Conversation Management

    /// Clear conversation history
    func clearConversation() {
        conversationHistory = [
            LLMMessage(
                role: .system,
                content: "You are a helpful coding assistant integrated into a code editor. Provide concise, accurate, and helpful responses."
            )
        ]
        messages = []
        currentResponse = ""
    }

    /// Export conversation as markdown
    func exportConversation() -> String {
        var markdown = "# Code Assistant Conversation\n\n"
        markdown += "Exported: \(Date())\n\n---\n\n"

        for message in messages {
            let role = message.role.rawValue.capitalized
            markdown += "## \(role)\n\n"
            markdown += "\(message.content)\n\n"
            markdown += "---\n\n"
        }

        return markdown
    }
}

// MARK: - Model Discovery

extension CoreMLLLMService {

    /// Discover available models in the app bundle and documents directory
    func discoverModels() -> [URL] {
        var modelURLs: [URL] = []

        // Check app bundle
        if let bundleModels = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) {
            modelURLs.append(contentsOf: bundleModels)
        }

        // Check documents directory
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelsDir = documentsURL.appendingPathComponent("Models")
            if let enumerator = FileManager.default.enumerator(at: modelsDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "mlmodelc" || fileURL.pathExtension == "mlpackage" {
                        modelURLs.append(fileURL)
                    }
                }
            }
        }

        return modelURLs
    }
}
