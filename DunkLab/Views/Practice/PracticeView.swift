import Charts
import SwiftData
import SwiftUI

struct PracticeView: View {
    let athlete: Athlete

    @Environment(\.modelContext) private var context
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @Query(sort: \PracticeSession.startedAt, order: .reverse) private var sessions: [PracticeSession]
    @Query(sort: \TouchRecord.date) private var touches: [TouchRecord]

    @State private var settingUp = false
    @State private var pending: PracticeSession?
    @State private var live: PracticeSession?
    @State private var loggingTouch = false
    // Debug builds accept `-open library` to start on the library.
    @State private var showingLibrary = UserDefaults.standard.string(forKey: "open") == "library"

    private var progress: DunkProgress { DunkProgress(stages: stages, sessions: sessions) }
    private var goal: DunkStage? { progress.goal }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let week = Calendar.training.currentWeek()
                    let minutes = sessions.filter { week.contains($0.startedAt) }.reduce(0) { $0 + $1.minutes }
                    PlayBudgetBar(minutes: minutes, budget: Double(athlete.weeklyPlayMinutes))
                        .padding(.vertical, 4)
                    Button("Start a session") { settingUp = true }
                        .buttonStyle(BigButtonStyle())
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    let progress = progress
                    let goal = progress.goal
                    ForEach(stages) { stage in
                        stageRow(stage, progress: progress, isGoal: stage == goal)
                    }
                    NavigationLink("Edit the ladder") { LadderEditor(athlete: athlete) }
                } header: {
                    SectionTitle("Dunk ladder")
                } footer: {
                    Text("A make lands a dunk. Makes in \(DunkProgress.sessionsToOwn) separate sessions own it, and your goal is the first dunk you don't own. Swipe right to make a dunk your goal, or left to mark one you already own. Heights are rough guides for where your hand needs to be.")
                }

                Section {
                    if touches.count > 1 {
                        touchChart.frame(height: 160).padding(.vertical, 8)
                    }
                    if let best = touches.max(by: { $0.heightIn < $1.heightIn }) {
                        LabeledContent(best.isEstimate ? "Best, estimated" : "Best") {
                            Text(Fmt.feet(best.heightIn)).font(.readout(.title3))
                        }
                        LabeledContent("Vertical from standing reach") {
                            Text(Fmt.inches(best.heightIn - athlete.standingReachIn)).font(.readout(.title3))
                        }
                    }
                    Button("Log a touch") { loggingTouch = true }
                } header: {
                    SectionTitle("Touch")
                }

                if !sessions.isEmpty {
                    Section {
                        ForEach(sessions) { session in
                            NavigationLink {
                                SessionDetail(session: session, athlete: athlete)
                            } label: {
                                sessionRow(session)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(sessions[i]) }
                        }
                    } header: {
                        SectionTitle("Sessions")
                    }
                }
            }
            .navigationTitle("Practice")
            .libraryButton()
            .navigationDestination(isPresented: $showingLibrary) { ClipLibraryView() }
            .sheet(isPresented: $settingUp, onDismiss: {
                live = pending
                pending = nil
            }) {
                PracticeSetupView(goal: goal) { pending = $0 }
            }
            .fullScreenCover(item: $live) { LiveSessionView(session: $0, athlete: athlete) }
            #if DEBUG
            .task {
                if UserDefaults.standard.string(forKey: "open") == "session" {
                    let session = PracticeSession(focus: "Penultimate step", cue: "Long, low second-to-last step. Hips drop, then explode.", stage: goal?.name ?? "", attemptCap: 20)
                    context.insert(session)
                    for outcome in [AttemptOutcome.miss, .close, .make, .make, .miss, .make, .close] {
                        let attempt = DunkAttempt(stage: session.stage, outcome: outcome)
                        context.insert(attempt)
                        attempt.session = session
                    }
                    live = session
                }
            }
            #endif
            .sheet(isPresented: $loggingTouch) {
                TouchSheet(athlete: athlete, session: nil)
            }
        }
    }

    private func stageRow(_ stage: DunkStage, progress: DunkProgress, isGoal: Bool) -> some View {
        let line = athlete.line(for: stage)
        let owned = progress.isOwned(stage)
        let made = progress.sessionsMade(stage)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.name).fontWeight(isGoal ? .semibold : .regular)
                Text("\(Fmt.feet(line)), \(Fmt.inches(stage.clearanceIn)) over the rim")
                    .font(.caption).foregroundStyle(Palette.inkSoft)
            }
            Spacer()
            if owned {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.vaneBlue)
                    .accessibilityLabel("Owned")
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    if isGoal {
                        Label("Goal", systemImage: "pin.fill")
                            .labelStyle(PinnedLabelStyle(pinned: stage.isGoalPinned))
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.vaneRed)
                    }
                    if progress.isLanded(stage) {
                        Text("Made in \(made) of \(DunkProgress.sessionsToOwn)")
                            .font(.caption).monospacedDigit().foregroundStyle(Palette.inkSoft)
                    }
                }
            }
        }
        .swipeActions(edge: .leading) {
            if !owned {
                Button(stage.isGoalPinned ? "Unpin" : "Make goal") {
                    DunkProgress.pin(stage, in: stages)
                }
                .tint(Palette.vaneRed)
            }
        }
        .swipeActions(edge: .trailing) {
            if !progress.isOwnedByPractice(stage) {
                Button(stage.ownedAt != nil ? "Not owned" : "Owned") {
                    stage.ownedAt = stage.ownedAt != nil ? nil : .now
                }
                .tint(stage.ownedAt != nil ? .gray : Palette.vaneBlue)
            }
        }
    }

    private var touchChart: some View {
        Chart {
            ForEach(touches) { touch in
                LineMark(x: .value("Date", touch.date), y: .value("Touch", touch.heightIn))
                    .foregroundStyle(Palette.vaneBlue)
                PointMark(x: .value("Date", touch.date), y: .value("Touch", touch.heightIn))
                    .foregroundStyle(touch.isEstimate ? Palette.inkSoft : Palette.vaneBlue)
            }
            if let goal {
                RuleMark(y: .value("Goal", athlete.line(for: goal)))
                    .foregroundStyle(Palette.vaneRed)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(goal.name).font(.caption2).foregroundStyle(Palette.vaneRed)
                    }
            }
            RuleMark(y: .value("Rim", athlete.rimHeightIn))
                .foregroundStyle(Palette.rim)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.feet(v)) } }
            }
        }
    }

    private func sessionRow(_ session: PracticeSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.focus)
            Text("\(session.startedAt.formatted(date: .abbreviated, time: .omitted)), \(session.makes) of \(session.attempts.count) on \(session.stage.lowercased())")
                .font(.caption).foregroundStyle(Palette.inkSoft)
            if session.finishedAt == nil {
                Text("Never ended")
                    .font(.caption).foregroundStyle(Palette.vaneRed)
            }
        }
    }
}

