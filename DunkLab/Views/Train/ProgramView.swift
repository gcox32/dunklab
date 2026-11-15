import SwiftData
import SwiftUI

struct ProgramView: View {
    @Bindable var program: Program
    @Query(sort: \Program.createdAt) private var programs: [Program]

    var body: some View {
        List {
            Section {
                Text(program.summary)
                if !program.basisVideos.isEmpty {
                    DisclosureGroup("Before you start: test your \(program.percentBasis)") {
                        BasisVideoRows(videos: program.basisVideos)
                    }
                }
                if !program.guidelines.isEmpty {
                    DisclosureGroup("How to read the program") {
                        ForEach(program.guidelines, id: \.self) { line in
                            Text(line).font(.subheadline).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
                if !program.isActive {
                    Button("Follow this program") {
                        for other in programs { other.isActive = false }
                        program.isActive = true
                        program.jump(toWeek: program.sortedWeeks.first?.number ?? 1)
                    }
                }
            } footer: {
                if !program.author.isEmpty { Text(program.author) }
            }

            ForEach(program.sortedWeeks) { week in
                Section {
                    ForEach(Array(week.sortedDays.enumerated()), id: \.element.id) { index, day in
                        NavigationLink {
                            PlanDayView(day: day)
                        } label: {
                            dayRow(week: week, index: index, day: day)
                        }
                    }
                    if let decision = week.decision {
                        DisclosureGroup("Decision time") {
                            Text(decision).font(.subheadline).foregroundStyle(Palette.inkSoft)
                        }
                    }
                } header: {
                    SectionTitle("Week \(week.number)")
                }
            }

            if !program.asNeeded.isEmpty {
                Section {
                    ForEach(program.sortedAsNeeded) { day in
                        NavigationLink(day.title) { PlanDayView(day: day) }
                    }
                } header: {
                    SectionTitle("As needed")
                } footer: {
                    Text("Isometrics for tendon health and stretches for flexibility. Do them as often as you need, including at the start of a warm-up.")
                }
            }
        }
        .navigationTitle(program.name)
    }

    private func dayRow(week: ProgramWeek, index: Int, day: PlanDay) -> some View {
        let isNext = program.isActive && !program.awaitingDecision
            && program.currentWeek == week.number && program.currentDay == index
        let isDone = program.isActive
            && (week.number < program.currentWeek
                || (week.number == program.currentWeek && index < program.currentDay))
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.title).fontWeight(isNext ? .semibold : .regular)
                Text(day.sortedItems.filter { $0.kind != .warmup }.prefix(3).map(\.exercise).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(1)
            }
            Spacer()
            if isNext {
                Text("Next").font(.caption.weight(.semibold)).foregroundStyle(Palette.vaneBlue)
            } else if isDone {
                Image(systemName: "checkmark").foregroundStyle(Palette.inkSoft)
            }
        }
    }
}

/// One workout template, with weights worked out from the current max.
struct PlanDayView: View {
    @Bindable var day: PlanDay

    @Environment(\.modelContext) private var context
    @Query(sort: \StrengthTest.date, order: .reverse) private var tests: [StrengthTest]
    @State private var editing = false
    @State private var runningLog: WorkoutLog?

    private var basis: Double? { tests.first?.weightLb }

    var body: some View {
        List {
            if day.items.isEmpty {
                Text("No exercises yet. Tap Edit to add some.")
                    .foregroundStyle(Palette.inkSoft)
            }
            ForEach(day.sortedItems) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.exercise.capitalizedSentence).font(.headline)
                        Spacer()
                        VideoButton(link: item.videoURL)
                    }
                    ForEach(Loads.summary(item.sets, basis: basis, perSide: item.perSide), id: \.self) { line in
                        Text(line).font(.readout(.body)).monospacedDigit()
                    }
                    if let details = item.details {
                        Text(details.capitalizedSentence).font(.subheadline).foregroundStyle(Palette.inkSoft)
                    }
                }
                .padding(.vertical, 2)
            }
            if basis == nil, day.items.contains(where: { $0.sets.contains { $0.load?.percent != nil } }) {
                Text("Log a max deep squat in Train to turn percentages into weights.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .navigationTitle(navTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            if let program = day.week?.program, program.isActive, let week = day.week,
               program.nextDay?.persistentModelID != day.persistentModelID {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Make this the next workout") {
                        let index = week.sortedDays.firstIndex { $0.persistentModelID == day.persistentModelID } ?? 0
                        program.jump(toWeek: week.number, day: index)
                    }
                }
            }
            if !day.isOwnWorkout {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy to your workouts") { copyToOwn() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !day.items.isEmpty {
                Button("Start workout") {
                    runningLog = WorkoutFactory.start(day, basis: basis, in: context)
                }
                .buttonStyle(BigButtonStyle())
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { PlanDayEditor(day: day, isNew: false) }
        }
        .fullScreenCover(item: $runningLog) { WorkoutSessionView(log: $0) }
    }

    private var navTitle: String {
        if let week = day.week { return "Week \(week.number), \(day.title.lowercased())" }
        return day.title.isEmpty ? "Untitled workout" : day.title
    }

    private func copyToOwn() {
        let copy = PlanDay(title: navTitle)
        context.insert(copy)
        for item in day.sortedItems {
            let new = PlanItem(order: item.order, exercise: item.exercise, kind: item.kind,
                               sets: item.sets, perSide: item.perSide, details: item.details,
                               videoURL: item.videoURL, gauge: item.gauge)
            context.insert(new)
            new.day = copy
        }
    }
}

