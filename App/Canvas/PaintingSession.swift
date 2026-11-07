import UIKit
import Observation
import PaintEngine

// API fixed by docs/superpowers/specs/2026-11-06-malen-design.md §4.2 (members may be added, not removed).

enum BrushSize: CaseIterable, Codable {
    case small, medium, large

    /// Brush diameter in screen points; stays the same on screen at every zoom level.
    var diameter: CGFloat {
        switch self {
        case .small: 8
        case .medium: 18
        case .large: 36
        }
    }
}

@MainActor @Observable final class PaintingSession {
    let template: Template
    var selectedColor = 0
    var brush: BrushSize = .medium
    private(set) var progressByColor: [Double]
    private(set) var progress: Double = 0
    private(set) var completedColors: Set<Int> = []
    private(set) var canUndo = false
    var isComplete: Bool { completedColors.count == template.palette.count }
    @ObservationIgnored var onStrokeEnded: (() -> Void)?
    @ObservationIgnored var onFieldCompleted: ((Int32) -> Void)?
    @ObservationIgnored var onColorCompleted: ((Int) -> Void)?

    @ObservationIgnored let layer: PaintLayer
    @ObservationIgnored let art: TemplateArt
    @ObservationIgnored weak var canvasView: PaintCanvasView?
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0

    /// `paintLayerPNG` is what `paintLayerPNG()` returned earlier; a PNG of the wrong size is ignored.
    init(template: Template, paintLayerPNG: Data?) {
        self.template = template
        layer = PaintLayer(template: template, png: paintLayerPNG)
        art = TemplateArt(template: template)
        progressByColor = Array(repeating: 0, count: template.palette.count)
        publish()
    }

    /// Undoes the last stroke (at least 30 steps back), progress included. Ignored mid-stroke.
    func undo() {
        guard let dirty = layer.undo() else { return }
        canvasView?.redraw(dirty)
        publish()
        onStrokeEnded?()
    }

    /// Zooms out to show the whole picture ("Ganzes Bild").
    func showWholePicture() { canvasView?.zoomToFit(animated: true) }

    /// Coverage of the paint layer as an 8-bit grey PNG (2 px per grid pixel). Not a viewable
    /// picture; use `renderFinished` for that. Round-trips exactly through `init`.
    func paintLayerPNG() -> Data { layer.pngData() }

    /// The picture as painted so far, on white. `showLines` adds borders and the numbers that are
    /// still readable at that size. `maxSide` is the longest side in pixels.
    func renderFinished(showLines: Bool, maxSide: Int) -> UIImage {
        let w = CGFloat(template.width), h = CGFloat(template.height)
        let s = CGFloat(max(1, maxSide)) / max(w, h, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let paint = layer.makeImage(PixelRect(x0: 0, y0: 0, x1: layer.width, y1: layer.height))
        let size = CGSize(width: max(1, (w * s).rounded()), height: max(1, (h * s).rounded()))
        return UIGraphicsImageRenderer(size: size, format: format).image { [art] r in
            let ctx = r.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: s, y: s)
            let all = CGRect(x: 0, y: 0, width: w, height: h)
            if showLines { art.drawNumbers(in: ctx, rect: all) }
            ctx.interpolationQuality = .high
            if let paint { UIImage(cgImage: paint).draw(in: all) }
            if showLines { art.drawBorders(in: ctx, rect: all) }
        }
    }

    // MARK: Used by PaintCanvasView (points and radius in paint pixels)

    func beginStroke(radius: Double) {
        layer.beginStroke(color: min(max(0, selectedColor), template.palette.count - 1), radius: radius)
    }

    func continueStroke(_ points: [CGPoint], predicted: [CGPoint]) -> PixelRect? {
        let change = layer.continueStroke(points, predicted: predicted)
        let now = CACurrentMediaTime()
        // Rings move live, but at most ~10× per second so SwiftUI does not re-render at 120 Hz.
        if !change.completedFields.isEmpty || now - lastPublish > 0.1 { publish(); lastPublish = now }
        change.completedFields.forEach { onFieldCompleted?($0) }
        change.completedColors.forEach { onColorCompleted?($0) }
        return change.dirty
    }

    func endStroke() -> PixelRect? {
        let change = layer.endStroke()
        publish()
        if change.committed { onStrokeEnded?() }
        return change.dirty
    }

    func cancelStroke() -> PixelRect? {
        let dirty = layer.cancelStroke()
        publish()
        return dirty
    }

    private func publish() {
        let byColor = template.palette.indices.map(layer.progress(ofColor:))
        if byColor != progressByColor { progressByColor = byColor }
        if layer.progress != progress { progress = layer.progress }
        let done = layer.completedColors
        if done != completedColors { completedColors = done }
        if layer.canUndo != canUndo { canUndo = layer.canUndo }
    }
}
