import SwiftData
import SwiftUI

struct LadderEditor: View {
    let athlete: Athlete

    @Environment(\.modelContext) private var context
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]

    var body: some View {
        List {
            ForEach(stages) { stage in
                NavigationLink {
                    StageForm(stage: stage, rim: athlete.rimHeightIn)
                } label: {
                    LabeledContent(stage.name, value: "+\(Fmt.inches(stage.clearanceIn))")
                }
            }
            .onMove { source, destination in
                var items = stages
                items.move(fromOffsets: source, toOffset: destination)
                for (index, item) in items.enumerated() { item.order = index }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(stages[i]) }
            }
            Button("Add a dunk") {
                let last = stages.last
                context.insert(DunkStage(
                    order: (last?.order ?? -1) + 1, name: "New dunk", detail: "",
                    clearanceIn: (last?.clearanceIn ?? 6) + 2))
            }
        }
        .navigationTitle("Dunk ladder")
        .toolbar { EditButton() }
    }
}

private struct StageForm: View {
    @Bindable var stage: DunkStage
    var rim: Double

    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @Query private var sessions: [PracticeSession]

    var body: some View {
        Form {
            TextField("Name", text: $stage.name)
            TextField("Notes", text: $stage.detail, axis: .vertical)
            Section {
                Stepper("\(Fmt.inches(stage.clearanceIn)) over the rim", value: $stage.clearanceIn, in: 0...30, step: 0.5)
                LabeledContent("Hand height", value: Fmt.feet(rim + stage.clearanceIn))
            } footer: {
                Text("How high your hand needs to get for this dunk. Big hands that palm the ball need less.")
            }
            Section {
                let progress = DunkProgress(stages: stages, sessions: sessions)
                if let date = progress.landedDate(stage) {
                    LabeledContent("First landed", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Sessions with a make", value: "\(progress.sessionsMade(stage))")
                if !progress.isOwnedByPractice(stage) {
                    Toggle("Owned", isOn: Binding(
                        get: { stage.ownedAt != nil },
                        set: { stage.ownedAt = $0 ? .now : nil }))
                }
                if !progress.isOwned(stage) {
                    Toggle("Make this my goal", isOn: Binding(
                        get: { stage.isGoalPinned },
                        set: { _ in DunkProgress.pin(stage, in: stages) }))
                }
            } footer: {
                Text("Makes in \(DunkProgress.sessionsToOwn) separate practice sessions own a dunk. Mark one owned by hand if you could already do it.")
            }
        }
        .navigationTitle(stage.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FocusEditor: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PracticeFocus.order) private var focuses: [PracticeFocus]

    var body: some View {
        List {
            ForEach(focuses) { focus in
                NavigationLink(focus.name) { FocusForm(focus: focus) }
            }
            .onMove { source, destination in
                var items = focuses
                items.move(fromOffsets: source, toOffset: destination)
                for (index, item) in items.enumerated() { item.order = index }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(focuses[i]) }
            }
            Button("Add a focus") {
                context.insert(PracticeFocus(order: (focuses.last?.order ?? -1) + 1, name: "New focus", cue: ""))
            }
        }
        .navigationTitle("Focuses")
        .toolbar { EditButton() }
    }
}

private struct FocusForm: View {
    @Bindable var focus: PracticeFocus

    var body: some View {
        Form {
            TextField("Name", text: $focus.name)
            TextField("Cue", text: $focus.cue, axis: .vertical)
        }
        .navigationTitle(focus.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
