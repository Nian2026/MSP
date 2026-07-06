import Foundation

struct Core100OracleFixture: Decodable {
    var schemaVersion: Int
    var artifactKind: String
    var profile: String
    var evidenceSummary: Core100OracleEvidenceSummary
    var cases: [Core100OracleCase]
}

struct Core100OracleEvidenceSummary: Decodable {
    var caseCount: Int
    var linuxCaptureOnlyCount: Int
    var timeoutCount: Int
    var limitExceededCount: Int
    var core100CommandCount: Int
    var coveredCore100CommandCount: Int
    var missingCore100Commands: [String]
    var shellStressCaseCount: Int
    var perCommandCaseCount: [String: Int]
}

struct Core100OracleCase: Decodable {
    var id: String
    var title: String
    var category: String
    var caseType: String
    var evidenceLevel: String
    var shell: Core100OracleShell
    var commands: [String]
    var commandLine: String
    var standardInputB64: String
    var fixture: Core100OracleFixtureSpec
    var compareFields: [String]
    var expected: Core100OracleExpectedOutput
    var timeout: Bool
    var fileTree: [Core100OracleFileTreeEntry]

    var standardInputData: Data {
        Data(base64Encoded: standardInputB64) ?? Data()
    }

    var expectedFileTree: [Core100OracleFileTreeEntry] {
        fileTree.map { $0.normalizedForComparison }
            .sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.kind < rhs.kind
                }
                return lhs.path < rhs.path
            }
    }

    func compares(_ field: String) -> Bool {
        compareFields.contains(field)
    }
}

struct Core100OracleShell: Codable {
    var dialect: String
    var argv: [String]
}

struct Core100OracleFixtureSpec: Decodable {
    var directories: [String]
    var files: [Core100OracleFixtureFile]
}

struct Core100OracleFixtureFile: Decodable {
    var path: String
    var mode: String?
    var contentB64: String

    var contentData: Data {
        Data(base64Encoded: contentB64) ?? Data()
    }

    var modeValue: UInt16? {
        guard let mode else {
            return nil
        }
        return UInt16(mode, radix: 8)
    }
}

struct Core100OracleExpectedOutput: Decodable {
    var stdoutB64: String
    var stderrB64: String
    var exitCode: Int32

    var stdoutData: Data {
        Data(base64Encoded: stdoutB64) ?? Data()
    }

    var stderrData: Data {
        Data(base64Encoded: stderrB64) ?? Data()
    }
}

struct Core100OracleFileTreeEntry: Codable, Equatable {
    var kind: String
    var mode: String
    var path: String
    var size: Int?
    var contentB64: String?
    var target: String?

    var normalizedForComparison: Core100OracleFileTreeEntry {
        Core100OracleFileTreeEntry(
            kind: kind,
            mode: mode,
            path: path,
            size: size,
            contentB64: contentB64,
            target: target
        )
    }

    func normalizingGNUDdTransferStats() -> Core100OracleFileTreeEntry {
        guard kind == "file",
              let contentB64,
              let data = Data(base64Encoded: contentB64),
              let text = String(data: data, encoding: .utf8) else {
            return self
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let normalizedText = lines
            .map { line -> String in
                let value = String(line)
                if Self.gnuDdTransferStatsRegexMatches(value) {
                    return "<GNU_DD_TRANSFER_STATS>"
                }
                return value
            }
            .joined(separator: "\n")
        guard normalizedText != text else {
            return self
        }

        let normalizedData = Data(normalizedText.utf8)
        return Core100OracleFileTreeEntry(
            kind: kind,
            mode: mode,
            path: path,
            size: normalizedData.count,
            contentB64: normalizedData.base64EncodedString(),
            target: target
        )
    }

    func normalizingMktempTemplatePaths() -> Core100OracleFileTreeEntry {
        Core100OracleFileTreeEntry(
            kind: kind,
            mode: mode,
            path: Self.normalizedMktempTemplatePath(path),
            size: size,
            contentB64: contentB64,
            target: target.map(Self.normalizedMktempTemplatePath)
        )
    }

    private static func normalizedMktempTemplatePath(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"case\.[A-Za-z0-9]{6}"#,
            with: "case.XXXXXX",
            options: .regularExpression
        )
    }

    private static func gnuDdTransferStatsRegexMatches(_ line: String) -> Bool {
        let pattern = #"^[0-9]+ bytes?( \([^)]+\))? copied, [^,]+, .+/s$"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }
}

struct Core100OracleMismatch: Codable {
    var stdoutMatches: Bool
    var stderrMatches: Bool
    var exitCodeMatches: Bool
    var fileTreeMatches: Bool

    var isPassing: Bool {
        stdoutMatches && stderrMatches && exitCodeMatches && fileTreeMatches
    }
}

struct Core100OracleObservedResult: Codable {
    var stdoutB64: String
    var stderrB64: String
    var exitCode: Int32
    var fileTree: [Core100OracleFileTreeEntry]
}

struct Core100OracleCaseFailure: Codable {
    var id: String
    var title: String
    var category: String
    var evidenceLevel: String
    var shellDialect: String
    var commands: [String]
    var compareFields: [String]
    var commandLine: String
    var mismatch: Core100OracleMismatch
    var likelyLayer: String
    var expected: Core100OracleObservedResult
    var actual: Core100OracleObservedResult
    var diagnostics: Core100OracleFailureDiagnostics
}

struct Core100OracleFailureDiagnostics: Codable {
    var stdout: Core100OracleByteComparison
    var stderr: Core100OracleByteComparison
}

struct Core100OracleByteComparison: Codable {
    var expectedByteCount: Int
    var actualByteCount: Int
    var firstDifferentByteOffset: Int?
    var expectedByteAtOffset: UInt8?
    var actualByteAtOffset: UInt8?
    var expectedUtf8Preview: String
    var actualUtf8Preview: String
}

struct Core100OracleRunReport: Codable {
    var generatedAt: String
    var selectedCaseCount: Int
    var passedCaseCount: Int
    var failedCaseCount: Int
    var selectedCommandCounts: [String: Int]
    var failedCommandCounts: [String: Int]
    var failedLikelyLayerCounts: [String: Int]
    var passedCaseIDs: [String]
    var failedCaseIDs: [String]
    var failures: [Core100OracleCaseFailure]
}
