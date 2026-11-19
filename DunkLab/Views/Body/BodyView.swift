import Charts
import SwiftData
import SwiftUI

struct BodyView: View {
    @Bindable var athlete: Athlete

    @Environment(\.modelContext) private var context
    @Query(sort: \BodyEntry.date, order: .reverse) private var entries: [BodyEntry]
    @State private var logging = false

    private var latestWeight: BodyEntry? { entries.first { $0.weightLb != nil } }
    private var latestFat: BodyEntry? { entries.first { $0.bodyFatPct != nil } }

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 28) {
                        readout(latestWeight?.weightLb.map { Fmt.number($0) } ?? "–", unit: "lb", label: "Weight")
                        readout(latestFat?.bodyFatPct.map { Fmt.number($0) } ?? "–", unit: "%", label: "Body fat")
                    }
                    .padding(.vertical, 6)
                    Button("Log weight and body fat") { logging = true }
                }

                let weights = entries.filter { $0.weightLb != nil }
                if weights.count > 1 {
                    Section {
                        Chart(weights) { entry in
                            LineMark(x: .value("Date", entry.date), y: .value("Weight", entry.weightLb ?? 0))
                                .foregroundStyle(Palette.vaneBlue)
                            PointMark(x: .value("Date", entry.date), y: .value("Weight", entry.weightLb ?? 0))
                                .foregroundStyle(Palette.vaneBlue)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 160)
                        .padding(.vertical, 8)
                    } header: {
                        SectionTitle("Weight")
                    }
                }

                JumpSignalsSection()
                ReactiveSection()

                if let weight = latestWeight?.weightLb {
                    nutrition(weight: weight)
                }

                Section {
                    MeasureField("Height", value: $athlete.heightIn.optional, unit: "in", showFeet: true)
                    MeasureField("Standing reach", value: $athlete.standingReachIn.optional, unit: "in", showFeet: true)
                    if athlete.heightIn > 0 {
                        LabeledContent("Reach above height", value: Fmt.inches(athlete.standingReachIn - athlete.heightIn))
                    }
                } header: {
                    SectionTitle("Frame")
                } footer: {
                    Text("These rarely change. Standing reach is the floor of the ladder on Today.")
                }

                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            LabeledContent(entry.date.formatted(date: .abbreviated, time: .omitted)) {
                                Text([entry.weightLb.map(Fmt.pounds), entry.bodyFatPct.map { "\(Fmt.number($0))%" }]
                                    .compactMap { $0 }.joined(separator: ", "))
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(entries[i]) }
                        }
                    } header: {
                        SectionTitle("History")
                    }
                }
            }
            .navigationTitle("Measure")
            // Applied first so the library keeps the far-right spot it has on every tab.
            .libraryButton()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(athlete: athlete) } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $logging) {
                BodyEntrySheet(lastWeight: latestWeight?.weightLb, lastFat: latestFat?.bodyFatPct)
            }
        }
    }

    private func readout(_ value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 44, weight: .heavy).width(.compressed)).monospacedDigit()
                Text(unit).foregroundStyle(Palette.inkSoft)
            }
            Text(label).font(.subheadline).foregroundStyle(Palette.inkSoft)
        }
    }

    private func nutrition(weight: Double) -> some View {
        let targets = NutritionTargets.make(
            weightLb: weight, bodyFatPct: latestFat?.bodyFatPct, leanPct: athlete.leanBodyFatPct)
        return Section {
            LabeledContent("Carbohydrate", value: "\(Int(targets.carbsG.rounded())) g or more")
            LabeledContent("Protein", value: "\(Int(targets.proteinG.rounded())) g")
            LabeledContent("Fat", value: "\(Int(targets.fatG.rounded())) g")
            LabeledContent("Calories, about", value: "\(Int(targets.calories.rounded()))")
        } header: {
            SectionTitle("Daily targets")
        } footer: {
            Text(nutritionFooter(targets, weight: weight))
        }
    }

    private func nutritionFooter(_ targets: NutritionTargets, weight: Double) -> String {
        var text = "Per kilogram: 3+ g carbs, 1.5 g protein, 1 g fat. Eat more carbs on days you play."
        if abs(targets.basisLb - weight) > 0.5 {
            text = "Based on \(Fmt.pounds(targets.basisLb.rounded())), your weight at \(Fmt.number(athlete.leanBodyFatPct))% body fat. " + text
        } else if latestFat == nil {
            text += " Add body fat to base this on lean weight."
        }
        return text
    }
}

struct BodyEntrySheet: View {
    var lastWeight: Double?
    var lastFat: Double?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double?
    @State private var fat: Double?
    @State private var date = Date.now

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        NavigationStack {
            Form {
                MeasureField("Weight", value: $weight, unit: "lb", prompt: lastWeight.map { Fmt.number($0) } ?? "")
                MeasureField("Body fat", value: $fat, unit: "%", prompt: lastFat.map { Fmt.number($0) } ?? "Optional")
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("Log body")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        context.insert(BodyEntry(date: date, weightLb: weight, bodyFatPct: fat))
                        dismiss()
                    }
                    .disabled(weight == nil && fat == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// How the app is set up, rather than anything measured: the rim, the week's
/// play budget, what counts as lean, and where clips are stored.
struct SettingsView: View {
    @Bindable var athlete: Athlete

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        Form {
            Section {
                MeasureField("Rim height", value: $athlete.rimHeightIn.optional, unit: "in", showFeet: true)
                Stepper("Play budget \(Fmt.minutes(Double(athlete.weeklyPlayMinutes))) a week",
                        value: $athlete.weeklyPlayMinutes, in: 60...600, step: 30)
                Stepper("Lean means \(Fmt.number(athlete.leanBodyFatPct))% body fat",
                        value: $athlete.leanBodyFatPct, in: 5...25, step: 1)
            } header: {
                SectionTitle("Training")
            } footer: {
                Text("Jump Science treats 10% body fat as lean for men and 15% for women.")
            }

            Section {
                NavigationLink("Clip storage") { CloudSettingsView() }
            } header: {
                SectionTitle("Videos")
            }

            #if DEBUG
            Section {
                NavigationLink("Slo-Mo probe") { SlowMoProbeView() }
            } header: {
                SectionTitle("Debug")
            }
            #endif
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }
}
