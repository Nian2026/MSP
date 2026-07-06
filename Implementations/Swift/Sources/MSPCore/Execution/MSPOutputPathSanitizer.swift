import Foundation

public struct MSPOutputPathSanitizer: Sendable {
    public struct Mapping: Sendable, Equatable {
        public var realPath: String
        public var virtualPath: String

        public init(realPath: String, virtualPath: String) {
            self.realPath = realPath
            self.virtualPath = MSPWorkspacePathResolver.normalize(virtualPath)
        }
    }

    public var mappings: [Mapping]
    private var replacements: [Replacement]

    public init(mappings: [Mapping]) {
        let normalizedMappings = mappings
            .flatMap(Self.pathVariants(for:))
            .filter { !$0.realPath.isEmpty && $0.realPath != "/" }
            .sorted { lhs, rhs in
                if lhs.realPath.count != rhs.realPath.count {
                    return lhs.realPath.count > rhs.realPath.count
                }
                return lhs.realPath > rhs.realPath
            }
        var seen = Set<String>()
        self.mappings = normalizedMappings.filter { mapping in
            let key = mapping.realPath + "\u{0}" + mapping.virtualPath
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
        self.replacements = Self.replacements(for: self.mappings)
    }

    public init(
        workspaceRootURL: URL?,
        runtimeDirectoryMappings: [(url: URL, virtualPath: String)] = [],
        runtimeFileMappings: [(url: URL, virtualPath: String)] = []
    ) {
        var mappings: [Mapping] = []
        if let workspaceRootURL {
            mappings.append(Mapping(realPath: workspaceRootURL.path, virtualPath: "/"))
        }
        mappings.append(contentsOf: runtimeDirectoryMappings.map { mapping in
            Mapping(realPath: mapping.url.path, virtualPath: mapping.virtualPath)
        })
        mappings.append(contentsOf: runtimeFileMappings.map { mapping in
            Mapping(realPath: mapping.url.path, virtualPath: mapping.virtualPath)
        })
        self.init(mappings: mappings)
    }

    public func sanitize(_ result: MSPCommandResult) -> MSPCommandResult {
        MSPCommandResult(
            stdoutData: sanitize(result.stdoutData),
            stderrData: sanitize(result.stderrData),
            exitCode: result.exitCode,
            stateChange: result.stateChange,
            modelContentItems: result.modelContentItems
        )
    }

    public func sanitize(_ data: Data) -> Data {
        var output = data
        for replacement in replacements {
            output.replacePathOccurrences(
                of: replacement.needle,
                with: replacement.exactReplacement,
                childReplacement: replacement.childReplacement
            )
        }
        return output
    }

    public func sanitize(_ text: String) -> String {
        String(decoding: sanitize(Data(text.utf8)), as: UTF8.self)
    }

    public var maximumNeedleByteCount: Int {
        replacements.map(\.needle.count).max() ?? 0
    }

    func safeSanitizablePrefixLength(
        in data: Data,
        keepingAtLeast minimumTailByteCount: Int
    ) -> Int {
        guard !data.isEmpty else {
            return 0
        }
        var safeEnd = max(0, data.count - max(0, minimumTailByteCount))
        while safeEnd > 0 {
            let adjustedEnd = prefixLengthBeforeAnySplitReplacement(in: data, proposedEnd: safeEnd)
            if adjustedEnd == safeEnd {
                return safeEnd
            }
            safeEnd = adjustedEnd
        }
        return 0
    }

    private static func pathVariants(for mapping: Mapping) -> [Mapping] {
        let rawPath = mapping.realPath
        let standardizedPath = normalizedPath(rawPath)
        let resolvedSymlinkPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var variants: [Mapping] = []
        for path in [rawPath, standardizedPath, resolvedSymlinkPath]
            .flatMap(Self.platformAliasPathVariants) {
            guard !path.isEmpty else {
                continue
            }
            variants.append(Mapping(realPath: path, virtualPath: mapping.virtualPath))
        }
        return variants
    }

    private static func platformAliasPathVariants(for path: String) -> [String] {
        var variants = [path]
        if path.hasPrefix("/private/var/") || path == "/private/var" {
            variants.append(String(path.dropFirst("/private".count)))
        } else if path.hasPrefix("/var/") || path == "/var" {
            variants.append("/private" + path)
        }
        if path.hasPrefix("/private/tmp/") || path == "/private/tmp" {
            variants.append(String(path.dropFirst("/private".count)))
        } else if path.hasPrefix("/tmp/") || path == "/tmp" {
            variants.append("/private" + path)
        }
        return variants
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func replacements(for mappings: [Mapping]) -> [Replacement] {
        mappings.flatMap { mapping in
            replacementRules(for: mapping)
        }
        .sorted { lhs, rhs in
            if lhs.needle.count != rhs.needle.count {
                return lhs.needle.count > rhs.needle.count
            }
            return lhs.needle.lexicographicallyPrecedes(rhs.needle) == false
        }
    }

    private static func replacementRules(for mapping: Mapping) -> [Replacement] {
        var replacements = [
            Replacement(
                needle: Data(mapping.realPath.utf8),
                exactReplacement: Data(mapping.virtualPath.utf8),
                childReplacement: Data((mapping.virtualPath == "/" ? "" : mapping.virtualPath).utf8)
            )
        ]

        let realFileURL = fileURLText(forPath: mapping.realPath)
        let virtualFileURL = fileURLText(forPath: mapping.virtualPath)
        if realFileURL != mapping.realPath {
            replacements.append(
                Replacement(
                    needle: Data(realFileURL.utf8),
                    exactReplacement: Data(virtualFileURL.utf8),
                    childReplacement: Data((mapping.virtualPath == "/" ? "file://" : virtualFileURL).utf8)
                )
            )
        }
        return replacements
    }

    private static func fileURLText(forPath path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false)
            .standardizedFileURL
            .absoluteString
    }

    private func prefixLengthBeforeAnySplitReplacement(
        in data: Data,
        proposedEnd: Int
    ) -> Int {
        var safeEnd = proposedEnd
        for replacement in replacements where replacement.needle.count > 1 {
            let earliestStart = max(0, safeEnd - replacement.needle.count)
            guard earliestStart < safeEnd else {
                continue
            }
            for start in earliestStart..<safeEnd {
                let matchEnd = start + replacement.needle.count
                let boundaryNeedsChildPathContext = matchEnd == safeEnd
                    && (
                        safeEnd == data.count
                        || data[safeEnd] == UInt8(ascii: "/")
                    )
                guard matchEnd > safeEnd || boundaryNeedsChildPathContext else {
                    continue
                }
                if data.matchesPrefix(of: replacement.needle, at: start) {
                    safeEnd = min(safeEnd, start)
                    break
                }
            }
        }
        return safeEnd
    }
}

public struct MSPStreamingOutputSanitizer: Sendable {
    private let sanitizer: MSPOutputPathSanitizer
    private let maxBufferedBytes: Int
    private var buffer = Data()

