import SwiftUI
import PaintEngine

struct PaintView: View {
    let id: UUID
    let onClose: () -> Void

    @Environment(ArtworkStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session: PaintingSession?
    @State private var autosaver: Autosaver?
    @State private var completion: CompletionView.Mode?
    @State private var failed = false
    @State private var palette: [PaletteColor] = []
    /// Zen mode: the tools step aside and only the picture (and a quiet way back) stays.
    @State private var zen = false

    private var title: String { store.artworks.first { $0.id == id }?.title ?? "" }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if let session {
                PaintCanvas(session: session).ignoresSafeArea()
                if zen {
                    ZenControls(session: session, palette: palette) { zen = false }
                        .transition(.opacity)
                } else {
                    PaintChrome(session: session, palette: palette, title: title,
                                onBack: close,
                                onUndo: { session.undo() },   // undo fires onStrokeEnded → autosave
                                onShowFinished: { completion = .look },
                                onZen: { zen = true })
                        .transition(.opacity)
                }
                if let completion {
                    CompletionView(session: session, title: title, palette: palette,
                                   fallback: store.artworks.first { $0.id == id }.flatMap(store.thumbnail(for:)),
                                   mode: completion,
                                   onClose: { self.completion = nil }, onGallery: close)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(1)
                }
            } else if failed {
                ContentUnavailableView {
                    Label("Das Bild ist beschädigt", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Zur Galerie", action: onClose).buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.spring, value: completion)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: zen)
        .sensoryFeedback(.selection, trigger: zen)
        .task { await load() }
        .onChange(of: scenePhase) { if scenePhase != .active { autosaver?.flush() } }
        .onDisappear { autosaver?.flush() }
        .onChange(of: session?.isComplete ?? false) { _, done in
            if done { autosaver?.flush(); completion = .celebrate }
        }
    }

    private func load() async {
        guard session == nil else { return }
        guard let template = try? await store.loadTemplate(id) else { failed = true; return }
        var paint = store.paintData(id)
        #if DEBUG
        if paint == nil, ProcessInfo.processInfo.arguments.contains("-uiTestPrefill") {
            paint = ScreenshotPrefill.paintLayerPNG(for: template)
        }
        #endif
        let session = PaintingSession(template: template, paintLayerPNG: paint,
                                      paintColors: store.paintColorData(id), paintFine: store.paintFineData(id))
        let saver = Autosaver(id: id, store: store, session: session)
        session.onStrokeEnded = { [weak saver] in saver?.changed() }
        if let open = (0..<template.palette.count).first(where: { !session.completedColors.contains($0) }) {
            session.selectedColor = open
        }
        palette = template.palette
        self.session = session
        autosaver = saver
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestPrefill") { saver.changed() }   // gallery shows it painted
        if ProcessInfo.processInfo.arguments.contains("-uiTestShowCompletion") { completion = .celebrate; return }
        #endif
        if session.isComplete { completion = .look }
    }

    private func close() {
        autosaver?.flush()
        onClose()
    }
}

/// Floating controls over the full-bleed canvas.
private struct PaintChrome: View {
    @Bindable var session: PaintingSession
    let palette: [PaletteColor]
    let title: String
    let onBack: () -> Void
    let onUndo: () -> Void
    let onShowFinished: () -> Void
    let onZen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finished colours leave the bar unless asked for; the selected one stays until another is picked.
    @AppStorage("paint.showDoneColors") private var showDone = false

    private var order: [Int] { session.potOrder(showDone: showDone) }

    private var pots: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { index in
                PaintPot(color: palette[index], number: index + 1,
                         progress: session.progressByColor.indices.contains(index) ? session.progressByColor[index] : 0,
                         isDone: session.completedColors.contains(index),
                         isSelected: session.selectedColor == index) {
                    withAnimation(Theme.spring) { session.selectColor(index) }
                }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if !session.completedColors.isEmpty {
                DoneToggle(count: session.completedColors.count, isShowing: showDone) {
                    withAnimation(Theme.spring) { showDone.toggle() }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                RoundButton(systemImage: "chevron.left", label: "Zur Galerie", action: onBack)
                    .accessibilityIdentifier("backToGallery")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(.headline, weight: .bold)).lineLimit(1)
                    Text(session.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.rounded(.subheadline, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.softInk)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 16).frame(height: 52)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityElement(children: .combine)
                Spacer()
                if session.isComplete {
                    RoundButton(systemImage: "sparkles", label: "Fertiges Bild ansehen", action: onShowFinished)
                }
                BrushSizeControl(diameter: $session.brushDiameter)
                RoundButton(systemImage: "arrow.uturn.backward", label: "Rückgängig", action: onUndo)
                    .disabled(!session.canUndo)
                RoundButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Ganzes Bild") {
                    session.fitWholePicture()
                }
                RoundButton(systemImage: "eye.slash", label: "Werkzeuge ausblenden", action: onZen)
                    .accessibilityIdentifier("zenMode")
            }
            .foregroundStyle(Theme.ink)
            Spacer()
            ViewThatFits(in: .horizontal) {
                pots
                ScrollView(.horizontal, showsIndicators: false) { pots }
            }
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
            .frame(maxWidth: 1000)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7), value: order)
        }
        .overlay(alignment: .leading) { ToolRail(tool: $session.tool) }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .sensoryFeedback(.selection, trigger: session.selectedColor)
        .sensoryFeedback(.selection, trigger: session.tool)
        .sensoryFeedback(.success, trigger: session.completedColors.count)
    }
}

