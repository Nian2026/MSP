import CoreGraphics
import CoreImage
import CoreLocation
import ModelShellProxy
import MSPCore
import MSPPOSIXCore
import Photos
import XCTest
@testable import PhotoSorter
#if canImport(UIKit) && canImport(Vision)
import UIKit
import Vision
#endif

final class PhotoLibraryWorkspaceFileSystemPathTests: XCTestCase {
    func testPhotoLibraryMountUsesGalleryAndAlbumsTreeShape() throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let fileSystem = fixture.workspace.fileSystem

        XCTAssertEqual(
            try fileSystem.listDirectory("/", from: "/").map(\.name),
            ["图库", "最近删除", "相册"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册", from: "/").map(\.name),
            ["系统", "用户"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/系统", from: "/").map(\.name),
            [
                "个人收藏",
                "截图",
                "最近添加",
                "视频",
                "屏幕录制",
                "RAW",
                "实况照片",
                "慢动作",
                "全景照片",
                "自拍",
                "连拍",
                "延时摄影",
                "电影效果",
                "空间"
            ]
        )

        XCTAssertThrowsError(try fileSystem.listDirectory("/截图", from: "/"))
        XCTAssertNoThrow(try fileSystem.stat("/相册/系统/截图", from: "/"))
        XCTAssertNoThrow(try fileSystem.stat("/相册/系统/屏幕录制", from: "/"))
        XCTAssertNoThrow(try fileSystem.stat("/相册/系统/空间", from: "/"))
        XCTAssertThrowsError(try fileSystem.stat("/相册/系统/隐藏", from: "/"))
        XCTAssertNoThrow(try fileSystem.stat("/相册/用户", from: "/"))
    }

    func testPhotoWorkspacePromptTreeContextCanBeRootedAtWorkspacePath() throws {
        let snapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "a.jpg",
            additionalAssetDirectoryPaths: [
                "/图库",
                "/相册/用户/待确认"
            ],
            userAlbumPaths: [
                "/相册/用户/待确认",
                "/相册/用户/留存"
            ]
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: snapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let tree = fixture.mount.photoWorkspacePromptTreeContext(
            rootPath: "/相册/用户",
            maxUserAlbums: 1
        )

        XCTAssertTrue(tree.contains("/相册/用户/ (1)"))
        XCTAssertTrue(tree.contains("└── ... 还有 1 个用户相册未列出"))
        XCTAssertTrue(tree.contains("待确认/ (1)"))
        XCTAssertFalse(tree.contains("/图库/"))
        XCTAssertFalse(tree.contains("/相册/系统/"))
    }

    func testPhotoLibraryMountDirectoryListingSupportsOffsetPagination() throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let fileSystem = fixture.workspace.photoLibraryFileSystem

        XCTAssertEqual(
            try fileSystem.listDirectory("/", from: "/", offset: 0, limit: 1).map(\.name),
            ["图库"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/", from: "/", offset: 1, limit: 1).map(\.name),
            ["最近删除"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/", from: "/", offset: 2, limit: 1).map(\.name),
            ["相册"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/", from: "/", offset: 3, limit: 1).map(\.name),
            []
        )
    }

    func testPhotoWorkspaceLocalFilesExposeSequentialReaderThroughWrapper() throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let fileSystem = fixture.workspace.photoLibraryFileSystem
        try fileSystem.writeFile(
            "/tmp/probe.txt",
            data: Data("abcdef".utf8),
            from: "/",
            options: [.createParentDirectories]
        )

        let reader = try XCTUnwrap(
            try fileSystem.openSequentialFileReader("/tmp/probe.txt", from: "/")
        )
        defer {
            try? reader.close()
        }

        XCTAssertEqual(String(decoding: try XCTUnwrap(reader.read(upToCount: 2)), as: UTF8.self), "ab")
        XCTAssertEqual(String(decoding: try XCTUnwrap(reader.read(upToCount: 4)), as: UTF8.self), "cdef")
        XCTAssertNil(try reader.read(upToCount: 1))
    }

    func testWorkspaceFileNodesInferMediaKindsForThumbnails() throws {
        let modificationDate = Date(timeIntervalSince1970: 123)
        let entries = [
            MSPDirectoryEntry(
                name: "photo.HEIC",
                info: MSPFileInfo(
                    virtualPath: "/photo.HEIC",
                    type: .regularFile,
                    modificationDate: modificationDate
                )
            ),
            MSPDirectoryEntry(
                name: "clip.mp4",
                info: MSPFileInfo(
                    virtualPath: "/clip.mp4",
                    type: .regularFile,
                    modificationDate: modificationDate
                )
            ),
            MSPDirectoryEntry(
                name: "notes.txt",
                info: MSPFileInfo(
                    virtualPath: "/notes.txt",
                    type: .regularFile,
                    modificationDate: modificationDate
                )
            ),
            MSPDirectoryEntry(
                name: "Folder",
                info: MSPFileInfo(
                    virtualPath: "/Folder",
                    type: .directory,
                    modificationDate: modificationDate
                )
            )
        ]

        let nodes = try WorkspaceFileNode.loadChildren(
            path: "/",
            remainingDepth: 1
        ) { path in
            path == "/" ? entries : []
        }

        XCTAssertEqual(nodes.map(\.mediaKind), [.image, .video, nil, nil])
        XCTAssertEqual(nodes[0].modificationDate, modificationDate)
    }

    func testPresentationListingUsesPersistedPhotoLibraryCacheWithoutValidation() throws {
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: "4f4fb263cf16.jpg")
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectoryForPresentation(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.name), ["4f4fb263cf16.jpg"])
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPresentationListingDoesNotBuildMissingPhotoLibraryCache() throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectoryForPresentation(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries, [])
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPresentationListingFallsBackToLightweightPhotoLibraryPageWhenCacheMissing() throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let records = [
            Self.manifestAssetRecord(identifier: "asset-a", fileExtension: "jpg", creationTime: 3),
            Self.manifestAssetRecord(identifier: "asset-b", fileExtension: "png", creationTime: 2),
            Self.manifestAssetRecord(identifier: "asset-c", fileExtension: "mov", mediaType: .video, creationTime: 1)
        ]
        fixture.manifestProvider.presentationAssetRecordsByPath["/图库"] = records

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectoryForPresentation(
            "/图库",
            from: "/",
            offset: 1,
            limit: 2
        )
        let visibleRecords = Array(records[1...2])
        let expectedNames = PhotoLibraryMount.assetFileNames(for: visibleRecords)

        XCTAssertEqual(entries.map(\.name), visibleRecords.compactMap { expectedNames[$0.localIdentifier] })
        XCTAssertEqual(entries.map(\.virtualPath), entries.map { "/图库/\($0.name)" })
        XCTAssertEqual(fixture.manifestProvider.presentationAssetRecordsCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
        XCTAssertEqual(
            fixture.mount.presentationAsset(at: entries[0].virtualPath)?.localIdentifier,
            "asset-b"
        )
    }

    func testPresentationUserAlbumsFallBackToLightweightPhotoLibraryListingWhenCacheMissing() throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.presentationUserAlbumsResult = [
            PhotoLibraryMount.MountedAlbum(
                name: "旅行",
                virtualPath: "/相册/用户/旅行",
                localIdentifier: "album-a"
            )
        ]

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectoryForPresentation(
            "/相册/用户",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.name), ["旅行"])
        XCTAssertEqual(entries.map(\.virtualPath), ["/相册/用户/旅行"])
        XCTAssertEqual(fixture.manifestProvider.presentationUserAlbumsCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testCachedAssetLookupUsesPersistedPhotoLibraryCacheWithoutValidation() throws {
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: "4f4fb263cf16.jpg")
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let asset = fixture.mount.cachedAsset(at: "/图库/4f4fb263cf16.jpg")

        XCTAssertEqual(asset?.localIdentifier, "asset-a")
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPhotoLibraryStatUsesPersistedCacheWithoutValidation() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let info = try fixture.workspace.photoLibraryFileSystem.stat("/相册/系统/截图/\(fileName)", from: "/")

        XCTAssertEqual(info.virtualPath, "/相册/系统/截图/\(fileName)")
        XCTAssertEqual(info.type, .regularFile)
        XCTAssertNil(info.size)
        XCTAssertEqual(info.modificationDate, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(info.permissions, UInt16(0o444))
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPhotoLibraryReadFileUsesControlledResourceBackendButRejectsBinaryWrites() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: fileName)
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.resourceDataByLocalIdentifier["asset-a"] = Data("photo-bytes".utf8)
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        let data = try fileSystem.readFile("/图库/\(fileName)", from: "/")

        XCTAssertEqual(String(data: data, encoding: .utf8), "photo-bytes")
        XCTAssertEqual(fixture.manifestProvider.resourceDataRequestLocalIdentifiers, ["asset-a"])
        XCTAssertThrowsError(try fileSystem.writeFile(
            "/图库/\(fileName)",
            data: Data("overwrite".utf8),
            from: "/",
            options: [.overwriteExisting]
        )) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .accessDenied("/图库/\(fileName)"))
        }
    }

    func testRemovePhotoLibraryAssetMovesItToWorkspaceTrashWithoutPhotoKitWriteback() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: fileName, tokenData: Data([0x01]))
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.remove("/图库/\(fileName)", from: "/", recursive: false)

        XCTAssertThrowsError(try fileSystem.stat("/图库/\(fileName)", from: "/"))
        XCTAssertEqual(
            try fileSystem.listDirectory("/最近删除", from: "/").map(\.name),
            [fileName]
        )
        XCTAssertEqual(
            fixture.mount.presentationAsset(at: "/最近删除/\(fileName)")?.localIdentifier,
            "asset-a"
        )
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 1)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testPhotoLibraryOverlayKeepsLookupReadAndPreviewConsistentAfterTrash() async throws {
        let fileName = "ca8d29b0d08a.mov"
        let originalPath = "/图库/\(fileName)"
        let trashPath = "/最近删除/\(fileName)"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: fileName, mediaType: .video)
                ],
                tokenData: Data([0x01])
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        fixture.manifestProvider.resourceDataByLocalIdentifier["asset-a"] = Data("video-bytes".utf8)
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.remove(originalPath, from: "/", recursive: false)

        switch fixture.mount.cachedAssetLookup(at: originalPath) {
        case .knownMissing:
            break
        case let .found(asset):
            XCTFail("original path still resolves to \(asset.localIdentifier)")
        case .unknown:
            XCTFail("original path should be known missing after workspace trash overlay")
        }
        XCTAssertThrowsError(try fileSystem.stat(originalPath, from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound(originalPath))
        }
        XCTAssertThrowsError(try fileSystem.readFile(originalPath, from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound(originalPath))
        }
        if case .unavailable("找不到这个媒体文件。") = await fixture.mount.preview(for: originalPath) {
        } else {
            XCTFail("original path preview should be unavailable after workspace trash overlay")
        }

        switch fixture.mount.cachedAssetLookup(at: trashPath) {
        case let .found(asset):
            XCTAssertEqual(asset.localIdentifier, "asset-a")
            XCTAssertEqual(asset.virtualPath, trashPath)
        case .knownMissing:
            XCTFail("trash path should not be known missing")
        case .unknown:
            XCTFail("trash path should resolve through workspace trash overlay")
        }
        XCTAssertEqual(try fileSystem.stat(trashPath, from: "/").virtualPath, trashPath)
        XCTAssertEqual(String(data: try fileSystem.readFile(trashPath, from: "/"), encoding: .utf8), "video-bytes")
        guard case let .media(preview) = await fixture.mount.preview(for: trashPath) else {
            XCTFail("trash path should preview as media through workspace trash overlay")
            return
        }
        XCTAssertEqual(preview.path, trashPath)
        XCTAssertEqual(preview.fileName, fileName)
        XCTAssertEqual(preview.kind, .video)
        XCTAssertEqual(preview.photoLibraryLocalIdentifier, "asset-a")
        XCTAssertEqual(fixture.manifestProvider.resourceDataRequestLocalIdentifiers, ["asset-a"])
    }

    func testPhotoLibraryWorkspaceOverlayKeepsTreeLookupReadPreviewAndRestoreConsistent() async throws {
        let trashedFileName = "ca8d29b0d08a.mov"
        let albumFileName = "544d3b5c5c6b.mov"
        let trashedOriginalPath = "/图库/\(trashedFileName)"
        let trashPath = "/最近删除/\(trashedFileName)"
        let albumPath = "/相册/用户/旅行"
        let albumAssetPath = "\(albumPath)/\(albumFileName)"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-trash", fileName: trashedFileName, mediaType: .video),
                    (identifier: "asset-album", fileName: albumFileName, mediaType: .video)
                ],
                tokenData: Data([0x01])
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        fixture.manifestProvider.resourceDataByLocalIdentifier["asset-trash"] = Data("trash-video-bytes".utf8)
        fixture.manifestProvider.resourceDataByLocalIdentifier["asset-album"] = Data("album-video-bytes".utf8)
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.remove(trashedOriginalPath, from: "/", recursive: false)
        try fileSystem.createDirectory(albumPath, from: "/", intermediates: false)
        try fileSystem.move(
            "/图库/\(albumFileName)",
            to: albumAssetPath,
            from: "/",
            options: [.overwriteExisting]
        )

        XCTAssertEqual(
            Set(try fileSystem.listDirectory("/图库", from: "/").map(\.name)),
            [albumFileName]
        )
        XCTAssertEqual(
            Set(try fileSystem.listDirectoryForPresentation("/图库", from: "/").map(\.name)),
            [albumFileName]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/最近删除", from: "/").map(\.name),
            [trashedFileName]
        )
        XCTAssertEqual(
            try fileSystem.listDirectoryForPresentation("/最近删除", from: "/").map(\.name),
            [trashedFileName]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/用户", from: "/").map(\.name),
            ["旅行"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectoryForPresentation("/相册/用户", from: "/").map(\.name),
            ["旅行"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory(albumPath, from: "/").map(\.name),
            [albumFileName]
        )
        XCTAssertEqual(
            try fileSystem.listDirectoryForPresentation(albumPath, from: "/").map(\.name),
            [albumFileName]
        )

        switch fixture.mount.cachedAssetLookup(at: trashedOriginalPath) {
        case .knownMissing:
            break
        case let .found(asset):
            XCTFail("original path still resolves to \(asset.localIdentifier)")
        case .unknown:
            XCTFail("original path should be known missing after workspace trash overlay")
        }
        XCTAssertThrowsError(try fileSystem.stat(trashedOriginalPath, from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound(trashedOriginalPath))
        }
        XCTAssertThrowsError(try fileSystem.readFile(trashedOriginalPath, from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound(trashedOriginalPath))
        }
        if case .unavailable("找不到这个媒体文件。") = await fixture.mount.preview(for: trashedOriginalPath) {
        } else {
            XCTFail("original path preview should be unavailable after workspace trash overlay")
        }

        switch fixture.mount.cachedAssetLookup(at: trashPath) {
        case let .found(asset):
            XCTAssertEqual(asset.localIdentifier, "asset-trash")
            XCTAssertEqual(asset.virtualPath, trashPath)
        case .knownMissing:
            XCTFail("trash path should not be known missing")
        case .unknown:
            XCTFail("trash path should resolve through workspace trash overlay")
        }
        XCTAssertEqual(try fileSystem.stat(trashPath, from: "/").virtualPath, trashPath)
        XCTAssertEqual(String(data: try fileSystem.readFile(trashPath, from: "/"), encoding: .utf8), "trash-video-bytes")
        guard case let .media(trashPreview) = await fixture.mount.preview(for: trashPath) else {
            XCTFail("trash path should preview as media through workspace trash overlay")
            return
        }
        XCTAssertEqual(trashPreview.path, trashPath)
        XCTAssertEqual(trashPreview.fileName, trashedFileName)
        XCTAssertEqual(trashPreview.kind, .video)
        XCTAssertEqual(trashPreview.photoLibraryLocalIdentifier, "asset-trash")

        switch fixture.mount.cachedAssetLookup(at: albumAssetPath) {
        case let .found(asset):
            XCTAssertEqual(asset.localIdentifier, "asset-album")
            XCTAssertEqual(asset.virtualPath, albumAssetPath)
        case .knownMissing:
            XCTFail("pending album asset should not be known missing")
        case .unknown:
            XCTFail("pending album asset should resolve through workspace overlay")
        }
        XCTAssertEqual(try fileSystem.stat(albumAssetPath, from: "/").virtualPath, albumAssetPath)
        XCTAssertEqual(String(data: try fileSystem.readFile(albumAssetPath, from: "/"), encoding: .utf8), "album-video-bytes")
        guard case let .media(albumPreview) = await fixture.mount.preview(for: albumAssetPath) else {
            XCTFail("pending album asset should preview as media through workspace overlay")
            return
        }
        XCTAssertEqual(albumPreview.path, albumAssetPath)
        XCTAssertEqual(albumPreview.fileName, albumFileName)
        XCTAssertEqual(albumPreview.kind, .video)
        XCTAssertEqual(albumPreview.photoLibraryLocalIdentifier, "asset-album")

        let restoreSummaries = try fileSystem.restoreTrash([trashPath], from: "/", collisionPolicy: .unique)
        XCTAssertEqual(restoreSummaries, [
            MSPWorkspaceTrashRestoreSummary(
                originalPath: trashedOriginalPath,
                restoredPath: trashedOriginalPath,
                originalName: trashedFileName,
                isDirectory: false
            )
        ])
        XCTAssertEqual(try fileSystem.listDirectory("/最近删除", from: "/").map(\.name), [])
        XCTAssertEqual(try fileSystem.listDirectoryForPresentation("/最近删除", from: "/").map(\.name), [])
        XCTAssertEqual(
            Set(try fileSystem.listDirectory("/图库", from: "/").map(\.name)),
            [trashedFileName, albumFileName]
        )
        XCTAssertEqual(
            Set(try fileSystem.listDirectoryForPresentation("/图库", from: "/").map(\.name)),
            [trashedFileName, albumFileName]
        )
        switch fixture.mount.cachedAssetLookup(at: trashedOriginalPath) {
        case let .found(asset):
            XCTAssertEqual(asset.localIdentifier, "asset-trash")
            XCTAssertEqual(asset.virtualPath, trashedOriginalPath)
        case .knownMissing:
            XCTFail("restored original path should no longer be known missing")
        case .unknown:
            XCTFail("restored original path should resolve through cached index plus overlay")
        }
        XCTAssertEqual(try fileSystem.stat(trashedOriginalPath, from: "/").virtualPath, trashedOriginalPath)
        XCTAssertEqual(
            String(data: try fileSystem.readFile(trashedOriginalPath, from: "/"), encoding: .utf8),
            "trash-video-bytes"
        )
        guard case let .media(restoredPreview) = await fixture.mount.preview(for: trashedOriginalPath) else {
            XCTFail("restored original path should preview as media")
            return
        }
        XCTAssertEqual(restoredPreview.path, trashedOriginalPath)
        XCTAssertEqual(restoredPreview.photoLibraryLocalIdentifier, "asset-trash")
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 0)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumCreationCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 1)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testRemovedSystemAlbumAssetStatReturnsMissingFromOverlayWithoutIndexRefresh() throws {
        let fileName = "4f4fb263cf16.jpg"
        let screenshotPath = "/相册/系统/截图/\(fileName)"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.remove(screenshotPath, from: "/", recursive: false)
        fixture.mount.markPhotoLibraryIndexDirty(reason: "test stale path lookup")
        let persistentChangesAfterRemove = fixture.manifestProvider.persistentChangesCallCount
        let makeManifestAfterRemove = fixture.manifestProvider.makeManifestCallCount

        XCTAssertThrowsError(try fileSystem.stat(screenshotPath, from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound(screenshotPath))
        }
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, persistentChangesAfterRemove)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, makeManifestAfterRemove)
        XCTAssertEqual(try fileSystem.listDirectory("/最近删除", from: "/").map(\.name), [fileName])
    }

    func testPhotoSorterRmBatchesPhotoAssetTrashWithoutChangingShellResult() async throws {
        let firstFileName = "4f4fb263cf16.jpg"
        let secondFileName = "544d3b5c5c6b.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: firstFileName, mediaType: .image),
                    (identifier: "asset-b", fileName: secondFileName, mediaType: .image)
                ],
                tokenData: Data([0x01])
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: fixture.workspace))
            .enable(.posixCore(excluding: ["rm"]))
            .enable(PhotoSorterCommandPack(
                photoLibraryMount: fixture.mount,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState()
            ))

        let result = await shell.run("rm -- '/图库/\(firstFileName)' '/图库/\(secondFileName)'")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertThrowsError(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(firstFileName)", from: "/"))
        XCTAssertThrowsError(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(secondFileName)", from: "/"))
        XCTAssertEqual(
            try fixture.workspace.photoLibraryFileSystem.listDirectory("/最近删除", from: "/").map(\.name),
            [firstFileName, secondFileName]
        )
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 2)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testMoveFromWorkspaceTrashRestoresAssetInWorkspaceOnly() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: fileName, tokenData: Data([0x01]))
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem
        try fileSystem.remove("/图库/\(fileName)", from: "/", recursive: false)

        try fileSystem.move(
            "/最近删除/\(fileName)",
            to: "/图库/\(fileName)",
            from: "/",
            options: [.overwriteExisting]
        )

        XCTAssertNoThrow(try fileSystem.stat("/图库/\(fileName)", from: "/"))
        XCTAssertEqual(try fileSystem.listDirectory("/最近删除", from: "/").map(\.name), [])
        XCTAssertFalse(fixture.mount.photoLibraryWorkspaceChangeSummary.hasChanges)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testFlatWorkspaceTrashDisplayDisambiguatesDuplicateNames() throws {
        let overlay = PhotoLibraryWorkspaceOverlay(store: nil)
        let firstAsset = Self.mountedAsset(identifier: "asset-a", name: "a.png")
        let secondAsset = Self.mountedAsset(identifier: "asset-b", name: "a.png")

        try overlay.trashAsset(firstAsset, originalPath: "/图库/a.png")
        try overlay.trashAsset(secondAsset, originalPath: "/相册/用户/旅行/a.png")

        let snapshot = overlay.snapshot
        XCTAssertEqual(
            snapshot.trashRecords.map { snapshot.trashDisplayPath(for: $0) }.sorted(),
            ["/最近删除/a 2.png", "/最近删除/a.png"]
        )
        XCTAssertEqual(
            snapshot.trashAsset(atDisplayPath: "/最近删除/a.png")?.assetReference.localIdentifier,
            "asset-a"
        )
        XCTAssertEqual(
            snapshot.trashAsset(atDisplayPath: "/最近删除/a 2.png")?.assetReference.localIdentifier,
            "asset-b"
        )
    }

    func testRemoveUserAlbumMovesAlbumAndContainedAssetsToWorkspaceTrash() throws {
        let albumPath = "/相册/用户/旅行"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "ca8d29b0d08a.mov", mediaType: .video)
                ],
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: [albumPath],
                userAlbumPaths: [albumPath]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.remove(albumPath, from: "/", recursive: true)

        XCTAssertThrowsError(try fileSystem.stat(albumPath, from: "/"))
        XCTAssertEqual(try fileSystem.listDirectory("/相册/用户", from: "/").map(\.name), [])
        XCTAssertEqual(try fileSystem.listDirectory("/最近删除", from: "/").map(\.name), ["旅行"])
        XCTAssertEqual(
            try fileSystem.listDirectory("/最近删除/旅行", from: "/").map(\.name),
            ["4f4fb263cf16.jpg", "ca8d29b0d08a.mov"]
        )
        XCTAssertEqual(
            fixture.mount.presentationAsset(at: "/最近删除/旅行/4f4fb263cf16.jpg")?.localIdentifier,
            "asset-a"
        )
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 2)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.deletedAlbumCount, 1)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testMoveTrashedUserAlbumOutOfWorkspaceTrashRestoresAlbumAndContainedAssets() throws {
        let albumPath = "/相册/用户/旅行"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "ca8d29b0d08a.mov", mediaType: .video)
                ],
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: [albumPath],
                userAlbumPaths: [albumPath]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.remove(albumPath, from: "/", recursive: true)
        try fileSystem.move(
            "/最近删除/旅行",
            to: albumPath,
            from: "/",
            options: [.overwriteExisting]
        )

        XCTAssertEqual(try fileSystem.listDirectory("/相册/用户", from: "/").map(\.name), ["旅行"])
        XCTAssertEqual(
            try fileSystem.listDirectory(albumPath, from: "/").map(\.name),
            ["4f4fb263cf16.jpg", "ca8d29b0d08a.mov"]
        )
        XCTAssertEqual(try fileSystem.listDirectory("/最近删除", from: "/").map(\.name), [])
        XCTAssertFalse(fixture.mount.photoLibraryWorkspaceChangeSummary.hasChanges)
        XCTAssertTrue(try fixture.mount.photoLibraryWorkspaceSyncChangeSet().isEmpty)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testApplyPendingWorkspaceChangesDeletesTrashedAlbumAndContainedAssets() async throws {
        let albumPath = "/相册/用户/旅行"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "ca8d29b0d08a.mov", mediaType: .video)
                ],
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: [albumPath],
                userAlbumPaths: [albumPath]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )

        try fixture.workspace.photoLibraryFileSystem.remove(albumPath, from: "/", recursive: true)
        try await fixture.mount.applyPendingWorkspaceChangesToPhotoLibrary()

        let changeSet = try XCTUnwrap(fixture.manifestProvider.appliedWorkspaceChangeSets.first)
        XCTAssertEqual(changeSet.deletedAlbums.map(\.albumVirtualPath), [albumPath])
        XCTAssertEqual(changeSet.deletedAlbums.map(\.albumLocalIdentifier), ["album:\(albumPath)"])
        XCTAssertEqual(changeSet.trashedAssetLocalIdentifiers, ["asset-a", "asset-b"])
        XCTAssertFalse(fixture.mount.photoLibraryWorkspaceChangeSummary.hasChanges)
    }

    func testDeleteUserAlbumContainerDoesNotTrashContainedAssets() throws {
        let albumPath = "/相册/用户/旅行"
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: [albumPath],
                userAlbumPaths: [albumPath]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )

        try fixture.mount.deleteUserAlbumContainer(at: albumPath)
        let changeSet = try fixture.mount.photoLibraryWorkspaceSyncChangeSet()

        XCTAssertThrowsError(try fixture.workspace.photoLibraryFileSystem.stat(albumPath, from: "/"))
        XCTAssertNoThrow(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(fileName)", from: "/"))
        XCTAssertEqual(try fixture.workspace.photoLibraryFileSystem.listDirectory("/最近删除", from: "/").map(\.name), [])
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 0)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.deletedAlbumCount, 1)
        XCTAssertEqual(changeSet.deletedAlbums.map(\.albumVirtualPath), [albumPath])
        XCTAssertEqual(changeSet.trashedAssetLocalIdentifiers, [])
    }

    func testWorkspaceTrashOverlayPersistsAcrossMounts() throws {
        let fileName = "4f4fb263cf16.jpg"
        let overlayURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("photo-library-workspace-overlay.json")
        let snapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: fileName,
            tokenData: Data([0x01])
        )
        let firstFixture = try makeWorkspaceFixture(
            persistedSnapshot: snapshot,
            overlayURL: overlayURL
        )
        defer {
            try? FileManager.default.removeItem(at: firstFixture.temporaryDirectory)
            try? FileManager.default.removeItem(at: overlayURL.deletingLastPathComponent())
        }
        firstFixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        try firstFixture.workspace.photoLibraryFileSystem.remove(
            "/图库/\(fileName)",
            from: "/",
            recursive: false
        )

        let secondFixture = try makeWorkspaceFixture(
            persistedSnapshot: snapshot,
            overlayURL: overlayURL
        )
        defer {
            try? FileManager.default.removeItem(at: secondFixture.temporaryDirectory)
        }
        secondFixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )

        XCTAssertEqual(
            try secondFixture.workspace.photoLibraryFileSystem.listDirectory("/最近删除", from: "/").map(\.name),
            [fileName]
        )
        XCTAssertEqual(secondFixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 1)
    }

    func testCreateAlbumAndMoveAssetUpdateWorkspaceOverlayImmediately() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: fileName, tokenData: Data([0x01]))
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.createDirectory("/相册/用户/旅行", from: "/", intermediates: false)
        try fileSystem.move(
            "/图库/\(fileName)",
            to: "/相册/用户/旅行/\(fileName)",
            from: "/",
            options: [.overwriteExisting]
        )

        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/用户", from: "/").map(\.name),
            ["旅行"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/用户/旅行", from: "/").map(\.name),
            [fileName]
        )
        XCTAssertNoThrow(try fileSystem.stat("/图库/\(fileName)", from: "/"))
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumCreationCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 1)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testCopyFromSystemAlbumAddsAssetToUserAlbumWithoutRemovingSource() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem

        try fileSystem.createDirectory("/相册/用户/待删除截图-最旧50张", from: "/", intermediates: false)
        try fileSystem.copy(
            "/相册/系统/截图/\(fileName)",
            to: "/相册/用户/待删除截图-最旧50张/\(fileName)",
            from: "/",
            options: []
        )

        XCTAssertNoThrow(try fileSystem.stat("/相册/系统/截图/\(fileName)", from: "/"))
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/用户/待删除截图-最旧50张", from: "/").map(\.name),
            [fileName]
        )
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumCreationCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipRemovalCount, 0)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testRepeatedCopyToSameUserAlbumDoesNotCreateOverlayMutation() throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem
        let albumPath = "/相册/用户/待确认-可清理截图候选"
        let destination = "\(albumPath)/\(fileName)"

        try fileSystem.createDirectory(albumPath, from: "/", intermediates: false)
        try fileSystem.copy(
            "/相册/系统/截图/\(fileName)",
            to: destination,
            from: "/",
            options: [.overwriteExisting]
        )
        let versionAfterFirstCopy = fixture.mount.photoLibraryWorkspaceChangeSummary.version

        try fileSystem.copy(
            "/相册/系统/截图/\(fileName)",
            to: destination,
            from: "/",
            options: [.overwriteExisting]
        )

        XCTAssertEqual(
            try fileSystem.listDirectory(albumPath, from: "/").map(\.name),
            [fileName]
        )
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.version, versionAfterFirstCopy)
    }

    func testCpMultipleSystemAlbumAssetsAddsUserAlbumReferences() async throws {
        let firstFileName = "4f4fb263cf16.jpg"
        let secondFileName = "544d3b5c5c6b.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: firstFileName, mediaType: .image),
                    (identifier: "asset-b", fileName: secondFileName, mediaType: .image)
                ],
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        let fileSystem = fixture.workspace.photoLibraryFileSystem
        try fileSystem.createDirectory("/相册/用户/待确认-可清理截图候选", from: "/", intermediates: false)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: fixture.workspace))
            .enable(.posixCore)

        let result = await shell.run("""
        cp -- '/相册/系统/截图/\(firstFileName)' '/相册/系统/截图/\(secondFileName)' '/相册/用户/待确认-可清理截图候选/'
        """)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertNoThrow(try fileSystem.stat("/相册/系统/截图/\(firstFileName)", from: "/"))
        XCTAssertNoThrow(try fileSystem.stat("/相册/系统/截图/\(secondFileName)", from: "/"))
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/用户/待确认-可清理截图候选", from: "/").map(\.name),
            [firstFileName, secondFileName]
        )
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumCreationCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 2)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipRemovalCount, 0)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testAlbumAddFromFileAddsAssetReferencesToUserAlbum() async throws {
        let firstFileName = "4f4fb263cf16.jpg"
        let secondFileName = "544d3b5c5c6b.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: firstFileName, mediaType: .image),
                    (identifier: "asset-b", fileName: secondFileName, mediaType: .image)
                ],
                tokenData: Data([0x01])
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        try fixture.workspace.photoLibraryFileSystem.writeFile(
            "/tmp/low_value_paths.txt",
            data: Data("/图库/\(firstFileName)\n/图库/\(secondFileName)\n/图库/\(firstFileName)\n".utf8),
            from: "/",
            options: [.createParentDirectories]
        )
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: fixture.workspace))
            .enable(PhotoSorterCommandPack(
                photoLibraryMount: fixture.mount,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState()
            ))

        let result = await shell.run("album add --create --from-file /tmp/low_value_paths.txt /相册/用户/待删除-低价值截图候选")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("added 2"))
        XCTAssertTrue(result.stdout.contains("skipped_existing 1"))
        XCTAssertTrue(result.stdout.contains("requested 3"))
        XCTAssertEqual(
            try fixture.workspace.photoLibraryFileSystem.listDirectory(
                "/相册/用户/待删除-低价值截图候选",
                from: "/"
            ).map(\.name),
            [firstFileName, secondFileName]
        )
        XCTAssertNoThrow(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(firstFileName)", from: "/"))
        XCTAssertNoThrow(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(secondFileName)", from: "/"))
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumCreationCount, 1)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 2)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testAlbumRemoveFromFileRemovesAssetReferencesFromUserAlbum() async throws {
        let albumPath = "/相册/用户/旅行"
        let firstFileName = "4f4fb263cf16.jpg"
        let secondFileName = "544d3b5c5c6b.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: firstFileName, mediaType: .image),
                    (identifier: "asset-b", fileName: secondFileName, mediaType: .image)
                ],
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: [albumPath],
                userAlbumPaths: [albumPath]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )
        try fixture.workspace.photoLibraryFileSystem.writeFile(
            "/tmp/selected_from_album.txt",
            data: Data(
                """
                \(albumPath)/\(firstFileName)
                /图库/\(secondFileName)
                /图库/\(firstFileName)
                """.utf8
            ),
            from: "/",
            options: [.createParentDirectories]
        )
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: fixture.workspace))
            .enable(PhotoSorterCommandPack(
                photoLibraryMount: fixture.mount,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState()
            ))

        let result = await shell.run("album remove --from-file /tmp/selected_from_album.txt \(albumPath)")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("removed 2"))
        XCTAssertTrue(result.stdout.contains("skipped_not_in_album 1"))
        XCTAssertTrue(result.stdout.contains("requested 3"))
        XCTAssertEqual(
            try fixture.workspace.photoLibraryFileSystem.listDirectory(albumPath, from: "/").map(\.name),
            []
        )
        XCTAssertNoThrow(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(firstFileName)", from: "/"))
        XCTAssertNoThrow(try fixture.workspace.photoLibraryFileSystem.stat("/图库/\(secondFileName)", from: "/"))
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipAdditionCount, 0)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.pendingAlbumMembershipRemovalCount, 2)
        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
    }

    func testFindEmptyUserAlbumUsesWorkspaceSnapshotWithoutBlockingPhotoLibraryRefresh() async throws {
        let albumPath = "/相册/用户/待删除-明显可删截图候选"
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [],
                tokenData: savedToken,
                userAlbumPaths: [albumPath]
            ),
            usesPresentationPhotoLibraryReads: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 1,
            updatedAssetLocalIdentifiers: ["external-change"]
        )
        let directInfo = try fixture.workspace.photoLibraryFileSystem.stat(albumPath, from: "/")
        XCTAssertEqual(directInfo.type, .directory)
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
        let directTestCommandResult = try await MSPTestCommand(name: "[").run(
            invocation: MSPCommandInvocation(name: "[", arguments: ["-d", albumPath, "]"]),
            context: MSPConfiguration(workspace: fixture.workspace).makeCommandContext()
        )
        XCTAssertEqual(directTestCommandResult.exitCode, 0)
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: fixture.workspace))
            .enable(.posixCore(excluding: ["rm"]))
            .enable(PhotoSorterCommandPack(
                photoLibraryMount: fixture.mount,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState()
            ))

        let result = await shell.run("""
        if [ -d '\(albumPath)' ]; then echo 'exists'; find '\(albumPath)' -maxdepth 1 -type f | wc -l; else echo 'missing'; fi
        """)

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(lines, ["exists", "0"])
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testFindGalleryFromShellUsesPresentationSnapshotWithoutBlockingPhotoLibraryRefresh() async throws {
        let fileName = "4f4fb263cf16.jpg"
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                tokenData: savedToken
            ),
            usesPresentationPhotoLibraryReads: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 1,
            updatedAssetLocalIdentifiers: ["asset-a"]
        )
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: fixture.workspace))
            .enable(.posixCore(excluding: ["rm"]))
            .enable(PhotoSorterCommandPack(
                photoLibraryMount: fixture.mount,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState()
            ))

        let result = await shell.run("""
        find / -maxdepth 3 -type f \\( -iname '*.png' -o -iname '*.jpg' \\) 2>/dev/null | head -1
        """)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "/图库/\(fileName)")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testUserAlbumFileStatUsesWorkspaceSnapshotWithoutBlockingPhotoLibraryRefresh() throws {
        let albumPath = "/相册/用户/待删除-明显可删截图候选"
        let fileName = "4f4fb263cf16.jpg"
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: fileName,
                tokenData: savedToken,
                additionalAssetDirectoryPaths: [albumPath],
                userAlbumPaths: [albumPath]
            ),
            usesPresentationPhotoLibraryReads: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 1,
            updatedAssetLocalIdentifiers: ["external-change"]
        )

        let info = try fixture.workspace.photoLibraryFileSystem.stat("\(albumPath)/\(fileName)", from: "/")

        XCTAssertEqual(info.virtualPath, "\(albumPath)/\(fileName)")
        XCTAssertEqual(info.type, .regularFile)
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testApplyPendingWorkspaceChangesWritesThroughProviderAndClearsOverlay() async throws {
        let fileName = "4f4fb263cf16.jpg"
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: fileName, tokenData: Data([0x01]))
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let fileSystem = fixture.workspace.photoLibraryFileSystem
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x02])
        )

        try fileSystem.createDirectory("/相册/用户/旅行", from: "/", intermediates: false)
        try fileSystem.move(
            "/图库/\(fileName)",
            to: "/相册/用户/旅行/\(fileName)",
            from: "/",
            options: [.overwriteExisting]
        )
        try fileSystem.remove("/图库/\(fileName)", from: "/", recursive: false)

        try await fixture.mount.applyPendingWorkspaceChangesToPhotoLibrary()

        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.appliedWorkspaceChangeSets.first?.trashedAssetLocalIdentifiers, ["asset-a"])
        XCTAssertEqual(fixture.manifestProvider.appliedWorkspaceChangeSets.first?.createdAlbums.map(\.name), ["旅行"])
        XCTAssertFalse(fixture.mount.photoLibraryWorkspaceChangeSummary.hasChanges)
    }

    func testApplyPendingWorkspaceChangesReportsConflictsAndKeepsOverlay() async throws {
        let fileName = "4f4fb263cf16.jpg"
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(assetIdentifier: "asset-a", fileName: fileName, tokenData: savedToken)
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        let fileSystem = fixture.workspace.photoLibraryFileSystem
        fixture.manifestProvider.currentTokenData = savedToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: savedToken,
            changeCount: 0
        )

        try fileSystem.remove("/图库/\(fileName)", from: "/", recursive: false)

        var changes = PhotoLibraryPersistentChangeSummary(latestTokenData: freshToken, changeCount: 1)
        changes.deletedAssetLocalIdentifiers = ["asset-a"]
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = changes
        fixture.manifestProvider.incrementalManifest = Self.manifestScan(from: Self.snapshot(
            assetRecords: [],
            tokenData: freshToken
        ))
        fixture.mount.markPhotoLibraryIndexDirty(reason: "test conflict")

        do {
            try await fixture.mount.applyPendingWorkspaceChangesToPhotoLibrary()
            XCTFail("Expected workspace sync conflict")
        } catch let error as PhotoLibraryWorkspaceSyncConflictError {
            XCTAssertEqual(error.conflicts.count, 1)
            XCTAssertTrue(error.conflicts[0].message.contains("删除照片失败"))
        }

        XCTAssertEqual(fixture.manifestProvider.applyWorkspaceChangesCallCount, 0)
        XCTAssertEqual(fixture.mount.photoLibraryWorkspaceChangeSummary.trashedAssetCount, 1)
    }

    func testBlockingListingTrustsPersistedCacheWhenPersistentChangesAreEmpty() throws {
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: "4f4fb263cf16.jpg",
                tokenData: savedToken
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 0
        )

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.name), ["4f4fb263cf16.jpg"])
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testBlockingListingUsesIncrementalManifestForPersistentChanges() throws {
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let initialSnapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.jpg",
            tokenData: savedToken
        )
        let incrementalSnapshot = Self.snapshot(
            assetIdentifier: "asset-b",
            fileName: "544d3b5c5c6b.jpg",
            tokenData: freshToken
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: initialSnapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        var changes = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 1
        )
        changes.insertedAssetLocalIdentifiers = ["asset-b"]
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = changes
        fixture.manifestProvider.incrementalManifest = Self.manifestScan(from: incrementalSnapshot)

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testBlockingListingSkipsIncrementalManifestWhenUpdatedAssetIndexedFieldsAreUnchanged() throws {
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let snapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.jpg",
            tokenData: savedToken
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: snapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        var changes = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 1
        )
        changes.updatedAssetLocalIdentifiers = ["asset-a"]
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = changes
        fixture.manifestProvider.assetRecordsByLocalIdentifier = Self.manifestScan(from: snapshot).assetRecords

        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.name), ["4f4fb263cf16.jpg"])
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.manifestAssetRecordRequestLocalIdentifiers, ["asset-a"])
    }

    func testOCRCachePreheatUsesAvailableCachedSnapshotWithoutRevalidation() async throws {
        let savedToken = Data([0x01])
        let freshToken = Data([0x02])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: "4f4fb263cf16.jpg",
                tokenData: savedToken
            ),
            ocrRecognitionOverride: { _, _ in "cached snapshot text" }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = freshToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: freshToken,
            changeCount: 0
        )
        _ = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        fixture.mount.startOCRCachePreheatBatch(limit: 1)
        try await waitForOCRPreheatToFinish(fixture.mount)

        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testOCRCachePreheatUsesPersistedSnapshotEvenWhenIndexIsNotReady() async throws {
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: "4f4fb263cf16.jpg",
                tokenData: Data([0x01])
            ),
            ocrRecognitionOverride: { _, _ in "persisted snapshot text" }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startOCRCachePreheatBatch(limit: 1)
        try await waitForOCRPreheatToFinish(fixture.mount)

        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
        XCTAssertNotEqual(fixture.mount.photoLibraryOCRCacheStatus.message, "暂无照片库缓存")
    }

    func testOCRCachePreheatWithoutLimitCachesEveryUncachedImage() async throws {
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image),
                    (identifier: "asset-c", fileName: "804610ad3361.png", mediaType: .image),
                    (identifier: "asset-v", fileName: "ca8d29b0d08a.mov", mediaType: .video)
                ]
            ),
            ocrRecognitionOverride: { asset, _ in
                "text for \(asset.localIdentifier)"
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startOCRCachePreheatBatch()
        try await waitForOCRPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryOCRCacheStatus
        XCTAssertEqual(status.totalCount, 3)
        XCTAssertEqual(status.cachedCount, 3)
        XCTAssertEqual(status.processedInCurrentBatch, 3)
        XCTAssertEqual(status.batchLimit, 3)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "OCR 缓存已全部完成")
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testOCRImageTargetSizeDownscalesLargeImagesWithoutUpscalingSmallImages() {
        func asset(name: String, width: Int, height: Int) -> PhotoLibraryMount.MountedAsset {
            PhotoLibraryMount.MountedAsset(
                name: name,
                virtualPath: "/图库/\(name)",
                localIdentifier: "asset-\(name)",
                mediaType: .image,
                mediaSubtypes: [],
                pixelWidth: width,
                pixelHeight: height,
                creationDate: nil,
                modificationDate: nil,
                locationLatitude: nil,
                locationLongitude: nil,
                locationHorizontalAccuracy: nil
            )
        }

        let largeAsset = asset(name: "large.jpg", width: 6000, height: 4000)
        let readableWideAsset = asset(name: "wide.jpg", width: 3000, height: 1500)
        let readableTallAsset = asset(name: "tall.jpg", width: 1170, height: 2532)
        let longScreenshotAsset = asset(name: "long.png", width: 1170, height: 8000)
        let smallAsset = asset(name: "small.jpg", width: 1200, height: 800)

        let largeTargetSize = PhotoLibraryMount.ocrImageTargetSize(for: largeAsset)
        let readableWideTargetSize = PhotoLibraryMount.ocrImageTargetSize(for: readableWideAsset)
        let readableTallTargetSize = PhotoLibraryMount.ocrImageTargetSize(for: readableTallAsset)
        let longScreenshotPlan = PhotoLibraryMount.ocrImagePlan(for: longScreenshotAsset)
        let smallTargetSize = PhotoLibraryMount.ocrImageTargetSize(for: smallAsset)
        let previewWideTargetSize = PhotoLibraryMount.previewImageTargetSize(for: readableWideAsset)
        let previewTallTargetSize = PhotoLibraryMount.previewImageTargetSize(for: readableTallAsset)

        XCTAssertEqual(largeTargetSize.width, 2048, accuracy: 0.001)
        XCTAssertEqual(largeTargetSize.height, 1365.333, accuracy: 0.001)
        XCTAssertEqual(readableWideTargetSize.width, 2160, accuracy: 0.001)
        XCTAssertEqual(readableWideTargetSize.height, 1080, accuracy: 0.001)
        XCTAssertEqual(readableTallTargetSize.width, 1080, accuracy: 0.001)
        XCTAssertEqual(readableTallTargetSize.height, 2337.231, accuracy: 0.001)
        XCTAssertEqual(longScreenshotPlan.targetSize.width, 1080, accuracy: 0.001)
        XCTAssertEqual(longScreenshotPlan.targetSize.height, 7384.615, accuracy: 0.001)
        XCTAssertTrue(longScreenshotPlan.usesTiling)
        XCTAssertEqual(longScreenshotPlan.estimatedTileCount, 3)
        XCTAssertEqual(smallTargetSize.width, 1200, accuracy: 0.001)
        XCTAssertEqual(smallTargetSize.height, 800, accuracy: 0.001)
        XCTAssertEqual(previewWideTargetSize.width, 2160, accuracy: 0.001)
        XCTAssertEqual(previewWideTargetSize.height, 1080, accuracy: 0.001)
        XCTAssertEqual(previewTallTargetSize.width, 1080, accuracy: 0.001)
        XCTAssertEqual(previewTallTargetSize.height, 2337.231, accuracy: 0.001)
    }

    func testOCRImageTilesSplitLongImagesAlongLongestAxis() throws {
        let image = try Self.blankCGImage(width: 8, height: 7385)

        let tiles = PhotoLibraryMount.ocrImageTiles(for: image)

        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles.map(\.index), [0, 1, 2])
        XCTAssertEqual(tiles.map(\.count), [3, 3, 3])
        XCTAssertEqual(tiles.map(\.rect), [
            CGRect(x: 0, y: 0, width: 8, height: 3072),
            CGRect(x: 0, y: 2912, width: 8, height: 3072),
            CGRect(x: 0, y: 4313, width: 8, height: 3072)
        ])
    }

    func testOCRTileTextMergeDropsOverlapDuplicates() {
        let merged = PhotoLibraryMount.mergedOCRTileTexts([
            "first\nshared one\nshared two",
            "shared one\nshared two\nsecond",
            "second\nthird"
        ])

        XCTAssertEqual(merged, "first\nshared one\nshared two\nsecond\nthird")
    }

    func testOCRCacheStatusProgressTracksCachedCoverage() {
        let status = PhotoSorterMediaOCRCacheStatus(
            cachedCount: 10,
            totalCount: 100,
            isPreheating: true,
            isPaused: false,
            processedInCurrentBatch: 2,
            batchLimit: 4,
            message: "OCR 缓存 2/4"
        )

        XCTAssertEqual(status.progressFraction, 0.1)
    }

    func testMediaCachesCanDeferPersistenceUntilFlush() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let ocrCacheURL = temporaryDirectory.appendingPathComponent("ocr-cache.json")
        let placeCacheURL = temporaryDirectory.appendingPathComponent("place-cache.json")
        let ocrCache = PhotoSorterMediaOCRCache(fileURL: ocrCacheURL)
        let placeCache = PhotoSorterMediaPlaceCache(fileURL: placeCacheURL)

        try ocrCache.store(
            text: "hello",
            localIdentifier: "asset-a",
            assetVersion: "ocr-v1",
            persistImmediately: false
        )
        try placeCache.store(
            place: "上海",
            localIdentifier: "asset-a",
            locationVersion: "place-v1",
            persistImmediately: false
        )

        XCTAssertEqual(
            ocrCache.text(localIdentifier: "asset-a", assetVersion: "ocr-v1"),
            "hello"
        )
        XCTAssertEqual(
            placeCache.place(localIdentifier: "asset-a", locationVersion: "place-v1"),
            "上海"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ocrCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: placeCacheURL.path))
        XCTAssertNil(PhotoSorterMediaOCRCache(fileURL: ocrCacheURL).text(
            localIdentifier: "asset-a",
            assetVersion: "ocr-v1"
        ))
        XCTAssertNil(PhotoSorterMediaPlaceCache(fileURL: placeCacheURL).place(
            localIdentifier: "asset-a",
            locationVersion: "place-v1"
        ))

        try ocrCache.flush()
        try placeCache.flush()

        XCTAssertEqual(
            PhotoSorterMediaOCRCache(fileURL: ocrCacheURL).text(
                localIdentifier: "asset-a",
                assetVersion: "ocr-v1"
            ),
            "hello"
        )
        XCTAssertEqual(
            PhotoSorterMediaPlaceCache(fileURL: placeCacheURL).place(
                localIdentifier: "asset-a",
                locationVersion: "place-v1"
            ),
            "上海"
        )
    }

    func testMediaAskExclusionCachePersistsCountsByLocalIdentifier() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let cacheURL = temporaryDirectory.appendingPathComponent("media-ask-exclusions.json")
        let cache = PhotoSorterMediaAskExclusionCache(fileURL: cacheURL)

        XCTAssertEqual(cache.count(localIdentifier: "asset-a"), 0)

        try cache.increment(localIdentifiers: ["asset-a", "asset-a", "asset-b"])

        XCTAssertEqual(cache.count(localIdentifier: "asset-a"), 1)
        XCTAssertEqual(cache.count(localIdentifier: "asset-b"), 1)
        XCTAssertEqual(cache.counts(localIdentifiers: ["asset-a", "asset-b", "missing"]), [1, 1, 0])

        let persistedCache = PhotoSorterMediaAskExclusionCache(fileURL: cacheURL)
        XCTAssertEqual(persistedCache.count(localIdentifier: "asset-a"), 1)
        XCTAssertEqual(persistedCache.count(localIdentifier: "asset-b"), 1)

        try persistedCache.increment(localIdentifiers: ["asset-a"])

        XCTAssertEqual(PhotoSorterMediaAskExclusionCache(fileURL: cacheURL).count(localIdentifier: "asset-a"), 2)
    }

    func testMediaCacheGenerationAndValidCountsTrackStores() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let ocrCache = PhotoSorterMediaOCRCache(
            fileURL: temporaryDirectory.appendingPathComponent("ocr-cache.json")
        )
        let vlmCacheURL = temporaryDirectory.appendingPathComponent("vlm-cache.json")
        let vlmCache = PhotoSorterMediaVLMSummaryCache(fileURL: vlmCacheURL)
        let vlmKey = PhotoSorterMediaVLMSummaryCacheKey(
            localIdentifier: "asset-a",
            assetVersion: "v1",
            providerKind: "local",
            modelID: "fastvlm",
            modelVersion: "1",
            processorConfigFingerprint: "processor",
            promptVersion: "prompt",
            language: "zh-Hans",
            summarySchemaVersion: 1
        )

        XCTAssertEqual(ocrCache.generation, 0)
        XCTAssertEqual(
            ocrCache.validEntryCount(for: [
                PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-a", assetVersion: "v1")
            ]).validCount,
            0
        )

        let firstOCRStore = try ocrCache.store(
            text: "alpha",
            localIdentifier: "asset-a",
            assetVersion: "v1"
        )
        XCTAssertTrue(firstOCRStore.insertedValidEntry)
        XCTAssertEqual(firstOCRStore.generation, 1)
        XCTAssertEqual(
            ocrCache.validEntryCount(for: [
                PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-a", assetVersion: "v1"),
                PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-a", assetVersion: "v2")
            ]).validCount,
            1
        )

        let secondOCRStore = try ocrCache.store(
            text: "alpha updated",
            localIdentifier: "asset-a",
            assetVersion: "v1"
        )
        XCTAssertFalse(secondOCRStore.insertedValidEntry)
        XCTAssertEqual(secondOCRStore.generation, 2)

        let firstVLMStore = try vlmCache.store(summary: "summary", for: vlmKey)
        XCTAssertTrue(firstVLMStore.insertedValidEntry)
        XCTAssertEqual(firstVLMStore.generation, 1)
        XCTAssertEqual(vlmCache.validEntryCount(for: [vlmKey]).validCount, 1)
        let staleVLMKey = PhotoSorterMediaVLMSummaryCacheKey(
            localIdentifier: vlmKey.localIdentifier,
            assetVersion: "modified:0|size:1x1|vlm-cache:1",
            providerKind: vlmKey.providerKind,
            modelID: vlmKey.modelID,
            modelVersion: vlmKey.modelVersion,
            processorConfigFingerprint: vlmKey.processorConfigFingerprint,
            promptVersion: vlmKey.promptVersion,
            language: vlmKey.language,
            summarySchemaVersion: vlmKey.summarySchemaVersion
        )
        XCTAssertEqual(vlmCache.validEntryCount(for: [staleVLMKey]).validCount, 0)

        let secondVLMStore = try vlmCache.store(summary: "summary updated", for: vlmKey)
        XCTAssertFalse(secondVLMStore.insertedValidEntry)
        XCTAssertEqual(secondVLMStore.generation, 2)

        let persistedVLMCache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: vlmCacheURL)) as? [String: Any]
        )
        let persistedVLMEntries = try XCTUnwrap(persistedVLMCache["entries"] as? [String: Any])
        let persistedVLMEntry = try XCTUnwrap(persistedVLMEntries.values.first as? [String: Any])
        XCTAssertEqual(Set(persistedVLMEntry.keys), ["summary"])
        XCTAssertEqual(persistedVLMEntry["summary"] as? String, "summary updated")
    }

    func testDefaultVLMPreheatRunsContinuouslyWithBoundedInputImages() {
        XCTAssertNil(PhotoLibraryMount.defaultVLMSummaryPreheatBatchLimit)
        XCTAssertEqual(PhotoLibraryMount.vlmMaximumInputLongPixelDimension, 1536)
        XCTAssertEqual(PhotoSorterMediaVLMSummaryCache.configurationVersion, 2)
    }

    func testVLMSummaryCachePreheatWithoutLimitCachesEveryUncachedImage() async throws {
        let provider = CountingVLMSummaryProvider()
        let imageRequests = CountingVLMImageRequests()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image),
                    (identifier: "asset-c", fileName: "804610ad3361.png", mediaType: .image),
                    (identifier: "asset-v", fileName: "ca8d29b0d08a.mov", mediaType: .video)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { asset in
                imageRequests.record(asset)
                return Self.blankCIImage()
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitForVLMPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.totalCount, 3)
        XCTAssertEqual(status.cachedCount, 3)
        XCTAssertEqual(status.processedInCurrentBatch, 3)
        XCTAssertEqual(status.batchLimit, 3)
        XCTAssertEqual(status.failedInCurrentBatch, 0)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "视觉摘要缓存已全部完成")
        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(imageRequests.requestedLocalIdentifiers.sorted(), ["asset-a", "asset-b", "asset-c"])
        XCTAssertEqual(fixture.mount.photoLibraryOCRCacheStatus.cachedCount, 0)
    }

    func testVLMSummaryCachePreheatContinuesAfterProviderError() async throws {
        let provider = FailingVLMSummaryProvider(failingRequestNumbers: [1])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image),
                    (identifier: "asset-c", fileName: "804610ad3361.png", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                Self.blankCIImage()
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitForVLMPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.totalCount, 3)
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 3)
        XCTAssertEqual(status.batchLimit, 3)
        XCTAssertEqual(status.failedInCurrentBatch, 1)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "视觉摘要缓存本轮已处理 3/3，写入 2，跳过 0，失败 1")
        XCTAssertEqual(provider.requestCount, 3)
    }

    func testVLMSummaryCachePreheatCountsMLXAllocationFailureAndContinues() async throws {
        let allocationError = NSError(
            domain: "PhotoSorterTests.VLM",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "[malloc_or_wait] Unable to allocate 268435456 bytes."
            ]
        )
        XCTAssertFalse(PhotoLibraryMount.isVLMForegroundExecutionDenied(allocationError))
        let provider = FailingVLMSummaryProvider(
            failingRequestNumbers: [1],
            failureMessage: allocationError.localizedDescription
        )
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image),
                    (identifier: "asset-c", fileName: "804610ad3361.png", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                Self.blankCIImage()
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitForVLMPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.totalCount, 3)
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 3)
        XCTAssertEqual(status.batchLimit, 3)
        XCTAssertEqual(status.failedInCurrentBatch, 1)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "视觉摘要缓存本轮已处理 3/3，写入 2，跳过 0，失败 1")
        XCTAssertEqual(provider.requestCount, 3)
    }

    func testVLMSummaryCachePreheatWaitsForForegroundBeforeInference() async throws {
        let provider = CountingVLMSummaryProvider()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                Self.blankCIImage()
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.setVLMSummaryInferenceForegroundAllowed(false)
        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitUntil {
            let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
            return status.isPreheating
                && !status.isPaused
                && status.processedInCurrentBatch == 0
                && status.message == "等待前台继续视觉摘要 0/2"
        }
        XCTAssertEqual(provider.requestCount, 0)

        fixture.mount.setVLMSummaryInferenceForegroundAllowed(true)
        try await waitForVLMPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.failedInCurrentBatch, 0)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testVLMSummaryCachePreheatSkipsStaleForegroundPermissionErrorWhenAlreadyActive() async throws {
        let provider = ForegroundDeniedOnceVLMSummaryProvider()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                Self.blankCIImage()
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitForVLMPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.cachedCount, 1)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(status.failedInCurrentBatch, 1)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertFalse(status.isPreheating)
        XCTAssertEqual(status.message, "视觉摘要缓存本轮已处理 2/2，写入 1，跳过 0，失败 1")
    }

    func testVLMSummaryCachePreheatDefersInFlightBackgroundGPUPermissionError() async throws {
        let provider = BlockingForegroundDeniedOnceVLMSummaryProvider()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                Self.blankCIImage()
            }
        )
        defer {
            provider.releaseFirstRequest()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitUntil {
            provider.requestCount == 1
        }

        fixture.mount.setVLMSummaryInferenceForegroundAllowed(false)
        provider.releaseFirstRequest()
        try await waitUntil {
            provider.foregroundDeniedErrorCount == 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await waitUntil {
            let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
            return status.isPreheating
                && !status.isPaused
                && status.processedInCurrentBatch == 0
                && status.failedInCurrentBatch == 0
                && status.message == "等待前台继续视觉摘要 0/1"
        }

        fixture.mount.setVLMSummaryInferenceForegroundAllowed(true)
        try await waitForVLMPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.cachedCount, 1)
        XCTAssertEqual(status.processedInCurrentBatch, 1)
        XCTAssertEqual(status.failedInCurrentBatch, 0)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(status.message, "视觉摘要缓存已全部完成")
    }

    func testVLMSummaryCachePreheatDownsamplesImageBeforeProvider() async throws {
        let provider = CountingVLMSummaryProvider()
        let sourceExtent = CGRect(x: 0, y: 0, width: 4321, height: 8765)
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-large", fileName: "4f4fb263cf16.jpg", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
                    .cropped(to: sourceExtent)
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitForVLMPreheatToFinish(fixture.mount)

        let receivedExtents = provider.imageExtents
        XCTAssertEqual(receivedExtents.count, 1)
        XCTAssertLessThanOrEqual(
            max(receivedExtents[0].width, receivedExtents[0].height),
            CGFloat(PhotoLibraryMount.vlmMaximumInputLongPixelDimension)
        )
        XCTAssertLessThan(receivedExtents[0].width, sourceExtent.width)
        XCTAssertLessThan(receivedExtents[0].height, sourceExtent.height)
        XCTAssertEqual(fixture.mount.photoLibraryVLMSummaryCacheStatus.cachedCount, 1)
    }

    func testVLMSummaryCachePreheatCanPauseAndResumeCurrentBatch() async throws {
        let provider = BlockingVLMSummaryProvider()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image)
                ]
            ),
            vlmSummaryProvider: provider,
            vlmImageOverride: { _ in
                Self.blankCIImage()
            }
        )
        defer {
            provider.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startVLMSummaryCachePreheatBatch()
        try await waitUntil {
            provider.requestCount >= 1
        }

        fixture.mount.pauseVLMSummaryCachePreheat()
        var status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertFalse(status.isPreheating)
        XCTAssertTrue(status.isPaused)
        XCTAssertEqual(status.processedInCurrentBatch, 0)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.failedInCurrentBatch, 0)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertEqual(status.message, "视觉摘要缓存已暂停 0/2")

        provider.releaseOne()
        try await waitUntil {
            let status = fixture.mount.photoLibraryVLMSummaryCacheStatus
            return status.isPaused && status.processedInCurrentBatch == 1
        }
        XCTAssertEqual(provider.requestCount, 1)

        fixture.mount.resumeVLMSummaryCachePreheat()
        status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertTrue(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.processedInCurrentBatch, 1)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "继续视觉摘要缓存 1/2")

        try await waitUntil {
            provider.requestCount >= 2
        }
        provider.releaseOne()
        try await waitForVLMPreheatToFinish(fixture.mount)

        status = fixture.mount.photoLibraryVLMSummaryCacheStatus
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.totalCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.failedInCurrentBatch, 0)
        XCTAssertEqual(status.skippedInCurrentBatch, 0)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "视觉摘要缓存已全部完成")
    }

    func testOCRCacheBulkTextsPreservesOrderDuplicatesAndVersionChecks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let cache = PhotoSorterMediaOCRCache(
            fileURL: temporaryDirectory.appendingPathComponent("ocr-cache.json")
        )
        try cache.store(
            text: "alpha text",
            localIdentifier: "asset-a",
            assetVersion: "v1"
        )
        try cache.store(
            text: "beta text",
            localIdentifier: "asset-b",
            assetVersion: "v2"
        )

        let texts = cache.texts(for: [
            PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-a", assetVersion: "v1"),
            PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-b", assetVersion: "wrong"),
            PhotoSorterMediaOCRCacheRequest(localIdentifier: "missing", assetVersion: "v1"),
            PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-a", assetVersion: "v1"),
            PhotoSorterMediaOCRCacheRequest(localIdentifier: "asset-b", assetVersion: "v2")
        ])

        XCTAssertEqual(texts.count, 5)
        XCTAssertEqual(texts[0], "alpha text")
        XCTAssertNil(texts[1])
        XCTAssertNil(texts[2])
        XCTAssertEqual(texts[3], "alpha text")
        XCTAssertEqual(texts[4], "beta text")
    }

    func testPhotoLibraryMountCachedOCRBatchLookupPreservesOrderAndDoesNotRunLiveOCR() async throws {
        let recognizer = CountingOCRRecognitionOverride([
            "/图库/a.png": "验证码 123456"
        ])
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "a.png", mediaType: .image),
                    (identifier: "asset-video", fileName: "video.mov", mediaType: .video)
                ]
            ),
            ocrRecognitionOverride: { asset, outputPath in
                recognizer.recognize(asset: asset, outputPath: outputPath)
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let liveResult = try await fixture.mount.recognizePhotoSorterMediaOCRText(for: "/图库/a.png")
        XCTAssertEqual(liveResult?.source, .live)
        XCTAssertEqual(recognizer.requestPaths, ["/图库/a.png"])

        let lookups = fixture.mount.cachedPhotoSorterMediaOCRTexts(for: [
            "/图库/a.png",
            "/图库/missing.png",
            "/图库/video.mov",
            "/图库/a.png"
        ])

        XCTAssertEqual(recognizer.requestPaths, ["/图库/a.png"])
        XCTAssertEqual(lookups.count, 4)
        XCTAssertEqual(
            lookups,
            [
                .hit(PhotoSorterMediaOCRResult(
                    path: "/图库/a.png",
                    text: "验证码 123456",
                    source: .cache
                )),
                .unavailable("media asset not found"),
                .unavailable("OCR supports images only"),
                .hit(PhotoSorterMediaOCRResult(
                    path: "/图库/a.png",
                    text: "验证码 123456",
                    source: .cache
                ))
            ]
        )
    }

    func testWorkspaceOverlayEffectiveAssetsPageOnlyResolvesRequestedWindow() {
        let overlaySnapshot = PhotoLibraryWorkspaceOverlay(store: nil).snapshot
        let identifiers = (1...1_000).map { "asset-\($0)" }
        var resolvedIdentifiers: [String] = []

        let assets = overlaySnapshot.effectiveAssetsPage(
            in: "/图库",
            baseAssetLocalIdentifiers: identifiers,
            offset: 10,
            limit: 2
        ) { identifier in
            resolvedIdentifiers.append(identifier)
            return Self.mountedAsset(identifier: identifier)
        }

        XCTAssertEqual(resolvedIdentifiers, Array(identifiers.prefix(12)))
        XCTAssertEqual(assets.map(\.localIdentifier), ["asset-11", "asset-12"])
    }

    func testPhotoLibraryImageRequestsRejectDegradedResults() {
        XCTAssertTrue(PhotoLibraryMount.imageRequestResultIsDegraded([
            PHImageResultIsDegradedKey: true
        ]))
        XCTAssertFalse(PhotoLibraryMount.imageRequestResultIsDegraded([
            PHImageResultIsDegradedKey: false
        ]))
        XCTAssertFalse(PhotoLibraryMount.imageRequestResultIsDegraded(nil))
    }

