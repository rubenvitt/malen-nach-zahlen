import SwiftUI
import PhotosUI
import PaintEngine

enum Route: Hashable {
    case editor(EditorSource)
    case paint(UUID)
}

struct GalleryView: View {
    @Binding var path: [Route]
    @Environment(ArtworkStore.self) private var store
    @State private var pickerItem: PhotosPickerItem?
    @State private var renaming: UUID?
    @State private var pending: PendingAction?

    private enum PendingAction: Identifiable {
        case delete(ArtworkMeta), restart(ArtworkMeta)
        var id: UUID { switch self { case .delete(let m), .restart(let m): m.id } }
        var meta: ArtworkMeta { switch self { case .delete(let m), .restart(let m): m } }
    }

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 24, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                section("Deine Bilder") {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        NewPictureCard()
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("newPicture")
                    ForEach(store.artworks) { meta in
                        ArtworkCard(meta: meta, image: store.thumbnail(for: meta), isRenaming: renaming == meta.id,
                                    onRename: { store.rename(meta.id, to: $0); renaming = nil },
                                    onOpen: { path.append(.paint(meta.id)) })
                            .contextMenu {
                                Button("Umbenennen", systemImage: "pencil") { renaming = meta.id }
                                Button("Neu starten", systemImage: "arrow.counterclockwise") { pending = .restart(meta) }
                                Button("Löschen", systemImage: "trash", role: .destructive) { pending = .delete(meta) }
                            }
                    }
                }
                section("Zum Ausprobieren") {
                    ForEach(Motif.all) { motif in
                        MotifCard(motif: motif) { path.append(.editor(.motif(motif))) }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .animation(Theme.spring, value: store.artworks)
        }
        .background(Theme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            path.append(.editor(.photo(item)))
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { action in
            switch action {
            case .delete(let meta):
                Button("Löschen", role: .destructive) { store.delete(meta.id) }
            case .restart(let meta):
                Button("Neu starten", role: .destructive) { restart(meta) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { action in
            switch action {
            case .delete: Text("Das Bild und alles Ausgemalte sind dann weg.")
            case .restart: Text("Alles Ausgemalte wird entfernt, die Vorlage bleibt.")
            }
        }
    }

    private var dialogTitle: String {
        switch pending {
        case .delete(let m): "„\(m.title)“ löschen?"
        case .restart(let m): "„\(m.title)“ neu starten?"
        case nil: ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Malen")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("Such dir ein Bild aus und leg los.")
                .font(.rounded(.title3, weight: .medium))
                .foregroundStyle(Theme.softInk)
        }
        .padding(.top, 12)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.rounded(.title2, weight: .bold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 28, content: content)
        }
    }

    private func restart(_ meta: ArtworkMeta) {
        Task {
            let template = try? await store.loadTemplate(meta.id)
            let thumb = template.flatMap(TemplateRenderer.thumbnailJPEG)
            store.restart(meta.id, thumbnail: thumb)
        }
    }
}

// MARK: Cards

private struct CardFrame<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.black.opacity(0.05)))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
    }
}

private struct NewPictureCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardFrame {
                ZStack {
                    LinearGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .bold))
                            .frame(width: 76, height: 76)
                            .background(.white.opacity(0.22), in: Circle())
                        Text("Aus deinen Fotos").font(.rounded(.headline))
                            .multilineTextAlignment(.center).minimumScaleFactor(0.6).padding(.horizontal, 8)
                    }
                    .foregroundStyle(.white)
                }
            }
            Text("Neues Bild").font(.rounded(.headline)).foregroundStyle(Theme.ink)
        }
    }
}

private struct ArtworkCard: View {
    let meta: ArtworkMeta
    let image: UIImage?
    let isRenaming: Bool
    let onRename: (String) -> Void
    let onOpen: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                CardFrame {
                    ZStack {
                        Color.white
                        if let image {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding(12)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if meta.isComplete {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            .padding(10)
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("\(meta.title), \(progressText)")
            .accessibilityIdentifier("artworkCard")

            Group {
                if isRenaming {
                    TextField("Titel", text: $draft)
                        .font(.rounded(.headline))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { onRename(draft) }
                        .onAppear { draft = meta.title; focused = true }
                        .onChange(of: focused) { if !focused { onRename(draft) } }
                } else {
                    // Large Dynamic Type: progress moves below the title instead of truncating it.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { title; Spacer(minLength: 4); progress }
                        VStack(alignment: .leading, spacing: 4) { title; progress }
                    }
                }
            }
            .accessibilityHidden(!isRenaming)
        }
    }

    private var title: some View {
        Text(meta.title).font(.rounded(.headline)).foregroundStyle(Theme.ink)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressRing(progress: meta.progress)
            Text(progressText)
                .font(.rounded(.subheadline, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.softInk)
        }
    }

    private var progressText: String {
        meta.isComplete ? "fertig" : meta.progress.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "de_DE")))
    }
}

private struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.ink.opacity(0.12), lineWidth: 3.5)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}

private struct MotifCard: View {
    let motif: Motif
    let action: () -> Void

    var body: some View {
        let image = motif.image
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                CardFrame {
                    if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [Theme.ink.opacity(0.06), Theme.ink.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom)
                            Image(systemName: "paintpalette").font(.system(size: 40)).foregroundStyle(Theme.softInk)
                        }
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(image == nil)
            .accessibilityLabel(motif.title)
            .accessibilityIdentifier(motif.id)
            Text(motif.title).font(.rounded(.headline)).foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
        }
    }
}
