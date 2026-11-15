import SwiftData
import SwiftUI

enum WorkoutFactory {
    /// Creates a log from a template, with targets and weights filled in.
    static func start(_ day: PlanDay, basis: Double?, in context: ModelContext) -> WorkoutLog {
        let log = WorkoutLog(title: day.title, context: day.contextLabel)
        context.insert(log)
        log.sourceDay = day
        for item in day.sortedItems {
            let entry = LoggedEntry(
                order: item.order, exercise: item.exercise, kind: item.kind,
                perSide: item.perSide, details: item.details, videoURL: item.videoURL,
                gauge: item.gauge, sets: sets(item.sets, basis: basis))
            context.insert(entry)
            entry.log = log
        }
        // Save before presenting: saving swaps the log's temporary ID for a permanent
        // one, and if that happens while its screen is up, the screen re-presents.
        try? context.save()
        return log
    }

    /// Sets to log from planned ones, with weights worked out from the max.
    static func sets(_ specs: [SetSpec], basis: Double?) -> [LoggedSet] {
        let sets = specs.map { spec in
            LoggedSet(
                target: spec, reps: spec.reps, seconds: spec.seconds, meters: spec.meters,
                weightLb: Loads.pounds(spec.load, basis: basis))
        }
        return sets.isEmpty ? [LoggedSet()] : sets
    }

    /// Switches an entry between a program exercise and the lifts allowed in its place.
    static func swap(_ entry: LoggedEntry, to exercise: String, using swap: ExerciseSwap, basis: Double?) {
        guard exercise != entry.exercise else { return }
        if exercise == swap.replaces,
           let item = entry.log?.sourceDay?.sortedItems.first(where: { $0.order == entry.order }) {
            entry.exercise = item.exercise
            entry.details = item.details
            entry.videoURL = item.videoURL
            entry.sets = sets(item.sets, basis: basis)
        } else {
            entry.exercise = exercise
            entry.details = swap.details
            entry.videoURL = nil
            entry.sets = sets(swap.sets, basis: basis)
        }
    }
}

struct WorkoutSessionView: View {
    @Bindable var log: WorkoutLog
    /// Set when the presenter wants to delete the log itself after this screen closes.
    var onDiscard: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    @State private var discardOnExit = false
    @State private var editing: SetLocation?
    @State private var stopwatch = Stopwatch()
    @State private var stopwatchOpen = UserDefaults.standard.bool(forKey: "stopwatchOpen")
    @State private var newMax: Double?
    @Query(sort: \StrengthTest.date, order: .reverse) private var tests: [StrengthTest]

    private var currentMax: Double? { tests.first?.weightLb }

