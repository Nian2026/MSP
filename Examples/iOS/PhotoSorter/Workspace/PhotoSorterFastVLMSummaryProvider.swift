import CoreImage
import Foundation

#if canImport(MLX) && canImport(MLXLMCommon) && canImport(MLXVLM)
import MLX
import MLXLMCommon
import MLXVLM
#endif

final class PhotoSorterFastVLMInferenceGate: @unchecked Sendable {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var isRunning = false
    private var waiters: [Waiter] = []

    func run<T>(
        operation: () async throws -> T
    ) async throws -> T {
        let permitID = try await acquire()
        defer {
            release(permitID)
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws -> UUID {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard isRunning else {
                    isRunning = true
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter(id: id)
        }
        return id
    }

    private func release(_ id: UUID) {
        let nextContinuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if waiters.isEmpty {
            isRunning = false
            nextContinuation = nil
        } else {
            nextContinuation = waiters.removeFirst().continuation
        }
        lock.unlock()
        nextContinuation?.resume()
    }

    private func cancelWaiter(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            continuation = waiters.remove(at: index).continuation
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

protocol PhotoSorterFastVLMSummaryProviding: Sendable {
    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus
    func summarize(
        image: CIImage,
        modelBundle: PhotoSorterFastVLMModelBundle
    ) async throws -> String
}

enum PhotoSorterDefaultFastVLMSummaryProviderFactory {
    static func make() -> any PhotoSorterFastVLMSummaryProviding {
#if canImport(MLX) && canImport(MLXLMCommon) && canImport(MLXVLM)
        return PhotoSorterFastVLMLocalSummaryProvider.shared
#else
        return PhotoSorterUnavailableFastVLMSummaryProvider()
#endif
    }
}

struct PhotoSorterUnavailableFastVLMSummaryProvider: PhotoSorterFastVLMSummaryProviding {
    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        PhotoSorterMediaVLMConfiguration.bundledFastVLMProviderStatus(
            modelBundle: modelBundle
        )
    }

    func summarize(
        image: CIImage,
        modelBundle: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        let status = status(for: modelBundle)
        throw PhotoSorterMediaVLMError.unavailable(
            status.reason ?? "local FastVLM inference runtime is unavailable"
        )
    }
}

#if canImport(MLX) && canImport(MLXLMCommon) && canImport(MLXVLM)
final class PhotoSorterFastVLMLocalSummaryProvider: @unchecked Sendable, PhotoSorterFastVLMSummaryProviding {
    static let shared = PhotoSorterFastVLMLocalSummaryProvider()

    private let lock = NSLock()
    private let inferenceGate = PhotoSorterFastVLMInferenceGate()
    private var didRegisterFastVLM = false
    private var runningCount = 0
    private var loadedContainers: [String: ModelContainer] = [:]

    private init() {}

    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        guard modelBundle.isInstalled else {
            return PhotoSorterMediaVLMConfiguration.bundledFastVLMProviderStatus(
                modelBundle: modelBundle
            )
        }
        if let unsupportedReason = Self.unsupportedRuntimeReason {
            return PhotoSorterMediaVLMProviderStatus(
                kind: PhotoSorterMediaVLMConfiguration.providerKind,
                backend: PhotoSorterMediaVLMConfiguration.backend,
                modelID: PhotoSorterMediaVLMConfiguration.modelID,
                modelVersion: PhotoSorterMediaVLMConfiguration.modelVersion,
                modelState: .unavailable,
                isLiveSummarizationAvailable: false,
                processorConfigFingerprint: modelBundle.processorConfigFingerprint,
                reason: unsupportedReason
            )
        }
        let isRunning = lock.withLock {
            runningCount > 0
        }
        return PhotoSorterMediaVLMProviderStatus(
            kind: PhotoSorterMediaVLMConfiguration.providerKind,
            backend: PhotoSorterMediaVLMConfiguration.backend,
            modelID: PhotoSorterMediaVLMConfiguration.modelID,
            modelVersion: PhotoSorterMediaVLMConfiguration.modelVersion,
            modelState: isRunning ? .running : .installed,
            isLiveSummarizationAvailable: true,
            processorConfigFingerprint: modelBundle.processorConfigFingerprint,
            reason: nil
        )
    }

    func summarize(
        image: CIImage,
        modelBundle: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        guard modelBundle.isInstalled else {
            throw PhotoSorterMediaVLMError.unavailable(
                modelBundle.reason ?? "local FastVLM model is not installed"
            )
        }
        if let unsupportedReason = Self.unsupportedRuntimeReason {
            throw PhotoSorterMediaVLMError.unavailable(unsupportedReason)
        }
        enterRunning()
        defer {
            leaveRunning()
        }

        return try await inferenceGate.run {
            PhotoSorterMLXRuntimeErrorState.installRecoveringErrorHandler()
            PhotoSorterMLXRuntimeErrorState.clear()
#if !targetEnvironment(simulator)
            MLX.GPU.clearCache()
            defer {
                MLX.GPU.clearCache()
            }
#endif
            do {
                let container = try await loadContainer(modelBundle: modelBundle)
                let userInput = UserInput(
                    prompt: .text(PhotoSorterMediaVLMConfiguration.prompt),
                    images: [.ciImage(image)]
                )
                let output = try await container.perform { context in
                    let input = try await context.processor.prepare(input: userInput)
                    let result = try MLXLMCommon.generate(
                        input: input,
                        parameters: GenerateParameters(temperature: 0.0),
                        context: context
                    ) { tokens in
                        tokens.count >= 96 ? .stop : .more
                    }
                    return result.output
                }
                try PhotoSorterMLXRuntimeErrorState.throwIfPresent()
                return PhotoSorterMediaVLMConfiguration.normalizedSummaryOutput(output)
            } catch {
                if let mlxError = PhotoSorterMLXRuntimeErrorState.consume() {
                    throw PhotoSorterMediaVLMError.unavailable(mlxError)
                }
                throw error
            }
        }
    }

    private func loadContainer(
        modelBundle: PhotoSorterFastVLMModelBundle
    ) async throws -> ModelContainer {
        let cacheKey = [
            modelBundle.directoryPath,
            modelBundle.processorConfigFingerprint
        ].joined(separator: "|")
        if let loaded = lock.withLock({ loadedContainers[cacheKey] }) {
            return loaded
        }

        registerFastVLMIfNeeded()
#if !targetEnvironment(simulator)
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
#endif
        let configuration = ModelConfiguration(
            directory: URL(fileURLWithPath: modelBundle.directoryPath, isDirectory: true)
        )
        let container = try await VLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { _ in
        }
        lock.withLock {
            loadedContainers[cacheKey] = container
        }
        return container
    }

    private func registerFastVLMIfNeeded() {
        lock.withLock {
            guard !didRegisterFastVLM else {
                return
            }
            FastVLM.register(modelFactory: VLMModelFactory.shared)
            didRegisterFastVLM = true
        }
    }

    private static var unsupportedRuntimeReason: String? {
#if targetEnvironment(simulator)
        return "local FastVLM live inference is unavailable in iOS Simulator because MLX Metal aborts during device initialization; run on a physical device for live VLM"
#else
        guard mlxMetalLibraryIsBundled else {
            return "local FastVLM live inference is unavailable because MLX Metal library default.metallib is not bundled in this runtime"
        }
        return nil
#endif
    }

    private static var mlxMetalLibraryIsBundled: Bool {
        let fileManager = FileManager.default
        let baseURLs = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: PhotoSorterFastVLMLocalSummaryProvider.self).resourceURL,
            Bundle(for: PhotoSorterFastVLMLocalSummaryProvider.self).bundleURL,
            executableDirectoryURL()
        ].compactMap(\.self)

        return baseURLs.contains { baseURL in
            let directURL = baseURL
                .appendingPathComponent("mlx-swift_Cmlx.bundle", isDirectory: true)
                .appendingPathComponent("default.metallib")
            if fileManager.fileExists(atPath: directURL.path) {
                return true
            }

            let resourcesURL = baseURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("mlx-swift_Cmlx.bundle", isDirectory: true)
                .appendingPathComponent("default.metallib")
            return fileManager.fileExists(atPath: resourcesURL.path)
        }
    }

