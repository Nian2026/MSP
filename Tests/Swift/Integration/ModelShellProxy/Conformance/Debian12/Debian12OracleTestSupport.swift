import Foundation
import XCTest

enum Debian12OracleTestSupport {
    static func commaSeparatedSet(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    static func makeTemporaryURL(suiteName: String, name: String) -> URL {
        mspConformanceTemporaryURL(
            suiteName: suiteName,
            name: "\(name)-\(UUID().uuidString)"
        )
    }

    static func removeTemporaryURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func runnerError(_ message: String) -> NSError {
        NSError(
            domain: "ModelShellProxyDebian12OracleConformanceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func noninteractiveFixture() throws -> Debian12OracleFixture {
        let url = try oracleRootURL().appendingPathComponent("noninteractive-cases.json")
        return try decode(Debian12OracleFixture.self, from: url)
    }

    static func ptyFixture() throws -> Debian12PTYOracleFixture {
        let url = try oracleRootURL().appendingPathComponent("pty-cases.json")
        return try decode(Debian12PTYOracleFixture.self, from: url)
    }

    static func oracleRootURL() throws -> URL {
        try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("ReferenceOutputs")
            .appendingPathComponent("MSPV1Debian12Oracle")
    }

    static func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let fixtureURL = url
                .appendingPathComponent("Conformance")
                .appendingPathComponent("ReferenceOutputs")
                .appendingPathComponent("MSPV1Debian12Oracle")
                .appendingPathComponent("noninteractive-cases.json")
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ModelShellProxyDebian12OracleConformanceTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "package root not found"]
        )
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    static func environmentFlag(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name] else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    static func assertPublicSafe(_ rootURL: URL) throws {
        let forbidden = [
            "rea" + "dex",
            [67, 230, 181, 127].map(String.init).joined(separator: "."),
            "ro" + "ot@",
            "/Vol" + "umes/",
            "/Us" + "ers/",
            "AI" + " reading" + " Test" + "Flight"
        ]
        let files = try FileManager.default
            .contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" || $0.lastPathComponent == "README.md" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    text.range(of: token, options: [.caseInsensitive]) != nil,
                    "forbidden public token \(token) in \(file.path)"
                )
            }
        }
    }

    static func byteComparison(expected: Data, actual: Data) -> Debian12OracleByteComparison {
        let expectedBytes = [UInt8](expected)
        let actualBytes = [UInt8](actual)
        let sharedCount = min(expectedBytes.count, actualBytes.count)
        var firstDifference: Int?
        for index in 0..<sharedCount where expectedBytes[index] != actualBytes[index] {
            firstDifference = index
            break
        }
        if firstDifference == nil, expectedBytes.count != actualBytes.count {
            firstDifference = sharedCount
        }
        let offset = firstDifference
        return Debian12OracleByteComparison(
            expectedByteCount: expectedBytes.count,
            actualByteCount: actualBytes.count,
            firstDifferentByteOffset: offset,
            expectedByteAtOffset: offset.flatMap { expectedBytes.indices.contains($0) ? expectedBytes[$0] : nil },
            actualByteAtOffset: offset.flatMap { actualBytes.indices.contains($0) ? actualBytes[$0] : nil },
            expectedUtf8Preview: utf8Preview(expected),
            actualUtf8Preview: utf8Preview(actual)
        )
    }

    static func expectedOutputDataForMSPComparison(
        _ data: Data,
        caseCommandName: String
    ) -> Data {
        let caseRootWithSlash = Data("<CASE_ROOT>/".utf8)
        let caseRoot = Data("<CASE_ROOT>".utf8)
        let caseCommand = Data("<CASE_COMMAND>".utf8)
        var output = replacingBytes(in: data, target: caseRootWithSlash, replacement: Data("/".utf8))
        output = replacingBytes(in: output, target: caseRoot, replacement: Data("/".utf8))
        output = replacingBytes(in: output, target: caseCommand, replacement: Data(caseCommandName.utf8))
        return output
    }

    private static func replacingBytes(in data: Data, target: Data, replacement: Data) -> Data {
        guard !target.isEmpty, data.count >= target.count else {
            return data
        }
        let bytes = [UInt8](data)
        let targetBytes = [UInt8](target)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if index + targetBytes.count <= bytes.count,
               Array(bytes[index..<(index + targetBytes.count)]) == targetBytes {
                output.append(replacement)
                index += targetBytes.count
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static func utf8Preview(_ data: Data, limit: Int = 1_200) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.count > limit {
            let end = text.index(text.startIndex, offsetBy: limit)
            text = String(text[..<end]) + "...<truncated>"
        }
        return text.debugDescription
    }
}