    var body: some View {
        NavigationStack {
            List {
                ForEach(log.sortedEntries) { entry in
                    Section {
                        ForEach(Array(entry.sets.enumerated()), id: \.element.id) { index, set in
                            LoggedSetRow(entry: entry, index: index, set: set) {
                                editing = SetLocation(entry: entry, index: index)
                            }
                        }
                        if entry.gauge == .barSpeed { BarFeelPicker(entry: entry) }
                        if entry.gauge == .reactive { ReactiveEntryRows(entry: entry, log: log) }
                        if let swap = log.sourceDay?.program?.swap(for: entry.exercise) {
                            swapMenu(entry, swap)
                        }
                    } header: {
                        EntryHeader(entry: entry)
                    } footer: {
                        footer(entry)
                    }
                }
                Section {
                    TextField("How did it go?", text: $log.notes, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    SectionTitle("Notes")
                }
            }
            .safeAreaInset(edge: .bottom) {
                StopwatchPanel(stopwatch: stopwatch, isOpen: $stopwatchOpen)
            }
            .navigationTitle(log.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                }
                ToolbarItem(placement: .principal) {
                    TimelineView(.periodic(from: log.startedAt, by: 1)) { timeline in
                        Text(Duration.seconds(timeline.date.timeIntervalSince(log.startedAt)),
                             format: .time(pattern: .minuteSecond))
                            .font(.readout(.headline))
                            .monospacedDigit()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish", action: finish)
                }
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard) {
                Button("Discard workout", role: .destructive) {
                    if let onDiscard { onDiscard() } else { discardOnExit = true }
                    dismiss()
                }
            } message: {
                Text("Nothing from this workout will be saved.")
            }
            .sheet(item: $editing) { location in
                SetEditSheet(entry: location.entry, index: location.index)
                    .presentationDetents([.medium])
            }
            .alert("New max deep squat?", isPresented: Binding(get: { newMax != nil }, set: { if !$0 { newMax = nil } }),
                   presenting: newMax) { best in
                Button("Save \(Fmt.pounds(best))") {
                    context.insert(StrengthTest(date: log.startedAt, weightLb: best))
                    complete()
                }
                Button("Not now", role: .cancel) { complete() }
            } message: { best in
                Text(currentMax.map { "You lifted \(Fmt.pounds(best)), up from \(Fmt.pounds($0)). Program percentages will use the new max." }
                     ?? "You lifted \(Fmt.pounds(best)). Program percentages will use it as your max.")
            }
        }
        // Mirror the workout on the lock screen while this screen is up.
        .onChange(of: LiveActivities.state(for: log), initial: true) {
            if !discardOnExit { Task { await LiveActivities.show(log) } }
        }        // Delete only once the screen is gone, so nothing renders a deleted log.
        .onDisappear {
            LiveActivities.endWorkouts()
            if discardOnExit {
                context.delete(log)
                try? context.save()
            }
        }
    }

    @ViewBuilder
    private func footer(_ entry: LoggedEntry) -> some View {
        let efforts = Loads.efforts(entry.sets.compactMap(\.target))
        let gauge = gaugeNote(entry.gauge)
        if entry.details != nil || !efforts.isEmpty || gauge != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let details = entry.details { Text(details.capitalizedSentence) }
                ForEach(efforts) { Text("\($0.label): \($0.guide)") }
                if let gauge { Text(gauge) }
            }
        }
    }

    private func gaugeNote(_ gauge: Gauge?) -> String? {
        switch gauge {
        case .maxTest:
            currentMax.map { "Enter the weight of each single. Beat \(Fmt.pounds($0)) and Finish offers to save it as your new max." }
                ?? "Enter the weight of each single. Finish offers to save the heaviest as your max."
        case .barSpeed:
            "Strength work is light now, so how the bar moves on these singles shows where your strength is."
        case .reactive:
            "Film a set in Slo-Mo with the phone low and your feet in frame. Time your best rep now or from the workout's history later."
        case nil:
            nil
        }
    }

    private func swapMenu(_ entry: LoggedEntry, _ swap: ExerciseSwap) -> some View {
        Menu {
            ForEach([swap.replaces] + swap.options, id: \.self) { name in
                Button {
                    WorkoutFactory.swap(entry, to: name, using: swap, basis: currentMax)
                } label: {
                    if name == entry.exercise {
                        Label(name.capitalizedSentence, systemImage: "checkmark")
                    } else {
                        Text(name.capitalizedSentence)
                    }
                }
            }
        } label: {
            Label(entry.exercise == swap.replaces ? "Swap for an Olympic lift" : "Swap lift",
                  systemImage: "arrow.triangle.swap")
        }
    }

    private func finish() {
        if let best = log.maxTestBest, best > (currentMax ?? 0) {
            newMax = best
        } else {
            complete()
        }
    }

    private func complete() {
        log.finish()
        try? context.save()
        dismiss()
    }
}

/// How the bar moved, for a strength check done by feel.
struct BarFeelPicker: View {
    @Bindable var entry: LoggedEntry

    var body: some View {
        Picker("Bar speed", selection: $entry.feel) {
            Text("Not rated").tag(BarFeel?.none)
            ForEach(BarFeel.allCases) { Text($0.label).tag(BarFeel?.some($0)) }
        }
    }
}

