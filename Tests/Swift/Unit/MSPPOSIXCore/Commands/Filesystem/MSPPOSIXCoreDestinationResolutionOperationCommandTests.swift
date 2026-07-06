import XCTest

extension MSPPOSIXCoreFileOperationCommandTests {
    func testCopyMoveAndLinkFollowSymlinkedDestinationDirectories() async throws {
        let cpWorkspace = WorkerEWorkspace(entries: workerESymlinkDirectoryEntries())
        let cp = await runCommand("cp", ["src.txt", "dirlink"], workspace: cpWorkspace)

        XCTAssertEqual(cp.exitCode, 0)
        XCTAssertEqual(cp.stderr, "")
        XCTAssertEqual(cpWorkspace.fileSystemBox.copyCalls, [
            WorkerECopyCall(
                source: "src.txt",
                destination: "/target/src.txt",
                currentDirectory: "/",
                options: [.overwriteExisting]
            )
        ])
        XCTAssertEqual(cpWorkspace.fileSystemBox.listDirectoryCallCount, 0)
        XCTAssertEqual(cpWorkspace.fileSystemBox.readFileCallCount, 0)

        let mvWorkspace = WorkerEWorkspace(entries: workerESymlinkDirectoryEntries())
        let mv = await runCommand("mv", ["src.txt", "dirlink"], workspace: mvWorkspace)

        XCTAssertEqual(mv.exitCode, 0)
        XCTAssertEqual(mv.stderr, "")
        XCTAssertEqual(mvWorkspace.fileSystemBox.moveCalls, [
            WorkerEMoveCall(
                source: "src.txt",
                destination: "/target/src.txt",
                currentDirectory: "/",
                options: [.overwriteExisting]
            )
        ])
        XCTAssertEqual(mvWorkspace.fileSystemBox.listDirectoryCallCount, 0)
        XCTAssertEqual(mvWorkspace.fileSystemBox.readFileCallCount, 0)

        let hardLinkWorkspace = WorkerEWorkspace(entries: workerESymlinkDirectoryEntries())
        let hardLink = await runCommand("ln", ["src.txt", "dirlink"], workspace: hardLinkWorkspace)

        XCTAssertEqual(hardLink.exitCode, 0)
        XCTAssertEqual(hardLink.stderr, "")
        XCTAssertEqual(hardLinkWorkspace.fileSystemBox.hardLinkCalls, [
            WorkerEHardLinkCall(source: "src.txt", link: "/target/src.txt", currentDirectory: "/")
        ])

        let symbolicLinkWorkspace = WorkerEWorkspace(entries: workerESymlinkDirectoryEntries())
        let symbolicLink = await runCommand("ln", ["-s", "src.txt", "dirlink"], workspace: symbolicLinkWorkspace)

        XCTAssertEqual(symbolicLink.exitCode, 0)
        XCTAssertEqual(symbolicLink.stderr, "")
        XCTAssertEqual(symbolicLinkWorkspace.fileSystemBox.symbolicLinkCalls, [
            WorkerESymbolicLinkCall(target: "src.txt", link: "/target/src.txt", currentDirectory: "/")
        ])
    }
}
