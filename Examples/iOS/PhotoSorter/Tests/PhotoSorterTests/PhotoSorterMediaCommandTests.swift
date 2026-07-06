import CoreGraphics
import Foundation
import ImageIO
import ModelShellProxy
import UniformTypeIdentifiers
import XCTest
@testable import PhotoSorter

final class PhotoSorterMediaCommandTests: XCTestCase {
    func testMediaShowRunsThroughModelShellProxyCommandPack() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_782_650_590)
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/截图_000001.png": PhotoSorterMediaMetadata(
                path: "/图库/截图_000001.png",
                pixelWidth: 1179,
                pixelHeight: 2556,
                creationDate: createdAt
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/截图_000001.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            Path: /图库/截图_000001.png
            Size: 1179x2556
            Created: \(PhotoSorterMediaCommand.createdText(for: createdAt))
            OCR: false
            VLM: false

            """
        )
    }

    func testMediaShowIncludesMediaAskExcludedCountOnlyWhenPositive() async throws {
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/keep-signal.png": PhotoSorterMediaMetadata(
                    path: "/图库/keep-signal.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                ),
                "/图库/fresh.png": PhotoSorterMediaMetadata(
                    path: "/图库/fresh.png",
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    creationDate: nil
                )
            ],
            mediaAskExcludedCountByPath: [
                "/图库/keep-signal.png": 5
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/keep-signal.png /图库/fresh.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.mediaAskExcludedCountBatchRequestPaths, [["/图库/keep-signal.png", "/图库/fresh.png"]])
        XCTAssertTrue(result.stdout.contains("Path: /图库/keep-signal.png\nSize: 1179x2556\nCreated: unknown\nOCR: false\nVLM: false\nmedia ask excluded count by user: 5"))
        XCTAssertTrue(result.stdout.contains("Path: /图库/fresh.png\nSize: 1284x2778\nCreated: unknown\nOCR: false\nVLM: false"))
        XCTAssertFalse(result.stdout.contains("media ask excluded count by user: 0"))
    }

    func testAlbumRmRunsThroughModelShellProxyCommandPack() async throws {
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("album rm /相册/用户/旅行")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.deletedAlbumPaths, ["/相册/用户/旅行"])
        XCTAssertTrue(result.stdout.contains("without deleting contained photos"))
    }

    func testAlbumRmSupportsMultipleAlbumPaths() async throws {
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("album rm /相册/用户/待确认-订单截图候选 /相册/用户/待确认-广告截图候选 /相册/用户/待确认-游戏截图候选")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.deletedAlbumPaths, [
            "/相册/用户/待确认-订单截图候选",
            "/相册/用户/待确认-广告截图候选",
            "/相册/用户/待确认-游戏截图候选"
        ])
        XCTAssertTrue(result.stdout.contains("album rm: marked 3 album containers"))
        XCTAssertTrue(result.stdout.contains("without deleting contained photos"))
    }

    func testAlbumRmSupportsFromFilePathList() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterAlbumRm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let tmpURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try """
        /相册/用户/空相册-A

          /相册/用户/空相册-B
        /相册/用户/空相册-A
        """.write(
            to: tmpURL.appendingPathComponent("empty_user_albums.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("album rm --from-file /tmp/empty_user_albums.txt")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.deletedAlbumPaths, [
            "/相册/用户/空相册-A",
            "/相册/用户/空相册-B"
        ])
        XCTAssertTrue(result.stdout.contains("album rm: marked 2 album containers"))
    }

    func testFileTreeLsReturnsPhotoSorterWorkspaceTreeSnapshot() async throws {
        let provider = StubMediaProvider()
        provider.fileTreeSnapshotText = """
        当前照片工作区树（动态快照；括号内为该目录树下的媒体条目数；相册统计的是相册引用，可能重复计算同一张照片）：

        /
        ├── 图库/ (42)
        └── 相册/ (1)
            └── 用户/ (1)
                └── 待确认-重要截图/ (0)

        照片库索引：ready，version 7，processed 42/42
        """
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("filetree ls --limit 500")
        let rootPathResult = await shell.run("filetree ls / --limit 12")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, provider.fileTreeSnapshotText + "\n")
        XCTAssertEqual(rootPathResult.exitCode, 0)
        XCTAssertEqual(rootPathResult.stderr, "")
        XCTAssertEqual(rootPathResult.stdout, provider.fileTreeSnapshotText + "\n")
        XCTAssertEqual(provider.fileTreeSnapshotRequests, [
            StubFileTreeSnapshotRequest(rootPath: "/", maxUserAlbums: 500),
            StubFileTreeSnapshotRequest(rootPath: "/", maxUserAlbums: 12)
        ])
    }

    func testFileTreeHelpUsesExampleChatStyleRootAndTopics() async throws {
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let root = await shell.run("filetree --help")
        let lsByHelp = await shell.run("filetree help ls")
        let lsByFlag = await shell.run("filetree ls --help")
        let scopedPath = await shell.run("filetree ls /相册/用户")

        XCTAssertEqual(root.exitCode, 0)
        XCTAssertEqual(root.stderr, "")
        XCTAssertTrue(root.stdout.contains("filetree ls [path] [--limit N]"))
        XCTAssertEqual(lsByHelp.stdout, lsByFlag.stdout)
        XCTAssertTrue(lsByHelp.stdout.contains("current PhotoSorter workspace tree snapshot"))
        XCTAssertTrue(lsByHelp.stdout.contains("rooted at that workspace path"))
        XCTAssertTrue(lsByHelp.stdout.contains("not a recursive filesystem walk"))
        XCTAssertEqual(scopedPath.exitCode, 0)
        XCTAssertEqual(scopedPath.stdout, provider.fileTreeSnapshotText + "\n")
        XCTAssertEqual(provider.fileTreeSnapshotRequests, [
            StubFileTreeSnapshotRequest(rootPath: "/相册/用户", maxUserAlbums: 300)
        ])
    }

    func testMediaHelpUsesExampleChatStyleRootAndTopics() async throws {
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: StubMediaProvider()))

        let root = await shell.run("media --help")
        let showByHelp = await shell.run("media help show")
        let showByFlag = await shell.run("media show --help")
        let ocrByHelp = await shell.run("media help show --ocr")
        let ocrByFlag = await shell.run("media show --ocr --help")
        let vlmByHelp = await shell.run("media help show --vlm")
        let vlmByFlag = await shell.run("media show --vlm --help")
        let vlmStatusByHelp = await shell.run("media help vlm")
        let vlmStatusByFlag = await shell.run("media vlm --help")
        let searchByHelp = await shell.run("media help search --ocr")
        let searchByFlag = await shell.run("media search --ocr --help")
        let searchVLMByHelp = await shell.run("media help search --vlm")
        let searchVLMByFlag = await shell.run("media search --vlm --help")
        let askByHelp = await shell.run("media help ask")
        let askByFlag = await shell.run("media ask --help")

        XCTAssertEqual(root.exitCode, 0)
        XCTAssertEqual(root.stderr, "")
        XCTAssertTrue(root.stdout.contains("media show <path>..."))
        XCTAssertTrue(root.stdout.contains("media list <scope>"))
        XCTAssertTrue(root.stdout.contains("media show --from-file <path-list>"))
        XCTAssertTrue(root.stdout.contains("media show --ocr <path>..."))
        XCTAssertTrue(root.stdout.contains("media show --vlm <path>..."))
        XCTAssertTrue(root.stdout.contains("media status"))
        XCTAssertTrue(root.stdout.contains("media cache status [ocr|vlm|place]"))
        XCTAssertTrue(root.stdout.contains("media stats <scope>"))
        XCTAssertTrue(root.stdout.contains("media trash --from-file <path-list>"))
        XCTAssertTrue(root.stdout.contains("media restore --from-file <path-list>"))
        XCTAssertTrue(root.stdout.contains("media vlm status"))
        XCTAssertTrue(root.stdout.contains("media search --ocr <keyword> <path>..."))
        XCTAssertTrue(root.stdout.contains("media search --ocr <keyword> --from-file <path-list>"))
        XCTAssertTrue(root.stdout.contains("media search --ocr --regex <pattern> <path>..."))
        XCTAssertTrue(root.stdout.contains("media search --vlm <keyword> <path>..."))
        XCTAssertTrue(root.stdout.contains("media search --vlm <keyword> --from-file <path-list>"))
        XCTAssertTrue(root.stdout.contains("media view <path>..."))
        XCTAssertTrue(root.stdout.contains("media ask [--message <text>] <path>..."))
        XCTAssertTrue(root.stdout.contains("media ask ... [--write-selected <path>] [--write-excluded <path>] [--write-skipped <path>]"))

        XCTAssertEqual(showByHelp.stdout, showByFlag.stdout)
        XCTAssertTrue(showByHelp.stdout.contains("OCR: true|false, VLM: true|false"))
        XCTAssertTrue(showByHelp.stdout.contains("media show /相册/系统/截图/a.png"))

        XCTAssertEqual(ocrByHelp.stdout, ocrByFlag.stdout)
        XCTAssertTrue(ocrByHelp.stdout.contains("Cached OCR is returned for every requested path."))
        XCTAssertTrue(ocrByHelp.stdout.contains("OCR:false paths are newly OCRed at most 20 per shell run"))
        XCTAssertTrue(ocrByHelp.stdout.contains("20-image live OCR budget is shared by the whole shell run"))
        XCTAssertTrue(ocrByHelp.stdout.contains("1000 paths"))
        XCTAssertTrue(ocrByHelp.stdout.contains("500 OCR:true"))
        XCTAssertTrue(ocrByHelp.stdout.contains("480 skipped"))
        XCTAssertTrue(ocrByHelp.stdout.contains("Use media search --ocr for cached OCR keyword or regex filtering"))
        XCTAssertTrue(ocrByHelp.stdout.contains("inspect selected images with media view"))
        XCTAssertTrue(ocrByHelp.stdout.contains("does not print Path: records"))
        XCTAssertTrue(ocrByHelp.stdout.contains("/图库/a.png:"))
        XCTAssertTrue(ocrByHelp.stdout.contains("may print only OCR text"))
        XCTAssertTrue(ocrByHelp.stdout.contains("Do not parse media show --ocr output with ^Path:"))

        XCTAssertEqual(vlmByHelp.stdout, vlmByFlag.stdout)
        XCTAssertTrue(vlmByHelp.stdout.contains("Cached VLM summaries are returned for every requested path."))
        XCTAssertTrue(vlmByHelp.stdout.contains("natural-language only"))
        XCTAssertTrue(vlmByHelp.stdout.contains("independent from OCR"))
        XCTAssertTrue(vlmByHelp.stdout.contains("do not contain JSON, labels, or kind fields"))
        XCTAssertTrue(vlmByHelp.stdout.contains("at most 3 per shell run"))
        XCTAssertTrue(vlmByHelp.stdout.contains(PhotoSorterMediaVLMConfiguration.prompt))
        XCTAssertTrue(vlmByHelp.stdout.contains("Search never performs live VLM."))

        XCTAssertEqual(vlmStatusByHelp.stdout, vlmStatusByFlag.stdout)
        XCTAssertTrue(vlmStatusByHelp.stdout.contains("media vlm status"))
        XCTAssertTrue(vlmStatusByHelp.stdout.contains("FastVLM-0.5B stage3"))

        XCTAssertEqual(searchByHelp.stdout, searchByFlag.stdout)
        XCTAssertTrue(searchByHelp.stdout.contains("Search cached OCR text"))
        XCTAssertTrue(searchByHelp.stdout.contains("does not perform live OCR"))
        XCTAssertTrue(searchByHelp.stdout.contains("matching paths with short snippets"))
        XCTAssertTrue(searchByHelp.stdout.contains("media search --ocr <keyword> <path>..."))
        XCTAssertTrue(searchByHelp.stdout.contains("media search --ocr --regex <pattern> <path>..."))

        XCTAssertEqual(searchVLMByHelp.stdout, searchVLMByFlag.stdout)
        XCTAssertTrue(searchVLMByHelp.stdout.contains("Search cached VLM summaries"))
        XCTAssertTrue(searchVLMByHelp.stdout.contains("does not perform live VLM"))
        XCTAssertTrue(searchVLMByHelp.stdout.contains("media search --vlm <keyword> <path>..."))
        XCTAssertTrue(searchVLMByHelp.stdout.contains("media search --vlm --regex <pattern> <path>..."))

        XCTAssertEqual(askByHelp.stdout, askByFlag.stdout)
        XCTAssertTrue(askByHelp.stdout.contains("Ask the user to visually review candidate photos, videos, or Live Photos"))
        XCTAssertTrue(askByHelp.stdout.contains("not for sending original media contents to the model"))
        XCTAssertTrue(askByHelp.stdout.contains("--message <text>"))
        XCTAssertTrue(askByHelp.stdout.contains("media ask --from-file <path-list> [--limit 200]"))
        XCTAssertTrue(askByHelp.stdout.contains("--write-selected, --write-excluded, and --write-skipped"))
        XCTAssertTrue(askByHelp.stdout.contains("one path per line, without changing the default stdout shape"))
        XCTAssertTrue(askByHelp.stdout.contains("At most 200 media items are previewed per command"))
        XCTAssertTrue(askByHelp.stdout.contains("show the user a short explanation"))
        XCTAssertTrue(askByHelp.stdout.contains("date, dimensions, OCR cache, and VLM cache"))
        XCTAssertTrue(askByHelp.stdout.contains("Treat the user's selection and note as the source of truth"))
    }

    func testMediaListReturnsBoundedPathPage() async throws {
        let provider = StubMediaProvider(listItemsByScope: [
            "/相册/系统/截图": [
                PhotoSorterMediaListItem(
                    path: "/相册/系统/截图/b.png",
                    pixelWidth: 1200,
                    pixelHeight: 2000,
                    creationDate: Date(timeIntervalSince1970: 20),
                    modificationDate: nil,
                    mediaType: .image
                ),
                PhotoSorterMediaListItem(
                    path: "/相册/系统/截图/a.png",
                    pixelWidth: 1200,
                    pixelHeight: 2000,
                    creationDate: Date(timeIntervalSince1970: 30),
                    modificationDate: nil,
                    mediaType: .image
                ),
                PhotoSorterMediaListItem(
                    path: "/相册/系统/截图/c.png",
                    pixelWidth: 1200,
                    pixelHeight: 2000,
                    creationDate: Date(timeIntervalSince1970: 10),
                    modificationDate: nil,
                    mediaType: .image
                )
            ]
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media list /相册/系统/截图 --sort name --order asc --limit 2")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "/相册/系统/截图/a.png\n/相册/系统/截图/b.png\n")
        XCTAssertEqual(
            result.stderr,
            "media list: total 3, offset 0, returned 2, remaining 1, scope /相册/系统/截图\n"
        )
        XCTAssertEqual(provider.listRequests, [
            StubMediaListRequest(
                scopePath: "/相册/系统/截图",
                offset: 0,
                limit: 2,
                sort: .name,
                order: .asc,
                mediaType: .all
            )
        ])
    }

    func testMediaShowReadsFromFileWithInputLimitAndStructuredOutput() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try """
        /图库/a.png
        /图库/b.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("show_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/a.png": PhotoSorterMediaMetadata(
                path: "/图库/a.png",
                pixelWidth: 1179,
                pixelHeight: 2556,
                creationDate: Date(timeIntervalSince1970: 1)
            ),
            "/图库/b.png": PhotoSorterMediaMetadata(
                path: "/图库/b.png",
                pixelWidth: 1284,
                pixelHeight: 2778,
                creationDate: Date(timeIntervalSince1970: 2)
            )
        ])
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show --from-file /tmp/show_paths.txt --limit 1 --format tsv")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.hasPrefix("path\ttype\twidth\theight\tcreated\tmodified\tocr\tvlm\n/图库/a.png\tunknown\t1179\t2556\t"))
        XCTAssertFalse(result.stdout.contains("/图库/b.png"))
        XCTAssertEqual(provider.metadataBatchRequestPaths, [["/图库/a.png"]])
    }

    func testMediaSearchOCRReadsFromFileAndCanOutputPathsOnly() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try """
        /图库/pay.png
        /图库/code.png
        /图库/nohit.png
        /图库/ignored.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider(cachedOCRByPath: [
            "/图库/pay.png": "微信 支付成功 金额 128",
            "/图库/code.png": "验证码 123456",
            "/图库/nohit.png": "今天的天气很好",
            "/图库/ignored.png": "验证码 999999"
        ])
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --ocr --regex '支付|验证码' --from-file /tmp/paths.txt --limit 3 --format paths")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "/图库/pay.png\n/图库/code.png\n")
        XCTAssertEqual(
            result.stderr,
            "OCR search: requested 3, cached 3, matched 2, uncached 0, unavailable 0.\n"
        )
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [[
            "/图库/pay.png",
            "/图库/code.png",
            "/图库/nohit.png"
        ]])
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
    }

    func testMediaViewReadsFromFileWithInputLimit() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try """
        /图库/a.png
        /图库/b.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("view_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": Self.sampleImage(path: "/图库/a.png"),
            "/图库/b.png": Self.sampleImage(path: "/图库/b.png")
        ])
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view --from-file /tmp/view_paths.txt --limit 1")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.modelImageRequestPaths, ["/图库/a.png"])
        XCTAssertTrue(result.stdout.contains("Sent 1 image(s) to model:"))
        XCTAssertTrue(result.stdout.contains("- /图库/a.png"))
        XCTAssertFalse(result.stdout.contains("/图库/b.png"))
    }

    func testMediaTrashAndRestoreReadFromFileWithInputLimit() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try """
        /图库/a.png
        /图库/b.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("trash_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        /最近删除/a.png
        /最近删除/b.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("restore_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let trash = await shell.run("media trash --from-file /tmp/trash_paths.txt --limit 1")
        let restore = await shell.run("media restore --from-file /tmp/restore_paths.txt --limit 1")

        XCTAssertEqual(trash.exitCode, 0)
        XCTAssertEqual(trash.stderr, "")
        XCTAssertEqual(trash.stdout, "media trash: trashed 1, requested 1\n")
        XCTAssertEqual(restore.exitCode, 0)
        XCTAssertEqual(restore.stderr, "")
        XCTAssertEqual(restore.stdout, "media restore: restored 1, requested 1\n")
        XCTAssertEqual(provider.trashedAssetPathBatches, [["/图库/a.png"]])
        XCTAssertEqual(provider.restoredTrashPathBatches, [["/最近删除/a.png"]])
    }

    func testMediaTrashAndRestoreSkipMissingPathsByDefault() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try """
        /图库/a.png
        /图库/missing.png
        /图库/b.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("trash_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        /最近删除/a.png
        /最近删除/missing.png
        /最近删除/b.png
        """.write(
            to: workspace.tmpURL.appendingPathComponent("restore_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider(
            missingTrashPaths: ["/图库/missing.png"],
            missingRestorePaths: ["/最近删除/missing.png"]
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let trash = await shell.run("media trash --from-file /tmp/trash_paths.txt")
        let restore = await shell.run("media restore --from-file /tmp/restore_paths.txt")

        XCTAssertEqual(trash.exitCode, 0)
        XCTAssertEqual(trash.stderr, "")
        XCTAssertEqual(trash.stdout, "media trash: trashed 2, missing 1, requested 3\n")
        XCTAssertEqual(restore.exitCode, 0)
        XCTAssertEqual(restore.stderr, "")
        XCTAssertEqual(restore.stdout, "media restore: restored 2, missing 1, requested 3\n")
        XCTAssertEqual(provider.trashedAssetPathBatches, [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(provider.restoredTrashPathBatches, [["/最近删除/a.png", "/最近删除/b.png"]])
    }

    func testMediaTrashAndRestoreRejectInvalidRoots() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try "/tmp/not-photo.png\n".write(
            to: workspace.tmpURL.appendingPathComponent("invalid_trash_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "/图库/a.png\n".write(
            to: workspace.tmpURL.appendingPathComponent("invalid_restore_paths.txt"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let trash = await shell.run("media trash --from-file /tmp/invalid_trash_paths.txt")
        let restore = await shell.run("media restore --from-file /tmp/invalid_restore_paths.txt")

        XCTAssertNotEqual(trash.exitCode, 0)
        XCTAssertEqual(trash.stdout, "")
        XCTAssertTrue(trash.stderr.contains("media trash: expected a photo or video path under /图库 or /相册"))
        XCTAssertNotEqual(restore.exitCode, 0)
        XCTAssertEqual(restore.stdout, "")
        XCTAssertTrue(restore.stderr.contains("media restore: expected a /最近删除 path"))
        XCTAssertEqual(provider.trashedAssetPathBatches, [])
        XCTAssertEqual(provider.restoredTrashPathBatches, [])
    }

    func testMediaStatusAndStatsUseCheapProviders() async throws {
        let provider = StubMediaProvider(listItemsByScope: [
            "/图库": [
                PhotoSorterMediaListItem(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: Date(timeIntervalSince1970: 1),
                    modificationDate: nil,
                    mediaType: .image
                ),
                PhotoSorterMediaListItem(
                    path: "/图库/b.mov",
                    pixelWidth: 1920,
                    pixelHeight: 1080,
                    creationDate: Date(timeIntervalSince1970: 2),
                    modificationDate: nil,
                    mediaType: .video
                )
            ]
        ])
        provider.indexStatus = PhotoLibraryIndexStatus(
            phase: .ready,
            processed: 10,
            total: 10,
            currentPath: nil,
            version: 4,
            message: nil,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        provider.ocrStatus = PhotoSorterMediaOCRCacheStatus(
            cachedCount: 7,
            totalCount: 10,
            isPreheating: false,
            isPaused: false,
            processedInCurrentBatch: 0,
            batchLimit: 20,
            message: nil
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let status = await shell.run("media status")
        let stats = await shell.run("media stats /图库 --group-by type")

        XCTAssertEqual(status.exitCode, 0)
        XCTAssertTrue(status.stdout.contains("Index: ready, version 4, processed 10/10"))
        XCTAssertTrue(status.stdout.contains("OCR cache: 7/10"))
        XCTAssertEqual(stats.exitCode, 0)
        XCTAssertEqual(stats.stdout, "key\tcount\nimage\t1\nvideo\t1\n")
        XCTAssertEqual(provider.statsRequests, [
            StubMediaStatsRequest(
                scopePath: "/图库",
                groupBy: .type,
                dateField: .created,
                mediaType: .all
            )
        ])
        XCTAssertEqual(provider.listRequests, [])
    }

    func testVLMConfigurationUsesNaturalLanguageSummaryPromptOnly() {
        XCTAssertEqual(
            PhotoSorterMediaVLMConfiguration.prompt,
            "用简体中文一到两句话描述这张图片的主要内容，总字数不超过50字。不要转写大段文字。"
        )
        XCTAssertFalse(PhotoSorterMediaVLMConfiguration.prompt.localizedCaseInsensitiveContains("json"))
        XCTAssertFalse(PhotoSorterMediaVLMConfiguration.prompt.localizedCaseInsensitiveContains("label"))
        XCTAssertFalse(PhotoSorterMediaVLMConfiguration.prompt.localizedCaseInsensitiveContains("kind"))
        XCTAssertFalse(PhotoSorterMediaVLMConfiguration.prompt.localizedCaseInsensitiveContains("ocr"))
        XCTAssertEqual(PhotoSorterMediaVLMConfiguration.language, "zh-Hans")
        XCTAssertEqual(PhotoSorterMediaVLMConfiguration.summarySchemaVersion, 1)
        XCTAssertEqual(PhotoSorterMediaVLMConfiguration.maximumSummaryCharacterCount, 50)
    }

    func testVLMSummaryNormalizationCapsRunawayModelOutput() {
        let output = """
        这张图片展示了一款动作游戏的屏幕，其中包含中文文字和游戏界面元素，如“dnf”、“SickStyle”、“SickStyle”、“SickStyle”、“SickStyle”、“SickStyle”、“SickStyle”。第二句仍然继续很长。第三句不应该进入缓存。
        """

        let summary = PhotoSorterMediaVLMConfiguration.normalizedSummaryOutput(output)

        XCTAssertLessThanOrEqual(summary.count, PhotoSorterMediaVLMConfiguration.maximumSummaryCharacterCount)
        XCTAssertTrue(summary.hasPrefix("这张图片展示了一款动作游戏"))
        XCTAssertTrue(summary.hasSuffix("。"))
        XCTAssertFalse(summary.contains("第三句"))
    }

    func testVLMSummaryNormalizationTurnsLongFragmentsIntoSentence() {
        let output = "这张图片显示了一个使用SQLLite的文件传输工具，用于将文件从一个文件夹传输到另一个文件夹，同时处理多个文件路径。"

        let summary = PhotoSorterMediaVLMConfiguration.normalizedSummaryOutput(output)

        XCTAssertEqual(summary, "这张图片显示了一个使用SQLLite的文件传输工具。")
        XCTAssertLessThanOrEqual(summary.count, PhotoSorterMediaVLMConfiguration.maximumSummaryCharacterCount)
    }

    func testVLMSummaryNormalizationCollapsesWhitespaceAndKeepsAtMostTwoSentences() {
        let output = "  第一句摘要。\n\n第二句摘要。\n第三句不应该进入缓存。  "

        let summary = PhotoSorterMediaVLMConfiguration.normalizedSummaryOutput(output)

        XCTAssertEqual(summary, "第一句摘要。 第二句摘要。")
    }

    func testMediaViewHelpDoesNotRequireFullAccessMode() async throws {
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": Self.sampleImage(path: "/图库/a.png")
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media view --help")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("Requires full Photos access mode."))
        XCTAssertTrue(result.stdout.contains("At most 20 images are sent per command"))
        XCTAssertTrue(result.stdout.contains("Use this when OCR is missing or uncertain"))
        XCTAssertEqual(provider.modelImageRequestPaths, [])
    }

    func testAlbumHelpUsesExampleChatStyleRootAndTopics() async throws {
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let root = await shell.run("album help")
        let rootByFlag = await shell.run("album --help")
        let addByHelp = await shell.run("album help add")
        let addByFlag = await shell.run("album add --help")
        let removeByHelp = await shell.run("album help remove")
        let removeByFlag = await shell.run("album remove --help")
        let rmByHelp = await shell.run("album help rm")
        let rmByFlag = await shell.run("album rm --help")

        XCTAssertEqual(root.exitCode, 0)
        XCTAssertEqual(root.stdout, rootByFlag.stdout)
        XCTAssertTrue(root.stdout.contains("album add [--create] <user-album-path> <photo-path>..."))
        XCTAssertTrue(root.stdout.contains("album add [--create] --from-file <path-list> <user-album-path>"))
        XCTAssertTrue(root.stdout.contains("album remove --from-file <path-list> <user-album-path>"))
        XCTAssertTrue(root.stdout.contains("album rm <user-album-path>..."))
        XCTAssertTrue(root.stdout.contains("album rm --from-file <path-list>"))
        XCTAssertEqual(addByHelp.stdout, addByFlag.stdout)
        XCTAssertTrue(addByHelp.stdout.contains("Add existing photo or video references to a user album under /相册/用户."))
        XCTAssertTrue(addByHelp.stdout.contains("does not duplicate image bodies"))
        XCTAssertTrue(addByHelp.stdout.contains("album add --create --from-file /tmp/low_value_paths.txt"))
        XCTAssertEqual(removeByHelp.stdout, removeByFlag.stdout)
        XCTAssertTrue(removeByHelp.stdout.contains("Remove selected photo or video references from a user album under /相册/用户."))
        XCTAssertTrue(removeByHelp.stdout.contains("keeps the assets in /图库"))
        XCTAssertTrue(removeByHelp.stdout.contains("album remove --from-file /tmp/selected_from_album.txt"))
        XCTAssertEqual(rmByHelp.stdout, rmByFlag.stdout)
        XCTAssertTrue(rmByHelp.stdout.contains("Remove a user album container under /相册/用户."))
        XCTAssertTrue(rmByHelp.stdout.contains("does not delete the photo assets inside the album"))
        XCTAssertTrue(rmByHelp.stdout.contains("with one user album path per line"))
        XCTAssertTrue(rmByHelp.stdout.contains("album rm --from-file /tmp/empty_user_albums.txt"))
        XCTAssertEqual(provider.albumAddRequests, [])
        XCTAssertEqual(provider.albumRemoveRequests, [])
        XCTAssertEqual(provider.deletedAlbumPaths, [])
    }

    func testAlbumAddRunsThroughModelShellProxyCommandPack() async throws {
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("album add --create /相册/用户/候选 /图库/a.png 相册/系统/截图/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("album add: added 2"))
        XCTAssertTrue(result.stdout.contains("requested 2"))
        XCTAssertEqual(provider.albumAddRequests, [
            StubAlbumAddRequest(
                assetPaths: ["/图库/a.png", "/相册/系统/截图/b.png"],
                albumPath: "/相册/用户/候选",
                createAlbumIfNeeded: true
            )
        ])
    }

    func testAlbumRemoveRunsThroughModelShellProxyCommandPack() async throws {
        let provider = StubMediaProvider()
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(currentDirectory: "/")
        ).enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("album remove /相册/用户/候选 /相册/用户/候选/a.png 图库/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("album remove: removed 2"))
        XCTAssertTrue(result.stdout.contains("skipped_not_in_album 0"))
        XCTAssertTrue(result.stdout.contains("requested 2"))
        XCTAssertEqual(provider.albumRemoveRequests, [
            StubAlbumRemoveRequest(
                assetPaths: ["/相册/用户/候选/a.png", "/图库/b.png"],
                albumPath: "/相册/用户/候选"
            )
        ])
    }

    func testAlbumHelpWorksThroughStderrMergeAndHeadPipeline() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore(excluding: ["rm"]))
            .enable(PhotoSorterCommandPack(mediaProvider: StubMediaProvider()))

        let result = await shell.run("album --help 2>&1 | head -120")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("album add [--create] --from-file <path-list> <user-album-path>"))
        XCTAssertTrue(result.stdout.contains("album remove --from-file <path-list> <user-album-path>"))
        XCTAssertTrue(result.stdout.contains("album rm <user-album-path>..."))
        XCTAssertTrue(result.stdout.contains("album rm --from-file <path-list>"))
    }

    func testMediaHelpReportsUnknownTopic() async throws {
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: StubMediaProvider()))

        let result = await shell.run("media help missing")

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("media help: unknown topic missing"))
        XCTAssertTrue(result.stderr.contains("media show <path>..."))
    }

    func testMediaShowNormalizesRelativePathFromCurrentDirectory() async throws {
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/照片_000123.jpg": PhotoSorterMediaMetadata(
                path: "/图库/照片_000123.jpg",
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil
            )
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(currentDirectory: "/图库")
        ).enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show 照片_000123.jpg")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stdout,
            """
            Path: /图库/照片_000123.jpg
            Size: 4032x3024
            Created: unknown
            OCR: false
            VLM: false

            """
        )
    }

    func testMediaShowReportsOCRCacheMissInFullAccessMode() async throws {
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/截图_000777.png": PhotoSorterMediaMetadata(
                path: "/图库/截图_000777.png",
                pixelWidth: 1284,
                pixelHeight: 2778,
                creationDate: nil
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show /图库/截图_000777.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stdout,
            """
            Path: /图库/截图_000777.png
            Size: 1284x2778
            Created: unknown
            OCR: false
            VLM: false

            """
        )
        XCTAssertFalse(result.stdout.contains("Location:"))
    }

    func testMediaShowReportsOCRCacheHitWithoutLiveRecognition() async throws {
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/cached.png": PhotoSorterMediaMetadata(
                    path: "/图库/cached.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                )
            ],
            cachedOCRByPath: [
                "/图库/cached.png": "cached text"
            ],
            liveOCRByPath: [
                "/图库/cached.png": "live text"
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/cached.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("OCR: true"))
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
    }

    func testMediaShowHidesCachedPlaceOutsideFullAccessMode() async throws {
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/照片_000888.jpg": PhotoSorterMediaMetadata(
                path: "/图库/照片_000888.jpg",
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil,
                cachedPlace: "中国上海市黄浦区"
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/照片_000888.jpg")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains("地点:"))
        XCTAssertFalse(result.stdout.contains("中国上海市黄浦区"))
    }

    func testMediaShowIncludesCachedChinesePlaceInFullAccessMode() async throws {
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/照片_000999.jpg": PhotoSorterMediaMetadata(
                path: "/图库/照片_000999.jpg",
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil,
                cachedPlace: "中国上海市黄浦区"
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show /图库/照片_000999.jpg")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("地点: 中国上海市黄浦区"))
        XCTAssertFalse(result.stdout.contains("Location:"))
    }

    func testMediaShowSupportsMultiplePaths() async throws {
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/照片_000001.jpg": PhotoSorterMediaMetadata(
                path: "/图库/照片_000001.jpg",
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil
            ),
            "/图库/照片_000002.jpg": PhotoSorterMediaMetadata(
                path: "/图库/照片_000002.jpg",
                pixelWidth: 1179,
                pixelHeight: 2556,
                creationDate: nil
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/照片_000001.jpg /图库/照片_000002.jpg")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            Path: /图库/照片_000001.jpg
            Size: 4032x3024
            Created: unknown
            OCR: false
            VLM: false

            Path: /图库/照片_000002.jpg
            Size: 1179x2556
            Created: unknown
            OCR: false
            VLM: false

            """
        )
    }

    func testMediaShowUsesBatchMetadataAndOCRCacheLookups() async throws {
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/a.png": PhotoSorterMediaMetadata(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                ),
                "/图库/b.png": PhotoSorterMediaMetadata(
                    path: "/图库/b.png",
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    creationDate: nil
                )
            ],
            cachedOCRByPath: [
                "/图库/b.png": "cached text"
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/a.png /图库/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(provider.metadataBatchRequestPaths, [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(provider.metadataSingleRequestPaths, [])
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(provider.cachedOCRSingleRequestPaths, [])
        XCTAssertTrue(result.stdout.contains("Path: /图库/a.png\nSize: 1179x2556\nCreated: unknown\nOCR: false\nVLM: false"))
        XCTAssertTrue(result.stdout.contains("Path: /图库/b.png\nSize: 1284x2778\nCreated: unknown\nOCR: true\nVLM: false"))
    }

    func testMediaShowReturnsFoundPathsAndReportsMissingPaths() async throws {
        let provider = StubMediaProvider(metadataByPath: [
            "/图库/found.jpg": PhotoSorterMediaMetadata(
                path: "/图库/found.jpg",
                pixelWidth: 4032,
                pixelHeight: 3024,
                creationDate: nil
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/found.jpg /图库/missing.jpg")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "media show: /图库/missing.jpg: media asset not found\n")
        XCTAssertEqual(
            result.stdout,
            """
            Path: /图库/found.jpg
            Size: 4032x3024
            Created: unknown
            OCR: false
            VLM: false

            """
        )
    }

    func testMediaShowReportsMissingAsset() async throws {
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: StubMediaProvider()))

        let result = await shell.run("media show /图库/照片_999999.jpg")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "media show: /图库/照片_999999.jpg: media asset not found\n")
    }

    func testMediaShowOCRSinglePathReturnsOnlyText() async throws {
        let provider = StubMediaProvider(
            liveOCRByPath: [
                "/图库/a.png": "第一行\n第二行"
            ],
            mediaAskExcludedCountByPath: [
                "/图库/a.png": 5
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --ocr /图库/a.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "第一行\n第二行\n")
        XCTAssertEqual(provider.liveOCRRequestPaths, ["/图库/a.png"])
        XCTAssertEqual(provider.mediaAskExcludedCountBatchRequestPaths, [["/图库/a.png"]])
    }

    func testMediaShowOCRRequiresFullAccessMode() async throws {
        let provider = StubMediaProvider(liveOCRByPath: [
            "/图库/a.png": "text"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show --ocr /图库/a.png")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "media show --ocr: OCR requires full Photos access mode\n")
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
    }

    func testMediaShowOCRMultiplePathsUsesOriginalPathsAsSeparators() async throws {
        let provider = StubMediaProvider(liveOCRByPath: [
            "/图库/a.png": "Alpha",
            "/相册/系统/截图/b.png": "Beta"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --ocr /图库/a.png /相册/系统/截图/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            /图库/a.png:
            Alpha

            /相册/系统/截图/b.png:
            Beta

            """
        )
    }

    func testMediaShowOCRMultiplePathsIncludesPositiveMediaAskExcludedCount() async throws {
        let provider = StubMediaProvider(
            cachedOCRByPath: [
                "/图库/a.png": "Alpha",
                "/图库/b.png": "Beta"
            ],
            mediaAskExcludedCountByPath: [
                "/图库/a.png": 5
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --ocr /图库/a.png /图库/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            /图库/a.png:
            media ask excluded count by user: 5
            Alpha

            /图库/b.png:
            Beta

            """
        )
        XCTAssertFalse(result.stdout.contains("media ask excluded count by user: 0"))
    }

    func testMediaShowOCRLimitsOnlyLiveRecognitionNotCachedResults() async throws {
        let cachedPaths = (1...50).map { "/图库/cached-\($0).png" }
        let livePaths = (1...50).map { "/图库/live-\($0).png" }
        var cachedOCRByPath: [String: String] = [:]
        var liveOCRByPath: [String: String] = [:]
        for path in cachedPaths {
            cachedOCRByPath[path] = "cached \(path)"
        }
        for path in livePaths {
            liveOCRByPath[path] = "live \(path)"
        }
        let provider = StubMediaProvider(
            cachedOCRByPath: cachedOCRByPath,
            liveOCRByPath: liveOCRByPath
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --ocr " + (cachedPaths + livePaths).joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveOCRRequestPaths, Array(livePaths.prefix(20)))
        XCTAssertTrue(result.stdout.contains("/图库/cached-50.png:\ncached /图库/cached-50.png"))
        XCTAssertTrue(result.stdout.contains("/图库/live-20.png:\nlive /图库/live-20.png"))
        XCTAssertFalse(result.stdout.contains("/图库/live-21.png:"))
        XCTAssertTrue(result.stdout.contains("OCR limit: requested 100, returned 70, cached 50, processed 20, skipped 30."))
    }

    func testMediaShowOCRSharesLiveBudgetAcrossOneShellRun() async throws {
        let firstLivePaths = (1...20).map { "/图库/live-\($0).png" }
        let secondLivePaths = (21...23).map { "/图库/live-\($0).png" }
        var liveOCRByPath: [String: String] = [:]
        for path in firstLivePaths + secondLivePaths {
            liveOCRByPath[path] = "live \(path)"
        }
        let provider = StubMediaProvider(liveOCRByPath: liveOCRByPath)
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await PhotoSorterMediaLiveOCRBudget.withBudget(limit: 20) {
            await shell.run([
                "media show --ocr " + firstLivePaths.joined(separator: " "),
                "media show --ocr " + secondLivePaths.joined(separator: " ")
            ].joined(separator: "; "))
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveOCRRequestPaths, firstLivePaths)
        XCTAssertTrue(result.stdout.contains("/图库/live-20.png:\nlive /图库/live-20.png"))
        XCTAssertFalse(result.stdout.contains("/图库/live-21.png:"))
        XCTAssertTrue(result.stdout.contains("OCR limit: requested 3, returned 0, cached 0, processed 0, skipped 3."))
    }

    func testMediaShowOCRSharedBudgetStillReturnsCachedResultsAfterBudgetIsExhausted() async throws {
        let firstLivePaths = (1...20).map { "/图库/live-\($0).png" }
        let cachedPaths = (1...3).map { "/图库/cached-\($0).png" }
        let skippedLivePaths = (21...23).map { "/图库/live-\($0).png" }
        var cachedOCRByPath: [String: String] = [:]
        var liveOCRByPath: [String: String] = [:]
        for path in cachedPaths {
            cachedOCRByPath[path] = "cached \(path)"
        }
        for path in firstLivePaths + skippedLivePaths {
            liveOCRByPath[path] = "live \(path)"
        }
        let provider = StubMediaProvider(
            cachedOCRByPath: cachedOCRByPath,
            liveOCRByPath: liveOCRByPath
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await PhotoSorterMediaLiveOCRBudget.withBudget(limit: 20) {
            await shell.run([
                "media show --ocr " + firstLivePaths.joined(separator: " "),
                "media show --ocr " + (cachedPaths + skippedLivePaths).joined(separator: " ")
            ].joined(separator: "; "))
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveOCRRequestPaths, firstLivePaths)
        XCTAssertTrue(result.stdout.contains("/图库/cached-3.png:\ncached /图库/cached-3.png"))
        XCTAssertFalse(result.stdout.contains("/图库/live-21.png:"))
        XCTAssertTrue(result.stdout.contains("OCR limit: requested 6, returned 3, cached 3, processed 0, skipped 3."))
    }

    func testMediaShowOCRCacheHitsDoNotTriggerLiveRecognition() async throws {
        let provider = StubMediaProvider(cachedOCRByPath: [
            "/图库/cached.png": "cached text"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --ocr /图库/cached.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "cached text\n")
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
    }

    func testMediaSearchOCRKeywordSearchesCachedTextWithoutLiveRecognition() async throws {
        let provider = StubMediaProvider(
            cachedOCRByPath: [
                "/图库/pay.png": "微信 支付成功\n金额 ¥128.00",
                "/图库/code.png": "验证码 123456\n请勿泄露",
                "/图库/nohit.png": "今天的天气很好"
            ],
            liveOCRByPath: [
                "/图库/live.png": "验证码 999999"
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --ocr 验证码 /图库/pay.png /图库/code.png /图库/nohit.png /图库/live.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [[
            "/图库/pay.png",
            "/图库/code.png",
            "/图库/nohit.png",
            "/图库/live.png"
        ]])
        XCTAssertTrue(result.stdout.contains("OCR search: requested 4, cached 3, matched 1, uncached 1, unavailable 0."))
        XCTAssertTrue(result.stdout.contains("Keyword: 验证码"))
        XCTAssertTrue(result.stdout.contains("/图库/code.png:\n验证码 123456 请勿泄露"))
        XCTAssertFalse(result.stdout.contains("/图库/pay.png:"))
        XCTAssertFalse(result.stdout.contains("/图库/live.png:"))
    }

    func testMediaSearchOCRRegexSearchesCachedTextWithoutLiveRecognition() async throws {
        let provider = StubMediaProvider(
            cachedOCRByPath: [
                "/图库/pay.png": "微信 支付成功\n金额 ¥128.00",
                "/图库/code.png": "验证码 123456\n请勿泄露",
                "/图库/nohit.png": "今天的天气很好"
            ],
            liveOCRByPath: [
                "/图库/live.png": "验证码 999999"
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --ocr --regex '支付成功|验证码' /图库/pay.png /图库/code.png /图库/nohit.png /图库/live.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
        XCTAssertTrue(result.stdout.contains("OCR search: requested 4, cached 3, matched 2, uncached 1, unavailable 0."))
        XCTAssertTrue(result.stdout.contains("Regex: 支付成功|验证码"))
        XCTAssertTrue(result.stdout.contains("/图库/pay.png:\n微信 支付成功 金额 ¥128.00"))
        XCTAssertTrue(result.stdout.contains("/图库/code.png:\n验证码 123456 请勿泄露"))
        XCTAssertFalse(result.stdout.contains("/图库/live.png:"))
    }

    func testMediaSearchOCRJSONLIncludesMatchDetails() async throws {
        let provider = StubMediaProvider(
            cachedOCRByPath: [
                "/图库/pay.png": "微信 支付成功\n金额 ¥128.00",
                "/图库/code.png": "验证码 123456\n请勿泄露",
                "/图库/nohit.png": "今天的天气很好"
            ],
            liveOCRByPath: [
                "/图库/live.png": "验证码 999999"
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --ocr --regex '支付成功|验证码' /图库/pay.png /图库/code.png /图库/nohit.png /图库/live.png --format jsonl")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stderr,
            "OCR search: requested 4, cached 3, matched 2, uncached 1, unavailable 0.\n"
        )
        let objects = try Self.jsonLines(result.stdout)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["path"] as? String, "/图库/pay.png")
        XCTAssertEqual(objects[0]["source"] as? String, "ocr")
        XCTAssertEqual(objects[0]["query_kind"] as? String, "regex")
        XCTAssertEqual(objects[0]["query"] as? String, "支付成功|验证码")
        XCTAssertEqual(objects[0]["pattern"] as? String, "支付成功|验证码")
        XCTAssertEqual(objects[0]["match"] as? String, "支付成功")
        XCTAssertEqual(objects[0]["snippet"] as? String, "微信 支付成功 金额 ¥128.00")
        XCTAssertEqual(objects[1]["path"] as? String, "/图库/code.png")
        XCTAssertEqual(objects[1]["match"] as? String, "验证码")
    }

    func testMediaSearchVLMJSONLIncludesMatchDetails() async throws {
        let provider = StubMediaProvider(cachedVLMByPath: [
            "/图库/game.png": "一张游戏战绩截图，画面里有胜利和段位信息。",
            "/图库/nohit.png": "一张课堂笔记截图。"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --vlm 游戏 /图库/game.png /图库/nohit.png --format jsonl")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.stderr,
            "VLM search: requested 2, cached 2, matched 1, uncached 0, unavailable 0.\n"
        )
        let objects = try Self.jsonLines(result.stdout)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0]["path"] as? String, "/图库/game.png")
        XCTAssertEqual(objects[0]["source"] as? String, "vlm")
        XCTAssertEqual(objects[0]["query_kind"] as? String, "keyword")
        XCTAssertEqual(objects[0]["query"] as? String, "游戏")
        XCTAssertEqual(objects[0]["term"] as? String, "游戏")
        XCTAssertEqual(objects[0]["match"] as? String, "游戏")
        XCTAssertTrue((objects[0]["snippet"] as? String)?.contains("游戏战绩截图") == true)
    }

    func testMediaSearchOCRPreservesDuplicatePathStatsInBatchLookup() async throws {
        let provider = StubMediaProvider(cachedOCRByPath: [
            "/图库/code.png": "验证码 123456\n请勿泄露"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --ocr 验证码 /图库/code.png /图库/missing.png /图库/code.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [[
            "/图库/code.png",
            "/图库/missing.png",
            "/图库/code.png"
        ]])
        XCTAssertTrue(result.stdout.contains("OCR search: requested 3, cached 2, matched 2, uncached 1, unavailable 0."))
        XCTAssertEqual(
            result.stdout.components(separatedBy: "/图库/code.png:\n验证码 123456 请勿泄露").count - 1,
            2
        )
    }

    func testMediaSearchOCRRequiresFullAccessMode() async throws {
        let provider = StubMediaProvider(cachedOCRByPath: [
            "/图库/code.png": "验证码 123456"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media search --ocr '验证码' /图库/code.png")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "media search --ocr: OCR search requires full Photos access mode\n")
        XCTAssertEqual(provider.liveOCRRequestPaths, [])
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [])
    }

    func testMediaSearchOCRReportsInvalidRegex() async throws {
        let provider = StubMediaProvider(cachedOCRByPath: [
            "/图库/code.png": "验证码 123456"
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media search --ocr --regex '[' /图库/code.png")

        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("media search --ocr: invalid regex:"))
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [])
    }

    func testMediaVLMStatusReportsProviderAndCacheState() async throws {
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/a.png": PhotoSorterMediaMetadata(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                ),
                "/图库/b.png": PhotoSorterMediaMetadata(
                    path: "/图库/b.png",
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    creationDate: nil
                )
            ],
            cachedVLMByPath: [
                "/图库/a.png": "一张手机支付页面截图，画面中有付款成功提示。"
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media vlm status")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("VLM: not installed"))
        XCTAssertTrue(result.stdout.contains("Backend: bundled local model"))
        XCTAssertTrue(result.stdout.contains("Model: FastVLM-0.5B stage3"))
        XCTAssertTrue(result.stdout.contains("System provider: unavailable"))
        XCTAssertTrue(result.stdout.contains("Cache: 1/2"))
        XCTAssertTrue(result.stdout.contains("Prompt: vlm-summary-zh-v1"))
        XCTAssertTrue(result.stdout.contains("Reason: local FastVLM model is not installed"))
    }

    func testMediaShowReportsVLMCacheHitWithoutLiveSummary() async throws {
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/cached.png": PhotoSorterMediaMetadata(
                    path: "/图库/cached.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                )
            ],
            cachedVLMByPath: [
                "/图库/cached.png": "一张手机支付页面截图。"
            ],
            liveVLMByPath: [
                "/图库/cached.png": "live summary"
            ],
            vlmLiveAvailable: true
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(mediaProvider: provider))

        let result = await shell.run("media show /图库/cached.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("VLM: true"))
        XCTAssertEqual(provider.liveVLMRequestPaths, [])
    }

    func testMediaShowVLMLimitsOnlyLiveSummariesNotCachedResults() async throws {
        let cachedPaths = (1...5).map { "/图库/cached-\($0).png" }
        let livePaths = (1...5).map { "/图库/live-\($0).png" }
        var cachedVLMByPath: [String: String] = [:]
        var liveVLMByPath: [String: String] = [:]
        for path in cachedPaths {
            cachedVLMByPath[path] = "cached summary \(path)"
        }
        for path in livePaths {
            liveVLMByPath[path] = "live summary \(path)"
        }
        let provider = StubMediaProvider(
            cachedVLMByPath: cachedVLMByPath,
            liveVLMByPath: liveVLMByPath,
            vlmLiveAvailable: true
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --vlm " + (cachedPaths + livePaths).joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveVLMRequestPaths, Array(livePaths.prefix(3)))
        XCTAssertTrue(result.stdout.contains("/图库/cached-5.png:\ncached summary /图库/cached-5.png"))
        XCTAssertTrue(result.stdout.contains("/图库/live-3.png:\nlive summary /图库/live-3.png"))
        XCTAssertFalse(result.stdout.contains("/图库/live-4.png:"))
        XCTAssertTrue(result.stdout.contains("VLM limit: requested 10, returned 8, cached 5, processed 3, skipped 2."))
    }

    func testMediaShowVLMMultiplePathsIncludesPositiveMediaAskExcludedCount() async throws {
        let provider = StubMediaProvider(
            cachedVLMByPath: [
                "/图库/a.png": "一张物理题截图。",
                "/图库/b.png": "一张购物订单截图。"
            ],
            mediaAskExcludedCountByPath: [
                "/图库/a.png": 3
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --vlm /图库/a.png /图库/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            /图库/a.png:
            media ask excluded count by user: 3
            一张物理题截图。

            /图库/b.png:
            一张购物订单截图。

            """
        )
        XCTAssertFalse(result.stdout.contains("media ask excluded count by user: 0"))
    }

    func testMediaShowVLMSharedBudgetAcrossOneShellRun() async throws {
        let firstLivePaths = (1...3).map { "/图库/live-\($0).png" }
        let secondLivePaths = (4...6).map { "/图库/live-\($0).png" }
        var liveVLMByPath: [String: String] = [:]
        for path in firstLivePaths + secondLivePaths {
            liveVLMByPath[path] = "live summary \(path)"
        }
        let provider = StubMediaProvider(
            liveVLMByPath: liveVLMByPath,
            vlmLiveAvailable: true
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await MSPPlaygroundShellRuntime.withMediaLiveBudgets {
            await shell.run([
                "media show --vlm " + firstLivePaths.joined(separator: " "),
                "media show --vlm " + secondLivePaths.joined(separator: " ")
            ].joined(separator: "; "))
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveVLMRequestPaths, firstLivePaths)
        XCTAssertTrue(result.stdout.contains("/图库/live-3.png:\nlive summary /图库/live-3.png"))
        XCTAssertFalse(result.stdout.contains("/图库/live-4.png:"))
        XCTAssertTrue(result.stdout.contains("VLM limit: requested 3, returned 0, cached 0, processed 0, skipped 3."))
    }

    func testMediaShowVLMSkipsUncachedWhenLocalModelIsUnavailable() async throws {
        let provider = StubMediaProvider(
            cachedVLMByPath: [
                "/图库/cached.png": "一张夜间街景照片。"
            ],
            liveVLMByPath: [
                "/图库/live.png": "不应该被调用"
            ],
            vlmLiveAvailable: false
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media show --vlm /图库/cached.png /图库/live.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.liveVLMRequestPaths, [])
        XCTAssertTrue(result.stdout.contains("/图库/cached.png:\n一张夜间街景照片。"))
        XCTAssertTrue(result.stdout.contains("VLM limit: requested 2, returned 1, cached 1, processed 0, skipped 1."))
        XCTAssertTrue(result.stdout.contains("Live VLM unavailable: local FastVLM model is not installed."))
    }

    func testFastVLMModelBundleDiscoveryUsesOfficialConfigFingerprint() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterFastVLM-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let missingDirectory = PhotoSorterFastVLMModelBundle.discover(directoryURL: directoryURL)
        XCTAssertFalse(missingDirectory.isInstalled)
        XCTAssertEqual(
            missingDirectory.processorConfigFingerprint,
            PhotoSorterMediaVLMConfiguration.processorConfigFingerprintNotInstalled
        )

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"model_type":"llava_qwen2"}"#.utf8)
            .write(to: directoryURL.appendingPathComponent("config.json"))

        let incompleteBundle = PhotoSorterFastVLMModelBundle.discover(directoryURL: directoryURL)
        XCTAssertFalse(incompleteBundle.isInstalled)
        XCTAssertEqual(
            incompleteBundle.missingRequiredConfigFileNames,
            [
                "preprocessor_config.json",
                "processor_config.json",
                "tokenizer_config.json"
            ]
        )

        try Data(#"{"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],"size":{"shortest_edge":512},"crop_size":{"width":512,"height":512}}"#.utf8)
            .write(to: directoryURL.appendingPathComponent("preprocessor_config.json"))
        try Data(#"{"image_token":"<image>","patch_size":64,"processor_class":"LlavaProcessor"}"#.utf8)
            .write(to: directoryURL.appendingPathComponent("processor_config.json"))
        try Data(#"{"added_tokens_decoder":{}}"#.utf8)
            .write(to: directoryURL.appendingPathComponent("tokenizer_config.json"))

        let configOnlyBundle = PhotoSorterFastVLMModelBundle.discover(directoryURL: directoryURL)
        XCTAssertFalse(configOnlyBundle.isInstalled)
        XCTAssertEqual(configOnlyBundle.missingRequiredConfigFileNames, [])
        XCTAssertEqual(configOnlyBundle.modelComponentIssues, [
            "missing *.safetensors",
            "missing exactly one *.mlpackage"
        ])

        try Data("weights".utf8)
            .write(to: directoryURL.appendingPathComponent("model-00001-of-00001.safetensors"))
        try FileManager.default.createDirectory(
            at: directoryURL.appendingPathComponent("fastvithd.mlpackage", isDirectory: true),
            withIntermediateDirectories: true
        )

        let installedBundle = PhotoSorterFastVLMModelBundle.discover(directoryURL: directoryURL)
        XCTAssertTrue(installedBundle.isInstalled)
        XCTAssertTrue(installedBundle.processorConfigFingerprint.hasPrefix("fastvlm-official-config-fnv1a64-"))

        let providerStatus = PhotoSorterMediaVLMConfiguration.bundledFastVLMProviderStatus(
            modelBundle: installedBundle
        )
        XCTAssertEqual(providerStatus.modelState, .installed)
        XCTAssertFalse(providerStatus.isLiveSummarizationAvailable)
        XCTAssertEqual(providerStatus.processorConfigFingerprint, installedBundle.processorConfigFingerprint)

        try Data(#"{"image_mean":[0.4,0.5,0.6],"image_std":[0.5,0.5,0.5],"size":{"shortest_edge":512},"crop_size":{"width":512,"height":512}}"#.utf8)
            .write(to: directoryURL.appendingPathComponent("preprocessor_config.json"))
        let changedBundle = PhotoSorterFastVLMModelBundle.discover(directoryURL: directoryURL)
        XCTAssertNotEqual(
            changedBundle.processorConfigFingerprint,
            installedBundle.processorConfigFingerprint
        )
    }

    func testMediaSearchVLMKeywordAndRegexSearchCachedSummariesOnly() async throws {
        let provider = StubMediaProvider(
            cachedVLMByPath: [
                "/图库/pay.png": "一张手机支付页面截图，画面中有付款成功提示。",
                "/图库/street.png": "一张夜间街景照片，画面中有路灯和车辆。",
                "/图库/order.png": "一张订单详情截图，画面中有商品金额。"
            ],
            liveVLMByPath: [
                "/图库/live.png": "一张支付截图。"
            ],
            vlmLiveAvailable: true
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let keywordResult = await shell.run("media search --vlm 支付 /图库/pay.png /图库/street.png /图库/order.png /图库/live.png")
        let regexResult = await shell.run("media search --vlm --regex '支付|订单' /图库/pay.png /图库/street.png /图库/order.png /图库/live.png")

        XCTAssertEqual(keywordResult.exitCode, 0)
        XCTAssertEqual(keywordResult.stderr, "")
        XCTAssertTrue(keywordResult.stdout.contains("VLM search: requested 4, cached 3, matched 1, uncached 1, unavailable 0."))
        XCTAssertTrue(keywordResult.stdout.contains("Keyword: 支付"))
        XCTAssertTrue(keywordResult.stdout.contains("/图库/pay.png:"))
        XCTAssertFalse(keywordResult.stdout.contains("/图库/order.png:"))

        XCTAssertEqual(regexResult.exitCode, 0)
        XCTAssertEqual(regexResult.stderr, "")
        XCTAssertTrue(regexResult.stdout.contains("VLM search: requested 4, cached 3, matched 2, uncached 1, unavailable 0."))
        XCTAssertTrue(regexResult.stdout.contains("Regex: 支付|订单"))
        XCTAssertTrue(regexResult.stdout.contains("/图库/pay.png:"))
        XCTAssertTrue(regexResult.stdout.contains("/图库/order.png:"))
        XCTAssertEqual(provider.liveVLMRequestPaths, [])
    }

    func testMediaViewRequiresFullAccessMode() async throws {
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": Self.sampleImage(path: "/图库/a.png")
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view /图库/a.png")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "media view: image reads require full Photos access mode\n")
        XCTAssertTrue(result.modelContentItems.isEmpty)
        XCTAssertEqual(provider.modelImageRequestPaths, [])
    }

    func testMediaViewReportsMissingAssetsWithoutAuthorizationPrompt() async throws {
        let provider = StubMediaProvider()
        let authorizer = StubMediaViewAuthorizer(allowedPaths: ["/图库/missing.png"])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media view /图库/missing.png")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(authorizer.requests, [])
        XCTAssertEqual(
            result.stdout,
            """
            Failed (1):
            - /图库/missing.png: media asset not found

            """
        )
    }

    func testMediaViewRequiresAuthorizationUIInAskMode() async throws {
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": Self.sampleImage(path: "/图库/a.png")
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full)
            ))

        let result = await shell.run("media view /图库/a.png")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "media view: sensitive read approval UI is unavailable\n")
        XCTAssertTrue(result.modelContentItems.isEmpty)
        XCTAssertEqual(provider.modelImageRequestPaths, [])
    }

    func testMediaViewReturnsModelImageAsModelContent() async throws {
        let image = Self.sampleImage(path: "/图库/a.png")
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": image
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view /图库/a.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            """
            Sent 1 image(s) to model:
            - /图库/a.png

            """
        )
        XCTAssertEqual(provider.modelImageRequestPaths, ["/图库/a.png"])
        XCTAssertEqual(
            provider.modelImageMaxPixelDimensions,
            [PhotoSorterModelImageSizing.preferredMaximumPixelDimension]
        )
        XCTAssertEqual(result.modelContentItems, [
            .inputImage(data: image.data, mimeType: "image/png", detail: "high")
        ])
    }

    func testMediaViewAlwaysAllowProcessesOnlyFirstTwentyImages() async throws {
        let paths = (1...25).map { "/图库/\($0).png" }
        var imagesByPath: [String: PhotoSorterOriginalImage] = [:]
        for path in paths {
            imagesByPath[path] = Self.sampleImage(path: path)
        }
        let provider = StubMediaProvider(modelImagesByPath: imagesByPath)
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view " + paths.joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.modelImageRequestPaths.count, 20)
        XCTAssertEqual(Set(provider.modelImageRequestPaths), Set(paths.prefix(20)))
        XCTAssertEqual(result.modelContentItems.count, 20)
        XCTAssertTrue(result.stdout.contains("Sent 20 image(s) to model:"))
        XCTAssertTrue(result.stdout.contains("Skipped by media view limit (5):"))
        XCTAssertTrue(result.stdout.contains("- /图库/21.png"))
        XCTAssertTrue(result.stdout.contains("Re-run `media view` with the remaining paths."))
    }

    func testMediaViewDownscalesImagesWhileKeepingShortSideReadable() async throws {
        let sourceData = try XCTUnwrap(Self.pngImageData(width: 3000, height: 1500))
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/large.png": PhotoSorterOriginalImage(
                path: "/图库/large.png",
                fileName: "large.png",
                mimeType: "image/png",
                pixelWidth: 3000,
                pixelHeight: 1500,
                data: sourceData
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view /图库/large.png")
        let item = try XCTUnwrap(result.modelContentItems.first)
        let outputData = try XCTUnwrap(item.data)
        let dimensions = try XCTUnwrap(Self.imageDimensions(from: outputData))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(item.mimeType, "image/png")
        XCTAssertEqual(item.detail, "high")
        XCTAssertGreaterThanOrEqual(
            min(dimensions.width, dimensions.height),
            PhotoSorterModelImageSizing.minimumShortPixelDimension
        )
        XCTAssertEqual(dimensions.width, 2160)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testMediaViewDoesNotDownscaleWhenSourceShortSideIsBelowMinimum() async throws {
        let sourceData = try XCTUnwrap(Self.pngImageData(width: 2000, height: 1000))
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/medium.png": PhotoSorterOriginalImage(
                path: "/图库/medium.png",
                fileName: "medium.png",
                mimeType: "image/png",
                pixelWidth: 2000,
                pixelHeight: 1000,
                data: sourceData
            )
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view /图库/medium.png")
        let item = try XCTUnwrap(result.modelContentItems.first)
        let outputData = try XCTUnwrap(item.data)
        let dimensions = try XCTUnwrap(Self.imageDimensions(from: outputData))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(dimensions.width, 2000)
        XCTAssertEqual(dimensions.height, 1000)
    }

    func testMediaViewReportsUnavailableImageAndContinuesWithAvailableImages() async throws {
        let image = Self.sampleImage(path: "/图库/local.png")
        let provider = StubMediaProvider(
            modelImagesByPath: [
                "/图库/local.png": image
            ],
            modelImageErrorsByPath: [
                "/图库/icloud.png": PhotoSorterMediaImageError.unavailable(
                    "local image preview is unavailable; image may need iCloud download"
                )
            ]
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view /图库/icloud.png /图库/local.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.modelImageRequestPaths.count, 2)
        XCTAssertEqual(Set(provider.modelImageRequestPaths), Set(["/图库/icloud.png", "/图库/local.png"]))
        XCTAssertEqual(result.modelContentItems, [
            .inputImage(data: image.data, mimeType: "image/png", detail: "high")
        ])
        XCTAssertTrue(result.stdout.contains("Sent 1 image(s) to model:"))
        XCTAssertTrue(result.stdout.contains("- /图库/local.png"))
        XCTAssertTrue(result.stdout.contains("Failed (1):"))
        XCTAssertTrue(result.stdout.contains("- /图库/icloud.png: local image preview is unavailable; image may need iCloud download"))
    }

    func testMediaViewIgnoresReviewProviderAndKeepsModelImagesOnly() async throws {
        let videoPath = "/图库/clip.mov"
        let provider = StubMediaProvider()
        let reviewProvider = StubMediaReviewProvider(itemsByPath: [
            videoPath: PhotoSorterMediaViewItem(preview: PhotoSorterMediaPreview(
                path: videoPath,
                fileName: "clip.mov",
                kind: .video,
                pixelWidth: 1920,
                pixelHeight: 1080,
                thumbnailData: Data([0x01]),
                photoLibraryLocalIdentifier: "video-local-id",
                fileURL: nil
            ))
        ])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                reviewProvider: reviewProvider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                sensitiveReadPolicyProvider: PhotoSorterSensitiveReadPolicyState(.alwaysAllow)
            ))

        let result = await shell.run("media view \(videoPath)")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(provider.modelImageRequestPaths, [videoPath])
        XCTAssertEqual(reviewProvider.reviewRequestPaths, [])
        XCTAssertEqual(
            result.stdout,
            """
            Failed (1):
            - \(videoPath): media asset not found

            """
        )
    }

    func testMediaViewAskModeReturnsOnlyUserSelectedImages() async throws {
        let paths = ["/图库/a.png", "/图库/b.png", "/图库/c.png"]
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": Self.sampleImage(path: "/图库/a.png", byte: 0xA1),
            "/图库/b.png": Self.sampleImage(path: "/图库/b.png", byte: 0xB1),
            "/图库/c.png": Self.sampleImage(path: "/图库/c.png", byte: 0xC1)
        ])
        let authorizer = StubMediaViewAuthorizer(allowedPaths: ["/图库/a.png", "/图库/c.png"])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media view " + paths.joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(provider.modelImageRequestPaths.count, paths.count)
        XCTAssertEqual(Set(provider.modelImageRequestPaths), Set(paths))
        XCTAssertEqual(authorizer.requests.map { $0.items.map(\.path) }, [paths])
        XCTAssertEqual(result.modelContentItems, [
            .inputImage(data: Data([0xA1]), mimeType: "image/png", detail: "high"),
            .inputImage(data: Data([0xC1]), mimeType: "image/png", detail: "high")
        ])
        XCTAssertTrue(result.stdout.contains("Sent 2 image(s) to model:"))
        XCTAssertTrue(result.stdout.contains("- /图库/a.png"))
        XCTAssertTrue(result.stdout.contains("- /图库/c.png"))
        XCTAssertTrue(result.stdout.contains("Denied by user (1):"))
        XCTAssertTrue(result.stdout.contains("- /图库/b.png"))
    }

    func testMediaViewAskModeCanDenyAllImagesWithoutToolFailure() async throws {
        let provider = StubMediaProvider(modelImagesByPath: [
            "/图库/a.png": Self.sampleImage(path: "/图库/a.png")
        ])
        let authorizer = StubMediaViewAuthorizer(allowedPaths: [])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media view /图库/a.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(
            result.stdout,
            """
            Denied by user (1):
            - /图库/a.png

            """
        )
    }

    func testMediaAskReturnsUserSelectionNoteAndMetadataWithoutModelImages() async throws {
        let createdA = Date(timeIntervalSince1970: 1_782_650_590)
        let createdB = Date(timeIntervalSince1970: 1_782_736_400)
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/a.png": PhotoSorterMediaMetadata(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: createdA
                ),
                "/图库/b.png": PhotoSorterMediaMetadata(
                    path: "/图库/b.png",
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    creationDate: createdB
                )
            ],
            cachedOCRByPath: [
                "/图库/a.png": "支付成功"
            ],
            cachedVLMByPath: [
                "/图库/b.png": "一张游戏截图"
            ],
            modelImagesByPath: [
                "/图库/a.png": Self.sampleImage(path: "/图库/a.png", byte: 0xA1),
                "/图库/b.png": Self.sampleImage(path: "/图库/b.png", byte: 0xB1)
            ]
        )
        let authorizer = StubMediaViewAuthorizer(
            allowedPaths: ["/图库/a.png"],
            note: "学习资料不要删，游戏截图可以继续筛。"
        )
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let message = "我筛出了一批疑似游戏截图。请取消勾选想保留的图片。"
        let result = await shell.run("media ask --message \"\(message)\" /图库/a.png /图库/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(Set(provider.modelImageRequestPaths), Set(["/图库/a.png", "/图库/b.png"]))
        XCTAssertEqual(provider.metadataBatchRequestPaths, [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(provider.cachedOCRBatchRequestPaths, [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(provider.cachedVLMBatchRequestPaths, [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(provider.recordedMediaAskExclusionPathBatches, [["/图库/b.png"]])
        XCTAssertEqual(provider.mediaAskExcludedCountByPath["/图库/a.png"], nil)
        XCTAssertEqual(provider.mediaAskExcludedCountByPath["/图库/b.png"], 1)
        XCTAssertEqual(authorizer.requests.map(\.purpose), [.askUser])
        XCTAssertEqual(authorizer.requests.first?.message, message)
        XCTAssertEqual(authorizer.requests.map(\.items), [[]])
        XCTAssertEqual(authorizer.requests.map(\.pendingPaths), [["/图库/a.png", "/图库/b.png"]])
        XCTAssertEqual(
            result.stdout,
            """
            media ask: confirmed
            requested 2
            shown 2
            user note:
            学习资料不要删，游戏截图可以继续筛。

            selected 1
            /图库/a.png
              date: \(PhotoSorterMediaCommand.createdText(for: createdA))
              dimensions: 1179x2556
              OCR: true
              VLM: false

            excluded 1
            /图库/b.png
              date: \(PhotoSorterMediaCommand.createdText(for: createdB))
              dimensions: 1284x2778
              OCR: false
              VLM: true

            """
        )
    }

    func testMediaAskCanWriteSelectedExcludedAndSkippedPathLists() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/a.png": PhotoSorterMediaMetadata(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                ),
                "/图库/b.png": PhotoSorterMediaMetadata(
                    path: "/图库/b.png",
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    creationDate: nil
                )
            ],
            modelImagesByPath: [
                "/图库/a.png": Self.sampleImage(path: "/图库/a.png"),
                "/图库/b.png": Self.sampleImage(path: "/图库/b.png")
            ]
        )
        let authorizer = StubMediaViewAuthorizer(allowedPaths: ["/图库/a.png"])
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run([
            "media ask --message \"请确认这批候选。\" /图库/a.png /图库/b.png /图库/c.png",
            "--write-selected /tmp/media-ask/selected.txt",
            "--write-excluded /tmp/media-ask/excluded.txt",
            "--write-skipped /tmp/media-ask/skipped.txt"
        ].joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("media ask: confirmed"))
        XCTAssertTrue(result.stdout.contains("selected 1"))
        XCTAssertTrue(result.stdout.contains("excluded 1"))
        XCTAssertTrue(result.stdout.contains("skipped 1"))
        XCTAssertTrue(result.stdout.contains("""
        written path lists
        selected 1 -> /tmp/media-ask/selected.txt
        excluded 1 -> /tmp/media-ask/excluded.txt
        skipped 1 -> /tmp/media-ask/skipped.txt
        """))
        XCTAssertEqual(provider.recordedMediaAskExclusionPathBatches, [["/图库/b.png"]])
        XCTAssertEqual(
            try String(
                contentsOf: workspace.tmpURL.appendingPathComponent("media-ask/selected.txt"),
                encoding: .utf8
            ),
            "/图库/a.png\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: workspace.tmpURL.appendingPathComponent("media-ask/excluded.txt"),
                encoding: .utf8
            ),
            "/图库/b.png\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: workspace.tmpURL.appendingPathComponent("media-ask/skipped.txt"),
                encoding: .utf8
            ),
            "/图库/c.png\n"
        )
    }

    func testMediaAskReviewsVideosAndLivePhotosWithoutModelImages() async throws {
        let videoPath = "/图库/clip.mov"
        let livePhotoPath = "/图库/live.heic"
        let createdVideo = Date(timeIntervalSince1970: 1_782_820_800)
        let createdLivePhoto = Date(timeIntervalSince1970: 1_782_907_200)
        let provider = StubMediaProvider(
            metadataByPath: [
                videoPath: PhotoSorterMediaMetadata(
                    path: videoPath,
                    pixelWidth: 1920,
                    pixelHeight: 1080,
                    creationDate: createdVideo,
                    mediaType: .video
                ),
                livePhotoPath: PhotoSorterMediaMetadata(
                    path: livePhotoPath,
                    pixelWidth: 3024,
                    pixelHeight: 4032,
                    creationDate: createdLivePhoto,
                    mediaType: .image
                )
            ],
            cachedOCRByPath: [
                livePhotoPath: "票据"
            ],
            cachedVLMByPath: [
                videoPath: "一段旅行视频"
            ],
            modelImagesByPath: [
                "/图库/unused.png": Self.sampleImage(path: "/图库/unused.png")
            ]
        )
        let reviewProvider = StubMediaReviewProvider(itemsByPath: [
            videoPath: PhotoSorterMediaViewItem(preview: PhotoSorterMediaPreview(
                path: videoPath,
                fileName: "clip.mov",
                kind: .video,
                pixelWidth: 1920,
                pixelHeight: 1080,
                thumbnailData: Data([0x01]),
                photoLibraryLocalIdentifier: "video-local-id",
                fileURL: nil
            )),
            livePhotoPath: PhotoSorterMediaViewItem(preview: PhotoSorterMediaPreview(
                path: livePhotoPath,
                fileName: "live.heic",
                kind: .livePhoto,
                pixelWidth: 3024,
                pixelHeight: 4032,
                thumbnailData: Data([0x02]),
                photoLibraryLocalIdentifier: "live-photo-local-id",
                fileURL: nil
            ))
        ])
        let authorizer = StubMediaViewAuthorizer(allowedPaths: [videoPath])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                reviewProvider: reviewProvider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media ask --message \"请确认这些媒体。\" \(videoPath) \(livePhotoPath)")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(provider.modelImageRequestPaths, [])
        XCTAssertEqual(reviewProvider.reviewRequestPaths, [videoPath, livePhotoPath])
        XCTAssertEqual(
            reviewProvider.reviewRequestMaxPixelDimensions,
            [
                PhotoSorterModelImageSizing.preferredMaximumPixelDimension,
                PhotoSorterModelImageSizing.preferredMaximumPixelDimension
            ]
        )
        XCTAssertEqual(authorizer.requests.map(\.purpose), [.askUser])
        XCTAssertEqual(authorizer.requests.first?.pendingPaths, [videoPath, livePhotoPath])
        XCTAssertTrue(result.stdout.contains("media ask: confirmed"))
        XCTAssertTrue(result.stdout.contains("selected 1\n\(videoPath)"))
        XCTAssertTrue(result.stdout.contains("  date: \(PhotoSorterMediaCommand.createdText(for: createdVideo))"))
        XCTAssertTrue(result.stdout.contains("  dimensions: 1920x1080"))
        XCTAssertTrue(result.stdout.contains("  OCR: false"))
        XCTAssertTrue(result.stdout.contains("  VLM: true"))
        XCTAssertTrue(result.stdout.contains("excluded 1\n\(livePhotoPath)"))
        XCTAssertEqual(provider.recordedMediaAskExclusionPathBatches, [[livePhotoPath]])
        XCTAssertEqual(provider.mediaAskExcludedCountByPath[livePhotoPath], 1)
        XCTAssertTrue(result.stdout.contains("  date: \(PhotoSorterMediaCommand.createdText(for: createdLivePhoto))"))
        XCTAssertTrue(result.stdout.contains("  dimensions: 3024x4032"))
        XCTAssertTrue(result.stdout.contains("  OCR: true"))
        XCTAssertTrue(result.stdout.contains("  VLM: false"))
    }

    func testMediaAskFromJSONLShowsReasonsAndReturnsReasonMetadata() async throws {
        let workspace = try makeTemporaryShellWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        try """
        {"path":"/图库/a.png","title":"物流临时截图","confidence":"把握中等","basis":["OCR","截图相册","VLM"],"matched_terms":["取件码","已签收"],"risk":"可能是售后/订单凭证","detail":"OCR 片段：您的包裹已签收..."}
        {"path":"/图库/b.png","title":"广告活动页","confidence":"把握较高","basis":["OCR"],"matchedTerms":["限时活动"],"risk":"通常可清理"}
        """.write(
            to: workspace.tmpURL.appendingPathComponent("ask_candidates.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/a.png": PhotoSorterMediaMetadata(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: Date(timeIntervalSince1970: 1)
                ),
                "/图库/b.png": PhotoSorterMediaMetadata(
                    path: "/图库/b.png",
                    pixelWidth: 1284,
                    pixelHeight: 2778,
                    creationDate: Date(timeIntervalSince1970: 2)
                )
            ],
            cachedOCRByPath: [
                "/图库/a.png": "取件码 已签收",
                "/图库/b.png": "限时活动"
            ],
            cachedVLMByPath: [
                "/图库/a.png": "一张物流取件码截图"
            ],
            modelImagesByPath: [
                "/图库/a.png": Self.sampleImage(path: "/图库/a.png"),
                "/图库/b.png": Self.sampleImage(path: "/图库/b.png")
            ]
        )
        let authorizer = StubMediaViewAuthorizer(allowedPaths: ["/图库/a.png"])
        let shell = try ModelShellProxy.iOS(workspaceURL: workspace.rootURL)
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media ask --message \"请确认这批候选。\" --from-jsonl /tmp/ask_candidates.jsonl --limit 2")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(authorizer.requests.first?.pendingPaths, ["/图库/a.png", "/图库/b.png"])
        XCTAssertEqual(authorizer.requests.first?.reasonsByPath["/图库/a.png"]?.title, "物流临时截图")
        XCTAssertEqual(authorizer.requests.first?.reasonsByPath["/图库/a.png"]?.confidence, "把握中等")
        XCTAssertEqual(authorizer.requests.first?.reasonsByPath["/图库/a.png"]?.basis, ["OCR", "截图相册", "VLM"])
        XCTAssertEqual(authorizer.requests.first?.reasonsByPath["/图库/a.png"]?.matchedTerms, ["取件码", "已签收"])
        XCTAssertTrue(result.stdout.contains("selected 1\n/图库/a.png"))
        XCTAssertTrue(result.stdout.contains("  title: 物流临时截图"))
        XCTAssertTrue(result.stdout.contains("  confidence: 把握中等"))
        XCTAssertTrue(result.stdout.contains("  basis: OCR, 截图相册, VLM"))
        XCTAssertTrue(result.stdout.contains("  matched_terms: 取件码, 已签收"))
        XCTAssertTrue(result.stdout.contains("  risk: 可能是售后/订单凭证"))
        XCTAssertTrue(result.stdout.contains("excluded 1\n/图库/b.png"))
        XCTAssertTrue(result.stdout.contains("  title: 广告活动页"))
        XCTAssertTrue(result.stdout.contains("  matched_terms: 限时活动"))
    }

    func testMediaAskPreviewsOnlyFirstTwoHundredImages() async throws {
        let paths = (1...205).map { "/图库/\($0).png" }
        var imagesByPath: [String: PhotoSorterOriginalImage] = [:]
        for path in paths {
            imagesByPath[path] = Self.sampleImage(path: path)
        }
        let provider = StubMediaProvider(modelImagesByPath: imagesByPath)
        let authorizer = StubMediaViewAuthorizer(allowedPaths: Set(paths.prefix(200)))
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media ask " + paths.joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(provider.modelImageRequestPaths.count, 200)
        XCTAssertEqual(Set(provider.modelImageRequestPaths), Set(paths.prefix(200)))
        XCTAssertEqual(authorizer.requests.map(\.purpose), [.askUser])
        XCTAssertEqual(authorizer.requests.first?.items.count, 0)
        XCTAssertEqual(authorizer.requests.first?.pendingPaths.count, 200)
        XCTAssertEqual(authorizer.requests.first?.limitSkippedPaths, Array(paths.dropFirst(200)))
        XCTAssertTrue(result.stdout.contains("media ask: confirmed"))
        XCTAssertTrue(result.stdout.contains("requested 205"))
        XCTAssertTrue(result.stdout.contains("shown 200"))
        XCTAssertTrue(result.stdout.contains("selected 200"))
        XCTAssertTrue(result.stdout.contains("excluded 0"))
        XCTAssertTrue(result.stdout.contains("skipped by media ask limit 5"))
        XCTAssertTrue(result.stdout.contains("/图库/201.png"))
    }

    func testMediaAskSkipsTimedOutPreviewAndStillPromptsWithLoadedImages() async throws {
        let provider = StubMediaProvider(
            modelImagesByPath: [
                "/图库/a.png": Self.sampleImage(path: "/图库/a.png")
            ],
            modelImageNeverReturnPaths: ["/图库/b.png"]
        )
        let authorizer = StubMediaViewAuthorizer(allowedPaths: ["/图库/a.png"])
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer,
                mediaPreviewLoadTimeoutNanoseconds: 50_000_000
            ))

        let result = await shell.run("media ask /图库/a.png /图库/b.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(Set(provider.modelImageRequestPaths), Set(["/图库/a.png", "/图库/b.png"]))
        XCTAssertEqual(authorizer.requests.map(\.purpose), [.askUser])
        XCTAssertEqual(authorizer.requests.first?.items.map(\.path), [])
        XCTAssertEqual(authorizer.requests.first?.pendingPaths, ["/图库/a.png", "/图库/b.png"])
        XCTAssertTrue(result.stdout.contains("media ask: confirmed"))
        XCTAssertTrue(result.stdout.contains("requested 2"))
        XCTAssertTrue(result.stdout.contains("shown 1"))
        XCTAssertTrue(result.stdout.contains("selected 1"))
        XCTAssertTrue(result.stdout.contains("excluded 0"))
        XCTAssertEqual(provider.recordedMediaAskExclusionPathBatches, [])
        XCTAssertEqual(provider.mediaAskExcludedCountByPath, [:])
        XCTAssertTrue(result.stdout.contains("skipped 1"))
        XCTAssertTrue(result.stdout.contains("/图库/b.png: preview timed out"))
    }

    func testMediaAskDoesNotSelectUnreviewedImagesWhenUserConfirmsEarly() async throws {
        let paths = ["/图库/a.png", "/图库/b.png", "/图库/c.png"]
        let provider = StubMediaProvider(
            modelImagesByPath: [
                "/图库/a.png": Self.sampleImage(path: "/图库/a.png"),
                "/图库/b.png": Self.sampleImage(path: "/图库/b.png"),
                "/图库/c.png": Self.sampleImage(path: "/图库/c.png")
            ]
        )
        let authorizer = StubEarlyConfirmMediaAskAuthorizer(loadedCountBeforeConfirm: 1)
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media ask " + paths.joined(separator: " "))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertEqual(provider.modelImageRequestPaths, ["/图库/a.png"])
        XCTAssertEqual(authorizer.requests.first?.pendingPaths, paths)
        XCTAssertTrue(result.stdout.contains("media ask: confirmed"))
        XCTAssertTrue(result.stdout.contains("shown 1"))
        XCTAssertTrue(result.stdout.contains("selected 1"))
        XCTAssertTrue(result.stdout.contains("excluded 0"))
        XCTAssertEqual(provider.recordedMediaAskExclusionPathBatches, [])
        XCTAssertEqual(provider.mediaAskExcludedCountByPath, [:])
        XCTAssertTrue(result.stdout.contains("skipped 2"))
        XCTAssertTrue(result.stdout.contains("/图库/b.png: not reviewed because user confirmed before preview loaded"))
        XCTAssertTrue(result.stdout.contains("/图库/c.png: not reviewed because user confirmed before preview loaded"))
    }

    func testMediaAskCanReturnCancelledWithoutSendingModelImages() async throws {
        let provider = StubMediaProvider(
            metadataByPath: [
                "/图库/a.png": PhotoSorterMediaMetadata(
                    path: "/图库/a.png",
                    pixelWidth: 1179,
                    pixelHeight: 2556,
                    creationDate: nil
                )
            ],
            modelImagesByPath: [
                "/图库/a.png": Self.sampleImage(path: "/图库/a.png")
            ]
        )
        let authorizer = StubMediaViewAuthorizer(allowedPaths: [], cancelled: true)
        let shell = try ModelShellProxy()
            .enable(PhotoSorterCommandPack(
                mediaProvider: provider,
                agentAccessModeProvider: PhotoSorterAgentAccessModeState(.full),
                mediaViewAuthorizer: authorizer
            ))

        let result = await shell.run("media ask /图库/a.png")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.modelContentItems, [])
        XCTAssertTrue(result.stdout.contains("media ask: cancelled"))
        XCTAssertTrue(result.stdout.contains("selected 0"))
        XCTAssertTrue(result.stdout.contains("excluded 1"))
        XCTAssertTrue(result.stdout.contains("/图库/a.png"))
        XCTAssertEqual(provider.recordedMediaAskExclusionPathBatches, [])
        XCTAssertEqual(provider.mediaAskExcludedCountByPath, [:])
    }

    private func makeTemporaryShellWorkspace() throws -> (rootURL: URL, tmpURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterMediaCommand-\(UUID().uuidString)", isDirectory: true)
        let tmpURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        return (rootURL, tmpURL)
    }

    private static func sampleImage(path: String, byte: UInt8 = 0x00) -> PhotoSorterOriginalImage {
        PhotoSorterOriginalImage(
            path: path,
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            mimeType: "image/png",
            pixelWidth: 1179,
            pixelHeight: 2556,
            data: Data([byte])
        )
    }

    private static func jsonLines(_ text: String) throws -> [[String: Any]] {
        try text
            .split(whereSeparator: \.isNewline)
            .map { line in
                let data = Data(String(line).utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "PhotoSorterMediaCommandTests", code: 1)
                }
                return object
            }
    }

    private static func pngImageData(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }

}

private final class StubMediaViewAuthorizer: PhotoSorterMediaViewAuthorizing, @unchecked Sendable {
    private let allowedPaths: Set<String>
    private let note: String
    private let cancelled: Bool
    private let lock = NSLock()
    private var capturedRequests: [PhotoSorterMediaViewAuthorizationRequest] = []

    init(allowedPaths: Set<String>, note: String = "", cancelled: Bool = false) {
        self.allowedPaths = allowedPaths
        self.note = note
        self.cancelled = cancelled
    }

    var requests: [PhotoSorterMediaViewAuthorizationRequest] {
        lock.withLock {
            capturedRequests
        }
    }

    @MainActor
    func authorizeMediaView(
        _ request: PhotoSorterMediaViewAuthorizationRequest
    ) async -> PhotoSorterMediaViewAuthorizationDecision {
        lock.withLock {
            capturedRequests.append(request)
        }
        let loadedResults: [PhotoSorterMediaViewLoadResult]
        if !request.pendingPaths.isEmpty, let itemLoader = request.itemLoader {
            var results: [PhotoSorterMediaViewLoadResult] = []
            for (index, path) in request.pendingPaths.enumerated() {
                results.append(await itemLoader.load(index: index, path: path))
            }
            loadedResults = results
        } else if !request.pendingPaths.isEmpty {
            loadedResults = request.pendingPaths.enumerated().map { index, path in
                PhotoSorterMediaViewLoadResult(
                    index: index,
                    item: nil,
                    failure: PhotoSorterMediaViewFailure(path: path, message: "preview loader unavailable")
                )
            }
        } else {
            loadedResults = request.items.enumerated().map { index, item in
                PhotoSorterMediaViewLoadResult(index: index, item: item, failure: nil)
            }
        }
        let reviewedItems = loadedResults.compactMap(\.item)
        let skippedFailures = loadedResults.compactMap(\.failure)
        return PhotoSorterMediaViewAuthorizationDecision(
            allowedItemIDs: cancelled ? [] : Set(reviewedItems.filter { allowedPaths.contains($0.path) }.map(\.id)),
            note: note,
            cancelled: cancelled,
            reviewedItems: reviewedItems,
            skippedFailures: skippedFailures
        )
    }
}

private final class StubEarlyConfirmMediaAskAuthorizer: PhotoSorterMediaViewAuthorizing, @unchecked Sendable {
    private let loadedCountBeforeConfirm: Int
    private let lock = NSLock()
    private var capturedRequests: [PhotoSorterMediaViewAuthorizationRequest] = []

    init(loadedCountBeforeConfirm: Int) {
        self.loadedCountBeforeConfirm = max(0, loadedCountBeforeConfirm)
    }

    var requests: [PhotoSorterMediaViewAuthorizationRequest] {
        lock.withLock {
            capturedRequests
        }
    }

    @MainActor
    func authorizeMediaView(
        _ request: PhotoSorterMediaViewAuthorizationRequest
    ) async -> PhotoSorterMediaViewAuthorizationDecision {
        lock.withLock {
            capturedRequests.append(request)
        }
        let pendingPaths = request.pendingPaths
        let loadCount = min(loadedCountBeforeConfirm, pendingPaths.count)
        var loadedResults: [PhotoSorterMediaViewLoadResult] = []
        if let itemLoader = request.itemLoader {
            for index in pendingPaths.indices.prefix(loadCount) {
                loadedResults.append(await itemLoader.load(index: index, path: pendingPaths[index]))
            }
        }
        let reviewedItems = loadedResults.compactMap(\.item)
        let loadedFailures = loadedResults.compactMap(\.failure)
        let notReviewedFailures = pendingPaths.indices.dropFirst(loadCount).map { index in
            PhotoSorterMediaViewFailure(
                path: pendingPaths[index],
                message: "not reviewed because user confirmed before preview loaded"
            )
        }
        return PhotoSorterMediaViewAuthorizationDecision(
            allowedItemIDs: Set(reviewedItems.map(\.id)),
            reviewedItems: reviewedItems,
            skippedFailures: loadedFailures + notReviewedFailures
        )
    }
}

private final class StubMediaReviewProvider: PhotoSorterMediaReviewProviding, @unchecked Sendable {
    private let itemsByPath: [String: PhotoSorterMediaViewItem]
    private let neverReturnPaths: Set<String>
    private let lock = NSLock()
    private var requestedReviewPaths: [String] = []
    private var requestedMaxPixelDimensions: [Int] = []

    init(
        itemsByPath: [String: PhotoSorterMediaViewItem],
        neverReturnPaths: Set<String> = []
    ) {
        self.itemsByPath = itemsByPath
        self.neverReturnPaths = neverReturnPaths
    }

    var reviewRequestPaths: [String] {
        lock.withLock {
            requestedReviewPaths
        }
    }

    var reviewRequestMaxPixelDimensions: [Int] {
        lock.withLock {
            requestedMaxPixelDimensions
        }
    }

    func photoSorterReviewMedia(
        for virtualPath: String,
        maxPixelDimension: Int
    ) async throws -> PhotoSorterMediaViewItem? {
        lock.withLock {
            requestedReviewPaths.append(virtualPath)
            requestedMaxPixelDimensions.append(maxPixelDimension)
        }
        while neverReturnPaths.contains(virtualPath), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return itemsByPath[virtualPath]
    }
}

private struct StubAlbumAddRequest: Equatable {
    var assetPaths: [String]
    var albumPath: String
    var createAlbumIfNeeded: Bool
}

private struct StubAlbumRemoveRequest: Equatable {
    var assetPaths: [String]
    var albumPath: String
}

private struct StubMediaListRequest: Equatable {
    var scopePath: String
    var offset: Int
    var limit: Int
    var sort: PhotoSorterMediaListSort
    var order: PhotoSorterMediaListOrder
    var mediaType: PhotoSorterMediaType
}

private struct StubMediaStatsRequest: Equatable {
    var scopePath: String
    var groupBy: PhotoSorterMediaStatsGroup
    var dateField: PhotoSorterMediaStatsDateField
    var mediaType: PhotoSorterMediaType
}

private struct StubFileTreeSnapshotRequest: Equatable {
    var rootPath: String
    var maxUserAlbums: Int
}

private final class StubMediaProvider: PhotoSorterMediaMetadataProviding, PhotoSorterMediaListing, PhotoSorterMediaStatsProviding, PhotoSorterMediaOCRProviding, PhotoSorterVLMProviding, PhotoSorterMediaImageProviding, PhotoSorterMediaAskExclusionTracking, PhotoSorterAlbumManaging, PhotoSorterAssetTrashBatching, PhotoSorterAssetTrashRestoring, PhotoSorterMediaCacheStatusProviding, PhotoSorterFileTreeSnapshotProviding, @unchecked Sendable {
    var metadataByPath: [String: PhotoSorterMediaMetadata] = [:]
    var listItemsByScope: [String: [PhotoSorterMediaListItem]] = [:]
    var cachedOCRByPath: [String: String] = [:]
    var liveOCRByPath: [String: String] = [:]
    var cachedVLMByPath: [String: String] = [:]
    var liveVLMByPath: [String: String] = [:]
    var mediaAskExcludedCountByPath: [String: Int] = [:]
    var vlmStatus: PhotoSorterMediaVLMStatus
    var indexStatus: PhotoLibraryIndexStatus = .idle
    var ocrStatus: PhotoSorterMediaOCRCacheStatus = .idle
    var placeStatus: PhotoSorterMediaPlaceCacheStatus = .idle
    var fileTreeSnapshotText = "当前照片工作区树（动态快照；括号内为该目录树下的媒体条目数；相册统计的是相册引用，可能重复计算同一张照片）：\n\n/\n└── 相册/ (0)\n\n照片库索引：ready，version 1，processed 0/0"
    var modelImagesByPath: [String: PhotoSorterOriginalImage] = [:]
    var modelImageErrorsByPath: [String: PhotoSorterMediaImageError] = [:]
    var modelImageNeverReturnPaths: Set<String> = []
    var missingTrashPaths: Set<String> = []
    var missingRestorePaths: Set<String> = []
    private let lock = NSLock()
    private var requestedListRequests: [StubMediaListRequest] = []
    private var requestedStatsRequests: [StubMediaStatsRequest] = []
    private var requestedMetadataSinglePaths: [String] = []
    private var requestedMetadataBatchPaths: [[String]] = []
    private var requestedCachedOCRSinglePaths: [String] = []
    private var requestedCachedOCRBatchPaths: [[String]] = []
    private var requestedLiveOCRPaths: [String] = []
    private var requestedCachedVLMSinglePaths: [String] = []
    private var requestedCachedVLMBatchPaths: [[String]] = []
    private var requestedLiveVLMPaths: [String] = []
    private var requestedMediaAskExcludedCountBatchPaths: [[String]] = []
    private var requestedRecordedMediaAskExclusionPathBatches: [[String]] = []
    private var requestedModelImagePaths: [String] = []
    private var requestedModelImageMaxPixelDimensions: [Int] = []
    private var requestedAlbumAddRequests: [StubAlbumAddRequest] = []
    private var requestedAlbumRemoveRequests: [StubAlbumRemoveRequest] = []
    private var requestedDeletedAlbumPaths: [String] = []
    private var requestedTrashedAssetPaths: [[String]] = []
    private var requestedRestoredTrashPaths: [[String]] = []
    private var requestedFileTreeSnapshotRequests: [StubFileTreeSnapshotRequest] = []

    init(
        metadataByPath: [String: PhotoSorterMediaMetadata] = [:],
        listItemsByScope: [String: [PhotoSorterMediaListItem]] = [:],
        cachedOCRByPath: [String: String] = [:],
        liveOCRByPath: [String: String] = [:],
        cachedVLMByPath: [String: String] = [:],
        liveVLMByPath: [String: String] = [:],
        mediaAskExcludedCountByPath: [String: Int] = [:],
        vlmLiveAvailable: Bool = false,
        vlmStatus: PhotoSorterMediaVLMStatus? = nil,
        modelImagesByPath: [String: PhotoSorterOriginalImage] = [:],
        modelImageErrorsByPath: [String: PhotoSorterMediaImageError] = [:],
        modelImageNeverReturnPaths: Set<String> = [],
        missingTrashPaths: Set<String> = [],
        missingRestorePaths: Set<String> = []
    ) {
        self.metadataByPath = metadataByPath
        self.listItemsByScope = listItemsByScope
        self.cachedOCRByPath = cachedOCRByPath
        self.liveOCRByPath = liveOCRByPath
        self.cachedVLMByPath = cachedVLMByPath
        self.liveVLMByPath = liveVLMByPath
        self.mediaAskExcludedCountByPath = mediaAskExcludedCountByPath
        self.vlmStatus = vlmStatus ?? Self.defaultVLMStatus(
            cachedCount: cachedVLMByPath.count,
            totalCount: metadataByPath.count,
            liveAvailable: vlmLiveAvailable
        )
        self.modelImagesByPath = modelImagesByPath
        self.modelImageErrorsByPath = modelImageErrorsByPath
        self.modelImageNeverReturnPaths = modelImageNeverReturnPaths
        self.missingTrashPaths = missingTrashPaths
        self.missingRestorePaths = missingRestorePaths
    }

    var listRequests: [StubMediaListRequest] {
        lock.withLock {
            requestedListRequests
        }
    }

    var statsRequests: [StubMediaStatsRequest] {
        lock.withLock {
            requestedStatsRequests
        }
    }

    var metadataSingleRequestPaths: [String] {
        lock.withLock {
            requestedMetadataSinglePaths
        }
    }

    var metadataBatchRequestPaths: [[String]] {
        lock.withLock {
            requestedMetadataBatchPaths
        }
    }

    var cachedOCRSingleRequestPaths: [String] {
        lock.withLock {
            requestedCachedOCRSinglePaths
        }
    }

    var cachedOCRBatchRequestPaths: [[String]] {
        lock.withLock {
            requestedCachedOCRBatchPaths
        }
    }

    var liveOCRRequestPaths: [String] {
        lock.withLock {
            requestedLiveOCRPaths
        }
    }

    var fileTreeSnapshotRequests: [StubFileTreeSnapshotRequest] {
        lock.withLock {
            requestedFileTreeSnapshotRequests
        }
    }

    var cachedVLMSingleRequestPaths: [String] {
        lock.withLock {
            requestedCachedVLMSinglePaths
        }
    }

    var cachedVLMBatchRequestPaths: [[String]] {
        lock.withLock {
            requestedCachedVLMBatchPaths
        }
    }

    var liveVLMRequestPaths: [String] {
        lock.withLock {
            requestedLiveVLMPaths
        }
    }

    var mediaAskExcludedCountBatchRequestPaths: [[String]] {
        lock.withLock {
            requestedMediaAskExcludedCountBatchPaths
        }
    }

    var recordedMediaAskExclusionPathBatches: [[String]] {
        lock.withLock {
            requestedRecordedMediaAskExclusionPathBatches
        }
    }

    var modelImageRequestPaths: [String] {
        lock.withLock {
            requestedModelImagePaths
        }
    }

    var modelImageMaxPixelDimensions: [Int] {
        lock.withLock {
            requestedModelImageMaxPixelDimensions
        }
    }

    var deletedAlbumPaths: [String] {
        lock.withLock {
            requestedDeletedAlbumPaths
        }
    }

    var albumAddRequests: [StubAlbumAddRequest] {
        lock.withLock {
            requestedAlbumAddRequests
        }
    }

    var albumRemoveRequests: [StubAlbumRemoveRequest] {
        lock.withLock {
            requestedAlbumRemoveRequests
        }
    }

    var trashedAssetPathBatches: [[String]] {
        lock.withLock {
            requestedTrashedAssetPaths
        }
    }

    var restoredTrashPathBatches: [[String]] {
        lock.withLock {
            requestedRestoredTrashPaths
        }
    }

    var photoSorterMediaIndexStatus: PhotoLibraryIndexStatus {
        indexStatus
    }

    var photoSorterMediaOCRCacheStatus: PhotoSorterMediaOCRCacheStatus {
        ocrStatus
    }

    var photoSorterMediaPlaceCacheStatus: PhotoSorterMediaPlaceCacheStatus {
        placeStatus
    }

    func photoSorterMediaList(
        in scopePath: String,
        offset: Int,
        limit: Int,
        sort: PhotoSorterMediaListSort,
        order: PhotoSorterMediaListOrder,
        mediaType: PhotoSorterMediaType
    ) throws -> PhotoSorterMediaListPage {
        lock.withLock {
            requestedListRequests.append(StubMediaListRequest(
                scopePath: scopePath,
                offset: offset,
                limit: limit,
                sort: sort,
                order: order,
                mediaType: mediaType
            ))
        }
        let sourceItems = listItemsByScope[scopePath] ?? metadataByPath.values
            .filter { metadata in
                PhotoLibraryMount.parentPath(of: metadata.path) == scopePath
            }
            .map { metadata in
                PhotoSorterMediaListItem(
                    path: metadata.path,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    creationDate: metadata.creationDate,
                    modificationDate: metadata.modificationDate,
                    mediaType: metadata.mediaType
                )
            }
        let typedItems = sourceItems.filter { item in
            mediaType == .all || item.mediaType == mediaType
        }
        let sortedItems = typedItems.sorted { lhs, rhs in
            let ascending = order == .asc
            switch sort {
            case .created:
                let left = lhs.creationDate ?? .distantPast
                let right = rhs.creationDate ?? .distantPast
                return left == right
                    ? lhs.path < rhs.path
                    : (ascending ? left < right : left > right)
            case .modified:
                let left = lhs.modificationDate ?? lhs.creationDate ?? .distantPast
                let right = rhs.modificationDate ?? rhs.creationDate ?? .distantPast
                return left == right
                    ? lhs.path < rhs.path
                    : (ascending ? left < right : left > right)
            case .name:
                return ascending ? lhs.path < rhs.path : lhs.path > rhs.path
            }
        }
        let pageItems = Array(sortedItems.dropFirst(min(max(offset, 0), sortedItems.count)).prefix(max(limit, 0)))
        return PhotoSorterMediaListPage(
            items: pageItems,
            totalCount: sortedItems.count,
            offset: max(offset, 0),
            limit: max(limit, 0)
        )
    }

    func photoSorterMediaStats(
        in scopePath: String,
        groupBy: PhotoSorterMediaStatsGroup,
        dateField: PhotoSorterMediaStatsDateField,
        mediaType: PhotoSorterMediaType
    ) throws -> [PhotoSorterMediaStatsBucket] {
        lock.withLock {
            requestedStatsRequests.append(StubMediaStatsRequest(
                scopePath: scopePath,
                groupBy: groupBy,
                dateField: dateField,
                mediaType: mediaType
            ))
        }
        let sourceItems = listItemsByScope[scopePath] ?? metadataByPath.values
            .filter { metadata in
                PhotoLibraryMount.parentPath(of: metadata.path) == scopePath
            }
            .map { metadata in
                PhotoSorterMediaListItem(
                    path: metadata.path,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    creationDate: metadata.creationDate,
                    modificationDate: metadata.modificationDate,
                    mediaType: metadata.mediaType
                )
            }
        let typedItems = sourceItems.filter { item in
            mediaType == .all || item.mediaType == mediaType
        }
        let grouped: [String: [PhotoSorterMediaListItem]]
        switch groupBy {
        case .month:
            grouped = Dictionary(grouping: typedItems, by: { item in
                PhotoSorterMediaCommand.monthText(
                    for: dateField == .created ? item.creationDate : item.modificationDate
                )
            })
        case .type:
            grouped = Dictionary(grouping: typedItems, by: { $0.mediaType.rawValue })
        }
        return grouped
            .map { PhotoSorterMediaStatsBucket(key: $0.key, count: $0.value.count) }
            .sorted { $0.key < $1.key }
    }


    func photoSorterMediaMetadata(for virtualPath: String) throws -> PhotoSorterMediaMetadata? {
        lock.withLock {
            requestedMetadataSinglePaths.append(virtualPath)
        }
        return metadataByPath[virtualPath]
    }

    func photoSorterMediaMetadata(for virtualPaths: [String]) -> [PhotoSorterMediaMetadataLookup] {
        lock.withLock {
            requestedMetadataBatchPaths.append(virtualPaths)
        }
        return virtualPaths.map { path in
            guard let metadata = metadataByPath[path] else {
                return .unavailable("media asset not found")
            }
            return .hit(metadata)
        }
    }

    func cachedPhotoSorterMediaOCRText(for virtualPath: String) throws -> PhotoSorterMediaOCRCacheLookup {
        lock.withLock {
            requestedCachedOCRSinglePaths.append(virtualPath)
        }
        guard let text = cachedOCRByPath[virtualPath] else {
            return .miss
        }
        return .hit(PhotoSorterMediaOCRResult(
            path: virtualPath,
            text: text,
            source: .cache
        ))
    }

    func cachedPhotoSorterMediaOCRTexts(for virtualPaths: [String]) -> [PhotoSorterMediaOCRCacheLookup] {
        lock.withLock {
            requestedCachedOCRBatchPaths.append(virtualPaths)
        }
        return virtualPaths.map { path in
            guard let text = cachedOCRByPath[path] else {
                return .miss
            }
            return .hit(PhotoSorterMediaOCRResult(
                path: path,
                text: text,
                source: .cache
            ))
        }
    }

    func recognizePhotoSorterMediaOCRText(for virtualPath: String) async throws -> PhotoSorterMediaOCRResult? {
        lock.withLock {
            requestedLiveOCRPaths.append(virtualPath)
        }
        guard let text = liveOCRByPath[virtualPath] else {
            return nil
        }
        return PhotoSorterMediaOCRResult(
            path: virtualPath,
            text: text,
            source: .live
        )
    }

    func photoSorterVLMStatus() -> PhotoSorterMediaVLMStatus {
        vlmStatus
    }

    func cachedPhotoSorterVLMSummary(for virtualPath: String) throws -> PhotoSorterMediaVLMCacheLookup {
        lock.withLock {
            requestedCachedVLMSinglePaths.append(virtualPath)
        }
        guard let summary = cachedVLMByPath[virtualPath] else {
            return .miss
        }
        return .hit(PhotoSorterMediaVLMSummaryResult(
            path: virtualPath,
            summary: summary,
            source: .cache
        ))
    }

    func cachedPhotoSorterVLMSummaries(for virtualPaths: [String]) -> [PhotoSorterMediaVLMCacheLookup] {
        lock.withLock {
            requestedCachedVLMBatchPaths.append(virtualPaths)
        }
        return virtualPaths.map { path in
            guard let summary = cachedVLMByPath[path] else {
                return .miss
            }
            return .hit(PhotoSorterMediaVLMSummaryResult(
                path: path,
                summary: summary,
                source: .cache
            ))
        }
    }

    func summarizePhotoSorterMediaVLM(for virtualPath: String) async throws -> PhotoSorterMediaVLMSummaryResult? {
        lock.withLock {
            requestedLiveVLMPaths.append(virtualPath)
        }
        guard let summary = liveVLMByPath[virtualPath] else {
            return nil
        }
        return PhotoSorterMediaVLMSummaryResult(
            path: virtualPath,
            summary: summary,
            source: .live
        )
    }

    func photoSorterMediaAskExcludedCountsByUser(for virtualPaths: [String]) -> [Int] {
        lock.withLock {
            requestedMediaAskExcludedCountBatchPaths.append(virtualPaths)
            return virtualPaths.map { max(mediaAskExcludedCountByPath[$0, default: 0], 0) }
        }
    }

    func recordPhotoSorterMediaAskExclusionsByUser(at virtualPaths: [String]) throws {
        lock.withLock {
            requestedRecordedMediaAskExclusionPathBatches.append(virtualPaths)
            var seen = Set<String>()
            for path in virtualPaths where seen.insert(path).inserted {
                mediaAskExcludedCountByPath[path, default: 0] = max(mediaAskExcludedCountByPath[path, default: 0], 0) + 1
            }
        }
    }

    func photoSorterModelImage(
        for virtualPath: String,
        maxPixelDimension: Int
    ) async throws -> PhotoSorterOriginalImage? {
        lock.withLock {
            requestedModelImagePaths.append(virtualPath)
            requestedModelImageMaxPixelDimensions.append(maxPixelDimension)
        }
        while modelImageNeverReturnPaths.contains(virtualPath), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if let error = modelImageErrorsByPath[virtualPath] {
            throw error
        }
        return modelImagesByPath[virtualPath]
    }

    func photoSorterFileTreeSnapshot(rootPath: String, maxUserAlbums: Int) -> String {
        lock.withLock {
            requestedFileTreeSnapshotRequests.append(StubFileTreeSnapshotRequest(
                rootPath: rootPath,
                maxUserAlbums: maxUserAlbums
            ))
        }
        return fileTreeSnapshotText
    }

    private static func defaultVLMStatus(
        cachedCount: Int,
        totalCount: Int,
        liveAvailable: Bool
    ) -> PhotoSorterMediaVLMStatus {
        let providerStatus = PhotoSorterMediaVLMProviderStatus(
            kind: PhotoSorterMediaVLMConfiguration.providerKind,
            backend: PhotoSorterMediaVLMConfiguration.backend,
            modelID: PhotoSorterMediaVLMConfiguration.modelID,
            modelVersion: PhotoSorterMediaVLMConfiguration.modelVersion,
            modelState: liveAvailable ? .installed : .notInstalled,
            isLiveSummarizationAvailable: liveAvailable,
            processorConfigFingerprint: PhotoSorterMediaVLMConfiguration.processorConfigFingerprintNotInstalled,
            reason: liveAvailable ? nil : "local FastVLM model is not installed"
        )
        return PhotoSorterMediaVLMStatus(
            primaryProvider: providerStatus,
            systemProvider: PhotoSorterMediaVLMConfiguration.systemUnavailableProviderStatus,
            cachedCount: cachedCount,
            totalCount: totalCount,
            isPreheating: false,
            isPaused: false,
            processedInCurrentBatch: 0,
            batchLimit: 0,
            failedInCurrentBatch: 0,
            skippedInCurrentBatch: 0,
            message: providerStatus.reason,
            promptVersion: PhotoSorterMediaVLMConfiguration.promptVersion,
            prompt: PhotoSorterMediaVLMConfiguration.prompt,
            language: PhotoSorterMediaVLMConfiguration.language,
            summarySchemaVersion: PhotoSorterMediaVLMConfiguration.summarySchemaVersion
        )
    }

    func addPhotoSorterAssets(
        at assetPaths: [String],
        toAlbumPath albumPath: String,
        createAlbumIfNeeded: Bool
    ) throws -> PhotoSorterAlbumAddSummary {
        lock.withLock {
            requestedAlbumAddRequests.append(StubAlbumAddRequest(
                assetPaths: assetPaths,
                albumPath: albumPath,
                createAlbumIfNeeded: createAlbumIfNeeded
            ))
        }
        return PhotoSorterAlbumAddSummary(
            requested: assetPaths.count,
            added: assetPaths.count,
            skippedExisting: 0
        )
    }

    func removePhotoSorterAssets(
        at assetPaths: [String],
        fromAlbumPath albumPath: String
    ) throws -> PhotoSorterAlbumRemoveSummary {
        lock.withLock {
            requestedAlbumRemoveRequests.append(StubAlbumRemoveRequest(
                assetPaths: assetPaths,
                albumPath: albumPath
            ))
        }
        return PhotoSorterAlbumRemoveSummary(
            requested: assetPaths.count,
            removed: assetPaths.count,
            skippedNotInAlbum: 0
        )
    }

    func trashPhotoSorterAssets(at virtualPaths: [String]) throws -> PhotoSorterMediaTrashSummary {
        let missing = virtualPaths.filter { missingTrashPaths.contains($0) }
        let existing = virtualPaths.filter { !missingTrashPaths.contains($0) }
        lock.withLock {
            requestedTrashedAssetPaths.append(existing)
        }
        return PhotoSorterMediaTrashSummary(
            requested: virtualPaths.count,
            trashed: existing.count,
            missingPaths: missing
        )
    }

    func restorePhotoSorterTrash(at virtualPaths: [String]) throws -> PhotoSorterMediaRestoreSummary {
        let missing = virtualPaths.filter { missingRestorePaths.contains($0) }
        let existing = virtualPaths.filter { !missingRestorePaths.contains($0) }
        lock.withLock {
            requestedRestoredTrashPaths.append(existing)
        }
        return PhotoSorterMediaRestoreSummary(
            requested: virtualPaths.count,
            restored: existing.count,
            missingPaths: missing
        )
    }

    func deletePhotoSorterUserAlbumContainer(at virtualPath: String) throws {
        lock.withLock {
            requestedDeletedAlbumPaths.append(virtualPath)
        }
    }
}
