import SwiftUI
import PaintEngine

struct EditorView: View {
    let source: EditorSource
    let onStart: (UUID) -> Void

    @Environment(ArtworkStore.self) private var store
    @Environment(FullVersion.self) private var fullVersion
    @Environment(\.dismiss) private var dismiss
    @State private var model = EditorModel()
    @State private var editing = false
    @State private var starting = false
    @State private var showsFullVersion = false

    private var isPhoto: Bool {
        if case .photo = source { true } else { false }
    }

    /// Own photos beyond the free one need the full version; motifs never do.
    private var needsFullVersion: Bool { isPhoto && !fullVersion.canCreatePhoto }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.1
            Group {
                switch model.phase {
                case .loading: ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed: failed
                case .ready:
                    if wide {
                        HStack(spacing: 28) { preview; controls.frame(width: 380) }
                    } else {
                        VStack(spacing: 24) { preview; controls.fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            .padding(28)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(source) }
        .sheet(isPresented: $showsFullVersion) {
            FullVersionSheet { start() }
        }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(model.mode == .outline ? .high : .none)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 24, y: 10)
                    .accessibilityLabel("Vorschau der Vorlage")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Picker("Ansicht", selection: $model.mode.animation(.easeInOut(duration: 0.2))) {
                Text("Vorlage").tag(TemplateRenderer.Mode.outline)
                Text("Fertig").tag(TemplateRenderer.Mode.colored)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .offset(y: -14)
        }
        .overlay(alignment: .topTrailing) {
            if model.isBuilding && !editing {
                ProgressView().padding(12).background(.ultraThinMaterial, in: Circle()).padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isBuilding && !editing)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaletteStrip(palette: model.palette)

            sliderRow(title: "Farben", value: "\(Int(model.colors))") {
                Slider(value: $model.colors, in: 4...30, step: 1, onEditingChanged: editingChanged)
                    .accessibilityValue("\(Int(model.colors)) Farben")
            }
            .onChange(of: model.colors) { valueChanged() }

            sliderRow(title: "Details", value: detailLabel) {
                HStack(spacing: 10) {
                    Text("grob").font(.rounded(.footnote, weight: .medium)).foregroundStyle(Theme.softInk)
                    Slider(value: $model.detail, in: 0...1, step: 0.05, onEditingChanged: editingChanged)
                        .accessibilityValue(detailLabel)
                    Text("fein").font(.rounded(.footnote, weight: .medium)).foregroundStyle(Theme.softInk)
                }
            }
            .onChange(of: model.detail) { valueChanged() }

            Spacer(minLength: 0)

            Button(action: start) {
                HStack(spacing: 10) {
                    if starting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: needsFullVersion ? "lock.fill" : "paintbrush.pointed.fill")
                    }
                    Text("Los geht's")
                }
                .font(.rounded(.title3, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 60)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .shadow(color: Color.accentColor.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(PressableStyle())
            .disabled(starting || model.palette.isEmpty)
            .accessibilityIdentifier("startPainting")

            if isPhoto && !fullVersion.isUnlocked {
                Text(needsFullVersion ? "Für weitere eigene Fotos brauchst du die Vollversion."
                                      : "Dein erstes eigenes Foto ist gratis.")
                    .font(.rounded(.footnote, weight: .medium))
                    .foregroundStyle(Theme.softInk)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 6)
    }

    private var detailLabel: String {
        switch model.detail {
        case ..<0.25: String(localized: "grob")
        case ..<0.5: String(localized: "locker")
        case ..<0.75: String(localized: "fein")
        default: String(localized: "sehr fein")
        }
    }

    private func sliderRow(title: LocalizedStringKey, value: String, @ViewBuilder slider: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.rounded(.headline))
                Spacer()
                Text(value)
                    .font(.rounded(.headline, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.numericText())
            }
            slider()
        }
        .foregroundStyle(Theme.ink)
    }

    private func editingChanged(_ isEditing: Bool) {
        editing = isEditing
        if !isEditing { model.optionsCommitted() }
    }

    /// VoiceOver adjusts without an editing phase, so outside a drag go straight to full resolution.
    private func valueChanged() {
        if editing { model.optionsChanging() } else { model.optionsCommitted() }
    }

    private var failed: some View {
        ContentUnavailableView {
            Label("Das Bild ließ sich nicht öffnen", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Probier ein anderes Foto oder eins der Motive.")
        } actions: {
            Button("Zurück") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private func start() {
        guard !needsFullVersion else { showsFullVersion = true; return }
        starting = true
        Task {
            defer { starting = false }
            guard let template = await model.finalTemplate() else { return }
            let options = model.options, title = model.title
            let thumb = await Task.detached(priority: .userInitiated) { TemplateRenderer.thumbnailJPEG(template) }.value
            guard let meta = try? store.create(template: template, title: title, options: options, thumbnail: thumb)
            else { return }
            if isPhoto { fullVersion.photoCreated() }
            onStart(meta.id)
        }
    }
}

/// Numbered colour dots under the preview.
struct PaletteStrip: View {
    let palette: [PaletteColor]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deine Farben").font(.rounded(.headline)).foregroundStyle(Theme.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 46), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(palette.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(color.color)
                        .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                        .overlay(
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(color.isLight ? Color.black.opacity(0.7) : .white)
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel("Farbe \(index + 1)")
                }
            }
            .animation(Theme.spring, value: palette.count)
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
