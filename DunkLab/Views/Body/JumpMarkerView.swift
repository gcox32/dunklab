import AVFoundation
import SwiftData
import SwiftUI

/// Step through a Slo-Mo clip frame by frame and tap the moments of each rep:
/// touch (or start), take off, land. Built for a thumb: the next moment to mark
/// is always the one big button.
struct JumpMarkerView: View {
    let clip: SlowMoClip
    var log: WorkoutLog?
    var boxHeightIn: Double?

    @Environment(\.dismiss) private var dismiss
    @State private var stepper = FrameStepper()
    @State private var kind: JumpTestKind = .dropJump
    @State private var marks: [Double] = []
    @State private var reps: [JumpRep] = []
    @State private var loadError: String?
    @State private var saving = false

    private var nextLabel: String {
        switch marks.count {
        case 0: kind.startLabel
        case 1: "Take off"
        default: "Land"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PlayerLayerView(player: stepper.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .overlay {
                        if let loadError {
                            Text(loadError).foregroundStyle(.white).padding()
                        } else if stepper.frames.isEmpty {
                            ProgressView().tint(.white)
                        }
                    }

                panel
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Palette.backboard)
            }
            .navigationTitle(kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saving = true }.disabled(reps.isEmpty)
                }
            }
            .sheet(isPresented: $saving) {
                SaveJumpTestSheet(kind: kind, reps: reps, recordedAt: clip.recordedAt,
                                  log: log, suggestedBoxIn: boxHeightIn) { dismiss() }
            }
        }
        .sensoryFeedback(.impact, trigger: marks.count)
        .task {
            do {
                try await stepper.load(clip)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if marks.isEmpty && reps.isEmpty {
                Picker("Test", selection: $kind) {
                    ForEach(JumpTestKind.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            scrubber

            currentRep

            if !reps.isEmpty { repList }

            Button { mark() } label: { Text(nextLabel) }
                .buttonStyle(BigButtonStyle())
                .disabled(stepper.frames.isEmpty)

            HStack {
                Button("Undo") { undo() }
                    .disabled(marks.isEmpty && reps.isEmpty)
                Spacer()
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                stepButton(-10, "backward.fill", "Back 10 frames")
                stepButton(-1, "backward.frame.fill", "Back 1 frame")
                Slider(value: Binding(
                    get: { Double(stepper.index) },
                    set: { stepper.show(Int($0.rounded())) }
                ), in: 0...Double(max(1, stepper.frames.count - 1)))
                stepButton(1, "forward.frame.fill", "Forward 1 frame")
                stepButton(10, "forward.fill", "Forward 10 frames")
            }
            Text(stepper.frames.isEmpty ? " " :
                    String(format: "%.3f s · frame %d of %d", stepper.elapsed, stepper.index + 1, stepper.frames.count))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Palette.inkSoft)
        }
    }

    private func stepButton(_ delta: Int, _ icon: String, _ label: String) -> some View {
        Button { stepper.show(stepper.index + delta) } label: {
            Image(systemName: icon).frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .disabled(stepper.frames.isEmpty)
    }

    /// The rep being marked: what's known so far.
    @ViewBuilder private var currentRep: some View {
        if marks.count >= 2 {
            let ground = marks[1] - marks[0]
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Rep \(reps.count + 1)").font(.readout(.title3))
                Text("\(kind.isRebound ? "Ground" : "Dip") \(Reactive.ms(ground))")
                    .foregroundStyle(kind.isRebound && ground > Reactive.maxReboundGroundTime ? Palette.vaneRed : Palette.ink)
                Text("Now find the landing").foregroundStyle(Palette.inkSoft)
            }
            .font(.subheadline)
        } else if marks.count == 1 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Rep \(reps.count + 1)").font(.readout(.title3))
                Text("Now find the last frame on the ground").font(.subheadline).foregroundStyle(Palette.inkSoft)
            }
        }
    }

    private var repList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(reps.enumerated()).suffix(3), id: \.element.id) { offset, rep in
                RepRow(number: offset + 1, rep: rep, kind: kind)
            }
        }
    }

    private var hint: String {
        switch marks.count {
        case 0: kind == .cmj ? "Mark the first frame of the dip." : "Mark the first frame a foot touches."
        case 1: "Mark the last frame on the ground."
        default: "Mark the first frame a foot touches again."
        }
    }

    private func mark() {
        let now = stepper.seconds
        guard marks.last.map({ now > $0 }) ?? true else { return }
        marks.append(now)
        if marks.count == 3 {
            reps.append(JumpRep(contact: marks[0], takeoff: marks[1], landing: marks[2]))
            // Pogo hops chain: this landing is the next hop's touch.
            marks = kind == .pogo ? [now] : []
            if kind == .pogo { stepper.jump(by: 0.18) }
        } else {
            // Skip ahead to about where the next moment usually is.
            stepper.jump(by: marks.count == 1 ? (kind == .cmj ? 0.35 : 0.18) : 0.4)
        }
    }

    private func undo() {
        let chained = kind == .pogo && marks.count == 1 && !reps.isEmpty
        if marks.isEmpty || chained, let last = reps.popLast() {
            marks = [last.contact, last.takeoff]
            stepper.show(time: last.landing)
        } else if let last = marks.popLast() {
            stepper.show(time: last)
        }
    }
}

