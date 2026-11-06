// Photo → template, port of prototype/web/seg.js:
// downscale → k-means in CIELAB → 2× majority smoothing → merge small fields → compact + sort palette.
import Foundation

extension TemplateBuilder {
    static func build(rgba: [UInt8], width: Int, height: Int, options: TemplateOptions, minArea: Int?) throws -> Template {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { throw TemplateBuilderError.invalidImage }
        try Task.checkCancellation()
        let k = min(max(options.colors, 1), 64)
        let (rgb, w, h) = try downscale(rgba, width, height, maxSide: max(options.maxSide, 1))
        try Task.checkCancellation()
        var labels = try quantize(lab: toLab(rgb), k: k)
        try smooth(&labels, w, h)
        try smooth(&labels, w, h)
        try mergeSmall(&labels, w, h, k: k,
                       minArea: minArea ?? Self.minArea(detail: options.detail, width: w, height: h))
        let palette = compactAndSort(&labels, rgb: rgb, k: k)
        try Task.checkCancellation()
        return Template(width: w, height: h, palette: palette, colorOfPixel: labels)
    }

    /// Smallest field in grid pixels: 144 (12×12) at detail 0.5 on a 1000×750 grid, proportional to grid area,
    /// ×4 at detail 0 and ×¼ at detail 1. So a preview at maxSide 320 shows the same fields as the full build.
    static func minArea(detail: Double, width: Int, height: Int) -> Int {
        let d = min(max(detail, 0), 1)
        return max(4, Int((Double(width * height) * 144 / 750_000 * pow(4, 1 - 2 * d)).rounded()))
    }

    /// Area-average downscale so the longest side is at most maxSide (never upscales). Returns packed RGB.
    static func downscale(_ rgba: [UInt8], _ sw: Int, _ sh: Int, maxSide: Int) throws -> (rgb: [UInt8], w: Int, h: Int) {
        let s = min(1, Double(maxSide) / Double(max(sw, sh)))
        let w = max(1, Int((Double(sw) * s).rounded())), h = max(1, Int((Double(sh) * s).rounded()))
        var out = [UInt8](repeating: 0, count: w * h * 3)
        // Source column x falls into output column x*w/sw; every output column gets ≥ 1 source column.
        let colOf = (0..<sw).map { Int32($0 * w / sw) }
        var colCount = [Int](repeating: 0, count: w)
        for c in colOf { colCount[Int(c)] += 1 }
        var acc = [UInt64](repeating: 0, count: w * 3)
        try rgba.withUnsafeBufferPointer { src in
            try out.withUnsafeMutableBufferPointer { dst in
                try acc.withUnsafeMutableBufferPointer { acc in
                    var rows = 0
                    for y in 0..<sh {
                        if y & 63 == 0 { try Task.checkCancellation() }
                        var i = y * sw * 4
                        for x in 0..<sw {
                            let o = Int(colOf[x]) * 3
                            acc[o] += UInt64(src[i]); acc[o + 1] += UInt64(src[i + 1]); acc[o + 2] += UInt64(src[i + 2])
                            i += 4
                        }
                        rows += 1
                        let oy = y * h / sh
                        guard y == sh - 1 || (y + 1) * h / sh != oy else { continue }
                        for ox in 0..<w {
                            let n = UInt64(colCount[ox] * rows), o = ox * 3, d = (oy * w + ox) * 3
                            for c in 0..<3 { dst[d + c] = UInt8((acc[o + c] + n / 2) / n); acc[o + c] = 0 }
                        }
                        rows = 0
                    }
                }
            }
        }
        return (out, w, h)
    }

    // MARK: Colour

