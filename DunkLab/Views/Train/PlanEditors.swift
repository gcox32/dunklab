import SwiftData
import SwiftUI

struct PlanDayEditor: View {
    @Bindable var day: PlanDay
    var isNew: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newItem: PlanItem?

    var body: some View {
        Form {
            Section {
                TextField("Workout name", text: $day.title)
                if day.week != nil {
                    Stepper(value: $day.restDaysBefore, in: 0...3) {
                        LabeledContent("Rest days before", value: "\(day.restDaysBefore)")
                    }
                }
            } footer: {
                if day.week != nil {
                    Text("Full days off between the previous program workout and this one. Today shows a rest day until it's time.")
                }
            }
            Section {
                ForEach(day.sortedItems) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.exercise.isEmpty ? "Untitled exercise" : item.exercise)
                            Text(Loads.summary(item.sets, basis: nil, perSide: item.perSide).joined(separator: ", "))
                                .font(.caption).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
                Button("Add exercise", action: add)
            } header: {
                SectionTitle("Exercises")
            }
        }
        .navigationTitle(isNew ? "New workout" : "Edit workout")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PlanItem.self) { PlanItemEditor(item: $0) }
        .navigationDestination(item: $newItem) { PlanItemEditor(item: $0) }
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        context.delete(day)
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if day.title.isEmpty { day.title = "My workout" }
                    try? context.save()
                    dismiss()
                }
            }
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
    }

    private func add() {
        let item = PlanItem(order: (day.items.map(\.order).max() ?? -1) + 1, exercise: "",
                            kind: .strength, sets: Array(repeating: SetSpec(reps: 5), count: 3))
        context.insert(item)
        item.day = day
        newItem = item
    }

    private func move(from source: IndexSet, to destination: Int) {
        var items = day.sortedItems
        items.move(fromOffsets: source, toOffset: destination)
        for (index, item) in items.enumerated() { item.order = index }
    }

    private func delete(at offsets: IndexSet) {
        let items = day.sortedItems
        for i in offsets { context.delete(items[i]) }
    }
}

struct PlanItemEditor: View {
    @Bindable var item: PlanItem

    @Query(sort: \StrengthTest.date, order: .reverse) private var tests: [StrengthTest]
    @Query private var allItems: [PlanItem]

    private var suggestions: [String] {
        guard !item.exercise.isEmpty else { return [] }
        let names = Set(allItems.map(\.exercise))
        return names.filter { $0.localizedCaseInsensitiveContains(item.exercise) && $0 != item.exercise }
            .sorted().prefix(5).map { $0 }
    }

