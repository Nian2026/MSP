import XCTest
@testable import PhotoSorter

final class MSPPlaygroundWorkspaceBootstrapTests: XCTestCase {
    func testEnsureTemporaryDirectoryCreatesWorkspaceTmp() throws {
        let workspaceURL = try makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspaceURL.appendingPathComponent("tmp", isDirectory: true).path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testEnsureTemporaryDirectoryPreservesExistingContents() throws {
        let workspaceURL = try makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let tmpURL = workspaceURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        let markerURL = tmpURL.appendingPathComponent("keep.txt")
        try "keep\n".write(to: markerURL, atomically: true, encoding: .utf8)

        try MSPPlaygroundWorkspaceBootstrap.ensureTemporaryDirectory(in: workspaceURL)

        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "keep\n")
    }

    private func makeTemporaryWorkspaceURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPPlaygroundWorkspaceBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
