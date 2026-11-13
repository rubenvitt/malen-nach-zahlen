import CoreGraphics
import Testing
import PaintEngine
@testable import Malen

@Test func bordersRunBetweenJunctionsOrFormLoops() throws {
    let b = BorderLines(template: canvasTestTemplate())
    #expect(b.lines.count == 2)
    // Between field 0 and field 1: from the top edge to the bottom edge, ends kept exactly.
    let open = try #require(b.lines.first { !$0.closed })
    #expect(open.points.first == CGPoint(x: 4, y: 0))
    #expect(open.points.last == CGPoint(x: 4, y: 4))
    // Around field 2: a closed loop whose square corners got rounded off.
    let loop = try #require(b.lines.first { $0.closed })
    #expect(loop.points.count == 8)
    for corner in [CGPoint(x: 5, y: 1), CGPoint(x: 7, y: 1), CGPoint(x: 7, y: 3), CGPoint(x: 5, y: 3)] {
        #expect(!loop.points.contains(corner))
    }
    #expect(b.lineIndices(in: CGRect(x: 5, y: 1, width: 1, height: 1)).count == 2)
}

@Test func pixelStaircaseBecomesAStraightLine() {
    let n = 20
    let colors = (0..<(n * n)).map { i in UInt8(i % n > i / n ? 1 : 0) }
    let t = Template(width: n, height: n, palette: [PaletteColor(r: 0, g: 0, b: 0), PaletteColor(r: 255, g: 255, b: 255)],
                     colorOfPixel: colors)
    let traced = BorderLines.trace(t)
    #expect(traced.count == 1)
    let raw = traced[0].points
    let smooth = BorderLines.smooth(raw, closed: false)
    #expect(smooth.first == raw.first && smooth.last == raw.last)
    // The staircase corners sit 0.35 off the diagonal y = x − 0.5; smoothed, the line is on it.
    let off = { (p: CGPoint) in abs(p.x - 0.5 - p.y) / 2.squareRoot() }
    #expect(raw.dropFirst(6).dropLast(6).allSatisfy { off($0) > 0.3 })
    #expect(smooth.dropFirst(6).dropLast(6).allSatisfy { off($0) < 0.05 })
}
