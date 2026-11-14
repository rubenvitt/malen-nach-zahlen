import CoreGraphics
import Foundation
import Testing
import PaintEngine
@testable import Malen

/// 8×4 grid: left half colour 0 / field 0, right half colour 1 / field 1, plus a 2×2 field 2 of
/// colour 0 inside the right half (rows 1–2, columns 5–6) so colour 0 has two fields.
func canvasTestTemplate() -> Template {
    let w = 8, h = 4
    var color = [UInt8](repeating: 0, count: w * h), field = [Int32](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 4..<w { color[y * w + x] = 1; field[y * w + x] = 1 }
    }
    for y in 1...2 { for x in 5...6 { color[y * w + x] = 0; field[y * w + x] = 2 } }
    return Template(width: w, height: h,
                    palette: [PaletteColor(r: 200, g: 40, b: 40), PaletteColor(r: 40, g: 40, b: 200)],
                    colorOfPixel: color, fieldOfPixel: field, colorOfField: [0, 1, 0], sizeOfField: [16, 12, 4],
                    spots: [NumberSpot(x: 1, y: 1, radius: 1, field: 0), NumberSpot(x: 4, y: 0, radius: 1, field: 1),
                            NumberSpot(x: 5, y: 1, radius: 1, field: 2)])
}

private func cov(_ l: PaintLayer, gridX: Int, gridY: Int) -> [UInt8] {
    let s = PaintLayer.scale
    return (0..<s).flatMap { dy in (0..<s).map { dx in l.coverage[(gridY * s + dy) * l.width + gridX * s + dx] } }
}

private func strokeAcross(_ l: PaintLayer, color: Int, y: CGFloat, radius: Double = 1.5) -> StrokeChange {
    l.beginStroke(color: color, radius: radius)
    var change = l.continueStroke([CGPoint(x: 0, y: y), CGPoint(x: 16, y: y)])
    change.dirty = l.endStroke().dirty.map { $0.union(change.dirty) } ?? change.dirty
    return change
}

@Test func sameColourOverFullPaintIsNoUndoStep() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 1)
    #expect(!l.endStroke().committed)
    _ = strokeAcross(l, color: 0, y: 4, radius: 4)
    #expect(l.canUndo)
    l.beginStroke(color: 0, radius: 2)
    _ = l.continueStroke([CGPoint(x: 2, y: 2)])
    #expect(!l.endStroke().committed)
}

@Test func strokeCrossesAllFieldsButCountsOnlyItsColour() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 4)
    _ = l.continueStroke([CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4)])   // fields 0, 1, 2
    #expect(l.endStroke().committed)
    #expect(cov(l, gridX: 4, gridY: 1).allSatisfy { $0 == 255 })      // field 1, wrong colour
    #expect(l.paintColor[2 * l.width + 8] == 0)
    #expect(l.paintedOfField[1] == 0)
    #expect(l.progress(ofColor: 1) == 0)
    #expect(l.fieldComplete[0] && l.fieldComplete[2])               // right colour counts as usual
    // Finished fields are not locked: painting over them opens them again, undo brings them back.
    l.beginStroke(color: 1, radius: 2)
    _ = l.continueStroke([CGPoint(x: 2, y: 4)])
    #expect(l.endStroke().committed)
    #expect(l.paintColor[3 * l.width + 3] == 1)
    #expect(l.paintedOfField[0] == 13)
    #expect(!l.fieldComplete[0])
    _ = l.undo()
    #expect(l.fieldComplete[0])
    // The right colour paints over the wrong one and counts; it also eats into field 2 (now
    // 2 of 4, open again).
    l.beginStroke(color: 1, radius: 3)
    _ = l.continueStroke([CGPoint(x: 9, y: 1), CGPoint(x: 15, y: 1)])
    _ = l.endStroke()
    #expect(l.paintColor[1 * l.width + 15] == 1)
    #expect(l.paintedOfField[1] > 0)
    #expect(l.paintedOfField[2] == 2)
    #expect(!l.fieldComplete[2])
}

