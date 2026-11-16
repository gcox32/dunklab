import AudioToolbox
import Charts
import SwiftUI

/// Opens a motion-timed test, with the phone worn at the waist.
struct MotionJumpButton: View {
    var title = "Use Accelerometer"
    var log: WorkoutLog?
    var boxHeightIn: Double?

    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label(title, systemImage: "gyroscope")
        }
        .fullScreenCover(isPresented: $open) { MotionTestView(log: log, boxHeightIn: boxHeightIn) }
    }
}

/// Wear the phone snug at the waistband, jump, and the accelerometer times it.
/// No screen to watch mid-test, so the countdown and start are sounds.
struct MotionTestView: View {
    var log: WorkoutLog?
    var boxHeightIn: Double?

    private enum Phase: Equatable { case setup, countdown(Int), recording, review }

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.setup
    @State private var kind: JumpTestKind = .dropJump
    @State private var recorder = MotionRecorder()
    @State private var startedAt = Date.now
    @State private var trace: MotionTrace?
    @State private var reps: [JumpRep] = []
    @State private var excluded: Set<UUID> = []
    @State private var saving = false
    @State private var run: Task<Void, Never>?

    static let countdown = 5
    static let maxSeconds = 30.0

    private var kept: [JumpRep] { reps.filter { !excluded.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .setup: setup
                case .countdown(let n): countdownView(n)
                case .recording: recordingView
                case .review: review
                }
            }
            .background(Palette.backboard)
            .navigationTitle(kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopRecording(keep: false)
                        dismiss()
                    }
                }
                if phase == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { saving = true }.disabled(kept.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $saving) {
                SaveJumpTestSheet(kind: kind, reps: kept, recordedAt: startedAt, log: log,
                                  suggestedBoxIn: boxHeightIn, source: .motion, trace: trace?.data) { dismiss() }
            }
        }
        .onDisappear {
            run?.cancel()
            _ = recorder.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Test", selection: $kind) {
                ForEach(JumpTestKind.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Tuck the phone in your waistband at the side or back, snug so it can't bounce.")
                step(2, "After the countdown ticks, one long tone means it's recording.")
                step(3, instruction)
                step(4, "Take the phone out and tap Stop. It stops on its own after \(Int(Self.maxSeconds)) seconds.")
            }
            .font(.body)

            Spacer()

            if recorder.isAvailable {
                Button("Start") { begin() }.buttonStyle(BigButtonStyle())
            } else {
                Text("This device has no accelerometer.").foregroundStyle(Palette.vaneRed)
            }
        }
        .padding(20)
    }

    private var instruction: String {
        switch kind {
        case .dropJump: "Step off the box, rebound as fast and high as you can, and stand still for a second. Repeat up to 3 times."
        case .pogo: "Hop in place on stiff ankles, 5 to 10 hops, hands on hips."
        case .cmj: "Stand still for a second, then dip and jump. Stand still again between jumps."
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.readout(.title3)).foregroundStyle(Palette.vaneBlue)
            Text(text)
        }
    }

    // MARK: Countdown and recording

    private func countdownView(_ n: Int) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text("\(n)").font(.system(size: 120, weight: .heavy).width(.compressed)).monospacedDigit()
            Text("Tuck the phone in").foregroundStyle(Palette.inkSoft)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingView: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: startedAt, by: 0.5)) { timeline in
                VStack(spacing: 4) {
                    Text("Recording").font(.readout(.largeTitle))
                    Text("\(Int(timeline.date.timeIntervalSince(startedAt))) s")
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .padding(.top, 40)
            Spacer()
            Button { stopRecording(keep: true) } label: {
                Text("Stop").frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(BigButtonStyle(tint: Palette.vaneRed))
        }
        .padding(20)
    }

    private func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        run = Task {
            for n in stride(from: Self.countdown, through: 1, by: -1) {
                phase = .countdown(n)
                AudioServicesPlaySystemSound(1103) // tick
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            recorder.start()
            startedAt = .now
            phase = .recording
            AudioServicesPlaySystemSound(1005) // long tone: go
            try? await Task.sleep(for: .seconds(Self.maxSeconds))
            if Task.isCancelled { return }
            AudioServicesPlaySystemSound(1006)
            stopRecording(keep: true)
        }
    }

    private func stopRecording(keep: Bool) {
        // Only the countdown and recording have anything to stop.
        guard phase != .setup && phase != .review else { return }
        run?.cancel()
        let recorded = recorder.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        guard keep else { return }
        trace = recorded
        reps = MotionJumps.reps(in: recorded, kind: kind)
        excluded = []
        phase = .review
    }

    // MARK: Review

    private var review: some View {
        List {
            if let trace {
                Section {
                    TraceChart(trace: trace)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
                } footer: {
                    Text(String(format: "%.1f s at %.0f samples a second. Shaded spans are time in the air. Drag to scroll.",
                                trace.duration, trace.rateHz))
                }
            }

            Section {
                if reps.isEmpty {
                    Text("No \(kind.isRebound ? "rebounds" : "jumps") found. Check the phone was snug, then try again.")
                        .foregroundStyle(Palette.inkSoft)
                }
                ForEach(Array(reps.enumerated()), id: \.element.id) { offset, rep in
                    Button {
                        if excluded.contains(rep.id) { excluded.remove(rep.id) } else { excluded.insert(rep.id) }
                    } label: {
                        HStack {
                            RepRow(number: offset + 1, rep: rep, kind: kind)
                            Spacer()
                            Image(systemName: excluded.contains(rep.id) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(excluded.contains(rep.id) ? Palette.inkSoft : Palette.vaneBlue)
                        }
                    }
                    .tint(Palette.ink)
                }
                Button("Record again") {
                    trace = nil
                    reps = []
                    phase = .setup
                }
            } header: {
                SectionTitle(reps.count == 1 ? "1 rep found" : "\(reps.count) reps found")
            } footer: {
                Text("Tap a rep to leave it out, like a stumble or a step off the box that read as a jump.")
            }
        }
    }
}

/// The trace with flights shaded. One series, so no legend; the free-fall threshold is a dashed rule.
private struct TraceChart: View {
    let trace: MotionTrace
    private let flights: [MotionJumps.Flight]

    init(trace: MotionTrace) {
        self.trace = trace
        self.flights = MotionJumps.flights(in: trace)
    }

    var body: some View {
        Chart {
            ForEach(flights) { flight in
                RectangleMark(xStart: .value("Take off", flight.start), xEnd: .value("Land", flight.end))
                    .foregroundStyle(Palette.vaneBlue.opacity(0.15))
            }
            RuleMark(y: .value("Free fall", Double(MotionJumps.freeFallG)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Palette.inkSoft.opacity(0.6))
            ForEach(trace.g.indices, id: \.self) { i in
                LineMark(x: .value("Time", trace.times[i]), y: .value("g", Double(trace.g[i])))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(Palette.ink)
            }
        }
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("g")
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: min(6, max(trace.duration, 1)))
        .chartScrollPosition(initialX: max(0, (flights.first?.start ?? 0) - 1))
        .frame(height: 180)
    }
}
