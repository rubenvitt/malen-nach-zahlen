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

    /// Renders paint pixels `rect` at `scale` output pixels per paint pixel into `out`, which shows
    /// `outRect` (paint pixels, containing `rect`) with `outBytesPerRow`. Premultiplied RGBA.
    /// `window` must contain `windowRect(for: rect, …)`.
    static func render(_ window: PaintWindow, rect: PixelRect, scale: Int, into out: UnsafeMutablePointer<UInt8>,
                       outRect: PixelRect, outBytesPerRow: Int) {
        let win = window.rect, ww = win.x1 - win.x0, wh = win.y1 - win.y0
        guard !rect.isEmpty, ww > 0, wh > 0, scale > 0 else { return }
        let n = ww * wh

        // Per window pixel: premultiplied RGBA exactly as PaintLayer.makeImage has it, coverage, and
        // the lowest and highest coverage around it.
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

            // Where each output column and row samples: window column/row of the two neighbours and
            // the fraction between them. Samples beyond the layer's edge repeat the edge.
            let sc = Float(scale)
            func axis(_ from: Int, _ to: Int, origin: Int, winOrigin: Int, winSize: Int, layer: Int) -> [(Int, Int, Float)] {
                (from..<to).map { o in
                    let p = Float(origin) + (Float(o) + 0.5) / sc - 0.5
                    let i = Int(p.rounded(.down)), f = p - Float(i)
                    let a = min(max(i, 0), layer - 1) - winOrigin, b = min(max(i + 1, 0), layer - 1) - winOrigin
                    return (min(max(a, 0), winSize - 1), min(max(b, 0), winSize - 1), f)
                }
            }
            let ox0 = (rect.x0 - outRect.x0) * scale, ox1 = (rect.x1 - outRect.x0) * scale
            let oy0 = (rect.y0 - outRect.y0) * scale, oy1 = (rect.y1 - outRect.y0) * scale
            let cols = axis(ox0, ox1, origin: outRect.x0, winOrigin: win.x0, winSize: ww, layer: window.layerWidth)
            let rows = axis(oy0, oy1, origin: outRect.y0, winOrigin: win.y0, winSize: wh, layer: window.layerHeight)

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
