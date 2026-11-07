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
    #expect(fields == [0])                 // one stroke stays in one field
    #expect(colors.isEmpty)
    s.beginStroke(radius: 4)
    _ = s.continueStroke([CGPoint(x: 12, y: 4)], predicted: [])
    _ = s.endStroke()
    #expect(fields == [0, 2])
    #expect(colors == [0])
    #expect(ends == 2)
    #expect(s.completedColors == [0])
    #expect(s.progressByColor == [1, 0])
    #expect(s.canUndo)
    #expect(!s.isComplete)

    s.undo()
    s.undo()
    #expect(s.progress == 0)
    #expect(s.completedColors.isEmpty)
    #expect(!s.canUndo)
    #expect(ends == 4)

    // A stroke in a foreign colour's field changes nothing and is no undo step.
    s.selectedColor = 1
    s.beginStroke(radius: 2)
    _ = s.continueStroke([CGPoint(x: 1, y: 1)], predicted: [])
    _ = s.endStroke()
    #expect(!s.canUndo)
    #expect(ends == 4)

    // Without the overpaint protection it lands there, but does not count.
    s.overpaintProtection = false
    s.beginStroke(radius: 2)
    _ = s.continueStroke([CGPoint(x: 1, y: 1)], predicted: [])
    _ = s.endStroke()
    #expect(s.canUndo)
    #expect(s.progress == 0)
    #expect(s.paintColorData() != nil)
}

@MainActor @Test func sessionPNGRoundTripAndRender() {
    let s = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil)
    s.beginStroke(radius: 1.2)
    _ = s.continueStroke([CGPoint(x: 1, y: 1), CGPoint(x: 12, y: 6)], predicted: [])
    _ = s.endStroke()
    let back = PaintingSession(template: canvasTestTemplate(), paintLayerPNG: s.paintLayerPNG())
    #expect(back.layer.coverage == s.layer.coverage)
    #expect(back.progressByColor == s.progressByColor)

    let image = s.renderFinished(showLines: true, maxSide: 400)
    #expect(image.size == CGSize(width: 400, height: 200))
    #expect(s.renderFinished(showLines: false, maxSide: 80).size == CGSize(width: 80, height: 40))
}
