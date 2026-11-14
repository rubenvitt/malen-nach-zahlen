import CoreGraphics
import Foundation
import ImageIO
import PaintEngine
import UniformTypeIdentifiers

/// Half-open rectangle in paint-layer pixels.
struct PixelRect: Equatable, Sendable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    func union(_ o: PixelRect?) -> PixelRect {
        guard let o, !o.isEmpty else { return self }
        if isEmpty { return o }
        return PixelRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
}

/// What one call into the stroke API changed.
struct StrokeChange: Sendable {
    var dirty: PixelRect?
    var completedFields: [Int32] = []
    var completedColors: [Int] = []
    var committed = false          // endStroke pushed an undo step
}

/// How a stroke puts paint down. Shading tools leave colour and coverage alone and only make the
/// paint that is already there darker or lighter.
enum BrushKind: String, CaseIterable, Codable, Sendable {
    /// Round, opaque, smooth edge.
    case brush
    /// Grainy like a crayon on paper; pressing harder or going over it again fills the gaps.
    case crayon
    /// Soft and see-through; strokes build up and glaze over other colours.
    case airbrush
    /// Darkens paint that is already there.
    case shadow
    /// Lightens paint that is already there.
    case light

    var isShading: Bool { self == .shadow || self == .light }

    /// Soft tools reach a bit further than the brush size, so their faded edge does not make them
    /// look thinner.
    fileprivate var radiusFactor: Double { self == .brush || self == .crayon ? 1 : 1.3 }
}

/// The paint bitmap and all progress bookkeeping, without any UIKit.
///
/// Per paint pixel the layer stores *coverage* (alpha 0...255), the palette index of the paint
/// (`paintColor`, always the colour that makes up most of it), a second colour mixed in where two
/// colours meet or glaze over each other (`under`, share `mix` ≤ ½), and a *shade* (128 = as is,
/// 0 = darkest, 255 = lightest). Paint goes anywhere, across field borders and over finished fields;
/// a wrong colour does not count as painted. Nothing is ever filled in automatically: a field counts
/// as done once almost all of it carries its colour, and painting over it can undo that again.
///
/// A stroke never paints over itself: each pixel remembers the strongest touch of the running
/// stroke (`strokeMask`), and the result is always mixed from what was there before the stroke. New
/// paint lies *on top of* old paint and never makes it thinner, so no white seams show where colours
/// meet.
final class PaintLayer {
    /// Paint pixels per grid pixel (as in the web prototype).
    static let scale = 2
    static let tileSize = 64          // undo snapshot granularity, paint pixels
    static let maxUndo = 50
    /// Undo snapshots beyond this many bytes drop the oldest steps (a stroke across the whole picture
    /// can be several megabytes).
    static let maxUndoBytes = 160 << 20
    static let neutralShade: UInt8 = 128
    private static let covered: UInt8 = 128

    /// The planes of `pixels`, in this order, each `width × height` bytes.
    enum Plane: Int, CaseIterable { case coverage, color, shade, under, mix }
    private static let planes = Plane.allCases.count

    let template: Template
    let width: Int, height: Int       // paint pixels
    private let planeSize: Int
    /// All planes back to back (see `Plane`).
    private(set) var pixels: [UInt8]

    var coverage: [UInt8] { plane(.coverage) }
    /// Palette index of the paint per paint pixel; only meaningful where `coverage > 0`.
    var paintColor: [UInt8] { plane(.color) }
    var shade: [UInt8] { plane(.shade) }
    func plane(_ p: Plane) -> [UInt8] { Array(pixels[(p.rawValue * planeSize)..<((p.rawValue + 1) * planeSize)]) }

    private(set) var paintedOfField: [Int32]
    private(set) var fieldComplete: [Bool]
    /// Progress per colour in grid pixels: painted pixels, or the whole field once it is done.
    private(set) var paintedOfColor: [Int]
    private(set) var sizeOfColor: [Int]
    private(set) var completeFieldsOfColor: [Int]
    private var fieldsOfColor: [Int]
    private(set) var totalPainted = 0
    private var totalSize = 0

