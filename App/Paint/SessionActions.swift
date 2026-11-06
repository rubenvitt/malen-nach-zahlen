import Foundation

// UI-facing names for the canvas actions.
extension PaintingSession {
    /// Open fields of the selected colour pulse once (helps to find small fields).
    func pulseOpenFields() { flashOpenFields() }

    /// „Ganzes Bild“: zoom the canvas so the whole picture fits.
    func fitWholePicture() { showWholePicture() }
}
