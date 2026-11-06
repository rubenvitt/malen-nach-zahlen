import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct PaintCanvas: UIViewRepresentable {
    let session: PaintingSession
    func makeUIView(context: Context) -> PaintCanvasView { PaintCanvasView(session: session) }
    func updateUIView(_ view: PaintCanvasView, context: Context) {
        if view.session !== session { view.configure(session) }
    }
}

/// Zoomable painting surface. Content coordinates are grid pixels (the content view is
/// `template.width × template.height` points at zoom 1); the paint layer has 2 px per grid pixel.
///
/// Layers, bottom to top: white + grey numbers (tiled, vector) → paint tiles → flash → borders
/// (tiled, vector). Tiled layers redraw at the current zoom, so numbers and lines stay crisp.
///
/// Input: the pencil paints, fingers pan (1) and pinch (2). Until a pencil was ever seen, a single
/// finger paints and panning needs two fingers.
final class PaintCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private(set) var session: PaintingSession
    private let scrollView = UIScrollView()
    private var content = UIView()
    private var paintTiles: [CALayer] = []
    private var flashLayer = CALayer()
    private let strokeRecognizer = StrokeRecognizer()
    private var fitScale: CGFloat = 1
    private var isAtFit = true

    private static let paintTile = 128               // paint pixels per tile layer
    private static let pencilSeenKey = "canvas.pencilSeen"
    private var pencilSeen = UserDefaults.standard.bool(forKey: PaintCanvasView.pencilSeenKey) {
        didSet {
            UserDefaults.standard.set(pencilSeen, forKey: Self.pencilSeenKey)
            updateInputMode()
        }
    }

    init(session: PaintingSession) {
        self.session = session
        super.init(frame: .zero)
        scrollView.delegate = self
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        addSubview(scrollView)

        strokeRecognizer.delegate = self
        strokeRecognizer.cancelsTouchesInView = false
        strokeRecognizer.delaysTouchesBegan = false
        strokeRecognizer.delaysTouchesEnded = false
        strokeRecognizer.canvas = self
        scrollView.addGestureRecognizer(strokeRecognizer)

        addInteraction(UIPencilInteraction(delegate: self))
        configure(session)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ session: PaintingSession) {
        self.session = session
        session.canvasView = self
        content.removeFromSuperview()
        content = UIView(frame: CGRect(x: 0, y: 0, width: session.template.width, height: session.template.height))
        scrollView.zoomScale = 1
        scrollView.addSubview(content)
        scrollView.contentSize = content.bounds.size

        let numbers = TemplateTiledLayer(art: session.art, kind: .numbers)
        numbers.backgroundColor = UIColor.white.cgColor
        let borders = TemplateTiledLayer(art: session.art, kind: .borders)
        let paint = CALayer()
        paintTiles = []
        let layer = session.layer, t = Self.paintTile, s = CGFloat(PaintLayer.scale)
        for y in stride(from: 0, to: layer.height, by: t) {
            for x in stride(from: 0, to: layer.width, by: t) {
                let tile = CALayer()
                tile.frame = CGRect(x: CGFloat(x) / s, y: CGFloat(y) / s,
                                    width: CGFloat(min(t, layer.width - x)) / s, height: CGFloat(min(t, layer.height - y)) / s)
                tile.magnificationFilter = .nearest   // paint edges stay exactly on the grid lines
                tile.minificationFilter = .linear
                paint.addSublayer(tile)
                paintTiles.append(tile)
            }
        }
        flashLayer = CALayer()
        flashLayer.magnificationFilter = .nearest
        flashLayer.opacity = 0
        for l in [numbers, paint, flashLayer, borders] {
            l.frame = content.bounds
            content.layer.addSublayer(l)
        }
        redraw(PixelRect(x0: 0, y0: 0, x1: layer.width, y1: layer.height))
        isAtFit = true
        setNeedsLayout()
    }

    // MARK: Layout & zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let w = CGFloat(session.template.width), h = CGFloat(session.template.height)
        fitScale = min(bounds.width / w, bounds.height / h) * 0.95
        scrollView.minimumZoomScale = fitScale * 0.5
        scrollView.maximumZoomScale = fitScale * 12
        let screen = traitCollection.displayScale
        for case let tiled as TemplateTiledLayer in content.layer.sublayers ?? [] {
            tiled.contentsScale = screen
            tiled.levelsOfDetailBias = max(1, Int(log2(scrollView.maximumZoomScale).rounded(.up)) + 1)
            tiled.levelsOfDetail = tiled.levelsOfDetailBias + 4
        }
        updateInputMode()   // the pinch recognizer exists only once zooming is configured
        if isAtFit { zoomToFit(animated: false) } else { centerContent() }
    }

    func zoomToFit(animated: Bool) {
        scrollView.setZoomScale(fitScale, animated: animated)
        isAtFit = true
        centerContent(scale: fitScale)
        scrollView.setContentOffset(CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top),
                                    animated: animated)
    }

    private func centerContent(scale: CGFloat? = nil) {
        let size = scrollView.bounds.size, z = scale ?? scrollView.zoomScale
        let w = CGFloat(session.template.width) * z, h = CGFloat(session.template.height) * z
        let x = max(0, (size.width - w) / 2), y = max(0, (size.height - h) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { isAtFit = false }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { isAtFit = false }

    // MARK: Input

    private func updateInputMode() {
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        scrollView.panGestureRecognizer.allowedTouchTypes = [finger]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [finger]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = pencilSeen ? 1 : 2
        strokeRecognizer.allowedTouchTypes = pencilSeen ? [pencil] : [pencil, finger]
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    fileprivate func strokeBegan(_ touch: UITouch, _ event: UIEvent) {
        if touch.type == .pencil {
            if !pencilSeen { pencilSeen = true }
            // A resting palm must not pan or zoom while the pencil paints.
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.pinchGestureRecognizer?.isEnabled = false
        }
        let radius = Double(session.brush.diameter / 2 / scrollView.zoomScale) * Double(PaintLayer.scale)
        session.beginStroke(radius: radius)
        strokeMoved(touch, event)
    }

    fileprivate func strokeMoved(_ touch: UITouch, _ event: UIEvent) {
        let points = (event.coalescedTouches(for: touch) ?? [touch]).map(paintPoint)
        let predicted = (event.predictedTouches(for: touch) ?? []).map(paintPoint)
        if let dirty = session.continueStroke(points, predicted: predicted) { redraw(dirty) }
    }

    fileprivate func strokeEnded(_ touch: UITouch?, _ event: UIEvent?) {
        if let touch, let event {
            let points = (event.coalescedTouches(for: touch) ?? [touch]).map(paintPoint)
            if let dirty = session.continueStroke(points, predicted: []) { redraw(dirty) }
        }
        if let dirty = session.endStroke() { redraw(dirty) }
        enableScrolling()
    }

    /// The stroke was the start of a two-finger gesture: take it back completely.
    fileprivate func strokeReverted() {
        if let dirty = session.cancelStroke() { redraw(dirty) }
        enableScrolling()
    }

    private func enableScrolling() {
        scrollView.panGestureRecognizer.isEnabled = true
        scrollView.pinchGestureRecognizer?.isEnabled = true
    }

    private func paintPoint(_ touch: UITouch) -> CGPoint {
        let p = touch.type == .pencil ? touch.preciseLocation(in: content) : touch.location(in: content)
        let s = CGFloat(PaintLayer.scale)
        return CGPoint(x: p.x * s, y: p.y * s)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        session.undo()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        session.undo()
    }

    // MARK: Drawing

    /// Re-renders the paint tiles under a dirty rect (paint pixels).
    func redraw(_ dirty: PixelRect) {
        let layer = session.layer, t = Self.paintTile
        let perRow = (layer.width + t - 1) / t
        guard !dirty.isEmpty, !paintTiles.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ty in max(0, dirty.y0 / t)...min((layer.height - 1) / t, (dirty.y1 - 1) / t) {
            for tx in max(0, dirty.x0 / t)...min(perRow - 1, (dirty.x1 - 1) / t) {
                let r = PixelRect(x0: tx * t, y0: ty * t, x1: min(layer.width, tx * t + t), y1: min(layer.height, ty * t + t))
                paintTiles[ty * perRow + tx].contents = layer.makeImage(r)
            }
        }
        CATransaction.commit()
    }

    func flashOpenFields(color: Int) {
        guard let image = session.layer.openFieldsImage(color: color) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.contents = image
        CATransaction.commit()
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        if UIAccessibility.isReduceMotionEnabled {
            pulse.values = [0, 0.45, 0]
            pulse.duration = 0.8
        } else {
            pulse.values = [0, 0.6, 0.15, 0.6, 0]
            pulse.duration = 1.4
        }
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        flashLayer.add(pulse, forKey: "flash")
    }
}

/// Recognizes immediately on touch-down, tracks a single touch and hands it to the canvas.
private final class StrokeRecognizer: UIGestureRecognizer {
    weak var canvas: PaintCanvasView?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked {
            // A second finger joins a finger stroke: it was a pinch/pan after all.
            if tracked.type != .pencil {
                canvas?.strokeReverted()
                state = .cancelled
            } else {
                touches.forEach { ignore($0, for: event) }
            }
            return
        }
        guard touches.count == 1, let touch = touches.first, (event.allTouches?.count ?? 1) == 1 else {
            state = .failed
            return
        }
        tracked = touch
        state = .began
        canvas?.strokeBegan(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        canvas?.strokeMoved(tracked, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        canvas?.strokeEnded(tracked, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        canvas?.strokeEnded(nil, nil)   // system cancel (app switch, alert): keep what was painted
        state = .cancelled
    }

    override func reset() {
        tracked = nil
        super.reset()
    }
}

/// Draws numbers or borders for whatever tile Core Animation asks for, at that tile's zoom level.
private final class TemplateTiledLayer: CATiledLayer {
    enum Kind { case numbers, borders }
    private var art: TemplateArt?
    private var kind = Kind.numbers

    convenience init(art: TemplateArt, kind: Kind) {
        self.init()
        self.art = art
        self.kind = kind
        tileSize = CGSize(width: 512, height: 512)
        isOpaque = kind == .numbers
    }

    override init() { super.init() }
    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TemplateTiledLayer { art = other.art; kind = other.kind }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override func draw(in ctx: CGContext) {
        guard let art else { return }
        let rect = ctx.boundingBoxOfClipPath
        switch kind {
        case .numbers:
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(rect)
            art.drawNumbers(in: ctx, rect: rect)
        case .borders:
            art.drawBorders(in: ctx, rect: rect)
        }
    }
}
