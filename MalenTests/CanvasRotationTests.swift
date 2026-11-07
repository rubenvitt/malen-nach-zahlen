import CoreGraphics
import Testing
import UIKit
@testable import Malen

@MainActor private func makeCanvas() -> PaintCanvasView {
    let view = PaintCanvasView(session: PaintingSession(template: canvasTestTemplate(), paintLayerPNG: nil))
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    view.layoutIfNeeded()
    return view
}

@MainActor private func contentPoint(_ view: PaintCanvasView, _ p: CGPoint) -> CGPoint {
    let content = view.contentViewForTesting
    return view.convert(p, to: content)
}

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

@MainActor @Test func rotationKeepsThePictureUnderThePivot() {
    let view = makeCanvas()
    let pivot = CGPoint(x: 260, y: 110)
    let before = contentPoint(view, pivot)
    view.rotate(by: .pi / 5, around: pivot)
    #expect(abs(view.rotation - .pi / 5) < 1e-6)
    #expect(close(contentPoint(view, pivot), before))
}

@MainActor @Test func touchesMapThroughTheRotation() {
    let view = makeCanvas()
    let center = CGPoint(x: 200, y: 150), angle = CGFloat.pi / 3
    view.rotate(by: angle, around: center)
    let zoom = view.zoomScaleForTesting
    let origin = contentPoint(view, center)
    // 50 pt to the right on screen is 50 pt along the direction turned back by the paper's angle.
    let hit = contentPoint(view, CGPoint(x: center.x + 50, y: center.y))
    let expected = CGPoint(x: origin.x + 50 * cos(-angle) / zoom, y: origin.y + 50 * sin(-angle) / zoom)
    #expect(close(hit, expected))
}

@MainActor @Test func wholePictureStraightensThePaper() {
    let view = makeCanvas()
    view.rotate(by: 2.5, around: CGPoint(x: 100, y: 100))
    view.rotate(by: 2.5, around: CGPoint(x: 100, y: 100))   // past π: wraps into (-π, π]
    #expect(view.rotation > -.pi && view.rotation <= .pi)
    view.zoomToFit(animated: false)
    #expect(view.rotation == 0)
    // Straight and fitted, the picture's centre is the screen's centre again.
    let t = view.session.template
    #expect(close(contentPoint(view, CGPoint(x: 200, y: 150)), CGPoint(x: CGFloat(t.width) / 2, y: CGFloat(t.height) / 2), 0.05))
}
