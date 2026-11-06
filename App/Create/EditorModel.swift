import SwiftUI
import PhotosUI
import Observation
import PaintEngine

struct Motif: Identifiable, Hashable, Sendable {
    let id: String   // asset name
    let title: String

    static let all = [
        Motif(id: "motif-fox", title: "Fuchs im Herbstwald"),
        Motif(id: "motif-lighthouse", title: "Leuchtturm"),
        Motif(id: "motif-flowers", title: "Blumenstrauß"),
        Motif(id: "motif-balloons", title: "Heißluftballons"),
    ]

    @MainActor var image: UIImage? { UIImage(named: id) }
}

enum EditorSource: Hashable {
    case photo(PhotosPickerItem)
    case motif(Motif)
}

@MainActor @Observable final class EditorModel {
    enum Phase { case loading, ready, failed }

    nonisolated static let previewSide = 320
    nonisolated static let fullSide = 1000

    private(set) var phase = Phase.loading
    private(set) var title = ""
    var colors: Double = 12
    var detail: Double = 0.5
    var mode = TemplateRenderer.Mode.outline { didSet { rerender() } }
    private(set) var image: CGImage?
    private(set) var palette: [PaletteColor] = []
    private(set) var isBuilding = false

    @ObservationIgnored private var full: RGBAImage?
    @ObservationIgnored private var small: RGBAImage?
    @ObservationIgnored private var shown: Template?
    @ObservationIgnored private(set) var fullTemplate: Template?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var options: TemplateOptions { TemplateOptions(colors: Int(colors), detail: detail, maxSide: Self.fullSide) }

    func load(_ source: EditorSource) async {
        guard phase == .loading, full == nil else { return }
        do {
            let rgba: RGBAImage
            switch source {
            case .motif(let motif):
                title = motif.title
                guard let cg = motif.image?.cgImage else { throw RGBAImage.LoadError.undecodable }
                rgba = try await Task.detached(priority: .userInitiated) { try RGBAImage(cgImage: cg) }.value
            case .photo(let item):
                title = "Foto vom \(Date.now.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "de_DE"))))"
                guard let data = try await item.loadTransferable(type: Data.self) else { throw RGBAImage.LoadError.undecodable }
                rgba = try await Task.detached(priority: .userInitiated) { try RGBAImage(data: data) }.value
            }
            full = rgba
            small = await Task.detached(priority: .userInitiated) { rgba.downsampled(maxSide: 640) }.value
            phase = .ready
            build(sides: [Self.previewSide, Self.fullSide])
        } catch {
            phase = .failed
        }
    }

    /// Slider moved: cheap preview, the previous build is cancelled.
    func optionsChanging() { build(sides: [Self.previewSide]) }

    /// Slider released: full resolution, needed for „Los geht's“.
    func optionsCommitted() { build(sides: [Self.fullSide]) }

    /// Waits for the full-resolution build of the current options.
    func finalTemplate() async -> Template? {
        if fullTemplate == nil { await buildTask?.value }
        if fullTemplate == nil { build(sides: [Self.fullSide]); await buildTask?.value }
        return fullTemplate
    }

    private func build(sides: [Int]) {
        guard let full, let small else { return }
        generation += 1
        let gen = generation
        fullTemplate = nil
        buildTask?.cancel()   // reaches the detached task itself; cancelling a parent would not
        isBuilding = true
        let base = options, mode = mode
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            for side in sides {
                var opts = base
                opts.maxSide = side
                let source = side <= Self.previewSide ? small : full
                guard let template = try? TemplateBuilder.build(rgba: source.pixels, width: source.width,
                                                                height: source.height, options: opts),
                      !Task.isCancelled else { return }
                let image = TemplateRenderer.render(template, mode: mode, scale: Self.scale(for: template))
                guard !Task.isCancelled else { return }
                await self?.apply(template, image: image, isFull: side == Self.fullSide, generation: gen)
            }
        }
    }

    private func apply(_ template: Template, image: CGImage?, isFull: Bool, generation gen: Int) {
        guard gen == generation else { return }   // a newer build started meanwhile
        shown = template
        self.image = image
        palette = template.palette
        if isFull { fullTemplate = template; isBuilding = false }
    }

    private func rerender() {
        guard let shown else { return }
        let mode = mode, gen = generation
        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let image = TemplateRenderer.render(shown, mode: mode, scale: Self.scale(for: shown))
            guard !Task.isCancelled else { return }
            await self?.applyRender(image, generation: gen)
        }
    }

    private func applyRender(_ image: CGImage?, generation gen: Int) {
        if gen == generation { self.image = image }
    }

    nonisolated static func scale(for t: Template) -> Int { max(1, min(4, 2000 / max(t.width, t.height, 1))) }
}