    private struct Snapshot {
        /// Every plane of a tile as it was before the stroke.
        var tiles: [Int: [UInt8]] = [:]
        var fields: [Int32: (painted: Int32, complete: Bool)] = [:]
        var bytes: Int { tiles.values.reduce(0) { $0 + $1.count } }
    }
    private struct Preview {
        var rect: PixelRect
        var pixels: [UInt8]
        var tiles: [Int: [UInt8]]
        var mask: [Int: [UInt8]]
    }
    private var undoStack: [Snapshot] = []
    private var undoBytes = 0
    private var stroke: Snapshot?
    /// Strongest touch of the running stroke per pixel, per tile (`tileSize²`, or less at the edges).
    private var strokeMask: [Int: [UInt8]] = [:]
    private var strokeColor = 0
    private var strokeKind = BrushKind.brush
    private var strokeRadius = 1.0
    private var lastPoint: CGPoint?
    private var lastPressure = 1.0
    private var preview: Preview?

    var canUndo: Bool { !undoStack.isEmpty }
    var isStroking: Bool { stroke != nil }

    /// `colors` is what `colorData()` returned earlier; without it all paint has its template colour.
    init(template: Template, png: Data? = nil, colors: Data? = nil) {
        self.template = template
        width = template.width * Self.scale
        height = template.height * Self.scale
        planeSize = width * height
        pixels = [UInt8](repeating: 0, count: planeSize * Self.planes)
        let n = planeSize
        for y in 0..<height {
            let grow = (y >> 1) * template.width
            for x in 0..<width {
                let c = template.colorOfPixel[grow + (x >> 1)]
                pixels[n + y * width + x] = c
                pixels[3 * n + y * width + x] = c
            }
        }
        for i in (2 * n)..<(3 * n) { pixels[i] = Self.neutralShade }

        let fields = template.sizeOfField.count, colorCount = template.palette.count
        paintedOfField = [Int32](repeating: 0, count: fields)
        fieldComplete = [Bool](repeating: false, count: fields)
        paintedOfColor = [Int](repeating: 0, count: colorCount)
        sizeOfColor = [Int](repeating: 0, count: colorCount)
        completeFieldsOfColor = [Int](repeating: 0, count: colorCount)
        fieldsOfColor = [Int](repeating: 0, count: colorCount)

        for f in 0..<fields {
            let c = Int(template.colorOfField[f]), size = Int(template.sizeOfField[f])
            sizeOfColor[c] += size
            fieldsOfColor[c] += 1
            totalSize += size
        }

        if let png {
            if let colors { loadColors(colors) }
            load(png)
        }
    }

    // MARK: Progress

    func progress(ofColor c: Int) -> Double {
        sizeOfColor[c] == 0 ? 1 : Double(paintedOfColor[c]) / Double(sizeOfColor[c])
    }
    var progress: Double { totalSize == 0 ? 1 : Double(totalPainted) / Double(totalSize) }
    func isColorComplete(_ c: Int) -> Bool { completeFieldsOfColor[c] == fieldsOfColor[c] }
    var completedColors: Set<Int> { Set(sizeOfColor.indices.filter(isColorComplete)) }
    var isComplete: Bool { sizeOfColor.indices.allSatisfy(isColorComplete) }

    /// What a field adds to the progress: all of it once done, so a finished picture reads 100 %
    /// even though the last bits of each field are left to the painter.
    private func credit(_ f: Int) -> Int { Int(fieldComplete[f] ? template.sizeOfField[f] : paintedOfField[f]) }

    private func addCredit(_ f: Int, since old: Int) {
        let delta = credit(f) - old
        paintedOfColor[Int(template.colorOfField[f])] += delta
        totalPainted += delta
    }

    private func setPainted(_ f: Int, _ value: Int32) {
        let old = credit(f)
        paintedOfField[f] = value
        addCredit(f, since: old)
    }

    private func setComplete(_ f: Int, _ value: Bool) {
        guard fieldComplete[f] != value else { return }
        let old = credit(f)
        fieldComplete[f] = value
        completeFieldsOfColor[Int(template.colorOfField[f])] += value ? 1 : -1
        addCredit(f, since: old)
    }

    // MARK: Stroke API (points in paint pixels)

    /// `radius` in paint pixels; it stays fixed for the stroke.
    func beginStroke(color: Int, radius: Double, kind: BrushKind = .brush) {
        if stroke != nil { _ = endStroke() }
        stroke = Snapshot()
        strokeMask = [:]
        strokeColor = color
        strokeKind = kind
        strokeRadius = max(0.75, radius) * kind.radiusFactor
        lastPoint = nil
        lastPressure = 1
    }

