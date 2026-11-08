import SwiftUI
import StoreKit

/// Shown when „Los geht's“ would create a picture from a second own photo. No nagging anywhere else.
struct FullVersionSheet: View {
    let onUnlocked: () -> Void

    @Environment(FullVersion.self) private var fullVersion
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var note: Note?
    @State private var finished = false

    private enum Note {
        case pending, failed, nothingToRestore, storeUnavailable

        var text: LocalizedStringKey {
            switch self {
            case .pending: "Der Kauf wartet noch auf eine Bestätigung."
            case .failed: "Das hat nicht geklappt. Versuch es bitte noch einmal."
            case .nothingToRestore: "Kein Kauf gefunden."
            case .storeUnavailable: "Der App Store ist gerade nicht erreichbar."
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 104)
                    .background(Color.accentColor.gradient, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 8)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Male alle deine Fotos")
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                        .multilineTextAlignment(.center)
                    Text("Dein Foto zum Ausprobieren hast du schon verwendet. Mit der Vollversion wird jedes deiner Fotos zur Malvorlage, so viele du willst.")
                        .font(.rounded(.title3, weight: .medium))
                        .foregroundStyle(Theme.softInk)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.ink)

                VStack(alignment: .leading, spacing: 16) {
                    feature("infinity", "Unbegrenzt eigene Fotos")
                    feature("checkmark.seal", "Einmal zahlen, für immer. Kein Abo.")
                    feature("hand.raised", "Keine Werbung, keine Datensammlung")
                    feature("person.2", "Mit deiner Familie teilen")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(spacing: 14) {
                    buyButton
                    Button("Käufe wiederherstellen", action: restore)
                        .font(.rounded(.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(minHeight: 44)
                        .disabled(busy)
                        .accessibilityIdentifier("restorePurchases")
                    if let note {
                        Text(note.text)
                            .font(.rounded(.subheadline, weight: .medium))
                            .foregroundStyle(Theme.softInk)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    Text("Die mitgelieferten Motive bleiben gratis.")
                        .font(.rounded(.footnote, weight: .medium))
                        .foregroundStyle(Theme.softInk)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            RoundButton(systemImage: "xmark", label: "Schließen") { dismiss() }.padding(16)
        }
        .animation(.easeInOut(duration: 0.2), value: note)
        .task { await loadProduct() }
        .onChange(of: fullVersion.isUnlocked) { _, unlocked in
            if unlocked { finish() }   // e.g. Ask to Buy approved while the sheet is open
        }
    }

    private func feature(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text).font(.rounded(.headline)).foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder private var buyButton: some View {
        Button(action: buy) {
            HStack(spacing: 10) {
                if busy || fullVersion.isLoadingProduct {
                    ProgressView().tint(.white)
                } else if let price = displayPrice {
                    Text("Freischalten für \(price)")
                } else {
                    Text("Erneut versuchen")
                }
            }
            .font(.rounded(.title3, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: Color.accentColor.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(PressableStyle())
        .disabled(busy || fullVersion.isLoadingProduct)
        .accessibilityIdentifier("buyFullVersion")
    }

    private var displayPrice: String? {
        if let product = fullVersion.product { return product.displayPrice }
        #if DEBUG
        // App Review screenshot: the simulator in CI has no StoreKit products (`-uiTestPrice "$6.99"`).
        return UserDefaults.standard.string(forKey: "uiTestPrice")
        #else
        return nil
        #endif
    }

    private func loadProduct() async {
        await fullVersion.loadProduct()
        note = displayPrice == nil ? .storeUnavailable : nil
    }

    private func buy() {
        guard let product = fullVersion.product else {
            Task { await loadProduct() }
            return
        }
        busy = true
        note = nil
        Task {
            defer { busy = false }
            do {
                let result = try await purchase(product)
                switch await fullVersion.complete(result) {
                case .unlocked: finish()
                case .pending: note = .pending
                case .cancelled: break
                case .failed: note = .failed
                }
            } catch {
                note = .failed
            }
        }
    }

    private func restore() {
        busy = true
        note = nil
        Task {
            defer { busy = false }
            if await fullVersion.restore() { finish() } else { note = .nothingToRestore }
        }
    }

    /// Runs once, though both the purchase result and `isUnlocked` report the same unlock.
    private func finish() {
        guard !finished else { return }
        finished = true
        dismiss()
        onUnlocked()
    }
}
