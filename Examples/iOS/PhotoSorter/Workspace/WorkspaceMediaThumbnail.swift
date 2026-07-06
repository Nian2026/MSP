import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif
#if canImport(UIKit)
import UIKit
#endif

struct WorkspaceFileThumbnail: Equatable, Sendable {
    var data: Data
}

enum WorkspaceFileMediaKind: String, Sendable, Equatable {
    case image
    case video

    static func inferred(fromFileName fileName: String) -> WorkspaceFileMediaKind? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard !ext.isEmpty else {
            return nil
        }
        if imageExtensions.contains(ext) {
            return .image
        }
        if videoExtensions.contains(ext) {
            return .video
        }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "avif",
        "bmp",
        "gif",
        "heic",
        "heif",
        "jpeg",
        "jpg",
        "png",
        "tif",
        "tiff",
        "webp"
    ]

    private static let videoExtensions: Set<String> = [
        "3g2",
        "3gp",
        "avi",
        "m4v",
        "mkv",
        "mov",
        "mp4",
        "mpeg",
        "mpg",
        "webm"
    ]
}

actor WorkspaceFileThumbnailCache {
    private let maximumCount: Int
    private var thumbnailsByKey: [String: WorkspaceFileThumbnail] = [:]
    private var keysInInsertionOrder: [String] = []

    init(maximumCount: Int = 360) {
        self.maximumCount = max(1, maximumCount)
    }

    func thumbnail(for key: String) -> WorkspaceFileThumbnail? {
        thumbnailsByKey[key]
    }

    func store(_ thumbnail: WorkspaceFileThumbnail, for key: String) {
        if thumbnailsByKey[key] == nil {
            keysInInsertionOrder.append(key)
        }
        thumbnailsByKey[key] = thumbnail

        while keysInInsertionOrder.count > maximumCount {
            let oldestKey = keysInInsertionOrder.removeFirst()
            thumbnailsByKey.removeValue(forKey: oldestKey)
        }
    }
}

enum WorkspaceFileThumbnailEncoder {
#if canImport(UIKit)
    static func data(from image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.82) ?? image.pngData()
    }
#endif

#if canImport(AppKit)
    static func data(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
            ?? bitmap.representation(using: .png, properties: [:])
    }
#endif
}

enum WorkspaceLocalMediaThumbnailGenerator {
    static func thumbnail(for url: URL, targetSize: CGSize) async -> WorkspaceFileThumbnail? {
#if canImport(QuickLookThumbnailing) && canImport(UIKit)
        let size = CGSize(width: max(targetSize.width, 1), height: max(targetSize.height, 1))
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 1,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                guard let image = thumbnail?.uiImage,
                      let data = WorkspaceFileThumbnailEncoder.data(from: image)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: WorkspaceFileThumbnail(data: data))
            }
        }
#elseif canImport(QuickLookThumbnailing) && canImport(AppKit)
        let size = CGSize(width: max(targetSize.width, 1), height: max(targetSize.height, 1))
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 1,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                guard let image = thumbnail?.nsImage,
                      let data = WorkspaceFileThumbnailEncoder.data(from: image)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: WorkspaceFileThumbnail(data: data))
            }
        }
#else
        return nil
#endif
    }
}