    /// Commits a segment chain through `points` and shows `predicted` as a temporary preview that
    /// never counts towards progress, undo or export. `pressures` (0...1, one per point; missing ones
    /// keep the last) steer how much the airbrush and the shading tools give, and how dense the
    /// crayon is.
    func continueStroke(_ points: [CGPoint], pressures: [Double] = [], predicted: [CGPoint] = []) -> StrokeChange {
        guard stroke != nil else { return StrokeChange() }
        var change = StrokeChange(dirty: clearPreview())
        var touched = Set<Int32>()
        for (k, p) in points.enumerated() {
            let pressure = k < pressures.count ? min(1, max(0, pressures[k])) : lastPressure
            let from = lastPoint ?? p, fromPressure = lastPoint == nil ? pressure : lastPressure
            change.dirty = rasterize(from: from, to: p, pressure: (fromPressure, pressure), commit: true, touched: &touched)
                .map { $0.union(change.dirty) } ?? change.dirty
            lastPoint = p
            lastPressure = pressure
        }
        updateCompletion(touched, into: &change)
        if var a = lastPoint, !predicted.isEmpty {
            // Back up the whole area first so the preview can be taken back byte-exactly.
            let bound = predicted.reduce(boundsOfSegment(a, a)) { $0.union(boundsOfSegment($1, $1)) }
            if !bound.isEmpty {
                preview = Preview(rect: bound, pixels: copy(bound), tiles: stroke?.tiles ?? [:], mask: strokeMask)
                var ignored = Set<Int32>()
                for p in predicted {
                    _ = rasterize(from: a, to: p, pressure: (lastPressure, lastPressure), commit: false, touched: &ignored)
                    a = p
                }
                change.dirty = bound.union(change.dirty)
            }
        }
        return change
    }

    /// Finishes the stroke (keeps what was painted) and pushes one undo step if anything changed.
    func endStroke() -> StrokeChange {
        var change = StrokeChange(dirty: clearPreview())
        if let s = stroke, !s.tiles.isEmpty {
            undoStack.append(s)
            undoBytes += s.bytes
            while undoStack.count > Self.maxUndo || (undoBytes > Self.maxUndoBytes && undoStack.count > 1) {
                undoBytes -= undoStack.removeFirst().bytes
            }
            change.committed = true
        }
        stroke = nil
        strokeMask = [:]
        lastPoint = nil
        return change
    }

    /// Reverts the running stroke completely (used when a second finger turns it into a pinch).
    func cancelStroke() -> PixelRect? {
        let dirty = clearPreview()
        guard let s = stroke else { return dirty }
        stroke = nil
        strokeMask = [:]
        lastPoint = nil
        return restore(s).union(dirty)
    }

    func undo() -> PixelRect? {
        guard stroke == nil, let s = undoStack.popLast() else { return nil }
        undoBytes -= s.bytes
        return restore(s)
    }

