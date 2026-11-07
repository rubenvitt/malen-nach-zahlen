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

@Test func strokeAcrossForeignFieldLeavesItUntouched() {
    let l = PaintLayer(template: canvasTestTemplate())
    _ = strokeAcross(l, color: 0, y: 1)   // row 0 only: field 0 (colour 0) then field 1 (colour 1)
    let t = l.template
    for gx in 0..<8 { for gy in 0..<4 where t.colorOfPixel[gy * 8 + gx] == 1 {
        #expect(cov(l, gridX: gx, gridY: gy).allSatisfy { $0 == 0 })
    } }
    #expect(cov(l, gridX: 1, gridY: 0).contains { $0 > 0 })
    #expect(cov(l, gridX: 7, gridY: 0).allSatisfy { $0 == 0 })
    #expect(l.paintedOfField[1] == 0)
    #expect(l.progress(ofColor: 1) == 0)
}

@Test func strokeThatChangesNothingIsNoUndoStep() {
    let l = PaintLayer(template: canvasTestTemplate())
    l.beginStroke(color: 1, radius: 1)
    _ = l.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 3)])   // only colour 0 there
    #expect(!l.endStroke().committed)
    #expect(!l.canUndo)
    // Painting into an already completed field is no undo step either.
    _ = strokeAcross(l, color: 0, y: 4, radius: 4)
    #expect(l.fieldComplete[0])
    #expect(l.canUndo)
    _ = l.undo()
    _ = strokeAcross(l, color: 0, y: 4, radius: 4)
    l.beginStroke(color: 0, radius: 2)
    _ = l.continueStroke([CGPoint(x: 2, y: 2)])
    #expect(!l.endStroke().committed)
}

@Test func strokeReachesSameColouredFieldInsideForeignField() {
    let l = PaintLayer(template: canvasTestTemplate())
    _ = strokeAcross(l, color: 0, y: 4, radius: 3)    // rows 1–2 cover field 2
    #expect(cov(l, gridX: 5, gridY: 1).allSatisfy { $0 == 255 })
    #expect(cov(l, gridX: 4, gridY: 1).allSatisfy { $0 == 0 })   // field 1 between them
    #expect(cov(l, gridX: 7, gridY: 2).allSatisfy { $0 == 0 })
}

@Test func progressCompletesFieldsAndColour() {
    let l = PaintLayer(template: canvasTestTemplate())
    #expect(l.progress == 0)
    // Grid rows 0–1: 8 of 16 pixels of field 0, 2 of 4 of field 2.
    var change = strokeAcross(l, color: 0, y: 2, radius: 2)
    #expect(l.paintedOfField[0] == 8)
    #expect(l.paintedOfField[2] == 2)
    #expect(change.completedFields.isEmpty)
    // 15 of 16 pixels of field 0 = 93.75 % → still open.
    l.beginStroke(color: 0, radius: 0.75)
    _ = l.continueStroke([CGPoint(x: 1, y: 5), CGPoint(x: 7, y: 5), CGPoint(x: 7, y: 7), CGPoint(x: 3, y: 7)])
    _ = l.endStroke()
    #expect(l.paintedOfField[0] == 15)
    #expect(!l.fieldComplete[0])
    // Last pixel → field 0 complete and filled cleanly; colour 0 still has field 2 open.
    l.beginStroke(color: 0, radius: 0.75)
    change = l.continueStroke([CGPoint(x: 1, y: 7)])
    _ = l.endStroke()
    #expect(change.completedFields == [0])
    #expect(change.completedColors.isEmpty)
    for gx in 0..<4 { for gy in 0..<4 { #expect(cov(l, gridX: gx, gridY: gy).allSatisfy { $0 == 255 }) } }
    // Rest of field 2 → colour 0 complete.
    l.beginStroke(color: 0, radius: 0.75)
    change = l.continueStroke([CGPoint(x: 11, y: 5), CGPoint(x: 13, y: 5)])
    _ = l.endStroke()
    #expect(change.completedFields == [2])
    #expect(change.completedColors == [0])
    #expect(l.isColorComplete(0))
    #expect(l.completedColors == [0])
    #expect(l.progress(ofColor: 0) == 1)
    #expect(l.progress(ofColor: 1) == 0)
    #expect(l.progress == 20.0 / 32.0)
    #expect(!l.isComplete)
}

@Test func ninetyFivePercentCompletesAndFillsRest() {
    // One field of 40 px, so 38 painted = 95 %.
    let w = 40
    let t = Template(width: w, height: 1, palette: [PaletteColor(r: 1, g: 2, b: 3)],
                     colorOfPixel: [UInt8](repeating: 0, count: w), fieldOfPixel: [Int32](repeating: 0, count: w),
                     colorOfField: [0], sizeOfField: [Int32(w)], spots: [NumberSpot(x: 0, y: 0, radius: 1, field: 0)])
    let l = PaintLayer(template: t)
    l.beginStroke(color: 0, radius: 0.75)
    var change = l.continueStroke([CGPoint(x: 1.5, y: 1.5), CGPoint(x: 73.5, y: 1.5)])   // grid 0...36 = 37 px
    #expect(change.completedFields.isEmpty)
    change = l.continueStroke([CGPoint(x: 75.5, y: 1.5)])                               // 38 px
    _ = l.endStroke()
    #expect(change.completedFields == [0])
    #expect(l.coverage.allSatisfy { $0 == 255 })
    #expect(l.isComplete)
    #expect(l.progress == 1)
}

@Test func undoRestoresPixelsAndProgressExactly() {
    let l = PaintLayer(template: canvasTestTemplate())
    _ = strokeAcross(l, color: 0, y: 1, radius: 1.3)
    let pixels = l.coverage, painted = l.paintedOfField, complete = l.fieldComplete
    let progress = (0..<2).map(l.progress(ofColor:))
    _ = strokeAcross(l, color: 0, y: 4, radius: 4)       // completes fields 0 and 2 → colour 0
    #expect(l.isColorComplete(0))
    #expect(l.coverage != pixels)
    let dirty = l.undo()
    #expect(dirty != nil)
    #expect(l.coverage == pixels)
    #expect(l.paintedOfField == painted)
    #expect(l.fieldComplete == complete)
    #expect((0..<2).map(l.progress(ofColor:)) == progress)
    #expect(!l.isColorComplete(0))
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
    _ = strokeAcross(l, color: 1, y: 5.7, radius: 0.9)
    #expect(l.coverage.contains { $0 > 0 && $0 < 255 })
    let png = l.pngData()
    #expect(!png.isEmpty)
    let back = PaintLayer(template: t, png: png)
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
