//
//  ANEModelCompiler.swift
//  Code
//
//  Load and organize Qwen3.5 hybrid Mamba-Attention model weights
//  Weights stay as raw Q8_0 pointers to mmap'd data (no full dequantization)
//

import Accelerate
import Foundation

// MARK: - Weight Reference (raw pointer to Q8_0 data in mmap)

struct QWeight {
    let ptr: UnsafeRawPointer
    let outDim: Int  // ne1 (number of rows)
    let inDim: Int  // ne0 (number of columns, fastest changing)

    /// Compute y = W * x using quantized matvec
    func matvec(_ x: [Float]) -> [Float] {
        return GGUFDequantizer.q8_0Matvec(w: ptr, x: x, outDim: outDim, inDim: inDim)
    }
}

// MARK: - Layer Weight Types

struct MambaLayerWeights {
    // Norms (F32, small)
    let attnNorm: [Float]  // [dim]
    let postAttnNorm: [Float]  // [dim]

    // SSM input projection (fused x+B+C)
    let attnQKV: QWeight  // [dim → 3*ssmInner]

    // Gate
    let attnGate: QWeight  // [dim → ssmInner]

    // SSM parameters (F32, small)
    let ssmConv1d: [Float]  // [channels * kernel] stored as [channels, kernel]
    let ssmA: [Float]  // [nGroups]
    let ssmAlpha: QWeight  // [dim → nGroups]
    let ssmBeta: QWeight  // [dim → nGroups]
    let ssmDtBias: [Float]  // [nGroups]
    let ssmNorm: [Float]  // [headDim] (per-group norm)
    let ssmOut: QWeight  // [ssmInner → dim]

    // FFN
    let ffnGate: QWeight  // [dim → hiddenDim]
    let ffnUp: QWeight  // [dim → hiddenDim]
    let ffnDown: QWeight  // [hiddenDim → dim]
}

struct AttentionLayerWeights {
    // Norms (F32, small)
    let attnNorm: [Float]  // [dim]
    let postAttnNorm: [Float]  // [dim]

    // Attention projections
    let attnQ: QWeight  // [dim → dim]
    let attnK: QWeight  // [dim → kvDim]
    let attnV: QWeight  // [dim → kvDim]
    let attnOutput: QWeight  // [dim → dim]

    // Per-head norms (F32, small)
    let attnQNorm: [Float]  // [headDim]
    let attnKNorm: [Float]  // [headDim]

    // FFN
    let ffnGate: QWeight  // [dim → hiddenDim]
    let ffnUp: QWeight  // [dim → hiddenDim]
    let ffnDown: QWeight  // [hiddenDim → dim]
}

enum LayerWeights {
    case mamba(MambaLayerWeights)
    case attention(AttentionLayerWeights)
}

// MARK: - Model Compiler

class ANEModelCompiler {

    let loader: GGUFLoader
    let config: GGUFModelConfig

    private(set) var layerWeights: [LayerWeights] = []
    private(set) var isCompiled = false

    // Global weights
    private(set) var embeddingPtr: UnsafeRawPointer!  // Q8_0 [vocabSize, dim]
    private(set) var outputWeight: QWeight!  // Q8_0 [vocabSize, dim]
    private(set) var rmsFinalWeight: [Float] = []  // F32 [dim]

    init(loader: GGUFLoader) {
        self.loader = loader
        self.config = loader.config
    }

    /// Load all layer weights (pointers for Q8_0, arrays for F32)
    func compile(progress: @escaping (Float, String) -> Void) throws {
        let totalSteps = Float(config.nLayers + 2)

        // Step 1: Token embedding (raw Q8_0 pointer)
        progress(0, "Loading token embedding...")
        guard let embPtr = loader.tensorData(for: "token_embd.weight") else {
            throw GGUFError.tensorNotFound("token_embd.weight")
        }
        embeddingPtr = embPtr
        let embeddingWeight = try loadQWeight("token_embd.weight")
        if loader.tensors["output.weight"] != nil {
            outputWeight = try loadQWeight("output.weight")
        } else {
            outputWeight = embeddingWeight
        }

        // Step 2: Final RMSNorm (F32)
        progress(1 / totalSteps, "Loading final norm...")
        rmsFinalWeight = try loadF32Tensor("output_norm.weight")

        // Step 3: Load each layer
        for l in 0..<config.nLayers {
            let p = Float(l + 2) / totalSteps

            if config.isFullAttentionLayer(l) {
                progress(p, "Layer \(l): Loading attention weights...")
                let weights = try loadAttentionLayer(l)
                layerWeights.append(.attention(weights))
            } else {
                progress(p, "Layer \(l): Loading Mamba weights...")
                let weights = try loadMambaLayer(l)
                layerWeights.append(.mamba(weights))
            }
        }

        isCompiled = true
        progress(1.0, "Model loaded (\(config.nLayers) layers)")
    }

