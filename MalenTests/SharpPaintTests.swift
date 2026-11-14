import CoreGraphics
import Foundation
import Testing
import PaintEngine
@testable import Malen

/// The canvas test template (16×8 paint pixels) with a brush stroke of colour 0 along row 4.
private func strokedLayer() -> PaintLayer {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 2.6)
    _ = l.continueStroke([CGPoint(x: 1, y: 4), CGPoint(x: 9, y: 4)])
    _ = l.endStroke()
    return l
}

private func bytes(_ b: PixelBuffer, x: Int, y: Int) -> [UInt8] {
    (0..<4).map { b.bytes[y * b.bytesPerRow + x * 4 + $0] }
}

@Test func sharpPaintKeepsTheColourOfEvenlyPaintedAreas() throws {
    let l = strokedLayer()
    let all = PixelRect(x0: 0, y0: 0, x1: l.width, y1: l.height)
    let sharp = SharpPaint.render(l.window(around: all), rect: all, scale: 4)
    #expect(sharp.width == l.width * 4 && sharp.height == l.height * 4)
    let image = try #require(l.makeImage(PixelRect(x0: 4, y0: 4, x1: 5, y1: 5)))
    let plain = try #require(image.dataProvider?.data.map { [UInt8]($0 as Data) })
    // Output pixel (18, 18) lies between paint pixels 4 and 5, all four of them fully painted.
    #expect(bytes(sharp, x: 18, y: 18) == Array(plain[0..<4]))
    #expect(bytes(sharp, x: 2, y: 30) == [0, 0, 0, 0])               // far from the stroke: nothing
}

@Test func sharpPaintEdgesAreAboutOneOutputPixelWide() {
    let l = strokedLayer()
    let all = PixelRect(x0: 0, y0: 0, x1: l.width, y1: l.height)
    let scale = 8
    let sharp = SharpPaint.render(l.window(around: all), rect: all, scale: scale)
    // Down a column through the middle of the stroke, across its upper edge (paint rows 0–3).
    let x = 5 * scale + scale / 2
    let column = (0..<(4 * scale)).map { sharp.bytes[$0 * sharp.bytesPerRow + x * 4 + 3] }
    #expect(column.first == 0 && column.last == 255)
    // From 10 % to 90 % within 2 output pixels; scaled up plainly it takes about 13.
    #expect(column.filter { $0 > 25 && $0 < 230 }.count <= 2)
    #expect(zip(column, column.dropFirst()).allSatisfy { Int($0) <= Int($1) + 8 })   // no fringe, no holes
}

@Test func sharpPaintPatchesMatchAFullRender() {
    let l = strokedLayer()
    l.beginStroke(color: 1, radius: 1.5)
    _ = l.continueStroke([CGPoint(x: 5, y: 0), CGPoint(x: 6, y: 8)])
    _ = l.endStroke()
    let all = PixelRect(x0: 0, y0: 0, x1: l.width, y1: l.height), scale = 4
    let full = SharpPaint.render(l.window(around: all), rect: all, scale: scale)
    let patched = PixelBuffer(width: full.width, height: full.height)
    for part in [PixelRect(x0: 0, y0: 0, x1: 7, y1: 5), PixelRect(x0: 7, y0: 0, x1: 16, y1: 5),
                 PixelRect(x0: 0, y0: 5, x1: 16, y1: 8)] {
        SharpPaint.render(l.window(around: part), rect: part, scale: scale, into: patched.bytes, outRect: all,
                          outBytesPerRow: patched.bytesPerRow)
    }
    #expect((0..<full.count).allSatisfy { full.bytes[$0] == patched.bytes[$0] })
}

/// 200×100 grid pixels of one field: at fit in 400×300 points a paint pixel is about one point.
private func largeTemplate() -> Template {
    let w = 200, h = 100
    return Template(width: w, height: h, palette: [PaletteColor(r: 200, g: 40, b: 40)],
                    colorOfPixel: [UInt8](repeating: 0, count: w * h), fieldOfPixel: [Int32](repeating: 0, count: w * h),
                    colorOfField: [0], sizeOfField: [Int32(w * h)], spots: [])
}

@MainActor @Test func zoomingInDrawsSharpPaintForTheVisiblePart() async throws {
    let view = PaintCanvasView(session: PaintingSession(template: largeTemplate(), paintLayerPNG: nil))
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    view.layoutIfNeeded()
    #expect(view.detailScaleForTesting == 1 && view.detailTileCountForTesting == 0)

    view.zoomForTesting(8)
    #expect(view.detailScaleForTesting > 1)
    let tiles = view.detailTileCountForTesting
    #expect(tiles > 0)
    // Only what is on screen: far fewer tiles than would cover the whole picture.
    let side = 256 / view.detailScaleForTesting
    #expect(tiles < (400 / side + 1) * (200 / side + 1))
    for _ in 0..<300 where !view.detailIsDrawnForTesting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(view.detailIsDrawnForTesting)

    view.zoomToFit(animated: false)
    #expect(view.detailScaleForTesting == 1 && view.detailTileCountForTesting == 0)
}
