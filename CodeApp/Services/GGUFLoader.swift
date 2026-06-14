//
//  GGUFLoader.swift
//  Code
//
//  GGUF v3 binary parser: memory-map file, parse header/metadata/tensor info
//

import Foundation

// MARK: - GGUF Constants

enum GGUFType: UInt32 {
    case uint8 = 0
    case int8 = 1
    case uint16 = 2
    case int16 = 3
    case uint32 = 4
    case int32 = 5
    case float32 = 6
    case bool_ = 7
    case string = 8
    case array = 9
    case uint64 = 10
    case int64 = 11
    case float64 = 12
}

enum GGMLType: UInt32 {
    case f32 = 0
    case f16 = 1
    case q4_0 = 2
    case q4_1 = 3
    case q5_0 = 6
    case q5_1 = 7
    case q8_0 = 8
    case q8_1 = 9
    case q2_K = 10
    case q3_K = 11
    case q4_K = 12
    case q5_K = 13
    case q6_K = 14
    case iq2_xxs = 16
    case iq2_xs = 17
    case iq3_xxs = 18
    case iq1_s = 19
    case iq4_nl = 20
    case iq3_s = 21
    case iq2_s = 22
    case iq4_xs = 23
    case i8 = 24
    case i16 = 25
    case i32 = 26
    case i64 = 27
    case f64 = 28
    case iq1_m = 29
    case bf16 = 30

    var blockSize: Int {
        switch self {
        case .f32: return 1
        case .f16: return 1
        case .q4_0: return 32
        case .q4_1: return 32
        case .q5_0: return 32
        case .q5_1: return 32
        case .q8_0: return 32
        case .q8_1: return 32
        default: return 32
        }
    }

    var typeSize: Int {
        switch self {
        case .f32: return 4
        case .f16: return 2
        case .q4_0: return 18  // 2 bytes scale + 16 bytes (32 nibbles)
        case .q4_1: return 20  // 2 bytes scale + 2 bytes min + 16 bytes
        case .q5_0: return 22
        case .q5_1: return 24
        case .q8_0: return 34  // 2 bytes scale + 32 bytes (32 int8)
        case .q8_1: return 36  // 4 bytes scale + 32 bytes
        default: return 0
        }
    }
}

// MARK: - GGUF Tensor Info

struct GGUFTensorInfo {
    let name: String
    let dimensions: [UInt64]
    let type: GGMLType
    let offset: UInt64

    var elementCount: Int {
        dimensions.reduce(1, { $0 * Int($1) })
    }

    var shape: [Int] {
        dimensions.map { Int($0) }
    }
}

// MARK: - GGUF Model Config (Qwen3.5)

struct GGUFModelConfig {
    var architecture: String = ""
    var dim: Int = 0  // embedding_length
    var hiddenDim: Int = 0  // feed_forward_length
    var nLayers: Int = 0  // block_count
    var nHeads: Int = 0  // attention.head_count
    var nKVHeads: Int = 0  // attention.head_count_kv
    var headDim: Int = 0  // computed: dim / nHeads
    var vocabSize: Int = 0
    var contextLength: Int = 0
    var ropeTheta: Float = 10000.0
    var rmsNormEps: Float = 1e-6
    var ropeDim: Int = 0  // rope.dimension_count

    // SSM (Mamba-2) parameters
    var ssmConvKernel: Int = 4
    var ssmStateSize: Int = 128
    var ssmGroupCount: Int = 16
    var ssmTimeStepRank: Int = 16
    var ssmInnerSize: Int = 2048
    var fullAttentionInterval: Int = 4  // every Nth layer is pure attention

    var keyLength: Int = 0  // total K dimension
    var valueLength: Int = 0  // total V dimension

    var kvDim: Int { nKVHeads * headDim }
    var gqaGroupSize: Int { nHeads / max(nKVHeads, 1) }

