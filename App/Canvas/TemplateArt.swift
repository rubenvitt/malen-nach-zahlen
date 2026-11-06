import CoreGraphics
import CoreText
import Foundation
import PaintEngine
import UIKit

/// Vector drawing of the template's numbers and borders, in grid coordinates (1 unit = 1 grid
/// pixel). Immutable after init, so tiled layers may draw it from background threads.
final class TemplateArt: @unchecked Sendable {
    let template: Template
    private let labels: [(line: CTLine, center: CGPoint, size: CGFloat, bounds: CGRect)]

    init(template: Template) {
        self.template = template
        let base = UIFont.systemFont(ofSize: 10, weight: .medium)
        let descriptor = (base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor) as CTFontDescriptor
        let grey = CGColor(gray: 0.42, alpha: 1)
        labels = template.spots.compactMap { spot in
            guard Int(spot.field) < template.colorOfField.count else { return nil }
            let number = Int(template.colorOfField[Int(spot.field)]) + 1
            let size = CGFloat(min(max(spot.radius * 1.25, 2.5), 14))
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            let text = NSAttributedString(string: String(number), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): grey,
            ])
            let line = CTLineCreateWithAttributedString(text)
            let center = CGPoint(x: CGFloat(spot.x) + 0.5, y: CGFloat(spot.y) + 0.5)
            return (line, center, size, CGRect(x: center.x - size, y: center.y - size, width: 2 * size, height: 2 * size))
        }
    }

    /// Device pixels per grid unit of a context.
    static func scale(of ctx: CGContext) -> CGFloat {
        let t = ctx.ctm
        return max(0.001, (t.a * t.a + t.c * t.c).squareRoot())
    }

    /// Grey numbers; ones too small to read at this scale are skipped. Expects a top-left origin.
    func drawNumbers(in ctx: CGContext, rect: CGRect) {
        let scale = Self.scale(of: ctx)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for label in labels where label.size * scale >= 6 && label.bounds.intersects(rect) {
            let b = CTLineGetBoundsWithOptions(label.line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: label.center.x - b.midX, y: label.center.y + b.midY)
            CTLineDraw(label.line, ctx)
        }
        ctx.restoreGState()
    }

    /// Thin black lines between fields plus an outline, ~1.5 device pixels wide.
    func drawBorders(in ctx: CGContext, rect: CGRect) {
        let w = template.width, h = template.height
        let x0 = max(0, Int(rect.minX.rounded(.down)) - 1), x1 = min(w, Int(rect.maxX.rounded(.up)) + 1)
        let y0 = max(0, Int(rect.minY.rounded(.down)) - 1), y1 = min(h, Int(rect.maxY.rounded(.up)) + 1)
        guard x0 < x1, y0 < y1 else { return }
        let path = CGMutablePath()
        template.fieldOfPixel.withUnsafeBufferPointer { field in
            // Horizontal edges at y (between rows y-1 and y), merged into runs.
            for y in max(1, y0)..<max(max(1, y0), min(h, y1 + 1)) {
                var run: Int?
                for x in x0...x1 {
                    let edge = x < x1 && field[(y - 1) * w + x] != field[y * w + x]
                    if edge, run == nil { run = x }
                    if !edge, let s = run {
                        path.move(to: CGPoint(x: s, y: y)); path.addLine(to: CGPoint(x: x, y: y)); run = nil
                    }
                }
            }
            // Vertical edges at x (between columns x-1 and x).
            for x in max(1, x0)..<max(max(1, x0), min(w, x1 + 1)) {
                var run: Int?
                for y in y0...y1 {
                    let edge = y < y1 && field[y * w + x - 1] != field[y * w + x]
                    if edge, run == nil { run = y }
                    if !edge, let s = run {
                        path.move(to: CGPoint(x: x, y: s)); path.addLine(to: CGPoint(x: x, y: y)); run = nil
                    }
                }
            }
        }
        path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(min(1.5 / Self.scale(of: ctx), 0.45))
        ctx.setLineCap(.square)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
