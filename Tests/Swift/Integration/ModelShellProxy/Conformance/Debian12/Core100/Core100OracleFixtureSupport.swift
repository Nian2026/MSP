import Foundation
import XCTest

extension ModelShellProxyCore100OracleConformanceTests {
    func prepareFixture(_ fixture: Core100OracleFixtureSpec, rootURL: URL) throws {
        for directory in fixture.directories {
            let url = try safeFixtureURL(rootURL: rootURL, relativePath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o777)],
                ofItemAtPath: url.path
            )
        }
        for file in fixture.files {
            let url = try safeFixtureURL(rootURL: rootURL, relativePath: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contentData.write(to: url)
            if let mode = file.modeValue {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int(mode))],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    func snapshotFileTree(rootURL: URL) throws -> [Core100OracleFileTreeEntry] {
        var entries: [Core100OracleFileTreeEntry] = []
        try appendSnapshotEntry(url: rootURL, path: ".", entries: &entries)
        return entries.sorted { lhs, rhs in
            if lhs.path == rhs.path {
                return lhs.kind < rhs.kind
            }
            return lhs.path < rhs.path
        }
    }

    func safeFixtureURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw Self.runnerError("absolute fixture path is not allowed: \(relativePath)")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw Self.runnerError("escaping fixture path is not allowed: \(relativePath)")
        }
        return rootURL.appendingPathComponent(relativePath)
    }

    static func fixture() throws -> Core100OracleFixture {
        let url = try oracleRootURL().appendingPathComponent("noninteractive-cases.json")
        return try decode(Core100OracleFixture.self, from: url)
    }

    static func oracleRootURL() throws -> URL {
        try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("ReferenceOutputs")
            .appendingPathComponent("MSPV1Core100Debian12Oracle")
    }

    static func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let fixtureURL = url
                .appendingPathComponent("Conformance")
                .appendingPathComponent("ReferenceOutputs")
                .appendingPathComponent("MSPV1Core100Debian12Oracle")
                .appendingPathComponent("noninteractive-cases.json")
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw runnerError("package root not found")
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
            "AI" + " reading" + " Test" + "Flight",
            "/tmp/msp-oracle-capture-"
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

    static func outputDataForMSPComparison(_ data: Data, testCase: Core100OracleCase) -> Data {
        let caseRootWithSlash = Data("<CASE_ROOT>/".utf8)
        let caseRoot = Data("<CASE_ROOT>".utf8)
        let caseRunnerRoot = Data("<CASE_RUNNER_ROOT>".utf8)
        var output = replacingBytes(in: data, target: caseRootWithSlash, replacement: Data("/".utf8))
        output = replacingBytes(in: output, target: caseRoot, replacement: Data("/".utf8))
        output = replacingBytes(in: output, target: caseRunnerRoot, replacement: Data("/".utf8))
        output = normalizeUnstableOutput(output, testCase: testCase)
        return output
    }

    static func fileTreeForMSPComparison(
        _ entries: [Core100OracleFileTreeEntry],
        testCase: Core100OracleCase
    ) -> [Core100OracleFileTreeEntry] {
        entries.map { entry in
            var normalized = entry.normalizedForComparison
            if testCase.commands.contains("dd") {
                normalized = normalized.normalizingGNUDdTransferStats()
            }
            if testCase.id.hasPrefix("core100-required-mktemp-") {
                normalized = normalized.normalizingMktempTemplatePaths()
            }
            return normalized
        }
        .sorted { lhs, rhs in
            if lhs.path == rhs.path {
                return lhs.kind < rhs.kind
            }
            return lhs.path < rhs.path
        }
    }

    static func byteComparison(expected: Data, actual: Data) -> Core100OracleByteComparison {
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
        return Core100OracleByteComparison(
            expectedByteCount: expectedBytes.count,
            actualByteCount: actualBytes.count,
            firstDifferentByteOffset: offset,
            expectedByteAtOffset: offset.flatMap { expectedBytes.indices.contains($0) ? expectedBytes[$0] : nil },
            actualByteAtOffset: offset.flatMap { actualBytes.indices.contains($0) ? actualBytes[$0] : nil },
            expectedUtf8Preview: utf8Preview(expected),
            actualUtf8Preview: utf8Preview(actual)
        )
    }

    static func runnerError(_ message: String) -> NSError {
        NSError(
            domain: "ModelShellProxyCore100OracleConformanceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func appendSnapshotEntry(
        url: URL,
        path: String,
        entries: inout [Core100OracleFileTreeEntry]
    ) throws {
        guard !isInternalImplementationSnapshotPath(path) else {
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = String(format: "%03o", (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            if isDirectorySymlink(url: url, target: target) {
                return
            }
            entries.append(
                Core100OracleFileTreeEntry(
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
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let children = try FileManager.default
                .contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            entries.append(
                Core100OracleFileTreeEntry(
                    kind: "directory",
                    mode: mode,
                    path: path,
                    size: nil,
                    contentB64: nil,
                    target: nil
                )
            )
            for child in children {
                let childPath = path == "."
                    ? "./\(child.lastPathComponent)"
                    : "\(path)/\(child.lastPathComponent)"
                try appendSnapshotEntry(url: child, path: childPath, entries: &entries)
            }
        } else {
            let data = try Data(contentsOf: url)
            entries.append(
                Core100OracleFileTreeEntry(
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

    private func isDirectorySymlink(url: URL, target: String) -> Bool {
        let targetURL: URL
        if target.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: target)
        } else {
            targetURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(target)
        }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isInternalImplementationSnapshotPath(_ path: String) -> Bool {
        path == "./.msp" || path.hasPrefix("./.msp/")
    }

    private static func normalizeUnstableOutput(_ data: Data, testCase: Core100OracleCase) -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            return data
        }
        if testCase.id == "core100-required-diff-unified" {
            text = text.replacingOccurrences(
                of: #"\t[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ \+0000"#,
                with: "\t<DIFF_MTIME>",
                options: .regularExpression
            )
        }
        if testCase.id.hasPrefix("core100-required-mktemp-") {
            text = text.replacingOccurrences(
                of: #"case\.[A-Za-z0-9]{6}"#,
                with: "case.XXXXXX",
                options: .regularExpression
            )
        }
        return Data(text.utf8)
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
