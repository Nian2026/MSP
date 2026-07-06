import Foundation

#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
enum ModelShellProxyPTYSuppressedOutput {
    static func removingSuppressedPrefix(
        _ prefix: Data,
        from data: Data
    ) -> (visibleData: Data, remainingPrefix: Data) {
        if prefix.count <= 64, let range = data.range(of: prefix) {
            var visible = data
            visible.removeSubrange(range)
            return (visible, Data())
        }
        if data.starts(with: prefix) {
            return (data.dropFirst(prefix.count), Data())
        }
        if prefix.starts(with: data) {
            return (Data(), prefix.dropFirst(data.count))
        }
        if let suffix = leadingSuppressedSuffixLength(prefix, in: data) {
            return (data.dropFirst(suffix), Data())
        }
        if let split = trailingSuppressedPrefixLength(prefix, in: data) {
            if prefix.count > 64, split < data.count {
                return (data, Data())
            }
            let visible = data.dropLast(split)
            let remaining = prefix.dropFirst(split)
            return (visible, remaining)
        }
        if prefix.count > 64 {
            return (data, Data())
        }
        return (data, prefix)
    }

    private static func leadingSuppressedSuffixLength(
        _ prefix: Data,
        in data: Data
    ) -> Int? {
        guard prefix.count > 64, data.count >= 16 else {
            return nil
        }
        let maxLength = min(prefix.count, data.count)
        for length in stride(from: maxLength, through: 16, by: -1) {
            if data.prefix(length).elementsEqual(prefix.suffix(length)) {
                return length
            }
        }
        return nil
    }

    private static func trailingSuppressedPrefixLength(
        _ prefix: Data,
        in data: Data
    ) -> Int? {
        guard !prefix.isEmpty, !data.isEmpty else {
            return nil
        }
        let maxLength = min(prefix.count - 1, data.count)
        guard maxLength > 0 else {
            return nil
        }
        for length in stride(from: maxLength, through: 1, by: -1) {
            if data.suffix(length).elementsEqual(prefix.prefix(length)) {
                return length
            }
        }
        return nil
    }
}
#endif
