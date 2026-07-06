import XCTest
import Foundation
import MSPCore
import MSPPOSIXCore

final class MSPPOSIXCoreCommandPackTests: XCTestCase {
    func testCommandPackMatchesMSPV1RequiredLinuxCommandLayerFixture() throws {
        let registry = try MSPCommandRegistry()

        try MSPPOSIXCoreCommandPack().registerCommands(into: registry)

        let fixture = try Self.requiredCommandsFixture()
        XCTAssertEqual(fixture.profile, "msp-v1-linux-command-layer")

        let implementedCommands = fixture.commands
            .filter { $0.status == "implemented" }
            .map(\.name)
            .sorted()

        XCTAssertGreaterThanOrEqual(implementedCommands.count, 92)
        XCTAssertEqual(Set(implementedCommands).count, implementedCommands.count)
        XCTAssertEqual(registry.commandNames, implementedCommands)
    }

    func testCommandPackDoesNotRegisterAppOrExternalExtensionCommands() throws {
        let registry = try MSPCommandRegistry()

        try MSPPOSIXCoreCommandPack().registerCommands(into: registry)

        let extensionCommands: Set<String> = [
            "chat",
            "exo-open",
            "ffmpeg",
            "ffprobe",
            "gio",
            "git",
            "kde-open",
            "kde-open5",
            "km",
            "mimeopen",
            "open",
            "pdf",
            "qpdf",
            "restore",
            "see",
            "text",
            "trash",
            "video",
            "xdg-open",
            "yt-dlp"
        ]

        XCTAssertTrue(Set(registry.commandNames).isDisjoint(with: extensionCommands))
    }

    func testCommandPackCanExcludeSelectedCommands() throws {
        let registry = try MSPCommandRegistry()

        try MSPPOSIXCoreCommandPack(excluding: [
            "sha256sum",
            "md5sum",
            "cksum"
        ]).registerCommands(into: registry)

        XCTAssertNil(registry.command(named: "sha256sum"))
        XCTAssertNil(registry.command(named: "md5sum"))
        XCTAssertNil(registry.command(named: "cksum"))
        XCTAssertNotNil(registry.command(named: "find"))
        XCTAssertNotNil(registry.command(named: "ls"))
        XCTAssertNotNil(registry.command(named: "rm"))
    }

    private static func requiredCommandsFixture() throws -> RequiredCommandsFixture {
        let root = try packageRoot()
        let url = root
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("MSPV1LinuxCommandLayer.required-commands.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RequiredCommandsFixture.self, from: data)
    }

    private static func packageRoot() throws -> URL {
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
            domain: "MSPPOSIXCoreCommandPackTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "package root not found"]
        )
    }
}

private struct RequiredCommandsFixture: Decodable {
    var profile: String
    var commands: [RequiredCommand]
}

private struct RequiredCommand: Decodable {
    var name: String
    var status: String
}
