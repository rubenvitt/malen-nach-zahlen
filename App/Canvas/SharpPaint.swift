import Foundation

/// A copy of the paint layer's planes inside `rect`, so paint can be rendered off the main thread.
struct PaintWindow: Sendable {
    /// The window in paint pixels; always inside the layer.
    let rect: PixelRect
    /// Size of the whole layer in paint pixels; samples beyond its edge repeat the edge pixel.
    let layerWidth: Int, layerHeight: Int
    /// Coverage, colour, shade, under and mix (as `PaintLayer.Plane`), plane after plane.
    let planes: [UInt8]
    /// Palette as r, g, b, r, g, b, …
    let palette: [Float]
}

/// RGBA pixels that a `CGImage` can use without copying them. Only ever written by one owner.
final class PixelBuffer: @unchecked Sendable {
    let width: Int, height: Int
    let bytes: UnsafeMutablePointer<UInt8>
    var count: Int { width * height * 4 }
    var bytesPerRow: Int { width * 4 }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = .allocate(capacity: width * height * 4)
        bytes.initialize(repeating: 0, count: width * height * 4)
    }

    func copy() -> PixelBuffer {
        let c = PixelBuffer(width: width, height: height)
        c.bytes.update(from: bytes, count: count)
        return c
    }

    deinit { bytes.deallocate() }
}

/// Paint rendered larger than the paint layer's own pixels, with sharp edges.
///
/// Scaled up the plain way, the paint layer (2 px per grid pixel) turns blurry when zoomed in: every
/// brush edge is a soft ramp one paint pixel wide, and close up that pixel is a dozen screen pixels.
/// Here the ramps get steep again. Coverage and the share of the main colour are interpolated
/// bilinearly; where they change steeply and by a lot (the edge of a brush stroke, two colours side by
/// side), the value is pushed towards the two sides of the edge, so the edge is one output pixel wide
/// and follows the smooth contour of the interpolation. Gentle changes (airbrush, glazes, shading) stay
/// as soft as they are.
enum SharpPaint {
    /// The paint pixels a window needs so that `render` can draw `rect`.
    static func windowRect(for rect: PixelRect, layerWidth: Int, layerHeight: Int) -> PixelRect {
        PixelRect(x0: max(0, rect.x0 - 2), y0: max(0, rect.y0 - 2),
                  x1: min(layerWidth, rect.x1 + 2), y1: min(layerHeight, rect.y1 + 2))
    }

    /// Factor towards black and share towards white per shade, out of 255 (as `PaintLayer` renders).
    @inline(__always) static func dark(_ s: Float) -> Float { s < 128 ? 255 - (128 - s) * 153 / 128 : 255 }
    @inline(__always) static func light(_ s: Float) -> Float { s > 128 ? (s - 128) * 153 / 127 : 0 }

