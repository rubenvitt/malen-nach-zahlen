import CoreGraphics
import Foundation
import Testing
import PaintEngine
@testable import Malen

private func whole(_ l: PaintLayer) -> PixelRect { PixelRect(x0: 0, y0: 0, x1: l.width, y1: l.height) }

private func alpha(_ b: PixelBuffer, x: Int, y: Int) -> UInt8 { b.bytes[y * b.bytesPerRow + x * 4 + 3] }

private func pixel(_ b: PixelBuffer, x: Int, y: Int) -> [UInt8] {
    (0..<4).map { b.bytes[y * b.bytesPerRow + x * 4 + $0] }
}

@Test func thinStrokesStartFineTilesBroadOnesDoNot() {
    let broad = PaintLayer(template: canvasTestTemplate())
    broad.beginStroke(color: 0, radius: 20)
    _ = broad.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    _ = broad.endStroke()
    #expect(broad.fineTileCount == 0)

    let thin = PaintLayer(template: canvasTestTemplate())
    thin.beginStroke(color: 0, radius: 1.2)
    _ = thin.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    _ = thin.endStroke()
    #expect(thin.fineTileCount == 1)
    #expect(thin.fineData() != nil)

    // A broad stroke over it keeps the fine tile up to date; undo takes both back.
    thin.beginStroke(color: 1, radius: 20)
    _ = thin.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    _ = thin.endStroke()
    let all = whole(thin)
    let fine = thin.detailWindow(around: all).render(rect: all, scale: 4)
    let plain = SharpPaint.render(thin.window(around: all), rect: all, scale: 4)
    #expect(pixel(fine, x: 32, y: 16) == pixel(plain, x: 32, y: 16))       // all colour 1 now
    _ = thin.undo()
    _ = thin.undo()
    #expect(thin.fineTileCount == 0)
    #expect(thin.coverage.allSatisfy { $0 == 0 })
}

@Test func strokesThatChangeNothingLeaveNoFineTile() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 2, kind: .shadow)                   // bare paper: nothing to shade
    _ = l.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    #expect(!l.endStroke().committed)
    #expect(l.fineTileCount == 0)
}

@Test func finePaintDrawsThinLinesSharp() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 1)
    _ = l.continueStroke([CGPoint(x: 1, y: 4), CGPoint(x: 15, y: 4)])
    _ = l.endStroke()
    let all = whole(l), scale = 8
    let sharp = l.detailWindow(around: all).render(rect: all, scale: scale)
    #expect(sharp.width == l.width * scale && sharp.height == l.height * scale)
    // Down a column through the middle of the line: two paint pixels wide, both edges about one
    // output pixel wide.
    let x = 8 * scale + scale / 2
    let column = (0..<(8 * scale)).map { alpha(sharp, x: x, y: $0) }
    #expect(column[4 * scale] == 255)
    #expect(column.first == 0 && column.last == 0)
    #expect(column.filter { $0 > 25 && $0 < 230 }.count <= 4)
    let solid = column.filter { $0 >= 230 }.count
    #expect(abs(solid - 2 * scale) <= 3)
}

@Test func fineTilesMeetThePaintAroundThemSeamlessly() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 18)                                  // broad: no fine tile
    _ = l.continueStroke([CGPoint(x: -14, y: 4)])                        // its round edge near x = 4
    _ = l.endStroke()
    #expect(l.fineTileCount == 0)
    let all = whole(l)
    let before = l.detailWindow(around: all).render(rect: all, scale: 4)
    // A thin stroke in a corner starts the tile from the paint scaled up: the edge of the broad
    // stroke looks the same as before.
    l.beginStroke(color: 1, radius: 0.75)
    _ = l.continueStroke([CGPoint(x: 14, y: 6), CGPoint(x: 15, y: 6)])
    _ = l.endStroke()
    #expect(l.fineTileCount == 1)
    let after = l.detailWindow(around: all).render(rect: all, scale: 4)
    for y in 0..<after.height {
        for x in 0..<(10 * 4) {
            let a = pixel(before, x: x, y: y), b = pixel(after, x: x, y: y)
            #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "at \(x), \(y)")
        }
    }
}

