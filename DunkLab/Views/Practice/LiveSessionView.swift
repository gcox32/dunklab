import SwiftData
import SwiftUI

/// The in-gym screen. Built for one thumb between attempts.
struct LiveSessionView: View {
    @Bindable var session: PracticeSession
    let athlete: Athlete
    /// Set when the presenter wants to delete the session itself after this screen closes.
    var onDiscard: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]

    @State private var loggingTouch = false
    @State private var ending = false
    @State private var discardOnExit = false
    /// The replay camera, while filming is on.
    @State private var filming: Filming?
    @AppStorage(Filming.keepSecondsKey) private var keepSeconds: Double = 10

    private var attempts: [DunkAttempt] { session.sortedAttempts }
    private var count: Int { attempts.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let filming {
                CameraPanel(filming: filming)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(.rect(cornerRadius: 14))
                    .padding(.top, 12)
            }
            Spacer(minLength: 12)
            counter
            Spacer(minLength: 12)
            if count >= session.attemptCap {
                Text("That's \(session.attemptCap). End here, or keep going only if every jump still feels fast.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.vaneRed)
                    .padding(.bottom, 12)
            }
            outcomeButtons
            footerButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.backboard)
        .sensoryFeedback(.impact, trigger: count)
        .sheet(isPresented: $loggingTouch) {
            TouchSheet(athlete: athlete, session: session)
        }
        .sheet(isPresented: $ending) {
            EndSessionSheet(session: session) { discard in
                if discard {
                    if let onDiscard { onDiscard() } else { discardOnExit = true }
                }
                dismiss()
            }
        }
        // Mirror the session on the lock screen while this screen is up.
        .onChange(of: LiveActivities.state(for: session), initial: true) {
            if !discardOnExit { Task { await LiveActivities.show(session) } }
        }        // Delete only once the screen is gone, so nothing renders a deleted session.
        .onDisappear {
            filming?.stop()
            LiveActivities.endPractice()
            if filming != nil { Task { await ClipSync.shared.syncPending(context) } }
            if discardOnExit {
                context.delete(session)
                try? context.save()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.focus)
                    .font(.system(size: 34, weight: .heavy).width(.compressed))
                    .foregroundStyle(Palette.ink)
                Spacer()
                TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                    Text(Duration.seconds(timeline.date.timeIntervalSince(session.startedAt)),
                         format: .time(pattern: .minuteSecond))
                        .font(.readout(.title3))
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            if !session.cue.isEmpty {
                Text(session.cue)
                    .font(.title3)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Menu {
                    Picker("Dunk", selection: $session.stage) {
                        ForEach(stages) { Text($0.name).tag($0.name) }
                    }
                } label: {
                    Label(session.stage, systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                filmControl
            }
            .padding(.top, 4)
        }
    }

    /// Turns the replay camera on, and once on, sets how much each tap keeps.
    @ViewBuilder private var filmControl: some View {
        if filming == nil {
            Button {
                let camera = Filming()
                filming = camera
                Task { await camera.start() }
            } label: {
                Label("Film", systemImage: "video")
                    .font(.subheadline.weight(.semibold))
            }
        } else {
            Menu {
                Picker("Each attempt keeps", selection: $keepSeconds) {
                    ForEach(Filming.keepChoices, id: \.self) { Text("Last \(Int($0)) seconds").tag($0) }
                }
                Button("Stop filming", systemImage: "video.slash") {
                    filming?.stop()
                    filming = nil
                }
            } label: {
                Label("Keeps \(Int(keepSeconds)) s", systemImage: "video.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.vaneRed)
            }
        }
    }

    private var counter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(count)")
                    .font(.system(size: 96, weight: .heavy).width(.compressed))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                Text("of \(session.attemptCap) attempts, \(session.makes) \(session.makes == 1 ? "make" : "makes")")
                    .font(.title3)
                    .foregroundStyle(Palette.inkSoft)
            }
            // Recent outcomes, newest last.
            HStack(spacing: 5) {
                ForEach(attempts.suffix(16)) { attempt in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(attempt.outcome))
                        .frame(width: 14, height: 22)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var outcomeButtons: some View {
        VStack(spacing: 10) {
            Button { record(.make) } label: { Text("Make").frame(maxWidth: .infinity, minHeight: 88) }
                .buttonStyle(OutcomeStyle(tint: Palette.vaneBlue))
            HStack(spacing: 10) {
                Button { record(.close) } label: { Text("Rimmed out").frame(maxWidth: .infinity, minHeight: 72) }
                    .buttonStyle(OutcomeStyle(tint: Palette.rim))
                Button { record(.miss) } label: { Text("Miss").frame(maxWidth: .infinity, minHeight: 72) }
                    .buttonStyle(OutcomeStyle(tint: Palette.inkSoft))
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Undo") {
                guard let last = attempts.last else { return }
                // A mis-tap's video goes with it.
                for clip in last.clips { ClipLibrary.delete(clip, from: context) }
                context.delete(last)
            }
            .disabled(attempts.isEmpty)
            Spacer()
            Button("Log a touch") { loggingTouch = true }
            Spacer()
            Button("End session") { ending = true }
                .fontWeight(.semibold)
        }
        .padding(.top, 16)
    }

    private func record(_ outcome: AttemptOutcome) {
        let attempt = DunkAttempt(stage: session.stage, outcome: outcome)
        context.insert(attempt)
        attempt.session = session
        if let filming, filming.isRunning {
            let stage = session.stage
            Task {
                guard let clip = try? await filming.keep(.attempt, seconds: keepSeconds, into: context) else { return }
                // Undone while it was being written.
                if attempt.isDeleted || attempt.modelContext == nil {
                    ClipLibrary.delete(clip, from: context)
                    return
                }
                clip.stage = stage
                clip.outcomeRaw = outcome.rawValue
                clip.attempt = attempt
                clip.session = attempt.session
            }
        }
    }

    private func color(_ outcome: AttemptOutcome) -> Color {
        switch outcome {
        case .make: Palette.vaneBlue
        case .close: Palette.rim
        case .miss: Palette.chalk
        }
    }
}

private struct OutcomeStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title, weight: .heavy).width(.compressed))
            .foregroundStyle(.white)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct EndSessionSheet: View {
    @Bindable var session: PracticeSession
    /// Called with `true` when the session should be thrown away.
    var onFinish: (_ discard: Bool) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @Query private var sessions: [PracticeSession]
    @State private var confirmDiscard = false

    private var stage: DunkStage? { stages.first { $0.name == session.stage } }

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Attempts", value: "\(session.attempts.count)")
                    LabeledContent("Makes", value: "\(session.makes)")
                    LabeledContent("Time", value: Fmt.minutes(Date.now.timeIntervalSince(session.startedAt) / 60))
                    if let best = session.bestTouch {
                        LabeledContent("Best touch", value: Fmt.feet(best))
                    }
                }
                Section {
                    TextField("What worked, and what to change next time", text: $session.reflection, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    SectionTitle("Reflect")
                }
                if let stage, let note = ownershipNote(for: stage) {
                    Section {
                        Text(note)
                    }
                }
                Section {
                    Button("Discard session", role: .destructive) { confirmDiscard = true }
                } footer: {
                    Text("For a session that isn't happening after all. Nothing from it is kept.")
                }
            }
            .confirmationDialog("Discard this session?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard session", role: .destructive) {
                    dismiss()
                    onFinish(true)
                }
            } message: {
                Text("Its attempts and touches won't be saved.")
            }
            .navigationTitle("End session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep going") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        session.finishedAt = .now
                        try? context.save()
                        dismiss()
                        // An empty session isn't worth keeping.
                        onFinish(session.attempts.isEmpty && session.touches.isEmpty)
                    }
                }
            }
        }
    }
}