@Test func wrongColourOverRightPaintTakesProgressBackAndUndoRestoresIt() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 0.75)
    _ = l.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 7, y: 1)])
    _ = l.endStroke()
    #expect(l.paintedOfField[0] == 4)
    let pixels = l.coverage, colors = l.paintColor
    l.beginStroke(color: 1, radius: 0.75)
    _ = l.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1)])
    _ = l.endStroke()
    #expect(l.paintedOfField[0] == 2)
    #expect(l.progress(ofColor: 0) == 2.0 / 20.0)
    _ = l.undo()
    #expect(l.paintedOfField[0] == 4)
    #expect(l.coverage == pixels)
    #expect(l.paintColor == colors)
}

@Test func colourDataRoundTripsWrongPaint() throws {
    let t = canvasTestTemplate()
    let l = PaintLayer(template: t)
    l.beginStroke(color: 0, radius: 1.1)
    _ = l.continueStroke([CGPoint(x: 1, y: 1.3), CGPoint(x: 6, y: 1.3)])   // stays in field 0
    _ = l.endStroke()
    #expect(l.colorData() == nil)                      // all paint has its colour: no colour file
    l.beginStroke(color: 0, radius: 1.4)
    _ = l.continueStroke([CGPoint(x: 15, y: 5.7), CGPoint(x: 8, y: 5.7)])
    _ = l.endStroke()
    let colors = try #require(l.colorData())
    let back = PaintLayer(template: t, png: l.pngData(), colors: colors)
    #expect(back.coverage == l.coverage)
    #expect(back.paintColor == l.paintColor)
    #expect(back.paintedOfField == l.paintedOfField)
    #expect(back.progress == l.progress)
    // Without the colour file the wrong paint would count; garbage is ignored the same way.
    #expect(PaintLayer(template: t, png: l.pngData(), colors: Data([1, 2, 3])).paintedOfField[1] > 0)
}

@Test func fieldsCountAsDoneWhenNearlyFullAndAreNeverFilled() {
    let l = PaintLayer(template: canvasTestTemplate())
    #expect(l.progress == 0)
    // Grid rows 0–1 of field 0: 8 of 16 pixels.
    // Paint pixel centres sit at 2·grid + 1.5.
    l.beginStroke(color: 0, radius: 0.75)
    var change = l.continueStroke([CGPoint(x: 1.5, y: 1.5), CGPoint(x: 7.5, y: 1.5), CGPoint(x: 7.5, y: 3.5),
                                   CGPoint(x: 1.5, y: 3.5)])
    _ = l.endStroke()
    #expect(l.paintedOfField[0] == 8)
    #expect(l.paintedOfField[1] == 0 && l.paintedOfField[2] == 0)
    #expect(change.completedFields.isEmpty)
    // 15 of 16: one pixel left counts as done, but that pixel stays blank.
    l.beginStroke(color: 0, radius: 0.75)
    change = l.continueStroke([CGPoint(x: 1.5, y: 5.5), CGPoint(x: 7.5, y: 5.5), CGPoint(x: 7.5, y: 7.5),
                               CGPoint(x: 3.5, y: 7.5)])
    _ = l.endStroke()
    #expect(l.paintedOfField[0] == 15)
    #expect(change.completedFields == [0])
    #expect(change.completedColors.isEmpty)
    #expect(l.coverage[7 * l.width + 1] == 0)          // grid (0, 3): nothing filled in
    #expect(l.progress(ofColor: 0) == 16.0 / 20.0)     // a done field counts in full
    // All of field 2 → colour 0 complete.
    l.beginStroke(color: 0, radius: 0.75)
    change = l.continueStroke([CGPoint(x: 11.5, y: 3.5), CGPoint(x: 13.5, y: 3.5), CGPoint(x: 13.5, y: 5.5),
                               CGPoint(x: 11.5, y: 5.5)])
    _ = l.endStroke()
    #expect(change.completedFields == [2])
    #expect(change.completedColors == [0])
    #expect(l.isColorComplete(0))
    #expect(l.completedColors == [0])
    #expect(l.progress(ofColor: 0) == 1)
    #expect(l.progress(ofColor: 1) == 0)
    #expect(l.progress == 20.0 / 32.0)
    #expect(!l.isComplete)
    // Another colour over field 0 opens it again.
    l.beginStroke(color: 1, radius: 0.75)
    _ = l.continueStroke([CGPoint(x: 1.5, y: 1.5)])
    _ = l.endStroke()
    #expect(l.paintedOfField[0] == 14)
    #expect(!l.fieldComplete[0])
    #expect(!l.isColorComplete(0))
    #expect(l.progress(ofColor: 0) == 18.0 / 20.0)
}

