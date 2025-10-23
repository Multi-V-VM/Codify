//
//  CoreMLInference.swift
//  Code
//
//  Core ML LLM Inference Engine
//

import Foundation
import CoreML

/// Core ML LLM Inference Engine
class CoreMLInferenceEngine {

    private var model: MLModel?
    private let tokenizer: LLMTokenizer

    // Generation parameters
    var maxTokens: Int = 512
    var temperature: Float = 0.7
    var topK: Int = 40
    var topP: Float = 0.9

    init(tokenizer: LLMTokenizer) {
        self.tokenizer = tokenizer
    }

    // MARK: - Model Management

    /// Load Core ML model from URL
    /// Handles .mlpackage, .mlmodelc, and .mlmodel files
    func loadModel(from url: URL) throws {
        // Use the CoreMLModelHandler to properly load the model
        // This handles .mlpackage bundles correctly
        let loadedModel = try CoreMLModelHandler.loadModel(from: url)
        model = loadedModel

        // Log model input requirements for debugging
        print("Model loaded successfully")
        print("Required inputs:")
        for (name, description) in loadedModel.modelDescription.inputDescriptionsByName {
            print("  - \(name): \(description.type)")
        }
        print("Output descriptions:")
        for (name, description) in loadedModel.modelDescription.outputDescriptionsByName {
            print("  - \(name): \(description.type)")
        }
    }

    /// Unload the model
    func unloadModel() {
        model = nil
    }

    // MARK: - Inference

    /// Generate text given input tokens
    func generate(inputTokens: [Int], stopTokens: [Int] = []) async throws -> [Int] {
        guard let model = model else {
            throw InferenceError.modelNotLoaded
        }

        var generatedTokens: [Int] = []
        var currentTokens = inputTokens

        print("Starting generation with \(inputTokens.count) input tokens")

        // Generate tokens one at a time
        for step in 0..<maxTokens {
            do {
                // Prepare input
                let input = try prepareInput(tokens: currentTokens)

                // Run inference
                let output = try model.prediction(from: input)

                // Log output info on first iteration
                if step == 0 {
                    print("Model output features:")
                    for name in output.featureNames {
                        if let feature = output.featureValue(for: name),
                           let array = feature.multiArrayValue {
                            print("  - \(name): shape \(array.shape)")
                        }
                    }
                }

                // Extract logits from output
                guard let logits = extractLogits(from: output) else {
                    throw InferenceError.invalidOutput
                }

                if step == 0 {
                    print("Extracted logits with vocab size: \(logits.count)")
                }

                // Sample next token
                let nextToken = sampleToken(from: logits)

                // Check for stop tokens
                if stopTokens.contains(nextToken) || nextToken == tokenizer.eosTokenId {
                    print("Generation stopped at step \(step) (stop token)")
                    break
                }

                generatedTokens.append(nextToken)
                currentTokens.append(nextToken)

                // Yield to allow cancellation
                try Task.checkCancellation()
            } catch {
                print("Error at generation step \(step): \(error)")
                throw error
            }
        }

        print("Generated \(generatedTokens.count) tokens")
        return generatedTokens
    }

    /// Generate text with streaming callback
    func generateStreaming(
        inputTokens: [Int],
        stopTokens: [Int] = [],
        onToken: @escaping (Int, String) -> Void
    ) async throws -> [Int] {
        guard let model = model else {
            throw InferenceError.modelNotLoaded
        }

        var generatedTokens: [Int] = []
        var currentTokens = inputTokens

        print("Starting streaming generation with \(inputTokens.count) input tokens")

        // Generate tokens one at a time
        for step in 0..<maxTokens {
            do {
                // Prepare input
                let input = try prepareInput(tokens: currentTokens)

                // Run inference
                let output = try model.prediction(from: input)

                // Extract logits
                guard let logits = extractLogits(from: output) else {
                    throw InferenceError.invalidOutput
                }

                // Sample next token
                let nextToken = sampleToken(from: logits)

                // Check for stop tokens
                if stopTokens.contains(nextToken) || nextToken == tokenizer.eosTokenId {
                    print("Streaming generation stopped at step \(step) (stop token)")
                    break
                }

                generatedTokens.append(nextToken)
                currentTokens.append(nextToken)

                // Decode and stream token
                let tokenText = tokenizer.decode([nextToken], skipSpecialTokens: true)
                await MainActor.run {
                    onToken(nextToken, tokenText)
                }

                // Yield to allow cancellation
                try Task.checkCancellation()

                // Small delay to allow UI updates
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            } catch {
                print("Error at streaming step \(step): \(error)")
                throw error
            }
        }

        print("Streaming complete: generated \(generatedTokens.count) tokens")
        return generatedTokens
    }

    // MARK: - Input/Output Processing

