import Charts
import SwiftData
import SwiftUI

/// The two numbers that best predict a jump, side by side: how much force you
/// have for your size (squat ÷ bodyweight) and how fast you use it (RSI).
/// Two charts on one time axis rather than one chart with two scales.
struct JumpSignalsSection: View {
    @Query(sort: \StrengthTest.date) private var squats: [StrengthTest]
    @Query(sort: \BodyEntry.date) private var entries: [BodyEntry]
    @Query(sort: \JumpTest.date) private var tests: [JumpTest]

    /// Shared by both charts, so a tap on one marks the same date on the other.
    @State private var selected: Date?

    private var ratio: [SignalPoint] {
        Signals.squatRatio(
            squats: squats.map { ($0.date, $0.weightLb) },
            weights: entries.compactMap { entry in entry.weightLb.map { (entry.date, $0) } })
    }

    /// RSI is only comparable within one kind of test, and until motion timing is
    /// checked against video, one way of timing. Chart whatever was tested most recently.
    private var rsiKind: JumpTestKind? { tests.last?.kind }
    private var rsiSource: JumpSource? { tests.last?.source }

    private var rsi: [SignalPoint] {
        guard let rsiKind, let rsiSource else { return [] }
        return Signals.rsi(tests.filter { $0.kind == rsiKind && $0.source == rsiSource }.map { ($0.date, $0.best?.rsi) })
    }

    private var rsiTitle: String {
        let title = switch rsiKind {
        case .cmj: "RSI-mod, CMJ"
        case .pogo: "RSI, pogo hops"
        default: "RSI, drop jump"
        }
        return rsiSource == .motion ? title + ", motion" : title
    }

    var body: some View {
        let ratio = ratio
        let rsi = rsi
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                readout(ratio.last.map { Signals.ratioText($0.value) } ?? "–", unit: "×", label: "Squat ÷ weight")
                readout(rsi.last.map { Reactive.rsiText($0.value) } ?? "–", unit: "", label: rsiKind == .cmj ? "RSI-mod" : "RSI")
            }
            .padding(.vertical, 6)

            let domain = sharedDomain(ratio, rsi)
            if ratio.count > 1 {
                chart("Squat ÷ bodyweight", points: ratio, format: { "\(Signals.ratioText($0))×" },
                      steps: true, domain: domain)
            }
            if rsi.count > 1 {
                chart(rsiTitle, points: rsi, format: Reactive.rsiText, steps: false, domain: domain)
            }
        } header: {
            SectionTitle("Jump signals")
        } footer: {
            Text(footer(ratio: ratio, rsi: rsi))
        }
    }

    private func footer(ratio: [SignalPoint], rsi: [SignalPoint]) -> String {
        var text = "Squat ÷ bodyweight is how much force you have for your size. RSI is how fast you use it."
        if ratio.isEmpty { text += " Log a squat max and your weight to see the first." }
        if rsi.isEmpty { text += " Time a drop jump below to see the second." }
        return text
    }

    private func sharedDomain(_ a: [SignalPoint], _ b: [SignalPoint]) -> ClosedRange<Date> {
        let dates = (a + b).map(\.date)
        let start = dates.min() ?? .now
        let end = max(dates.max() ?? .now, start.addingTimeInterval(86_400))
        return start...end
    }

    private func nearest(_ points: [SignalPoint], to date: Date) -> SignalPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func chart(_ title: String, points: [SignalPoint], format: @escaping (Double) -> String,
                       steps: Bool, domain: ClosedRange<Date>) -> some View {
        let focus = selected.flatMap { nearest(points, to: $0) }
        let shown = focus ?? points.last
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let shown {
                    Text("\(format(shown.value)), \(shown.date.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(focus == nil ? Palette.inkSoft : Palette.ink)
                }
            }
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value(title, point.value))
                        .interpolationMethod(steps ? .stepEnd : .linear)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Palette.vaneBlue)
                    PointMark(x: .value("Date", point.date), y: .value(title, point.value))
                        .symbolSize(30)
                        .foregroundStyle(Palette.vaneBlue)
                }
                if let focus {
                    RuleMark(x: .value("Date", focus.date))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Palette.inkSoft.opacity(0.5))
                    PointMark(x: .value("Date", focus.date), y: .value(title, focus.value))
                        .symbolSize(90)
                        .foregroundStyle(Palette.vaneBlue)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXSelection(value: $selected)
            .frame(height: 120)
            .accessibilityLabel(title)
        }
        .padding(.vertical, 8)
    }

    private func readout(_ value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 44, weight: .heavy).width(.compressed)).monospacedDigit()
                if !unit.isEmpty { Text(unit).foregroundStyle(Palette.inkSoft) }
            }
            Text(label).font(.subheadline).foregroundStyle(Palette.inkSoft)
        }
    }
}