@Test func finePatchesMatchAFullRender() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 2.6, kind: .crayon)
    _ = l.continueStroke([CGPoint(x: 1, y: 4), CGPoint(x: 9, y: 4)])
    _ = l.endStroke()
    l.beginStroke(color: 1, radius: 1.5)
    _ = l.continueStroke([CGPoint(x: 5, y: 0), CGPoint(x: 6, y: 8)])
    _ = l.endStroke()
    let all = whole(l)
    for scale in [2, 4, 8] {
        let full = l.detailWindow(around: all).render(rect: all, scale: scale)
        let patched = PixelBuffer(width: full.width, height: full.height)
        for part in [PixelRect(x0: 0, y0: 0, x1: 7, y1: 5), PixelRect(x0: 7, y0: 0, x1: 16, y1: 5),
                     PixelRect(x0: 0, y0: 5, x1: 16, y1: 8)] {
            l.detailWindow(around: part, unpack: true).render(rect: part, scale: scale, into: patched.bytes, outRect: all,
                                                              outBytesPerRow: patched.bytesPerRow)
        }
        #expect((0..<full.count).allSatisfy { full.bytes[$0] == patched.bytes[$0] }, "scale \(scale)")
    }
}

@Test func finePaintRoundTripsThroughSaving() throws {
    let t = canvasTestTemplate()
    let l = PaintLayer(template: t)
    l.beginStroke(color: 1, radius: 1.1, kind: .pencil)
    _ = l.continueStroke([CGPoint(x: 1, y: 1.3), CGPoint(x: 14, y: 6.2)], pressures: [0.3, 0.9])
    _ = l.endStroke()
    let fine = try #require(l.fineData())
    let back = PaintLayer(template: t, png: l.pngData(), colors: l.colorData(), fine: fine)
    #expect(back.fineTileCount == l.fineTileCount)
    let all = whole(l)
    let a = l.detailWindow(around: all).render(rect: all, scale: 8)
    let b = back.detailWindow(around: all).render(rect: all, scale: 8)
    #expect((0..<a.count).allSatisfy { a.bytes[$0] == b.bytes[$0] })

    // Data for another size, or garbage, is ignored.
    let tiny = Template(width: 2, height: 2, palette: [PaletteColor(r: 0, g: 0, b: 0)], colorOfPixel: [0, 0, 0, 0],
                        fieldOfPixel: [0, 0, 0, 0], colorOfField: [0], sizeOfField: [4], spots: [])
    let other = PaintLayer(template: tiny, png: PaintLayer(template: tiny).pngData(), fine: fine)
    #expect(other.fineTileCount == 0)
    let garbage = PaintLayer(template: t, png: l.pngData(), fine: Data([1, 2, 3]))
    #expect(garbage.fineTileCount == 0)
}

@Test func predictedPointsNeverStickInFinePaint() {
    let a = PaintLayer(template: canvasTestTemplate()), b = PaintLayer(template: canvasTestTemplate())
    a.beginStroke(color: 0, radius: 1.2)
    b.beginStroke(color: 0, radius: 1.2)
    _ = a.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1)], predicted: [CGPoint(x: 6, y: 6)])
    _ = b.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1)])
    _ = a.continueStroke([CGPoint(x: 4, y: 2)], predicted: [CGPoint(x: 7, y: 7)])
    _ = b.continueStroke([CGPoint(x: 4, y: 2)])
    _ = a.endStroke(); _ = b.endStroke()
    #expect(a.fineData() == b.fineData())
    _ = a.undo()
    #expect(a.fineTileCount == 0)
}

@MainActor @Test func fineStrokesSurviveTheStore() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "fine-store-\(UUID().uuidString)")
    let store = ArtworkStore(directory: dir)
    let meta = try store.create(template: ArtworkStoreTests.template, title: "A", options: TemplateOptions(), thumbnail: nil)
    store.save(meta.id, paint: Data([7]), colors: Data([5, 5]), fine: Data([4, 4, 4]), thumbnail: nil, progress: 0.1)
    let reopened = ArtworkStore(directory: dir)
    #expect(reopened.paintData(meta.id) == Data([7]))
    #expect(reopened.paintColorData(meta.id) == Data([5, 5]))
    #expect(reopened.paintFineData(meta.id) == Data([4, 4, 4]))
    store.save(meta.id, paint: Data([8]), fine: Data([3]), thumbnail: nil, progress: 0.2)
    #expect(store.paintColorData(meta.id) == nil)
    #expect(store.paintFineData(meta.id) == Data([3]))
    store.save(meta.id, paint: Data([9]), thumbnail: nil, progress: 0.3)
    #expect(store.paintFineData(meta.id) == nil)
    #expect(store.paintData(meta.id) == Data([9]))
    try? FileManager.default.removeItem(at: dir)
}
