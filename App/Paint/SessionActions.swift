import Foundation

// Seam to canvas features outside the fixed §4.2 API. The canvas branch adds
// `flashOpenFields()` and `showWholePicture()` on PaintingSession; these names differ on purpose
// so both branches merge without a duplicate declaration.
extension PaintingSession {
    /// Open fields of the selected colour pulse once (helps to find small fields).
    func pulseOpenFields() {
        // TODO(canvas-merge): call `flashOpenFields()`.
    }

    /// „Ganzes Bild“: zoom the canvas so the whole picture fits.
    func fitWholePicture() {
        // TODO(canvas-merge): call `showWholePicture()`.
    }
}
