import SwiftUI
import PaintEngine

struct CompletionView: View {
    enum Mode { case celebrate, look }

    let session: PaintingSession
    let title: String
    let palette: [PaletteColor]
    let fallback: UIImage?
    let mode: Mode
    let onClose: () -> Void
    let onGallery: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLines = false
    @State private var images: [Bool: UIImage] = [:]
    @State private var appeared = false

    private var image: UIImage? {
        if let rendered = images[showLines], rendered.size != .zero { return rendered }
        return fallback
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            Theme.paper.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text(mode == .celebrate ? "Geschafft!" : "Dein Bild")
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    Text(title).font(.rounded(.title3, weight: .medium)).foregroundStyle(Theme.softInk)
                }
                .foregroundStyle(Theme.ink)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 30, y: 14)
                        .frame(maxWidth: 820, maxHeight: 620)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
                        .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -3))
                        .accessibilityLabel("Fertiges Bild")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showLines.toggle() }
                } label: {
                    Label(showLines ? "Ränder ausblenden" : "Ränder zeigen",
                          systemImage: showLines ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .font(.rounded(.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(PressableStyle())

                HStack(spacing: 14) {
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
                            Label("Teilen", systemImage: "square.and.arrow.up")
                                .font(.rounded(.title3, weight: .bold))
                                .frame(minWidth: 180, minHeight: 58)
                                .foregroundStyle(.white)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    Button(action: onGallery) {
                        Label("Zur Galerie", systemImage: "square.grid.2x2")
                            .font(.rounded(.title3, weight: .bold))
                            .frame(minWidth: 180, minHeight: 58)
                            .foregroundStyle(Theme.ink)
                            .background(Theme.card, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(32)

            if mode == .celebrate && !reduceMotion {
                ConfettiView(colors: palette.map(\.color) + [.accentColor]).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            RoundButton(systemImage: "xmark", label: "Schließen", action: onClose).padding(20)
        }
        .onAppear {
            images[false] = session.renderFinished(showLines: false, maxSide: 2048)
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.1)) { appeared = true }
        }
        .onChange(of: showLines) { _, lines in
            if images[lines] == nil { images[lines] = session.renderFinished(showLines: lines, maxSide: 2048) }
        }
    }
}

/// Paper confetti in the colours of the finished picture.
struct ConfettiView: View {
    let colors: [Color]
    @State private var start = Date.now
    @State private var pieces: [Piece] = []
    @State private var finished = false

    struct Piece {
        var x: Double, delay: Double, speed: Double, sway: Double, phase: Double, spin: Double
        var size: CGSize, color: Int, round: Bool
    }

    var body: some View {
        TimelineView(.animation(paused: finished)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                for p in pieces {
                    let lt = t - p.delay
                    guard lt > 0 else { continue }
                    let y = -30 + lt * p.speed + 60 * lt * lt
                    guard y < size.height + 40 else { continue }
                    let x = p.x * size.width + sin(lt * 2.2 + p.phase) * p.sway
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(lt * p.spin))
                    c.scaleBy(x: 1, y: abs(cos(lt * 3 + p.phase)) * 0.8 + 0.2)   // paper flutter
                    let rect = CGRect(origin: CGPoint(x: -p.size.width / 2, y: -p.size.height / 2), size: p.size)
                    let path = p.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 2)
                    c.fill(path, with: .color(colors.isEmpty ? .accentColor : colors[p.color % colors.count]))
                }
            }
        }
        .opacity(finished ? 0 : 1)
        .task {
            try? await Task.sleep(for: .seconds(6))
            finished = true
        }
        .onAppear {
            start = .now
            pieces = (0..<160).map { _ in
                Piece(x: .random(in: 0...1), delay: .random(in: 0...1.4), speed: .random(in: 120...320),
                      sway: .random(in: 10...50), phase: .random(in: 0...(2 * .pi)), spin: .random(in: -6...6),
                      size: CGSize(width: .random(in: 8...14), height: .random(in: 10...20)),
                      color: .random(in: 0..<max(colors.count, 1)), round: .random(in: 0...1) < 0.25)
            }
        }
    }
}
