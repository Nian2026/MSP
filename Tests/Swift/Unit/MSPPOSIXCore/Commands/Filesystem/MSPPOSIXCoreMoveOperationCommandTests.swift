import Foundation
import XCTest

extension MSPPOSIXCoreFileOperationCommandTests {
    func testMoveNoClobberSkipsExistingDestination() async throws {
        let workspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/src": .file(Data("new".utf8)),
            "/dst": .file(Data("old".utf8))
        ])

        let result = await runCommand("mv", ["-n", "src", "dst"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.moveCalls, [])
    }

    func testMoveTargetDirectoryNoTargetDirectoryAndVerboseOptions() async throws {
        let targetDirectoryWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/dst": .directory,
            "/a": .file(Data("a".utf8))
        ])

        let targetDirectory = await runCommand("mv", ["-t", "dst", "a"], workspace: targetDirectoryWorkspace)

        XCTAssertEqual(targetDirectory.exitCode, 0)
        XCTAssertEqual(targetDirectory.stderr, "")
        XCTAssertEqual(targetDirectoryWorkspace.fileSystemBox.moveCalls, [
            WorkerEMoveCall(source: "a", destination: "/dst/a", currentDirectory: "/", options: [.overwriteExisting])
        ])

        let verboseWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/src": .file(Data("new".utf8)),
            "/dst": .file(Data("old".utf8))
        ])

        let verbose = await runCommand("mv", ["-vT", "src", "dst"], workspace: verboseWorkspace)

        XCTAssertEqual(verbose.exitCode, 0)
        XCTAssertEqual(verbose.stderr, "")
        XCTAssertEqual(verbose.stdout, "renamed 'src' -> 'dst'\n")
        XCTAssertEqual(verboseWorkspace.fileSystemBox.moveCalls, [
            WorkerEMoveCall(source: "src", destination: "dst", currentDirectory: "/", options: [.overwriteExisting])
        ])
    }

    func testMoveStripTrailingSlashesNormalizesSourceOperand() async throws {
        let workspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/src": .file(Data("new".utf8)),
            "/dst": .file(Data("old".utf8))
        ])

        let result = await runCommand(
            "mv",
            ["--strip-trailing-slashes", "src/", "dst"],
            workspace: workspace
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.moveCalls, [
            WorkerEMoveCall(source: "src", destination: "dst", currentDirectory: "/", options: [.overwriteExisting])
        ])
    }
}