    @inline(__always) private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Pushes `v` (between `lo` and `hi`) towards `lo` or `hi`, so that a ramp with gradient `g` (per
    /// paint pixel) becomes one output pixel (`1 / scale` paint pixels) wide around its middle.
    /// `strength` (0...1) says how far to go.
    @inline(__always) static func sharpen(_ v: Float, gradient g: Float, lo: Float, hi: Float, scale: Float,
                                          strength: Float) -> Float {
        guard strength > 0 else { return v }
        let range = hi - lo
        let t = min(1, max(0, 0.5 + (v - lo - range / 2) / max(g, 1e-4) * scale))
        return v + (lo + range * t - v) * strength
    }

    /// Per window pixel: premultiplied RGBA exactly as `PaintLayer.makeImage` has it, coverage, and
    /// the lowest and highest coverage around it.
    private struct Prepared {
        var packed: [UInt32], cover: [Float], lo: [Float], hi: [Float]
    }

    private static func prepare(_ window: PaintWindow) -> Prepared {
        let ww = window.rect.x1 - window.rect.x0, wh = window.rect.y1 - window.rect.y0, n = ww * wh
        var packed = [UInt32](repeating: 0, count: n)
        var cover = [Float](repeating: 0, count: n), lo = cover, hi = cover
        window.planes.withUnsafeBufferPointer { px in
        window.palette.withUnsafeBufferPointer { palette in
        packed.withUnsafeMutableBufferPointer { packed in
        cover.withUnsafeMutableBufferPointer { cover in
        lo.withUnsafeMutableBufferPointer { lo in
        hi.withUnsafeMutableBufferPointer { hi in
            for i in 0..<n {
                let a = Int(px[i])
                cover[i] = Float(a) / 255
                guard a > 0 else { continue }
                let c = Int(px[n + i]) * 3, s = Float(px[2 * n + i]), u = Int(px[3 * n + i]) * 3, m = Int(px[4 * n + i])
                let d = Int(dark(s)), l = Int(light(s))
                var word = UInt32(a) << 24
                for k in 0..<3 {
                    let ck = Int(palette[c + k]), uk = Int(palette[u + k])
                    var v = m > 0 ? (ck * (255 - m) + uk * m + 127) / 255 : ck
                    v = v * d / 255
                    v += (255 - v) * l / 255
                    word |= UInt32((v * a + 127) / 255) << (8 * k)
                }
                packed[i] = word
            }
            for y in 0..<wh {
                let ya = max(0, y - 1), yb = min(wh - 1, y + 1)
                for x in 0..<ww {
                    let xa = max(0, x - 1), xb = min(ww - 1, x + 1)
                    var l: Float = 1, h: Float = 0
                    for yy in ya...yb {
                        for xx in xa...xb {
                            let v = cover[yy * ww + xx]
                            l = min(l, v); h = max(h, v)
                        }
                    }
                    lo[y * ww + x] = l; hi[y * ww + x] = h
                }
            }
        }}}}}}
        return Prepared(packed: packed, cover: cover, lo: lo, hi: hi)
    }

    /// Where output pixels `range` (counted from 0 at the layer's edge, `scale` per paint pixel)
    /// sample: window column/row of the two neighbours and the fraction between them. Samples beyond
    /// the layer's edge repeat the edge.
    private static func samples(_ range: Range<Int>, scale: Int, winOrigin: Int, winSize: Int,
                                layer: Int) -> [(Int, Int, Float)] {
        let sc = Float(scale)
        return range.map { o in
            let p = (Float(o) + 0.5) / sc - 0.5
            let i = Int(p.rounded(.down)), f = p - Float(i)
            let a = min(max(i, 0), layer - 1) - winOrigin, b = min(max(i + 1, 0), layer - 1) - winOrigin
            return (min(max(a, 0), winSize - 1), min(max(b, 0), winSize - 1), f)
        }
    }

    /// Renders paint pixels `rect` at `scale` output pixels per paint pixel into `out`, which shows
    /// `outRect` (paint pixels, containing `rect`) with `outBytesPerRow`. Premultiplied RGBA.
    /// `window` must contain `windowRect(for: rect, …)`.
    static func render(_ window: PaintWindow, rect: PixelRect, scale: Int, into out: UnsafeMutablePointer<UInt8>,
                       outRect: PixelRect, outBytesPerRow: Int) {
        let win = window.rect, ww = win.x1 - win.x0, wh = win.y1 - win.y0
        guard !rect.isEmpty, ww > 0, wh > 0, scale > 0 else { return }
        let n = ww * wh
        let prepared = prepare(window)
        if scale == 1 {
            // Pixel for pixel: exactly the paint layer's own pixels.
            for y in rect.y0..<rect.y1 {
                let line = out + (y - outRect.y0) * outBytesPerRow + (rect.x0 - outRect.x0) * 4
                for x in rect.x0..<rect.x1 {
                    let p = prepared.packed[(y - win.y0) * ww + (x - win.x0)], o = line + (x - rect.x0) * 4
                    o[0] = UInt8(truncatingIfNeeded: p); o[1] = UInt8(truncatingIfNeeded: p >> 8)
                    o[2] = UInt8(truncatingIfNeeded: p >> 16); o[3] = UInt8(truncatingIfNeeded: p >> 24)
                }
            }
            return
        }
        window.planes.withUnsafeBufferPointer { px in
        window.palette.withUnsafeBufferPointer { palette in
        prepared.packed.withUnsafeBufferPointer { packed in
        prepared.cover.withUnsafeBufferPointer { cover in
        prepared.lo.withUnsafeBufferPointer { lo in
        prepared.hi.withUnsafeBufferPointer { hi in
            let sc = Float(scale)
            let cols = samples((rect.x0 * scale)..<(rect.x1 * scale), scale: scale, winOrigin: win.x0, winSize: ww,
                               layer: window.layerWidth)
            let rows = samples((rect.y0 * scale)..<(rect.y1 * scale), scale: scale, winOrigin: win.y0, winSize: wh,
                               layer: window.layerHeight)
            let ox0 = (rect.x0 - outRect.x0) * scale, oy0 = (rect.y0 - outRect.y0) * scale

            for ry in 0..<rows.count {
                let row = rows[ry], r0 = row.0 * ww, r1 = row.1 * ww, fy = row.2
                let line = out + (oy0 + ry) * outBytesPerRow + ox0 * 4
                for rx in 0..<cols.count {
                    let col = cols[rx], o = line + rx * 4
                    let i0 = r0 + col.0, i1 = r0 + col.1, i2 = r1 + col.0, i3 = r1 + col.1
                    let p0 = packed[i0]
                    if p0 == packed[i1] && p0 == packed[i2] && p0 == packed[i3] {
                        o[0] = UInt8(truncatingIfNeeded: p0); o[1] = UInt8(truncatingIfNeeded: p0 >> 8)
                        o[2] = UInt8(truncatingIfNeeded: p0 >> 16); o[3] = UInt8(truncatingIfNeeded: p0 >> 24)
                        continue
                    }
                    let fx = col.2
                    let w0 = (1 - fx) * (1 - fy), w1 = fx * (1 - fy), w2 = (1 - fx) * fy, w3 = fx * fy
                    let a0 = cover[i0], a1 = cover[i1], a2 = cover[i2], a3 = cover[i3]

                    // Coverage. An edge where it goes from little to a lot; airbrush stays soft.
                    let av = w0 * a0 + w1 * a1 + w2 * a2 + w3 * a3
                    let gx = (a1 - a0) * (1 - fy) + (a3 - a2) * fy
                    let gy = (a2 - a0) * (1 - fx) + (a3 - a1) * fx
                    let lv = w0 * lo[i0] + w1 * lo[i1] + w2 * lo[i2] + w3 * lo[i3]
                    let hv = w0 * hi[i0] + w1 * hi[i1] + w2 * hi[i2] + w3 * hi[i3]
                    let alpha = sharpen(av, gradient: (gx * gx + gy * gy).squareRoot(), lo: lv, hi: hv, scale: sc,
                                        strength: smoothstep(0.3, 0.55, hv - lv))
                    guard alpha * 255 >= 0.5, av > 0 else {
                        o[0] = 0; o[1] = 0; o[2] = 0; o[3] = 0
                        continue
                    }

                    // Colour: the main colour is the one of the corner that weighs most; `share` is how
                    // much of a corner's paint is that colour (unpainted corners count as all of it,
                    // they add no colour anyway).
                    let wa0 = w0 * a0, wa1 = w1 * a1, wa2 = w2 * a2, wa3 = w3 * a3
                    var best = i0, bestW = wa0
                    if wa1 > bestW { best = i1; bestW = wa1 }
                    if wa2 > bestW { best = i2; bestW = wa2 }
                    if wa3 > bestW { best = i3 }
                    let main = Int(px[n + best])
                    var acc = Mix()
                    let s0 = acc.add(i0, wa0, main: main, px: px, n: n, palette: palette)
                    let s1 = acc.add(i1, wa1, main: main, px: px, n: n, palette: palette)
                    let s2 = acc.add(i2, wa2, main: main, px: px, n: n, palette: palette)
                    let s3 = acc.add(i3, wa3, main: main, px: px, n: n, palette: palette)
                    var share = w0 * s0 + w1 * s1 + w2 * s2 + w3 * s3
                    let mainColor = SIMD3(palette[main * 3], palette[main * 3 + 1], palette[main * 3 + 2])
                    var color = mainColor
                    if acc.otherWeight > 0 {
                        // Two colours side by side have a steep share; glazes change it gently.
                        let sx = (s1 - s0) * (1 - fy) + (s3 - s2) * fy
                        let sy = (s2 - s0) * (1 - fx) + (s3 - s1) * fx
                        let g = (sx * sx + sy * sy).squareRoot()
                        share = sharpen(share, gradient: g, lo: 0, hi: 1, scale: sc, strength: smoothstep(0.12, 0.3, g))
                        color = share * mainColor + (1 - share) * acc.other / acc.otherWeight
                    }
                    let shade = acc.shade / av
                    color *= dark(shade) / 255
                    color += (255 - color) * (light(shade) / 255)
                    color = color * alpha + 0.5
                    o[0] = UInt8(min(255, max(0, color.x)))
                    o[1] = UInt8(min(255, max(0, color.y)))
                    o[2] = UInt8(min(255, max(0, color.z)))
                    o[3] = UInt8(min(255, max(0, alpha * 255 + 0.5)))
                }
            }
        }}}}}}
    }

    /// The paint pixels `upscale` needs to fill fine pixels `rect`.
    static func upscaleWindowRect(for rect: PixelRect, factor: Int, layerWidth: Int, layerHeight: Int) -> PixelRect {
        let r = PixelRect(x0: rect.x0 / factor, y0: rect.y0 / factor,
                          x1: (rect.x1 + factor - 1) / factor, y1: (rect.y1 + factor - 1) / factor)
        return windowRect(for: r, layerWidth: layerWidth, layerHeight: layerHeight)
    }

    /// The paint scaled up by `factor` into plain paint planes (as `PaintLayer.Plane`), with edges as
    /// sharp as `render` draws them: fills fine pixels `rect` of `out`, which holds the planes of
    /// `outRect` (fine pixels, containing `rect`) back to back. `window` must contain
    /// `upscaleWindowRect(for: rect, …)`.
    ///
    /// Each fine pixel gets the colour that weighs most around it and, where two colours meet, the
    /// other one as `under` with its share as `mix`; coverage and shade are interpolated.
    static func upscale(_ window: PaintWindow, factor: Int, rect: PixelRect, into out: UnsafeMutablePointer<UInt8>,
                        outRect: PixelRect) {
        let win = window.rect, ww = win.x1 - win.x0, wh = win.y1 - win.y0
        guard !rect.isEmpty, ww > 0, wh > 0, factor > 0 else { return }
        let n = ww * wh, ow = outRect.x1 - outRect.x0, on = ow * (outRect.y1 - outRect.y0)
        let prepared = prepare(window)
        // All five planes of a window pixel in one word, to spot even areas quickly.
        var keys = [UInt64](repeating: 0, count: n)
        window.planes.withUnsafeBufferPointer { px in
            for i in 0..<n {
                keys[i] = UInt64(px[i]) | UInt64(px[n + i]) << 8 | UInt64(px[2 * n + i]) << 16
                    | UInt64(px[3 * n + i]) << 24 | UInt64(px[4 * n + i]) << 32
            }
        }
        let cols = samples(rect.x0..<rect.x1, scale: factor, winOrigin: win.x0, winSize: ww, layer: window.layerWidth)
        let rows = samples(rect.y0..<rect.y1, scale: factor, winOrigin: win.y0, winSize: wh, layer: window.layerHeight)
        let sc = Float(factor)
        window.planes.withUnsafeBufferPointer { px in
        keys.withUnsafeBufferPointer { keys in
        prepared.cover.withUnsafeBufferPointer { cover in
        prepared.lo.withUnsafeBufferPointer { lo in
        prepared.hi.withUnsafeBufferPointer { hi in
            for ry in 0..<rows.count {
                let row = rows[ry], r0 = row.0 * ww, r1 = row.1 * ww, fy = row.2
                let line = (rect.y0 + ry - outRect.y0) * ow + (rect.x0 - outRect.x0)
                for rx in 0..<cols.count {
                    let col = cols[rx], o = line + rx
                    let i0 = r0 + col.0, i1 = r0 + col.1, i2 = r1 + col.0, i3 = r1 + col.1
                    let k0 = keys[i0]
                    if k0 == keys[i1] && k0 == keys[i2] && k0 == keys[i3] {
                        for p in 0..<5 { out[p * on + o] = px[p * n + i0] }
                        continue
                    }
                    let fx = col.2
                    let w0 = (1 - fx) * (1 - fy), w1 = fx * (1 - fy), w2 = (1 - fx) * fy, w3 = fx * fy
                    let a0 = cover[i0], a1 = cover[i1], a2 = cover[i2], a3 = cover[i3]
                    let av = w0 * a0 + w1 * a1 + w2 * a2 + w3 * a3
                    let gx = (a1 - a0) * (1 - fy) + (a3 - a2) * fy
                    let gy = (a2 - a0) * (1 - fx) + (a3 - a1) * fx
                    let lv = w0 * lo[i0] + w1 * lo[i1] + w2 * lo[i2] + w3 * lo[i3]
                    let hv = w0 * hi[i0] + w1 * hi[i1] + w2 * hi[i2] + w3 * hi[i3]
                    let alpha = sharpen(av, gradient: (gx * gx + gy * gy).squareRoot(), lo: lv, hi: hv, scale: sc,
                                        strength: smoothstep(0.3, 0.55, hv - lv))
                    let near = fx < 0.5 ? (fy < 0.5 ? i0 : i2) : (fy < 0.5 ? i1 : i3)
                    let coverage = UInt8(min(255, max(0, alpha * 255 + 0.5)))
                    guard coverage > 0, av > 0 else {
                        out[o] = 0
                        out[on + o] = px[n + near]
                        out[2 * on + o] = PaintLayer.neutralShade
                        out[3 * on + o] = px[n + near]
                        out[4 * on + o] = 0
                        continue
                    }
                    let wa0 = w0 * a0, wa1 = w1 * a1, wa2 = w2 * a2, wa3 = w3 * a3
                    var best = i0, bestW = wa0
                    if wa1 > bestW { best = i1; bestW = wa1 }
                    if wa2 > bestW { best = i2; bestW = wa2 }
                    if wa3 > bestW { best = i3 }
                    let main = px[n + best]
                    var acc = Others()
                    let s0 = acc.add(i0, wa0, main: main, px: px, n: n)
                    let s1 = acc.add(i1, wa1, main: main, px: px, n: n)
                    let s2 = acc.add(i2, wa2, main: main, px: px, n: n)
                    let s3 = acc.add(i3, wa3, main: main, px: px, n: n)
                    var share = w0 * s0 + w1 * s1 + w2 * s2 + w3 * s3
                    let shade = UInt8(min(255, max(0, acc.shade / av + 0.5)))
                    out[o] = coverage
                    out[2 * on + o] = shade
                    if let other = acc.strongest {
                        let sx = (s1 - s0) * (1 - fy) + (s3 - s2) * fy
                        let sy = (s2 - s0) * (1 - fx) + (s3 - s1) * fx
                        let g = (sx * sx + sy * sy).squareRoot()
                        share = sharpen(share, gradient: g, lo: 0, hi: 1, scale: sc, strength: smoothstep(0.12, 0.3, g))
                        let top = share >= 0.5
                        out[on + o] = top ? main : other
                        out[3 * on + o] = top ? other : main
                        out[4 * on + o] = UInt8(min(255, max(0, (top ? 1 - share : share) * 255 + 0.5)))
                    } else {
                        out[on + o] = main
                        out[3 * on + o] = main
                        out[4 * on + o] = 0
                    }
                }
            }
        }}}}}
    }

    /// Weighs the colours of a sample's corners other than the main one.
    private struct Others {
        var colors: [(UInt8, Float)] = []
        var shade: Float = 0

        var strongest: UInt8? {
            colors.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil }
        }

        private mutating func weigh(_ c: UInt8, _ w: Float) {
            guard w > 0 else { return }
            if let i = colors.firstIndex(where: { $0.0 == c }) { colors[i].1 += w } else { colors.append((c, w)) }
        }

        /// Adds corner `k` with weight `wk` (bilinear weight × coverage); returns its share of `main`.
        mutating func add(_ k: Int, _ wk: Float, main: UInt8, px: UnsafeBufferPointer<UInt8>, n: Int) -> Float {
            guard px[k] > 0 else { return 1 }
            shade += wk * Float(px[2 * n + k])
            let c = px[n + k], u = px[3 * n + k], m = Float(px[4 * n + k]) / 255
            if c == u || m == 0 {
                if c == main { return 1 }
                weigh(c, wk)
                return 0
            }
            if c != main { weigh(c, wk * (1 - m)) }
            if u != main { weigh(u, wk * m) }
            return (c == main ? 1 - m : 0) + (u == main ? m : 0)
        }
    }

