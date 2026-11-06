import CoreGraphics
import CoreText
import UIKit
import PaintEngine

/// Pure CoreGraphics rendering of a template for the editor preview and gallery thumbnails.
/// Thread-safe: runs on background tasks.
enum TemplateRenderer {
    enum Mode: Sendable { case outline, colored }

    /// `scale` = output pixels per grid pixel (integer keeps the lines crisp).
    static func render(_ t: Template, mode: Mode, scale s: Int) -> CGImage? {
        let w = t.width, h = t.height, W = w * s, H = h * s
        guard w > 0, h > 0, t.colorOfPixel.count == w * h, t.fieldOfPixel.count == w * h else { return nil }
        let white: UInt32 = 0xFFFF_FFFF
        let line: UInt32 = pack(52, 46, 42)
        let colors = t.palette.map { pack($0.r, $0.g, $0.b) }
        var buf = [UInt32](repeating: white, count: W * H)
        let lw = max(1, min(3, s / 2))   // line width in output pixels, grows a little with the scale

        buf.withUnsafeMutableBufferPointer { out in
            t.colorOfPixel.withUnsafeBufferPointer { col in
                t.fieldOfPixel.withUnsafeBufferPointer { fld in
                    for y in 0..<h {
                        for x in 0..<w {
                            let i = y * w + x
                            let c = mode == .colored ? colors[Int(col[i]) < colors.count ? Int(col[i]) : 0] : white
                            if mode == .colored {
                                for dy in 0..<s {
                                    let row = (y * s + dy) * W + x * s
                                    for dx in 0..<s { out[row + dx] = c }
                                }
                            }
                            guard mode == .outline else { continue }
                            if x + 1 < w, fld[i] != fld[i + 1] {
                                let px = (x + 1) * s
                                for dy in 0..<s { for k in 0..<lw where px + k < W { out[(y * s + dy) * W + px + k] = line } }
                            }
                            if y + 1 < h, fld[i] != fld[i + w] {
                                for k in 0..<lw where (y + 1) * s + k < H {
                                    let row = ((y + 1) * s + k) * W
                                    for dx in 0..<(s + lw) where x * s + dx < W { out[row + x * s + dx] = line }
                                }
                            }
                        }
                    }
                }
            }
        }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                      bytesPerRow: W * 4, space: space, bitmapInfo: info) else { return nil }
            if mode == .outline { drawNumbers(t, in: ctx, scale: s, height: H) }
            return ctx.makeImage()
        }
    }

    static func thumbnailJPEG(_ t: Template) -> Data? {
        let scale = max(1, 900 / max(t.width, t.height, 1))
        guard let image = render(t, mode: .outline, scale: scale) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }

    // ABGR in memory order for byteOrder32Little + premultipliedLast → RGBA bytes.
    private static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(b) << 16 | UInt32(g) << 8 | UInt32(r)
    }

    private static func drawNumbers(_ t: Template, in ctx: CGContext, scale s: Int, height H: Int) {
        let base = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let gray = CGColor(red: 0.42, green: 0.40, blue: 0.38, alpha: 1)
        var fonts: [Int: CTFont] = [:]
        for spot in t.spots {
            let size = min(CGFloat(spot.radius) * CGFloat(s) * 1.15, CGFloat(s) * 11)
            guard size >= 7, Int(spot.field) < t.colorOfField.count else { continue }
            let key = Int(size.rounded())
            let font = fonts[key] ?? CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, CGFloat(key), nil)
            fonts[key] = font
            let text = NSAttributedString(string: "\(Int(t.colorOfField[Int(spot.field)]) + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): gray,
            ])
            let ctLine = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(ctLine, .useOpticalBounds)
            let cx = (CGFloat(spot.x) + 0.5) * CGFloat(s), cy = CGFloat(H) - (CGFloat(spot.y) + 0.5) * CGFloat(s)
            ctx.textPosition = CGPoint(x: cx - bounds.midX, y: cy - bounds.midY)
            CTLineDraw(ctLine, ctx)
        }
    }
}
