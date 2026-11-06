import UIKit

/// Saves at most every `interval` while painting (throttle, not debounce: continuous painting still saves),
/// and right away when leaving or going to the background.
@MainActor final class Autosaver {
    private let id: UUID
    private let store: ArtworkStore
    private let session: PaintingSession
    private let interval: Duration
    private var pending: Task<Void, Never>?
    private var dirty = false

    init(id: UUID, store: ArtworkStore, session: PaintingSession, interval: Duration = .seconds(2)) {
        self.id = id; self.store = store; self.session = session; self.interval = interval
    }

    func changed() {
        dirty = true
        guard pending == nil else { return }
        pending = Task { [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.save(withThumbnail: false)
        }
    }

    /// The gallery thumbnail is only rendered here, so strokes never pay for it.
    func flush() {
        pending?.cancel()
        pending = nil
        save(withThumbnail: true)
    }

    private func save(withThumbnail: Bool) {
        guard dirty else { return }
        dirty = false
        let thumb = withThumbnail ? session.renderFinished(showLines: true, maxSide: 900).jpegData(compressionQuality: 0.85) : nil
        store.save(id, paint: session.paintLayerPNG(), thumbnail: thumb, progress: session.progress)
    }
}
