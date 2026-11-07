#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import PaintEngine

/// App Store screenshots (`-uiTestPrefill`): a picture that is painted about halfway, from the top,
/// as a paint layer PNG in the format `PaintLayer` loads (8-bit grey, `PaintLayer.scale` per grid pixel).
enum ScreenshotPrefill {
    static func paintLayerPNG(for template: Template, upTo share: Double = 0.55) -> Data? {
        let limit = Int(Double(template.height) * share)
        let fields = Set(template.spots.filter { $0.y < limit }.map(\.field))
        let s = PaintLayer.scale, gw = template.width, w = gw * s, h = template.height * s
        var pixels = [UInt8](repeating: 0, count: w * h)
        for gy in 0..<template.height {
            for gx in 0..<gw where fields.contains(template.fieldOfPixel[gy * gw + gx]) {
                for sy in 0..<s {
                    for sx in 0..<s { pixels[(gy * s + sy) * w + gx * s + sx] = 255 }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
#endif