private struct RepRow: View {
    let number: Int
    let rep: JumpRep
    let kind: JumpTestKind

    var body: some View {
        let counts = Reactive.counts(rep, kind: kind)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.readout(.body)).frame(width: 18, alignment: .leading)
            Text(Fmt.inches((rep.heightIn * 4).rounded() / 4)).font(.readout(.title3))
            Text("RSI \(Reactive.rsiText(rep.rsi))").monospacedDigit()
            Text("\(Reactive.ms(rep.groundTime)) on the ground").foregroundStyle(Palette.inkSoft)
        }
        .font(.subheadline)
        .opacity(counts ? 1 : 0.5)
        .overlay(alignment: .trailing) {
            if !counts { Text("too slow").font(.caption).foregroundStyle(Palette.vaneRed) }
        }
    }
}

/// Holds the clip's frame times and seeks the player to exactly one of them.
@Observable final class FrameStepper {
    let player = AVPlayer()
    private(set) var frames: [FrameTime] = []
    private(set) var index = 0
    private var seeking = false

    var seconds: Double { frames.indices.contains(index) ? frames[index].seconds : 0 }
    var elapsed: Double { seconds - (frames.first?.seconds ?? 0) }

    func load(_ clip: SlowMoClip) async throws {
        frames = try await SlowMoLibrary.frameTimes(of: clip)
        player.replaceCurrentItem(with: AVPlayerItem(asset: clip.asset))
        show(0)
    }

    func show(_ newIndex: Int) {
        guard !frames.isEmpty else { return }
        index = min(max(newIndex, 0), frames.count - 1)
        guard !seeking else { return }
        seeking = true
        Task { await seekUntilCaughtUp() }
    }

    /// The frame nearest a time, in the clip's seconds.
    func show(time: Double) {
        show(nearestIndex(to: time))
    }

    func jump(by seconds: Double) {
        show(time: self.seconds + seconds)
    }

    private func nearestIndex(to time: Double) -> Int {
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].seconds < time { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(frames[low - 1].seconds - time) < abs(frames[low].seconds - time) { return low - 1 }
        return low
    }

    /// Scrubbing asks for frames faster than seeks finish, so only the latest one is chased.
    private func seekUntilCaughtUp() async {
        while true {
            let target = index
            await player.seek(to: frames[target].time, toleranceBefore: .zero, toleranceAfter: .zero)
            if target == index { break }
        }
        seeking = false
    }
}

/// The player's picture, with no controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}
}

/// Box height and date, then save.
struct SaveJumpTestSheet: View {
    let kind: JumpTestKind
    let reps: [JumpRep]
    let recordedAt: Date?
    var log: WorkoutLog?
    var suggestedBoxIn: Double?
    var onSaved: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \JumpTest.date, order: .reverse) private var tests: [JumpTest]
    @State private var boxHeight: Double?
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let best = Reactive.best(of: reps, kind: kind) {
                        LabeledContent("Best rep", value: "\(Fmt.inches((best.heightIn * 4).rounded() / 4)), RSI \(Reactive.rsiText(best.rsi))")
                        LabeledContent(kind.isRebound ? "Ground time" : "Time to take off", value: Reactive.ms(best.groundTime))
                    } else {
                        Text("No rep counts: each spent over \(Reactive.ms(Reactive.maxReboundGroundTime)) on the ground. It's saved anyway, but the best stays empty.")
                            .foregroundStyle(Palette.inkSoft)
                    }
                    LabeledContent("Reps marked", value: "\(reps.count)")
                }
                Section {
                    if kind == .dropJump {
                        MeasureField("Box height", value: $boxHeight, unit: "in")
                    }
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle(kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let test = JumpTest(date: date, kind: kind,
                                            boxHeightIn: kind == .dropJump ? boxHeight : nil, reps: reps)
                        context.insert(test)
                        test.log = log
                        try? context.save()
                        dismiss()
                        onSaved()
                    }
                }
            }
            .onAppear {
                date = recordedAt ?? .now
                // The workout's box, else the same box as last time, else about 30 cm.
                boxHeight = suggestedBoxIn ?? tests.first { $0.kind == .dropJump }?.boxHeightIn ?? 12
            }
        }
        .presentationDetents([.medium])
    }
}
