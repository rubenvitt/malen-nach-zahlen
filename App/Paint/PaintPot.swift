import SwiftUI
import PaintEngine

/// Round paint pot: colour, number, progress ring; a check once the colour is done.
struct PaintPot: View {
    let color: PaletteColor
    let number: Int
    let progress: Double
    let isDone: Bool
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Theme.ink.opacity(0.10), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(isDone ? Color.green : Theme.ink.opacity(0.75), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                Circle()
                    .fill(color.color.shadow(.inner(color: .black.opacity(0.18), radius: 3, y: -2)))
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                    .padding(7)
                Group {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .heavy))
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    } else {
                        Text("\(number)")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(color.isLight ? Color.black.opacity(0.72) : .white)
            }
            .frame(width: 60, height: 60)
            .scaleEffect(isSelected ? 1.14 : (isDone ? 0.88 : 1))
            .offset(y: isSelected && !reduceMotion ? -4 : 0)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.accentColor)
                    .frame(width: isSelected ? 18 : 0, height: 4)
                    .opacity(isSelected ? 1 : 0)
                    .offset(y: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: isSelected)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.5), value: isDone)
        .accessibilityLabel(isDone ? "Farbe \(number), fertig"
                                   : "Farbe \(number), \(progress.formatted(.percent.precision(.fractionLength(0)))) fertig")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("pot-\(number)")
    }
}
