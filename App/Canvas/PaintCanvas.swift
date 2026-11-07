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
/// Input: the pencil paints, fingers pan (1), pinch and rotate (2). Until a pencil was ever seen, a
/// single finger paints and panning needs two fingers.
///
/// Rotation turns the whole scroll view like a sheet of paper. The scroll view is a square as large
/// as this view's diagonal, centred on it, so it covers the screen at every angle; this view clips
/// it. UIKit converts touches through the rotation, so strokes land where the pencil is.
final class PaintCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private(set) var session: PaintingSession
    private let scrollView = UIScrollView()
    private var content = UIView()
    private var paintTiles: [CALayer] = []
    private var flashLayer = CALayer()
    private let strokeRecognizer = StrokeRecognizer()
    private let rotationRecognizer = UIRotationGestureRecognizer()
    private var fitScale: CGFloat = 1
    private var isAtFit = true
    /// Paper rotation in radians, in (-π, π].
    private(set) var rotation: CGFloat = 0
    /// Turning starts only after this much twist, so a plain pinch does not turn the paper.
    private var rotationEngaged = false
    private static let rotationThreshold: CGFloat = .pi / 24          // 7.5°
    private static let rotationSnap: CGFloat = .pi / 30               // within 6° of 0/90/180/270

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
        clipsToBounds = true
        addSubview(scrollView)

        rotationRecognizer.delegate = self
        rotationRecognizer.addTarget(self, action: #selector(handleRotation(_:)))
        addGestureRecognizer(rotationRecognizer)

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
        guard bounds.width > 0, bounds.height > 0 else { return }
        // bounds/center, not frame: the scroll view may carry a rotation transform.
        let side = hypot(bounds.width, bounds.height).rounded(.up)
        if scrollView.bounds.size != CGSize(width: side, height: side) {
            scrollView.bounds.size = CGSize(width: side, height: side)
        }
        scrollView.center = CGPoint(x: bounds.midX, y: bounds.midY)
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

    /// Shows the whole picture, straightened.
    func zoomToFit(animated: Bool) {
        setRotation(0, animated: animated)
        scrollView.setZoomScale(fitScale, animated: animated)
        isAtFit = true
        centerContent(scale: fitScale)
        let size = scrollView.bounds.size
        let w = CGFloat(session.template.width) * fitScale, h = CGFloat(session.template.height) * fitScale
        scrollView.setContentOffset(CGPoint(x: (w - size.width) / 2, y: (h - size.height) / 2), animated: animated)
    }

    /// Centres small content in the scroll view (and so on screen). The scroll view is larger than
    /// the screen, so the insets also let every edge of the picture reach the inscribed circle of
    /// the screen; that circle is visible at every rotation.
    private func centerContent(scale: CGFloat? = nil) {
        let size = scrollView.bounds.size, z = scale ?? scrollView.zoomScale
        let w = CGFloat(session.template.width) * z, h = CGFloat(session.template.height) * z
        let reach = max(0, (size.width - min(bounds.width, bounds.height)) / 2)
        let x = max(reach, (size.width - w) / 2), y = max(reach, (size.height - h) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    var contentViewForTesting: UIView { content }
    var zoomScaleForTesting: CGFloat { scrollView.zoomScale }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { isAtFit = false }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { isAtFit = false }

    // MARK: Rotation

    @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if !rotationEngaged {
                guard abs(g.rotation) > Self.rotationThreshold else { return }
                rotationEngaged = true
                g.rotation -= g.rotation > 0 ? Self.rotationThreshold : -Self.rotationThreshold
            }
            isAtFit = false
            rotate(by: g.rotation, around: g.location(in: self))
            g.rotation = 0
        case .ended:
            if rotationEngaged { snapRotation() }
            rotationEngaged = false
        case .cancelled, .failed:
            // Cancelled when the pencil starts painting: the paper stays exactly where it is.
            rotationEngaged = false
        default:
            break
        }
    }

    /// Turns the paper by `delta` radians so that the picture point under `pivot` (in this view's
    /// coordinates) stays under it, like a sheet turned under two fingers.
    func rotate(by delta: CGFloat, around pivot: CGPoint) {
        let anchor = convert(pivot, to: content)
        setRotation(rotation + delta, animated: false)
        let moved = content.convert(anchor, to: self)
        // The same screen offset, expressed along the rotated scroll view's axes.
        let a = scrollView.convert(pivot, from: self), b = scrollView.convert(moved, from: self)
        scrollView.contentOffset.x += b.x - a.x
        scrollView.contentOffset.y += b.y - a.y
    }

    private func setRotation(_ angle: CGFloat, animated: Bool) {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi } else if a <= -.pi { a += 2 * .pi }
        rotation = a
        let apply = { self.scrollView.transform = CGAffineTransform(rotationAngle: a) }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    /// Stops a running snap (or "Ganzes Bild") where it is on screen, so the paper does not move
    /// under a pencil that just touched down.
    private func freezeRunningAnimation() {
        let layer = scrollView.layer
        guard layer.animationKeys()?.isEmpty == false, let shown = layer.presentation() else { return }
        let angle = atan2(shown.transform.m12, shown.transform.m11)
        let origin = shown.bounds.origin
        layer.removeAllAnimations()
        setRotation(angle, animated: false)
        scrollView.contentOffset = origin
    }

    /// Close to straight (or a quarter turn), the paper settles exactly there.
    private func snapRotation() {
        let quarter = CGFloat.pi / 2
        let target = (rotation / quarter).rounded() * quarter
        guard rotation != target, abs(rotation - target) < Self.rotationSnap else { return }
        setRotation(target, animated: true)
    }

    // MARK: Input

    private func updateInputMode() {
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        scrollView.panGestureRecognizer.allowedTouchTypes = [finger]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [finger]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = pencilSeen ? 1 : 2
        rotationRecognizer.allowedTouchTypes = [finger]
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
            rotationRecognizer.isEnabled = false
            freezeRunningAnimation()
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
        rotationRecognizer.isEnabled = true
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
        guard touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        // Fallback finger painting needs exactly one finger; allTouches also holds touches this
        // recognizer never gets (a resting palm), so the pencil ignores them.
        let fingers = event.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
        if touch.type != .pencil && fingers > 1 {
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
