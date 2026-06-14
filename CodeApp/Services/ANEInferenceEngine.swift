//
//  ANEInferenceEngine.swift
//  Code
//
//  Qwen3.5 hybrid Mamba-2 + Attention inference engine
//  18 Mamba layers + 6 pure attention layers, all CPU with Accelerate
//

import Accelerate
import Foundation

class ANEInferenceEngine {

    let compiler: ANEModelCompiler
    let config: GGUFModelConfig

    // Generation parameters
    var maxTokens: Int = 512
    var temperature: Float = 0.7
    var topK: Int = 40
    var topP: Float = 0.9

    // State
    private var position: Int = 0
    private var lastHidden: [Float] = []

    // Mamba state: conv buffer + SSM recurrent state
    // convState[mambaIdx] = flattened [(K-1) * channels]
    private var convStates: [[Float]] = []
    // ssmState[mambaIdx] = flattened [nGroups * dState * dInnerPerGroup]
    private var ssmStates: [[Float]] = []

    // Attention state: KV cache
    // kvCache[attnIdx] = flat [maxSeq * 2 * kvDim] with layout [pos][K_or_V][kvDim]
    private var kvCaches: [[Float]] = []

    // Derived constants
    private let dim: Int
    private let hiddenDim: Int
    private let ropeDim: Int
    private let ropeTheta: Float
    private let rmsEps: Float
    private let nGroups: Int
    private let dState: Int
    private let ssmInner: Int
    private let ssmBCDim: Int
    private let dInnerPerGroup: Int
    private let convKernel: Int
    private let totalConvChannels: Int
    private let vocabSize: Int
    private let maxSeqLen: Int

    // Attention-specific dimensions (derived from actual weight shapes)
    private let attnHeadDim: Int  // 256 (key_length)
    private let nQHeads: Int  // 16 (Q sub-heads for differential attention)
    private let nAttnKVHeads: Int  // 2
    private let nOutHeads: Int  // 8 (logical output heads = nQHeads/2)
    private let kvTotalDim: Int  // 512 (nAttnKVHeads * attnHeadDim)
    private let attnOutDim: Int  // 2048 (nOutHeads * attnHeadDim)

    init(compiler: ANEModelCompiler) {
        self.compiler = compiler
        self.config = compiler.config

        dim = config.dim
        hiddenDim = config.hiddenDim
        ropeDim = config.ropeDim
        ropeTheta = config.ropeTheta
        rmsEps = config.rmsNormEps
        nGroups = config.ssmGroupCount
        dState = config.ssmStateSize
        ssmInner = config.ssmInnerSize
        ssmBCDim = nGroups * dState
        dInnerPerGroup = ssmInner / max(nGroups, 1)
        convKernel = config.ssmConvKernel
        totalConvChannels =
            compiler.layerWeights.compactMap { layer -> Int? in
                if case .mamba(let weights) = layer {
                    return weights.attnQKV.outDim
                }
                return nil
            }.first ?? (ssmInner + 2 * ssmBCDim)
        vocabSize = config.vocabSize
        maxSeqLen = min(config.contextLength, 2048)

        // Derive attention dimensions from the first attention layer's weights
        var _attnHeadDim = 256
        var _nQHeads = 16
        var _nAttnKVHeads = 2
        var _nOutHeads = 8
        for lw in compiler.layerWeights {
            if case .attention(let w) = lw {
                _attnHeadDim = w.attnQNorm.count  // 256
                _nQHeads = w.attnQ.outDim / _attnHeadDim  // 4096/256 = 16
                _nAttnKVHeads = w.attnK.outDim / _attnHeadDim  // 512/256 = 2
                _nOutHeads = w.attnOutput.inDim / _attnHeadDim  // 2048/256 = 8
                break
            }
        }
        attnHeadDim = _attnHeadDim
        nQHeads = _nQHeads
        nAttnKVHeads = _nAttnKVHeads
        nOutHeads = _nOutHeads
        kvTotalDim = _nAttnKVHeads * _attnHeadDim
        attnOutDim = _nOutHeads * _attnHeadDim

        initializeState()
    }

