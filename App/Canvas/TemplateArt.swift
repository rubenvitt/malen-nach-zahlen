import CoreGraphics
import CoreText
import Foundation
import PaintEngine
import UIKit

/// Vector drawing of the template's numbers and smooth borders, in grid coordinates (1 unit = 1 grid
/// pixel). Immutable after init, so tiled layers may draw it from background threads.
final class TemplateArt: @unchecked Sendable {
    let template: Template
    private let labels: [(line: CTLine, center: CGPoint, size: CGFloat, bounds: CGRect)]
    let borders: BorderLines

    init(template: Template) {
        self.template = template
        borders = BorderLines(template: template)
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

    /// Thin black lines between fields plus an outline, ~1.5 device pixels wide. The borders are
    /// smooth curves, not the pixel staircase of the fields underneath.
    func drawBorders(in ctx: CGContext, rect: CGRect) {
        let path = CGMutablePath()
        let pad = rect.insetBy(dx: -1, dy: -1)
        for index in borders.lineIndices(in: pad) {
            let line = borders.lines[index]
            guard line.bounds.intersects(pad) else { continue }
            BorderLines.add(line, to: path)
        }
        path.addRect(CGRect(x: 0, y: 0, width: template.width, height: template.height))
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(min(1.5 / Self.scale(of: ctx), 0.45))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// The borders between fields as smoothed polylines in grid units.
///
/// The pixel edges between different fields are chained into lines that run from junction to
/// junction (where three or more fields meet, or the picture edge) or form closed loops. Each line
/// is then smoothed with a Gaussian along its length; junctions stay fixed, so neighbouring lines
/// still meet. Drawn as quadratic curves through the midpoints, the result has no corners.
struct BorderLines: Sendable {
    struct Line: Sendable {
        var points: [CGPoint]
        var closed: Bool
        var bounds: CGRect
    }

    private(set) var lines: [Line] = []
    private static let cell = 32                       // grid units per index cell
    private let cellsPerRow: Int
    private var cells: [[Int32]]

    init(template: Template) {
        let w = template.width, h = template.height
        cellsPerRow = (w + Self.cell - 1) / Self.cell + 1
        cells = Array(repeating: [], count: cellsPerRow * ((h + Self.cell - 1) / Self.cell + 1))
        for (points, closed) in Self.trace(template) {
            let smooth = Self.thin(Self.smooth(points, closed: closed), closed: closed)
            var b = CGRect(origin: smooth[0], size: .zero)
            for p in smooth { b = b.union(CGRect(origin: p, size: .zero)) }
            let index = Int32(lines.count)
            lines.append(Line(points: smooth, closed: closed, bounds: b))
            for cy in cellRange(b.minY, b.maxY) {
                for cx in cellRange(b.minX, b.maxX) { cells[cy * cellsPerRow + cx].append(index) }
            }
        }
    }

    private func cellRange(_ lo: CGFloat, _ hi: CGFloat) -> ClosedRange<Int> {
        let a = max(0, Int(lo) / Self.cell), b = max(a, Int(hi.rounded(.up)) / Self.cell)
        return a...b
    }

    /// Indices of lines whose index cells touch `rect`, each once.
    func lineIndices(in rect: CGRect) -> [Int] {
        guard !rect.isNull, !cells.isEmpty else { return [] }
        let rows = cells.count / cellsPerRow
        let xs = cellRange(max(0, rect.minX), max(0, rect.maxX)), ys = cellRange(max(0, rect.minY), max(0, rect.maxY))
        var seen = Set<Int32>()
        var out: [Int] = []
        for cy in ys where cy < rows {
            for cx in xs where cx < cellsPerRow {
                for i in cells[cy * cellsPerRow + cx] where seen.insert(i).inserted { out.append(Int(i)) }
            }
        }
        return out
    }

    // MARK: Tracing

    /// Chains the pixel edges between different fields. Lattice vertex (x, y) is a pixel corner;
    /// edge ids: horizontal (x,y)–(x+1,y) at y*w+x, then vertical (x,y)–(x,y+1).
    static func trace(_ t: Template) -> [(points: [CGPoint], closed: Bool)] {
        let w = t.width, h = t.height, vw = w + 1
        let hCount = (h + 1) * w
        var on = [Bool](repeating: false, count: hCount + h * vw)
        t.fieldOfPixel.withUnsafeBufferPointer { field in
            for y in 1..<max(1, h) {
                for x in 0..<w where field[(y - 1) * w + x] != field[y * w + x] { on[y * w + x] = true }
            }
            for y in 0..<h {
                for x in 1..<max(1, w) where field[y * w + x - 1] != field[y * w + x] { on[hCount + y * vw + x] = true }
            }
        }
        var visited = [Bool](repeating: false, count: on.count)
        var around: [(edge: Int, x: Int, y: Int)] = []
        around.reserveCapacity(4)

        func edges(_ x: Int, _ y: Int) {
            around.removeAll(keepingCapacity: true)
            if x < w, on[y * w + x] { around.append((y * w + x, x + 1, y)) }
            if x > 0, on[y * w + x - 1] { around.append((y * w + x - 1, x - 1, y)) }
            if y < h, on[hCount + y * vw + x] { around.append((hCount + y * vw + x, x, y + 1)) }
            if y > 0, on[hCount + (y - 1) * vw + x] { around.append((hCount + (y - 1) * vw + x, x, y - 1)) }
        }

        func walk(_ x: Int, _ y: Int, _ first: (edge: Int, x: Int, y: Int)) -> [CGPoint] {
            var points = [CGPoint(x: x, y: y)]
            var e = first
            while true {
                visited[e.edge] = true
                points.append(CGPoint(x: e.x, y: e.y))
                edges(e.x, e.y)
                guard around.count == 2, let next = around.first(where: { !visited[$0.edge] }) else { break }
                e = next
            }
            return points
        }

        var out: [(points: [CGPoint], closed: Bool)] = []
        // Lines between junctions and ends first …
        for y in 0...h {
            for x in 0...w {
                edges(x, y)
                guard !around.isEmpty, around.count != 2 else { continue }
                for e in around where !visited[e.edge] {   // iterates a copy; walk reuses the buffer
                    out.append((walk(x, y, e), false))
                }
            }
        }
        // … then what is left are closed loops.
        for y in 0...h {
            for x in 0...w {
                edges(x, y)
                guard around.count == 2, let e = around.first(where: { !visited[$0.edge] }) else { continue }
                var points = walk(x, y, e)
                if points.count > 1, points.first == points.last { points.removeLast() }
                out.append((points, true))
            }
        }
        return out
    }

    // MARK: Smoothing

    private static let radius = 5
    private static let weights: [Double] = (0...radius).map { k in exp(-Double(k * k) / (2 * 2.2 * 2.2)) }

    /// Gaussian smoothing along the line. Open lines shrink the window towards their ends, so the
    /// end points stay exactly where they are.
    static func smooth(_ p: [CGPoint], closed: Bool) -> [CGPoint] {
        let n = p.count
        guard n > 2 else { return p }
        var out = p
        for i in 0..<n {
            let r = closed ? min(radius, (n - 1) / 2) : min(radius, i, n - 1 - i)
            guard r > 0 else { continue }
            var sx = 0.0, sy = 0.0, sw = 0.0
            for k in -r...r {
                let j = closed ? ((i + k) % n + n) % n : i + k
                let wk = weights[abs(k)]
                sx += wk * Double(p[j].x); sy += wk * Double(p[j].y); sw += wk
            }
            out[i] = CGPoint(x: sx / sw, y: sy / sw)
        }
        return out
    }

    /// Keeps every second point (ends included); the curve through them looks the same.
    static func thin(_ p: [CGPoint], closed: Bool) -> [CGPoint] {
        guard p.count > 8 else { return p }
        var out = stride(from: 0, to: p.count, by: 2).map { p[$0] }
        if !closed, out.last != p.last { out.append(p[p.count - 1]) }
        return out
    }

    // MARK: Drawing

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    /// Quadratic curves through the midpoints, with the points as controls.
    static func add(_ line: Line, to path: CGMutablePath) {
        let p = line.points, n = p.count
        guard n > 1 else { return }
        if n == 2 {
            path.move(to: p[0]); path.addLine(to: p[1]); return
        }
        if line.closed {
            path.move(to: mid(p[n - 1], p[0]))
            for i in 0..<n { path.addQuadCurve(to: mid(p[i], p[(i + 1) % n]), control: p[i]) }
            path.closeSubpath()
        } else {
            path.move(to: p[0])
            for i in 1..<(n - 1) { path.addQuadCurve(to: i == n - 2 ? p[n - 1] : mid(p[i], p[i + 1]), control: p[i]) }
        }
    }
}
