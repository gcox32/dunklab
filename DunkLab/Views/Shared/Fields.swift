import SwiftData
import SwiftUI

/// A numeric field with a unit, backed by text so every keystroke counts.
struct MeasureField: View {
    let title: String
    @Binding var value: Double?
    var unit: String
    var showFeet = false
    var prompt = ""

    @State private var text = ""

    init(_ title: String, value: Binding<Double?>, unit: String, showFeet: Bool = false, prompt: String = "") {
        self.title = title
        self._value = value
        self.unit = unit
        self.showFeet = showFeet
        self.prompt = prompt
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(prompt, text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                Text(unit)
                    .foregroundStyle(Palette.inkSoft)
                    .frame(minWidth: 18, alignment: .leading)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if showFeet, let value, value > 0 {
                    Text(Fmt.feet(value))
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
            }
        }
        .onAppear {
            if let value { text = value.formatted(.number.grouping(.never)) }
        }
        .onChange(of: text) {
            value = Double(text.replacingOccurrences(of: ",", with: "."))
        }
    }
}

/// Wraps a non-optional Double so it can use MeasureField.
extension Binding where Value == Double {
    var optional: Binding<Double?> {
        Binding<Double?>(get: { wrappedValue }, set: { if let v = $0 { wrappedValue = v } })
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.readout(.title2))
            .foregroundStyle(Palette.ink)
            .textCase(nil)
    }
}

/// Plus and minus a half inch around a big readout.
struct TouchPicker: View {
    @Binding var value: Double
    var rim: Double

    var body: some View {
        VStack(spacing: 8) {
            Text(Fmt.feet(value))
                .font(.system(size: 72, weight: .heavy).width(.compressed))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
            Text(aboveRim)
                .foregroundStyle(Palette.inkSoft)
            HStack(spacing: 16) {
                step(-0.5, "minus")
                step(0.5, "plus")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: value)
    }

    private var aboveRim: String {
        let d = value - rim
        if d == 0 { return "Level with the rim" }
        return d > 0 ? "\(Fmt.inches(d)) above the rim" : "\(Fmt.inches(-d)) below the rim"
    }

    private func step(_ delta: Double, _ icon: String) -> some View {
        Button {
            withAnimation(.snappy) { value += delta }
        } label: {
            Image(systemName: icon)
                .font(.title2.weight(.bold))
                .frame(width: 88, height: 56)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(delta > 0 ? "Half inch higher" : "Half inch lower")
    }
}
