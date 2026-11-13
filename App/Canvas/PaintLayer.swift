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

/// The paint bitmap and all progress bookkeeping, without any UIKit.
///
/// Per paint pixel the layer stores *coverage* (alpha 0...255) and the palette index of the paint
/// (`paintColor`). Paint goes anywhere, across field borders and over finished fields; a wrong
/// colour does not count as painted. Nothing is ever filled in automatically: a field counts as
/// done once almost all of it carries its colour, and painting over it can undo that again.
final class PaintLayer {
    /// Paint pixels per grid pixel (as in the web prototype).
    static let scale = 2
    static let tileSize = 64          // undo snapshot granularity, paint pixels
    static let maxUndo = 50
    private static let covered: UInt8 = 128

    let template: Template
    let width: Int, height: Int       // paint pixels
    private(set) var coverage: [UInt8]
    /// Palette index of the paint per paint pixel; only meaningful where `coverage > 0`.
    private(set) var paintColor: [UInt8]

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
        var tiles: [Int: [UInt8]] = [:]
        var fields: [Int32: (painted: Int32, complete: Bool)] = [:]
    }
    private var undoStack: [Snapshot] = []
    private var stroke: Snapshot?
    private var strokeColor = 0
    private var strokeRadius = 1.0
    private var lastPoint: CGPoint?
    private var preview: (rect: PixelRect, pixels: [UInt8])?

    var canUndo: Bool { !undoStack.isEmpty }
    var isStroking: Bool { stroke != nil }

    /// `colors` is what `colorData()` returned earlier; without it all paint has its template colour.
    init(template: Template, png: Data? = nil, colors: Data? = nil) {
        self.template = template
        width = template.width * Self.scale
        height = template.height * Self.scale
        coverage = [UInt8](repeating: 0, count: width * height)
        paintColor = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let grow = (y >> 1) * template.width
            for x in 0..<width { paintColor[y * width + x] = template.colorOfPixel[grow + (x >> 1)] }
        }

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
    func beginStroke(color: Int, radius: Double) {
        if stroke != nil { _ = endStroke() }
        stroke = Snapshot()
        strokeColor = color
        strokeRadius = max(0.75, radius)
        lastPoint = nil
    }

    /// Commits a segment chain through `points` and shows `predicted` as a temporary preview that
    /// never counts towards progress, undo or export.
    func continueStroke(_ points: [CGPoint], predicted: [CGPoint] = []) -> StrokeChange {
        guard stroke != nil else { return StrokeChange() }
        var change = StrokeChange(dirty: clearPreview())
        var touched = Set<Int32>()
        for p in points {
            change.dirty = rasterize(from: lastPoint ?? p, to: p, commit: true, touched: &touched)
                .map { $0.union(change.dirty) } ?? change.dirty
            lastPoint = p
        }
        updateCompletion(touched, into: &change)
        if var a = lastPoint, !predicted.isEmpty {
            // Back up the whole area first so the preview can be taken back byte-exactly.
            let bound = predicted.reduce(boundsOfSegment(a, a)) { $0.union(boundsOfSegment($1, $1)) }
            if !bound.isEmpty {
                preview = (bound, copy(bound))
                var ignored = Set<Int32>()
                for p in predicted {
                    _ = rasterize(from: a, to: p, commit: false, touched: &ignored)
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
            if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
            change.committed = true
        }
        stroke = nil
        lastPoint = nil
        return change
    }

    /// Reverts the running stroke completely (used when a second finger turns it into a pinch).
    func cancelStroke() -> PixelRect? {
        let dirty = clearPreview()
        guard let s = stroke else { return dirty }
        stroke = nil
        lastPoint = nil
        return restore(s).union(dirty)
    }

    func undo() -> PixelRect? {
        guard stroke == nil, let s = undoStack.popLast() else { return nil }
        return restore(s)
    }

    private func restore(_ s: Snapshot) -> PixelRect {
        var dirty = PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)
        for (index, pixels) in s.tiles {
            let r = tileRect(index)
            paste(pixels, into: r)
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

    /// Anti-aliased round-capped segment. Paint of the same colour is max-combined; another colour
    /// is painted over where the new paint is solid enough.
    private func rasterize(from a: CGPoint, to b: CGPoint, commit: Bool, touched: inout Set<Int32>) -> PixelRect? {
        let box = boundsOfSegment(a, b)
        guard !box.isEmpty, strokeColor < template.palette.count else { return nil }
        let saved = commit ? saveTiles(box) : []
        let r = strokeRadius, ax = Double(a.x), ay = Double(a.y)
        let dx = Double(b.x) - ax, dy = Double(b.y) - ay
        let len2 = dx * dx + dy * dy
        let gw = template.width, color = UInt8(strokeColor), w = width
        var changed = false
        template.colorOfPixel.withUnsafeBufferPointer { colorOf in
        template.fieldOfPixel.withUnsafeBufferPointer { fieldOf in
        paintColor.withUnsafeMutableBufferPointer { col in
        coverage.withUnsafeMutableBufferPointer { cov in
            for y in box.y0..<box.y1 {
                let py = Double(y) + 0.5, grow = (y >> 1) * gw
                for x in box.x0..<box.x1 {
                    let gi = grow + (x >> 1)
                    let px = Double(x) + 0.5
                    var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
                    t = min(1, max(0, t))
                    let ex = px - ax - t * dx, ey = py - ay - t * dy
                    let a = min(1, r + 0.5 - (ex * ex + ey * ey).squareRoot())
                    guard a > 0 else { continue }
                    let new = UInt8(a * 255)
                    let i = y * w + x, old = cov[i], oldColor = col[i]
                    if old == 0 || oldColor == color {
                        guard new > old else { continue }
                    } else {
                        // A soft brush edge must not wash out solid paint of another colour.
                        guard new >= Self.covered || new > old else { continue }
                    }
                    let field = Int(fieldOf[gi])
                    cov[i] = new
                    col[i] = color
                    changed = true
                    // A grid pixel counts as painted when the paint pixel at its centre is covered
                    // with the right colour.
                    if commit && x & 1 == 1 && y & 1 == 1 {
                        let right = colorOf[gi]
                        let was = old >= Self.covered && oldColor == right
                        let now = new >= Self.covered && color == right
                        if was != now {
                            let field32 = Int32(field)
                            if stroke?.fields[field32] == nil {
                                stroke?.fields[field32] = (paintedOfField[field], fieldComplete[field])
                            }
                            setPainted(field, paintedOfField[field] + (now ? 1 : -1))
                            touched.insert(field32)
                        }
                    }
                }
            }
        }}}}
        // Drop snapshots nobody needed, so strokes that change nothing leave no undo step.
        if !changed { saved.forEach { stroke?.tiles[$0] = nil } }
        return changed ? box : nil
    }

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

    /// Coverage of `r`, followed by the paint colours of `r`.
    private func copy(_ r: PixelRect) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity((r.x1 - r.x0) * (r.y1 - r.y0) * 2)
        for y in r.y0..<r.y1 { out.append(contentsOf: coverage[(y * width + r.x0)..<(y * width + r.x1)]) }
        for y in r.y0..<r.y1 { out.append(contentsOf: paintColor[(y * width + r.x0)..<(y * width + r.x1)]) }
        return out
    }

    private func paste(_ pixels: [UInt8], into r: PixelRect) {
        let half = pixels.count / 2
        Self.paste(pixels[..<half], into: r, of: &coverage, width: width)
        Self.paste(pixels[half...], into: r, of: &paintColor, width: width)
    }

    private static func paste(_ pixels: ArraySlice<UInt8>, into r: PixelRect, of buffer: inout [UInt8], width: Int) {
        let rw = r.x1 - r.x0
        for y in r.y0..<r.y1 {
            let src = pixels.startIndex + (y - r.y0) * rw
            buffer.replaceSubrange((y * width + r.x0)..<(y * width + r.x1), with: pixels[src..<(src + rw)])
        }
    }

    private func clearPreview() -> PixelRect? {
        guard let p = preview else { return nil }
        paste(p.pixels, into: p.rect)
        preview = nil
        return p.rect
    }

    // MARK: Rendering

    /// Premultiplied RGBA image of a part of the paint layer.
    func makeImage(_ r: PixelRect) -> CGImage? {
        guard !r.isEmpty else { return nil }
        let rw = r.x1 - r.x0, rh = r.y1 - r.y0
        let rgb = template.palette.map { [Int($0.r), Int($0.g), Int($0.b)] }
        var data = Data(count: rw * rh * 4)
        data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            coverage.withUnsafeBufferPointer { cov in
                paintColor.withUnsafeBufferPointer { colorOf in
                    var o = 0
                    for y in r.y0..<r.y1 {
                        for x in r.x0..<r.x1 {
                            let a = Int(cov[y * width + x])
                            if a > 0 {
                                let c = rgb[Int(colorOf[y * width + x])]
                                out[o] = UInt8((c[0] * a + 127) / 255)
                                out[o + 1] = UInt8((c[1] * a + 127) / 255)
                                out[o + 2] = UInt8((c[2] * a + 127) / 255)
                                out[o + 3] = UInt8(a)
                            }
                            o += 4
                        }
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
        var clean = coverage
        if let p = preview {   // never export predictions
            Self.paste(p.pixels[..<(p.pixels.count / 2)], into: p.rect, of: &clean, width: width)
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

    /// The paint colours (zlib), or nil while every bit of paint has its template colour.
    func colorData() -> Data? {
        var cov = coverage, col = paintColor
        if let p = preview {   // never export predictions
            let half = p.pixels.count / 2
            Self.paste(p.pixels[..<half], into: p.rect, of: &cov, width: width)
            Self.paste(p.pixels[half...], into: p.rect, of: &col, width: width)
        }
        let gw = template.width
        let foreign = (0..<height).contains { y in
            let grow = (y >> 1) * gw
            return (0..<width).contains { x in
                let i = y * width + x
                return cov[i] > 0 && col[i] != template.colorOfPixel[grow + (x >> 1)]
            }
        }
        guard foreign else { return nil }
        return try? (Data(col) as NSData).compressed(using: .zlib) as Data
    }

    /// Accepts only colours of exactly this layer's size and palette; anything else is ignored.
    private func loadColors(_ data: Data) {
        guard let raw = try? (data as NSData).decompressed(using: .zlib) as Data,
              raw.count == width * height, raw.allSatisfy({ Int($0) < template.palette.count }) else { return }
        paintColor = [UInt8](raw)
    }

    /// Accepts only a PNG of exactly this layer's size; anything else leaves the layer blank.
    private func load(_ png: Data) {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width == width, image.height == height else { return }
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
        recount()
    }

    private func recount() {
        let gw = template.width, s = Self.scale
        var counts = [Int32](repeating: 0, count: paintedOfField.count)
        for gy in 0..<template.height {
            for gx in 0..<gw {
                let i = (gy * s + 1) * width + gx * s + 1
                guard coverage[i] >= Self.covered, paintColor[i] == template.colorOfPixel[gy * gw + gx] else { continue }
                counts[Int(template.fieldOfPixel[gy * gw + gx])] += 1
            }
        }
        for f in counts.indices {
            setPainted(f, counts[f])
            setComplete(f, Self.isDone(painted: counts[f], size: template.sizeOfField[f]))
        }
    }
}