@Test func ninetyPercentCountsButNothingGetsFilled() {
    // One field of 40 px, so 36 painted = 90 %.
    let w = 40
    let t = Template(width: w, height: 1, palette: [PaletteColor(r: 1, g: 2, b: 3)],
                     colorOfPixel: [UInt8](repeating: 0, count: w), fieldOfPixel: [Int32](repeating: 0, count: w),
                     colorOfField: [0], sizeOfField: [Int32(w)], spots: [NumberSpot(x: 0, y: 0, radius: 1, field: 0)])
    let l = PaintLayer(template: t)
    l.beginStroke(color: 0, radius: 0.75)
    var change = l.continueStroke([CGPoint(x: 1.5, y: 1.5), CGPoint(x: 69.5, y: 1.5)])   // grid 0...34 = 35 px
    #expect(l.paintedOfField[0] == 35)
    #expect(change.completedFields.isEmpty)
    change = l.continueStroke([CGPoint(x: 71.5, y: 1.5)])                               // 36 px
    _ = l.endStroke()
    #expect(change.completedFields == [0])
    #expect(l.coverage.contains(0))
    #expect(l.isComplete)
    #expect(l.progress == 1)
    #expect(PaintLayer.isDone(painted: 1, size: 1))
    #expect(!PaintLayer.isDone(painted: 0, size: 1))
    #expect(!PaintLayer.isDone(painted: 17, size: 20))
}

@Test func undoRestoresPixelsAndProgressExactly() {
    let l = PaintLayer(template: canvasTestTemplate())
    _ = strokeAcross(l, color: 0, y: 1, radius: 1.3)
    let pixels = l.coverage, painted = l.paintedOfField, complete = l.fieldComplete
    let progress = (0..<2).map(l.progress(ofColor:))
    _ = strokeAcross(l, color: 0, y: 4, radius: 4)       // completes field 0
    #expect(l.fieldComplete[0])
    #expect(l.coverage != pixels)
    let dirty = l.undo()
    #expect(dirty != nil)
    #expect(l.coverage == pixels)
    #expect(l.paintedOfField == painted)
    #expect(l.fieldComplete == complete)
    #expect((0..<2).map(l.progress(ofColor:)) == progress)
    #expect(!l.fieldComplete[0])
    _ = l.undo()
    #expect(l.coverage.allSatisfy { $0 == 0 })
    #expect(l.progress == 0)
    #expect(!l.canUndo)
}

@Test func undoKeepsAtLeastThirtySteps() {
    let l = PaintLayer(template: canvasTestTemplate())
    for i in 0..<40 {
        l.beginStroke(color: 0, radius: 0.75)
        _ = l.continueStroke([CGPoint(x: CGFloat(i % 8) + 0.5, y: CGFloat(i / 8) + 0.5)])
        _ = l.endStroke()
    }
    var steps = 0
    while l.undo() != nil { steps += 1 }
    #expect(steps >= 30)
    #expect(l.coverage.allSatisfy { $0 == 0 })
}

@Test func cancelRevertsRunningStroke() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 3)
    _ = l.continueStroke([CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4)])
    #expect(l.progress > 0)
    #expect(l.cancelStroke() != nil)
    #expect(l.coverage.allSatisfy { $0 == 0 })
    #expect(l.progress == 0)
    #expect(!l.canUndo)
}