#if canImport(UIKit) && canImport(Vision)
    func testVisionOCRRecognizesReadableTextAfterShortSideDownscale() async throws {
        let image = await MainActor.run {
            Self.liveOCRProbeImage(size: CGSize(width: 3000, height: 1500))
        }
        let targetSize = PhotoSorterModelImageSizing.targetSize(
            width: Int(image.size.width),
            height: Int(image.size.height)
        )
        XCTAssertEqual(targetSize.width, 2160, accuracy: 0.001)
        XCTAssertEqual(targetSize.height, 1080, accuracy: 0.001)

        let resizedImage = await MainActor.run {
            Self.renderOCRProbeImage(image, targetSize: targetSize)
        }
        let cgImage = try XCTUnwrap(resizedImage.cgImage)
        XCTAssertEqual(cgImage.width, 2160)
        XCTAssertEqual(cgImage.height, 1080)

        let text = try Self.recognizedTextForOCRProbe(from: cgImage)
        print("PHOTOSORTER_SIMULATOR_OCR_TARGET_SIZE source=3000x1500 target=\(cgImage.width)x\(cgImage.height)")
        print("PHOTOSORTER_SIMULATOR_OCR_PROBE_TEXT_BEGIN\n\(text)\nPHOTOSORTER_SIMULATOR_OCR_PROBE_TEXT_END")

        XCTAssertTrue(text.localizedCaseInsensitiveContains("CODEX"), text)
        XCTAssertTrue(text.contains("48291"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("short side"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("PhotoSorter"), text)
    }

    func testLiveOCRRecognizesPhotoLibraryImageAtReadableResolution() async throws {
        let authorizationStatus = await Self.ensurePhotoLibraryReadWriteAuthorization()
        print("PHOTOSORTER_LIVE_OCR_AUTHORIZATION_STATUS \(Self.photoLibraryAuthorizationStatusDescription(authorizationStatus)) raw=\(authorizationStatus.rawValue)")
        let isAuthorized = authorizationStatus == .authorized || authorizationStatus == .limited
        try XCTSkipUnless(isAuthorized, "Photo library read-write authorization is required for live OCR probe")

        let image = await MainActor.run {
            Self.liveOCRProbeImage()
        }
        let localIdentifier = try await Self.createPhotoLibraryAsset(from: image)
        var didDeleteAsset = false
        defer {
            if !didDeleteAsset {
                Task {
                    try? await Self.deletePhotoLibraryAssets(localIdentifiers: [localIdentifier])
                }
            }
        }

        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: localIdentifier,
                fileName: "live-ocr-probe.png"
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let result = try await fixture.mount.recognizePhotoSorterMediaOCRText(for: "/图库/live-ocr-probe.png")
        let text = try XCTUnwrap(result?.text)
        print("PHOTOSORTER_LIVE_OCR_PROBE_TEXT_BEGIN\n\(text)\nPHOTOSORTER_LIVE_OCR_PROBE_TEXT_END")

        XCTAssertEqual(result?.source, .live)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("CODEX"), text)
        XCTAssertTrue(text.contains("48291"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("short side"), text)

        try await Self.deletePhotoLibraryAssets(localIdentifiers: [localIdentifier])
        didDeleteAsset = true
    }
#endif

    func testOCRCachePreheatCanPauseAndResumeCurrentBatch() async throws {
        let recognizer = BlockingOCRRecognitionOverride()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image)
                ]
            ),
            ocrRecognitionOverride: { asset, outputPath in
                recognizer.recognize(asset: asset, outputPath: outputPath)
            }
        )
        defer {
            recognizer.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startOCRCachePreheatBatch()
        try await waitUntil {
            recognizer.requestCount >= 1
        }

        fixture.mount.pauseOCRCachePreheat()
        var status = fixture.mount.photoLibraryOCRCacheStatus
        XCTAssertFalse(status.isPreheating)
        XCTAssertTrue(status.isPaused)
        XCTAssertEqual(status.processedInCurrentBatch, 0)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "OCR 缓存已暂停 0/2")

        recognizer.releaseOne()
        try await waitUntil {
            let status = fixture.mount.photoLibraryOCRCacheStatus
            return status.isPaused && status.processedInCurrentBatch == 1
        }
        XCTAssertEqual(recognizer.requestCount, 1)

        fixture.mount.resumeOCRCachePreheat()
        status = fixture.mount.photoLibraryOCRCacheStatus
        XCTAssertTrue(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.processedInCurrentBatch, 1)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "继续 OCR 缓存 1/2")

        try await waitUntil {
            recognizer.requestCount >= 2
        }
        recognizer.releaseOne()
        try await waitForOCRPreheatToFinish(fixture.mount)

        status = fixture.mount.photoLibraryOCRCacheStatus
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.totalCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "OCR 缓存已全部完成")
    }

    func testOCRCachePreheatWaitsForForegroundPhotoLibraryActivity() async throws {
        let foregroundActivity = BlockingForegroundPhotoLibraryActivity()
        let recognizer = BlockingOCRRecognitionOverride()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetIdentifier: "asset-a",
                fileName: "4f4fb263cf16.jpg"
            ),
            ocrRecognitionOverride: { asset, outputPath in
                recognizer.recognize(asset: asset, outputPath: outputPath)
            }
        )
        defer {
            foregroundActivity.release()
            recognizer.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let foregroundTask = Task {
            fixture.mount.withForegroundPhotoLibraryActivity {
                foregroundActivity.enterAndWait()
            }
        }
        try await waitUntil {
            foregroundActivity.didEnter
        }

        fixture.mount.startOCRCachePreheatBatch(limit: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recognizer.requestCount, 0)

        foregroundActivity.release()
        await foregroundTask.value
        try await waitUntil {
            recognizer.requestCount >= 1
        }
        recognizer.releaseOne()
        try await waitForOCRPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryOCRCacheStatus
        XCTAssertEqual(status.cachedCount, 1)
        XCTAssertEqual(status.processedInCurrentBatch, 1)
        XCTAssertEqual(status.message, "OCR 缓存已全部完成")
    }

    func testOCRCachePreheatContinuesWhenPhotoLibraryIndexBecomesDirty() async throws {
        let recognizer = BlockingOCRRecognitionOverride()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", mediaType: .image),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", mediaType: .image)
                ]
            ),
            ocrRecognitionOverride: { asset, outputPath in
                recognizer.recognize(asset: asset, outputPath: outputPath)
            }
        )
        defer {
            recognizer.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startOCRCachePreheatBatch()
        try await waitUntil {
            recognizer.requestCount >= 1
        }

        fixture.mount.markPhotoLibraryIndexDirty(reason: "test change")
        recognizer.releaseOne()
        try await waitUntil {
            recognizer.requestCount >= 2
        }
        recognizer.releaseOne()
        try await waitForOCRPreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryOCRCacheStatus
        XCTAssertEqual(recognizer.requestCount, 2)
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "OCR 缓存已全部完成")
    }

    func testPlaceCachePreheatWithoutLimitCachesEveryUncachedLocation() async throws {
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshotWithLocations(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", latitude: 31.2304, longitude: 121.4737),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", latitude: 39.9042, longitude: 116.4074),
                    (identifier: "asset-c", fileName: "804610ad3361.png", latitude: 22.3193, longitude: 114.1694)
                ]
            ),
            placeResolutionOverride: { _ in
                "中国上海市黄浦区"
            },
            placePreheatDelayNanoseconds: 0
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startPlaceCachePreheatBatch()
        try await waitForPlacePreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryPlaceCacheStatus
        XCTAssertEqual(status.totalCount, 3)
        XCTAssertEqual(status.cachedCount, 3)
        XCTAssertEqual(status.processedInCurrentBatch, 3)
        XCTAssertEqual(status.batchLimit, 3)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "地点缓存已全部完成")
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPlaceCachePreheatCanPauseAndResumeCurrentRun() async throws {
        let resolver = BlockingPlaceResolutionOverride()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshotWithLocations(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", latitude: 31.2304, longitude: 121.4737),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", latitude: 39.9042, longitude: 116.4074)
                ]
            ),
            placeResolutionOverride: { location in
                resolver.resolve(location: location)
            },
            placePreheatDelayNanoseconds: 0
        )
        defer {
            resolver.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startPlaceCachePreheatBatch()
        try await waitUntil {
            resolver.requestCount >= 1
        }

        fixture.mount.pausePlaceCachePreheat()
        var status = fixture.mount.photoLibraryPlaceCacheStatus
        XCTAssertFalse(status.isPreheating)
        XCTAssertTrue(status.isPaused)
        XCTAssertEqual(status.processedInCurrentBatch, 0)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "地点缓存已暂停 0/2")

        resolver.releaseOne()
        try await waitUntil {
            let status = fixture.mount.photoLibraryPlaceCacheStatus
            return status.isPaused && status.processedInCurrentBatch == 1
        }
        XCTAssertEqual(resolver.requestCount, 1)

        XCTAssertTrue(fixture.mount.resumePlaceCachePreheat())
        status = fixture.mount.photoLibraryPlaceCacheStatus
        XCTAssertTrue(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.processedInCurrentBatch, 1)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "继续地点缓存 1/2")

        try await waitUntil {
            resolver.requestCount >= 2
        }
        resolver.releaseOne()
        try await waitForPlacePreheatToFinish(fixture.mount)

        status = fixture.mount.photoLibraryPlaceCacheStatus
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.totalCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertFalse(status.isPreheating)
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(status.message, "地点缓存已全部完成")
    }

    func testPlaceCachePreheatWaitsForForegroundPhotoLibraryActivity() async throws {
        let foregroundActivity = BlockingForegroundPhotoLibraryActivity()
        let resolver = BlockingPlaceResolutionOverride()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshotWithLocations(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", latitude: 31.2304, longitude: 121.4737)
                ]
            ),
            placeResolutionOverride: { location in
                resolver.resolve(location: location)
            },
            placePreheatDelayNanoseconds: 0
        )
        defer {
            foregroundActivity.release()
            resolver.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let foregroundTask = Task {
            fixture.mount.withForegroundPhotoLibraryActivity {
                foregroundActivity.enterAndWait()
            }
        }
        try await waitUntil {
            foregroundActivity.didEnter
        }

        fixture.mount.startPlaceCachePreheatBatch(limit: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(resolver.requestCount, 0)

        foregroundActivity.release()
        await foregroundTask.value
        try await waitUntil {
            resolver.requestCount >= 1
        }
        resolver.releaseOne()
        try await waitForPlacePreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryPlaceCacheStatus
        XCTAssertEqual(status.cachedCount, 1)
        XCTAssertEqual(status.processedInCurrentBatch, 1)
        XCTAssertEqual(status.message, "地点缓存已全部完成")
    }

    func testPlaceCachePreheatContinuesWhenPhotoLibraryIndexBecomesDirty() async throws {
        let resolver = BlockingPlaceResolutionOverride()
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshotWithLocations(
                assetRecords: [
                    (identifier: "asset-a", fileName: "4f4fb263cf16.jpg", latitude: 31.2304, longitude: 121.4737),
                    (identifier: "asset-b", fileName: "544d3b5c5c6b.jpg", latitude: 39.9042, longitude: 116.4074)
                ]
            ),
            placeResolutionOverride: { location in
                resolver.resolve(location: location)
            },
            placePreheatDelayNanoseconds: 0
        )
        defer {
            resolver.releaseAll()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        fixture.mount.startPlaceCachePreheatBatch()
        try await waitUntil {
            resolver.requestCount >= 1
        }

        fixture.mount.markPhotoLibraryIndexDirty(reason: "test change")
        resolver.releaseOne()
        try await waitUntil {
            resolver.requestCount >= 2
        }
        resolver.releaseOne()
        try await waitForPlacePreheatToFinish(fixture.mount)

        let status = fixture.mount.photoLibraryPlaceCacheStatus
        XCTAssertEqual(resolver.requestCount, 2)
        XCTAssertEqual(status.cachedCount, 2)
        XCTAssertEqual(status.processedInCurrentBatch, 2)
        XCTAssertEqual(status.batchLimit, 2)
        XCTAssertEqual(status.message, "地点缓存已全部完成")
    }

    func testPhotoLibraryChangeNotificationIgnoresAssetUpdatesWhenIndexedFieldsAreUnchanged() async throws {
        let savedToken = Data([0x01])
        let readyToken = Data([0x02])
        let notificationToken = Data([0x03])
        let snapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.jpg",
            tokenData: savedToken
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: snapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = readyToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: readyToken,
            changeCount: 0
        )
        _ = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )
        let readyVersion = fixture.mount.photoLibraryIndexStatus.version
        var changes = PhotoLibraryPersistentChangeSummary(
            latestTokenData: notificationToken,
            changeCount: 1
        )
        changes.updatedAssetLocalIdentifiers = ["asset-a"]
        fixture.manifestProvider.currentTokenData = notificationToken
        fixture.manifestProvider.persistentChangeSummary = changes
        fixture.manifestProvider.assetRecordsByLocalIdentifier = Self.manifestScan(from: snapshot).assetRecords

        fixture.mount.handlePhotoLibraryChangeNotification()
        try await waitUntil {
            fixture.manifestProvider.manifestAssetRecordRequestLocalIdentifiers == ["asset-a"]
        }

        XCTAssertEqual(fixture.mount.photoLibraryIndexStatus.phase, .ready)
        XCTAssertEqual(fixture.mount.photoLibraryIndexStatus.version, readyVersion)
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 2)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 0)
    }

    func testForegroundActivityWakesPhotoLibraryChangeNotificationCoalescingWait() async throws {
        let savedToken = Data([0x01])
        let readyToken = Data([0x02])
        let notificationToken = Data([0x03])
        let snapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.jpg",
            tokenData: savedToken
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: snapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = readyToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: readyToken,
            changeCount: 0
        )
        _ = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        fixture.manifestProvider.currentTokenData = notificationToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: notificationToken,
            changeCount: 0
        )
        fixture.mount.handlePhotoLibraryChangeNotification()

        let startedAt = Date()
        let entries = try fixture.mount.withForegroundPhotoLibraryActivity {
            try fixture.workspace.photoLibraryFileSystem.listDirectory(
                "/图库",
                from: "/",
                offset: 0,
                limit: 10
            )
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(entries.map(\.name), ["4f4fb263cf16.jpg"])
        XCTAssertLessThan(elapsed, 0.20)
        XCTAssertGreaterThanOrEqual(fixture.manifestProvider.persistentChangesCallCount, 2)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPhotoLibraryChangeNotificationUsesIncrementalRefreshWhenUpdatedAssetIndexedFieldsChange() async throws {
        let savedToken = Data([0x01])
        let readyToken = Data([0x02])
        let notificationToken = Data([0x03])
        let initialSnapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.jpg",
            tokenData: savedToken
        )
        let updatedSnapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.png",
            tokenData: notificationToken
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: initialSnapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = readyToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: readyToken,
            changeCount: 0
        )
        _ = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )
        let readyVersion = fixture.mount.photoLibraryIndexStatus.version
        var changes = PhotoLibraryPersistentChangeSummary(
            latestTokenData: notificationToken,
            changeCount: 1
        )
        changes.updatedAssetLocalIdentifiers = ["asset-a"]
        fixture.manifestProvider.currentTokenData = notificationToken
        fixture.manifestProvider.persistentChangeSummary = changes
        fixture.manifestProvider.assetRecordsByLocalIdentifier = Self.manifestScan(from: updatedSnapshot).assetRecords
        fixture.manifestProvider.incrementalManifest = Self.manifestScan(from: updatedSnapshot)

        fixture.mount.handlePhotoLibraryChangeNotification()
        try await waitUntil {
            fixture.mount.photoLibraryIndexStatus.version > readyVersion
        }
        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].name.hasSuffix(".png"))
        XCTAssertEqual(fixture.manifestProvider.manifestAssetRecordRequestLocalIdentifiers, ["asset-a"])
        XCTAssertEqual(fixture.manifestProvider.incrementalManifestCallCount, 1)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPhotoLibraryChangeNotificationAppliesIncrementalRefreshWhenIndexedFieldsChange() async throws {
        let savedToken = Data([0x01])
        let readyToken = Data([0x02])
        let notificationToken = Data([0x03])
        let initialSnapshot = Self.snapshot(
            assetIdentifier: "asset-a",
            fileName: "4f4fb263cf16.jpg",
            tokenData: savedToken
        )
        let incrementalSnapshot = Self.snapshot(
            assetIdentifier: "asset-b",
            fileName: "544d3b5c5c6b.jpg",
            tokenData: notificationToken
        )
        let fixture = try makeWorkspaceFixture(persistedSnapshot: initialSnapshot)
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = readyToken
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: readyToken,
            changeCount: 0
        )
        _ = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )
        let readyVersion = fixture.mount.photoLibraryIndexStatus.version
        var changes = PhotoLibraryPersistentChangeSummary(
            latestTokenData: notificationToken,
            changeCount: 1
        )
        changes.insertedAssetLocalIdentifiers = ["asset-b"]
        fixture.manifestProvider.currentTokenData = notificationToken
        fixture.manifestProvider.persistentChangeSummary = changes
        fixture.manifestProvider.incrementalManifest = Self.manifestScan(from: incrementalSnapshot)

        fixture.mount.handlePhotoLibraryChangeNotification()
        try await waitUntil {
            fixture.mount.photoLibraryIndexStatus.version > readyVersion
        }
        let entries = try fixture.workspace.photoLibraryFileSystem.listDirectory(
            "/图库",
            from: "/",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            fixture.mount.cachedAsset(at: "/图库/\(entries[0].name)")?.localIdentifier,
            "asset-b"
        )
        XCTAssertEqual(fixture.mount.photoLibraryIndexStatus.phase, .ready)
        XCTAssertEqual(fixture.manifestProvider.persistentChangesCallCount, 2)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPhotoLibraryMountTypedEnumerationSkipsAssetDirectoriesForDirectoryOnlyFilter() async throws {
        let fixture = try makeWorkspaceFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }

        let fileSystem = fixture.workspace.photoLibraryFileSystem
        var galleryNames: [String] = []
        try await fileSystem.enumerateDirectory(
            "/图库",
            from: "/",
            options: .init(typeFilter: [.directory])
        ) { entry in
            galleryNames.append(entry.name)
            return true
        }

        var albumRootNames: [String] = []
        try await fileSystem.enumerateDirectory(
            "/相册",
            from: "/",
            options: .init(typeFilter: [.directory])
        ) { entry in
            albumRootNames.append(entry.name)
            return true
        }

        XCTAssertEqual(galleryNames, [])
        XCTAssertEqual(albumRootNames, ["系统", "用户"])
    }

    func testPhotoLibraryMountEnumeratesLargeAssetDirectoryFromSnapshotAccurately() async throws {
        let assetRecords = (0..<2048).map { index in
            (
                identifier: "asset-\(index)",
                fileName: String(format: "%04d.png", index),
                mediaType: PHAssetMediaType.image
            )
        }
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: assetRecords,
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = Data([0x01])
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x01]),
            changeCount: 0
        )

        var entries: [MSPDirectoryEntry] = []
        try await fixture.workspace.photoLibraryFileSystem.enumerateDirectory(
            "/相册/系统/截图",
            from: "/",
            options: .init(typeFilter: [.regularFile])
        ) { entry in
            entries.append(entry)
            return true
        }

        XCTAssertEqual(entries.count, assetRecords.count)
        XCTAssertEqual(entries.first?.name, "0000.png")
        XCTAssertEqual(entries.last?.name, "2047.png")
        XCTAssertEqual(entries.first?.virtualPath, "/相册/系统/截图/0000.png")
        XCTAssertEqual(entries.last?.virtualPath, "/相册/系统/截图/2047.png")
        XCTAssertEqual(entries.allSatisfy { $0.type == .regularFile }, true)
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    func testPhotoLibraryMountBatchEnumerationMatchesStreamingEnumeration() async throws {
        let assetRecords = (0..<2048).map { index in
            (
                identifier: "asset-\(index)",
                fileName: String(format: "%04d.png", index),
                mediaType: PHAssetMediaType.image
            )
        }
        let fixture = try makeWorkspaceFixture(
            persistedSnapshot: Self.snapshot(
                assetRecords: assetRecords,
                tokenData: Data([0x01]),
                additionalAssetDirectoryPaths: ["/相册/系统/截图"]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
        }
        fixture.manifestProvider.currentTokenData = Data([0x01])
        fixture.manifestProvider.persistentChangeSummary = PhotoLibraryPersistentChangeSummary(
            latestTokenData: Data([0x01]),
            changeCount: 0
        )

        var streamingEntries: [MSPDirectoryEntry] = []
        try await fixture.workspace.photoLibraryFileSystem.enumerateDirectory(
            "/相册/系统/截图",
            from: "/",
            options: .init(typeFilter: [.regularFile])
        ) { entry in
            streamingEntries.append(entry)
            return true
        }

        var batchEntries: [MSPDirectoryEntry] = []
        var batchSizes: [Int] = []
        try await fixture.workspace.photoLibraryFileSystem.enumerateDirectoryBatches(
            "/相册/系统/截图",
            from: "/",
            options: .init(typeFilter: [.regularFile]),
            batchSize: 512
        ) { entries in
            batchSizes.append(entries.count)
            batchEntries.append(contentsOf: entries)
            return true
        }

        XCTAssertEqual(batchEntries, streamingEntries)
        XCTAssertEqual(batchSizes, [512, 512, 512, 512])
        XCTAssertEqual(fixture.manifestProvider.makeManifestCallCount, 0)
    }

    private func makeWorkspaceFixture() throws -> (
        temporaryDirectory: URL,
        workspace: PhotoSorterWorkspace,
        mount: PhotoLibraryMount,
        manifestProvider: CountingPhotoLibraryManifestProvider
    ) {
        try makeWorkspaceFixture(persistedSnapshot: nil)
    }

    private func makeWorkspaceFixture(
        persistedSnapshot: PhotoLibraryIndexSnapshot?,
        ocrRecognitionOverride: (@Sendable (PhotoLibraryMount.MountedAsset, String) async throws -> String?)? = nil,
        placeResolutionOverride: (@Sendable (CLLocation) async throws -> String?)? = nil,
        vlmSummaryProvider: (any PhotoSorterFastVLMSummaryProviding)? = nil,
        vlmImageOverride: (@Sendable (PhotoLibraryMount.MountedAsset) async throws -> CIImage?)? = nil,
        placePreheatDelayNanoseconds: UInt64 = 250_000_000,
        overlayURL: URL? = nil,
        usesPresentationPhotoLibraryReads: Bool = false
    ) throws -> (
        temporaryDirectory: URL,
        workspace: PhotoSorterWorkspace,
        mount: PhotoLibraryMount,
        manifestProvider: CountingPhotoLibraryManifestProvider
    ) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDirectory = temporaryDirectory.appendingPathComponent("Workspace", isDirectory: true)
        let indexURL = temporaryDirectory
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("photo-library-index.json")
        let ocrCacheURL = temporaryDirectory
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("photo-library-ocr-cache.json")
        let placeCacheURL = temporaryDirectory
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("photo-library-place-cache.json")
        let vlmSummaryCacheURL = temporaryDirectory
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("photo-library-vlm-summary-cache.json")
        let resolvedOverlayURL = overlayURL ?? temporaryDirectory
            .appendingPathComponent("Overlay", isDirectory: true)
            .appendingPathComponent("photo-library-workspace-overlay.json")

        try FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true
        )

        let indexStore = PhotoLibraryIndexPersistentStore(fileURL: indexURL)
        if let persistedSnapshot {
            try indexStore.save(persistedSnapshot)
        }
        let manifestProvider = CountingPhotoLibraryManifestProvider()
        if let persistedSnapshot {
            manifestProvider.manifestScan = Self.manifestScan(from: persistedSnapshot)
        }
        let mount = PhotoLibraryMount(
            indexStore: indexStore,
            ocrCache: PhotoSorterMediaOCRCache(fileURL: ocrCacheURL),
            placeCache: PhotoSorterMediaPlaceCache(fileURL: placeCacheURL),
            vlmSummaryCache: PhotoSorterMediaVLMSummaryCache(fileURL: vlmSummaryCacheURL),
            workspaceOverlay: PhotoLibraryWorkspaceOverlay(
                store: PhotoLibraryWorkspaceOverlayStore(fileURL: resolvedOverlayURL)
            ),
            diagnosticsLog: nil,
            manifestProvider: manifestProvider,
            ocrRecognitionOverride: ocrRecognitionOverride,
            placeResolutionOverride: placeResolutionOverride,
            vlmSummaryProvider: vlmSummaryProvider,
            vlmImageOverride: vlmImageOverride,
            placePreheatDelayNanoseconds: placePreheatDelayNanoseconds
        )
        let workspace = PhotoSorterWorkspace(
            localWorkspaceURL: workspaceDirectory,
            photoLibraryMount: mount,
            usesPresentationPhotoLibraryReads: usesPresentationPhotoLibraryReads
        )
        return (temporaryDirectory, workspace, mount, manifestProvider)
    }

    private func waitForOCRPreheatToFinish(
        _ mount: PhotoLibraryMount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            let status = mount.photoLibraryOCRCacheStatus
            if !status.isPreheating && !status.isPaused {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("OCR cache preheat did not finish", file: file, line: line)
    }

    private func waitForPlacePreheatToFinish(
        _ mount: PhotoLibraryMount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            let status = mount.photoLibraryPlaceCacheStatus
            if !status.isPreheating && !status.isPaused {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Place cache preheat did not finish", file: file, line: line)
    }

    private func waitForVLMPreheatToFinish(
        _ mount: PhotoLibraryMount,
        timeoutIterations: Int = 3_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: ((PhotoSorterMediaVLMStatus) -> Bool)? = nil
    ) async throws {
        for _ in 0..<timeoutIterations {
            let status = mount.photoLibraryVLMSummaryCacheStatus
            let didFinish = !status.isPreheating && !status.isPaused
            if didFinish && (predicate?(status) ?? true) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = mount.photoLibraryVLMSummaryCacheStatus
        XCTFail(
            """
            VLM summary cache preheat did not finish: cached=\(status.cachedCount)/\(status.totalCount), \
            isPreheating=\(status.isPreheating), isPaused=\(status.isPaused), \
            processed=\(status.processedInCurrentBatch)/\(status.batchLimit), \
            failed=\(status.failedInCurrentBatch), skipped=\(status.skippedInCurrentBatch), \
            message=\(status.message ?? "nil")
            """,
            file: file,
            line: line
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 3_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private static func blankCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let width = max(width, 1)
        let height = max(height, 1)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private static func blankCIImage() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    }

#if canImport(UIKit) && canImport(Vision)
    private static func ensurePhotoLibraryReadWriteAuthorization() async -> PHAuthorizationStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .denied, .restricted:
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        @unknown default:
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }

    private static func photoLibraryAuthorizationStatusDescription(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        @unknown default:
            return "unknown"
        }
    }

    @MainActor
    private static func liveOCRProbeImage(
        size: CGSize = CGSize(width: 2400, height: 1350)
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .regular),
                .foregroundColor: UIColor.black
            ]
            let smallAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 36, weight: .medium),
                .foregroundColor: UIColor.black
            ]

            "CODEX OCR PROBE 48291".draw(
                at: CGPoint(x: 160, y: 180),
                withAttributes: titleAttributes
            )
            "short side 1080 readable text".draw(
                at: CGPoint(x: 160, y: 330),
                withAttributes: bodyAttributes
            )
            "tiny-line alpha beta 739".draw(
                at: CGPoint(x: 160, y: 450),
                withAttributes: smallAttributes
            )
            "PhotoSorter Vision live path".draw(
                at: CGPoint(x: 160, y: 570),
                withAttributes: bodyAttributes
            )
        }
    }

    @MainActor
    private static func renderOCRProbeImage(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let pixelSize = CGSize(
            width: max(targetSize.width.rounded(), 1),
            height: max(targetSize.height.rounded(), 1)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    private static func recognizedTextForOCRProbe(from image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let lhsBox = lhs.boundingBox
            let rhsBox = rhs.boundingBox
            if abs(lhsBox.midY - rhsBox.midY) > 0.015 {
                return lhsBox.midY > rhsBox.midY
            }
            return lhsBox.minX < rhsBox.minX
        }
        return observations.compactMap { observation in
            observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func createPhotoLibraryAsset(from image: UIImage) async throws -> String {
        var localIdentifier: String?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.userCancelled))
                }
            }
        }
        guard let localIdentifier else {
            throw CocoaError(.fileNoSuchFile)
        }
        return localIdentifier
    }

    private static func deletePhotoLibraryAssets(localIdentifiers: [String]) async throws {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard fetchResult.count > 0 else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetchResult)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.userCancelled))
                }
            }
        }
    }