    private func initializeState() {
        convStates = []
        ssmStates = []
        kvCaches = []
        lastHidden = [Float](repeating: 0, count: dim)

        for layer in compiler.layerWeights {
            switch layer {
            case .attention:
                kvCaches.append([Float](repeating: 0, count: maxSeqLen * 2 * kvTotalDim))
            case .mamba(let weights):
                let channels = weights.attnQKV.outDim
                convStates.append([Float](repeating: 0, count: (convKernel - 1) * channels))
                ssmStates.append([Float](repeating: 0, count: nGroups * dState * dInnerPerGroup))
            }
        }
        position = 0
    }

    func resetCache() {
        initializeState()
    }

    // MARK: - Forward Pass

    /// Run all layers without the classifier (for prefill — skips expensive 248K logit computation)
    private func forwardLayers(tokenId: Int) {
        var x = GGUFDequantizer.q8_0EmbedLookup(
            w: compiler.embeddingPtr, tokenId: tokenId, dim: dim)

        var mambaIdx = 0
        var attnIdx = 0

        for l in 0..<config.nLayers {
            switch compiler.layerWeights[l] {
            case .mamba(let w):
                x = mambaForward(x: x, w: w, mambaIdx: mambaIdx)
                mambaIdx += 1
            case .attention(let w):
                x = attentionForward(x: x, w: w, attnIdx: attnIdx)
                attnIdx += 1
            }
        }

        lastHidden = x
        position += 1
    }

    /// Compute logits from the last hidden state (expensive: 248K dot products)
    private func computeLogits() -> [Float] {
        let x = rmsNorm(lastHidden, weight: compiler.rmsFinalWeight)

        var logits = [Float](repeating: 0, count: compiler.outputWeight.outDim)
        x.withUnsafeBufferPointer { xBuf in
            logits.withUnsafeMutableBufferPointer { yBuf in
                GGUFDequantizer.q8_0Matvec(
                    w: compiler.outputWeight.ptr,
                    x: xBuf.baseAddress!, y: yBuf.baseAddress!,
                    outDim: compiler.outputWeight.outDim,
                    inDim: compiler.outputWeight.inDim)
            }
        }
        return logits
    }

    /// Full forward step: layers + classifier
    func forwardStep(tokenId: Int) -> [Float] {
        forwardLayers(tokenId: tokenId)
        return computeLogits()
    }

    // MARK: - Mamba Layer Forward

    private func mambaForward(x: [Float], w: MambaLayerWeights, mambaIdx: Int) -> [Float] {
        let xNorm = rmsNorm(x, weight: w.attnNorm)

        // Project to xBC space
        let xBC = w.attnQKV.matvec(xNorm)

        // Causal 1D convolution
        let convOut = causalConv1d(input: xBC, mambaIdx: mambaIdx, weight: w.ssmConv1d)

        // Split xBC as [x_ssm, B, C]. B/C are nGroups*dState, not always ssmInner.
        let expectedConvChannels = ssmInner + 2 * ssmBCDim
        guard convOut.count >= expectedConvChannels else {
            return x
        }
        var xSsm = Array(convOut[0..<ssmInner])
        let bStart = ssmInner
        let cStart = ssmInner + ssmBCDim
        let bFlat = Array(convOut[bStart..<(bStart + ssmBCDim)])
        let cFlat = Array(convOut[cStart..<(cStart + ssmBCDim)])

        // SiLU on x_ssm
        for i in 0..<ssmInner {
            xSsm[i] = xSsm[i] / (1.0 + exp(-xSsm[i]))
        }

        // Compute dt
        let dtRaw = w.ssmAlpha.matvec(xNorm)
        var dt = [Float](repeating: 0, count: nGroups)
        for g in 0..<nGroups {
            dt[g] = log(1.0 + exp(dtRaw[g] + w.ssmDtBias[g]))  // softplus
        }

        // SSM selective scan
        var y = ssmScan(
            xSsm: xSsm, B: bFlat, C: cFlat, dt: dt,
            A: w.ssmA, mambaIdx: mambaIdx)

        // Group RMSNorm
        y = groupRMSNorm(y, weight: w.ssmNorm)

        // D skip connection (feedthrough: y += D * x)
        let D = w.ssmBeta.matvec(xNorm)
        for g in 0..<nGroups {
            for j in 0..<dInnerPerGroup {
                let ch = g * dInnerPerGroup + j
                y[ch] += D[g] * xSsm[ch]
            }
        }

        // Gate (SiLU, NOT sigmoid)
        let gateRaw = w.attnGate.matvec(xNorm)
        for i in 0..<ssmInner {
            y[i] *= gateRaw[i] / (1.0 + exp(-gateRaw[i]))
        }

        // Output projection + residual
        let out = w.ssmOut.matvec(y)
        var result = x
        for i in 0..<dim { result[i] += out[i] }

        // FFN
        let ffnNorm = rmsNorm(result, weight: w.postAttnNorm)
        let ffnOut = ffnForward(ffnNorm, gate: w.ffnGate, up: w.ffnUp, down: w.ffnDown)
        for i in 0..<dim { result[i] += ffnOut[i] }

        return result
    }