@Test func predictedPointsNeverStick() {
    let a = PaintLayer(template: canvasTestTemplate()), b = PaintLayer(template: canvasTestTemplate())
    a.beginStroke(color: 0, radius: 1.2)
    b.beginStroke(color: 0, radius: 1.2)
    _ = a.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1)], predicted: [CGPoint(x: 6, y: 6)])
    _ = b.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1)])
    #expect(a.coverage != b.coverage)                 // the preview is visible …
    #expect(a.pngData() == b.pngData())               // … but never exported
    #expect(a.paintedOfField == b.paintedOfField)     // … nor counted
    _ = a.continueStroke([CGPoint(x: 4, y: 2)], predicted: [CGPoint(x: 7, y: 7)])
    _ = b.continueStroke([CGPoint(x: 4, y: 2)])
    _ = a.endStroke(); _ = b.endStroke()
    #expect(a.coverage == b.coverage)
    _ = a.undo(); _ = b.undo()
    #expect(a.coverage.allSatisfy { $0 == 0 })
}

@Test func pngRoundTripIsExact() throws {
    let t = canvasTestTemplate()
    let l = PaintLayer(template: t)
    _ = strokeAcross(l, color: 0, y: 1.3, radius: 1.1)    // soft, partial coverage values
    l.beginStroke(color: 1, radius: 0.9)
    _ = l.continueStroke([CGPoint(x: 15, y: 5.7), CGPoint(x: 8, y: 5.7)])
    _ = l.endStroke()
    #expect(l.paintedOfField[1] > 0)
    #expect(l.coverage.contains { $0 > 0 && $0 < 255 })
    let png = l.pngData()
    #expect(!png.isEmpty)
    let back = PaintLayer(template: t, png: png, colors: l.colorData())   // strokes crossed foreign fields
    #expect(back.coverage == l.coverage)
    #expect(back.paintedOfField == l.paintedOfField)
    #expect(back.fieldComplete == l.fieldComplete)
    #expect(back.progress == l.progress)
}

@Test func pngOfWrongSizeIsIgnored() {
    let small = PaintLayer(template: Template(width: 1, height: 1, palette: [PaletteColor(r: 0, g: 0, b: 0)],
                                              colorOfPixel: [0], fieldOfPixel: [0], colorOfField: [0], sizeOfField: [1],
                                              spots: []))
    let l = PaintLayer(template: canvasTestTemplate(), png: small.pngData())
    #expect(l.coverage.allSatisfy { $0 == 0 })
    let garbage = PaintLayer(template: canvasTestTemplate(), png: Data([1, 2, 3]))
    #expect(garbage.progress == 0)
}

// MARK: Mixing, brush types, shading

@Test func otherColourOverPaintNeverLetsWhiteThrough() {
    let l = PaintLayer(template: canvasTestTemplate())
    _ = strokeAcross(l, color: 0, y: 4, radius: 6)                   // everything solid colour 0
    #expect(l.coverage.allSatisfy { $0 == 255 })
    l.beginStroke(color: 1, radius: 1.3)
    _ = l.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    _ = l.endStroke()
    // The soft edge of the new stroke used to replace solid paint with thin paint: a white seam.
    #expect(l.coverage.allSatisfy { $0 == 255 })
    let under = l.plane(.under), mix = l.plane(.mix)
    let core = 3 * l.width + 8, edge = 2 * l.width + 8, outside = 1 * l.width + 8
    #expect(l.paintColor[core] == 1 && mix[core] == 0)
    // At the edge both colours blend; the stronger one (still the old) is the pixel's colour.
    #expect(l.paintColor[edge] == 0 && under[edge] == 1 && mix[edge] > 0 && mix[edge] < 128)
    #expect(l.paintColor[outside] == 0 && mix[outside] == 0)
}

@Test func shadingChangesOnlyTheShade() throws {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 0, radius: 2, kind: .shadow)
    _ = l.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    #expect(!l.endStroke().committed)                                 // bare paper: nothing to shade
    _ = strokeAcross(l, color: 0, y: 4, radius: 6)
    let coverage = l.coverage, colors = l.paintColor, painted = l.paintedOfField, progress = l.progress
    l.beginStroke(color: 1, radius: 2, kind: .shadow)                 // the selected colour does not matter
    _ = l.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    #expect(l.endStroke().committed)
    let centre = 4 * l.width + 8
    let dark = l.shade[centre]
    #expect(dark < PaintLayer.neutralShade)
    #expect(l.coverage == coverage && l.paintColor == colors)
    #expect(l.paintedOfField == painted && l.progress == progress)

    let image = try #require(l.makeImage(PixelRect(x0: 8, y0: 4, x1: 9, y1: 5)))
    let bytes = try #require(image.dataProvider?.data.map { $0 as Data })
    #expect(bytes[0] < 200 && bytes[3] == 255)                        // colour 0 is r = 200 unshaded

    l.beginStroke(color: 0, radius: 2, kind: .light)
    _ = l.continueStroke([CGPoint(x: 8, y: 4)], pressures: [1])
    _ = l.endStroke()
    #expect(l.shade[centre] > dark)
    _ = l.undo()
    #expect(l.shade[centre] == dark)
    // Painting the colour on again with the brush wipes the shading off.
    _ = strokeAcross(l, color: 0, y: 4, radius: 6)
    #expect(l.shade.allSatisfy { $0 == PaintLayer.neutralShade })
}