    private static func executableDirectoryURL() -> URL? {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    }

    private func enterRunning() {
        lock.withLock {
            runningCount += 1
        }
    }

    private func leaveRunning() {
        lock.withLock {
            runningCount = max(0, runningCount - 1)
        }
    }
}

private struct PhotoSorterMLXRuntimeError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private enum PhotoSorterMLXRuntimeErrorState {
    static func installRecoveringErrorHandler() {
        PhotoSorterMLXRuntimeErrorStorage.shared.install()
    }

    static func clear() {
        PhotoSorterMLXRuntimeErrorStorage.shared.clear()
    }

    static func consume() -> String? {
        PhotoSorterMLXRuntimeErrorStorage.shared.consume()
    }

    static func throwIfPresent() throws {
        if let message = consume() {
            throw PhotoSorterMLXRuntimeError(message: message)
        }
    }
}

private typealias PhotoSorterMLXErrorHandler = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void

private typealias PhotoSorterMLXErrorHandlerDestructor = @convention(c) (
    UnsafeMutableRawPointer?
) -> Void

@_silgen_name("mlx_set_error_handler")
private func photoSorterMLXSetErrorHandler(
    _ handler: PhotoSorterMLXErrorHandler?,
    _ data: UnsafeMutableRawPointer?,
    _ destructor: PhotoSorterMLXErrorHandlerDestructor?
)

private final class PhotoSorterMLXRuntimeErrorStorage: @unchecked Sendable {
    static let shared = PhotoSorterMLXRuntimeErrorStorage()

    private let lock = NSLock()
    private var isInstalled = false
    private var pendingMessages: [String] = []

    func install() {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !isInstalled else {
            return
        }
        photoSorterMLXSetErrorHandler(photoSorterRecoveringMLXErrorHandler, nil, nil)
        isInstalled = true
    }

    func record(_ message: String) {
        lock.lock()
        pendingMessages.append(message)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        pendingMessages.removeAll()
        lock.unlock()
    }

    func consume() -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !pendingMessages.isEmpty else {
            return nil
        }
        let message = pendingMessages.joined(separator: "\n")
        pendingMessages.removeAll()
        return message
    }
}

private func photoSorterRecoveringMLXErrorHandler(
    _ message: UnsafePointer<CChar>?,
    _ data: UnsafeMutableRawPointer?
) {
    let text = message.map { String(cString: $0) } ?? "unknown MLX runtime error"
    PhotoSorterMLXRuntimeErrorStorage.shared.record(text)
}
#endif
