import Foundation

public enum MSPExecCommandOutputTruncation {
    public static let defaultMaxOutputTokens = 10_000

    private static let approximateBytesPerToken = 4

    public static func approximateTokenCount(_ text: String) -> Int {
        approximateTokenCount(byteCount: text.utf8.count)
    }

    public static func formattedTruncateText(
        _ text: String,
        maxOutputTokens: Int = defaultMaxOutputTokens
    ) -> String {
        let byteBudget = byteBudget(forTokens: maxOutputTokens)
        guard text.utf8.count > byteBudget else {
            return text
        }

        let truncated = truncateText(text, maxOutputTokens: maxOutputTokens)
        return "Total output lines: \(lineCount(in: text))\n\n\(truncated)"
    }

    public static func truncateText(
        _ text: String,
        maxOutputTokens: Int = defaultMaxOutputTokens
    ) -> String {
        let maxBytes = byteBudget(forTokens: maxOutputTokens)
        return truncateMiddle(text, maxBytes: maxBytes)
    }

    private static func truncateMiddle(_ text: String, maxBytes: Int) -> String {
        guard !text.isEmpty else { return "" }

        let totalBytes = text.utf8.count
        guard maxBytes > 0 else {
            return truncationMarker(removedCount: approximateTokenCount(byteCount: totalBytes))
        }
        guard totalBytes > maxBytes else { return text }

        let leftBudget = maxBytes / 2
        let rightBudget = maxBytes - leftBudget
        let prefix = prefixWithinByteBudget(text, byteBudget: leftBudget)
        let suffix = suffixWithinByteBudget(text, byteBudget: rightBudget)
        let removedBytes = max(0, totalBytes - maxBytes)
        let marker = truncationMarker(removedCount: approximateTokenCount(byteCount: removedBytes))
        return prefix + marker + suffix
    }

    private static func prefixWithinByteBudget(_ text: String, byteBudget: Int) -> String {
        guard byteBudget > 0 else { return "" }

        var bytes = 0
        var output = String()
        output.reserveCapacity(min(text.count, byteBudget))
        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            guard bytes + scalarBytes <= byteBudget else { break }
            output.unicodeScalars.append(scalar)
            bytes += scalarBytes
        }
        return output
    }

    private static func suffixWithinByteBudget(_ text: String, byteBudget: Int) -> String {
        guard byteBudget > 0 else { return "" }

        var bytes = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= byteBudget else { break }
            scalars.append(scalar)
            bytes += scalarBytes
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    private static func approximateTokenCount(byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return (byteCount + approximateBytesPerToken - 1) / approximateBytesPerToken
    }

    private static func byteBudget(forTokens tokens: Int) -> Int {
        let tokens = max(0, tokens)
        guard tokens <= Int.max / approximateBytesPerToken else {
            return Int.max
        }
        return tokens * approximateBytesPerToken
    }

    private static func truncationMarker(removedCount: Int) -> String {
        "…\(removedCount) tokens truncated…"
    }

    private static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if text.hasSuffix("\n") {
            count = max(0, count - 1)
        }
        return count
    }
}