@Test func crayonLeavesGrainAndFillsUpWhenGoneOverAgain() {
    let l = PaintLayer(template: canvasTestTemplate())
    func crayon() {
        l.beginStroke(color: 0, radius: 6, kind: .crayon)
        _ = l.continueStroke([CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4)], pressures: [0.6, 0.6])
        _ = l.endStroke()
    }
    crayon()
    let once = l.coverage
    #expect(once.allSatisfy { $0 > 0 })
    #expect(once.contains { $0 < 255 })
    crayon()
    #expect(zip(l.coverage, once).allSatisfy { $0 >= $1 })
    #expect(zip(l.coverage, once).contains { $0 > $1 })
}

@Test func airbrushIsSeeThroughAndBuildsUp() {
    let centre = 4 * 16 + 8
    let l = PaintLayer(template: canvasTestTemplate())
    func spray(_ layer: PaintLayer, _ color: Int) {
        layer.beginStroke(color: color, radius: 3, kind: .airbrush)
        _ = layer.continueStroke([CGPoint(x: 8, y: 4)])
        _ = layer.endStroke()
    }
    spray(l, 0)
    let once = l.coverage[centre]
    #expect(once > 0 && once < 128)
    spray(l, 0)
    #expect(l.coverage[centre] > once)

    // Over another colour it glazes: the old colour stays and the new one is mixed in.
    let g = PaintLayer(template: canvasTestTemplate())
    _ = strokeAcross(g, color: 0, y: 4, radius: 6)
    spray(g, 1)
    #expect(g.coverage[centre] == 255 && g.paintColor[centre] == 0)
    #expect(g.plane(.under)[centre] == 1 && g.plane(.mix)[centre] > 0)
}

@Test func shadeAndMixSurviveSaving() throws {
    let t = canvasTestTemplate()
    let l = PaintLayer(template: t)
    _ = strokeAcross(l, color: 0, y: 4, radius: 6)
    l.beginStroke(color: 1, radius: 1.3)
    _ = l.continueStroke([CGPoint(x: 2, y: 4), CGPoint(x: 14, y: 4)])
    _ = l.endStroke()
    l.beginStroke(color: 0, radius: 2, kind: .shadow)
    _ = l.continueStroke([CGPoint(x: 4, y: 4)])
    _ = l.endStroke()
    let back = PaintLayer(template: t, png: l.pngData(), colors: try #require(l.colorData()))
    for plane in PaintLayer.Plane.allCases { #expect(back.plane(plane) == l.plane(plane), "\(plane)") }
    #expect(back.paintedOfField == l.paintedOfField)
    #expect(back.progress == l.progress)
}

@Test func pencilLineWidensWithPressure() {
    func width(pressure: Double) -> Int {
        let l = PaintLayer(template: canvasTestTemplate())
        l.beginStroke(color: 0, radius: 3, kind: .pencil)
        _ = l.continueStroke([CGPoint(x: 1, y: 4), CGPoint(x: 15, y: 4)], pressures: [pressure, pressure])
        _ = l.endStroke()
        // Covered pixels down the middle column.
        return (0..<l.height).filter { l.coverage[$0 * l.width + 8] >= 128 }.count
    }
    let light = width(pressure: 0.2), firm = width(pressure: 1)
    #expect(light >= 1)
    #expect(firm > light)
    #expect(firm <= 6)                                                // never wider than the size
}
