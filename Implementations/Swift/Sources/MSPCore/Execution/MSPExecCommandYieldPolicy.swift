public enum MSPExecCommandYieldPolicy {
    public static let defaultExecYieldTimeMilliseconds = 10_000
    public static let defaultWriteStdinYieldTimeMilliseconds = 250
    public static let defaultReadExecWaitMilliseconds = 0
    public static let minimumYieldTimeMilliseconds = 250
    public static let minimumEmptyWriteStdinYieldTimeMilliseconds = 5_000
    public static let maximumYieldTimeMilliseconds = 30_000
    public static let defaultMaximumBackgroundPollYieldTimeMilliseconds = 300_000

    public static func execMilliseconds(_ requested: Int?) -> Int {
        clamp(
            requested ?? defaultExecYieldTimeMilliseconds,
            lowerBound: minimumYieldTimeMilliseconds,
            upperBound: maximumYieldTimeMilliseconds
        )
    }

    public static func writeStdinMilliseconds(
        _ requested: Int?,
        chars: String,
        maximumBackgroundPollMilliseconds: Int = defaultMaximumBackgroundPollYieldTimeMilliseconds
    ) -> Int {
        writeStdinMilliseconds(
            requested,
            isEmpty: chars.isEmpty,
            maximumBackgroundPollMilliseconds: maximumBackgroundPollMilliseconds
        )
    }

    public static func writeStdinMilliseconds(
        _ requested: Int?,
        isEmpty: Bool,
        maximumBackgroundPollMilliseconds: Int = defaultMaximumBackgroundPollYieldTimeMilliseconds
    ) -> Int {
        let requestedOrDefault = requested ?? defaultWriteStdinYieldTimeMilliseconds
        let atLeastMinimum = max(requestedOrDefault, minimumYieldTimeMilliseconds)
        if isEmpty {
            return clamp(
                atLeastMinimum,
                lowerBound: minimumEmptyWriteStdinYieldTimeMilliseconds,
                upperBound: max(
                    maximumBackgroundPollMilliseconds,
                    minimumEmptyWriteStdinYieldTimeMilliseconds
                )
            )
        }
        return min(atLeastMinimum, maximumYieldTimeMilliseconds)
    }

    public static func readExecMilliseconds(
        _ requested: Int?,
        maximumBackgroundPollMilliseconds: Int = defaultMaximumBackgroundPollYieldTimeMilliseconds
    ) -> Int {
        clamp(
            requested ?? defaultReadExecWaitMilliseconds,
            lowerBound: 0,
            upperBound: max(maximumBackgroundPollMilliseconds, 0)
        )
    }

    private static func clamp(
        _ value: Int,
        lowerBound: Int,
        upperBound: Int
    ) -> Int {
        min(max(value, lowerBound), upperBound)
    }
}
