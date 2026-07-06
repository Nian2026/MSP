import Foundation

struct MSPPlaygroundShellOracleRunSummary {
    var selectedCaseCount: Int
    var passedCaseCount: Int
    var failedCaseCount: Int
}

@MainActor
struct MSPPlaygroundShellOracleRunner {
    var fixtureURL: URL
    var casesDirectoryURL: URL
    var eventLog: MSPPlaygroundE2EEventLog?
    var arguments: [String]
    var environment: [String: String]
    var fileManager: FileManager

    init(
        fixtureURL: URL,
        casesDirectoryURL: URL,
        eventLog: MSPPlaygroundE2EEventLog?,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.fixtureURL = fixtureURL
        self.casesDirectoryURL = casesDirectoryURL
        self.eventLog = eventLog
        self.arguments = arguments
        self.environment = environment
        self.fileManager = fileManager
    }

    func runPythonOracle() async -> MSPPlaygroundShellOracleRunSummary {
        eventLog?.record("shell_oracle_started", fields: [
            "oracle": "debian12-python-noninteractive"
        ])
        do {
            let fixture = try decodeFixture()
            let selectedCases = fixture.cases
                .filter { $0.commands.contains("python3") }
                .filter { !$0.commands.contains("node") }
            var passedCount = 0
            var failedCount = 0

            try resetDirectory(casesDirectoryURL)
            for testCase in selectedCases {
                let passed = await run(testCase)
                if passed {
                    passedCount += 1
                } else {
                    failedCount += 1
                }
            }

            let summary = MSPPlaygroundShellOracleRunSummary(
                selectedCaseCount: selectedCases.count,
                passedCaseCount: passedCount,
                failedCaseCount: failedCount
            )
            eventLog?.record("shell_oracle_finished", fields: [
                "oracle": "debian12-python-noninteractive",
                "selected_case_count": "\(summary.selectedCaseCount)",
                "passed_case_count": "\(summary.passedCaseCount)",
                "failed_case_count": "\(summary.failedCaseCount)"
            ])
            return summary
        } catch {
            eventLog?.record("shell_oracle_error", fields: [
                "oracle": "debian12-python-noninteractive",
                "message": String(describing: error)
            ])
            eventLog?.record("shell_oracle_finished", fields: [
                "oracle": "debian12-python-noninteractive",
                "selected_case_count": "0",
                "passed_case_count": "0",
                "failed_case_count": "1"
            ])
            return MSPPlaygroundShellOracleRunSummary(
                selectedCaseCount: 0,
                passedCaseCount: 0,
                failedCaseCount: 1
            )
        }
    }

    private func run(_ testCase: MSPPlaygroundDebian12OracleCase) async -> Bool {
        do {
            let rootURL = casesDirectoryURL
                .appendingPathComponent(testCase.id, isDirectory: true)
            eventLog?.record("shell_oracle_case_started", fields: [
                "id": testCase.id,
                "category": testCase.category
            ])
            try resetDirectory(rootURL)
            try prepareFixture(testCase.fixture, rootURL: rootURL)
            let runtime = try MSPPlaygroundShellRuntime(
                workspaceURL: rootURL,
                arguments: arguments,
                environment: environment
            )
            let result = await runtime.run(testCase.mspCommandLine)
            let actualFileTree = try snapshotFileTree(rootURL: rootURL)
            let expectedStdout = Self.expectedOutputDataForMSPComparison(
                testCase.expected.stdoutData,
                caseCommandName: testCase.shellCommandName
            )
            let expectedStderr = Self.expectedOutputDataForMSPComparison(
                testCase.expected.stderrData,
                caseCommandName: testCase.shellCommandName
            )
            let stdoutMatches = result.stdoutData == expectedStdout
            let stderrMatches = result.stderrData == expectedStderr
            let exitCodeMatches = result.exitCode == testCase.expected.exitCode
            let fileTreeMatches = actualFileTree == testCase.expectedFileTree
            let passed = stdoutMatches && stderrMatches && exitCodeMatches && fileTreeMatches
            eventLog?.record("shell_oracle_case", fields: [
                "id": testCase.id,
                "category": testCase.category,
                "passed": "\(passed)",
                "stdout_matches": "\(stdoutMatches)",
                "stderr_matches": "\(stderrMatches)",
                "exit_code_matches": "\(exitCodeMatches)",
                "file_tree_matches": "\(fileTreeMatches)",
                "actual_exit_code": "\(result.exitCode)",
                "expected_exit_code": "\(testCase.expected.exitCode)",
                "actual_stdout_b64": result.stdoutData.base64EncodedString(),
                "actual_stderr_b64": result.stderrData.base64EncodedString(),
                "expected_stdout_b64": expectedStdout.base64EncodedString(),
                "expected_stderr_b64": expectedStderr.base64EncodedString()
            ])
            return passed
        } catch {
            eventLog?.record("shell_oracle_case", fields: [
                "id": testCase.id,
                "category": testCase.category,
                "passed": "false",
                "error": String(describing: error)
            ])
            return false
        }
    }

