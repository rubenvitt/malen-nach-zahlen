import CoreGraphics
import Testing
@testable import Malen

@MainActor @Test func sessionFiresCallbacksAndUndoRestoresProgress() {
    let s = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil)
    var fields: [Int32] = [], colors: [Int] = [], ends = 0
    s.onFieldCompleted = { fields.append($0) }
    s.onColorCompleted = { colors.append($0) }
    s.onStrokeEnded = { ends += 1 }

    s.selectedColor = 0
    s.beginStroke(radius: 4)
    _ = s.continueStroke([CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4)], predicted: [])
    _ = s.endStroke()
    #expect(fields == [0, 2])              // the stroke crosses every field; colour 0 counts
    #expect(colors == [0])
    #expect(ends == 1)
    #expect(s.completedColors == [0])
    #expect(s.progressByColor == [1, 0])
    #expect(s.canUndo)
    #expect(!s.isComplete)

    s.undo()
    #expect(s.progress == 0)
    #expect(s.completedColors.isEmpty)
    #expect(!s.canUndo)
    #expect(ends == 2)

    // Another colour lands anywhere, but does not count.
    s.selectedColor = 1
    s.beginStroke(radius: 2)
    _ = s.continueStroke([CGPoint(x: 1, y: 1)], predicted: [])
    _ = s.endStroke()
    #expect(s.canUndo)
    #expect(ends == 3)
    #expect(s.progress == 0)
    #expect(s.paintColorData() != nil)
}

@MainActor @Test func sessionPNGRoundTripAndRender() {
    let s = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil)
    s.beginStroke(radius: 1.2)
    _ = s.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 12, y: 6)], predicted: [])
    _ = s.endStroke()
    let back = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: s.paintLayerPNG(),
                               paintColors: s.paintColorData())
    #expect(back.layer.coverage == s.layer.coverage)
    #expect(back.progressByColor == s.progressByColor)

    let image = s.renderFinished(showLines: true, maxSide: 400)
    #expect(image.size == CGSize(width: 400, height: 200))
    #expect(s.renderFinished(showLines: false, maxSide: 80).size == CGSize(width: 80, height: 40))
}

@MainActor @Test func pickingAColourEndsShading() {
    let s = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil)
    s.tool = .crayon
    s.tool = .shadow
    s.selectColor(1)
    #expect(s.tool == .crayon)
    #expect(s.selectedColor == 1)
    s.tool = .airbrush
    s.selectColor(0)
    #expect(s.tool == .airbrush)
    s.tool = .eraser
    s.selectColor(1)
    #expect(s.tool == .airbrush)
}

@MainActor @Test func brushSizeIsStepless_perTool() {
    let s = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil)
    s.tool = .pencil
    s.brushDiameter = 2.7
    #expect(s.brushDiameter == 2.7)
    s.brushDiameter = 0.1                                            // clamped to the finest size
    #expect(s.brushDiameter == PaintingSession.diameterRange.lowerBound)
    s.tool = .airbrush
    s.brushDiameter = 50
    s.tool = .pencil
    #expect(s.brushDiameter == PaintingSession.diameterRange.lowerBound)   // each tool keeps its own
    s.brush = .large
    #expect(s.brushDiameter == BrushSize.large.diameter && s.brush == .large)
}

@MainActor @Test func fieldBoundsCoverEachField() {
    let b = PaintingSession.fieldBounds(of: canvasTestTemplate())
    #expect(b[0] == PixelRect(x0: 0, y0: 0, x1: 4, y1: 4))
    #expect(b[1] == PixelRect(x0: 4, y0: 0, x1: 8, y1: 4))
    #expect(b[2] == PixelRect(x0: 5, y0: 1, x1: 7, y1: 3))
}

@MainActor @Test func findingOpenFieldsGoesThroughTheSelectedColourFirst() {
    let s = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil)
    s.selectedColor = 0
    #expect(s.showNextOpenField() == 0)
    #expect(s.showNextOpenField() == 2)                               // field 1 has colour 1
    #expect(s.showNextOpenField() == 0)                               // and round again
    // Colour 0 done: any open field, here only field 1.
    s.beginStroke(radius: 40)
    _ = s.continueStroke([CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4)], predicted: [])
    _ = s.endStroke()
    #expect(s.completedColors.contains(0) && !s.completedColors.contains(1))
    #expect(s.showNextOpenField() == 1)
    #expect(s.showNextOpenField() == 1)
    s.selectColor(1)
    s.beginStroke(radius: 40)
    _ = s.continueStroke([CGPoint(x: 0, y: 4), CGPoint(x: 16, y: 4)], predicted: [])
    _ = s.endStroke()
    // Colour 1 over everything: field 1 done, fields 0 and 2 open again (wrong colour on them).
    #expect(s.showNextOpenField() == 2)
    #expect(s.showNextOpenField() == 0)
}
