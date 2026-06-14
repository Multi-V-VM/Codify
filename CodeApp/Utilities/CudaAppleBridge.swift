//
//  CudaAppleBridge.swift
//  Code
//
//  C-callable Apple GPU backends for CUDA-style WebAssembly imports.
//

import Darwin
import Foundation
import Metal

private struct CudaMetalSGEMMParams {
    var m: UInt32
    var n: UInt32
    var k: UInt32
    var lda: UInt32
    var ldb: UInt32
    var ldc: UInt32
    var alpha: Float
    var beta: Float
}

private final class CudaMetalSGEMMRuntime {
    static let shared = CudaMetalSGEMMRuntime()

    private let lock = NSLock()
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLComputePipelineState?

    private init() {}

    func run(
        a: UnsafePointer<Float>,
        b: UnsafePointer<Float>,
        cIn: UnsafePointer<Float>,
        cOut: UnsafeMutablePointer<Float>,
        m: Int32,
        n: Int32,
        k: Int32,
        lda: Int32,
        ldb: Int32,
        ldc: Int32,
        alpha: Float,
        beta: Float
    ) -> Int32 {
        guard m > 0, n > 0, k > 0, lda >= m, ldb >= k, ldc >= m else {
            return 1
        }

        lock.lock()
        defer { lock.unlock() }

        guard preparePipeline() else {
            return 2
        }
        guard let device, let queue, let pipeline else {
            return 2
        }

        let aBytes = Int(lda) * Int(k) * MemoryLayout<Float>.stride
        let bBytes = Int(ldb) * Int(n) * MemoryLayout<Float>.stride
        let cBytes = Int(ldc) * Int(n) * MemoryLayout<Float>.stride

        guard
            let aBuffer = device.makeBuffer(bytes: a, length: aBytes, options: .storageModeShared),
            let bBuffer = device.makeBuffer(bytes: b, length: bBytes, options: .storageModeShared),
            let cInBuffer = device.makeBuffer(
                bytes: cIn, length: cBytes, options: .storageModeShared),
            let cOutBuffer = device.makeBuffer(length: cBytes, options: .storageModeShared)
        else {
            return 3
        }

        var params = CudaMetalSGEMMParams(
            m: UInt32(m),
            n: UInt32(n),
            k: UInt32(k),
            lda: UInt32(lda),
            ldb: UInt32(ldb),
            ldc: UInt32(ldc),
            alpha: alpha,
            beta: beta
        )

        guard
            let paramsBuffer = device.makeBuffer(
                bytes: &params,
                length: MemoryLayout<CudaMetalSGEMMParams>.stride,
                options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return 4
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(aBuffer, offset: 0, index: 0)
        encoder.setBuffer(bBuffer, offset: 0, index: 1)
        encoder.setBuffer(cInBuffer, offset: 0, index: 2)
        encoder.setBuffer(cOutBuffer, offset: 0, index: 3)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 4)

        let threadWidth = max(1, min(16, pipeline.threadExecutionWidth))
        let threadHeight = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threads = MTLSize(width: Int(m), height: Int(n), depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            return 5
        }

        let source = cOutBuffer.contents().assumingMemoryBound(to: Float.self)
        cOut.update(from: source, count: Int(ldc) * Int(n))
        return 0
    }

    private func preparePipeline() -> Bool {
        if pipeline != nil {
            return true
        }

        guard let metalDevice = MTLCreateSystemDefaultDevice(),
            let commandQueue = metalDevice.makeCommandQueue()
        else {
            return false
        }

        let source = """
            #include <metal_stdlib>
            using namespace metal;

            struct CudaMetalSGEMMParams {
                uint m;
                uint n;
                uint k;
                uint lda;
                uint ldb;
                uint ldc;
                float alpha;
                float beta;
            };

            kernel void codifyone_sgemm_col_major(
                device const float *a [[buffer(0)]],
                device const float *b [[buffer(1)]],
                device const float *c_in [[buffer(2)]],
                device float *c_out [[buffer(3)]],
                constant CudaMetalSGEMMParams &p [[buffer(4)]],
                uint2 gid [[thread_position_in_grid]])
            {
                const uint row = gid.x;
                const uint col = gid.y;
                if (row >= p.m || col >= p.n) {
                    return;
                }

                float sum = 0.0f;
                for (uint q = 0; q < p.k; ++q) {
                    sum += a[row + q * p.lda] * b[q + col * p.ldb];
                }

                const uint c_index = row + col * p.ldc;
                c_out[c_index] = fma(p.alpha, sum, p.beta * c_in[c_index]);
            }
            """

        do {
            let library = try metalDevice.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "codifyone_sgemm_col_major") else {
                return false
            }
            pipeline = try metalDevice.makeComputePipelineState(function: function)
            device = metalDevice
            queue = commandQueue
            return true
        } catch {
            fputs("codifyone_metal_sgemm: \(error)\n", stderr)
            return false
        }
    }
}