    public init(
        sanitizer: MSPOutputPathSanitizer,
        maxBufferedBytes: Int = 256 * 1024
    ) {
        self.sanitizer = sanitizer
        self.maxBufferedBytes = max(1, maxBufferedBytes)
    }

    public mutating func append(_ data: Data) -> Data {
        guard !data.isEmpty else {
            return Data()
        }
        buffer.append(data)
        guard let newlineIndex = buffer.lastIndex(of: 0x0A) else {
            if buffer.count > maxBufferedBytes {
                return flushKeepingPotentialMappingSuffix()
            }
            return Data()
        }
        let end = buffer.index(after: newlineIndex)
        let pending = buffer[..<end]
        buffer.removeSubrange(..<end)
        return sanitizer.sanitize(Data(pending))
    }

    public mutating func flush() -> Data {
        guard !buffer.isEmpty else {
            return Data()
        }
        let pending = buffer
        buffer.removeAll(keepingCapacity: false)
        return sanitizer.sanitize(pending)
    }

    private mutating func flushKeepingPotentialMappingSuffix() -> Data {
        let keepCount = min(
            max(0, sanitizer.maximumNeedleByteCount - 1),
            buffer.count
        )
        let prefixLength = sanitizer.safeSanitizablePrefixLength(
            in: buffer,
            keepingAtLeast: keepCount
        )
        guard prefixLength > 0 else {
            return Data()
        }
        let pending = buffer[..<prefixLength]
        buffer.removeSubrange(..<prefixLength)
        return sanitizer.sanitize(Data(pending))
    }
}

private struct Replacement: Sendable {
    var needle: Data
    var exactReplacement: Data
    var childReplacement: Data
}

private extension Data {
    mutating func replacePathOccurrences(
        of needle: Data,
        with replacement: Data,
        childReplacement: Data
    ) {
        guard !needle.isEmpty else {
            return
        }
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = self.range(of: needle, in: searchStart..<endIndex) {
            guard isPathBoundaryBefore(range.lowerBound) else {
                searchStart = index(after: range.lowerBound)
                continue
            }
            if range.upperBound < endIndex && self[range.upperBound] == UInt8(ascii: "/") {
                replaceSubrange(range, with: childReplacement)
                searchStart = range.lowerBound + childReplacement.count
            } else if isPathBoundaryAfter(range.upperBound) {
                replaceSubrange(range, with: replacement)
                searchStart = range.lowerBound + replacement.count
            } else {
                searchStart = index(after: range.lowerBound)
            }
        }
    }

    func isPathBoundaryBefore(_ index: Index) -> Bool {
        guard index > startIndex else {
            return true
        }
        return !isPathContinuationByte(self[self.index(before: index)])
    }

    func isPathBoundaryAfter(_ index: Index) -> Bool {
        guard index < endIndex else {
            return true
        }
        return !isPathContinuationByte(self[index])
    }

    func isPathContinuationByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "-"),
             UInt8(ascii: "_"),
             UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }

    func matchesPrefix(of needle: Data, at start: Int) -> Bool {
        guard start >= startIndex, start < endIndex else {
            return false
        }
        let availableCount = Swift.min(needle.count, endIndex - start)
        guard availableCount > 0 else {
            return false
        }
        for offset in 0..<availableCount where self[start + offset] != needle[offset] {
            return false
        }
        return true
    }
}
