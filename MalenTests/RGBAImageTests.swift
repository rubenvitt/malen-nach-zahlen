import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Malen

struct RGBAImageTests {
    /// 40×20 image, left half red, right half blue, stored as TIFF (lossless) with an EXIF orientation.
    private func tiff(orientation: Int) throws -> Data {
        let w = 40, h = 20
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Colour management may shift channels slightly (TIFF without profile), so classify instead of comparing exactly.
    private func pixel(_ img: RGBAImage, _ x: Int, _ y: Int) -> String {
        let i = (y * img.width + x) * 4
        let (r, b) = (img.pixels[i], img.pixels[i + 2])
        return r > 200 && b < 80 ? "red" : b > 200 && r < 80 ? "blue" : "other"
    }

    @Test func upright() throws {
        let img = try RGBAImage(data: tiff(orientation: 1))
        #expect(img.width == 40 && img.height == 20)
        #expect(pixel(img, 2, 10) == "red")
        #expect(pixel(img, 37, 10) == "blue")
    }

    @Test func exifRotationIsApplied() throws {
        // Orientation 6: rotate 90° clockwise for display → portrait, the red left half ends up on top.
        let img = try RGBAImage(data: tiff(orientation: 6))
        #expect(img.width == 20 && img.height == 40)
        #expect(pixel(img, 10, 2) == "red")
        #expect(pixel(img, 10, 37) == "blue")
    }

    @Test func downsamplesToMaxSide() throws {
        let img = try RGBAImage(data: tiff(orientation: 1), maxSide: 10)
        #expect(max(img.width, img.height) == 10)
        #expect(img.pixels.count == img.width * img.height * 4)
    }

    @Test func undecodableDataThrows() {
        #expect(throws: RGBAImage.LoadError.self) { try RGBAImage(data: Data("nope".utf8)) }
    }
}
