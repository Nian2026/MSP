import Foundation
import MSPAgentBridge

#if os(iOS)
import MSPCodexApplyPatchBridge
#endif

public enum MSPCodexApplyPatchRuntimeError: Error, LocalizedError, Sendable {
    case linkedRuntimeUnavailable

    public var errorDescription: String? {
        switch self {
        case .linkedRuntimeUnavailable:
            "Codex apply_patch linked runtime is only available when the native artifact is linked for this platform"
        }
    }
}

public enum MSPCodexApplyPatchRuntime {
    public static var isLinkedRuntimeAvailable: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    public static func makeLinkedExecutor(
        workspaceRoot: String,
        cwd: String = "/",
        hostPathRedactions: [String] = []
    ) throws -> MSPCodexApplyPatchExecutor {
        #if os(iOS)
        return MSPCodexApplyPatchExecutor(
            bridge: MSPLinkedCodexApplyPatchBridge(),
            workspaceRoot: workspaceRoot,
            cwd: cwd,
            hostPathRedactions: hostPathRedactions
        )
        #else
        throw MSPCodexApplyPatchRuntimeError.linkedRuntimeUnavailable
        #endif
    }

    public static func makeExecutor(
        workspaceRoot: String,
        cwd: String = "/",
        hostPathRedactions: [String] = []
    ) throws -> MSPCodexApplyPatchExecutor {
        try makeLinkedExecutor(
            workspaceRoot: workspaceRoot,
            cwd: cwd,
            hostPathRedactions: hostPathRedactions
        )
    }

    public static func makeDynamicLibraryExecutor(
        libraryPath: String? = nil,
        workspaceRoot: String,
        cwd: String = "/",
        hostPathRedactions: [String] = []
    ) throws -> MSPCodexApplyPatchExecutor {
        let bridge = try MSPNativeCodexApplyPatchBridge(libraryPath: libraryPath)
        return MSPCodexApplyPatchExecutor(
            bridge: bridge,
            workspaceRoot: workspaceRoot,
            cwd: cwd,
            hostPathRedactions: hostPathRedactions
        )
    }
}

#if os(iOS)
public final class MSPLinkedCodexApplyPatchBridge: MSPCodexApplyPatchBridge, @unchecked Sendable {
    public init() {}

    public func applyPatch(requestJSON: String) async throws -> String {
        let requestBytes = Array(requestJSON.utf8)
        var responsePointer: UnsafeMutablePointer<UInt8>?
        var responseLength = 0
        let status = requestBytes.withUnsafeBufferPointer { requestBuffer in
            msp_codex_apply_patch_json(
                requestBuffer.baseAddress,
                requestBuffer.count,
                &responsePointer,
                &responseLength
            )
        }
        defer {
            if responsePointer != nil {
                msp_codex_apply_patch_free(responsePointer, responseLength)
            }
        }
        guard status == 0 else {
            throw MSPNativeCodexApplyPatchBridgeError.callFailed(status)
        }
        guard let responsePointer else {
            throw MSPNativeCodexApplyPatchBridgeError.responsePointerMissing
        }
        let responseData = Data(bytes: responsePointer, count: responseLength)
        guard let response = String(data: responseData, encoding: .utf8) else {
            throw MSPNativeCodexApplyPatchBridgeError.responseUTF8Invalid
        }
        return response
    }
}
#endif
