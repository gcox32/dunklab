import PhotosUI
import SwiftData
import SwiftUI

/// Pick a Slo-Mo clip and mark it. Used on the Body tab and on a workout's drop jumps.
struct TimeJumpButton: View {
    var title = "Time a jump from a Slo-Mo clip"
    /// The workout to attach the test to, if any.
    var log: WorkoutLog?
    /// The box height the workout calls for, if it says.
    var boxHeightIn: Double?

    @State private var pick: PhotosPickerItem?
    @State private var clip: SlowMoClip?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        PhotosPicker(selection: $pick, matching: .videos, photoLibrary: .shared()) {
            HStack {
                Label(title, systemImage: "slowmo")
                if loading { Spacer(); ProgressView() }
            }
        }
        .disabled(loading)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            Task { await open(item) }
        }
        .fullScreenCover(item: $clip) { JumpMarkerView(clip: $0, log: log, boxHeightIn: boxHeightIn) }
        .alert("Couldn't open the clip", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func open(_ item: PhotosPickerItem) async {
        loading = true
        defer { loading = false }
        do {
            clip = try await SlowMoLibrary.clip(forPickerItem: item.itemIdentifier)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One test in a list: its best rep's height, RSI and ground time.
struct JumpTestRow: View {
    let test: JumpTest
    var showDate = true

    var body: some View {
        LabeledContent {
            Text(summary).monospacedDigit()
        } label: {
            if showDate { Text(test.date.formatted(date: .abbreviated, time: .omitted)) }
            Text(test.kind.label + (test.boxHeightIn.map { ", \(Fmt.inches($0)) box" } ?? ""))
        }
    }

    private var summary: String {
        guard let best = test.best else { return "no rep counted" }
        return "\(Fmt.inches((best.heightIn * 4).rounded() / 4)), RSI \(Reactive.rsiText(best.rsi)), \(Reactive.ms(best.groundTime))"
    }
}

/// The rows a drop jumps entry gets in a workout: tests timed so far, and a way to add one.
struct ReactiveEntryRows: View {
    let entry: LoggedEntry
    let log: WorkoutLog

    var body: some View {
        ForEach(log.jumpTests.sorted { $0.date < $1.date }) { JumpTestRow(test: $0, showDate: false) }
        TimeJumpButton(title: log.jumpTests.isEmpty ? "Time a rep from a Slo-Mo clip" : "Time another clip",
                       log: log, boxHeightIn: Reactive.boxHeightIn(fromDetails: entry.details))
    }
}
