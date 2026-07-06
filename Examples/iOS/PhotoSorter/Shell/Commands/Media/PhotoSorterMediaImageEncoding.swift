import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PhotoSorterMediaCommand {
    static func modelImage(for image: PhotoSorterOriginalImage) -> PhotoSorterOriginalImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else {
            return image
        }
        let dimensions = imageDimensions(from: source) ?? CGSize(
            width: max(image.pixelWidth, 0),
            height: max(image.pixelHeight, 0)
        )
        let targetSize = PhotoSorterModelImageSizing.targetSize(
            width: Int(dimensions.width.rounded()),
            height: Int(dimensions.height.rounded()),
            preferredMaximumPixelDimension: Self.mediaViewPreferredMaximumPixelDimension
        )
        let largestDimension = max(dimensions.width, dimensions.height)
        let targetLargestDimension = max(targetSize.width, targetSize.height)
        guard largestDimension > targetLargestDimension else {
            return image
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(targetLargestDimension)))
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = encodedImageData(from: thumbnail, originalMimeType: image.mimeType) else {
            return image
        }

        return PhotoSorterOriginalImage(
            path: image.path,
            fileName: image.fileName,
            mimeType: encoded.mimeType,
            pixelWidth: thumbnail.width,
            pixelHeight: thumbnail.height,
            data: encoded.data
        )
    }

    static func imageDimensions(from source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static func encodedImageData(
        from image: CGImage,
        originalMimeType: String
    ) -> (data: Data, mimeType: String)? {
        let keepsPNG = originalMimeType.lowercased() == "image/png"
        let outputType = keepsPNG ? UTType.png.identifier : UTType.jpeg.identifier
        let outputMimeType = keepsPNG ? "image/png" : "image/jpeg"
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            outputType as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = keepsPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return (data as Data, outputMimeType)
    }
}
