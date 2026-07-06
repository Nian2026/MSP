import CoreImage
import Foundation
import XCTest
@testable import PhotoSorter

final class PhotoSorterFastVLMLiveTests: XCTestCase {
    func testFastVLMInferenceGateRunsOperationsSerially() async throws {
        let gate = PhotoSorterFastVLMInferenceGate()
        let probe = PhotoSorterFastVLMInferenceGateProbe()
        let firstEntered = PhotoSorterAsyncTestSignal()
        let releaseFirst = PhotoSorterAsyncTestSignal()

        let firstTask = Task {
            try await gate.run {
                await probe.enter("first")
                await firstEntered.signal()
                await releaseFirst.wait()
                await probe.leave()
                return "first"
            }
        }

        await firstEntered.wait()

        let secondTask = Task {
            try await gate.run {
                await probe.enter("second")
                await probe.leave()
                return "second"
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let didEnterSecondBeforeRelease = await probe.didEnter("second")
        let maximumActiveCountBeforeRelease = await probe.maximumActiveCount()
        XCTAssertFalse(didEnterSecondBeforeRelease)
        XCTAssertEqual(maximumActiveCountBeforeRelease, 1)

        await releaseFirst.signal()

        let first = try await firstTask.value
        let second = try await secondTask.value
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
        let didEnterSecondAfterRelease = await probe.didEnter("second")
        let maximumActiveCountAfterRelease = await probe.maximumActiveCount()
        XCTAssertTrue(didEnterSecondAfterRelease)
        XCTAssertEqual(maximumActiveCountAfterRelease, 1)
    }

    func testBundledFastVLMSummarizesGeneratedImageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOSORTER_RUN_FASTVLM_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set PHOTOSORTER_RUN_FASTVLM_LIVE_TEST=1 to run the local FastVLM live inference test.")
        }

        let modelDirectoryURL = try Self.modelDirectoryURL()
        let modelBundle = PhotoSorterFastVLMModelBundle.discover(directoryURL: modelDirectoryURL)
        XCTAssertTrue(modelBundle.isInstalled, modelBundle.reason ?? "FastVLM model bundle is not installed")

        let provider = PhotoSorterDefaultFastVLMSummaryProviderFactory.make()
        let status = provider.status(for: modelBundle)
        guard status.isLiveSummarizationAvailable else {
            throw XCTSkip(status.reason ?? "FastVLM live provider is unavailable in this test environment.")
        }

        let image = CIImage(color: CIColor(red: 0.95, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let startedAt = Date()
        let summary = try await provider.summarize(
            image: image,
            modelBundle: modelBundle
        )
        let duration = Date().timeIntervalSince(startedAt)

        XCTAssertFalse(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("FastVLM live summary duration=\(duration) summary=\(summary)")
        await MainActor.run {
            XCTContext.runActivity(named: "FastVLM summary") { activity in
                activity.add(XCTAttachment(string: "duration=\(duration)\nsummary=\(summary)"))
            }
        }
    }

    func testBundledFastVLMSummarizesImageDirectoryWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHOTOSORTER_RUN_FASTVLM_IMAGE_DIR_TEST"] == "1" else {
            throw XCTSkip("Set PHOTOSORTER_RUN_FASTVLM_IMAGE_DIR_TEST=1 to run the local FastVLM image-directory test.")
        }
        guard let imageDirectoryPath = environment["PHOTOSORTER_FASTVLM_IMAGE_DIR"],
              !imageDirectoryPath.isEmpty
        else {
            throw XCTSkip("Set PHOTOSORTER_FASTVLM_IMAGE_DIR to a directory containing local images.")
        }

        let modelDirectoryURL = try Self.modelDirectoryURL()
        let modelBundle = PhotoSorterFastVLMModelBundle.discover(directoryURL: modelDirectoryURL)
        XCTAssertTrue(modelBundle.isInstalled, modelBundle.reason ?? "FastVLM model bundle is not installed")

        let provider = PhotoSorterDefaultFastVLMSummaryProviderFactory.make()
        let status = provider.status(for: modelBundle)
        guard status.isLiveSummarizationAvailable else {
            throw XCTSkip(status.reason ?? "FastVLM live provider is unavailable in this test environment.")
        }

        let limit = Self.imageDirectoryLimit(from: environment)
        let imageURLs = try Self.imageURLs(
            in: URL(fileURLWithPath: imageDirectoryPath, isDirectory: true),
            limit: limit
        )
        XCTAssertFalse(imageURLs.isEmpty, "No readable image files found in \(imageDirectoryPath)")

        var lines: [String] = []
        var durations: [TimeInterval] = []
        let suiteStartedAt = Date()
        for (index, imageURL) in imageURLs.enumerated() {
            guard let image = CIImage(contentsOf: imageURL) else {
                XCTFail("Unable to load image: \(imageURL.path)")
                continue
            }
            let startedAt = Date()
            let summary = try await provider.summarize(
                image: image,
                modelBundle: modelBundle
            )
            let duration = Date().timeIntervalSince(startedAt)
            durations.append(duration)
            let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(normalizedSummary.isEmpty)
            XCTAssertLessThanOrEqual(
                normalizedSummary.count,
                PhotoSorterMediaVLMConfiguration.maximumSummaryCharacterCount
            )
            let line = [
                "#\(index + 1)",
                imageURL.lastPathComponent,
                "\(Int(image.extent.width))x\(Int(image.extent.height))",
                String(format: "%.3fs", duration),
                normalizedSummary
            ].joined(separator: "\t")
            lines.append(line)
            print("FastVLM image summary \(line)")
        }

        let totalDuration = Date().timeIntervalSince(suiteStartedAt)
        let averageDuration = durations.isEmpty
            ? 0
            : durations.reduce(0, +) / Double(durations.count)
        let report = """
        count=\(durations.count)
        totalDuration=\(String(format: "%.3fs", totalDuration))
        averageDuration=\(String(format: "%.3fs", averageDuration))
        \(lines.joined(separator: "\n"))
        """
        if let reportPath = environment["PHOTOSORTER_FASTVLM_REPORT_PATH"],
           !reportPath.isEmpty {
            try report.write(
                to: URL(fileURLWithPath: reportPath),
                atomically: true,
                encoding: .utf8
            )
        }
        print("FastVLM image-directory summary\n\(report)")
        await MainActor.run {
            XCTContext.runActivity(named: "FastVLM image-directory summary") { activity in
                activity.add(XCTAttachment(string: report))
            }
        }
    }

    private static func modelDirectoryURL() throws -> URL {
        if let explicitPath = ProcessInfo.processInfo.environment["PHOTOSORTER_FASTVLM_MODEL_DIR"],
           !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath, isDirectory: true)
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("FastVLM", isDirectory: true)
            .appendingPathComponent("model", isDirectory: true)
    }

    private static func imageDirectoryLimit(from environment: [String: String]) -> Int {
        guard let rawValue = environment["PHOTOSORTER_FASTVLM_IMAGE_LIMIT"],
              let parsedValue = Int(rawValue)
        else {
            return 20
        }
        return min(max(parsedValue, 1), 50)
    }

    private static func imageURLs(in directoryURL: URL, limit: Int) throws -> [URL] {
        let supportedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png", "webp"]
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map(\.self)
    }
}

private actor PhotoSorterAsyncTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignaled else {
            return
        }
        isSignaled = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignaled else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor PhotoSorterFastVLMInferenceGateProbe {
    private var activeCount = 0
    private var maxActiveCount = 0
    private var enteredNames: [String] = []

    func enter(_ name: String) {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
        enteredNames.append(name)
    }

    func leave() {
        activeCount = max(0, activeCount - 1)
    }

    func didEnter(_ name: String) -> Bool {
        enteredNames.contains(name)
    }

    func maximumActiveCount() -> Int {
        maxActiveCount
    }
}