    /// Prepare input for Core ML model
    private func prepareInput(tokens: [Int]) throws -> MLFeatureProvider {
        guard let model = model else {
            throw InferenceError.modelNotLoaded
        }

        let batchSize = 1
        let sequenceLength = tokens.count
        let shape = [batchSize, sequenceLength] as [NSNumber]

        var features: [String: Any] = [:]

        // Get the input descriptions to know what the model expects
        let inputDescriptions = model.modelDescription.inputDescriptionsByName

        // Prepare input_ids (token IDs)
        if inputDescriptions.keys.contains("input_ids") || inputDescriptions.keys.contains("inputIds") {
            guard let inputIdsArray = try? MLMultiArray(shape: shape, dataType: .int32) else {
                throw InferenceError.failedToCreateInput
            }

            for (i, token) in tokens.enumerated() {
                inputIdsArray[[0, i] as [NSNumber]] = NSNumber(value: token)
            }

            let inputKey = inputDescriptions.keys.contains("input_ids") ? "input_ids" : "inputIds"
            features[inputKey] = inputIdsArray
        }

        // Prepare causal mask (attention mask)
        if inputDescriptions.keys.contains("causalMask") {
            guard let maskArray = try? MLMultiArray(shape: shape, dataType: .int32) else {
                throw InferenceError.failedToCreateInput
            }

            // Fill with 1s (attend to all tokens)
            for i in 0..<sequenceLength {
                maskArray[[0, i] as [NSNumber]] = NSNumber(value: 1)
            }

            features["causalMask"] = maskArray
        }

        // Prepare attention_mask (alternative name)
        if inputDescriptions.keys.contains("attention_mask") {
            guard let maskArray = try? MLMultiArray(shape: shape, dataType: .int32) else {
                throw InferenceError.failedToCreateInput
            }

            for i in 0..<sequenceLength {
                maskArray[[0, i] as [NSNumber]] = NSNumber(value: 1)
            }

            features["attention_mask"] = maskArray
        }

        // Prepare position_ids if required
        if inputDescriptions.keys.contains("position_ids") {
            guard let positionArray = try? MLMultiArray(shape: shape, dataType: .int32) else {
                throw InferenceError.failedToCreateInput
            }

            for i in 0..<sequenceLength {
                positionArray[[0, i] as [NSNumber]] = NSNumber(value: i)
            }

            features["position_ids"] = positionArray
        }

        // Validate that we've provided all required inputs
        let providedInputs = Set(features.keys)
        let requiredInputs = Set(inputDescriptions.keys)
        let missingInputs = requiredInputs.subtracting(providedInputs)

        if !missingInputs.isEmpty {
            print("Warning: Missing inputs for model: \(missingInputs)")
            print("Attempting to create default values for missing inputs...")

            // Try to create default values for any missing inputs
            for inputName in missingInputs {
                if let inputDescription = inputDescriptions[inputName],
                   let multiArrayConstraint = inputDescription.multiArrayConstraint {

                    // Create a default array based on the shape
                    let inputShape = multiArrayConstraint.shape
                    print("Creating default input for \(inputName) with shape: \(inputShape)")

                    if let defaultArray = try? MLMultiArray(shape: inputShape, dataType: multiArrayConstraint.dataType) {
                        // Fill with zeros or ones depending on the name
                        if inputName.lowercased().contains("mask") {
                            // Masks should be 1s (attend to all)
                            for i in 0..<defaultArray.count {
                                defaultArray[i] = NSNumber(value: 1)
                            }
                        } else if inputName.lowercased().contains("cache") {
                            // Caches start empty (zeros)
                            for i in 0..<defaultArray.count {
                                defaultArray[i] = NSNumber(value: 0)
                            }
                        }

                        features[inputName] = defaultArray
                    }
                }
            }
        }

        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    /// Extract logits from model output
    private func extractLogits(from output: MLFeatureProvider) -> [Float]? {
        // Try common output names
        let possibleNames = ["logits", "output", "output_logits", "predictions", "var_1385", "last_hidden_state"]

        for name in possibleNames {
            if let feature = output.featureValue(for: name),
               let multiArray = feature.multiArrayValue {
                // For LLMs, we often need the last token's logits
                // Shape is typically [batch, sequence, vocab_size]
                let logits = extractLastTokenLogits(from: multiArray)
                if !logits.isEmpty {
                    return logits
                }
            }
        }

        // If standard names don't work, try the first feature
        if let firstFeatureName = output.featureNames.first,
           let feature = output.featureValue(for: firstFeatureName),
           let multiArray = feature.multiArrayValue {
            print("Using output feature: \(firstFeatureName)")
            print("Output shape: \(multiArray.shape)")
            return extractLastTokenLogits(from: multiArray)
        }

        return nil
    }

    /// Extract logits for the last token from a multi-dimensional array
    private func extractLastTokenLogits(from multiArray: MLMultiArray) -> [Float] {
        let shape = multiArray.shape.map { $0.intValue }

        // Handle different output shapes
        if shape.count == 3 {
            // Shape: [batch, sequence, vocab_size]
            // We want the last sequence position
            let batchSize = shape[0]
            let sequenceLength = shape[1]
            let vocabSize = shape[2]

            // Extract logits for the last token
            let lastTokenIndex = sequenceLength - 1
            var logits = [Float](repeating: 0, count: vocabSize)

            for v in 0..<vocabSize {
                let index = [0, lastTokenIndex, v] as [NSNumber]
                logits[v] = multiArray[index].floatValue
            }

            return logits
        } else if shape.count == 2 {
            // Shape: [sequence, vocab_size] or [batch, vocab_size]
            // Assume last dimension is vocab_size
            let vocabSize = shape[1]
            let lastRow = shape[0] - 1

            var logits = [Float](repeating: 0, count: vocabSize)
            for v in 0..<vocabSize {
                let index = [lastRow, v] as [NSNumber]
                logits[v] = multiArray[index].floatValue
            }

            return logits
        } else if shape.count == 1 {
            // Already a 1D array of logits
            return extractFloatArray(from: multiArray)
        }

        // Fallback: flatten the array
        return extractFloatArray(from: multiArray)
    }

    /// Extract float array from MLMultiArray
    private func extractFloatArray(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        var result = [Float](repeating: 0, count: count)

        let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<count {
            result[i] = pointer[i]
        }

        return result
    }

    // MARK: - Sampling

    /// Sample next token from logits
    private func sampleToken(from logits: [Float]) -> Int {
        // Apply temperature
        let scaledLogits = logits.map { $0 / temperature }

        // Apply softmax to get probabilities
        let probs = softmax(scaledLogits)

        // Apply top-k and top-p filtering
        let filteredProbs = applyTopKTopP(probs: probs, topK: topK, topP: topP)

        // Sample from the distribution
        return sampleFromDistribution(probs: filteredProbs)
    }

    /// Softmax function
    private func softmax(_ logits: [Float]) -> [Float] {
        let maxLogit = logits.max() ?? 0
        let expLogits = logits.map { exp($0 - maxLogit) }
        let sumExp = expLogits.reduce(0, +)
        return expLogits.map { $0 / sumExp }
    }

    /// Apply top-k and top-p (nucleus) sampling
    private func applyTopKTopP(probs: [Float], topK: Int, topP: Float) -> [Float] {
        var result = probs

        // Apply top-k: keep only top-k highest probabilities
        if topK > 0 && topK < probs.count {
            let sortedIndices = probs.enumerated()
                .sorted { $0.element > $1.element }
                .prefix(topK)
                .map { $0.offset }

            for i in 0..<result.count {
                if !sortedIndices.contains(i) {
                    result[i] = 0
                }
            }

            // Renormalize
            let sum = result.reduce(0, +)
            if sum > 0 {
                result = result.map { $0 / sum }
            }
        }

        // Apply top-p (nucleus sampling)
        if topP < 1.0 {
            let sortedIndicesAndProbs = probs.enumerated()
                .sorted { $0.element > $1.element }

            var cumulativeProb: Float = 0
            var selectedIndices: Set<Int> = []

            for (index, prob) in sortedIndicesAndProbs {
                cumulativeProb += prob
                selectedIndices.insert(index)

                if cumulativeProb >= topP {
                    break
                }
            }

            for i in 0..<result.count {
                if !selectedIndices.contains(i) {
                    result[i] = 0
                }
            }

            // Renormalize
            let sum = result.reduce(0, +)
            if sum > 0 {
                result = result.map { $0 / sum }
            }
        }

        return result
    }

    /// Sample from probability distribution
    private func sampleFromDistribution(probs: [Float]) -> Int {
        let random = Float.random(in: 0..<1)
        var cumulative: Float = 0

        for (i, prob) in probs.enumerated() {
            cumulative += prob
            if random < cumulative {
                return i
            }
        }

        // Fallback: return highest probability
        return probs.enumerated().max { $0.element < $1.element }?.offset ?? 0
    }
}

// MARK: - Errors

enum InferenceError: LocalizedError {
    case modelNotLoaded
    case invalidOutput
    case failedToCreateInput
    case inferenceTimeout

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is currently loaded. Please load a Core ML model first."
        case .invalidOutput:
            return "Model output format is invalid or unexpected."
        case .failedToCreateInput:
            return "Failed to create model input from tokens."
        case .inferenceTimeout:
            return "Inference timed out. The model may be too large or complex."
        }
    }
}
