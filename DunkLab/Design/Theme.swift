import SwiftUI
import UIKit

enum Appearance {
    static func apply() {
        let large = UIFont.systemFont(ofSize: 40, weight: .heavy, width: .compressed)
        let inline = UIFont.systemFont(ofSize: 20, weight: .heavy, width: .compressed)
        let ink = UIColor(Palette.ink)
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
            .foregroundColor: ink,
        ]
        nav.titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline),
            .foregroundColor: ink,
        ]
    }
}

/// Full-width primary action, sized for a sweaty thumb.
struct BigButtonStyle: ButtonStyle {
    var tint: Color = Palette.vaneBlue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