    /// Returns true if this layer is a pure attention layer (vs Mamba hybrid)
    func isFullAttentionLayer(_ layerIdx: Int) -> Bool {
        guard fullAttentionInterval > 0 else { return true }
        return (layerIdx + 1) % fullAttentionInterval == 0
    }
}

// MARK: - GGUF Loader

class GGUFLoader {
    let url: URL
    private var data: Data?
    private var mmapData: UnsafeRawPointer?
    private var fileSize: Int = 0
    private var fd: Int32 = -1

    private(set) var version: UInt32 = 0
    private(set) var tensorCount: UInt64 = 0
    private(set) var metadataKVCount: UInt64 = 0
    private(set) var metadata: [String: Any] = [:]
    private(set) var tensors: [String: GGUFTensorInfo] = [:]
    private(set) var tensorDataOffset: UInt64 = 0
    private(set) var config: GGUFModelConfig = GGUFModelConfig()

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let mmapData = mmapData {
            munmap(UnsafeMutableRawPointer(mutating: mmapData), fileSize)
        }
        if fd >= 0 {
            close(fd)
        }
    }

    // MARK: - Loading

    func load() throws {
        // Memory-map the file
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw GGUFError.cannotOpenFile(url.path)
        }

        var stat = stat()
        fstat(fd, &stat)
        fileSize = Int(stat.st_size)

        guard let mapped = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0) else {
            close(fd)
            fd = -1
            throw GGUFError.mmapFailed
        }
        mmapData = UnsafeRawPointer(mapped)

        var offset = 0

        // Parse magic
        let magic = readUInt32(at: &offset)
        guard magic == 0x4655_4747 else {  // "GGUF" in little-endian
            throw GGUFError.invalidMagic(magic)
        }

        // Version
        version = readUInt32(at: &offset)
        guard version == 3 else {
            throw GGUFError.unsupportedVersion(version)
        }

        // Counts
        tensorCount = readUInt64(at: &offset)
        metadataKVCount = readUInt64(at: &offset)

        // Parse metadata
        for _ in 0..<metadataKVCount {
            let (key, value) = try readMetadataKV(at: &offset)
            metadata[key] = value
        }

        // Parse tensor info
        for _ in 0..<tensorCount {
            let info = try readTensorInfo(at: &offset)
            tensors[info.name] = info
        }

        // Compute tensor data offset (aligned to 32 bytes)
        tensorDataOffset = UInt64((offset + 31) & ~31)

        // Extract model config from metadata
        extractConfig()
    }

    // MARK: - Tensor Data Access

    /// Get raw pointer to tensor data (zero-copy from mmap)
    func tensorData(for name: String) -> UnsafeRawPointer? {
        guard let info = tensors[name], let base = mmapData else { return nil }
        return base.advanced(by: Int(tensorDataOffset + info.offset))
    }

    /// Get tensor data as typed buffer pointer
    func tensorBuffer<T>(for name: String, as type: T.Type) -> UnsafeBufferPointer<T>? {
        guard let info = tensors[name], let ptr = tensorData(for: name) else { return nil }
        let count: Int
        switch info.type {
        case .f32: count = info.elementCount
        case .f16: count = info.elementCount
        case .q8_0: count = (info.elementCount / info.type.blockSize) * info.type.typeSize
        case .q4_0: count = (info.elementCount / info.type.blockSize) * info.type.typeSize
        default: count = info.elementCount
        }
        return UnsafeBufferPointer(start: ptr.bindMemory(to: T.self, capacity: count), count: count)
    }

    /// Get the byte size of a tensor's data
    func tensorByteSize(for name: String) -> Int {
        guard let info = tensors[name] else { return 0 }
        switch info.type {
        case .f32: return info.elementCount * 4
        case .f16: return info.elementCount * 2
        case .q8_0:
            let nBlocks = info.elementCount / info.type.blockSize
            return nBlocks * info.type.typeSize
        case .q4_0:
            let nBlocks = info.elementCount / info.type.blockSize
            return nBlocks * info.type.typeSize
        default: return info.elementCount * 4
        }
    }

    // MARK: - Private Parsing Helpers

    // All reads use memcpy to handle unaligned offsets (GGUF fields are packed)

    private func readUInt8(at offset: inout Int) -> UInt8 {
        let v = mmapData!.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return v
    }

    private func readUInt32(at offset: inout Int) -> UInt32 {
        var v: UInt32 = 0
        memcpy(&v, mmapData!.advanced(by: offset), 4)
        offset += 4
        return v
    }

    private func readInt32(at offset: inout Int) -> Int32 {
        var v: Int32 = 0
        memcpy(&v, mmapData!.advanced(by: offset), 4)
        offset += 4
        return v
    }

    private func readUInt64(at offset: inout Int) -> UInt64 {
        var v: UInt64 = 0
        memcpy(&v, mmapData!.advanced(by: offset), 8)
        offset += 8
        return v
    }

    private func readInt64(at offset: inout Int) -> Int64 {
        var v: Int64 = 0
        memcpy(&v, mmapData!.advanced(by: offset), 8)
        offset += 8
        return v
    }

    private func readFloat32(at offset: inout Int) -> Float {
        var v: Float = 0
        memcpy(&v, mmapData!.advanced(by: offset), 4)
        offset += 4
        return v
    }

    private func readFloat64(at offset: inout Int) -> Double {
        var v: Double = 0
        memcpy(&v, mmapData!.advanced(by: offset), 8)
        offset += 8
        return v
    }

    private func readBool(at offset: inout Int) -> Bool {
        let v = readUInt8(at: &offset)
        return v != 0
    }

    private func readString(at offset: inout Int) -> String {
        let len = readUInt64(at: &offset)
        let bytes = UnsafeBufferPointer(
            start: mmapData!.advanced(by: offset).bindMemory(to: UInt8.self, capacity: Int(len)),
            count: Int(len)
        )
        offset += Int(len)
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func readValue(type: GGUFType, at offset: inout Int) throws -> Any {
        switch type {
        case .uint8: return readUInt8(at: &offset)
        case .int8: return Int8(bitPattern: readUInt8(at: &offset))
        case .uint16:
            var v: UInt16 = 0
            memcpy(&v, mmapData!.advanced(by: offset), 2)
            offset += 2
            return v
        case .int16:
            var v: Int16 = 0
            memcpy(&v, mmapData!.advanced(by: offset), 2)
            offset += 2
            return v
        case .uint32: return readUInt32(at: &offset)
        case .int32: return readInt32(at: &offset)
        case .float32: return readFloat32(at: &offset)
        case .bool_: return readBool(at: &offset)
        case .string: return readString(at: &offset)
        case .array:
            let elemType = GGUFType(rawValue: readUInt32(at: &offset))!
            let count = readUInt64(at: &offset)
            var arr: [Any] = []
            for _ in 0..<count {
                try arr.append(readValue(type: elemType, at: &offset))
            }
            return arr
        case .uint64: return readUInt64(at: &offset)
        case .int64: return readInt64(at: &offset)
        case .float64: return readFloat64(at: &offset)
        }
    }

    private func readMetadataKV(at offset: inout Int) throws -> (String, Any) {
        let key = readString(at: &offset)
        let typeRaw = readUInt32(at: &offset)
        guard let type = GGUFType(rawValue: typeRaw) else {
            throw GGUFError.unknownType(typeRaw)
        }
        let value = try readValue(type: type, at: &offset)
        return (key, value)
    }

    private func readTensorInfo(at offset: inout Int) throws -> GGUFTensorInfo {
        let name = readString(at: &offset)
        let nDims = readUInt32(at: &offset)
        var dims: [UInt64] = []
        for _ in 0..<nDims {
            dims.append(readUInt64(at: &offset))
        }
        let typeRaw = readUInt32(at: &offset)
        guard let type = GGMLType(rawValue: typeRaw) else {
            throw GGUFError.unknownTensorType(typeRaw)
        }
        let dataOffset = readUInt64(at: &offset)
        return GGUFTensorInfo(name: name, dimensions: dims, type: type, offset: dataOffset)
    }

    // MARK: - Config Extraction

    private func extractConfig() {
        config.architecture = stringMeta("general.architecture") ?? ""
        let arch = config.architecture

        config.dim = intMeta("\(arch).embedding_length") ?? 0
        config.hiddenDim = intMeta("\(arch).feed_forward_length") ?? 0
        config.nLayers = intMeta("\(arch).block_count") ?? 0
        config.nHeads = intMeta("\(arch).attention.head_count") ?? 0
        config.nKVHeads = intMeta("\(arch).attention.head_count_kv") ?? config.nHeads
        config.vocabSize =
            intMeta("\(arch).vocab_size")
            ?? (metadata["tokenizer.ggml.tokens"] as? [Any])?.count
            ?? 0
        config.contextLength = intMeta("\(arch).context_length") ?? 2048
        config.ropeTheta = floatMeta("\(arch).rope.freq_base") ?? 10000.0
        config.rmsNormEps = floatMeta("\(arch).attention.layer_norm_rms_epsilon") ?? 1e-6
        config.ropeDim = intMeta("\(arch).rope.dimension_count") ?? 0

        // Attention key/value lengths
        config.keyLength = intMeta("\(arch).attention.key_length") ?? 0
        config.valueLength = intMeta("\(arch).attention.value_length") ?? 0

        // SSM (Mamba-2) parameters
        config.ssmConvKernel = intMeta("\(arch).ssm.conv_kernel") ?? 4
        config.ssmStateSize = intMeta("\(arch).ssm.state_size") ?? 128
        config.ssmGroupCount = intMeta("\(arch).ssm.group_count") ?? 16
        config.ssmTimeStepRank = intMeta("\(arch).ssm.time_step_rank") ?? 16
        config.ssmInnerSize = intMeta("\(arch).ssm.inner_size") ?? 2048
        config.fullAttentionInterval = intMeta("\(arch).full_attention_interval") ?? 4

        // Compute head_dim
        if config.nHeads > 0 {
            config.headDim = config.dim / config.nHeads
        }
        if config.ropeDim == 0 {
            config.ropeDim = config.headDim
        }
    }

    private func stringMeta(_ key: String) -> String? {
        metadata[key] as? String
    }

    private func intMeta(_ key: String) -> Int? {
        if let v = metadata[key] as? UInt32 { return Int(v) }
        if let v = metadata[key] as? Int32 { return Int(v) }
        if let v = metadata[key] as? UInt64 { return Int(v) }
        if let v = metadata[key] as? Int64 { return Int(v) }
        return nil
    }

    private func floatMeta(_ key: String) -> Float? {
        if let v = metadata[key] as? Float { return v }
        if let v = metadata[key] as? Double { return Float(v) }
        return nil
    }
}

// MARK: - Errors

enum GGUFError: LocalizedError {
    case cannotOpenFile(String)
    case mmapFailed
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt32)
    case unknownType(UInt32)
    case unknownTensorType(UInt32)
    case tensorNotFound(String)
    case unsupportedQuantization(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path): return "Cannot open GGUF file: \(path)"
        case .mmapFailed: return "Memory mapping failed"
        case .invalidMagic(let m): return "Invalid GGUF magic: \(String(format: "0x%08X", m))"
        case .unsupportedVersion(let v): return "Unsupported GGUF version: \(v)"
        case .unknownType(let t): return "Unknown metadata type: \(t)"
        case .unknownTensorType(let t): return "Unknown tensor type: \(t)"
        case .tensorNotFound(let n): return "Tensor not found: \(n)"
        case .unsupportedQuantization(let q): return "Unsupported quantization: \(q)"
        }
    }
}
