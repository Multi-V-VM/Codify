//
//  GGUFDequantizer.swift
//  Code
//
//  Dequantize GGUF tensor data (Q8_0, Q4_0, F16, F32) to Float arrays
//

import Foundation
import Accelerate

class GGUFDequantizer {

    /// Dequantize a tensor from the GGUF loader into Float array
    static func dequantize(loader: GGUFLoader, tensorName: String) throws -> [Float] {
        guard let info = loader.tensors[tensorName] else {
            throw GGUFError.tensorNotFound(tensorName)
        }
        guard let ptr = loader.tensorData(for: tensorName) else {
            throw GGUFError.tensorNotFound(tensorName)
        }

        let count = info.elementCount

        switch info.type {
        case .f32:
            return dequantizeF32(ptr: ptr, count: count)
        case .f16:
            return dequantizeF16(ptr: ptr, count: count)
        case .q8_0:
            return dequantizeQ8_0(ptr: ptr, count: count)
        case .q4_0:
            return dequantizeQ4_0(ptr: ptr, count: count)
        default:
            throw GGUFError.unsupportedQuantization(String(describing: info.type))
        }
    }

    // MARK: - F32 (no dequantization needed)

    static func dequantizeF32(ptr: UnsafeRawPointer, count: Int) -> [Float] {
        let src = ptr.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: src, count: count))
    }

    // MARK: - F16 → F32

    static func dequantizeF16(ptr: UnsafeRawPointer, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let src = ptr.bindMemory(to: UInt16.self, capacity: count)
        // Use vImage for fp16 → fp32 conversion
        var srcBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src),
            height: 1, width: vImagePixelCount(count),
            rowBytes: count * 2
        )
        result.withUnsafeMutableBufferPointer { dstBuf in
            var dst = vImage_Buffer(
                data: dstBuf.baseAddress!,
                height: 1, width: vImagePixelCount(count),
                rowBytes: count * 4
            )
            vImageConvert_Planar16FtoPlanarF(&srcBuf, &dst, 0)
        }
        return result
    }

    // MARK: - Q8_0 → F32
    // Q8_0 block: [float16 scale (2 bytes)][int8 quants × 32 (32 bytes)] = 34 bytes per block

    static func dequantizeQ8_0(ptr: UnsafeRawPointer, count: Int) -> [Float] {
        let blockSize = 32
        let nBlocks = count / blockSize
        var result = [Float](repeating: 0, count: count)

        for b in 0..<nBlocks {
            let blockPtr = ptr.advanced(by: b * 34)

            // Read fp16 scale and convert to float32
            let scaleRaw = blockPtr.load(as: UInt16.self)
            let scale = fp16ToFloat(scaleRaw)

            // Read 32 int8 quantized values
            let quantsPtr = blockPtr.advanced(by: 2).bindMemory(to: Int8.self, capacity: 32)

            let outOffset = b * blockSize
            for i in 0..<32 {
                result[outOffset + i] = Float(quantsPtr[i]) * scale
            }
        }

        return result
    }

    // MARK: - Q4_0 → F32
    // Q4_0 block: [float16 scale (2 bytes)][4-bit quants × 32 packed in 16 bytes] = 18 bytes per block

    static func dequantizeQ4_0(ptr: UnsafeRawPointer, count: Int) -> [Float] {
        let blockSize = 32
        let nBlocks = count / blockSize
        var result = [Float](repeating: 0, count: count)

        for b in 0..<nBlocks {
            let blockPtr = ptr.advanced(by: b * 18)

            // Read fp16 scale
            let scaleRaw = blockPtr.load(as: UInt16.self)
            let scale = fp16ToFloat(scaleRaw)

            // Read 16 bytes of packed 4-bit values (32 values, 2 per byte)
            let nibblePtr = blockPtr.advanced(by: 2).bindMemory(to: UInt8.self, capacity: 16)

            let outOffset = b * blockSize
            for i in 0..<16 {
                let byte = nibblePtr[i]
                // Low nibble first, then high nibble
                let lo = Int(byte & 0x0F) - 8
                let hi = Int(byte >> 4) - 8
                result[outOffset + i * 2] = Float(lo) * scale
                result[outOffset + i * 2 + 1] = Float(hi) * scale
            }
        }

        return result
    }

    // MARK: - Quantized Matrix-Vector Multiply (Q8_0)

    /// Compute y = W * x where W is [outDim, inDim] in Q8_0 format
    /// W is stored row-major: outDim rows, each row has inDim/32 Q8_0 blocks
    ///
    /// Delegates to the C kernel (ane_q8_kernel.c): the activation is
    /// quantized to int8 once and each row is a NEON int8 dot product over
    /// the mmap'd weights — no F32 weight materialization — parallelized
    /// across cores. ~int8-noise-floor accuracy vs the previous
    /// dequantize+sgemv path (validated bit-exact against a scalar
    /// reference of the same quantized computation).
    static func q8_0Matvec(
        w: UnsafeRawPointer,
        x: UnsafePointer<Float>,
        y: UnsafeMutablePointer<Float>,
        outDim: Int,
        inDim: Int
    ) {
        ane_q8_matvec(w, x, y, Int32(outDim), Int32(inDim))
    }

    /// Wrapper that takes Swift arrays
    static func q8_0Matvec(
        w: UnsafeRawPointer,
        x: [Float],
        outDim: Int,
        inDim: Int
    ) -> [Float] {
        var result = [Float](repeating: 0, count: outDim)
        x.withUnsafeBufferPointer { xBuf in
            result.withUnsafeMutableBufferPointer { yBuf in
                q8_0Matvec(w: w, x: xBuf.baseAddress!, y: yBuf.baseAddress!,
                           outDim: outDim, inDim: inDim)
            }
        }
        return result
    }

    // MARK: - Quantized Embedding Lookup (Q8_0)

    /// Extract and dequantize a single row from a Q8_0 matrix (for embedding lookup)
    static func q8_0EmbedLookup(w: UnsafeRawPointer, tokenId: Int, dim: Int) -> [Float] {
        let blocksPerRow = dim / 32
        let bytesPerRow = blocksPerRow * 34
        let rowPtr = w.advanced(by: tokenId * bytesPerRow)
        var result = [Float](repeating: 0, count: dim)
        for b in 0..<blocksPerRow {
            let blockPtr = rowPtr.advanced(by: b * 34)
            var scaleU16: UInt16 = 0
            memcpy(&scaleU16, blockPtr, 2)
            let scale = Float(Float16(bitPattern: scaleU16))
            let qsPtr = blockPtr.advanced(by: 2).assumingMemoryBound(to: Int8.self)
            let off = b * 32
            for j in 0..<32 {
                result[off + j] = scale * Float(qsPtr[j])
            }
        }
        return result
    }

    // MARK: - Direct F32 Load from Raw Pointer

    /// Load F32 data directly from mmap'd pointer (with memcpy for alignment safety)
    static func loadF32Tensor(ptr: UnsafeRawPointer, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBufferPointer { buf in
            memcpy(buf.baseAddress!, ptr, count * MemoryLayout<Float>.size)
        }
        return result
    }

    // MARK: - FP16 Conversion Helper

    private static func fp16ToFloat(_ bits: UInt16) -> Float {
        return Float(Float16(bitPattern: bits))
    }
}