@_cdecl("codifyone_metal_sgemm")
public func codifyone_metal_sgemm(
    _ a: UnsafePointer<Float>?,
    _ b: UnsafePointer<Float>?,
    _ cIn: UnsafePointer<Float>?,
    _ cOut: UnsafeMutablePointer<Float>?,
    _ m: Int32,
    _ n: Int32,
    _ k: Int32,
    _ lda: Int32,
    _ ldb: Int32,
    _ ldc: Int32,
    _ alpha: Float,
    _ beta: Float
) -> Int32 {
    guard let a, let b, let cIn, let cOut else {
        return 1
    }

    return CudaMetalSGEMMRuntime.shared.run(
        a: a,
        b: b,
        cIn: cIn,
        cOut: cOut,
        m: m,
        n: n,
        k: k,
        lda: lda,
        ldb: ldb,
        ldc: ldc,
        alpha: alpha,
        beta: beta
    )
}

private enum CudaANEBridge {
    typealias InitFn = @convention(c) () -> Int32
    typealias CompileConvFn =
        @convention(c) (UnsafePointer<Float>?, Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    typealias WriteInputFn =
        @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int) -> Void
    typealias EvalFn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    typealias ReadOutputFn =
        @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?, Int) -> Void
    typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: type)
    }
}

@_cdecl("codifyone_ane_sgemm")
public func codifyone_ane_sgemm(
    _ a: UnsafePointer<Float>?,
    _ b: UnsafePointer<Float>?,
    _ cIn: UnsafePointer<Float>?,
    _ cOut: UnsafeMutablePointer<Float>?,
    _ m: Int32,
    _ n: Int32,
    _ k: Int32,
    _ lda: Int32,
    _ ldb: Int32,
    _ ldc: Int32,
    _ alpha: Float,
    _ beta: Float
) -> Int32 {
    guard let a, let b, let cOut else {
        return 1
    }
    guard m > 0, n > 0, k > 0, lda == m, ldb == k, ldc == m else {
        return 2
    }
    guard beta == 0 else {
        return 3
    }

    guard
        let initFn = CudaANEBridge.resolve("ane_compiler_init", as: CudaANEBridge.InitFn.self),
        let compileConv = CudaANEBridge.resolve(
            "ane_compile_conv",
            as: CudaANEBridge.CompileConvFn.self),
        let writeInput = CudaANEBridge.resolve(
            "ane_bridge_write_input",
            as: CudaANEBridge.WriteInputFn.self),
        let eval = CudaANEBridge.resolve("ane_bridge_eval", as: CudaANEBridge.EvalFn.self),
        let readOutput = CudaANEBridge.resolve(
            "ane_bridge_read_output",
            as: CudaANEBridge.ReadOutputFn.self),
        let freeKernel = CudaANEBridge.resolve(
            "ane_compiler_free_kernel",
            as: CudaANEBridge.FreeFn.self)
    else {
        return 4
    }

    guard initFn() == 0 else {
        return 5
    }

    let weightCount = Int(k) * Int(n)
    let inputBytes = Int(m) * Int(k) * MemoryLayout<Float>.stride
    let outputBytes = Int(m) * Int(n) * MemoryLayout<Float>.stride

    let runWithWeights: (UnsafePointer<Float>) -> Int32 = { weights in
        guard let kernel = compileConv(weights, k, n, m) else {
            return 6
        }
        defer { freeKernel(kernel) }

        writeInput(kernel, 0, UnsafeRawPointer(a), inputBytes)
        guard eval(kernel) else {
            return 7
        }
        readOutput(kernel, 0, UnsafeMutableRawPointer(cOut), outputBytes)
        return 0
    }

    if alpha == 1 {
        return runWithWeights(b)
    }

    let scaledWeights = Array(UnsafeBufferPointer(start: b, count: weightCount)).map {
        $0 * alpha
    }
    return scaledWeights.withUnsafeBufferPointer { buffer in
        guard let weights = buffer.baseAddress else {
            return 1
        }
        return runWithWeights(weights)
    }
}