    // MARK: - Layer Loading

    private func loadMambaLayer(_ l: Int) throws -> MambaLayerWeights {
        let attnNorm = try loadF32Tensor("blk.\(l).attn_norm.weight")
        let postAttnNorm = try loadF32Tensor("blk.\(l).post_attention_norm.weight")

        let attnQKV = try loadQWeight("blk.\(l).attn_qkv.weight")
        let attnGate = try loadQWeight("blk.\(l).attn_gate.weight")

        let ssmConv1dRaw = try loadF32Tensor("blk.\(l).ssm_conv1d.weight")
        let ssmA = try loadF32Tensor("blk.\(l).ssm_a")
        let ssmAlpha = try loadQWeight("blk.\(l).ssm_alpha.weight")
        let ssmBeta = try loadQWeight("blk.\(l).ssm_beta.weight")
        let ssmDtBias = try loadF32Tensor("blk.\(l).ssm_dt.bias")
        let ssmNorm = try loadF32Tensor("blk.\(l).ssm_norm.weight")
        let ssmOut = try loadQWeight("blk.\(l).ssm_out.weight")

        let ffnGate = try loadQWeight("blk.\(l).ffn_gate.weight")
        let ffnUp = try loadQWeight("blk.\(l).ffn_up.weight")
        let ffnDown = try loadQWeight("blk.\(l).ffn_down.weight")

        return MambaLayerWeights(
            attnNorm: attnNorm, postAttnNorm: postAttnNorm,
            attnQKV: attnQKV, attnGate: attnGate,
            ssmConv1d: ssmConv1dRaw, ssmA: ssmA,
            ssmAlpha: ssmAlpha, ssmBeta: ssmBeta,
            ssmDtBias: ssmDtBias, ssmNorm: ssmNorm, ssmOut: ssmOut,
            ffnGate: ffnGate, ffnUp: ffnUp, ffnDown: ffnDown
        )
    }

    private func loadAttentionLayer(_ l: Int) throws -> AttentionLayerWeights {
        let attnNorm = try loadF32Tensor("blk.\(l).attn_norm.weight")
        let postAttnNorm = try loadF32Tensor("blk.\(l).post_attention_norm.weight")

        let attnQ = try loadQWeight("blk.\(l).attn_q.weight")
        let attnK = try loadQWeight("blk.\(l).attn_k.weight")
        let attnV = try loadQWeight("blk.\(l).attn_v.weight")
        let attnOutput = try loadQWeight("blk.\(l).attn_output.weight")

        let attnQNorm = try loadF32Tensor("blk.\(l).attn_q_norm.weight")
        let attnKNorm = try loadF32Tensor("blk.\(l).attn_k_norm.weight")

        let ffnGate = try loadQWeight("blk.\(l).ffn_gate.weight")
        let ffnUp = try loadQWeight("blk.\(l).ffn_up.weight")
        let ffnDown = try loadQWeight("blk.\(l).ffn_down.weight")

        return AttentionLayerWeights(
            attnNorm: attnNorm, postAttnNorm: postAttnNorm,
            attnQ: attnQ, attnK: attnK, attnV: attnV, attnOutput: attnOutput,
            attnQNorm: attnQNorm, attnKNorm: attnKNorm,
            ffnGate: ffnGate, ffnUp: ffnUp, ffnDown: ffnDown
        )
    }

    // MARK: - Helpers

    /// Load a Q8_0 weight as a raw pointer + dimensions
    private func loadQWeight(_ name: String) throws -> QWeight {
        guard let info = loader.tensors[name] else {
            throw GGUFError.tensorNotFound(name)
        }
        guard let ptr = loader.tensorData(for: name) else {
            throw GGUFError.tensorNotFound(name)
        }
        let inDim = Int(info.dimensions[0])  // ne0
        let outDim = info.dimensions.count > 1 ? Int(info.dimensions[1]) : 1  // ne1
        return QWeight(ptr: ptr, outDim: outDim, inDim: inDim)
    }

    /// Load an F32 tensor into a Swift array
    private func loadF32Tensor(_ name: String) throws -> [Float] {
        guard let info = loader.tensors[name] else {
            throw GGUFError.tensorNotFound(name)
        }
        guard let ptr = loader.tensorData(for: name) else {
            throw GGUFError.tensorNotFound(name)
        }
        if info.type == .f32 {
            return GGUFDequantizer.loadF32Tensor(ptr: ptr, count: info.elementCount)
        } else {
            // Dequantize if not F32
            return try GGUFDequantizer.dequantize(loader: loader, tensorName: name)
        }
    }

    /// Free resources
    func cleanup() {
        layerWeights.removeAll()
        rmsFinalWeight.removeAll()
        embeddingPtr = nil
        outputWeight = nil
        isCompiled = false
    }

    deinit {
        cleanup()
    }
}
