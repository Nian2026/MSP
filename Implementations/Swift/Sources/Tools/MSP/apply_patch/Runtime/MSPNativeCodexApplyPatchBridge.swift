import Darwin
import Foundation

public typealias MSPNativeCodexApplyPatchJSONFunction = @Sendable (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?
) -> Int32

public typealias MSPNativeCodexApplyPatchFreeFunction = @Sendable (
    UnsafeMutablePointer<UInt8>?,
    Int
) -> Void

private typealias MSPNativeCodexApplyPatchJSONCFunction = @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?
) -> Int32

private typealias MSPNativeCodexApplyPatchFreeCFunction = @convention(c) (
    UnsafeMutablePointer<UInt8>?,
    Int
) -> Void

public enum MSPNativeCodexApplyPatchBridgeError: Error, LocalizedError, Sendable {
    case libraryUnavailable(String)
    case symbolUnavailable(String)
    case callFailed(Int32)
    case responsePointerMissing
    case responseUTF8Invalid

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let message):
            "apply_patch native library is unavailable: \(message)"
        case .symbolUnavailable(let symbol):
            "apply_patch native symbol is unavailable: \(symbol)"
        case .callFailed(let status):
            "apply_patch native bridge call failed with status \(status)"
        case .responsePointerMissing:
            "apply_patch native bridge returned a null response pointer"
        case .responseUTF8Invalid:
            "apply_patch native bridge response is not valid UTF-8"
        }
    }
}

public final class MSPNativeCodexApplyPatchBridge: MSPCodexApplyPatchBridge, @unchecked Sendable {
    public static let applyPatchSymbol = "msp_codex_apply_patch_json"
    public static let freeSymbol = "msp_codex_apply_patch_free"

    private let handle: UnsafeMutableRawPointer?
    private let applyPatchJSON: MSPNativeCodexApplyPatchJSONFunction
    private let freeBuffer: MSPNativeCodexApplyPatchFreeFunction
    private let shouldCloseHandle: Bool

    public convenience init() throws {
        try self.init(libraryPath: nil)
    }

    public init(libraryPath: String?) throws {
        let loadedHandle: UnsafeMutableRawPointer?
        if let libraryPath {
            loadedHandle = libraryPath.withCString { path in
                dlopen(path, RTLD_NOW | RTLD_LOCAL)
            }
        } else {
            loadedHandle = dlopen(nil, RTLD_NOW)
        }
        guard let loadedHandle else {
            throw MSPNativeCodexApplyPatchBridgeError.libraryUnavailable(Self.dlerrorMessage())
        }
        guard let applyPatchSymbol = dlsym(loadedHandle, Self.applyPatchSymbol) else {
            if libraryPath != nil {
                dlclose(loadedHandle)
            }
            throw MSPNativeCodexApplyPatchBridgeError.symbolUnavailable(Self.applyPatchSymbol)
        }
        guard let freeSymbol = dlsym(loadedHandle, Self.freeSymbol) else {
            if libraryPath != nil {
                dlclose(loadedHandle)
            }
            throw MSPNativeCodexApplyPatchBridgeError.symbolUnavailable(Self.freeSymbol)
        }
        handle = loadedHandle
        let cApplyPatchJSON = unsafeBitCast(
            applyPatchSymbol,
            to: MSPNativeCodexApplyPatchJSONCFunction.self
        )
        let cFreeBuffer = unsafeBitCast(
            freeSymbol,
            to: MSPNativeCodexApplyPatchFreeCFunction.self
        )
        applyPatchJSON = { @Sendable inputPointer, inputLength, outputPointer, outputLength in
            cApplyPatchJSON(
                inputPointer,
                inputLength,
                outputPointer,
                outputLength
            )
        }
        freeBuffer = { @Sendable pointer, length in
            cFreeBuffer(pointer, length)
        }
        shouldCloseHandle = libraryPath != nil
    }

    public init(
        applyPatchJSON: @escaping MSPNativeCodexApplyPatchJSONFunction,
        freeBuffer: @escaping MSPNativeCodexApplyPatchFreeFunction
    ) {
        handle = nil
        self.applyPatchJSON = applyPatchJSON
        self.freeBuffer = freeBuffer
        shouldCloseHandle = false
    }

    deinit {
        if shouldCloseHandle, let handle {
            dlclose(handle)
        }
    }

    public func applyPatch(requestJSON: String) async throws -> String {
        let requestBytes = Array(requestJSON.utf8)
        var responsePointer: UnsafeMutablePointer<UInt8>?
        var responseLength = 0
        let status = requestBytes.withUnsafeBufferPointer { requestBuffer in
            applyPatchJSON(
                requestBuffer.baseAddress,
                requestBuffer.count,
                &responsePointer,
                &responseLength
            )
        }
        defer {
            if responsePointer != nil {
                freeBuffer(responsePointer, responseLength)
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

    private static func dlerrorMessage() -> String {
        guard let message = dlerror() else {
            return "unknown dlopen/dlsym error"
        }
        return String(cString: message)
    }
}
