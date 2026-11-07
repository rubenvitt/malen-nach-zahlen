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
    @AppStorage("overpaintProtection") private var overpaintProtection = true

    private var title: String { store.artworks.first { $0.id == id }?.title ?? "" }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if let session {
                PaintCanvas(session: session).ignoresSafeArea()
                PaintChrome(session: session, palette: palette, title: title,
                            overpaintProtection: $overpaintProtection, onBack: close,
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
        .onChange(of: overpaintProtection) { _, on in session?.overpaintProtection = on }
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
        session.overpaintProtection = overpaintProtection
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
    @Binding var overpaintProtection: Bool
    let onBack: () -> Void
    let onUndo: () -> Void
    let onShowFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var protectionHint: Task<Void, Never>?
    @State private var showsProtectionHint = false

    private func toggleProtection() {
        withAnimation(Theme.spring) {
            overpaintProtection.toggle()
            showsProtectionHint = true
        }
        protectionHint?.cancel()
        protectionHint = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.spring) { showsProtectionHint = false }
        }
    }

    private var order: [Int] {
        let done = session.completedColors
        return palette.indices.sorted { a, b in
            (done.contains(a) ? 1 : 0, a) < (done.contains(b) ? 1 : 0, b)
        }
    }

    private var pots: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { index in
                PaintPot(color: palette[index], number: index + 1,
                         progress: session.progressByColor.indices.contains(index) ? session.progressByColor[index] : 0,
                         isDone: session.completedColors.contains(index),
                         isSelected: session.selectedColor == index) {
                    withAnimation(Theme.spring) { session.selectedColor = index }
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
                RoundButton(systemImage: overpaintProtection ? "shield.lefthalf.filled" : "shield.slash",
                            label: overpaintProtection ? "Übermalschutz an" : "Übermalschutz aus",
                            action: toggleProtection)
                    .accessibilityHint("Schaltet um, ob Farbe nur in Felder ihrer Nummer kommt")
                    .accessibilityIdentifier("overpaintProtection")
                BrushPicker(brush: $session.brush)
                RoundButton(systemImage: "arrow.uturn.backward", label: "Rückgängig", action: onUndo)
                    .disabled(!session.canUndo)
                RoundButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Ganzes Bild") {
                    session.fitWholePicture()
                }
            }
            .foregroundStyle(Theme.ink)
            if showsProtectionHint {
                Text(overpaintProtection ? "Übermalschutz an: Farbe bleibt in ihren Feldern"
                                         : "Übermalschutz aus: Farbe landet in jedem Feld")
                    .font(.rounded(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
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
        .padding(.horizontal, 20).padding(.vertical, 16)
        .sensoryFeedback(.selection, trigger: session.selectedColor)
        .sensoryFeedback(.success, trigger: session.completedColors.count)
        .onChange(of: session.completedColors) { _, done in
            // The finished colour slides to the end; jump to the next open one.
            guard done.contains(session.selectedColor),
                  let next = order.first(where: { !done.contains($0) }) else { return }
            withAnimation(Theme.spring) { session.selectedColor = next }
        }
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

private struct BrushPicker: View {
    @Binding var brush: BrushSize

    private static var labels: [LocalizedStringKey] { ["Dünner Pinsel", "Mittlerer Pinsel", "Dicker Pinsel"] }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(BrushSize.allCases.enumerated()), id: \.offset) { i, size in
                Button { withAnimation(Theme.spring) { brush = size } } label: {
                    Circle()
                        .fill(brush == size ? Color.accentColor : Theme.ink.opacity(0.55))
                        .frame(width: CGFloat(8 + i * 6), height: CGFloat(8 + i * 6))
                        .frame(width: 44, height: 44)
                        .background(brush == size ? Color.accentColor.opacity(0.16) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Self.labels[i])
                .accessibilityAddTraits(brush == size ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