    private static let linear: [Float] = (0..<256).map {
        let c = Float($0) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// sRGB (D65) → CIELAB.
    static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Float, Float, Float) {
        let r = linear[Int(r)], g = linear[Int(g)], b = linear[Int(b)]
        func f(_ t: Float) -> Float { t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116 }
        let fx = f((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047)
        let fy = f(0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let fz = f((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func toLab(_ rgb: [UInt8]) throws -> [Float] {
        var out = [Float](repeating: 0, count: rgb.count)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            if i & 0xFFFF == 0 { try Task.checkCancellation() }
            (out[i], out[i + 1], out[i + 2]) = lab(rgb[i], rgb[i + 1], rgb[i + 2])
        }
        return out
    }

    // MARK: k-means

    /// k-means++ on ~20 000 samples with a fixed seed (same photo → same template), then assigns every pixel.
    static func quantize(lab: [Float], k: Int) throws -> [UInt8] {
        let n = lab.count / 3
        var seed: UInt32 = 1
        func rand() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed) / 4294967296 }
        let samples = Array(stride(from: 0, to: n, by: max(1, n / 20000)))

        func dist(_ p: Int, _ cent: [Float], _ c: Int) -> Float {
            let a = lab[p * 3] - cent[c * 3], b = lab[p * 3 + 1] - cent[c * 3 + 1], d = lab[p * 3 + 2] - cent[c * 3 + 2]
            return a * a + b * b + d * d
        }
        let first = samples[Int(rand() * Double(samples.count))]
        var cent = Array(lab[first * 3 ..< first * 3 + 3])
        var d2 = [Float](repeating: .infinity, count: samples.count)
        while cent.count < k * 3 {
            let c = cent.count / 3 - 1
            var sum = 0.0
            for s in samples.indices {
                d2[s] = min(d2[s], dist(samples[s], cent, c))
                sum += Double(d2[s])
            }
            if sum == 0 { break } // fewer distinct colours than k
            var t = rand() * sum, s = 0
            while s < samples.count - 1 { t -= Double(d2[s]); if t <= 0 { break }; s += 1 }
            cent += lab[samples[s] * 3 ..< samples[s] * 3 + 3]
        }
        let kk = cent.count / 3

        func nearest(_ p: Int) -> Int {
            var best = 0, bd = Float.infinity
            for c in 0..<kk { let d = dist(p, cent, c); if d < bd { bd = d; best = c } }
            return best
        }
        for _ in 0..<20 {
            try Task.checkCancellation()
            var acc = [Double](repeating: 0, count: kk * 4)
            for p in samples {
                let c = nearest(p) * 4
                acc[c] += Double(lab[p * 3]); acc[c + 1] += Double(lab[p * 3 + 1]); acc[c + 2] += Double(lab[p * 3 + 2]); acc[c + 3] += 1
            }
            var moved: Float = 0
            for c in 0..<kk where acc[c * 4 + 3] > 0 {
                for j in 0..<3 {
                    let v = Float(acc[c * 4 + j] / acc[c * 4 + 3])
                    moved = max(moved, abs(v - cent[c * 3 + j])); cent[c * 3 + j] = v
                }
            }
            if moved < 0.01 { break }
        }

        var labels = [UInt8](repeating: 0, count: n)
        try lab.withUnsafeBufferPointer { lab in
            try cent.withUnsafeBufferPointer { cent in
                try labels.withUnsafeMutableBufferPointer { out in
                    for p in 0..<n {
                        if p & 0xFFFF == 0 { try Task.checkCancellation() }
                        let l = lab[p * 3], a = lab[p * 3 + 1], b = lab[p * 3 + 2]
                        var best = 0, bd = Float.infinity
                        for c in 0..<kk {
                            let x = l - cent[c * 3], y = a - cent[c * 3 + 1], z = b - cent[c * 3 + 2]
                            let d = x * x + y * y + z * z
                            if d < bd { bd = d; best = c }
                        }
                        out[p] = UInt8(best)
                    }
                }
            }
        }
        return labels
    }

    // MARK: Cleanup

    /// 3×3 majority filter against pixel noise; ties keep the pixel's own colour.
    static func smooth(_ labels: inout [UInt8], _ w: Int, _ h: Int) throws {
        let src = labels
        var counts = [UInt8](repeating: 0, count: 256)
        try src.withUnsafeBufferPointer { s in
            try labels.withUnsafeMutableBufferPointer { dst in
                try counts.withUnsafeMutableBufferPointer { cnt in
                    for y in 0..<h {
                        if y & 31 == 0 { try Task.checkCancellation() }
                        let y0 = max(y - 1, 0), y1 = min(y + 1, h - 1)
                        for x in 0..<w {
                            let x0 = max(x - 1, 0), x1 = min(x + 1, w - 1)
                            for yy in y0...y1 { for xx in x0...x1 { cnt[Int(s[yy * w + xx])] += 1 } }
                            var best = s[y * w + x], top = cnt[Int(best)]
                            for yy in y0...y1 {
                                for xx in x0...x1 {
                                    let l = s[yy * w + xx]
                                    if cnt[Int(l)] > top { top = cnt[Int(l)]; best = l }
                                }
                            }
                            for yy in y0...y1 { for xx in x0...x1 { cnt[Int(s[yy * w + xx])] = 0 } }
                            dst[y * w + x] = best
                        }
                    }
                }
            }
        }
    }

    /// 4-connected regions of equal label, ids in scan order of their first pixel.
    static func components(_ labels: [UInt8], _ w: Int, _ h: Int) -> (region: [Int32], sizes: [Int32]) {
        let n = w * h
        var region = [Int32](repeating: -1, count: n)
        var stack = [Int32](repeating: 0, count: n)
        var sizes: [Int32] = []
        labels.withUnsafeBufferPointer { lab in
            region.withUnsafeMutableBufferPointer { reg in
                stack.withUnsafeMutableBufferPointer { st in
                    for p0 in 0..<n where reg[p0] < 0 {
                        let id = Int32(sizes.count), l = lab[p0]
                        var top = 1, size: Int32 = 0
                        st[0] = Int32(p0); reg[p0] = id
                        while top > 0 {
                            top -= 1
                            let p = Int(st[top]), x = p % w
                            size += 1
                            @inline(__always) func visit(_ q: Int) {
                                if reg[q] < 0 && lab[q] == l { reg[q] = id; st[top] = Int32(q); top += 1 }
                            }
                            if x > 0 { visit(p - 1) }
                            if x < w - 1 { visit(p + 1) }
                            if p >= w { visit(p - w) }
                            if p + w < n { visit(p + w) }
                        }
                        sizes.append(size)
                    }
                }
            }
        }
        return (region, sizes)
    }

    /// Recolours fields smaller than minArea with their dominant neighbour colour. Large neighbours win
    /// (weight 1000 per shared border pixel); otherwise only higher-ranked (bigger) small neighbours count,
    /// so two small fields never just swap colours. Every pass reduces the field count; stops when none is small.
    static func mergeSmall(_ labels: inout [UInt8], _ w: Int, _ h: Int, k: Int, minArea: Int) throws {
        let n = w * h, minA = Int32(minArea)
        for _ in 0..<64 {
            try Task.checkCancellation()
            let (region, sizes) = components(labels, w, h)
            guard sizes.count > 1 else { return }
            var slot = [Int32](repeating: -1, count: sizes.count)
            var small = 0
            for r in sizes.indices where sizes[r] < minA { slot[r] = Int32(small); small += 1 }
            guard small > 0 else { return }
            var votes = [Int32](repeating: 0, count: small * k)
            var target = [Int16](repeating: -1, count: small)
            try labels.withUnsafeMutableBufferPointer { lab in
                try region.withUnsafeBufferPointer { reg in
                    try sizes.withUnsafeBufferPointer { size in
                        try slot.withUnsafeBufferPointer { slot in
                            try votes.withUnsafeMutableBufferPointer { votes in
                                for p in 0..<n {
                                    if p & 0xFFFF == 0 { try Task.checkCancellation() }
                                    let r = Int(reg[p]), sl = Int(slot[r])
                                    if sl < 0 { continue }
                                    let x = p % w
                                    @inline(__always) func vote(_ q: Int) {
                                        let s = Int(reg[q])
                                        guard s != r else { return }
                                        let weight: Int32 = size[s] >= minA ? 1000
                                            : (size[s] > size[r] || (size[s] == size[r] && s > r)) ? 1 : 0
                                        votes[sl * k + Int(lab[q])] += weight
                                    }
                                    if x > 0 { vote(p - 1) }
                                    if x < w - 1 { vote(p + 1) }
                                    if p >= w { vote(p - w) }
                                    if p + w < n { vote(p + w) }
                                }
                                for sl in 0..<small {
                                    var best: Int32 = 0
                                    for c in 0..<k where votes[sl * k + c] > best { best = votes[sl * k + c]; target[sl] = Int16(c) }
                                }
                                for p in 0..<n {
                                    let sl = Int(slot[Int(reg[p])])
                                    if sl >= 0, target[sl] >= 0 { lab[p] = UInt8(target[sl]) }
                                }
                            }
                        }
                    }
                }
            }
            if !target.contains(where: { $0 >= 0 }) { return }
        }
    }

    /// Drops unused colours, sets each colour to the mean RGB of its pixels and sorts the palette:
    /// chromatic colours by hue (red → yellow → green → blue → purple), then greys light → dark.
    static func compactAndSort(_ labels: inout [UInt8], rgb: [UInt8], k: Int) -> [PaletteColor] {
        var count = [Int](repeating: 0, count: k), sum = [Int](repeating: 0, count: k * 3)
        for p in labels.indices {
            let l = Int(labels[p])
            count[l] += 1
            for c in 0..<3 { sum[l * 3 + c] += Int(rgb[p * 3 + c]) }
        }
        let used = (0..<k).filter { count[$0] > 0 }
        let colors = used.map { l in
            let m = { (c: Int) in UInt8((sum[l * 3 + c] + count[l] / 2) / count[l]) }
            return PaletteColor(r: m(0), g: m(1), b: m(2))
        }
        let keys = colors.enumerated().map { i, c -> (Int, Float, Float, Int) in
            let (l, a, b) = lab(c.r, c.g, c.b)
            if (a * a + b * b).squareRoot() < 10 { return (1, -l, 0, i) }
            let hue = atan2(b, a) * 180 / .pi
            return (0, hue < 0 ? hue + 360 : hue, l, i)
        }
        let order = keys.sorted { $0 < $1 }.map { $0.3 }
        var map = [UInt8](repeating: 0, count: k)
        for (new, i) in order.enumerated() { map[used[i]] = UInt8(new) }
        for p in labels.indices { labels[p] = map[Int(labels[p])] }
        return order.map { colors[$0] }
    }
}

/// Fields, sizes and number spots derived from the colour of every pixel (also used when decoding).
struct Fields {
    var fieldOfPixel: [Int32], colorOfField: [UInt8], sizeOfField: [Int32], spots: [NumberSpot]

    init(_ labels: [UInt8], _ w: Int, _ h: Int) {
        let n = w * h
        (fieldOfPixel, sizeOfField) = TemplateBuilder.components(labels, w, h)
        let m = sizeOfField.count
        // Chamfer distance to the nearest field border (image border counts as border).
        var d = [Float](repeating: 0, count: n)
        labels.withUnsafeBufferPointer { lab in
            d.withUnsafeMutableBufferPointer { d in
                guard w >= 3, h >= 3 else { return }
                for y in 1..<h - 1 {
                    for x in 1..<w - 1 {
                        let p = y * w + x, l = lab[p]
                        d[p] = lab[p - 1] != l || lab[p + 1] != l || lab[p - w] != l || lab[p + w] != l ? 0 : 1e9
                    }
                }
                let D = Float(2).squareRoot()
                for y in 1..<h {
                    for x in 1..<w - 1 {
                        let p = y * w + x
                        d[p] = min(d[p], d[p - 1] + 1, d[p - w] + 1, d[p - w - 1] + D, d[p - w + 1] + D)
                    }
                }
                for y in stride(from: h - 2, through: 0, by: -1) {
                    for x in stride(from: w - 2, through: 1, by: -1) {
                        let p = y * w + x
                        d[p] = min(d[p], d[p + 1] + 1, d[p + w] + 1, d[p + w + 1] + D, d[p + w - 1] + D)
                    }
                }
            }
        }
        // Spot = farthest-from-border pixel; among (near-)ties the one closest to the field's centroid.
        var color = [UInt8](repeating: 0, count: m), maxD = [Float](repeating: -1, count: m)
        var sumX = [Int](repeating: 0, count: m), sumY = [Int](repeating: 0, count: m)
        for p in 0..<n {
            let r = Int(fieldOfPixel[p])
            color[r] = labels[p]; maxD[r] = max(maxD[r], d[p]); sumX[r] += p % w; sumY[r] += p / w
        }
        var best = [Int](repeating: 0, count: m), bestDist = [Float](repeating: .infinity, count: m)
        for p in 0..<n {
            let r = Int(fieldOfPixel[p])
            guard d[p] >= maxD[r] - 0.001 else { continue }
            let size = Float(sizeOfField[r])
            let dx = Float(p % w) - Float(sumX[r]) / size, dy = Float(p / w) - Float(sumY[r]) / size
            if dx * dx + dy * dy < bestDist[r] { bestDist[r] = dx * dx + dy * dy; best[r] = p }
        }
        colorOfField = color
        spots = (0..<m).map { NumberSpot(x: best[$0] % w, y: best[$0] / w, radius: maxD[$0] + 0.5, field: Int32($0)) }
    }
}
