import Foundation
import XCTest

extension MSPPOSIXCoreFileOperationCommandTests {
    func testLinkNoDereferenceForceReplacesDestinationSymlinkItself() async throws {
        let workspace = WorkerEWorkspace(entries: workerESymlinkDirectoryEntries())

        let result = await runCommand("ln", ["-snf", "src.txt", "dirlink"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.removeCalls, [
            WorkerERemoveCall(path: "/dirlink", currentDirectory: "/", recursive: false)
        ])
        XCTAssertEqual(workspace.fileSystemBox.symbolicLinkCalls, [
            WorkerESymbolicLinkCall(target: "src.txt", link: "/dirlink", currentDirectory: "/")
        ])
    }

    func testLnTargetDirectoryNoTargetDirectoryAndVerboseOptions() async throws {
        let targetDirectoryWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/dst": .directory,
            "/a": .file(Data("a".utf8))
        ])

        let targetDirectory = await runCommand("ln", ["-vt", "dst", "a"], workspace: targetDirectoryWorkspace)

        XCTAssertEqual(targetDirectory.exitCode, 0)
        XCTAssertEqual(targetDirectory.stderr, "")
        XCTAssertEqual(targetDirectory.stdout, "'dst/a' => 'a'\n")
        XCTAssertEqual(targetDirectoryWorkspace.fileSystemBox.hardLinkCalls, [
            WorkerEHardLinkCall(source: "a", link: "/dst/a", currentDirectory: "/")
        ])

        let noTargetDirectoryWorkspace = WorkerEWorkspace(entries: workerESymlinkDirectoryEntries())
        let noTargetDirectory = await runCommand(
            "ln",
            ["-sTv", "src.txt", "dirlink"],
            workspace: noTargetDirectoryWorkspace
        )

        XCTAssertEqual(noTargetDirectory.exitCode, 1)
        XCTAssertEqual(
            noTargetDirectory.stderr,
            "ln: failed to create symbolic link 'dirlink': File exists\n"
        )
        XCTAssertEqual(noTargetDirectoryWorkspace.fileSystemBox.symbolicLinkCalls, [])
    }
}
