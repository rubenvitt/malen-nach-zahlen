import UIKit
import Observation
import PaintEngine

// API fixed by docs/superpowers/specs/2026-11-06-malen-design.md §4.2 — stub until the canvas track lands.

enum BrushSize: CaseIterable, Codable { case small, medium, large }

@MainActor @Observable final class PaintingSession {
    let template: Template
    var selectedColor = 0
    var brush: BrushSize = .medium
    private(set) var progressByColor: [Double]
    private(set) var progress: Double = 0
    private(set) var completedColors: Set<Int> = []
    var isComplete: Bool { progress >= 1 }
    var canUndo: Bool { false }
    @ObservationIgnored var onStrokeEnded: (() -> Void)?
    @ObservationIgnored var onFieldCompleted: ((Int32) -> Void)?
    @ObservationIgnored var onColorCompleted: ((Int) -> Void)?

    init(template: Template, paintLayerPNG: Data?) {
        self.template = template
        progressByColor = Array(repeating: 0, count: template.palette.count)
    }

    func undo() {}
    func paintLayerPNG() -> Data { Data() }
    func renderFinished(showLines: Bool, maxSide: Int) -> UIImage { UIImage() }
}
