import Foundation
import Testing
@testable import PaintEngine

/// Photo-like test image: gradient, a few discs and stripes, pixel noise.
func photoLike(_ w: Int, _ h: Int) -> [UInt8] {
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    var seed: UInt32 = 7
    let discs = [(0.3, 0.4, 0.2, (230, 60, 50)), (0.7, 0.6, 0.25, (40, 90, 200)), (0.55, 0.25, 0.1, (250, 210, 40))]
    for y in 0..<h {
        for x in 0..<w {
            let u = Double(x) / Double(w), v = Double(y) / Double(h)
            var c = (Int(u * 200) + 30, Int(v * 180) + 40, 120 + Int(60 * sin(u * 9)))
            if Int(u * 40) % 7 == 0 && v > 0.8 { c = (20, 120, 60) }
            for (cx, cy, r, col) in discs where (u - cx) * (u - cx) + (v - cy) * (v - cy) * 0.56 < r * r { c = col }
            seed = seed &* 1664525 &+ 1013904223
            let noise = Int(seed >> 24) / 8 - 16
            let o = (y * w + x) * 4
            rgba[o] = UInt8(clamping: c.0 + noise); rgba[o + 1] = UInt8(clamping: c.1 + noise); rgba[o + 2] = UInt8(clamping: c.2 + noise)
        }
    }
    return rgba
}

/// 40×20: left half red, right half blue, one green speck that must disappear (prototype/web/seg.test.js).
@Test func twoHalvesBecomeTwoFieldsAndTheSpeckIsMergedAway() throws {
    let w = 40, h = 20
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            (rgba[o], rgba[o + 1], rgba[o + 2]) = x < 20 ? (220, 20, 20) : (20, 20, 220)
        }
    }
    let speck = (5 * w + 5) * 4
    (rgba[speck], rgba[speck + 1], rgba[speck + 2]) = (20, 220, 20)

    let t = try TemplateBuilder.build(rgba: rgba, width: w, height: h, options: TemplateOptions(colors: 3), minArea: 10)
    #expect(t.palette.count == 2)
    #expect(t.spots.count == 2)
    #expect(t.colorOfPixel[0] != t.colorOfPixel[w - 1])
    #expect(t.colorOfPixel[5 * w + 5] == t.colorOfPixel[0])
    let red = t.palette[Int(t.colorOfPixel[0])] // mean of its pixels, the merged speck included
    #expect(red.r == 220 && red.g <= 21 && red.b == 20)
    for s in t.spots { #expect(t.colorOfPixel[s.y * w + s.x] == t.colorOfField[Int(s.field)]) }
}

@Test func sameInputGivesSameTemplate() throws {
    let rgba = photoLike(400, 300), o = TemplateOptions(colors: 10, maxSide: 200)
    #expect(try TemplateBuilder.build(rgba: rgba, width: 400, height: 300, options: o)
        == TemplateBuilder.build(rgba: rgba, width: 400, height: 300, options: o))
}

@Test(arguments: [4, 12, 30])
func templateIsConsistent(colors: Int) throws {
    let o = TemplateOptions(colors: colors, detail: 0.7, maxSide: 300)
    let t = try TemplateBuilder.build(rgba: photoLike(600, 400), width: 600, height: 400, options: o)
    #expect(t.width == 300 && t.height == 200)
    #expect(t.palette.count <= colors && t.palette.count >= 2)
    #expect(Set(t.colorOfPixel) == Set(0..<UInt8(t.palette.count)), "no gaps in the palette")

    let minArea = TemplateBuilder.minArea(detail: o.detail, width: t.width, height: t.height)
    #expect(t.sizeOfField.allSatisfy { $0 >= minArea })
    #expect(t.sizeOfField.reduce(0, +) == Int32(t.width * t.height))
    #expect(t.spots.count == t.sizeOfField.count && t.colorOfField.count == t.sizeOfField.count)
    for (f, s) in t.spots.enumerated() {
        let p = s.y * t.width + s.x
        #expect(s.field == Int32(f) && t.fieldOfPixel[p] == s.field && t.colorOfPixel[p] == t.colorOfField[f])
        #expect(s.radius >= 0.5)
    }
}

@Test func minAreaFollowsDetailAndGridArea() {
    #expect(TemplateBuilder.minArea(detail: 0.5, width: 1000, height: 750) == 144)
    #expect(TemplateBuilder.minArea(detail: 0, width: 1000, height: 750) == 576)
    #expect(TemplateBuilder.minArea(detail: 1, width: 1000, height: 750) == 36)
    #expect(TemplateBuilder.minArea(detail: 0.5, width: 320, height: 240) == 15)
}

@Test func encodeDecodeRoundTrip() throws {
    let t = try TemplateBuilder.build(rgba: photoLike(300, 200), width: 300, height: 200, options: TemplateOptions())
    let data = try t.encoded()
    #expect(data.count < t.width * t.height + 1000)
    #expect(try Template(decoding: data) == t)
    let json = try JSONDecoder().decode(Template.self, from: JSONEncoder().encode(t))
    #expect(json == t)
}

@Test func corruptDataThrows() throws {
    let t = Template(width: 2, height: 1, palette: [PaletteColor(r: 0, g: 0, b: 0)], colorOfPixel: [0, 0])
    var json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
    json = json.replacingOccurrences(of: "\"width\":2", with: "\"width\":3")
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Template.self, from: Data(json.utf8)) }
    #expect(throws: (any Error).self) { try Template(decoding: Data([1, 2, 3])) }
}

@Test func cancelledBuildThrows() async {
    let rgba = photoLike(200, 100)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try TemplateBuilder.build(rgba: rgba, width: 200, height: 100, options: TemplateOptions())
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func invalidImageThrows() {
    #expect(throws: TemplateBuilderError.invalidImage) {
        try TemplateBuilder.build(rgba: [0, 0, 0], width: 1, height: 1, options: TemplateOptions())
    }
}

@Test func tinyAndUniformImagesWork() throws {
    let one = try TemplateBuilder.build(rgba: [10, 20, 30, 255], width: 1, height: 1, options: TemplateOptions())
    #expect(one.palette == [PaletteColor(r: 10, g: 20, b: 30)] && one.spots.count == 1)
    let flat = try TemplateBuilder.build(rgba: [UInt8](repeating: 200, count: 50 * 30 * 4), width: 50, height: 30,
                                         options: TemplateOptions(colors: 8))
    #expect(flat.palette.count == 1 && flat.sizeOfField == [1500])
}
