import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

enum PhotoSorterVisualContentFingerprint {
    private static let side = 128
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    static func make(
        from image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> String? {
        var pixels = Data(count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else {
            return nil
        }
        return digest(
            pixels,
            discriminator: "cg:\(orientation.rawValue):\(image.width)x\(image.height)"
        )
    }

    static func make(from image: CIImage) -> String? {
        let extent = image.extent
        guard extent.width.isFinite,
              extent.height.isFinite,
              extent.width > 0,
              extent.height > 0 else {
            return nil
        }

        let translated = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(side) / extent.width,
                y: CGFloat(side) / extent.height
            )
        )
        var pixels = Data(count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                return false
            }
            CIContext(options: [.cacheIntermediates: false]).render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: side * 4,
                bounds: CGRect(x: 0, y: 0, width: side, height: side),
                format: .RGBA8,
                colorSpace: colorSpace
            )
            return true
        }
        guard rendered else {
            return nil
        }
        return digest(
            pixels,
            discriminator: "ci:\(Int(extent.width.rounded()))x\(Int(extent.height.rounded()))"
        )
    }

    private static func digest(_ pixels: Data, discriminator: String) -> String {
        var payload = Data("photosorter-visual-fingerprint-v1|\(discriminator)|".utf8)
        payload.append(pixels)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