    private func restore(_ s: Snapshot) -> PixelRect {
        var dirty = PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)
        for (index, tile) in s.tiles {
            let r = tileRect(index)
            paste(tile, into: r)
            dirty = dirty.union(r)
        }
        for (f, old) in s.fields {
            setPainted(Int(f), old.painted)
            setComplete(Int(f), old.complete)
        }
        return dirty
    }

    // MARK: Rasterizing

    private func boundsOfSegment(_ a: CGPoint, _ b: CGPoint) -> PixelRect {
        let r = strokeRadius + 1
        return PixelRect(x0: max(0, Int((min(a.x, b.x) - r).rounded(.down))),
                         y0: max(0, Int((min(a.y, b.y) - r).rounded(.down))),
                         x1: min(width, Int((max(a.x, b.x) + r).rounded(.up))),
                         y1: min(height, Int((max(a.y, b.y) + r).rounded(.up))))
    }

    /// One paint pixel, all planes.
    struct Pixel: Equatable {
        var coverage: UInt8, color: UInt8, shade: UInt8, under: UInt8, mix: UInt8
    }

    /// How strongly a round-capped segment touches a pixel `distance` away from it (0...1).
    static func touch(_ kind: BrushKind, distance d: Double, radius r: Double, pressure p: Double, x: Int, y: Int) -> Double {
        let edge = min(1, max(0, r + 0.5 - d))
        switch kind {
        case .brush:
            return edge
        case .crayon:
            guard edge > 0 else { return 0 }
            // Paper grain: harder pressure reaches deeper into it.
            let g = Double(grain[(y & (grainSize - 1)) * grainSize + (x & (grainSize - 1))]) + (p - 0.6) * 0.5
            return edge * (0.1 + 0.9 * smoothstep(0.12, 0.5, g))
        case .airbrush, .shadow, .light:
            let q = min(1, d / (r + 0.5)), bump = (1 - q * q) * (1 - q * q)
            return bump * p * (kind == .airbrush ? 0.45 : 0.4)
        }
    }

    /// `amount` of colour `color` laid on top of `old`. The result is the old paint seen through the
    /// new one: coverage only grows, and a pixel keeps the two strongest colours of the mix.
    ///
    /// `opaque` paint (the brush) only draws a shape, its soft edge is how much of the pixel the shape
    /// covers: over the same colour the larger coverage wins instead of adding up, so going over
    /// finished paint with its own colour changes nothing.
    static func paint(_ color: UInt8, amount: UInt8, over old: Pixel, opaque: Bool) -> Pixel {
        guard old.coverage > 0 else {
            return Pixel(coverage: amount, color: color, shade: neutralShade, under: color, mix: 0)
        }
        let s = Double(amount) / 255, c0 = Double(old.coverage) / 255
        let shade = UInt8((Double(old.shade) + (Double(neutralShade) - Double(old.shade)) * s).rounded())
        if opaque && old.color == color && old.mix == 0 {
            return Pixel(coverage: max(old.coverage, amount), color: color, shade: shade, under: color, mix: 0)
        }
        let c = c0 + (1 - c0) * s
        let fresh = s / c                                  // share of the new paint in the result
        let m0 = Double(old.mix) / 255
        var new = fresh, top = (1 - fresh) * (1 - m0), under = (1 - fresh) * m0
        if old.color == color { new += top; top = 0 }
        if old.under == color { new += under; under = 0 }
        // A third colour folds into the stronger of the two old ones.
        let other = top >= under ? old.color : old.under, otherShare = top + under
        let coverage = UInt8((c * 255).rounded())
        if new >= otherShare {
            return Pixel(coverage: coverage, color: color, shade: shade,
                         under: otherShare > 0 ? other : color, mix: UInt8((otherShare * 255).rounded()))
        }
        return Pixel(coverage: coverage, color: other, shade: shade, under: color, mix: UInt8((new * 255).rounded()))
    }

    /// Moves the shade of existing paint `amount` of the way towards darkest or lightest.
    static func shade(_ old: Pixel, amount: UInt8, darker: Bool) -> Pixel {
        guard old.coverage > 0 else { return old }
        var p = old
        let target = darker ? 0.0 : 255.0
        p.shade = UInt8((Double(old.shade) + (target - Double(old.shade)) * Double(amount) / 255).rounded())
        return p
    }

    /// Lays a round-capped segment into the stroke mask and mixes every pixel it raised anew from
    /// what was there before the stroke.
    private func rasterize(from a: CGPoint, to b: CGPoint, pressure: (Double, Double), commit: Bool,
                           touched: inout Set<Int32>) -> PixelRect? {
        let box = boundsOfSegment(a, b)
        guard !box.isEmpty, strokeColor < template.palette.count, stroke != nil else { return nil }
        let saved = saveTiles(box)
        let r = strokeRadius, ax = Double(a.x), ay = Double(a.y)
        let dx = Double(b.x) - ax, dy = Double(b.y) - ay
        let len2 = dx * dx + dy * dy
        let gw = template.width, color = UInt8(strokeColor), w = width, n = planeSize, kind = strokeKind
        let t = Self.tileSize
        var changed = false
        for ty in (box.y0 / t)...((box.y1 - 1) / t) {
            for tx in (box.x0 / t)...((box.x1 - 1) / t) {
                let index = ty * tilesPerRow + tx
                guard let original = stroke?.tiles[index] else { continue }
                let tr = tileRect(index), tw = tr.x1 - tr.x0, area = tw * (tr.y1 - tr.y0)
                var mask = strokeMask.removeValue(forKey: index) ?? [UInt8](repeating: 0, count: area)
                template.colorOfPixel.withUnsafeBufferPointer { colorOf in
                template.fieldOfPixel.withUnsafeBufferPointer { fieldOf in
                pixels.withUnsafeMutableBufferPointer { px in
                    for y in max(box.y0, tr.y0)..<min(box.y1, tr.y1) {
                        let py = Double(y) + 0.5, grow = (y >> 1) * gw
                        for x in max(box.x0, tr.x0)..<min(box.x1, tr.x1) {
                            let px0 = Double(x) + 0.5
                            var u = len2 > 0 ? ((px0 - ax) * dx + (py - ay) * dy) / len2 : 0
                            u = min(1, max(0, u))
                            let ex = px0 - ax - u * dx, ey = py - ay - u * dy
                            let p = pressure.0 + (pressure.1 - pressure.0) * u
                            let amount = UInt8(Self.touch(kind, distance: (ex * ex + ey * ey).squareRoot(), radius: r,
                                                          pressure: p, x: x, y: y) * 255)
                            let li = (y - tr.y0) * tw + (x - tr.x0)
                            guard amount > mask[li] else { continue }
                            mask[li] = amount
                            let before = Pixel(coverage: original[li], color: original[area + li], shade: original[2 * area + li],
                                               under: original[3 * area + li], mix: original[4 * area + li])
                            let next = kind.isShading ? Self.shade(before, amount: amount, darker: kind == .shadow)
                                                      : Self.paint(color, amount: amount, over: before, opaque: kind == .brush)
                            let i = y * w + x
                            let now = Pixel(coverage: px[i], color: px[n + i], shade: px[2 * n + i],
                                            under: px[3 * n + i], mix: px[4 * n + i])
                            guard next != now else { continue }
                            px[i] = next.coverage
                            px[n + i] = next.color
                            px[2 * n + i] = next.shade
                            px[3 * n + i] = next.under
                            px[4 * n + i] = next.mix
                            changed = true
                            // A grid pixel counts as painted when the paint pixel at its centre is
                            // covered and mostly the right colour.
                            if commit && x & 1 == 1 && y & 1 == 1 {
                                let gi = grow + (x >> 1), right = colorOf[gi]
                                let was = now.coverage >= Self.covered && now.color == right
                                let isNow = next.coverage >= Self.covered && next.color == right
                                if was != isNow {
                                    let field = Int(fieldOf[gi]), field32 = Int32(field)
                                    if stroke?.fields[field32] == nil {
                                        stroke?.fields[field32] = (paintedOfField[field], fieldComplete[field])
                                    }
                                    setPainted(field, paintedOfField[field] + (isNow ? 1 : -1))
                                    touched.insert(field32)
                                }
                            }
                        }
                    }
                }}}
                strokeMask[index] = mask
            }
        }
        // Drop snapshots nobody needed, so strokes that change nothing leave no undo step.
        if commit && !changed { saved.forEach { stroke?.tiles[$0] = nil } }
        return changed ? box : nil
    }

    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Paper grain for the crayon, tiled over the picture: soft blobs plus fine speckle, evened out
    /// so that a threshold of 0.3 means "30 % of the paper".
    private static let grainSize = 128
    private static let grain: [Float] = {
        let n = grainSize, cell = 4, cells = n / cell
        func hash(_ x: Int, _ y: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            h = (h ^ (h >> 13)) &* 1_274_126_177
            h ^= h >> 16
            return Float(h & 0xffff) / 65535
        }
        func node(_ cx: Int, _ cy: Int) -> Float { hash(cx % cells + 1000, cy % cells + 7) }
        var raw = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let x0 = x / cell, y0 = y / cell
                var fx = Float(x % cell) / Float(cell), fy = Float(y % cell) / Float(cell)
                fx = fx * fx * (3 - 2 * fx)
                fy = fy * fy * (3 - 2 * fy)
                let top = node(x0, y0) * (1 - fx) + node(x0 + 1, y0) * fx
                let bottom = node(x0, y0 + 1) * (1 - fx) + node(x0 + 1, y0 + 1) * fx
                raw[y * n + x] = 0.55 * (top * (1 - fy) + bottom * fy) + 0.45 * hash(x, y)
            }
        }
        var out = [Float](repeating: 0, count: n * n)
        for (rank, i) in raw.indices.sorted(by: { raw[$0] < raw[$1] }).enumerated() {
            out[i] = Float(rank) / Float(n * n - 1)
        }
        return out
    }()

    /// A field counts as done when at most a tenth of it (and in tiny fields one grid pixel) still
    /// lacks its colour. Nothing gets filled in: what the picture shows is exactly what was painted.
    static func isDone(painted: Int32, size: Int32) -> Bool {
        let missing = Int(size - painted)
        return painted > 0 && (missing <= 1 || missing * 10 <= Int(size))
    }

    /// Re-checks fields whose count changed: newly done ones are reported, painted-over ones reopen.
    private func updateCompletion(_ fields: Set<Int32>, into change: inout StrokeChange) {
        for field in fields.sorted() {
            let f = Int(field)
            let done = Self.isDone(painted: paintedOfField[f], size: template.sizeOfField[f])
            guard done != fieldComplete[f] else { continue }
            setComplete(f, done)
            guard done else { continue }
            change.completedFields.append(field)
            let c = Int(template.colorOfField[f])
            if isColorComplete(c) { change.completedColors.append(c) }
        }
    }

    // MARK: Tiles, preview

    private var tilesPerRow: Int { (width + Self.tileSize - 1) / Self.tileSize }

    private func tileRect(_ index: Int) -> PixelRect {
        let t = Self.tileSize, tx = index % tilesPerRow, ty = index / tilesPerRow
        return PixelRect(x0: tx * t, y0: ty * t, x1: min(width, tx * t + t), y1: min(height, ty * t + t))
    }

    /// Snapshots tiles not yet saved in this stroke; returns the newly saved ones.
    @discardableResult private func saveTiles(_ r: PixelRect) -> [Int] {
        guard stroke != nil, !r.isEmpty else { return [] }
        let t = Self.tileSize
        var added: [Int] = []
        for ty in (r.y0 / t)...((r.y1 - 1) / t) {
            for tx in (r.x0 / t)...((r.x1 - 1) / t) {
                let index = ty * tilesPerRow + tx
                if stroke!.tiles[index] == nil { stroke!.tiles[index] = copy(tileRect(index)); added.append(index) }
            }
        }
        return added
    }

    /// All planes of `r`, plane after plane.
    private func copy(_ r: PixelRect) -> [UInt8] {
        let rw = r.x1 - r.x0
        var out = [UInt8](); out.reserveCapacity(rw * (r.y1 - r.y0) * Self.planes)
        for p in 0..<Self.planes {
            let base = p * planeSize
            for y in r.y0..<r.y1 { out.append(contentsOf: pixels[(base + y * width + r.x0)..<(base + y * width + r.x1)]) }
        }
        return out
    }

    private func paste(_ src: [UInt8], into r: PixelRect) {
        Self.paste(src, into: r, of: &pixels, width: width, planeSize: planeSize, planes: Self.planes)
    }

    /// Writes the first `planes` planes of `src` (as `copy` makes them) into `buffer`.
    private static func paste(_ src: [UInt8], into r: PixelRect, of buffer: inout [UInt8], width: Int, planeSize: Int,
                              planes: Int) {
        let rw = r.x1 - r.x0, area = rw * (r.y1 - r.y0)
        for p in 0..<planes {
            for y in r.y0..<r.y1 {
                let from = p * area + (y - r.y0) * rw, to = p * planeSize + y * width + r.x0
                buffer.replaceSubrange(to..<(to + rw), with: src[from..<(from + rw)])
            }
        }
    }

    private func clearPreview() -> PixelRect? {
        guard let p = preview else { return nil }
        paste(p.pixels, into: p.rect)
        stroke?.tiles = p.tiles
        strokeMask = p.mask
        preview = nil
        return p.rect
    }

    /// All planes without the prediction preview.
    private func committedPixels() -> [UInt8] {
        var out = pixels
        if let p = preview {   // never export predictions
            Self.paste(p.pixels, into: p.rect, of: &out, width: width, planeSize: planeSize, planes: Self.planes)
        }
        return out
    }

    // MARK: Rendering

    /// Factor towards black (`dark`) or share towards white (`light`) per shade, out of 255:
    /// darkest keeps 40 % of the colour, lightest goes 60 % of the way to white.
    private static let shadeDark: [Int] = (0..<256).map { $0 < 128 ? 255 - (128 - $0) * 153 / 128 : 255 }
    private static let shadeLight: [Int] = (0..<256).map { $0 > 128 ? ($0 - 128) * 153 / 127 : 0 }

    /// Premultiplied RGBA image of a part of the paint layer.
    func makeImage(_ r: PixelRect) -> CGImage? {
        guard !r.isEmpty else { return nil }
        let rw = r.x1 - r.x0, rh = r.y1 - r.y0
        let rgb = template.palette.map { [Int($0.r), Int($0.g), Int($0.b)] }
        let n = planeSize, dark = Self.shadeDark, light = Self.shadeLight
        var data = Data(count: rw * rh * 4)
        data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            pixels.withUnsafeBufferPointer { px in
                var o = 0
                for y in r.y0..<r.y1 {
                    for x in r.x0..<r.x1 {
                        let i = y * width + x
                        let a = Int(px[i])
                        if a > 0 {
                            let c = rgb[Int(px[n + i])], m = Int(px[4 * n + i])
                            let s = Int(px[2 * n + i]), d = dark[s], l = light[s]
                            let u = m > 0 ? rgb[Int(px[3 * n + i])] : c
                            for k in 0..<3 {
                                var v = m > 0 ? (c[k] * (255 - m) + u[k] * m + 127) / 255 : c[k]
                                v = v * d / 255
                                v += (255 - v) * l / 255
                                out[o + k] = UInt8((v * a + 127) / 255)
                            }
                            out[o + 3] = UInt8(a)
                        }
                        o += 4
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: rw, height: rh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rw * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: PNG (8-bit grey coverage, not a viewable picture)

    func pngData() -> Data {
        var clean = plane(.coverage)
        if let p = preview {   // never export predictions
            Self.paste(p.pixels, into: p.rect, of: &clean, width: width, planeSize: planeSize, planes: 1)
        }
        let data = Data(clean)
        let out = NSMutableData()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return out as Data
    }

    /// Colour, shade and mix of the paint (zlib), or nil while every bit of paint has its template
    /// colour, unshaded and unmixed. Only colours: the colour plane; otherwise the colour, shade,
    /// under and mix planes back to back.
    func colorData() -> Data? {
        let px = committedPixels(), n = planeSize, gw = template.width
        var foreign = false, extra = false
        scan: for y in 0..<height {
            let grow = (y >> 1) * gw
            for x in 0..<width {
                let i = y * width + x
                guard px[i] > 0 else { continue }
                if px[n + i] != template.colorOfPixel[grow + (x >> 1)] { foreign = true }
                if px[2 * n + i] != Self.neutralShade || px[4 * n + i] != 0 { extra = true; break scan }
            }
        }
        guard foreign || extra else { return nil }
        let body = Data(px[n..<((extra ? 5 : 2) * n)])
        return try? (body as NSData).compressed(using: .zlib) as Data
    }

    /// Accepts only data of exactly this layer's size and palette; anything else is ignored.
    private func loadColors(_ data: Data) {
        let n = planeSize, palette = template.palette.count
        guard let raw = try? (data as NSData).decompressed(using: .zlib) as Data,
              raw.count == n || raw.count == 4 * n else { return }
        let bytes = [UInt8](raw)
        guard bytes[0..<n].allSatisfy({ Int($0) < palette }) else { return }
        if bytes.count == 4 * n {
            guard bytes[(2 * n)..<(3 * n)].allSatisfy({ Int($0) < palette }) else { return }
        }
        pixels.replaceSubrange(n..<(n + bytes.count), with: bytes)
    }

    /// Accepts only a PNG of exactly this layer's size; anything else leaves the layer blank.
    private func load(_ png: Data) {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width == width, image.height == height else { return }
        var coverage = [UInt8](repeating: 0, count: planeSize)
        if image.bitsPerPixel == 8, image.bitsPerComponent == 8,
           let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            // Raw bytes: drawing into a context could apply colour conversion and break exactness.
            let row = image.bytesPerRow
            for y in 0..<height {
                for x in 0..<width { coverage[y * width + x] = bytes[y * row + x] }
            }
        } else {
            let ok = coverage.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            if !ok { return }
        }
        pixels.replaceSubrange(0..<planeSize, with: coverage)
        recount()
    }

    private func recount() {
        let gw = template.width, s = Self.scale, n = planeSize
        var counts = [Int32](repeating: 0, count: paintedOfField.count)
        for gy in 0..<template.height {
            for gx in 0..<gw {
                let i = (gy * s + 1) * width + gx * s + 1
                guard pixels[i] >= Self.covered, pixels[n + i] == template.colorOfPixel[gy * gw + gx] else { continue }
                counts[Int(template.fieldOfPixel[gy * gw + gx])] += 1
            }
        }
        for f in counts.indices {
            setPainted(f, counts[f])
            setComplete(f, Self.isDone(painted: counts[f], size: template.sizeOfField[f]))
        }
    }
}