/// All that is left in zen mode: a quiet column in the corner where the tools were. It shows only
/// what is in hand – tool, brush size, colour – and opens a small panel to change one when tapped;
/// the colours stay out of sight until then.
private struct ZenControls: View {
    @Bindable var session: PaintingSession
    let palette: [PaletteColor]
    let onExit: () -> Void

    private enum Panel { case tool, size, color }
    @State private var open: Panel?
    @AppStorage("paint.showDoneColors") private var showDone = false

    private var color: PaletteColor? {
        palette.indices.contains(session.selectedColor) ? palette[session.selectedColor] : nil
    }

    var body: some View {
        VStack(spacing: 10) {
            ZenButton(action: onExit) {
                Image(systemName: "eye").font(.system(size: 16, weight: .semibold))
            }
            .accessibilityLabel("Werkzeuge zeigen")
            .accessibilityIdentifier("exitZenMode")

            VStack(spacing: 2) {
                ZenButton { open = .tool } label: {
                    Image(systemName: session.tool.symbol).font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel(session.tool.label)
                .accessibilityIdentifier("zenTool")
                .popover(isPresented: isOpen(.tool), arrowEdge: .trailing) {
                    ToolRail(tool: $session.tool, framed: false) { open = nil }
                        .padding(8)
                        .presentationCompactAdaptation(.popover)
                }

                ZenButton { open = .size } label: {
                    Circle()
                        .fill(Theme.ink.opacity(0.75))
                        .frame(width: min(session.brushDiameter, 24), height: min(session.brushDiameter, 24))
                }
                .accessibilityLabel("Pinselgröße")
                .accessibilityValue(Text(verbatim: "\(Int(session.brushDiameter.rounded())) pt"))
                .accessibilityIdentifier("zenSize")
                .popover(isPresented: isOpen(.size), arrowEdge: .trailing) {
                    BrushSizeControl(diameter: $session.brushDiameter, framed: false)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                }

                ZenButton { open = .color } label: { colorDot }
                    .accessibilityLabel("Farbe \(session.selectedColor + 1)")
                    .accessibilityIdentifier("zenColor")
                    .popover(isPresented: isOpen(.color), arrowEdge: .trailing) {
                        colorPanel.presentationCompactAdaptation(.popover)
                    }
            }
            .padding(2)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(Theme.ink.opacity(0.7))
        // Quiet while painting, clear while choosing.
        .opacity(open == nil ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.2), value: open)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.horizontal, 20).padding(.vertical, 16)
        .sensoryFeedback(.selection, trigger: session.selectedColor)
        .sensoryFeedback(.selection, trigger: session.tool)
    }

    /// The colour in hand with its number, ringed by how far it is painted.
    private var colorDot: some View {
        let progress = session.progressByColor.indices.contains(session.selectedColor)
            ? session.progressByColor[session.selectedColor] : 0
        let done = session.completedColors.contains(session.selectedColor)
        return ZStack {
            Circle()
                .trim(from: 0, to: progress)
                .stroke(done ? Color.green : Theme.ink.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 36, height: 36)
            Circle()
                .fill(color?.color ?? .clear)
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .frame(width: 28, height: 28)
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
                } else {
                    Text(verbatim: "\(session.selectedColor + 1)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(color?.isLight ?? true ? Color.black.opacity(0.72) : .white)
        }
    }

    /// The paint pots, only while picking; a pick closes the panel again.
    private var colorPanel: some View {
        let indices = session.potOrder(showDone: showDone)
        let columns = min(5, max(1, indices.count))
        let rows = (indices.count + columns - 1) / columns
        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(66), spacing: 0), count: columns), spacing: 0) {
                ForEach(indices, id: \.self) { index in
                    PaintPot(color: palette[index], number: index + 1,
                             progress: session.progressByColor.indices.contains(index) ? session.progressByColor[index] : 0,
                             isDone: session.completedColors.contains(index),
                             isSelected: session.selectedColor == index) {
                        withAnimation(Theme.spring) { session.selectColor(index) }
                        open = nil
                    }
                }
            }
            .padding(12)
        }
        .frame(width: CGFloat(columns) * 66 + 24, height: min(CGFloat(rows) * 72 + 24, 384))
    }

    private func isOpen(_ panel: Panel) -> Binding<Bool> {
        Binding(get: { open == panel }, set: { if !$0, open == panel { open = nil } })
    }
}