    private func decodeFixture() throws -> MSPPlaygroundDebian12OracleFixture {
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MSPPlaygroundDebian12OracleFixture.self, from: data)
    }

    private func prepareFixture(
        _ fixture: MSPPlaygroundDebian12OracleFixtureSpec,
        rootURL: URL
    ) throws {
        for directory in fixture.directories {
            let url = try safeFixtureURL(rootURL: rootURL, relativePath: directory)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for file in fixture.files {
            let url = try safeFixtureURL(rootURL: rootURL, relativePath: file.path)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let target = file.target {
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            } else {
                try file.contentData.write(to: url)
            }
            if let mode = file.modeValue {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int(mode))],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    private func snapshotFileTree(rootURL: URL) throws -> [MSPPlaygroundDebian12OracleFileTreeEntry] {
        var entries: [MSPPlaygroundDebian12OracleFileTreeEntry] = []
        try appendSnapshotEntry(url: rootURL, rootURL: rootURL, entries: &entries)
        return entries.sorted { lhs, rhs in
            if lhs.path == rhs.path {
                return lhs.kind < rhs.kind
            }
            return lhs.path < rhs.path
        }
    }

    private func appendSnapshotEntry(
        url: URL,
        rootURL: URL,
        entries: inout [MSPPlaygroundDebian12OracleFileTreeEntry]
    ) throws {
        let path = snapshotPath(url: url, rootURL: rootURL)
        guard !isInternalImplementationSnapshotPath(path) else {
            return
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let mode = String(
            format: "%03o",
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        )
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            entries.append(
                MSPPlaygroundDebian12OracleFileTreeEntry(
                    kind: "symlink",
                    mode: "777",
                    path: path,
                    size: nil,
                    contentB64: nil,
                    target: target
                )
            )
            return
        }

        var isDirectory = ObjCBool(false)
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let children = try fileManager
                .contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if path == "./tmp", children.isEmpty {
                return
            }
            entries.append(
                MSPPlaygroundDebian12OracleFileTreeEntry(
                    kind: "directory",
                    mode: mode,
                    path: path,
                    size: nil,
                    contentB64: nil,
                    target: nil
                )
            )
            for child in children {
                try appendSnapshotEntry(url: child, rootURL: rootURL, entries: &entries)
            }
        } else {
            let data = try Data(contentsOf: url)
            entries.append(
                MSPPlaygroundDebian12OracleFileTreeEntry(
                    kind: "file",
                    mode: mode,
                    path: path,
                    size: data.count,
                    contentB64: data.base64EncodedString(),
                    target: nil
                )
            )
        }
    }

    private func resetDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func safeFixtureURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw oracleError("absolute fixture path is not allowed: \(relativePath)")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw oracleError("escaping fixture path is not allowed: \(relativePath)")
        }
        return rootURL.appendingPathComponent(relativePath)
    }

    private func isInternalImplementationSnapshotPath(_ path: String) -> Bool {
        path == "./.msp" || path.hasPrefix("./.msp/")
    }

    private func snapshotPath(url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath != rootPath else {
            return "."
        }
        let relative = itemPath.dropFirst(rootPath.count)
            .drop { $0 == "/" }
        return "./" + relative
    }

    private func oracleError(_ message: String) -> NSError {
        NSError(
            domain: "MSPPlaygroundShellOracleRunner",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func expectedOutputDataForMSPComparison(
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
}

private struct MSPPlaygroundDebian12OracleFixture: Decodable {
    var cases: [MSPPlaygroundDebian12OracleCase]
}

private struct MSPPlaygroundDebian12OracleCase: Decodable {
    var id: String
    var category: String
    var commands: [String]
    var commandLine: String?
    var scriptLines: [String]?
    var shell: MSPPlaygroundDebian12OracleShell?
    var standardInputB64: String
    var fixture: MSPPlaygroundDebian12OracleFixtureSpec
    var expected: MSPPlaygroundDebian12OracleExpectedOutput
    var fileTree: [MSPPlaygroundDebian12OracleFileTreeEntry]

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

    var expectedFileTree: [MSPPlaygroundDebian12OracleFileTreeEntry] {
        fileTree
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

private struct MSPPlaygroundDebian12OracleShell: Decodable {
    var argv: [String]

    var commandName: String {
        guard let executable = argv.first else {
            return "shell"
        }
        return URL(fileURLWithPath: executable).lastPathComponent
    }
}

private struct MSPPlaygroundDebian12OracleFixtureSpec: Decodable {
    var directories: [String]
    var files: [MSPPlaygroundDebian12OracleFixtureFile]
}

private struct MSPPlaygroundDebian12OracleFixtureFile: Decodable {
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

private struct MSPPlaygroundDebian12OracleExpectedOutput: Decodable {
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

private struct MSPPlaygroundDebian12OracleFileTreeEntry: Codable, Equatable {
    var kind: String
    var mode: String
    var path: String
    var size: Int?
    var contentB64: String?
    var target: String?
}