extension EndSessionSheet {
    /// Where this session leaves the dunk, when it had makes on one not yet owned before it.
    fileprivate func ownershipNote(for stage: DunkStage) -> String? {
        let madeHere = session.attempts.contains { $0.stage == stage.name && $0.outcome == .make }
        guard madeHere, stage.ownedAt == nil else { return nil }
        let progress = DunkProgress(stages: stages, sessions: sessions)
        let count = progress.sessionsMade(stage)
        let target = DunkProgress.sessionsToOwn
        let name = stage.name.lowercased()
        switch count {
        case 1:
            return "First \(name) landed. Make it in \(target - 1) more sessions to own it."
        case target:
            let next = progress.goal.map { " Your goal moves to the \($0.name.lowercased())." } ?? ""
            return "Makes in \(target) sessions. You own the \(name).\(next)"
        case ..<target:
            return "Makes on the \(name) in \(count) of \(target) sessions."
        default:
            return nil
        }
    }
}


struct TouchSheet: View {
    let athlete: Athlete
    var session: PracticeSession?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TouchRecord.heightIn, order: .reverse) private var touches: [TouchRecord]
    @State private var value: Double = 0

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                TouchPicker(value: $value, rim: athlete.rimHeightIn)
                Spacer()
            }
            .navigationTitle("Touch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let touch = TouchRecord(date: session?.finishedAt ?? .now, heightIn: value)
                        context.insert(touch)
                        touch.session = session
                        dismiss()
                    }
                }
            }
            .onAppear {
                value = touches.first?.heightIn ?? athlete.rimHeightIn
            }
        }
        .presentationDetents([.medium])
    }
}

