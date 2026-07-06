import Foundation
import MSPAgentBridge

struct MSPTerminalOutputPreview: Equatable {
    static let defaultMaximumVisibleBytes = 96 * 1024

    private let maximumVisibleBytes: Int
    private var visibleText: String
    private var hiddenByteCount: Int

    init(maximumVisibleBytes: Int = Self.defaultMaximumVisibleBytes) {
        self.maximumVisibleBytes = max(0, maximumVisibleBytes)
        self.visibleText = ""
        self.hiddenByteCount = 0
    }

    init(
        text: String,
        maximumVisibleBytes: Int = Self.defaultMaximumVisibleBytes
    ) {
        self.maximumVisibleBytes = max(0, maximumVisibleBytes)
        let normalizedText = MSPTerminalDisplayNormalizer.normalize(text)
        let byteCount = normalizedText.utf8.count
        guard byteCount > self.maximumVisibleBytes else {
            self.visibleText = normalizedText
            self.hiddenByteCount = 0
            return
        }

        let suffix = Self.suffixWithinByteBudget(
            normalizedText,
            byteBudget: self.maximumVisibleBytes
        )
        self.visibleText = suffix
        self.hiddenByteCount = byteCount - suffix.utf8.count
    }

    var displayText: String {
        guard hiddenByteCount > 0 else {
            return visibleText
        }
        return "...\(hiddenByteCount) bytes truncated...\n" + visibleText
    }

    @discardableResult
    mutating func append(_ text: String) -> String {
        guard !text.isEmpty else {
            return displayText
        }
        let normalizedText = MSPTerminalDisplayNormalizer.normalize(visibleText + text)
        let incomingByteCount = normalizedText.utf8.count
        if incomingByteCount >= maximumVisibleBytes {
            let suffix = Self.suffixWithinByteBudget(
                normalizedText,
                byteBudget: maximumVisibleBytes
            )
            hiddenByteCount += incomingByteCount - suffix.utf8.count
            visibleText = suffix
            return displayText
        }

        visibleText = normalizedText
        trimToVisibleByteBudget()
        return displayText
    }

    private mutating func trimToVisibleByteBudget() {
        let currentByteCount = visibleText.utf8.count
        guard currentByteCount > maximumVisibleBytes else {
            return
        }

        let suffix = Self.suffixWithinByteBudget(
            visibleText,
            byteBudget: maximumVisibleBytes
        )
        hiddenByteCount += currentByteCount - suffix.utf8.count
        visibleText = suffix
    }

    private static func suffixWithinByteBudget(
        _ text: String,
        byteBudget: Int
    ) -> String {
        guard byteBudget > 0 else {
            return ""
        }

        var bytes = 0
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(min(text.unicodeScalars.count, byteBudget))
        for scalar in text.unicodeScalars.reversed() {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= byteBudget else {
                break
            }
            scalars.append(scalar)
            bytes += scalarBytes
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }
}