/// A small round button for the zen column.
private struct ZenButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct RoundButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Brush size from a hairline to a broad stroke, without steps. The dot shows the size on screen
/// (up to its frame).
private struct BrushSizeControl: View {
    @Binding var diameter: CGFloat
    /// Without its own capsule, e.g. inside a popover.
    var framed = true

    private static let range = PaintingSession.diameterRange
    /// 0...1 along the slider; logarithmic so that the fine sizes get as much room as the broad ones.
    private var position: Binding<Double> {
        Binding(
            get: { log(Double(diameter / Self.range.lowerBound)) / log(Double(Self.range.upperBound / Self.range.lowerBound)) },
            set: { diameter = Self.range.lowerBound * CGFloat(pow(Double(Self.range.upperBound / Self.range.lowerBound), $0)) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: min(diameter, 36), height: min(diameter, 36))
                .frame(width: 36, height: 36)
            Slider(value: position, in: 0...1)
                .frame(width: 170)
                .accessibilityLabel("Pinselgröße")
                .accessibilityValue(Text(verbatim: "\(Int(diameter.rounded())) pt"))
        }
        .padding(.leading, 8).padding(.trailing, 16)
        .frame(height: 52)
        .background(framed ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: Capsule())
    }
}

/// At the end of the paint pots: how many colours are done; shows or hides them.
private struct DoneToggle: View {
    let count: Int
    let isShowing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isShowing ? "eye.slash" : "checkmark")
                    .font(.system(size: 15, weight: .heavy))
                Text(verbatim: "\(count)").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(Theme.ink.opacity(0.7))
            .frame(minWidth: 60, minHeight: 60)
            .padding(.horizontal, 4)
            .background(Theme.ink.opacity(0.06), in: Capsule())
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isShowing ? "Fertige Farben ausblenden" : "Fertige Farben zeigen")
        .accessibilityValue(Text(verbatim: "\(count)"))
        .accessibilityIdentifier("toggleDoneColors")
    }
}

/// Brush types, shading tools and the eraser, in a column on the leading edge.
private struct ToolRail: View {
    @Binding var tool: BrushKind
    /// Without its own capsule, e.g. inside a popover.
    var framed = true
    var onPick: () -> Void = {}

    private static let paint: [BrushKind] = [.pencil, .brush, .crayon, .airbrush]
    private static let shading: [BrushKind] = [.shadow, .light]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Self.paint, id: \.self) { kind in button(kind) }
            Capsule().fill(Theme.ink.opacity(0.15)).frame(width: 24, height: 2).padding(.vertical, 4)
            ForEach(Self.shading, id: \.self) { kind in button(kind) }
            Capsule().fill(Theme.ink.opacity(0.15)).frame(width: 24, height: 2).padding(.vertical, 4)
            button(.eraser)
        }
        .padding(4)
        .background(framed ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: Capsule())
        .foregroundStyle(Theme.ink)
    }

    private func button(_ kind: BrushKind) -> some View {
        Button { withAnimation(Theme.spring) { tool = kind }; onPick() } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tool == kind ? Color.accentColor : Theme.ink.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(tool == kind ? Color.accentColor.opacity(0.16) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(tool == kind ? .isSelected : [])
        .accessibilityIdentifier("tool-\(kind.rawValue)")
    }
}

extension BrushKind {
    var symbol: String {
        switch self {
        case .pencil: "pencil"
        case .brush: "paintbrush.pointed.fill"
        case .crayon: "scribble.variable"
        case .airbrush: "aqi.medium"
        case .shadow: "moon.fill"
        case .light: "sun.max.fill"
        case .eraser: "eraser.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .pencil: "Buntstift"
        case .brush: "Pinsel"
        case .crayon: "Kreide"
        case .airbrush: "Airbrush"
        case .shadow: "Schatten"
        case .light: "Licht"
        case .eraser: "Radiergummi"
        }
    }
}