/// A past session. Everything is editable, and it can be resumed or deleted.
struct SessionDetail: View {
    @Bindable var session: PracticeSession
    let athlete: Athlete

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @State private var resuming: PracticeSession?
    @State private var addingTouch = false
    @State private var confirmDelete = false
    @State private var deleteOnExit = false

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        Form {
            if session.finishedAt == nil {
                Section {
                    Button("Resume session") { resuming = session }
                    Button("Mark as ended") { session.finishedAt = session.effectiveEnd }
                } footer: {
                    Text("This session was never ended. Its time counts only up to the last thing you logged.")
                }
            }

            Section {
                TextField("Focus", text: $session.focus)
                Picker("Dunk", selection: $session.stage) {
                    ForEach(stages) { Text($0.name).tag($0.name) }
                }
                TextField("Cue", text: $session.cue, axis: .vertical)
            }

            Section {
                DatePicker("Started", selection: startBinding)
                if session.finishedAt != nil {
                    Stepper(value: durationBinding, in: 0...300, step: 5) {
                        LabeledContent("Length", value: Fmt.minutes(session.minutes))
                    }
                }
            } header: {
                SectionTitle("When")
            } footer: {
                Text("The length counts toward your weekly play budget.")
            }

            Section {
                ForEach(AttemptOutcome.allCases, id: \.self) { outcome in
                    Stepper(value: countBinding(outcome), in: 0...200) {
                        LabeledContent(outcome.label, value: "\(count(outcome))")
                    }
                }
            } header: {
                SectionTitle("Attempts")
            }

            SessionClipsSection(session: session)

            Section {
                let touches = session.touches.sorted { $0.date < $1.date }
                ForEach(touches) { touch in
                    LabeledContent(touch.date.formatted(date: .omitted, time: .shortened)) {
                        Text(Fmt.feet(touch.heightIn)).font(.readout(.title3))
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(touches[i]) }
                }
                Button("Add a touch") { addingTouch = true }
            } header: {
                SectionTitle("Touches")
            }

            Section {
                TextField("What worked, and what to change next time", text: $session.reflection, axis: .vertical)
                    .lineLimit(2...8)
            } header: {
                SectionTitle("Reflection")
            }

            Section {
                Button("Delete session", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(session.focus)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                deleteOnExit = true
                dismiss()
            }
        } message: {
            Text("Its attempts and touches are deleted too.")
        }
        .sheet(isPresented: $addingTouch) {
            TouchSheet(athlete: athlete, session: session)
        }
        .fullScreenCover(item: $resuming, onDismiss: {
            if deleteOnExit { dismiss() }
        }) {
            LiveSessionView(session: $0, athlete: athlete) { deleteOnExit = true }
        }
        .onDisappear {
            if deleteOnExit {
                context.delete(session)
                try? context.save()
            }
        }
    }

    private func count(_ outcome: AttemptOutcome) -> Int {
        session.attempts.filter { $0.outcome == outcome }.count
    }

    /// Adds or removes attempts of one outcome to match a corrected count.
    private func countBinding(_ outcome: AttemptOutcome) -> Binding<Int> {
        Binding(
            get: { count(outcome) },
            set: { target in
                let current = session.sortedAttempts.filter { $0.outcome == outcome }
                if target > current.count {
                    for _ in current.count..<target {
                        let attempt = DunkAttempt(stage: session.stage, outcome: outcome)
                        attempt.at = session.effectiveEnd
                        context.insert(attempt)
                        attempt.session = session
                    }
                } else {
                    for attempt in current.suffix(current.count - target) { context.delete(attempt) }
                }
            })
    }

    /// Moving the start keeps the length the same.
    private var startBinding: Binding<Date> {
        Binding(
            get: { session.startedAt },
            set: { start in
                let length = session.finishedAt?.timeIntervalSince(session.startedAt)
                session.startedAt = start
                if let length { session.finishedAt = start.addingTimeInterval(length) }
            })
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { (session.minutes / 5).rounded() * 5 },
            set: { session.finishedAt = session.startedAt.addingTimeInterval($0 * 60) })
    }
}
