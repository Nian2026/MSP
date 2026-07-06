import Photos
import XCTest
@testable import PhotoSorter

final class PhotoLibraryIndexTests: XCTestCase {
    func testIndexReusesReadySnapshotUntilMarkedDirty() throws {
        let index = PhotoLibraryIndex(store: nil)
        var buildCount = 0

        let first = try index.snapshot(reason: "test") { previousSnapshot, progress in
            XCTAssertNil(previousSnapshot)
            buildCount += 1
            progress(PhotoLibraryIndexBuildProgress(
                phase: .building,
                processed: 1,
                total: 1,
                currentPath: "/相册/用户/旅行",
                message: "build"
            ))
            return PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 1, albumCount: 1, version: 1),
                mode: .liveScan
            )
        }
        let second = try index.snapshot(reason: "test") { _, _ in
            XCTFail("ready index should not rebuild")
            return PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 99, albumCount: 1, version: 99),
                mode: .fullRebuild
            )
        }

        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(index.currentStatus.phase, .ready)

        index.markDirty(reason: "changed")
        let refreshed = try index.snapshot(reason: "refresh") { previousSnapshot, _ in
            XCTAssertEqual(previousSnapshot, first)
            buildCount += 1
            return PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 2, albumCount: 1, version: 2),
                mode: .incrementalRefresh
            )
        }

        XCTAssertEqual(buildCount, 2)
        XCTAssertEqual(refreshed.directFileCount(at: "/相册/用户/旅行 1"), 2)
        XCTAssertEqual(index.currentStatus.phase, .ready)
    }

    func testSyntheticLargeSnapshotKeepsCountsAndPathLookupInIndex() {
        let snapshot = Self.snapshot(assetCount: 750, albumCount: 8, version: 1)

        XCTAssertEqual(snapshot.directFileCount(at: "/相册/用户/旅行 1"), 750)
        XCTAssertEqual(snapshot.directFileCount(at: "/相册/用户/旅行 8"), 750)
        XCTAssertEqual(snapshot.recursiveFileCount(at: "/相册/用户"), 6_000)
        XCTAssertEqual(snapshot.userAlbums.count, 8)

        let firstPage = snapshot.assets(in: "/相册/用户/旅行 3", offset: 0, limit: 5)
        XCTAssertEqual(firstPage.count, 5)
        XCTAssertEqual(Set(firstPage.map(\.name)).count, 5)
        XCTAssertTrue(firstPage.allSatisfy { $0.name.range(of: #"^[0-9a-f]{12}\.jpg$"#, options: .regularExpression) != nil })
        let fourthName = firstPage[3].name
        XCTAssertEqual(
            snapshot.asset(at: "/相册/用户/旅行 3/\(fourthName)")?.localIdentifier,
            "asset-4"
        )
    }

    func testPersistentStoreRoundTripsSnapshot() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let store = PhotoLibraryIndexPersistentStore(
            fileURL: temporaryDirectory.appendingPathComponent("index.json")
        )
        let snapshot = Self.snapshot(assetCount: 12, albumCount: 2, version: 7)

        try store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func testPersistentStoreLoadsLatestChangeTokenFromSidecarWithoutRewritingIndex() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let indexURL = temporaryDirectory.appendingPathComponent("index.json")
        let tokenURL = temporaryDirectory.appendingPathComponent("photo-library-change-token.json")
        let store = PhotoLibraryIndexPersistentStore(
            fileURL: indexURL,
            changeTokenFileURL: tokenURL
        )
        var snapshot = Self.snapshot(assetCount: 12, albumCount: 2, version: 7)
        snapshot.photoLibraryChangeTokenData = Data([0x01])
        try store.save(snapshot)
        let indexDataBeforeTokenOnlyUpdate = try Data(contentsOf: indexURL)

        snapshot.photoLibraryChangeTokenData = Data([0x02])
        try store.saveChangeToken(for: snapshot)

        XCTAssertEqual(try Data(contentsOf: indexURL), indexDataBeforeTokenOnlyUpdate)
        XCTAssertEqual(store.load()?.photoLibraryChangeTokenData, Data([0x02]))
    }

    func testPersistentChangeTokenVerifiedUpdateDoesNotRewriteLargeIndexSnapshot() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let indexURL = temporaryDirectory.appendingPathComponent("index.json")
        let tokenURL = temporaryDirectory.appendingPathComponent("photo-library-change-token.json")
        let store = PhotoLibraryIndexPersistentStore(
            fileURL: indexURL,
            changeTokenFileURL: tokenURL
        )
        var persisted = Self.snapshot(assetCount: 24, albumCount: 2, version: 11)
        persisted.photoLibraryChangeTokenData = Data([0x01])
        try store.save(persisted)
        let index = PhotoLibraryIndex(store: store)
        let readySnapshot = try index.snapshot(reason: "validate") { previousSnapshot, _ in
            PhotoLibraryIndexBuildOutcome(
                snapshot: previousSnapshot ?? persisted,
                mode: .verifiedCacheHit
            )
        }
        let indexDataBeforeTokenOnlyUpdate = try Data(contentsOf: indexURL)

        var tokenOnlySnapshot = readySnapshot
        tokenOnlySnapshot.photoLibraryChangeTokenData = Data([0x03])
        XCTAssertTrue(index.applyResolvedChangeNotificationSnapshot(
            tokenOnlySnapshot,
            previousVersion: readySnapshot.version,
            mode: .persistentChangeTokenVerified
        ))

        XCTAssertEqual(try Data(contentsOf: indexURL), indexDataBeforeTokenOnlyUpdate)
        XCTAssertEqual(store.load()?.photoLibraryChangeTokenData, Data([0x03]))
        XCTAssertEqual(index.cachedSnapshotForStatus()?.photoLibraryChangeTokenData, Data([0x03]))
    }

    func testPersistedSnapshotRequiresValidationButCanBecomeReadyWithoutRebuild() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let store = PhotoLibraryIndexPersistentStore(
            fileURL: temporaryDirectory.appendingPathComponent("index.json")
        )
        let persisted = Self.snapshot(assetCount: 24, albumCount: 2, version: 11)
        try store.save(persisted)

        let index = PhotoLibraryIndex(store: store)
        XCTAssertEqual(index.currentStatus.phase, .loadingPersisted)

        var validatedPreviousSnapshot: PhotoLibraryIndexSnapshot?
        let snapshot = try index.snapshot(reason: "validate") { previousSnapshot, progress in
            validatedPreviousSnapshot = previousSnapshot
            progress(PhotoLibraryIndexBuildProgress(
                phase: .validating,
                processed: persisted.indexedAssetMembershipCount,
                total: persisted.indexedAssetMembershipCount,
                currentPath: nil,
                message: "validated"
            ))
            return PhotoLibraryIndexBuildOutcome(
                snapshot: previousSnapshot ?? persisted,
                mode: .verifiedCacheHit
            )
        }

        XCTAssertEqual(validatedPreviousSnapshot, persisted)
        var expected = persisted
        expected.version = persisted.version + 1
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(index.currentStatus.phase, .ready)
        XCTAssertEqual(index.currentStatus.message, "照片库缓存已校验")
    }

    func testPersistentStoreRejectsSnapshotMissingCurrentIndexShapeFingerprint() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let fileURL = temporaryDirectory.appendingPathComponent("index.json")
        let store = PhotoLibraryIndexPersistentStore(fileURL: fileURL)
        let snapshot = Self.snapshot(assetCount: 3, albumCount: 1, version: 4)
        try store.save(snapshot)

        let data = try Data(contentsOf: fileURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "indexShapeFingerprint")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacyData.write(to: fileURL, options: [.atomic])

        XCTAssertNil(store.load())
    }

    func testPersistentStoreRejectsSnapshotWhenIndexShapeFingerprintChanges() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let fileURL = temporaryDirectory.appendingPathComponent("index.json")
        let store = PhotoLibraryIndexPersistentStore(fileURL: fileURL)
        let snapshot = Self.snapshot(assetCount: 3, albumCount: 1, version: 4)
        try store.save(snapshot)

        let data = try Data(contentsOf: fileURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["indexShapeFingerprint"] = "old-shape"
        let staleData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try staleData.write(to: fileURL, options: [.atomic])

        XCTAssertNil(store.load())
    }

    func testPersistentStoreRejectsTooOldSchemaAndStartsDirty() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let fileURL = temporaryDirectory.appendingPathComponent("index.json")
        let store = PhotoLibraryIndexPersistentStore(fileURL: fileURL)
        let snapshot = Self.snapshot(assetCount: 3, albumCount: 1, version: 4)
        try store.save(snapshot)

        let data = try Data(contentsOf: fileURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        let staleData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try staleData.write(to: fileURL, options: [.atomic])

        XCTAssertNil(store.load())

        let index = PhotoLibraryIndex(store: store)
        XCTAssertEqual(index.currentStatus.phase, .dirty)
        XCTAssertEqual(index.currentStatus.message, "照片库索引待建立")
    }

    func testConcurrentSnapshotRequestsShareSingleRefresh() throws {
        let index = PhotoLibraryIndex(store: nil)
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        var buildCount = 0
        var snapshots: [PhotoLibraryIndexSnapshot] = []
        var errors: [Error] = []

        for _ in 0..<8 {
            group.enter()
            queue.async {
                do {
                    let snapshot = try index.snapshot(reason: "concurrent") { _, _ in
                        lock.lock()
                        buildCount += 1
                        lock.unlock()
                        Thread.sleep(forTimeInterval: 0.05)
                        return PhotoLibraryIndexBuildOutcome(
                            snapshot: Self.snapshot(assetCount: 10, albumCount: 2, version: 999),
                            mode: .liveScan
                        )
                    }
                    lock.lock()
                    snapshots.append(snapshot)
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(snapshots.count, 8)
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(Set(snapshots.map(\.version)), [1])
        XCTAssertTrue(snapshots.allSatisfy { $0.directFileCount(at: "/相册/用户/旅行 1") == 10 })
    }

    func testDirtyDuringRefreshLeavesSnapshotUntrustedAndForcesNextRefresh() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let store = PhotoLibraryIndexPersistentStore(
            fileURL: temporaryDirectory.appendingPathComponent("index.json")
        )
        let index = PhotoLibraryIndex(store: store)
        var buildCount = 0

        let dirtySnapshot = try index.snapshot(reason: "initial") { previousSnapshot, _ in
            XCTAssertNil(previousSnapshot)
            buildCount += 1
            index.markDirty(reason: "changed during refresh")
            return PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 1, albumCount: 1, version: 999),
                mode: .liveScan
            )
        }

        XCTAssertEqual(dirtySnapshot.version, 1)
        XCTAssertEqual(index.currentStatus.phase, .dirty)
        XCTAssertEqual(index.currentStatus.message, "照片库在刷新期间再次变化")
        XCTAssertNil(store.load())

        let refreshed = try index.snapshot(reason: "refresh after dirty") { previousSnapshot, _ in
            XCTAssertEqual(previousSnapshot, dirtySnapshot)
            buildCount += 1
            return PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 2, albumCount: 1, version: 999),
                mode: .incrementalRefresh
            )
        }

        XCTAssertEqual(buildCount, 2)
        XCTAssertEqual(refreshed.version, 2)
        XCTAssertEqual(refreshed.directFileCount(at: "/相册/用户/旅行 1"), 2)
        XCTAssertEqual(index.currentStatus.phase, .ready)
        XCTAssertEqual(store.load(), refreshed)
    }

    func testRefreshFailureDoesNotReturnDirtyOldSnapshot() throws {
        struct TestError: Error, Equatable {}

        let index = PhotoLibraryIndex(store: nil)
        let initial = try index.snapshot(reason: "initial") { _, _ in
            PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 1, albumCount: 1, version: 1),
                mode: .liveScan
            )
        }
        index.markDirty(reason: "changed")

        XCTAssertThrowsError(try index.snapshot(reason: "failing refresh") { previousSnapshot, _ in
            XCTAssertEqual(previousSnapshot, initial)
            throw TestError()
        })
        XCTAssertEqual(index.currentStatus.phase, .failed)

        var didRebuildAfterFailure = false
        let refreshed = try index.snapshot(reason: "retry") { previousSnapshot, _ in
            XCTAssertEqual(previousSnapshot, initial)
            didRebuildAfterFailure = true
            return PhotoLibraryIndexBuildOutcome(
                snapshot: Self.snapshot(assetCount: 3, albumCount: 1, version: 99),
                mode: .incrementalRefresh
            )
        }

        XCTAssertTrue(didRebuildAfterFailure)
        XCTAssertEqual(refreshed.directFileCount(at: "/相册/用户/旅行 1"), 3)
        XCTAssertEqual(index.currentStatus.phase, .ready)
    }

    func testManifestFingerprintChangesWhenCountPreservingAssetListChanges() {
        let first = Self.snapshot(
            assetIdentifiers: ["asset-1", "asset-2"],
            albumCount: 1,
            version: 1
        )
        let second = Self.snapshot(
            assetIdentifiers: ["asset-1", "asset-3"],
            albumCount: 1,
            version: 2
        )

        XCTAssertEqual(first.directFileCount(at: "/相册/用户/旅行 1"), 2)
        XCTAssertEqual(second.directFileCount(at: "/相册/用户/旅行 1"), 2)
        XCTAssertNotEqual(
            first.directories["/相册/用户/旅行 1"]?.manifestFingerprint,
            second.directories["/相册/用户/旅行 1"]?.manifestFingerprint
        )
    }

    private static func snapshot(
        assetCount: Int,
        albumCount: Int,
        version: Int
    ) -> PhotoLibraryIndexSnapshot {
        snapshot(
            assetIdentifiers: (1...max(assetCount, 0)).map { "asset-\($0)" },
            albumCount: albumCount,
            version: version
        )
    }

    private static func snapshot(
        assetIdentifiers: [String],
        albumCount: Int,
        version: Int
    ) -> PhotoLibraryIndexSnapshot {
        var directories: [String: PhotoLibraryIndexDirectory] = [:]
        func addDirectory(
            name: String,
            path: String,
            parentPath: String?,
            collectionLocalIdentifier: String? = nil,
            childDirectoryPaths: [String] = [],
            assetLocalIdentifiers: [String] = []
        ) {
            directories[path] = PhotoLibraryIndexDirectory(
                name: name,
                path: path,
                parentPath: parentPath,
                collectionLocalIdentifier: collectionLocalIdentifier,
                childDirectoryPaths: childDirectoryPaths,
                assetLocalIdentifiers: assetLocalIdentifiers,
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: !childDirectoryPaths.isEmpty
            )
        }

        let albumPaths = (1...max(albumCount, 0)).map {
            "/相册/用户/旅行 \($0)"
        }
        addDirectory(name: "图库", path: "/图库", parentPath: "/", assetLocalIdentifiers: assetIdentifiers)
        addDirectory(
            name: "相册",
            path: "/相册",
            parentPath: "/",
            childDirectoryPaths: ["/相册/系统", "/相册/用户"]
        )
        addDirectory(name: "系统", path: "/相册/系统", parentPath: "/相册")
        addDirectory(
            name: "用户",
            path: "/相册/用户",
            parentPath: "/相册",
            childDirectoryPaths: albumPaths
        )
        for (index, path) in albumPaths.enumerated() {
            addDirectory(
                name: "旅行 \(index + 1)",
                path: path,
                parentPath: "/相册/用户",
                collectionLocalIdentifier: "album-\(index + 1)",
                assetLocalIdentifiers: assetIdentifiers
            )
        }

        var assets: [String: PhotoLibraryIndexAsset] = [:]
        let records = assetIdentifiers.map { identifier in
            PhotoLibraryManifestAssetRecord(
                localIdentifier: identifier,
                fileExtension: "jpg",
                mediaTypeRawValue: PHAssetMediaType.image.rawValue,
                mediaSubtypesRawValue: 0,
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil,
                modificationDate: nil
            )
        }
        let fileNamesByLocalIdentifier = PhotoLibraryMount.assetFileNames(for: records)
        for identifier in assetIdentifiers {
            assets[identifier] = PhotoLibraryIndexAsset(
                localIdentifier: identifier,
                fileName: fileNamesByLocalIdentifier[identifier] ?? "missing.dat",
                fileExtension: "jpg",
                mediaTypeRawValue: PHAssetMediaType.image.rawValue,
                mediaSubtypesRawValue: 0,
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil,
                modificationDate: nil
            )
        }

        return PhotoLibraryIndexSnapshot.make(
            authorizationStatusRawValue: PHAuthorizationStatus.authorized.rawValue,
            version: version,
            directories: directories,
            assetsByLocalIdentifier: assets
        )
    }
}

private extension PhotoLibraryIndexSnapshot {
    func directFileCount(at path: String) -> Int {
        directories[path]?.directFileCount ?? 0
    }

    func recursiveFileCount(at path: String) -> Int {
        directories[path]?.recursiveFileCount ?? 0
    }
}