    // MARK: - Causal Conv1D

    private func causalConv1d(input: [Float], mambaIdx: Int, weight: [Float]) -> [Float] {
        let K = convKernel  // 4
        let C = input.count
        guard K > 0, weight.count >= C * K, convStates[mambaIdx].count >= max(K - 1, 0) * C else {
            return input
        }

        // Compute conv output FIRST using current state + new input
        // State holds last K-1=3 positions: [t-3, t-2, t-1]
        // weight layout: [channels, kernel] with ne0=K, ne1=C
        var output = [Float](repeating: 0, count: C)
        for ch in 0..<C {
            var sum: Float = 0
            // History from state (kernel positions 0..K-2)
            for k in 0..<(K - 1) {
                sum += weight[ch * K + k] * convStates[mambaIdx][k * C + ch]
            }
            // Current input (kernel position K-1)
            sum += weight[ch * K + (K - 1)] * input[ch]
            output[ch] = sum
        }

        // THEN update state: shift left, store new input at end
        if K > 2 {
            for i in 0..<((K - 2) * C) {
                convStates[mambaIdx][i] = convStates[mambaIdx][i + C]
            }
        }
        for i in 0..<C {
            convStates[mambaIdx][(K - 2) * C + i] = input[i]
        }

        return output
    }

    // MARK: - SSM Selective Scan