#endif

    private static func mountedAsset(identifier: String) -> PhotoLibraryMount.MountedAsset {
        mountedAsset(identifier: identifier, name: "\(identifier).jpg")
    }

    private static func mountedAsset(identifier: String, name: String) -> PhotoLibraryMount.MountedAsset {
        PhotoLibraryMount.MountedAsset(
            name: name,
            virtualPath: "/图库/\(name)",
            localIdentifier: identifier,
            mediaType: .image,
            mediaSubtypes: PHAssetMediaSubtype(rawValue: 0),
            pixelWidth: 4032,
            pixelHeight: 3024,
            creationDate: nil,
            modificationDate: nil,
            locationLatitude: nil,
            locationLongitude: nil,
            locationHorizontalAccuracy: nil
        )
    }

    private static func snapshot(
        assetIdentifier: String,
        fileName: String,
        tokenData: Data? = nil,
        additionalAssetDirectoryPaths: [String] = [],
        userAlbumPaths: [String] = []
    ) -> PhotoLibraryIndexSnapshot {
        snapshot(
            assetRecords: [
                (identifier: assetIdentifier, fileName: fileName, mediaType: .image)
            ],
            tokenData: tokenData,
            additionalAssetDirectoryPaths: additionalAssetDirectoryPaths,
            userAlbumPaths: userAlbumPaths
        )
    }

    private static func snapshotWithLocations(
        assetRecords: [(identifier: String, fileName: String, latitude: Double, longitude: Double)],
        tokenData: Data? = nil
    ) -> PhotoLibraryIndexSnapshot {
        var snapshot = snapshot(
            assetRecords: assetRecords.map { record in
                (identifier: record.identifier, fileName: record.fileName, mediaType: PHAssetMediaType.image)
            },
            tokenData: tokenData
        )
        for record in assetRecords {
            guard var asset = snapshot.assetsByLocalIdentifier[record.identifier] else {
                continue
            }
            asset.locationLatitude = record.latitude
            asset.locationLongitude = record.longitude
            asset.locationHorizontalAccuracy = 25
            snapshot.assetsByLocalIdentifier[record.identifier] = asset
        }
        return snapshot
    }

    private static func snapshot(
        assetRecords: [(identifier: String, fileName: String, mediaType: PHAssetMediaType)],
        tokenData: Data? = nil,
        additionalAssetDirectoryPaths: [String] = [],
        userAlbumPaths: [String] = []
    ) -> PhotoLibraryIndexSnapshot {
        let systemAlbumPaths = PhotoLibraryMount.systemAlbumDirectories.map {
            PhotoLibraryMount.join(PhotoLibraryMount.systemAlbumRootPath, $0)
        }
        let normalizedUserAlbumPaths = Array(Set(
            userAlbumPaths
                + additionalAssetDirectoryPaths.filter { path in
                    PhotoLibraryMount.normalizeVirtualPath(path).hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/")
                }
        )).map(PhotoLibraryMount.normalizeVirtualPath).sorted()
        let assetIdentifiers = assetRecords.map(\.identifier)
        var directories: [String: PhotoLibraryIndexDirectory] = [
            "/图库": PhotoLibraryIndexDirectory(
                name: "图库",
                path: "/图库",
                parentPath: "/",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: [],
                assetLocalIdentifiers: assetIdentifiers,
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            ),
            "/相册": PhotoLibraryIndexDirectory(
                name: "相册",
                path: "/相册",
                parentPath: "/",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: ["/相册/系统", "/相册/用户"],
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: true
            ),
            "/相册/系统": PhotoLibraryIndexDirectory(
                name: "系统",
                path: "/相册/系统",
                parentPath: "/相册",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: systemAlbumPaths,
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: true
            ),
            "/相册/用户": PhotoLibraryIndexDirectory(
                name: "用户",
                path: "/相册/用户",
                parentPath: "/相册",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: normalizedUserAlbumPaths,
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            )
        ]
        let assetsByLocalIdentifier = Dictionary(
            uniqueKeysWithValues: assetRecords.enumerated().map { index, record in
                let fileExtension = URL(fileURLWithPath: record.fileName).pathExtension.lowercased()
                return (
                    record.identifier,
                    PhotoLibraryIndexAsset(
                        localIdentifier: record.identifier,
                        fileName: record.fileName,
                        fileExtension: fileExtension.isEmpty ? "jpg" : fileExtension,
                        mediaTypeRawValue: record.mediaType.rawValue,
                        mediaSubtypesRawValue: 0,
                        pixelWidth: 4032,
                        pixelHeight: 3024,
                        creationDate: Date(timeIntervalSince1970: Double(index)),
                        modificationDate: nil
                    )
                )
            }
        )
        for (name, path) in zip(PhotoLibraryMount.systemAlbumDirectories, systemAlbumPaths) {
            directories[path] = PhotoLibraryIndexDirectory(
                name: name,
                path: path,
                parentPath: "/相册/系统",
                collectionLocalIdentifier: nil,
                childDirectoryPaths: [],
                assetLocalIdentifiers: [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            )
        }
        for path in normalizedUserAlbumPaths {
            let name = path.split(separator: "/").last.map(String.init) ?? "用户相册"
            directories[path] = PhotoLibraryIndexDirectory(
                name: name,
                path: path,
                parentPath: PhotoLibraryMount.userAlbumRootPath,
                collectionLocalIdentifier: "album:\(path)",
                childDirectoryPaths: [],
                assetLocalIdentifiers: additionalAssetDirectoryPaths.map(PhotoLibraryMount.normalizeVirtualPath).contains(path) ? assetIdentifiers : [],
                manifestFingerprint: nil,
                directFileCount: 0,
                recursiveFileCount: 0,
                hasSubdirectories: false
            )
        }
        for path in additionalAssetDirectoryPaths {
            directories[PhotoLibraryMount.normalizeVirtualPath(path)]?.assetLocalIdentifiers = assetIdentifiers
        }
        return PhotoLibraryIndexSnapshot.make(
            authorizationStatusRawValue: PHAuthorizationStatus.authorized.rawValue,
            version: 1,
            directories: directories,
            assetsByLocalIdentifier: assetsByLocalIdentifier,
            photoLibraryChangeTokenData: tokenData
        )
    }

    private static func manifestScan(from snapshot: PhotoLibraryIndexSnapshot) -> PhotoLibraryManifestScan {
        PhotoLibraryManifestScan(
            authorizationStatusRawValue: snapshot.authorizationStatusRawValue,
            libraryScopeFingerprint: snapshot.libraryScopeFingerprint,
            directories: snapshot.directories,
            assetRecords: snapshot.assetsByLocalIdentifier.mapValues {
                PhotoLibraryManifestAssetRecord(indexedAsset: $0)
            },
            photosFetchCount: 1,
            indexedAssetMembershipCount: snapshot.indexedAssetMembershipCount
        )
    }

    private static func manifestAssetRecord(
        identifier: String,
        fileExtension: String,
        mediaType: PHAssetMediaType = .image,
        creationTime: TimeInterval = 0
    ) -> PhotoLibraryManifestAssetRecord {
        PhotoLibraryManifestAssetRecord(
            localIdentifier: identifier,
            fileExtension: fileExtension,
            mediaTypeRawValue: mediaType.rawValue,
            mediaSubtypesRawValue: 0,
            pixelWidth: 4032,
            pixelHeight: 3024,
            creationDate: Date(timeIntervalSince1970: creationTime),
            modificationDate: nil
        )
    }
}