    /// Sums up the colours of a sample's corners.
    private struct Mix {
        var other = SIMD3<Float>(repeating: 0), otherWeight: Float = 0, shade: Float = 0

        /// Adds corner `k` with weight `wk` (bilinear weight × coverage); returns its share of `main`.
        @inline(__always) mutating func add(_ k: Int, _ wk: Float, main: Int, px: UnsafeBufferPointer<UInt8>, n: Int,
                                            palette: UnsafeBufferPointer<Float>) -> Float {
            guard px[k] > 0 else { return 1 }
            shade += wk * Float(px[2 * n + k])
            let c = Int(px[n + k]), u = Int(px[3 * n + k])
            guard c != u else {
                if c == main { return 1 }
                other += wk * SIMD3(palette[c * 3], palette[c * 3 + 1], palette[c * 3 + 2])
                otherWeight += wk
                return 0
            }
            let m = Float(px[4 * n + k]) / 255
            if c != main {
                other += wk * (1 - m) * SIMD3(palette[c * 3], palette[c * 3 + 1], palette[c * 3 + 2])
                otherWeight += wk * (1 - m)
            }
            if u != main {
                other += wk * m * SIMD3(palette[u * 3], palette[u * 3 + 1], palette[u * 3 + 2])
                otherWeight += wk * m
            }
            return (c == main ? 1 - m : 0) + (u == main ? m : 0)
        }
    }

