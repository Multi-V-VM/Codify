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
    private var stateStore: [String: MLFeatureValue] = [:]

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

        // Avoid using non-public KVC fields to query initial states.

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

    /// Quick heuristic to determine if the loaded model looks like a text LLM
    func isLikelyTextModel() -> Bool {
        guard let model = model else { return false }
        let inputs = model.modelDescription.inputDescriptionsByName
        let tokenKeys: [String] = ["input_ids", "inputIds", "token_ids", "tokens", "prompt_ids"]
        if tokenKeys.contains(where: { inputs[$0] != nil }) { return true }
        // If inputs look image-like (4D or named image/pixel), treat as incompatible
        let has4D = inputs.values.contains { $0.multiArrayConstraint?.shape.count ?? 0 >= 4 }
        let imageLike = inputs.keys.contains { $0.lowercased().contains("image") || $0.lowercased().contains("pixel") }
        return !(has4D || imageLike)
    }

    /// Throw if the model appears incompatible with text generation
    func validateModelCompatibility() throws {
        if !isLikelyTextModel() {
            throw InferenceError.incompatibleModel
        }

        // Detect models that require initial MLState caches like keyCache/valueCache.
        if let model = model {
            let inputs = model.modelDescription.inputDescriptionsByName
            let names = inputs.keys.map { $0.lowercased() }
            let requiresKV = names.contains("keycache") || names.contains("valuecache") || names.contains("kvcache")
            if requiresKV {
                // Without a public way to construct MLState, such models can’t be run from a cold start.
                throw InferenceError.requiresInitialState
            }
        }
    }

    /// Clear any accumulated model state (e.g., KV caches)
    func resetState() {
        stateStore.removeAll()
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
                let output = try await model.prediction(from: input)

                // Capture state outputs for next step
                captureState(from: output)

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
                let output = try await model.prediction(from: input)

                // Capture state outputs for next step
                captureState(from: output)

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

        let sequenceLength = tokens.count

        var features: [String: Any] = [:]

        // Get the input descriptions to know what the model expects
        let inputDescriptions = model.modelDescription.inputDescriptionsByName

        // Detect obviously incompatible models (e.g., vision models expecting 4D image inputs)
        let tokenInputCandidates: [String] = ["input_ids", "inputIds", "token_ids", "tokens", "prompt_ids"]
        let hasTokenLikeInput = tokenInputCandidates.contains(where: { inputDescriptions[$0] != nil })
        if !hasTokenLikeInput {
            let has4DInput = inputDescriptions.values.contains { desc in
                guard let c = desc.multiArrayConstraint else { return false }
                return c.shape.count >= 4
            }
            let hasImageLikeName = inputDescriptions.keys.contains { name in
                let n = name.lowercased()
                return n.contains("image") || n.contains("pixel")
            }
            if has4DInput || hasImageLikeName {
                // Surface a clear error so the UI can inform the user
                throw InferenceError.incompatibleModel
            }
        }

        // If the model requires KV caches at step 1 and we have none, surface a clear error
        for (name, desc) in inputDescriptions {
            let lname = name.lowercased()
            let requiresKV = (lname.contains("keycache") || lname.contains("valuecache") || lname.contains("kvcache"))
            if requiresKV {
                // If this input is required and we don't have state yet, we cannot proceed
                let isOptional = (desc as MLFeatureDescription).isOptional
                if !isOptional && stateStore[name] == nil {
                    throw InferenceError.requiresInitialState
                }
            }
        }

        func isCacheLike(_ name: String) -> Bool {
            let lname = name.lowercased()
            // Be explicit about common KV cache names
            return lname.contains("keycache") || lname.contains("valuecache") || lname.contains("cache") || lname.contains("kv") || lname.contains("past") || lname.contains("state")
        }

        // Helper to create an MLMultiArray matching the model's expected shape/dtype
        func makeArray(for key: String, fallbackShape: [NSNumber]) throws -> MLMultiArray {
            let dataType = inputDescriptions[key]?.multiArrayConstraint?.dataType ?? .int32
            // Prefer the model-declared shape only if all dims are positive
            let declaredShape = inputDescriptions[key]?.multiArrayConstraint?.shape
            let useDeclared = declaredShape?.allSatisfy { $0.intValue > 0 } == true
            let shape = useDeclared ? declaredShape! : fallbackShape
            guard let arr = try? MLMultiArray(shape: shape, dataType: dataType) else {
                throw InferenceError.failedToCreateInput
            }
            // Zero-initialize to be safe
            for i in 0..<arr.count { arr[i] = 0 }
            return arr
        }

        // Helper to set values along a detected sequence dimension
        func setSequenceValues(_ array: MLMultiArray, values: [NSNumber]) {
            let dims = array.shape.map { $0.intValue }
            guard !dims.isEmpty else { return }

            // Prefer the last dimension; if it can't fit, find the first that can
            var seqDim = max(0, dims.count - 1)
            if dims[seqDim] < values.count, let idx = dims.firstIndex(where: { $0 >= values.count }) {
                seqDim = idx
            }

            let limit = min(values.count, dims[seqDim])
            for i in 0..<limit {
                var coords = Array(repeating: 0, count: dims.count)
                coords[seqDim] = i
                array[coords.map { NSNumber(value: $0) }] = values[i]
            }
        }

        // Provide state inputs (KV caches, etc.) — only if we have captured states
        for (name, _) in inputDescriptions {
            if let state = stateStore[name], isCacheLike(name) {
                features[name] = state
            }
        }
        // No initial-state seeding; models requiring MLState at step 1 should expose an initializer
        // or optional caches. We rely on captured states for subsequent steps only.

        // Provide token IDs
        if let inputKey = tokenInputCandidates.first(where: { inputDescriptions[$0] != nil }) {
            let fallbackShape: [NSNumber] = [1, NSNumber(value: sequenceLength)]
            let inputIdsArray = try makeArray(for: inputKey, fallbackShape: fallbackShape)
            setSequenceValues(inputIdsArray, values: tokens.map { NSNumber(value: $0) })
            features[inputKey] = inputIdsArray
        }

        // Provide attention/causal masks if requested by model
        if let desc = inputDescriptions["causalMask"], desc.type == .multiArray {
            let maskArray = try makeArray(for: "causalMask", fallbackShape: [1, NSNumber(value: sequenceLength)])
            // For unknown higher-rank mask shapes, safest default is all-ones (attend to all)
            for i in 0..<maskArray.count { maskArray[i] = 1 }
            features["causalMask"] = maskArray
        }

        if let desc = inputDescriptions["attention_mask"], desc.type == .multiArray {
            let maskArray = try makeArray(for: "attention_mask", fallbackShape: [1, NSNumber(value: sequenceLength)])
            for i in 0..<maskArray.count { maskArray[i] = 1 }
            features["attention_mask"] = maskArray
        }

        // Provide position IDs if required
        if let desc = inputDescriptions["position_ids"], desc.type == .multiArray {
            let posArray = try makeArray(for: "position_ids", fallbackShape: [1, NSNumber(value: sequenceLength)])
            setSequenceValues(posArray, values: (0..<sequenceLength).map { NSNumber(value: $0) })
            features["position_ids"] = posArray
        }

        // Validate that we've provided all required inputs
        let providedInputs = Set(features.keys)
        let requiredInputs = Set(inputDescriptions.keys)
        let missingInputs = requiredInputs.subtracting(providedInputs)

        if !missingInputs.isEmpty {
            print("Warning: Missing inputs for model: \(missingInputs)")
            print("Attempting to create default values for missing inputs...")

            for inputName in missingInputs {
                guard let inputDescription = inputDescriptions[inputName] else { continue }

                // Skip cache/state-like inputs entirely — models typically handle initial state when omitted
                if isCacheLike(inputName) { continue }

                // Only auto-create defaults for multiArray-typed inputs
                if inputDescription.type == .multiArray, let multiArrayConstraint = inputDescription.multiArrayConstraint {
                    let shape = multiArrayConstraint.shape
                    let dtype = multiArrayConstraint.dataType
                    print("Creating default input for \(inputName) with shape: \(shape)")

                    if let defaultArray = try? MLMultiArray(shape: shape, dataType: dtype) {
                        // Sensible defaults: masks -> 1s, caches -> 0s, others -> 0s
                        let isMask = inputName.lowercased().contains("mask")
                        let fillValue: NSNumber = isMask ? 1 : 0
                        for i in 0..<defaultArray.count { defaultArray[i] = fillValue }
                        features[inputName] = defaultArray
                    }
                }
            }
        }

        // Final safety: ensure we never include cache-like keys unless sourced from stateStore
        for key in Array(features.keys) {
            if isCacheLike(key) && stateStore[key] == nil {
                features.removeValue(forKey: key)
            }
        }

        print("Preparing features for prediction: \(Array(features.keys))")

        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    /// Capture MLState outputs emitted by the model so we can feed them back in subsequent steps
    private func captureState(from output: MLFeatureProvider) {
        guard let model = model else { return }
        let inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        for name in output.featureNames {
            guard inputNames.contains(name), let value = output.featureValue(for: name) else { continue }
            let lname = name.lowercased()
            let looksLikeCache = lname.contains("cache") || lname.contains("kv") || lname.contains("past") || lname.contains("state")
            if looksLikeCache {
                stateStore[name] = value
            }
        }
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
    case incompatibleModel
    case requiresInitialState

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
        case .incompatibleModel:
            return "The selected Core ML model isn’t compatible with text generation (expects 4D inputs, e.g., images). Please load a text LLM model (.mlpackage/.mlmodelc) with token inputs."
        case .requiresInitialState:
            return "This Core ML model requires MLState cache inputs (e.g., keyCache/valueCache) on the first step. Initial states are not publicly constructible; please use a model that doesn’t require initial caches or provides an initializer/prefill."
        }
    }
}
