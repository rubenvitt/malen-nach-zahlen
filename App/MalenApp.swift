import SwiftUI
import PaintEngine

@main
struct MalenApp: App {
    @State private var store: ArtworkStore
    @State private var fullVersion: FullVersion
    @State private var path: [Route] = []
    @State private var showsFullVersionForReview = false   // App Review screenshot of the purchase sheet (Debug)

    init() {
        #if DEBUG // UI tests run in Debug; the shipped app never reads these launch arguments
        if ProcessInfo.processInfo.arguments.contains("-uiTestStore") {
            let store = ArtworkStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-uiTestFixedTemplate") { Self.injectFixture(into: store) }
            _showsFullVersionForReview = State(initialValue: args.contains("-uiTestShowFullVersion"))
            _store = State(initialValue: store)
            // Fresh counter per run, so one UI test's photo never uses up the next test's free photo.
            _fullVersion = State(initialValue: FullVersion(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard))
            if args.contains("-uiTestOpenPaint"), let first = store.artworks.first {
                _path = State(initialValue: [.paint(first.id)])
            } else if args.contains("-uiTestOpenEditor") {
                _path = State(initialValue: [.editor(.motif(Motif.all[0]))])
            }
            return
        }
        #endif
        _store = State(initialValue: .applicationSupport())
        _fullVersion = State(initialValue: FullVersion())
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                GalleryView(path: $path)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .editor(let source):
                            EditorView(source: source) { id in path = [.paint(id)] }
                        case .paint(let id):
                            PaintView(id: id) { path.removeAll() }
                        }
                    }
            }
            .sheet(isPresented: $showsFullVersionForReview) { FullVersionSheet {} }
            .environment(store)
            .environment(fullVersion)
            .task { fullVersion.start() }
        }
    }

    #if DEBUG
    /// 12×8 grid, three colour bands — built by hand so it does not depend on the engine.
    private static func injectFixture(into store: ArtworkStore) {
        let w = 12, h = 8
        let colorOfPixel = (0..<w * h).map { UInt8(($0 % w) / 4) }
        let template = Template(
            width: w, height: h,
            palette: [PaletteColor(r: 244, g: 107, b: 82), PaletteColor(r: 250, g: 200, b: 90), PaletteColor(r: 80, g: 140, b: 210)],
            colorOfPixel: colorOfPixel, fieldOfPixel: colorOfPixel.map(Int32.init),
            colorOfField: [0, 1, 2], sizeOfField: [32, 32, 32],
            spots: (0..<3).map { NumberSpot(x: $0 * 4 + 2, y: 4, radius: 2, field: Int32($0)) })
        _ = try? store.create(template: template, title: "Testbild", options: TemplateOptions(colors: 3),
                              thumbnail: TemplateRenderer.thumbnailJPEG(template))
    }
    #endif
}
