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