struct EntryHeader: View {
    let entry: LoggedEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.exercise.capitalizedSentence)
                    .font(.readout(.title3))
                    .foregroundStyle(Palette.ink)
                if let side = entry.perSide {
                    Text("Each \(side)").font(.caption).foregroundStyle(Palette.inkSoft)
                }
            }
            Spacer()
            VideoButton(link: entry.videoURL)
        }
        .textCase(nil)
    }
}

/// One set: tap the circle to mark it done, tap the numbers to change them.
struct LoggedSetRow: View {
    let entry: LoggedEntry
    let index: Int
    let set: LoggedSet
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button {
                var sets = entry.sets
                sets[index].done.toggle()
                entry.sets = sets
            } label: {
                Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(set.done ? Palette.vaneBlue : Palette.chalk)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: set.done) { _, done in done }
            .accessibilityLabel(set.done ? "Done" : "Not done")

            Button(action: onEdit) {
                HStack {
                    Text(entry.sets.count > 1 ? "Set \(index + 1)" : "Done")
                        .foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Text(set.summary)
                        .font(.readout(.title3))
                        .monospacedDigit()
                        .foregroundStyle(set.done ? Palette.inkSoft : Palette.ink)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

extension LoggedSet {
    /// "4 × 205 lb", "20 s × medium"
    var summary: String {
        var parts: [String] = []
        if let reps { parts.append("\(reps)") }
        if let seconds { parts.append("\(seconds) s") }
        if let meters { parts.append("\(meters) m") }
        if let weightLb {
            parts.append(Fmt.pounds(weightLb))
        } else if let effort = target?.load?.effort {
            parts.append(effort.label.lowercased())
        } else if target?.load?.bodyweight == true {
            parts.append("bodyweight")
        }
        return parts.joined(separator: " × ")
    }
}

struct SetLocation: Identifiable {
    let entry: LoggedEntry
    let index: Int
    var id: String { "\(entry.persistentModelID.hashValue)-\(index)" }
}

/// Adjust what was actually done in one set.
struct SetEditSheet: View {
    let entry: LoggedEntry
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var set = LoggedSet()

    var body: some View {
        NavigationStack {
            Form {
                if set.reps != nil {
                    Stepper("\(set.reps ?? 0) reps", value: Binding(get: { set.reps ?? 0 }, set: { set.reps = $0 }), in: 0...100)
                }
                if set.seconds != nil {
                    Stepper("\(set.seconds ?? 0) seconds", value: Binding(get: { set.seconds ?? 0 }, set: { set.seconds = $0 }), in: 0...600, step: 5)
                }
                if set.meters != nil {
                    Stepper("\(set.meters ?? 0) m", value: Binding(get: { set.meters ?? 0 }, set: { set.meters = $0 }), in: 0...400, step: 10)
                }
                Section {
                    HStack {
                        Button("−5") { set.weightLb = max(0, (set.weightLb ?? 0) - 5) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text(set.weightLb.map(Fmt.pounds) ?? "No weight")
                            .font(.readout(.title))
                            .monospacedDigit()
                        Spacer()
                        Button("+5") { set.weightLb = (set.weightLb ?? 0) + 5 }
                            .buttonStyle(.bordered)
                    }
                    if set.weightLb != nil {
                        Button("Remove weight", role: .destructive) { set.weightLb = nil }
                    }
                } header: {
                    SectionTitle("Weight")
                }
            }
            .navigationTitle(entry.sets.count > 1 ? "Set \(index + 1)" : entry.exercise)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var sets = entry.sets
                        set.done = true
                        sets[index] = set
                        entry.sets = sets
                        dismiss()
                    }
                }
            }
            .onAppear {
                set = entry.sets[index]
                // Build-up sets by feel ("heavy") start from the set before.
                if set.weightLb == nil, set.target?.load != nil, index > 0 {
                    set.weightLb = entry.sets[index - 1].weightLb
                }
            }
        }
    }
}

extension String {
    var capitalizedSentence: String {
        prefix(1).uppercased() + dropFirst()
    }
}