    /// Renders all of `rect` into a new buffer of `rect`'s size × `scale`.
    static func render(_ window: PaintWindow, rect: PixelRect, scale: Int) -> PixelBuffer {
        let buffer = PixelBuffer(width: (rect.x1 - rect.x0) * scale, height: (rect.y1 - rect.y0) * scale)
        render(window, rect: rect, scale: scale, into: buffer.bytes, outRect: rect, outBytesPerRow: buffer.bytesPerRow)
        return buffer
    }
}

/// Everything needed to draw a part of the paint sharp at any zoom, off the main thread: the paint
/// layer's pixels around it and the fine tiles there (see `PaintLayer`).
struct DetailWindow: Sendable {
    enum Source: Sendable { case raw([UInt8]), packed(Data) }
    /// Paint pixels around the part, enough for `SharpPaint.render` and `SharpPaint.upscale`.
    let base: PaintWindow
    /// Fine tiles near the part, by tile index.
    let fine: [Int: Source]
    let tileSize: Int, tilesPerRow: Int, fineScale: Int, planes: Int

    /// Draws paint pixels `rect` at `scale` output pixels per paint pixel (a power of two) into
    /// `out`, which shows `outRect` (paint pixels) with `outBytesPerRow`. Premultiplied RGBA. Where
    /// there are fine tiles they are drawn; elsewhere the paint layer is scaled up, so both meet
    /// seamlessly.
    func render(rect: PixelRect, scale: Int, into out: UnsafeMutablePointer<UInt8>, outRect: PixelRect,
                outBytesPerRow: Int) {
        guard !rect.isEmpty else { return }
        guard !fine.isEmpty else {
            SharpPaint.render(base, rect: rect, scale: scale, into: out, outRect: outRect, outBytesPerRow: outBytesPerRow)
            return
        }
        let f = fineScale, lw = base.layerWidth * f, lh = base.layerHeight * f
        let target = PixelRect(x0: rect.x0 * f, y0: rect.y0 * f, x1: rect.x1 * f, y1: rect.y1 * f)
        let win = SharpPaint.windowRect(for: target, layerWidth: lw, layerHeight: lh)
        let fineWindow = PaintWindow(rect: win, layerWidth: lw, layerHeight: lh, planes: finePlanes(win),
                                     palette: base.palette)
        if scale >= f {
            SharpPaint.render(fineWindow, rect: target, scale: scale / f, into: out,
                              outRect: PixelRect(x0: outRect.x0 * f, y0: outRect.y0 * f, x1: outRect.x1 * f, y1: outRect.y1 * f),
                              outBytesPerRow: outBytesPerRow)
            return
        }
        // Fewer output pixels than fine ones: draw them one to one, then average down.
        let full = SharpPaint.render(fineWindow, rect: target, scale: 1)
        let step = f / max(1, scale), ox = (rect.x0 - outRect.x0) * scale, oy = (rect.y0 - outRect.y0) * scale
        let area = UInt32(step * step)
        for y in 0..<((rect.y1 - rect.y0) * scale) {
            let line = out + (oy + y) * outBytesPerRow + ox * 4
            for x in 0..<((rect.x1 - rect.x0) * scale) {
                var sum = SIMD4<UInt32>(repeating: 0)
                for yy in 0..<step {
                    let src = full.bytes + (y * step + yy) * full.bytesPerRow + x * step * 4
                    for xx in 0..<step {
                        let p = src + xx * 4
                        sum &+= SIMD4(UInt32(p[0]), UInt32(p[1]), UInt32(p[2]), UInt32(p[3]))
                    }
                }
                let o = line + x * 4
                for k in 0..<4 { o[k] = UInt8((sum[k] + area / 2) / area) }
            }
        }
    }

