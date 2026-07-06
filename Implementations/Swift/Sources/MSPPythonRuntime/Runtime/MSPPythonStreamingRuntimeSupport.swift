import Foundation
import MSPCore

public enum MSPPythonStreamingRuntimeSupport {
    public static func contextByBufferingStandardInputStream(
        _ context: MSPCommandContext,
        chunkSize: Int = 32 * 1024
    ) async throws -> MSPCommandContext {
        guard let inputStream = context.standardInputStream else {
            return context
        }
        var bufferedContext = context
        var standardInput = Data()
        while let chunk = try await inputStream.read(maxBytes: chunkSize) {
            standardInput.append(chunk)
        }
        bufferedContext.standardInput = standardInput
        bufferedContext.standardInputStream = nil
        return bufferedContext
    }
}

public typealias MSPPythonStreamingOutputSanitizer = MSPStreamingOutputSanitizer
