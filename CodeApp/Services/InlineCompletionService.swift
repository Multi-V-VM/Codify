//
//  InlineCompletionService.swift
//  Code
//
//  Created by Claude on 23/10/2025.
//

import Foundation
import Combine

/// Service for handling inline code completions (like Copilot)
class InlineCompletionService: ObservableObject {
    static let shared = InlineCompletionService()

    @Published var currentSuggestion: String?
    @Published var isGenerating: Bool = false

    private var llmService: CoreMLLLMService
    private var debounceTimer: Timer?
    private var currentTask: Task<Void, Never>?

    // Configuration
    var debounceDelay: TimeInterval = 0.5  // Wait 0.5s after typing stops
    var maxCompletionLength: Int = 100     // Max tokens to generate
    var temperature: Float = 0.2            // Lower temperature for more deterministic completions
    var enabled: Bool = true

    private init() {
        self.llmService = CoreMLLLMService.shared
    }

    // MARK: - Completion Generation

    /// Request a completion for the current cursor position
    func requestCompletion(
        fileContent: String,
        cursorLine: Int,
        cursorColumn: Int,
        language: String?
    ) {
        guard enabled, llmService.modelLoaded else {
            currentSuggestion = nil
            return
        }

        // Cancel any existing timer
        debounceTimer?.invalidate()

        // Debounce - wait for user to stop typing
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { [weak self] _ in
            self?.generateCompletion(
                fileContent: fileContent,
                cursorLine: cursorLine,
                cursorColumn: cursorColumn,
                language: language
            )
        }
    }

    /// Generate completion immediately (without debounce)
    private func generateCompletion(
        fileContent: String,
        cursorLine: Int,
        cursorColumn: Int,
        language: String?
    ) {
        // Cancel any existing generation
        currentTask?.cancel()

        currentTask = Task {
            await MainActor.run {
                isGenerating = true
                currentSuggestion = nil
            }

            // Build the prompt
            let prompt = buildCompletionPrompt(
                fileContent: fileContent,
                cursorLine: cursorLine,
                cursorColumn: cursorColumn,
                language: language
            )

            // Update generation parameters for completion
            llmService.updateGenerationParameters(
                maxTokens: maxCompletionLength,
                temperature: temperature,
                topK: 40,
                topP: 0.95
            )

            // Generate completion
            let completion = await llmService.sendMessage(prompt)

            // Extract only the completion part (remove any extra text)
            let cleanedCompletion = cleanCompletion(completion)

            await MainActor.run {
                if !Task.isCancelled && !cleanedCompletion.isEmpty {
                    currentSuggestion = cleanedCompletion
                }
                isGenerating = false
            }
        }
    }

    /// Cancel any ongoing completion generation
    func cancelCompletion() {
        debounceTimer?.invalidate()
        currentTask?.cancel()
        currentTask = nil

        Task { @MainActor in
            isGenerating = false
            currentSuggestion = nil
        }
    }

    /// Accept the current suggestion
    func acceptSuggestion() -> String? {
        let suggestion = currentSuggestion
        currentSuggestion = nil
        return suggestion
    }

    // MARK: - Prompt Building

    private func buildCompletionPrompt(
        fileContent: String,
        cursorLine: Int,
        cursorColumn: Int,
        language: String?
    ) -> String {
        let lines = fileContent.components(separatedBy: .newlines)

        // Get context before cursor
        let beforeCursor = lines.prefix(cursorLine).joined(separator: "\n")
        let currentLine = lines.indices.contains(cursorLine) ? lines[cursorLine] : ""
        let currentLineBeforeCursor = String(currentLine.prefix(cursorColumn))

        // Get context after cursor (for better completion)
        let afterCursor = lines.suffix(from: min(cursorLine + 1, lines.count)).prefix(10).joined(separator: "\n")

        let languageHint = language.map { " in \($0)" } ?? ""

        return """
        Complete the following code\(languageHint). Provide ONLY the completion for the current line, no explanations.

        Code before cursor:
        ```
        \(beforeCursor)
        \(currentLineBeforeCursor)
        ```

        Code after cursor:
        ```
        \(afterCursor)
        ```

        Complete the current line (provide only the completion text):
        """
    }

    private func cleanCompletion(_ completion: String) -> String {
        var cleaned = completion.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: .newlines)
            if lines.count > 2 {
                cleaned = lines[1..<lines.count-1].joined(separator: "\n")
            }
        }

        // Take only the first line for inline completion
        if let firstLine = cleaned.components(separatedBy: .newlines).first {
            cleaned = firstLine
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Fill-in-the-Middle Support

extension InlineCompletionService {
    /// Generate completion using Fill-in-the-Middle (FIM) format
    /// This is more efficient for models that support it
    func generateFIMCompletion(
        prefix: String,
        suffix: String,
        language: String?
    ) async -> String? {
        guard enabled, llmService.modelLoaded else {
            return nil
        }

        // FIM format: <fim_prefix>prefix<fim_suffix>suffix<fim_middle>
        let fimPrompt = """
        <fim_prefix>\(prefix)<fim_suffix>\(suffix)<fim_middle>
        """

        llmService.updateGenerationParameters(
            maxTokens: maxCompletionLength,
            temperature: temperature,
            topK: 40,
            topP: 0.95
        )

        let completion = await llmService.sendMessage(fimPrompt)
        return cleanCompletion(completion)
    }
}