private final class BlockingOCRRecognitionOverride: @unchecked Sendable {
    private let condition = NSCondition()
    private var rawRequestCount = 0
    private var releaseCount = 0
    private var releaseEverything = false

    var requestCount: Int {
        condition.lock()
        defer {
            condition.unlock()
        }
        return rawRequestCount
    }

    func recognize(asset: PhotoLibraryMount.MountedAsset, outputPath _: String) -> String {
        condition.lock()
        rawRequestCount += 1
        condition.broadcast()
        while releaseCount == 0 && !releaseEverything {
            condition.wait()
        }
        if releaseCount > 0 {
            releaseCount -= 1
        }
        condition.unlock()
        return "text for \(asset.localIdentifier)"
    }

    func releaseOne() {
        condition.lock()
        releaseCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releaseEverything = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CountingOCRRecognitionOverride: @unchecked Sendable {
    private let lock = NSLock()
    private let textsByOutputPath: [String: String]
    private var rawRequestPaths: [String] = []

    init(_ textsByOutputPath: [String: String]) {
        self.textsByOutputPath = textsByOutputPath
    }

    var requestPaths: [String] {
        lock.withLock {
            rawRequestPaths
        }
    }

    func recognize(asset _: PhotoLibraryMount.MountedAsset, outputPath: String) -> String? {
        lock.withLock {
            rawRequestPaths.append(outputPath)
        }
        return textsByOutputPath[outputPath]
    }
}

private final class CountingVLMImageRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var rawRequestedLocalIdentifiers: [String] = []

    var requestedLocalIdentifiers: [String] {
        lock.withLock {
            rawRequestedLocalIdentifiers
        }
    }

    func record(_ asset: PhotoLibraryMount.MountedAsset) {
        lock.withLock {
            rawRequestedLocalIdentifiers.append(asset.localIdentifier)
        }
    }
}

private final class CountingVLMSummaryProvider: PhotoSorterFastVLMSummaryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var rawRequestCount = 0
    private var rawImageExtents: [CGRect] = []

