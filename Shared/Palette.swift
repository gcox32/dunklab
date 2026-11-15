import SwiftUI
import UIKit

// Shared with the widget extension, so Live Activities match the app.

/// Colors taken from a Vertec and a backboard. See DESIGN.md.
///
/// Nonisolated because SwiftUI can resolve these on its background render
/// thread (e.g. under a TimelineView); main-actor isolation traps there.
nonisolated enum Palette {
    static let backboard = dynamic(0xF3F5F6, 0x0F1A23)
    static let glass = dynamic(0xFFFFFF, 0x172430)
    static let ink = dynamic(0x16222D, 0xE8EDF1)
    static let inkSoft = dynamic(0x5A6773, 0x93A1AD)
    static let chalk = dynamic(0xD3D9DF, 0x2A3947)
    static let vaneBlue = dynamic(0x2457A8, 0x5B8DE0)
    /// Six-inch vanes and the dunk line only.
    static let vaneRed = dynamic(0xC7302A, 0xE5524B)
    /// The rim, nothing else.
    static let rim = dynamic(0xE0661C, 0xF07A2E)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Font {
    /// Measurements and titles: compressed numerals stack like tape on a Vertec pole.
    static func readout(_ style: Font.TextStyle) -> Font {
        .system(style, weight: .heavy).width(.compressed)
    }
}
