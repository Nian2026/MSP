import Foundation
import XCTest
import MSPApple
import MSPCore

final class MSPAppleWorkspaceTests: XCTestCase {
    private func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelShellProxyTests")
            .appendingPathComponent(name)
    }

    private func removeTemporaryURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testCreatesWorkspaceRootAndMapsItToVirtualRoot() throws {
        let rootURL = makeTemporaryURL()
        removeTemporaryURL(rootURL)
        defer { removeTemporaryURL(rootURL) }

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let resolved = try workspace.fileSystem.resolve("/")
        XCTAssertEqual(resolved.virtualPath, "/")
        XCTAssertEqual(resolved.physicalPath, rootURL.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testResolvesVirtualPathInsideWorkspace() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let resolved = try workspace.fileSystem.resolve("notes/../README.md", from: "/docs")

        XCTAssertEqual(resolved.virtualPath, "/docs/README.md")
        XCTAssertTrue(resolved.physicalPath?.hasSuffix("/docs/README.md") == true)
    }

    func testReadWriteCreateDirectoryTouchAndListUseVirtualPaths() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.createDirectory("/docs")
        try workspace.fileSystem.writeTextFile(
            "notes/hello.txt",
            contents: "hello workspace\n",
            from: "/docs",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.touch("/docs/touched.md")

        let text = try workspace.fileSystem.readTextFile("/docs/notes/hello.txt")
        let entries = try workspace.fileSystem.listDirectory("/docs").map(\.name)
        let fileInfo = try workspace.fileSystem.stat("/docs/notes/hello.txt")

        XCTAssertEqual(text, "hello workspace\n")
        XCTAssertEqual(Set(entries), Set(["notes", "touched.md"]))
        XCTAssertEqual(fileInfo.virtualPath, "/docs/notes/hello.txt")
        XCTAssertEqual(fileInfo.type, .regularFile)
    }

    func testFileManagerWorkspaceCanPageDirectoryListings() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileSystem = MSPFileManagerWorkspaceFileSystem(
            rootURL: rootURL,
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )

        try fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try fileSystem.writeTextFile(
            "/docs/b.txt",
            contents: "beta\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try fileSystem.createDirectory("/docs/c.chat")
        try fileSystem.writeTextFile(
            "/docs/d.txt",
            contents: "delta\n",
            options: [.overwriteExisting, .createParentDirectories]
        )

        let page = try fileSystem.listDirectory(
            "/docs",
            offset: 1,
            limit: 2
        )

        XCTAssertEqual(page.map(\.name), ["b.txt", "c.chat"])
        XCTAssertEqual(page.map(\.type), [.regularFile, .regularFile])
        XCTAssertEqual(page.map(\.virtualPath), ["/docs/b.txt", "/docs/c.chat"])
    }

    func testFileManagerWorkspaceSupportsTypedBatchDirectoryEnumeration() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileSystem = MSPFileManagerWorkspaceFileSystem(
            rootURL: rootURL,
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )

        try fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try fileSystem.createDirectory("/docs/folder")
        try fileSystem.createDirectory("/docs/history.chat")
        try fileSystem.writeTextFile(
            "/docs/z.txt",
            contents: "omega\n",
            options: [.overwriteExisting, .createParentDirectories]
        )

        let batchFileSystem: any MSPWorkspaceBatchDirectoryEnumerating = fileSystem
        var batches: [[String]] = []
        try await batchFileSystem.enumerateDirectoryBatches(
            "/docs",
            from: "/",
            options: MSPDirectoryEnumerationOptions(typeFilter: [.regularFile]),
            batchSize: 2
        ) { entries in
            batches.append(entries.map(\.name))
            XCTAssertTrue(entries.allSatisfy { $0.type == .regularFile })
            return true
        }

        XCTAssertEqual(batches, [
            ["a.txt", "history.chat"],
            ["z.txt"]
        ])
    }

    func testChatDirectoryPackagesArePresentedAsRegularFiles() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let packageURL = rootURL
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("history.chat", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(#"{"format":"msp.chat","version":1}"#.utf8)
            .write(to: packageURL.appendingPathComponent("manifest.json"))

        let packageInfo = try workspace.fileSystem.stat("/conversations/history.chat")
        let parentEntries = try workspace.fileSystem.listDirectory("/conversations")

        XCTAssertEqual(packageInfo.type, .regularFile)
        XCTAssertEqual(parentEntries.map(\.name), ["history.chat"])
        XCTAssertEqual(parentEntries.map(\.type), [.regularFile])

        XCTAssertThrowsError(try workspace.fileSystem.listDirectory("/conversations/history.chat")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notDirectory("/conversations/history.chat"))
        }
        XCTAssertThrowsError(try workspace.fileSystem.stat("/conversations/history.chat/manifest.json")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notDirectory("/conversations/history.chat"))
        }
    }

    func testChatDirectoryPackagesCanBeRemovedThroughFileFacade() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let packageURL = rootURL
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("delete-me.chat", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(#"{"format":"msp.chat","version":1}"#.utf8)
            .write(to: packageURL.appendingPathComponent("manifest.json"))

        try workspace.fileSystem.remove("/conversations/delete-me.chat")

        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testReadFileRangeReadsBoundedSliceWithoutLeakingPhysicalPath() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/docs/data.txt",
            contents: "0123456789",
            options: [.overwriteExisting, .createParentDirectories]
        )

        let slice = try workspace.fileSystem.readFileRange("/docs/data.txt", from: "/", offset: 3, length: 4)
        let eofSlice = try workspace.fileSystem.readFileRange("/docs/data.txt", from: "/", offset: 99, length: 4)

        XCTAssertEqual(String(decoding: slice, as: UTF8.self), "3456")
        XCTAssertEqual(eofSlice, Data())
    }

    func testAppendFileAppendsWithoutReplacingExistingContents() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/logs/out.txt",
            contents: "old",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.appendFile(
            "/logs/out.txt",
            data: Data("+new".utf8),
            from: "/",
            options: [.createParentDirectories],
            creationMode: 0o600
        )
        try workspace.fileSystem.appendFile(
            "/logs/created.txt",
            data: Data("created".utf8),
            from: "/",
            options: [.createParentDirectories],
            creationMode: 0o600
        )

        XCTAssertEqual(try workspace.fileSystem.readTextFile("/logs/out.txt"), "old+new")
        XCTAssertEqual(try workspace.fileSystem.readTextFile("/logs/created.txt"), "created")
    }

    func testEnumerateDirectoryVisitsEntriesWithoutUsingEagerListResult() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/docs/notes/hello.txt",
            contents: "hello workspace\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.touch("/docs/touched.md")

        var visitedNames: [String] = []
        try await workspace.fileSystem.enumerateDirectory("/docs", from: "/") { entry in
            visitedNames.append(entry.name)
            return true
        }

        XCTAssertEqual(Set(visitedNames), ["notes", "touched.md"])
    }

    func testEnumerateDirectoryStopsWhenVisitorReturnsFalse() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile("/docs/a.txt", contents: "alpha\n", options: [.overwriteExisting, .createParentDirectories])
        try workspace.fileSystem.writeTextFile("/docs/b.txt", contents: "beta\n", options: [.overwriteExisting, .createParentDirectories])

        var visitedCount = 0
        try await workspace.fileSystem.enumerateDirectory("/docs", from: "/") { _ in
            visitedCount += 1
            return false
        }

        XCTAssertEqual(visitedCount, 1)
    }

    func testParentTraversalIsClampedToWorkspaceRoot() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let resolved = try workspace.fileSystem.resolve("../../outside.txt", from: "/docs")

        XCTAssertEqual(resolved.virtualPath, "/outside.txt")
        XCTAssertEqual(resolved.physicalPath, rootURL.appendingPathComponent("outside.txt").path)
    }

    func testSymlinkEscapeIsDeniedWithoutLeakingPhysicalPaths() throws {
        let rootURL = makeTemporaryURL("root-\(UUID().uuidString)")
        let outsideURL = makeTemporaryURL("outside-\(UUID().uuidString)")
        defer {
            removeTemporaryURL(rootURL)
            removeTemporaryURL(outsideURL)
        }
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let linkURL = rootURL.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        do {
            _ = try workspace.fileSystem.resolve("/outside-link/secret.txt")
            XCTFail("Expected symlink escape to be denied")
        } catch let error as MSPWorkspaceFileSystemError {
            XCTAssertEqual(error, .accessDenied("/outside-link/secret.txt"))
            XCTAssertFalse(error.description.contains(rootURL.path))
            XCTAssertFalse(error.description.contains(outsideURL.path))
        }
    }

    func testReadSymbolicLinkReturnsWorkspaceSafeTargets() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try FileManager.default.createSymbolicLink(
            atPath: rootURL.appendingPathComponent("relative-link").path,
            withDestinationPath: "docs/a.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: rootURL.appendingPathComponent("absolute-link").path,
            withDestinationPath: rootURL.appendingPathComponent("docs/a.txt").path
        )

        XCTAssertEqual(
            try workspace.fileSystem.readSymbolicLink("/relative-link"),
            "docs/a.txt"
        )
        let absoluteTarget = try workspace.fileSystem.readSymbolicLink("/absolute-link")
        XCTAssertEqual(absoluteTarget, "/docs/a.txt")
        XCTAssertFalse(absoluteTarget.contains(rootURL.path))
    }

    func testReadSymbolicLinkDeniesExternalAbsoluteTargetsWithoutLeakingPhysicalPaths() throws {
        let rootURL = makeTemporaryURL("root-\(UUID().uuidString)")
        let outsideURL = makeTemporaryURL("outside-\(UUID().uuidString)")
        defer {
            removeTemporaryURL(rootURL)
            removeTemporaryURL(outsideURL)
        }
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        try FileManager.default.createSymbolicLink(
            atPath: rootURL.appendingPathComponent("outside-link").path,
            withDestinationPath: outsideURL.path
        )

        do {
            _ = try workspace.fileSystem.readSymbolicLink("/outside-link")
            XCTFail("Expected external absolute symlink target to be denied")
        } catch let error as MSPWorkspaceFileSystemError {
            XCTAssertEqual(error, .accessDenied("/outside-link"))
            XCTAssertFalse(error.description.contains(rootURL.path))
            XCTAssertFalse(error.description.contains(outsideURL.path))
        }
    }

    func testCreateSymbolicLinkNormalizesWorkspaceAbsoluteTargets() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/docs/source.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.createDirectory("/links")
        try workspace.fileSystem.createSymbolicLink(
            target: "/docs/source.txt",
            at: "/links/source-link"
        )

        let target = try workspace.fileSystem.readSymbolicLink("/links/source-link")
        XCTAssertEqual(target, "/docs/source.txt")
        XCTAssertFalse(target.contains(rootURL.path))
        XCTAssertEqual(try workspace.fileSystem.readTextFile("/links/source-link"), "alpha\n")
    }

    func testHiddenWorkspacePathsAreDeniedAndOmittedFromListings() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let policy = MSPWorkspaceFileSystemPolicy(hiddenPathComponents: [".msp", ".internal"])
        let workspace = try MSPAppleWorkspace(rootURL: rootURL, policy: policy)

        try "visible\n".write(
            to: rootURL.appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(".internal"),
            withIntermediateDirectories: true
        )

        let entries = try workspace.fileSystem.listDirectory("/").map(\.name)
        XCTAssertEqual(entries, ["visible.txt"])

        do {
            _ = try workspace.fileSystem.resolve("/.internal/state.json")
            XCTFail("Expected hidden path to be denied")
        } catch let error as MSPWorkspaceFileSystemError {
            XCTAssertEqual(error, .hiddenPath("/.internal/state.json"))
            XCTAssertFalse(error.description.contains(rootURL.path))
        }
    }

    func testCopyMoveAndRemoveStayInsideWorkspace() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.copy(
            "/docs/a.txt",
            to: "/docs/b.txt",
            options: [.overwriteExisting]
        )
        try workspace.fileSystem.move(
            "/docs/b.txt",
            to: "/moved/b.txt",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.remove("/docs/a.txt")

        XCTAssertEqual(try workspace.fileSystem.readTextFile("/moved/b.txt"), "alpha\n")
        XCTAssertThrowsError(try workspace.fileSystem.stat("/docs/a.txt")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound("/docs/a.txt"))
        }
    }

    func testRemoveMovesItemsIntoHiddenWorkspaceTrashByDefault() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let trash = try XCTUnwrap(workspace.fileSystem as? any MSPWorkspaceTrashCapable)

        try workspace.fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.remove("/docs/a.txt")

        XCTAssertThrowsError(try workspace.fileSystem.stat("/docs/a.txt")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound("/docs/a.txt"))
        }
        XCTAssertEqual(try workspace.fileSystem.listDirectory("/").map(\.name), ["docs"])

        let records = try trash.trashRecords()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.originalPath, "/docs/a.txt")
        XCTAssertEqual(record.originalName, "a.txt")
        XCTAssertFalse(record.isDirectory)

        let trashedPhysicalPath = rootURL
            .appendingPathComponent(String(record.trashPath.dropFirst()))
            .path
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedPhysicalPath))
    }

    func testRestoreTrashRestoresDefaultHiddenTrashRecords() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let trash = try XCTUnwrap(workspace.fileSystem as? any MSPWorkspaceTrashCapable)

        try workspace.fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.remove("/docs/a.txt")

        let restored = try trash.restoreTrash(["/docs/a.txt"])

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.originalPath, "/docs/a.txt")
        XCTAssertEqual(restored.first?.restoredPath, "/docs/a.txt")
        XCTAssertEqual(try workspace.fileSystem.readTextFile("/docs/a.txt"), "alpha\n")
        XCTAssertTrue(try trash.trashRecords().isEmpty)
    }

    func testDisplayedTrashConfigurationExposesTrashRootWithoutLeakingStorage() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let policy = MSPWorkspaceFileSystemPolicy(
            trashConfiguration: .displayedTrash(
                displayRootPath: "/废纸篓",
                storageRootPath: "/.msp/trash"
            )
        )
        let workspace = try MSPAppleWorkspace(rootURL: rootURL, policy: policy)
        let trash = try XCTUnwrap(workspace.fileSystem as? any MSPWorkspaceTrashCapable)

        try workspace.fileSystem.writeTextFile(
            "/docs/a.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.remove("/docs/a.txt")

        XCTAssertTrue(try workspace.fileSystem.listDirectory("/").map(\.name).contains("废纸篓"))
        XCTAssertEqual(try workspace.fileSystem.listDirectory("/废纸篓").map(\.name), ["docs"])
        XCTAssertEqual(try workspace.fileSystem.listDirectory("/废纸篓/docs").map(\.name), ["a.txt"])
        XCTAssertEqual(try workspace.fileSystem.readTextFile("/废纸篓/docs/a.txt"), "alpha\n")

        do {
            _ = try workspace.fileSystem.stat("/.msp/trash")
            XCTFail("Expected internal trash storage to stay hidden")
        } catch let error as MSPWorkspaceFileSystemError {
            XCTAssertEqual(error, .hiddenPath("/.msp/trash"))
        }

        let restored = try trash.restoreTrash(["/废纸篓/docs/a.txt"])
        XCTAssertEqual(restored.first?.restoredPath, "/docs/a.txt")
        XCTAssertEqual(try workspace.fileSystem.readTextFile("/docs/a.txt"), "alpha\n")
    }

    func testEmptyTrashRequiresUserConfirmedAuthorization() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let trash = try XCTUnwrap(workspace.fileSystem as? any MSPWorkspaceTrashCapable)

        try workspace.fileSystem.writeTextFile("/a.txt", contents: "alpha\n")
        try workspace.fileSystem.remove("/a.txt")
        XCTAssertEqual(try trash.trashRecords().count, 1)

        let authorization = MSPWorkspaceTrashEmptyAuthorization.userConfirmed(
            confirmationID: "unit-test-confirmation"
        )
        let removedCount = try trash.emptyTrash(authorization: authorization)

        XCTAssertEqual(removedCount, 1)
        XCTAssertTrue(try trash.trashRecords().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(".msp/trash").path))
    }

    func testRemoveWithoutTrashConfigurationIsDeniedInsteadOfHardDeleting() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let policy = MSPWorkspaceFileSystemPolicy(trashConfiguration: nil)
        let workspace = try MSPAppleWorkspace(rootURL: rootURL, policy: policy)

        try workspace.fileSystem.writeTextFile("/a.txt", contents: "alpha\n")

        do {
            try workspace.fileSystem.remove("/a.txt")
            XCTFail("Expected remove without trash capability to be denied")
        } catch let error as MSPWorkspaceFileSystemError {
            XCTAssertEqual(error, .accessDenied("/a.txt"))
        }

        XCTAssertEqual(try workspace.fileSystem.readTextFile("/a.txt"), "alpha\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("a.txt").path))
    }

    func testCreateHardLinkStaysInsideWorkspaceAndSharesFileData() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        try workspace.fileSystem.writeTextFile(
            "/docs/source.txt",
            contents: "alpha\n",
            options: [.overwriteExisting, .createParentDirectories]
        )
        try workspace.fileSystem.createHardLink(source: "/docs/source.txt", at: "/docs/hard.txt")
        try workspace.fileSystem.writeTextFile("/docs/hard.txt", contents: "beta\n")

        XCTAssertEqual(try workspace.fileSystem.readTextFile("/docs/source.txt"), "beta\n")
        XCTAssertEqual(try workspace.fileSystem.readTextFile("/docs/hard.txt"), "beta\n")

        let sourceAttributes = try FileManager.default.attributesOfItem(
            atPath: rootURL.appendingPathComponent("docs/source.txt").path
        )
        let hardLinkAttributes = try FileManager.default.attributesOfItem(
            atPath: rootURL.appendingPathComponent("docs/hard.txt").path
        )
        XCTAssertEqual(
            sourceAttributes[.systemFileNumber] as? NSNumber,
            hardLinkAttributes[.systemFileNumber] as? NSNumber
        )
    }

    func testRemoveRootIsDeniedWithoutLeakingPhysicalPath() throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        do {
            try workspace.fileSystem.remove("/", recursive: true)
            XCTFail("Expected root removal to be denied")
        } catch let error as MSPWorkspaceFileSystemError {
            XCTAssertEqual(error, .accessDenied("/"))
            XCTAssertFalse(error.description.contains(rootURL.path))
        }
    }
}
