import SwiftUI

struct LadderMark: Identifiable {
    enum Style { case rim, goal, nextDunk, touch, reach }

    var value: Double
    var label: String
    var style: Style

    var id: String { "\(style)-\(label)" }
}

/// The top of a Vertec, from a little below the rim to just above the goal dunk.
/// Vanes at or below the best touch are swept aside, the way they are after a real jump.
struct ReachLadder: View {
    var best: Double?
    var marks: [LadderMark]
    /// The lowest height drawn.
    var floor: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = false

    private let poleX: CGFloat = 10
    private let labelX: CGFloat = 104
    private let labelSpacing: CGFloat = 30

    private var range: ClosedRange<Double> {
        let values = marks.map(\.value) + [best].compactMap { $0 }
        let hi = ((values.max() ?? floor) + 2).rounded(.up)
        return floor...max(hi, floor + 12)
    }

    private var vanes: [Double] {
        let start = (range.lowerBound * 2).rounded(.up) / 2
        return Array(stride(from: start, through: range.upperBound, by: 0.5))
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let r = range
            let y = { (v: Double) -> CGFloat in
                height * (1 - CGFloat((v - r.lowerBound) / (r.upperBound - r.lowerBound)))
            }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Palette.inkSoft)
                    .frame(width: 3, height: height)
                    .offset(x: poleX - 1.5)

                ForEach(Array(vanes.enumerated()), id: \.offset) { index, value in
                    let hit = best.map { value <= $0 } ?? false
                    vane(value)
                        .scaleEffect(x: hit && swept ? 0.16 : 1, anchor: .leading)
                        .opacity(hit && swept ? 0.5 : 1)
                        .animation(
                            reduceMotion ? nil : .spring(duration: 0.4).delay(Double(index) * 0.012),
                            value: swept)
                        .offset(x: poleX + 2, y: y(value) - 1.75)
                }

                ForEach(marks) { mark in
                    line(mark.style)
                        .frame(width: labelX - poleX - 8)
                        .offset(x: poleX, y: y(mark.value) - 1)
                }

                let placed = placeLabels(y: y)
                ForEach(marks) { mark in
                    label(mark)
                        .offset(x: labelX, y: (placed[mark.id] ?? y(mark.value)) - 13)
                }
            }
        }
        .onAppear { swept = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Pieces

    private func vane(_ value: Double) -> some View {
        let six = value.truncatingRemainder(dividingBy: 6) == 0
        let inch = value.truncatingRemainder(dividingBy: 1) == 0
        let color = six ? Palette.vaneRed : inch ? Palette.vaneBlue : Palette.chalk
        let length: CGFloat = six ? 66 : inch ? 50 : 34
        return Capsule().fill(color).frame(width: length, height: 3.5)
    }

    @ViewBuilder
    private func line(_ style: LadderMark.Style) -> some View {
        switch style {
        case .rim:
            Rectangle().fill(Palette.rim).frame(height: 3)
        case .goal:
            Line().stroke(Palette.vaneRed, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(height: 2)
        case .nextDunk:
            Line().stroke(Palette.inkSoft.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(height: 1)
        case .touch:
            Rectangle().fill(Palette.vaneBlue).frame(height: 2)
        case .reach:
            Rectangle().fill(Palette.inkSoft).frame(height: 1)
        }
    }

    private func label(_ mark: LadderMark) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Fmt.feet(mark.value))
                .font(.readout(.title3))
                .monospacedDigit()
                .foregroundStyle(color(mark.style))
            Text(mark.label)
                .font(.subheadline)
                .foregroundStyle(mark.style == .nextDunk ? Palette.inkSoft : Palette.ink)
                .lineLimit(1)
        }
        .frame(height: 26)
    }

    private func color(_ style: LadderMark.Style) -> Color {
        switch style {
        case .rim: Palette.rim
        case .goal: Palette.vaneRed
        case .touch: Palette.vaneBlue
        case .nextDunk, .reach: Palette.inkSoft
        }
    }

    /// Pushes labels apart so neighbors never overlap, keeping them near their lines.
    private func placeLabels(y: (Double) -> CGFloat) -> [String: CGFloat] {
        let sorted = marks.sorted { $0.value > $1.value }
        var placed: [String: CGFloat] = [:]
        var last: CGFloat = -.infinity
        for mark in sorted {
            let target = max(y(mark.value), last + labelSpacing)
            placed[mark.id] = target
            last = target
        }
        return placed
    }

    private var accessibilitySummary: String {
        marks.sorted { $0.value > $1.value }
            .map { "\($0.label), \(Fmt.feet($0.value))" }
            .joined(separator: ". ")
    }
}

nonisolated private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