struct PracticeSetupView: View {
    var goal: DunkStage?
    var onStart: (PracticeSession) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PracticeFocus.order) private var focuses: [PracticeFocus]
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @AppStorage("practice.attemptCap") private var attemptCap = 20

    @State private var focus: PracticeFocus?
    @State private var cue = ""
    @State private var stage = ""

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(focuses) { item in
                        Button {
                            focus = item
                            cue = item.cue
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).foregroundStyle(Palette.ink)
                                    Text(item.cue).font(.caption).foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                                if focus == item {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.vaneBlue)
                                }
                            }
                        }
                    }
                    NavigationLink("Edit focuses") { FocusEditor() }
                } header: {
                    SectionTitle("One focus")
                } footer: {
                    Text("Pick one thing to work on. Every attempt is a rep of that.")
                }

                if focus != nil {
                    Section {
                        TextField("Cue", text: $cue, axis: .vertical)
                    } header: {
                        SectionTitle("Your cue")
                    } footer: {
                        Text("Stays on screen the whole session. Make it yours.")
                    }
                }

                Section {
                    Picker("Dunk", selection: $stage) {
                        ForEach(stages) { Text($0.name).tag($0.name) }
                    }
                    Stepper("Stop after \(attemptCap) attempts", value: $attemptCap, in: 5...50, step: 5)
                } header: {
                    SectionTitle("The work")
                } footer: {
                    Text("Tired jumps teach slow jumps. Rest fully between attempts and stop when the quality drops.")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start).disabled(focus == nil)
                }
            }
            .onAppear {
                if stage.isEmpty { stage = goal?.name ?? stages.first?.name ?? "" }
            }
        }
    }

    private func start() {
        guard let focus else { return }
        let session = PracticeSession(focus: focus.name, cue: cue, stage: stage, attemptCap: attemptCap)
        context.insert(session)
        // Save before presenting, so its ID is permanent before the live screen is up.
        try? context.save()
        onStart(session)
        dismiss()
    }
}

/// Shows the pin only when the athlete chose the goal, rather than the ladder.
private struct PinnedLabelStyle: LabelStyle {
    var pinned: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            if pinned { configuration.icon.imageScale(.small) }
            configuration.title
        }
    }
}