    /// Renders all of `rect` into a new buffer of `rect`'s size × `scale`.
    func render(rect: PixelRect, scale: Int) -> PixelBuffer {
        let buffer = PixelBuffer(width: (rect.x1 - rect.x0) * scale, height: (rect.y1 - rect.y0) * scale)
        render(rect: rect, scale: scale, into: buffer.bytes, outRect: rect, outBytesPerRow: buffer.bytesPerRow)
        return buffer
    }

    /// The fine planes of `r` (fine pixels): copied from the fine tiles, scaled up from the paint
    /// layer where there are none.
    private func finePlanes(_ r: PixelRect) -> [UInt8] {
        let rw = r.x1 - r.x0, area = rw * (r.y1 - r.y0), t = tileSize * fineScale
        var out = [UInt8](repeating: 0, count: area * planes)
        let layerFine = PixelRect(x0: 0, y0: 0, x1: base.layerWidth * fineScale, y1: base.layerHeight * fineScale)
        out.withUnsafeMutableBufferPointer { o in
            for ty in (r.y0 / t)...((r.y1 - 1) / t) {
                for tx in (r.x0 / t)...((r.x1 - 1) / t) {
                    let tileRect = PixelRect(x0: tx * t, y0: ty * t, x1: tx * t + t, y1: ty * t + t).intersection(layerFine)
                    let part = tileRect.intersection(r)
                    guard !part.isEmpty else { continue }
                    let tw = tileRect.x1 - tileRect.x0, tileArea = tw * (tileRect.y1 - tileRect.y0)
                    let raw: [UInt8]?
                    switch fine[ty * tilesPerRow + tx] {
                    case .raw(let bytes)?: raw = bytes.count == tileArea * planes ? bytes : nil
                    case .packed(let data)?: raw = PaintLayer.unpack(data, size: tileArea * planes)
                    case nil: raw = nil
                    }
                    guard let raw else {
                        SharpPaint.upscale(base, factor: fineScale, rect: part, into: o.baseAddress!, outRect: r)
                        continue
                    }
                    raw.withUnsafeBufferPointer { src in
                        for p in 0..<planes {
                            for y in part.y0..<part.y1 {
                                let from = p * tileArea + (y - tileRect.y0) * tw + (part.x0 - tileRect.x0)
                                let to = p * area + (y - r.y0) * rw + (part.x0 - r.x0)
                                (o.baseAddress! + to).update(from: src.baseAddress! + from, count: part.x1 - part.x0)
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
