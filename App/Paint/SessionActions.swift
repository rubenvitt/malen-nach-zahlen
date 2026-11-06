import Foundation

// Thin seam to canvas features that are not part of the fixed §4.2 API yet.
extension PaintingSession {
    /// Open fields of the selected colour pulse once (helps to find small fields).
    func pulseOpenFields() {
        // TODO(canvas): forward to the canvas' pulse API (asked for `flashOpenFields()`).
    }

    /// „Ganzes Bild“: zoom the canvas so the whole picture fits.
    func showWholePicture() {
        // TODO(canvas): forward to the canvas' zoom-to-fit API (asked for `zoomToFit()`).
    }
}