    var requestCount: Int {
        lock.withLock {
            rawRequestCount
        }
    }

    var imageExtents: [CGRect] {
        lock.withLock {
            rawImageExtents
        }
    }

    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        Self.availableStatus(processorConfigFingerprint: modelBundle.processorConfigFingerprint)
    }

    func summarize(
        image: CIImage,
        modelBundle _: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        let requestNumber = lock.withLock {
            rawRequestCount += 1
            rawImageExtents.append(image.extent)
            return rawRequestCount
        }
        return "summary \(requestNumber)"
    }

    static func availableStatus(processorConfigFingerprint: String) -> PhotoSorterMediaVLMProviderStatus {
        PhotoSorterMediaVLMProviderStatus(
            kind: PhotoSorterMediaVLMConfiguration.providerKind,
            backend: PhotoSorterMediaVLMConfiguration.backend,
            modelID: PhotoSorterMediaVLMConfiguration.modelID,
            modelVersion: PhotoSorterMediaVLMConfiguration.modelVersion,
            modelState: .installed,
            isLiveSummarizationAvailable: true,
            processorConfigFingerprint: processorConfigFingerprint,
            reason: nil
        )
    }
}

private final class FailingVLMSummaryProvider: PhotoSorterFastVLMSummaryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let failingRequestNumbers: Set<Int>
    private let failureMessage: String
    private var rawRequestCount = 0

    init(
        failingRequestNumbers: Set<Int>,
        failureMessage: String = "synthetic VLM failure"
    ) {
        self.failingRequestNumbers = failingRequestNumbers
        self.failureMessage = failureMessage
    }

    var requestCount: Int {
        lock.withLock {
            rawRequestCount
        }
    }

    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        CountingVLMSummaryProvider.availableStatus(processorConfigFingerprint: modelBundle.processorConfigFingerprint)
    }

    func summarize(
        image _: CIImage,
        modelBundle _: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        let requestNumber = lock.withLock {
            rawRequestCount += 1
            return rawRequestCount
        }
        if failingRequestNumbers.contains(requestNumber) {
            throw NSError(
                domain: "PhotoSorterTests.VLM",
                code: requestNumber,
                userInfo: [NSLocalizedDescriptionKey: "\(failureMessage) \(requestNumber)"]
            )
        }
        return "summary \(requestNumber)"
    }
}

