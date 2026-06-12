//
//  GGUFTokenizer.swift
//  Code
//
//  BPE tokenizer extracted from GGUF metadata (tokenizer.ggml.*)
//  Supports Qwen chat template (<|im_start|>, <|im_end|>)
//

import Foundation

class GGUFTokenizer {

    // Vocabulary
    private var tokens: [String] = []           // id → token string
    private var scores: [Float] = []            // id → merge score
    private var tokenTypes: [Int] = []           // id → GGML token type
    private var tokenToId: [String: Int] = [:]  // token → id
    private var merges: [(String, String)] = []  // BPE merge pairs
    private var tokenizerModel: String = ""
    private var usesByteLevelDecoding = true

    // Special tokens
    private(set) var bosTokenId: Int = -1
    private(set) var eosTokenId: Int = -1
    private(set) var padTokenId: Int = -1
    private(set) var unknownTokenId: Int = 0

    // Qwen special tokens
    private var imStartId: Int = -1
    private var imEndId: Int = -1
    private var nlTokenId: Int = -1

    private(set) var vocabSize: Int = 0

    // GPT-2 byte↔unicode mapping for byte-level BPE
    private var unicodeToByte: [Character: UInt8] = [:]
    private var byteToUnicode: [UInt8: Character] = [:]

    // Streaming byte buffer for incomplete UTF-8 sequences
    private var pendingBytes: [UInt8] = []

    // MARK: - GPT-2 Byte-Level BPE Mapping

    private func buildByteUnicodeMapping() {
        // GPT-2 byte_encoder: maps each byte to a visible Unicode character
        // Bytes in "printable" ranges map to themselves as Unicode codepoints
        // Other bytes map to codepoints starting at U+0100
        var bs: [Int] = []
        bs.append(contentsOf: Array(33...126))   // ! to ~
        bs.append(contentsOf: Array(161...172))  // ¡ to ¬
        bs.append(contentsOf: Array(174...255))  // ® to ÿ

        var cs = bs.map { $0 }
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }

        for i in 0..<256 {
            let byte = UInt8(bs[i])
            let ch = Character(Unicode.Scalar(cs[i])!)
            byteToUnicode[byte] = ch
            unicodeToByte[ch] = byte
        }
    }

    // MARK: - Loading from GGUF Metadata

    func loadFromGGUF(metadata: [String: Any]) {
        buildByteUnicodeMapping()
        tokenizerModel = (metadata["tokenizer.ggml.model"] as? String)?.lowercased() ?? ""
        usesByteLevelDecoding = tokenizerModel.contains("gpt2") || tokenizerModel.contains("bpe")
        if tokenizerModel.contains("llama") || tokenizerModel.contains("spm") || tokenizerModel.contains("unigram") {
            usesByteLevelDecoding = false
        }
        // Extract token list
        if let tokenList = metadata["tokenizer.ggml.tokens"] as? [Any] {
            tokens = tokenList.compactMap { $0 as? String }
            vocabSize = tokens.count
            for (i, tok) in tokens.enumerated() {
                tokenToId[tok] = i
            }
        }

        // Extract scores (for merge priority)
        if let scoreList = metadata["tokenizer.ggml.scores"] as? [Any] {
            scores = scoreList.compactMap {
                if let f = $0 as? Float { return f }
                if let d = $0 as? Double { return Float(d) }
                return 0
            }
        }

        if let typeList = metadata["tokenizer.ggml.token_type"] as? [Any] {
            tokenTypes = typeList.map { intValue($0) ?? 1 }
        }

        // Extract merge pairs
        if let mergeList = metadata["tokenizer.ggml.merges"] as? [Any] {
            merges = mergeList.compactMap { item -> (String, String)? in
                guard let str = item as? String else { return nil }
                let parts = str.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
        }
        if !merges.isEmpty && tokenizerModel.isEmpty {
            usesByteLevelDecoding = true
        }

        // Special token IDs
        if let v = metadata["tokenizer.ggml.bos_token_id"] {
            bosTokenId = intValue(v) ?? -1
        }
        if let v = metadata["tokenizer.ggml.eos_token_id"] {
            eosTokenId = intValue(v) ?? -1
        }
        if let v = metadata["tokenizer.ggml.padding_token_id"] {
            padTokenId = intValue(v) ?? -1
        }
        if let v = metadata["tokenizer.ggml.unknown_token_id"] {
            unknownTokenId = intValue(v) ?? 0
        }

        // Find Qwen special tokens
        imStartId = tokenToId["<|im_start|>"] ?? -1
        imEndId = tokenToId["<|im_end|>"] ?? -1
        nlTokenId = tokenToId["\n"] ?? -1
    }

    // MARK: - BPE Encoding

    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }

        // Convert text to initial byte-level tokens
        var symbols = textToInitialTokens(text)

        // Apply BPE merges
        applyBPEMerges(&symbols)

        return symbols
    }

    /// Encode with Qwen chat template
    func encodeChat(messages: [LLMMessage], addGeneration: Bool = true) -> [Int] {
        var tokens: [Int] = []

        for message in messages {
            // <|im_start|>role\ncontent<|im_end|>\n
            if imStartId >= 0 { tokens.append(imStartId) }

            let roleStr = message.role.rawValue
            tokens.append(contentsOf: encode(roleStr))
            if nlTokenId >= 0 { tokens.append(nlTokenId) }
            else { tokens.append(contentsOf: encode("\n")) }

            tokens.append(contentsOf: encode(message.content))

            if imEndId >= 0 { tokens.append(imEndId) }
            if nlTokenId >= 0 { tokens.append(nlTokenId) }
            else { tokens.append(contentsOf: encode("\n")) }
        }

        // Add generation prompt
        if addGeneration {
            if imStartId >= 0 { tokens.append(imStartId) }
            tokens.append(contentsOf: encode("assistant"))
            if nlTokenId >= 0 { tokens.append(nlTokenId) }
            else { tokens.append(contentsOf: encode("\n")) }
        }

        return tokens
    }

    // MARK: - Decoding

    func decode(_ ids: [Int], skipSpecial: Bool = true) -> String {
        if usesByteLevelDecoding {
            var allBytes: [UInt8] = []
            for id in ids {
                guard id >= 0, id < tokens.count else { continue }
                if skipSpecial && !isTextToken(id) { continue }
                allBytes.append(contentsOf: tokenToBytes(tokens[id]))
            }
            return String(bytes: allBytes, encoding: .utf8)
                ?? String(allBytes.map { Character(Unicode.Scalar($0)) })
        }

        return ids.compactMap { id in
            guard id >= 0, id < tokens.count else { return nil }
            if skipSpecial && !isTextToken(id) { return nil }
            return normalizedTextPiece(tokens[id])
        }.joined()
    }

    /// Decode a single token for streaming. Accumulates bytes internally
    /// and returns valid UTF-8 text when complete sequences are available.
    func decodeOne(_ id: Int) -> String {
        guard id >= 0, id < tokens.count else { return "" }
        guard isTextToken(id) else { return "" }

        if !usesByteLevelDecoding {
            return normalizedTextPiece(tokens[id])
        }

        pendingBytes.append(contentsOf: tokenToBytes(tokens[id]))

        // Try to decode as much valid UTF-8 as possible
        var result = ""
        var i = 0
        while i < pendingBytes.count {
            let byte = pendingBytes[i]
            let seqLen: Int
            if byte & 0x80 == 0 { seqLen = 1 }
            else if byte & 0xE0 == 0xC0 { seqLen = 2 }
            else if byte & 0xF0 == 0xE0 { seqLen = 3 }
            else if byte & 0xF8 == 0xF0 { seqLen = 4 }
            else { i += 1; continue }  // invalid leading byte, skip

            if i + seqLen <= pendingBytes.count {
                let slice = Array(pendingBytes[i..<(i + seqLen)])
                if let s = String(bytes: slice, encoding: .utf8) {
                    result += s
                    i += seqLen
                } else {
                    i += 1  // skip invalid
                }
            } else {
                break  // incomplete sequence, keep in buffer
            }
        }
        pendingBytes = Array(pendingBytes[i...])
        return result
    }

    /// Reset the streaming byte buffer (call when starting a new generation)
    func resetDecodeBuffer() {
        pendingBytes = []
    }

    func isEOS(_ id: Int) -> Bool {
        return id == eosTokenId || id == imEndId
    }

    func isSpecialToken(_ id: Int) -> Bool {
        return id == bosTokenId || id == eosTokenId || id == padTokenId
            || id == imStartId || id == imEndId
    }

    func isTextToken(_ id: Int) -> Bool {
        if isSpecialToken(id) { return false }
        guard id >= 0, id < tokens.count else { return false }

        if id < tokenTypes.count {
            switch tokenTypes[id] {
            case 2, 3, 5: // unknown, control, unused
                return false
            default:
                break
            }
        }

        let token = tokens[id]
        if token.hasPrefix("<|") && token.hasSuffix("|>") { return false }
        return true
    }

    private func normalizedTextPiece(_ token: String) -> String {
        token
            .replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: "Ġ", with: " ")
            .replacingOccurrences(of: "Ċ", with: "\n")
    }

    // MARK: - Private BPE Implementation

    private func textToInitialTokens(_ text: String) -> [Int] {
        let bytes = Array(text.utf8)

        // Convert raw bytes to GPT-2 unicode characters for vocab lookup
        let encoded: [Character] = bytes.map { b in
            byteToUnicode[b] ?? Character(Unicode.Scalar(b))
        }
        let encodedStr = String(encoded)

        var result: [Int] = []
        let chars = Array(encodedStr)

        var i = 0
        while i < chars.count {
            var bestLen = 0
            var bestId = unknownTokenId

            // Try longest match first (up to 32 chars)
            let maxLen = min(32, chars.count - i)
            for len in stride(from: maxLen, through: 1, by: -1) {
                let sub = String(chars[i..<(i + len)])
                if let id = tokenToId[sub] {
                    bestLen = len
                    bestId = id
                    break
                }
            }

            if bestLen > 0 {
                result.append(bestId)
                i += bestLen
            } else {
                // Single byte fallback using hex escape
                if let b = unicodeToByte[chars[i]] {
                    let byteStr = String(format: "<0x%02X>", b)
                    if let id = tokenToId[byteStr] {
                        result.append(id)
                    } else {
                        result.append(unknownTokenId)
                    }
                } else {
                    result.append(unknownTokenId)
                }
                i += 1
            }
        }

        return result
    }

    private func applyBPEMerges(_ symbols: inout [Int]) {
        guard !merges.isEmpty else { return }

        // Build merge priority lookup
        var mergePriority: [String: Int] = [:]
        for (i, merge) in merges.enumerated() {
            let key = merge.0 + " " + merge.1
            mergePriority[key] = i
        }

        // Iteratively apply best merge
        while symbols.count > 1 {
            var bestIdx = -1
            var bestPriority = Int.max
            var bestMergedId = -1

            for i in 0..<(symbols.count - 1) {
                let left = symbols[i] < tokens.count ? tokens[symbols[i]] : ""
                let right = symbols[i + 1] < tokens.count ? tokens[symbols[i + 1]] : ""
                let key = left + " " + right
                if let priority = mergePriority[key], priority < bestPriority {
                    let merged = left + right
                    if let mergedId = tokenToId[merged] {
                        bestIdx = i
                        bestPriority = priority
                        bestMergedId = mergedId
                    }
                }
            }

            if bestIdx < 0 { break }

            symbols[bestIdx] = bestMergedId
            symbols.remove(at: bestIdx + 1)
        }
    }

    /// Convert a token string to raw bytes using GPT-2 byte mapping
    private func tokenToBytes(_ token: String) -> [UInt8] {
        // Handle hex byte escape: <0xHH>
        if token.hasPrefix("<0x") && token.hasSuffix(">") {
            let hex = String(token.dropFirst(3).dropLast(1))
            if let byte = UInt8(hex, radix: 16) {
                return [byte]
            }
        }

        // Use the GPT-2 byte mapping if available
        if !unicodeToByte.isEmpty {
            var bytes: [UInt8] = []
            for ch in token {
                if let b = unicodeToByte[ch] {
                    bytes.append(b)
                } else {
                    // Character not in mapping, encode as UTF-8 directly
                    bytes.append(contentsOf: String(ch).utf8)
                }
            }
            return bytes
        }

        // Fallback: direct UTF-8
        return Array(token.utf8)
    }

    private func intValue(_ v: Any) -> Int? {
        if let i = v as? UInt32 { return Int(i) }
        if let i = v as? Int32 { return Int(i) }
        if let i = v as? UInt64 { return Int(i) }
        if let i = v as? Int64 { return Int(i) }
        if let i = v as? Int { return i }
        return nil
    }
}

// MARK: - Qwen Chat Template Extension for LLMTokenizer

extension LLMTokenizer {
    /// Format for Qwen-style chat models using ChatML template
    func formatQwenPrompt(messages: [LLMMessage]) -> String {
        var prompt = ""

        for message in messages {
            prompt += "<|im_start|>\(message.role.rawValue)\n"
            prompt += "\(message.content)<|im_end|>\n"
        }

        // Add assistant generation prompt
        prompt += "<|im_start|>assistant\n"

        return prompt
    }
}