    private func ssmScan(
        xSsm: [Float], B: [Float], C: [Float],
        dt: [Float], A: [Float], mambaIdx: Int
    ) -> [Float] {
        var y = [Float](repeating: 0, count: ssmInner)

        // Unsafe buffers: this triple loop runs ssmInner*dState MACs per
        // layer and Swift bounds checking on the state array dominates it.
        let dInner = dInnerPerGroup
        let states = dState
        y.withUnsafeMutableBufferPointer { yBuf in
            xSsm.withUnsafeBufferPointer { xBuf in
                B.withUnsafeBufferPointer { bBuf in
                    C.withUnsafeBufferPointer { cBuf in
                        ssmStates[mambaIdx].withUnsafeMutableBufferPointer { stateBuf in
                            let yPtr = yBuf.baseAddress!
                            let xPtr = xBuf.baseAddress!
                            let bPtr = bBuf.baseAddress!
                            let cPtr = cBuf.baseAddress!
                            let statePtr = stateBuf.baseAddress!

                            for g in 0..<nGroups {
                                // A in log-space: log_A = -softplus(ssm_a[g]), always negative
                                // dA = exp(dt * log_A) = exp(-dt * softplus(ssm_a[g])), in (0, 1)
                                let logA = -log(1.0 + exp(A[g]))  // -softplus(ssm_a)
                                let dtVal = dt[g]
                                let dA = exp(dtVal * logA)
                                let groupState = statePtr + g * states * dInner
                                let groupB = bPtr + g * states
                                let groupC = cPtr + g * states

                                for s in 0..<states {
                                    // state[s][:] = dA*state[s][:] + (dt*B[s])*x[:]
                                    // y[:] += C[s] * state[s][:]
                                    // Row-contiguous over j, so the compiler can vectorize.
                                    let row = groupState + s * dInner
                                    let dtB = dtVal * groupB[s]
                                    let cVal = groupC[s]
                                    let xGroup = xPtr + g * dInner
                                    let yGroup = yPtr + g * dInner
                                    for j in 0..<dInner {
                                        let updated = dA * row[j] + dtB * xGroup[j]
                                        row[j] = updated
                                        yGroup[j] += cVal * updated
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return y
    }

    // MARK: - Attention Layer Forward

    private func attentionForward(x: [Float], w: AttentionLayerWeights, attnIdx: Int) -> [Float] {
        let xNorm = rmsNorm(x, weight: w.attnNorm)

        // Q/K/V projections (Q: [4096], K: [512], V: [512])
        var q = w.attnQ.matvec(xNorm)
        var k = w.attnK.matvec(xNorm)
        let v = w.attnV.matvec(xNorm)

        // Per-head Q norm (16 Q sub-heads, each attnHeadDim=256)
        for h in 0..<nQHeads {
            let off = h * attnHeadDim
            var slice = Array(q[off..<(off + attnHeadDim)])
            slice = rmsNorm(slice, weight: w.attnQNorm)
            for i in 0..<attnHeadDim { q[off + i] = slice[i] }
        }
        // Per-head K norm (2 KV heads)
        for h in 0..<nAttnKVHeads {
            let off = h * attnHeadDim
            var slice = Array(k[off..<(off + attnHeadDim)])
            slice = rmsNorm(slice, weight: w.attnKNorm)
            for i in 0..<attnHeadDim { k[off + i] = slice[i] }
        }

        // RoPE (partial, ropeDim=64 within each head of attnHeadDim=256)
        applyRoPEAttn(&q, nHeadsCount: nQHeads)
        applyRoPEAttn(&k, nHeadsCount: nAttnKVHeads)

        // Store K/V in cache [pos][K_then_V][kvTotalDim]
        let pos = position
        for i in 0..<kvTotalDim {
            kvCaches[attnIdx][pos * 2 * kvTotalDim + i] = k[i]
            kvCaches[attnIdx][pos * 2 * kvTotalDim + kvTotalDim + i] = v[i]
        }

        // Differential GQA Attention
        // 16 Q sub-heads → 8 output heads (pairs: sub-heads 2i,2i+1 → output head i)
        // GQA: nOutHeads(8) / nAttnKVHeads(2) = 4 logical heads per KV head
        let qSubPerHead = nQHeads / nOutHeads  // 2 (differential pair)
        let gqaGroupSize = nOutHeads / max(nAttnKVHeads, 1)  // 4
        let scale = 1.0 / sqrt(Float(attnHeadDim))
        var attnOut = [Float](repeating: 0, count: attnOutDim)  // [2048]

        // vDSP dot products / scaled accumulation over the raw cache buffer:
        // these loops run O(position) times per token and dominate at long
        // contexts if left as bounds-checked scalar Swift.
        let headDim = attnHeadDim
        let strideKV = 2 * kvTotalDim
        let vBase = kvTotalDim
        kvCaches[attnIdx].withUnsafeBufferPointer { cacheBuf in
            let cache = cacheBuf.baseAddress!
            q.withUnsafeBufferPointer { qBuf in
                let qPtr = qBuf.baseAddress!
                attnOut.withUnsafeMutableBufferPointer { outBuf in
                    let out = outBuf.baseAddress!

                    for oh in 0..<nOutHeads {
                        let kvHead = oh / gqaGroupSize
                        let kHeadOff = kvHead * headDim

                        // Differential score pair for each cached position
                        var scores0 = [Float](repeating: 0, count: pos + 1)
                        var scores1 = [Float](repeating: 0, count: pos + 1)
                        let qOff0 = (oh * qSubPerHead) * headDim
                        let qOff1 = qOff0 + headDim
                        for p in 0...pos {
                            let kPtr = cache + p * strideKV + kHeadOff
                            var dot0: Float = 0
                            var dot1: Float = 0
                            vDSP_dotpr(qPtr + qOff0, 1, kPtr, 1, &dot0, vDSP_Length(headDim))
                            vDSP_dotpr(qPtr + qOff1, 1, kPtr, 1, &dot1, vDSP_Length(headDim))
                            scores0[p] = dot0 * scale
                            scores1[p] = dot1 * scale
                        }
                        softmax(&scores0)
                        softmax(&scores1)

                        // Weighted V: output = attn0·V - attn1·V (differential attention)
                        let outPtr = out + oh * headDim
                        for p in 0...pos {
                            let vPtr = cache + p * strideKV + vBase + kHeadOff
                            var diffScore = scores0[p] - scores1[p]
                            vDSP_vsma(
                                vPtr, 1, &diffScore, outPtr, 1, outPtr, 1, vDSP_Length(headDim))
                        }
                    }
                }
            }
        }

        // Output projection [2048 → 1024] + residual
        let projected = w.attnOutput.matvec(attnOut)
        var result = x
        for i in 0..<dim { result[i] += projected[i] }

        // FFN
        let ffnNorm = rmsNorm(result, weight: w.postAttnNorm)
        let ffnOut = ffnForward(ffnNorm, gate: w.ffnGate, up: w.ffnUp, down: w.ffnDown)
        for i in 0..<dim { result[i] += ffnOut[i] }

        return result
    }

    // MARK: - FFN (SwiGLU)

    private func ffnForward(_ x: [Float], gate: QWeight, up: QWeight, down: QWeight) -> [Float] {
        let gateOut = gate.matvec(x)
        let upOut = up.matvec(x)

        var hidden = [Float](repeating: 0, count: hiddenDim)
        for i in 0..<hiddenDim {
            let silu = gateOut[i] / (1.0 + exp(-gateOut[i]))
            hidden[i] = silu * upOut[i]
        }

        return down.matvec(hidden)
    }

    // MARK: - RoPE

    /// RoPE for attention layers (head_dim = attnHeadDim = 256)
    private func applyRoPEAttn(_ vec: inout [Float], nHeadsCount: Int) {
        let halfRope = ropeDim / 2  // 32
        for h in 0..<nHeadsCount {
            let off = h * attnHeadDim
            for i in 0..<halfRope {
                let freq = 1.0 / pow(ropeTheta, Float(2 * i) / Float(ropeDim))
                let theta = Float(position) * freq
                let cosVal = cos(theta)
                let sinVal = sin(theta)
                let r0 = vec[off + 2 * i]
                let r1 = vec[off + 2 * i + 1]
                vec[off + 2 * i] = r0 * cosVal - r1 * sinVal
                vec[off + 2 * i + 1] = r0 * sinVal + r1 * cosVal
            }
        }
    }

    // MARK: - Helpers

    private func rmsNorm(_ x: [Float], weight: [Float]) -> [Float] {
        let n = x.count
        var sumSq: Float = 0
        for i in 0..<n { sumSq += x[i] * x[i] }
        let rms = sqrt(sumSq / Float(n) + rmsEps)
        var result = [Float](repeating: 0, count: n)
        for i in 0..<n { result[i] = (x[i] / rms) * weight[i] }
        return result
    }

    private func groupRMSNorm(_ x: [Float], weight: [Float]) -> [Float] {
        let perChannel = weight.count > dInnerPerGroup
        var result = x
        for g in 0..<nGroups {
            let off = g * dInnerPerGroup
            var sumSq: Float = 0
            for j in 0..<dInnerPerGroup { sumSq += result[off + j] * result[off + j] }
            let rms = sqrt(sumSq / Float(dInnerPerGroup) + rmsEps)
            for j in 0..<dInnerPerGroup {
                let wIdx = perChannel ? (off + j) : j
                result[off + j] = (result[off + j] / rms) * weight[wIdx]
            }
        }
        return result
    }

    private func softmax(_ x: inout [Float]) {
        let maxVal = x.max() ?? 0
        var sumExp: Float = 0
        for i in 0..<x.count {
            x[i] = exp(x[i] - maxVal)
            sumExp += x[i]
        }
        for i in 0..<x.count { x[i] /= sumExp }
    }

    // MARK: - Token Generation

    func generate(
        promptTokens: [Int], tokenizer: GGUFTokenizer,
        onToken: (Int, String) -> Bool
    ) -> String {
        resetCache()
        tokenizer.resetDecodeBuffer()
        var output = ""

        // Prefill: run layers only (skip expensive 248K classifier until we need to sample)
        for token in promptTokens {
            forwardLayers(tokenId: token)
        }
        // Compute logits only for the last prompt token
        var lastLogits = computeLogits()

        // Autoregressive generation
        for _ in 0..<maxTokens {
            let nextToken = sampleToken(logits: lastLogits, tokenizer: tokenizer)
            if tokenizer.isEOS(nextToken) { break }
            if position >= maxSeqLen - 1 { break }

            let text = tokenizer.decodeOne(nextToken)
            output += text
            if !onToken(nextToken, text) { break }

            lastLogits = forwardStep(tokenId: nextToken)
        }

        return output
    }

    // MARK: - Sampling

    private func sampleToken(logits: [Float], tokenizer: GGUFTokenizer) -> Int {
        if temperature <= 0 {
            var bestIndex = 0
            var bestLogit = -Float.infinity
            for (index, logit) in logits.enumerated()
            where tokenizer.isTextToken(index) || tokenizer.isEOS(index) {
                if logit > bestLogit {
                    bestLogit = logit
                    bestIndex = index
                }
            }
            return bestIndex
        }

        // Select the top-K candidates in one pass over the vocabulary
        // (the previous implementation sorted all ~250K logits twice per
        // token, which dominated sampling time). Top-P then only needs to
        // look at those K candidates: everything below the K-th logit is
        // already excluded by top-K.
        let k = (topK > 0 && topK < logits.count) ? topK : 256
        var candidates = topKCandidates(logits: logits, k: k, tokenizer: tokenizer)

        if candidates.isEmpty {
            return 0
        }

        // Softmax over the candidates (sorted descending by logit)
        candidates.sort { $0.logit > $1.logit }
        let maxLogit = candidates[0].logit
        var probs = candidates.map { exp(($0.logit - maxLogit) / temperature) }
        var sumProbs = probs.reduce(0, +)

        // Top-P cutoff on the sorted candidates
        if topP < 1.0 {
            var cumProb: Float = 0
            var cutoff = probs.count
            for i in 0..<probs.count {
                cumProb += probs[i] / sumProbs
                if cumProb >= topP {
                    cutoff = i + 1
                    break
                }
            }
            probs = Array(probs[0..<cutoff])
            sumProbs = probs.reduce(0, +)
        }

        // Multinomial over the surviving candidates
        let r = Float.random(in: 0..<1) * sumProbs
        var cum: Float = 0
        for i in 0..<probs.count {
            cum += probs[i]
            if cum >= r { return candidates[i].index }
        }
        return candidates[probs.count - 1].index
    }

    /// Single-pass top-k selection with a size-k min-heap: O(N log k).
    private func topKCandidates(logits: [Float], k: Int, tokenizer: GGUFTokenizer) -> [(
        index: Int, logit: Float
    )] {
        var heap = [(index: Int, logit: Float)]()
        heap.reserveCapacity(k)

        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var smallest = parent
                if left < heap.count && heap[left].logit < heap[smallest].logit {
                    smallest = left
                }
                if right < heap.count && heap[right].logit < heap[smallest].logit {
                    smallest = right
                }
                if smallest == parent { return }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }

        for (i, logit) in logits.enumerated() {
            guard tokenizer.isTextToken(i) || tokenizer.isEOS(i) else { continue }
            if heap.count < k {
                heap.append((i, logit))
                if heap.count == k {
                    for node in stride(from: k / 2 - 1, through: 0, by: -1) {
                        siftDown(node)
                    }
                }
            } else if logit > heap[0].logit {
                heap[0] = (i, logit)
                siftDown(0)
            }
        }
        return heap
    }
}