struct Debian12OracleFixture: Decodable {
    var schemaVersion: Int
    var artifactKind: String
    var profile: String
    var evidenceSummary: Debian12OracleEvidenceSummary
    var cases: [Debian12OracleCase]
}

struct Debian12OracleEvidenceSummary: Decodable {
    var caseCount: Int
    var linuxAndCandidateParityPassCount: Int
    var linuxCaptureOnlyCount: Int
    var mismatchCountForParityPassSubset: Int
}

struct Debian12OracleCase: Decodable {
    var id: String
    var category: String
    var commands: [String]
    var evidenceLevel: String
    var commandLine: String?
    var scriptLines: [String]?
    var shell: Debian12OracleShell?
    var standardInputB64: String
    var fixture: Debian12OracleFixtureSpec
    var expected: Debian12OracleExpectedOutput
    var fileTree: [Debian12OracleFileTreeEntry]

    var scriptText: String {
        if let commandLine {
            return commandLine
        }
        return (scriptLines ?? []).joined(separator: "\n")
    }

    var mspCommandLine: String {
        guard let shell else {
            return scriptText
        }
        let invocation = [shell.commandName]
            + shell.argv.dropFirst()
            + ["-c", scriptText]
        return invocation.map(Self.shellQuote).joined(separator: " ")
    }

    var shellCommandName: String {
        shell?.commandName ?? "shell"
    }

    var standardInputData: Data {
        Data(base64Encoded: standardInputB64) ?? Data()
    }

    var expectedFileTree: [Debian12OracleFileTreeEntry] {
        fileTree.map { $0.normalizedForComparison }
            .sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.kind < rhs.kind
                }
                return lhs.path < rhs.path
            }
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

struct Debian12OracleShell: Decodable {
    var argv: [String]

    var commandName: String {
        guard let executable = argv.first else {
            return "shell"
        }
        return URL(fileURLWithPath: executable).lastPathComponent
    }
}

struct Debian12OracleFixtureSpec: Decodable {
    var directories: [String]
    var files: [Debian12OracleFixtureFile]
}

struct Debian12OracleFixtureFile: Decodable {
    var path: String
    var mode: String?
    var content: String?
    var contentB64: String?
    var target: String?

    var contentData: Data {
        if let contentB64,
           let data = Data(base64Encoded: contentB64) {
            return data
        }
        return Data((content ?? "").utf8)
    }

    var modeValue: UInt16? {
        guard let mode else {
            return nil
        }
        return UInt16(mode, radix: 8)
    }
}

struct Debian12OracleExpectedOutput: Decodable {
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

struct Debian12OracleFileTreeEntry: Codable, Equatable {
    var kind: String
    var mode: String
    var path: String
    var size: Int?
    var contentB64: String?
    var target: String?