private final class ForegroundDeniedOnceVLMSummaryProvider: PhotoSorterFastVLMSummaryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var rawRequestCount = 0

    var requestCount: Int {
        lock.withLock {
            rawRequestCount
        }
    }

    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        CountingVLMSummaryProvider.availableStatus(processorConfigFingerprint: modelBundle.processorConfigFingerprint)
    }

    func summarize(
        image _: CIImage,
        modelBundle _: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        let requestNumber = lock.withLock {
            rawRequestCount += 1
            return rawRequestCount
        }
        if requestNumber == 1 {
            throw Self.foregroundDeniedError()
        }
        return "summary \(requestNumber)"
    }

    static func foregroundDeniedError() -> NSError {
        NSError(
            domain: "PhotoSorterTests.VLM",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Insufficient Permission (to submit GPU work from background) " +
                    "(00000006:kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)"
            ]
        )
    }
}

private final class BlockingForegroundDeniedOnceVLMSummaryProvider: PhotoSorterFastVLMSummaryProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhotoSorterTests.BlockingForegroundDeniedOnceVLMSummaryProvider")
    private var rawRequestCount = 0
    private var rawForegroundDeniedErrorCount = 0
    private var shouldReleaseFirstRequest = false
    private var firstRequestWaiter: CheckedContinuation<Void, Never>?

    var requestCount: Int {
        queue.sync {
            rawRequestCount
        }
    }

    var foregroundDeniedErrorCount: Int {
        queue.sync {
            rawForegroundDeniedErrorCount
        }
    }

    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        CountingVLMSummaryProvider.availableStatus(processorConfigFingerprint: modelBundle.processorConfigFingerprint)
    }

    func summarize(
        image _: CIImage,
        modelBundle _: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        let requestNumber = queue.sync {
            rawRequestCount += 1
            return rawRequestCount
        }
        if requestNumber == 1 {
            await waitForFirstRequestRelease()
            queue.sync {
                rawForegroundDeniedErrorCount += 1
            }
            throw ForegroundDeniedOnceVLMSummaryProvider.foregroundDeniedError()
        }
        return "summary \(requestNumber)"
    }

    func releaseFirstRequest() {
        let waiter = queue.sync { () -> CheckedContinuation<Void, Never>? in
            if let firstRequestWaiter {
                self.firstRequestWaiter = nil
                return firstRequestWaiter
            }
            shouldReleaseFirstRequest = true
            return nil
        }
        waiter?.resume()
    }

    private func waitForFirstRequestRelease() async {
        await withCheckedContinuation { continuation in
            let shouldResume = queue.sync {
                if shouldReleaseFirstRequest {
                    return true
                }
                firstRequestWaiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class BlockingVLMSummaryProvider: PhotoSorterFastVLMSummaryProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhotoSorterTests.BlockingVLMSummaryProvider")
    private var rawRequestCount = 0
    private var releaseCount = 0
    private var releaseEverything = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var requestCount: Int {
        queue.sync {
            rawRequestCount
        }
    }

    func status(for modelBundle: PhotoSorterFastVLMModelBundle) -> PhotoSorterMediaVLMProviderStatus {
        CountingVLMSummaryProvider.availableStatus(processorConfigFingerprint: modelBundle.processorConfigFingerprint)
    }

    func summarize(
        image _: CIImage,
        modelBundle _: PhotoSorterFastVLMModelBundle
    ) async throws -> String {
        let request = registerRequest()
        if request.shouldWait {
            await withCheckedContinuation { continuation in
                enqueueWaiter(continuation)
            }
        }
        return "summary \(request.number)"
    }

    func releaseOne() {
        let waiter = queue.sync { () -> CheckedContinuation<Void, Never>? in
            if !waiters.isEmpty {
                return waiters.removeFirst()
            }
            releaseCount += 1
            return nil
        }
        waiter?.resume()
    }

    func releaseAll() {
        let continuations = queue.sync { () -> [CheckedContinuation<Void, Never>] in
            releaseEverything = true
            let continuations = waiters
            waiters = []
            return continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func registerRequest() -> (number: Int, shouldWait: Bool) {
        queue.sync {
            rawRequestCount += 1
            let requestNumber = rawRequestCount
            if releaseCount > 0 {
                releaseCount -= 1
                return (requestNumber, false)
            }
            return (requestNumber, !releaseEverything)
        }
    }

    private func enqueueWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        let shouldResume = queue.sync { () -> Bool in
            if releaseCount > 0 {
                releaseCount -= 1
                return true
            }
            if releaseEverything {
                return true
            }
            waiters.append(continuation)
            return false
        }
        if shouldResume {
            continuation.resume()
        }
    }
}

private final class BlockingForegroundPhotoLibraryActivity: @unchecked Sendable {
    private let condition = NSCondition()
    private var rawDidEnter = false
    private var isReleased = false

    var didEnter: Bool {
        condition.lock()
        defer {
            condition.unlock()
        }
        return rawDidEnter
    }

    func enterAndWait() {
        condition.lock()
        rawDidEnter = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BlockingPlaceResolutionOverride: @unchecked Sendable {
    private let condition = NSCondition()
    private var rawRequestCount = 0
    private var releaseCount = 0
    private var releaseEverything = false

    var requestCount: Int {
        condition.lock()
        defer {
            condition.unlock()
        }
        return rawRequestCount
    }

    func resolve(location _: CLLocation) -> String {
        condition.lock()
        rawRequestCount += 1
        condition.broadcast()
        while releaseCount == 0 && !releaseEverything {
            condition.wait()
        }
        if releaseCount > 0 {
            releaseCount -= 1
        }
        condition.unlock()
        return "中国上海市黄浦区"
    }

    func releaseOne() {
        condition.lock()
        releaseCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releaseEverything = true
        condition.broadcast()
        condition.unlock()
    }
}

final class CountingPhotoLibraryManifestProvider: PhotoLibraryManifestProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var rawMakeManifestCallCount = 0
    private var rawPersistentChangesCallCount = 0
    private var rawIncrementalManifestCallCount = 0
    private var rawPresentationUserAlbumsCallCount = 0
    private var rawPresentationAssetRecordsCallCount = 0
    private var rawApplyWorkspaceChangesCallCount = 0
    private var rawResourceDataRequestLocalIdentifiers: [String] = []
    private var rawManifestAssetRecordRequestLocalIdentifiers: [String] = []
    var currentTokenData: Data?
    var persistentChangeSummary: PhotoLibraryPersistentChangeSummary?
    var incrementalManifest: PhotoLibraryManifestScan?
    var manifestScan: PhotoLibraryManifestScan?
    var appliedWorkspaceChangeSets: [PhotoLibraryWorkspaceSyncChangeSet] = []
    var presentationUserAlbumsResult: [PhotoLibraryMount.MountedAlbum]?
    var presentationAssetRecordsByPath: [String: [PhotoLibraryManifestAssetRecord]] = [:]
    var assetRecordsByLocalIdentifier: [String: PhotoLibraryManifestAssetRecord] = [:]
    var resourceDataByLocalIdentifier: [String: Data] = [:]

    var makeManifestCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawMakeManifestCallCount
    }

    var persistentChangesCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawPersistentChangesCallCount
    }

    var incrementalManifestCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawIncrementalManifestCallCount
    }

    var presentationUserAlbumsCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawPresentationUserAlbumsCallCount
    }

    var presentationAssetRecordsCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawPresentationAssetRecordsCallCount
    }

    var applyWorkspaceChangesCallCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawApplyWorkspaceChangesCallCount
    }

    var resourceDataRequestLocalIdentifiers: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawResourceDataRequestLocalIdentifiers
    }

    var manifestAssetRecordRequestLocalIdentifiers: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return rawManifestAssetRecordRequestLocalIdentifiers
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        .authorized
    }

    func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        .authorized
    }

    func hasReadAccess() -> Bool {
        true
    }

    func currentPhotoLibraryChangeTokenData() -> Data? {
        currentTokenData
    }

    func photoLibraryPersistentChanges(since tokenData: Data) throws -> PhotoLibraryPersistentChangeSummary? {
        lock.lock()
        rawPersistentChangesCallCount += 1
        lock.unlock()
        return persistentChangeSummary
    }

    func resourceData(forLocalIdentifier localIdentifier: String) throws -> Data? {
        lock.lock()
        rawResourceDataRequestLocalIdentifiers.append(localIdentifier)
        let data = resourceDataByLocalIdentifier[localIdentifier]
        lock.unlock()
        return data
    }

    func presentationUserAlbums() -> [PhotoLibraryMount.MountedAlbum]? {
        lock.lock()
        rawPresentationUserAlbumsCallCount += 1
        lock.unlock()
        return presentationUserAlbumsResult
    }

    func manifestAssetRecords(
        for localIdentifiers: Set<String>
    ) -> [String: PhotoLibraryManifestAssetRecord] {
        lock.lock()
        rawManifestAssetRecordRequestLocalIdentifiers.append(contentsOf: localIdentifiers.sorted())
        let records = assetRecordsByLocalIdentifier.filter { localIdentifiers.contains($0.key) }
        lock.unlock()
        return records
    }

    func presentationAssetRecords(
        in virtualDirectoryPath: String,
        offset: Int,
        limit: Int?
    ) -> [PhotoLibraryManifestAssetRecord]? {
        lock.lock()
        rawPresentationAssetRecordsCallCount += 1
        lock.unlock()

        guard let records = presentationAssetRecordsByPath[PhotoLibraryMount.normalizeVirtualPath(virtualDirectoryPath)] else {
            return nil
        }
        let startIndex = min(max(offset, 0), records.count)
        let endIndex = limit
            .map { min(startIndex + max($0, 0), records.count) }
            ?? records.count
        return Array(records[startIndex..<endIndex])
    }

    func makeManifest(
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void,
        hasPreviousSnapshot: Bool
    ) -> PhotoLibraryManifestScan {
        lock.lock()
        rawMakeManifestCallCount += 1
        lock.unlock()
        progress(PhotoLibraryIndexBuildProgress(
            phase: hasPreviousSnapshot ? .validating : .building,
            processed: 0,
            total: 0,
            currentPath: nil,
            message: "test"
        ))
        if let manifestScan {
            return manifestScan
        }
        return PhotoLibraryManifestScan(
            authorizationStatusRawValue: PHAuthorizationStatus.authorized.rawValue,
            libraryScopeFingerprint: "test",
            directories: [:],
            assetRecords: [:],
            photosFetchCount: 0,
            indexedAssetMembershipCount: 0
        )
    }

    func makeIncrementalManifest(
        previousSnapshot: PhotoLibraryIndexSnapshot,
        changes: PhotoLibraryPersistentChangeSummary,
        progress: @escaping (PhotoLibraryIndexBuildProgress) -> Void
    ) throws -> PhotoLibraryManifestScan? {
        lock.lock()
        rawIncrementalManifestCallCount += 1
        lock.unlock()
        progress(PhotoLibraryIndexBuildProgress(
            phase: .refreshing,
            processed: 1,
            total: 1,
            currentPath: nil,
            message: "incremental test"
        ))
        return incrementalManifest
    }

    func applyWorkspaceChanges(_ changeSet: PhotoLibraryWorkspaceSyncChangeSet) async throws {
        recordAppliedWorkspaceChangeSet(changeSet)
    }

    private func recordAppliedWorkspaceChangeSet(_ changeSet: PhotoLibraryWorkspaceSyncChangeSet) {
        lock.lock()
        rawApplyWorkspaceChangesCallCount += 1
        appliedWorkspaceChangeSets.append(changeSet)
        lock.unlock()
    }

    func registerChangeObserver(_ observer: PHPhotoLibraryChangeObserver) {}

    func unregisterChangeObserver(_ observer: PHPhotoLibraryChangeObserver) {}
}
