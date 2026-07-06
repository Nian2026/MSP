import Foundation

struct MSPShellLimits: Hashable, Sendable {
    var timeout: TimeInterval
    var maxOutputBytes: Int
    var maxPipelineBytes: Int
    var maxInterpreterMirrorBytes: Int64
    var maxExternalBinaryInputBytes: Int64
    var maxCommandCount: Int
    var maxLoopIterations: Int
    var maxFunctionDepth: Int
    var maxTemporaryBytes: Int64
    var maxExternalBinaryTemporaryBytes: Int64
    var maxInputBytes: Int
    var maxSubstitutionDepth: Int
    var maxParserTokens: Int
    var maxParserOperations: Int
    var maxParserDepth: Int
    var maxStaticCommandNodes: Int
    var maxStaticLoopDepth: Int
    var maxGeneratedRecords: Int
    var maxSubcommandArgumentBytes: Int
    var maxFileDescriptors: Int

    init(
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 256 * 1024,
        maxPipelineBytes: Int = 8 * 1024 * 1024,
        maxInterpreterMirrorBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maxExternalBinaryInputBytes: Int64 = 64 * 1024 * 1024 * 1024,
        maxCommandCount: Int = 10_000,
        maxLoopIterations: Int = 100_000,
        maxFunctionDepth: Int = 128,
        maxTemporaryBytes: Int64 = 512 * 1024 * 1024,
        maxExternalBinaryTemporaryBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxInputBytes: Int = 10 * 1024 * 1024,
        maxSubstitutionDepth: Int = 32,
        maxParserTokens: Int = 100_000,
        maxParserOperations: Int = 500_000,
        maxParserDepth: Int = 100,
        maxStaticCommandNodes: Int = 50_000,
        maxStaticLoopDepth: Int = 32,
        maxGeneratedRecords: Int = 1_000_000,
        maxSubcommandArgumentBytes: Int = 128 * 1024,
        maxFileDescriptors: Int = 1024
    ) {
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.maxPipelineBytes = max(maxOutputBytes, maxPipelineBytes)
        self.maxInterpreterMirrorBytes = maxInterpreterMirrorBytes
        self.maxExternalBinaryInputBytes = maxExternalBinaryInputBytes
        self.maxCommandCount = maxCommandCount
        self.maxLoopIterations = maxLoopIterations
        self.maxFunctionDepth = maxFunctionDepth
        self.maxTemporaryBytes = maxTemporaryBytes
        self.maxExternalBinaryTemporaryBytes = maxExternalBinaryTemporaryBytes
        self.maxInputBytes = maxInputBytes
        self.maxSubstitutionDepth = maxSubstitutionDepth
        self.maxParserTokens = maxParserTokens
        self.maxParserOperations = maxParserOperations
        self.maxParserDepth = maxParserDepth
        self.maxStaticCommandNodes = maxStaticCommandNodes
        self.maxStaticLoopDepth = maxStaticLoopDepth
        self.maxGeneratedRecords = maxGeneratedRecords
        self.maxSubcommandArgumentBytes = maxSubcommandArgumentBytes
        self.maxFileDescriptors = maxFileDescriptors
    }
}
