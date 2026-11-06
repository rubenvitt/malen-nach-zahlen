import Foundation
import Testing
@testable import PaintEngine

#if DEBUG
private let isRelease = false
#else
private let isRelease = true
#endif

/// 24-bit BMP (e.g. `sips -s format bmp photo.jpg --out x.bmp`) → RGBA.
private func loadBMP(_ path: String) throws -> (rgba: [UInt8], w: Int, h: Int) {
    let b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    func i32(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)) }
    let off = i32(10), w = i32(18), rawH = i32(22), h = abs(rawH), stride = (w * 3 + 3) / 4 * 4
    precondition(b[28] == 24, "only 24-bit BMP")
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        let row = off + (rawH < 0 ? y : h - 1 - y) * stride
        for x in 0..<w { for c in 0..<3 { rgba[(y * w + x) * 4 + c] = b[row + x * 3 + 2 - c] } }
    }
    return (rgba, w, h)
}

/// Run with `swift test -c release -Xswiftc -enable-testing --filter benchmark`;
/// set ENGINE_PHOTO=/path/to/24bit.bmp to measure a real photo instead of the synthetic ~12 MP image.
@Test(.enabled(if: isRelease)) func benchmark() throws {
    let photo = ProcessInfo.processInfo.environment["ENGINE_PHOTO"]
    let (rgba, w, h) = try photo.map(loadBMP) ?? (photoLike(4000, 3000), 4000, 3000)
    func ms(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    var preview: Template?, full: Template?
    let tPreview = try ms { preview = try TemplateBuilder.build(rgba: rgba, width: w, height: h, options: TemplateOptions(maxSide: 320)) }
    let tFull = try ms { full = try TemplateBuilder.build(rgba: rgba, width: w, height: h, options: TemplateOptions(colors: 30, detail: 1)) }
    let data = try full!.encoded()
    var decoded: Template?
    let tDecode = try ms { decoded = try Template(decoding: data) }
    print("benchmark \(w)×\(h): preview 320 \(Int(tPreview)) ms (\(preview!.sizeOfField.count) fields), full 1000 \(Int(tFull)) ms (\(full!.sizeOfField.count) fields), encoded \(data.count / 1024) KB, decode \(Int(tDecode)) ms")
    #expect(tPreview < 150)
    #expect(tFull < 2000)
    #expect(data.count < 3_000_000)
    #expect(tDecode < 150)
    #expect(decoded == full)
}