    var body: some View {
        Form {
            Section {
                TextField("Exercise", text: $item.exercise)
                ForEach(suggestions, id: \.self) { name in
                    Button(name) {
                        item.exercise = name
                        if let match = allItems.first(where: { $0.exercise == name }) {
                            item.kind = match.kind
                            if item.videoURL == nil { item.videoURL = match.videoURL }
                        }
                    }
                }
                Picker("Type", selection: Binding(get: { item.kind }, set: { item.kind = $0 })) {
                    ForEach(ExerciseKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sides", selection: $item.perSide) {
                    Text("Both together").tag(String?.none)
                    Text("Each leg").tag(String?.some("leg"))
                    Text("Each side").tag(String?.some("side"))
                }
                TextField("Details, like \"down slowly\"", text: Binding(
                    get: { item.details ?? "" },
                    set: { item.details = $0.isEmpty ? nil : $0 }), axis: .vertical)
                TextField("Video link", text: Binding(
                    get: { item.videoURL ?? "" },
                    set: { item.videoURL = $0.isEmpty ? nil : $0 }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Strength read", selection: $item.gauge) {
                    Text("None").tag(Gauge?.none)
                    Text("Max test").tag(Gauge?.some(.maxTest))
                    Text("Bar speed").tag(Gauge?.some(.barSpeed))
                    Text("RSI").tag(Gauge?.some(.reactive))
                }
            } footer: {
                switch item.gauge {
                case .maxTest: Text("A heavy single here that beats your max can be saved as the new max.")
                case .barSpeed: Text("Rate how the bar moved. Decision time shows the last six weeks.")
                case .reactive: Text("Time a rep from a Slo-Mo clip for your RSI. It shows on the Body tab.")
                case nil: EmptyView()
                }
            }

            Section {
                ForEach(Array(item.sets.enumerated()), id: \.offset) { index, set in
                    NavigationLink {
                        SetSpecEditor(set: binding(index), basis: tests.first?.weightLb)
                            .navigationTitle("Set \(index + 1)")
                    } label: {
                        LabeledContent("Set \(index + 1)") {
                            Text([Loads.volume(set), Loads.describe(set.load, basis: tests.first?.weightLb)]
                                .compactMap { $0 }.joined(separator: " at "))
                        }
                    }
                }
                .onDelete { offsets in
                    var sets = item.sets
                    sets.remove(atOffsets: offsets)
                    item.sets = sets
                }
                Button("Add set") {
                    item.sets = item.sets + [item.sets.last ?? SetSpec(reps: 5)]
                }
            } header: {
                SectionTitle("Sets")
            } footer: {
                Text("Adding a set copies the last one.")
            }
        }
        .navigationTitle(item.exercise.isEmpty ? "Exercise" : item.exercise)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ index: Int) -> Binding<SetSpec> {
        Binding(
            get: { item.sets.indices.contains(index) ? item.sets[index] : SetSpec() },
            set: { new in
                var sets = item.sets
                guard sets.indices.contains(index) else { return }
                sets[index] = new
                item.sets = sets
            })
    }
}

struct SetSpecEditor: View {
    @Binding var set: SetSpec
    var basis: Double?

    private enum Measure: String, CaseIterable, Identifiable {
        case reps = "Reps", seconds = "Seconds", meters = "Meters", none = "Just do it"
        var id: String { rawValue }
    }

    private enum LoadKind: String, CaseIterable, Identifiable {
        case none = "None", percent = "% of squat max", effort = "Effort", pounds = "Pounds", bodyweight = "Bodyweight"
        var id: String { rawValue }
    }

    private var measure: Binding<Measure> {
        Binding(
            get: { set.reps != nil ? .reps : set.seconds != nil ? .seconds : set.meters != nil ? .meters : .none },
            set: { m in
                set.reps = m == .reps ? (set.reps ?? 5) : nil
                set.seconds = m == .seconds ? (set.seconds ?? 20) : nil
                set.meters = m == .meters ? (set.meters ?? 20) : nil
            })
    }

    private var loadKind: Binding<LoadKind> {
        Binding(
            get: {
                guard let load = set.load else { return .none }
                if load.percent != nil { return .percent }
                if load.effort != nil { return .effort }
                if load.pounds != nil { return .pounds }
                if load.bodyweight == true { return .bodyweight }
                return .none
            },
            set: { kind in
                switch kind {
                case .none: set.load = nil
                case .percent: set.load = LoadSpec(percent: set.load?.percent ?? 60)
                case .effort: set.load = LoadSpec(effort: set.load?.effort ?? .medium)
                case .pounds: set.load = LoadSpec(pounds: set.load?.pounds ?? Loads.pounds(set.load, basis: basis) ?? 45)
                case .bodyweight: set.load = LoadSpec(bodyweight: true)
                }
            })
    }

    var body: some View {
        Form {
            Section {
                Picker("Measure", selection: measure) {
                    ForEach(Measure.allCases) { Text($0.rawValue).tag($0) }
                }
                switch measure.wrappedValue {
                case .reps:
                    Stepper("\(set.reps ?? 0) reps", value: Binding(get: { set.reps ?? 0 }, set: { set.reps = $0 }), in: 1...100)
                case .seconds:
                    Stepper("\(set.seconds ?? 0) seconds", value: Binding(get: { set.seconds ?? 0 }, set: { set.seconds = $0 }), in: 5...600, step: 5)
                case .meters:
                    Stepper("\(set.meters ?? 0) m", value: Binding(get: { set.meters ?? 0 }, set: { set.meters = $0 }), in: 10...400, step: 10)
                case .none:
                    EmptyView()
                }
            }
            Section {
                Picker("Load", selection: loadKind) {
                    ForEach(LoadKind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch loadKind.wrappedValue {
                case .percent:
                    Stepper("\(Fmt.number(set.load?.percent ?? 0))%",
                            value: Binding(get: { set.load?.percent ?? 0 }, set: { set.load?.percent = $0 }),
                            in: 0...120, step: 2.5)
                    if let pounds = Loads.pounds(set.load, basis: basis) {
                        LabeledContent("At your current max", value: Fmt.pounds(pounds))
                    }
                case .effort:
                    Picker("Effort", selection: Binding(get: { set.load?.effort ?? .medium }, set: { set.load?.effort = $0 })) {
                        ForEach(Effort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(set.load?.effort?.guide ?? "").font(.footnote).foregroundStyle(Palette.inkSoft)
                case .pounds:
                    Stepper(Fmt.pounds(set.load?.pounds ?? 0),
                            value: Binding(get: { set.load?.pounds ?? 0 }, set: { set.load?.pounds = $0 }),
                            in: 0...1000, step: 5)
                case .none, .bodyweight:
                    EmptyView()
                }
            }
        }
    }
}
