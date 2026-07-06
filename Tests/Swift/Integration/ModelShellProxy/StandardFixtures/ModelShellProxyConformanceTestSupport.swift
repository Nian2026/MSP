import Foundation

enum ModelShellProxyConformanceSupport {
    static func makeTemporaryURL(suiteName: String, name: String = UUID().uuidString) -> URL {
        let uniqueName = "\(name)-\(UUID().uuidString)"
        return mspConformanceTemporaryURL(suiteName: suiteName, name: uniqueName)
    }

    static func removeTemporaryURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func parityFixture() throws -> ParityFixture {
        let url = try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MSPV1LinuxCommandLayer.parity-cases.json")
        return try decode(ParityFixture.self, from: url)
    }

    static func directParityFixture() throws -> DirectCommandParityFixture {
        let url = try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MSPV1LinuxCommandLayer.direct-parity-cases.json")
        return try decode(DirectCommandParityFixture.self, from: url)
    }

    static func edgeParityFixture() throws -> EdgeCommandParityFixture {
        let url = try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MSPV1LinuxCommandLayer.edge-parity-cases.json")
        return try decode(EdgeCommandParityFixture.self, from: url)
    }

    static func requiredCommandsFixture() throws -> RequiredCommandsFixture {
        let url = try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MSPV1LinuxCommandLayer.required-commands.json")
        return try decode(RequiredCommandsFixture.self, from: url)
    }

    static func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let fixtureURL = url
                .appendingPathComponent("Conformance")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("MSPV1LinuxCommandLayer.required-commands.json")
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ModelShellProxyConformanceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "package root not found"]
        )
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

struct ParityFixture: Decodable {
    var profile: String
    var cases: [ParityCase]
}

struct ParityCase: Decodable {
    var id: String
    var coveredCommands: [String]
    var setupFiles: [ParitySetupFile]?
    var script: [String]
    var stdout: String
    var stderr: String
    var exitCode: Int32

    private enum CodingKeys: String, CodingKey {
        case id
        case coveredCommands
        case setupFiles
        case script
        case stdout
        case stderr
        case exitCode
    }
}

struct ParitySetupFile: Decodable {
    var path: String
    var content: String
}

struct DirectCommandParityFixture: Decodable {
    var profile: String
    var cases: [DirectCommandParityCase]
}

struct DirectCommandParityCase: Decodable {
    var command: String
    var setupFiles: [ParitySetupFile]?
    var setupScript: [String]?
    var commandLine: String
    var stdout: String?
    var stdoutMatches: String?
    var stderr: String
    var exitCode: Int32
}

struct EdgeCommandParityFixture: Decodable {
    var profile: String
    var cases: [EdgeCommandParityCase]
}

struct EdgeCommandParityCase: Decodable {
    var id: String
    var coveredCommands: [String]
    var setupFiles: [ParitySetupFile]?
    var setupScript: [String]?
    var commandLine: String
    var stdout: String?
    var stdoutMatches: String?
    var stderr: String
    var exitCode: Int32
}

struct RequiredCommandsFixture: Decodable {
    var profile: String
    var commands: [RequiredCommand]
}

struct RequiredCommand: Decodable {
    var name: String
    var status: String
}

struct ProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}