    var normalizedForComparison: Debian12OracleFileTreeEntry {
        Debian12OracleFileTreeEntry(
            kind: kind,
            mode: mode,
            path: path,
            size: size,
            contentB64: contentB64,
            target: target
        )
    }
}

struct Debian12PTYOracleFixture: Decodable {
    var schemaVersion: Int
    var artifactKind: String
    var profile: String
    var evidenceSummary: Debian12PTYOracleEvidenceSummary
    var cases: [Debian12PTYOracleCase]
}

struct Debian12PTYOracleEvidenceSummary: Decodable {
    var findingCount: Int
}

struct Debian12PTYOracleCase: Decodable {
    var id: String
    var commandLine: String
    var description: String
    var actions: [Debian12PTYOracleAction]
    var expected: Debian12PTYOracleExpectedOutput
}

struct Debian12PTYOracleAction: Decodable {
    var label: String
    var bytesB64: String
    var text: String?
    var readTimeout: Double
    var sleepBeforeMs: Int

    var bytesData: Data {
        Data(base64Encoded: bytesB64) ?? Data()
    }

    var readTimeoutMilliseconds: Int {
        max(250, Int((readTimeout * 1_000).rounded(.up)))
    }
}

struct Debian12PTYOracleExpectedOutput: Decodable {
    var streamB64: String
    var exitCode: Int32?
    var signal: Int32?

    var streamData: Data {
        Data(base64Encoded: streamB64) ?? Data()
    }
}

struct Debian12OracleMismatch: Codable {
    var stdoutMatches: Bool
    var stderrMatches: Bool
    var exitCodeMatches: Bool
    var fileTreeMatches: Bool

    var isPassing: Bool {
        stdoutMatches && stderrMatches && exitCodeMatches && fileTreeMatches
    }
}

struct Debian12OracleObservedResult: Codable {
    var stdoutB64: String
    var stderrB64: String
    var exitCode: Int32
    var fileTree: [Debian12OracleFileTreeEntry]
}

struct Debian12OracleCaseFailure: Codable {
    var id: String
    var category: String
    var evidenceLevel: String
    var command: String
    var mismatch: Debian12OracleMismatch
    var likelyLayer: String
    var expected: Debian12OracleObservedResult
    var actual: Debian12OracleObservedResult
    var diagnostics: Debian12OracleFailureDiagnostics
}

struct Debian12OracleFailureDiagnostics: Codable {
    var stdout: Debian12OracleByteComparison
    var stderr: Debian12OracleByteComparison
}

struct Debian12OracleByteComparison: Codable {
    var expectedByteCount: Int
    var actualByteCount: Int
    var firstDifferentByteOffset: Int?
    var expectedByteAtOffset: UInt8?
    var actualByteAtOffset: UInt8?
    var expectedUtf8Preview: String
    var actualUtf8Preview: String
}

struct Debian12OracleRunReport: Codable {
    var generatedAt: String
    var selectedCaseCount: Int
    var passedCaseCount: Int
    var failedCaseCount: Int
    var passedCaseIDs: [String]
    var failedCaseIDs: [String]
    var failures: [Debian12OracleCaseFailure]
}

struct Debian12PTYOracleMismatch: Codable {
    var streamMatches: Bool
    var exitCodeMatches: Bool
    var signalMatches: Bool

    var isPassing: Bool {
        streamMatches && exitCodeMatches && signalMatches
    }
}

struct Debian12PTYOracleObservedResult: Codable {
    var streamB64: String
    var exitCode: Int32?
    var signal: Int32?

    var streamData: Data {
        Data(base64Encoded: streamB64) ?? Data()
    }
}

struct Debian12PTYOracleCaseFailure: Codable {
    var id: String
    var command: String
    var mismatch: Debian12PTYOracleMismatch
    var expected: Debian12PTYOracleObservedResult
    var actual: Debian12PTYOracleObservedResult
    var diagnostics: Debian12PTYOracleFailureDiagnostics
}

struct Debian12PTYOracleFailureDiagnostics: Codable {
    var stream: Debian12OracleByteComparison
}

struct Debian12PTYOracleRunReport: Codable {
    var generatedAt: String
    var runnerBackend: String
    var runnerPlatform: String
    var selectedCaseCount: Int
    var passedCaseCount: Int
    var failedCaseCount: Int
    var passedCaseIDs: [String]
    var failedCaseIDs: [String]
    var failures: [Debian12PTYOracleCaseFailure]
}
