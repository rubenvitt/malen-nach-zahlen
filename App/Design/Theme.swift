import SwiftUI
import PaintEngine

enum Theme {
    /// Warm paper in light mode, a soft dark workspace in dark mode.
    static let paper = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.11, green: 0.105, blue: 0.10, alpha: 1)
        : UIColor(red: 0.985, green: 0.965, blue: 0.93, alpha: 1) })
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.17, green: 0.16, blue: 0.155, alpha: 1)
        : UIColor.white })
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1)
        : UIColor(red: 0.20, green: 0.16, blue: 0.13, alpha: 1) })
    static let softInk = ink.opacity(0.6)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.72)
}

extension Font {
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension PaletteColor {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    /// Relative luminance check so numbers and checkmarks stay readable on the pot.
    var isLight: Bool { 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) > 160 }
}
