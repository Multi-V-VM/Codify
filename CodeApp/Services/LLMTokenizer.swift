//
//  LLMTokenizer.swift
//  Code
//
//  Tokenizer for LLM text processing
//

import Foundation
import NaturalLanguage

/// Simple tokenizer for LLM models
/// For production, use a proper BPE tokenizer like SentencePiece or tiktoken
class LLMTokenizer {

    // Special tokens
    private let bosToken = "<s>"
    private let eosToken = "</s>"
    private let unkToken = "<unk>"
    private let padToken = "<pad>"

    // Token IDs
    let bosTokenId: Int = 1
    let eosTokenId: Int = 2
    let unkTokenId: Int = 0
    let padTokenId: Int = 3

    // Vocabulary
    private var vocab: [String: Int] = [:]
    private var reverseVocab: [Int: String] = [:]

    init() {
        // Initialize with special tokens
        vocab[unkToken] = unkTokenId
        vocab[bosToken] = bosTokenId
        vocab[eosToken] = eosTokenId
        vocab[padToken] = padTokenId

        reverseVocab[unkTokenId] = unkToken
        reverseVocab[bosTokenId] = bosToken
        reverseVocab[eosTokenId] = eosToken
        reverseVocab[padTokenId] = padToken
    }

    /// Load vocabulary from a JSON file
    func loadVocabulary(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let loadedVocab = try JSONDecoder().decode([String: Int].self, from: data)

        // Merge with existing vocab (special tokens take precedence)
        for (token, id) in loadedVocab {
            if vocab[token] == nil {
                vocab[token] = id
                reverseVocab[id] = token
            }
        }
    }

    /// Simple word-level tokenization (fallback)
    /// For production, replace with BPE tokenizer
    func encode(_ text: String, addSpecialTokens: Bool = true) -> [Int] {
        var tokens: [Int] = []

        // Add BOS token
        if addSpecialTokens {
            tokens.append(bosTokenId)
        }

        // Simple word tokenization
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        for word in words {
            // Convert word to lowercase for better matching
            let normalizedWord = word.lowercased()

            if let tokenId = vocab[normalizedWord] {
                tokens.append(tokenId)
            } else if let tokenId = vocab[word] {
                tokens.append(tokenId)
            } else {
                // For unknown words, try to split into characters
                for char in word {
                    let charStr = String(char)
                    if let tokenId = vocab[charStr] {
                        tokens.append(tokenId)
                    } else {
                        tokens.append(unkTokenId)
                    }
                }
            }
        }

        // Add EOS token
        if addSpecialTokens {
            tokens.append(eosTokenId)
        }

        return tokens
    }

    /// Decode token IDs back to text
    func decode(_ tokens: [Int], skipSpecialTokens: Bool = true) -> String {
        var words: [String] = []

        for tokenId in tokens {
            // Skip special tokens if requested
            if skipSpecialTokens && isSpecialToken(tokenId) {
                continue
            }

            if let word = reverseVocab[tokenId] {
                words.append(word)
            }
        }

        return words.joined(separator: " ")
    }

    /// Check if a token ID is a special token
    private func isSpecialToken(_ tokenId: Int) -> Bool {
        return tokenId == bosTokenId ||
               tokenId == eosTokenId ||
               tokenId == unkTokenId ||
               tokenId == padTokenId
    }

    /// Get vocabulary size
    var vocabularySize: Int {
        return vocab.count
    }
}

// MARK: - Llama-style Chat Formatting

extension LLMTokenizer {

    /// Format messages for Llama-style chat models
    func formatChatPrompt(messages: [LLMMessage]) -> String {
        var prompt = ""

        for message in messages {
            switch message.role {
            case .system:
                prompt += "<|system|>\n\(message.content)\n"
            case .user:
                prompt += "<|user|>\n\(message.content)\n"
            case .assistant:
                prompt += "<|assistant|>\n\(message.content)\n"
            }
        }

        // Add assistant prompt for next response
        prompt += "<|assistant|>\n"

        return prompt
    }

    /// Format for DeepSeek-style models
    func formatDeepSeekPrompt(messages: [LLMMessage]) -> String {
        var prompt = ""

        for message in messages {
            switch message.role {
            case .system:
                prompt += "System: \(message.content)\n\n"
            case .user:
                prompt += "User: \(message.content)\n\n"
            case .assistant:
                prompt += "Assistant: \(message.content)\n\n"
            }
        }

        prompt += "Assistant: "

        return prompt
    }
}
