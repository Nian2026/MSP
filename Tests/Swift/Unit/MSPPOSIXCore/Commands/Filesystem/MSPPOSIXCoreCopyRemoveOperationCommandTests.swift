import Foundation
import MSPCore
import XCTest

extension MSPPOSIXCoreFileOperationCommandTests {
    func testRecursiveCopyAndRemoveDelegateTraversalToWorkspaceLayer() async throws {
        let copyWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/tree": .directory,
            "/tree/a.txt": .file(Data("a\n".utf8))
        ])

        let copy = await runCommand("cp", ["-R", "tree", "copy"], workspace: copyWorkspace)

        XCTAssertEqual(copy.exitCode, 0)
        XCTAssertEqual(copy.stderr, "")
        XCTAssertEqual(copyWorkspace.fileSystemBox.copyCalls, [
            WorkerECopyCall(
                source: "tree",
                destination: "copy",
                currentDirectory: "/",
                options: [.recursive, .overwriteExisting]
            )
        ])
        XCTAssertEqual(copyWorkspace.fileSystemBox.listDirectoryCallCount, 0)
        XCTAssertEqual(copyWorkspace.fileSystemBox.readFileCallCount, 0)

        let removeWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/tree": .directory,
            "/tree/a.txt": .file(Data("a\n".utf8))
        ])

        let remove = await runCommand("rm", ["-r", "tree"], workspace: removeWorkspace)

        XCTAssertEqual(remove.exitCode, 0)
        XCTAssertEqual(remove.stderr, "")
        XCTAssertEqual(removeWorkspace.fileSystemBox.removeCalls, [
            WorkerERemoveCall(path: "tree", currentDirectory: "/", recursive: true)
        ])
        XCTAssertEqual(removeWorkspace.fileSystemBox.listDirectoryCallCount, 0)
        XCTAssertEqual(removeWorkspace.fileSystemBox.readFileCallCount, 0)
    }

    func testCopyTargetDirectoryAndNoClobberOptions() async throws {
        let targetDirectoryWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/dst": .directory,
            "/a": .file(Data("a".utf8)),
            "/b": .file(Data("b".utf8))
        ])

        let targetDirectory = await runCommand(
            "cp",
            ["-t", "dst", "a", "b"],
            workspace: targetDirectoryWorkspace
        )

        XCTAssertEqual(targetDirectory.exitCode, 0)
        XCTAssertEqual(targetDirectory.stderr, "")
        XCTAssertEqual(targetDirectoryWorkspace.fileSystemBox.copyCalls, [])
        XCTAssertEqual(targetDirectoryWorkspace.fileSystemBox.batchCopyCalls, [
            WorkerEBatchCopyCall(
                requests: [
                    MSPFileCopyRequest(sourcePath: "a", destinationPath: "/dst/a"),
                    MSPFileCopyRequest(sourcePath: "b", destinationPath: "/dst/b")
                ],
                currentDirectory: "/",
                options: [.overwriteExisting]
            )
        ])

        let noClobberWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/src": .file(Data("new".utf8)),
            "/dst": .file(Data("old".utf8))
        ])

        let noClobber = await runCommand("cp", ["-n", "src", "dst"], workspace: noClobberWorkspace)

        XCTAssertEqual(noClobber.exitCode, 0)
        XCTAssertEqual(noClobber.stderr, "")
        XCTAssertEqual(noClobberWorkspace.fileSystemBox.copyCalls, [])
    }

    func testCopyNoTargetDirectoryAndVerboseOptions() async throws {
        let workspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/src": .file(Data("new".utf8)),
            "/dst": .file(Data("old".utf8))
        ])

        let result = await runCommand("cp", ["-vT", "src", "dst"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "'src' -> 'dst'\n")
        XCTAssertEqual(workspace.fileSystemBox.copyCalls, [
            WorkerECopyCall(source: "src", destination: "dst", currentDirectory: "/", options: [.overwriteExisting])
        ])
    }

    func testCopyParentsCreatesDestinationAncestorsAndStripsSourceSlash() async throws {
        let workspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/src": .directory,
            "/src/file": .file(Data("new".utf8)),
            "/dst": .directory
        ])

        let result = await runCommand(
            "cp",
            ["--parents", "--strip-trailing-slashes", "src/file/", "dst"],
            workspace: workspace
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.createDirectoryCalls, [
            WorkerECreateDirectoryCall(
                path: "/dst/src",
                currentDirectory: "/",
                intermediates: true,
                creationMode: 0o755
            )
        ])
        XCTAssertEqual(workspace.fileSystemBox.copyCalls, [
            WorkerECopyCall(
                source: "src/file",
                destination: "/dst/src/file",
                currentDirectory: "/",
                options: [.overwriteExisting]
            )
        ])
    }
}
