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

/// The screen's centre, in picture points.
@MainActor private func centrePoint(_ view: PaintCanvasView) -> CGPoint {
    contentPoint(view, CGPoint(x: view.bounds.midX, y: view.bounds.midY))
}

@MainActor @Test func everyEdgeReachesTheMiddleButNoFurther() {
    let view = makeCanvas()
    view.zoomForTesting(4)
    let t = view.session.template, inset = view.contentInsetForTesting
    let zoomed = CGSize(width: CGFloat(t.width) * view.zoomScaleForTesting, height: CGFloat(t.height) * view.zoomScaleForTesting)
    let side = hypot(view.bounds.width, view.bounds.height).rounded(.up)
    // Scrolled all the way to the top left: the picture's top left corner sits in the middle.
    view.contentOffsetForTesting = CGPoint(x: -inset.left, y: -inset.top)
    #expect(close(centrePoint(view), .zero, 0.05))
    // All the way to the bottom right: the bottom right corner sits in the middle.
    view.contentOffsetForTesting = CGPoint(x: zoomed.width + inset.right - side, y: zoomed.height + inset.bottom - side)
    #expect(close(centrePoint(view), CGPoint(x: CGFloat(t.width), y: CGFloat(t.height)), 0.05))
}

@MainActor @Test func turningAtTheEdgeKeepsThePictureInTheMiddle() {
    let view = makeCanvas()
    view.zoomForTesting(4)
    let inset = view.contentInsetForTesting
    view.contentOffsetForTesting = CGPoint(x: -inset.left, y: -inset.top)
    // Turning around a point near the screen's edge would swing the corner past the middle.
    view.rotate(by: .pi / 2, around: CGPoint(x: 20, y: 280))
    let t = view.session.template, c = centrePoint(view)
    #expect(c.x >= -0.05 && c.x <= CGFloat(t.width) + 0.05)
    #expect(c.y >= -0.05 && c.y <= CGFloat(t.height) + 0.05)
}

@MainActor @Test func findingAnOpenFieldCentresAndLightsItUp() {
    let view = makeCanvas()
    view.rotate(by: 0.4, around: CGPoint(x: 120, y: 80))
    view.focus(onField: 2, bounds: PixelRect(x0: 5, y0: 1, x1: 7, y1: 3))
    #expect(close(contentPoint(view, CGPoint(x: 200, y: 150)), CGPoint(x: 6, y: 2)))
    #expect(abs(view.rotation - 0.4) < 1e-6)                          // the paper keeps its turn
    let glow = view.flashLayerForTesting
    #expect(glow?.frame == CGRect(x: 5, y: 1, width: 2, height: 2))
    #expect(glow?.contents != nil)
}
