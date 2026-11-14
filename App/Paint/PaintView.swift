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

    private var title: String { store.artworks.first { $0.id == id }?.title ?? "" }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if let session {
                PaintCanvas(session: session).ignoresSafeArea()
                PaintChrome(session: session, palette: palette, title: title,
                            onBack: close,
                            onUndo: { session.undo() },   // undo fires onStrokeEnded → autosave
                            onShowFinished: { completion = .look })
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
                                      paintColors: store.paintColorData(id))
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finished colours leave the bar unless asked for; the selected one stays until another is picked.
    @AppStorage("paint.showDoneColors") private var showDone = false

    private var order: [Int] {
        let done = session.completedColors
        return palette.indices
            .filter { showDone || !done.contains($0) || $0 == session.selectedColor }
            .sorted { a, b in (done.contains(a) ? 1 : 0, a) < (done.contains(b) ? 1 : 0, b) }
    }

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
        .background(.ultraThinMaterial, in: Capsule())
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

/// Brush types and shading tools, in a column on the leading edge.
private struct ToolRail: View {
    @Binding var tool: BrushKind

    private static let paint: [BrushKind] = [.pencil, .brush, .crayon, .airbrush]
    private static let shading: [BrushKind] = [.shadow, .light]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Self.paint, id: \.self) { kind in button(kind) }
            Capsule().fill(Theme.ink.opacity(0.15)).frame(width: 24, height: 2).padding(.vertical, 4)
            ForEach(Self.shading, id: \.self) { kind in button(kind) }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(Theme.ink)
    }

    private func button(_ kind: BrushKind) -> some View {
        Button { withAnimation(Theme.spring) { tool = kind } } label: {
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
        }
    }
}
