import SwiftData
import SwiftUI

struct TrainView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Program.createdAt) private var programs: [Program]
    @Query(sort: \StrengthTest.date, order: .reverse) private var tests: [StrengthTest]
    @Query(sort: \WorkoutLog.startedAt, order: .reverse) private var logs: [WorkoutLog]
    @Query(filter: #Predicate<PlanDay> { $0.week == nil && $0.asNeededFor == nil },
           sort: \PlanDay.createdAt) private var ownWorkouts: [PlanDay]

    @State private var loggingMax = false
    @State private var runningLog: WorkoutLog?
    @State private var newWorkout: PlanDay?

    private var active: Program? { programs.first { $0.isActive } }

    var body: some View {
        NavigationStack {
            List {
                if let program = active {
                    Section {
                        programRows(program)
                    } header: {
                        SectionTitle(program.name)
                    }
                }

                Section {
                    if let max = tests.first {
                        LabeledContent("Current max") {
                            Text(Fmt.pounds(max.weightLb)).font(.readout(.title3))
                        }
                        Text("Tested \(max.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Palette.inkSoft)
                    }
                    Button("Log a new max") { loggingMax = true }
                    if tests.count > 1 {
                        NavigationLink("History") { StrengthHistoryView() }
                    }
                    if let videos = active?.basisVideos, !videos.isEmpty {
                        DisclosureGroup("How to test it") { BasisVideoRows(videos: videos) }
                    }
                } header: {
                    SectionTitle("Max deep squat")
                } footer: {
                    Text("Program percentages turn into weights from this number. Weeks 4 and 10 include a chance to max out.")
                }

                Section {
                    ForEach(ownWorkouts) { day in
                        NavigationLink(day.title.isEmpty ? "Untitled workout" : day.title) {
                            PlanDayView(day: day)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(ownWorkouts[i]) }
                    }
                    Button("New workout") {
                        let day = PlanDay(title: "")
                        context.insert(day)
                        newWorkout = day
                    }
                } header: {
                    SectionTitle("Your workouts")
                } footer: {
                    Text("Lifting, plyometrics or sprints of your own, alongside or instead of a program.")
                }

                if !logs.isEmpty {
                    let recent = Array(logs.prefix(15))
                    Section {
                        ForEach(recent) { log in
                            NavigationLink {
                                WorkoutLogDetail(log: log)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.context.map { "\($0), \(log.title.lowercased())" } ?? log.title)
                                    Text(log.finishedAt == nil
                                         ? "Not finished, started \(log.startedAt.formatted(date: .abbreviated, time: .shortened))"
                                         : log.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(log.finishedAt == nil ? Palette.vaneRed : Palette.inkSoft)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(recent[i]) }
                        }
                    } header: {
                        SectionTitle("Recent")
                    }
                }

                Section {
                    ForEach(programs) { program in
                        NavigationLink {
                            ProgramView(program: program)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(program.name)
                                Text(program.isActive ? "Following" : "\(program.weeks.count) weeks")
                                    .font(.caption).foregroundStyle(Palette.inkSoft)
                            }
                        }
                    }
                } header: {
                    SectionTitle("Programs")
                }
            }
            .navigationTitle("Train")
            .libraryButton()
            .sheet(isPresented: $loggingMax) { StrengthTestSheet() }
            .sheet(item: $newWorkout) { day in
                NavigationStack { PlanDayEditor(day: day, isNew: true) }
            }
            .fullScreenCover(item: $runningLog) { WorkoutSessionView(log: $0) }
        }
    }

    @ViewBuilder
    private func programRows(_ program: Program) -> some View {
        if program.awaitingDecision {
            NavigationLink {
                DecisionView(program: program)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(program.currentWeek) is done")
                    Text("Decide where the program goes next.")
                        .font(.caption).foregroundStyle(Palette.inkSoft)
                }
            }
        } else if let day = program.nextDay {
            let ready = Schedule.readyDate(for: day, in: program, logs: logs)
            NavigationLink {
                PlanDayView(day: day)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next: week \(program.currentWeek), \(day.title.lowercased())"
                         + (Calendar.current.isDateInToday(ready) ? "" : ", ready \(Fmt.day(ready))"))
                    Text(day.sortedItems.filter { $0.kind != .warmup }.prefix(3).map(\.exercise).joined(separator: ", "))
                        .font(.caption).foregroundStyle(Palette.inkSoft)
                }
            }
            Button("Start workout") {
                runningLog = WorkoutFactory.start(day, basis: tests.first?.weightLb, in: context)
            }
        }
        NavigationLink("Full program") { ProgramView(program: program) }
    }
}

struct StrengthTestSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double?
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                MeasureField("Max deep squat", value: $weight, unit: "lb")
                DatePicker("Tested", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("New max")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let weight { context.insert(StrengthTest(date: date, weightLb: weight)) }
                        dismiss()
                    }
                    .disabled(weight == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The program's videos on testing its basis lift, one row each.
struct BasisVideoRows: View {
    let videos: [VideoLink]

    var body: some View {
        ForEach(videos, id: \.self) { link in
            HStack {
                Text(link.title)
                Spacer()
                VideoButton(link: link.video)
            }
        }
    }
}

struct StrengthHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StrengthTest.date, order: .reverse) private var tests: [StrengthTest]

    var body: some View {
        List {
            ForEach(tests) { test in
                LabeledContent(test.date.formatted(date: .abbreviated, time: .omitted)) {
                    Text(Fmt.pounds(test.weightLb)).font(.readout(.title3))
                }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(tests[i]) }
            }
        }
        .navigationTitle("Squat history")
    }
}

struct WorkoutLogDetail: View {
    @Bindable var log: WorkoutLog

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SetLocation?
    @State private var resuming: WorkoutLog?
    @State private var confirmDelete = false
    @State private var deleteOnExit = false

    var body: some View {
        List {
            if log.finishedAt == nil {
                Section {
                    Button("Resume workout") { resuming = log }
                    Button("Mark as finished") {
                        log.finish(at: log.startedAt)
                    }
                } footer: {
                    Text("This workout was never finished. Mark it finished to count it, or delete it below.")
                }
            }

            Section {
                DatePicker("Date", selection: $log.startedAt)
                if let context = log.context {
                    LabeledContent("From", value: context)
                }
            }

            ForEach(log.sortedEntries) { entry in
                Section {
                    ForEach(Array(entry.sets.enumerated()), id: \.element.id) { index, set in
                        LoggedSetRow(entry: entry, index: index, set: set) {
                            editing = SetLocation(entry: entry, index: index)
                        }
                    }
                    if entry.gauge == .barSpeed { BarFeelPicker(entry: entry) }
                    if entry.gauge == .reactive { ReactiveEntryRows(entry: entry, log: log) }
                } header: {
                    EntryHeader(entry: entry)
                }
            }

            Section {
                TextField("How did it go?", text: $log.notes, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                SectionTitle("Notes")
            }

            Section {
                Button("Delete workout", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(log.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete workout", role: .destructive) {
                deleteOnExit = true
                dismiss()
            }
        } message: {
            Text("It's removed from your history. The program doesn't move back.")
        }
        .sheet(item: $editing) { location in
            SetEditSheet(entry: location.entry, index: location.index)
                .presentationDetents([.medium])
        }
        .fullScreenCover(item: $resuming, onDismiss: {
            if deleteOnExit { dismiss() }
        }) {
            WorkoutSessionView(log: $0) { deleteOnExit = true }
        }
        .onDisappear {
            if deleteOnExit {
                context.delete(log)
                try? context.save()
            }
        }
    }
}
