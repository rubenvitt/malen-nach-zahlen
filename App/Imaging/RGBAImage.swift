import CoreGraphics
import ImageIO
import Foundation

/// Opaque sRGB RGBA8 pixels, the input format of `TemplateBuilder.build`.
struct RGBAImage: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    enum LoadError: Error { case undecodable }

    /// Decodes any ImageIO format (HEIC, JPEG, PNG …), applies EXIF orientation and
    /// downsamples to `maxSide` without ever holding the full-size bitmap.
    init(data: Data, maxSide: Int = 2000) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { throw LoadError.undecodable }
        try self.init(cgImage: image, maxSide: maxSide)
    }

    /// Draws into an sRGB bitmap, scaled down to `maxSide` if needed.
    init(cgImage: CGImage, maxSide: Int = 2000) throws {
        let scale = min(1, Double(maxSide) / Double(max(cgImage.width, cgImage.height)))
        let w = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let h = max(1, Int((Double(cgImage.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // White under transparency, otherwise transparent areas become a black colour cluster.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw LoadError.undecodable }
        self.pixels = pixels
        self.width = w
        self.height = h
    }

    /// A smaller copy for live previews, so the engine does not resample 4 MP on every slider tick.
    func downsampled(maxSide: Int) -> RGBAImage {
        guard max(width, height) > maxSide,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let small = try? RGBAImage(cgImage: image, maxSide: maxSide)
        else { return self }
        return small
    }
}