struct DecisionView: View {
    @Bindable var program: Program
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StrengthTest.date) private var tests: [StrengthTest]
    @Query(sort: \TouchRecord.date) private var touches: [TouchRecord]
    @Query(sort: \WorkoutLog.startedAt) private var logs: [WorkoutLog]

    private var windowStart: Date { Calendar.current.date(byAdding: .weekOfYear, value: -6, to: .now)! }

    /// Bar-speed checks logged in the last six weeks, oldest first.
    private var checks: [(date: Date, entry: LoggedEntry)] {
        logs.filter { $0.finishedAt != nil && $0.startedAt >= windowStart }
            .flatMap { log in log.sortedEntries.filter { $0.gauge == .barSpeed }.map { (log.startedAt, $0) } }
    }

    var body: some View {
        List {
            Section {
                trend("Max deep squat",
                      before: tests.last { $0.date < windowStart }?.weightLb,
                      now: tests.last?.weightLb,
                      format: Fmt.pounds)
                trend("Best touch",
                      before: touches.filter { $0.date < windowStart }.map(\.heightIn).max(),
                      now: touches.filter { $0.date >= windowStart }.map(\.heightIn).max(),
                      format: Fmt.feet)
            } header: {
                SectionTitle("Last six weeks")
            } footer: {
                Text("Compares the six weeks before today with everything earlier.")
            }

            if !checks.isEmpty {
                Section {
                    ForEach(checks, id: \.entry.id) { check in
                        let parts = [check.entry.topWeight.map(Fmt.pounds), check.entry.feel?.label.lowercased()]
                            .compactMap { $0 }
                        LabeledContent {
                            Text(parts.isEmpty ? "Not rated" : parts.joined(separator: ", "))
                        } label: {
                            Text(check.date.formatted(date: .abbreviated, time: .omitted))
                            Text(check.entry.exercise.capitalizedSentence)
                        }
                    }
                } header: {
                    SectionTitle("Bar speed")
                } footer: {
                    Text("With little max strength work, how the bar moves on these singles is the read on your strength.")
                }
            }

            if let week = program.currentWeekModel {
                if let decision = week.decision {
                    Section {
                        Text(decision).font(.subheadline)
                    } header: {
                        SectionTitle("What the program says")
                    }
                }
                Section {
                    ForEach(week.decisionOptions, id: \.self) { option in
                        Button {
                            program.jump(toWeek: option.goToWeek)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label).font(.headline).foregroundStyle(Palette.ink)
                                Text(option.detail).font(.subheadline).foregroundStyle(Palette.inkSoft)
                                Text("Go to week \(option.goToWeek)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.vaneBlue)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if week.decisionOptions.isEmpty {
                        Button("Start again at week 1") {
                            program.jump(toWeek: 1)
                            dismiss()
                        }
                    }
                } header: {
                    SectionTitle("Choose")
                }
            }
        }
        .navigationTitle("Decision time")
    }

    private func trend(_ title: String, before: Double?, now: Double?, format: (Double) -> String) -> some View {
        LabeledContent(title) {
            switch (before, now) {
            case let (before?, now?):
                let delta = now - before
                Text("\(format(before)) to \(format(now))")
                    .foregroundStyle(delta > 0 ? Palette.vaneBlue : Palette.ink)
            case let (nil, now?):
                Text("\(format(now)), nothing earlier to compare")
            default:
                Text("Not logged")
            }
        }
    }
}
