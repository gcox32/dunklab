import AVFoundation
import SwiftData
import SwiftUI

/// Film a jump test in the app: prop the phone, do the reps, keep the last
/// few seconds, then mark them frame by frame.
struct FilmJumpTestView: View {
    /// The workout to attach the test to, if any.
    var log: WorkoutLog?
    var boxHeightIn: Double?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var filming = Filming()
    @AppStorage("camera.testSeconds") private var seconds: Double = 10
    @State private var kept: Clip?
    @State private var marking: SlowMoClip?
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPanel(filming: filming)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Prop the phone side-on at hip height, 3 to 4 m away, with the ground in frame. Do your reps, then keep them.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Picker("Keep", selection: $seconds) {
                    ForEach(Filming.keepChoices, id: \.self) { Text("Last \(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                Button(filming.saving > 0 ? "Saving…" : "Keep the last \(Int(seconds)) seconds") {
                    Task { await keep() }
                }
                .buttonStyle(BigButtonStyle())
                .disabled(!filming.isRunning || filming.saving > 0)
            }
            .padding(16)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 18))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .topLeading) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.5))
                .padding(16)
        }
        .task { await filming.start() }
        .onDisappear { filming.stop() }
        .fullScreenCover(item: $marking, onDismiss: { dismiss() }) {
            JumpMarkerView(clip: $0, log: log, boxHeightIn: boxHeightIn, libraryClip: kept)
        }
        .alert("Couldn't keep the clip", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func keep() async {
        do {
            let clip = try await filming.keep(.jumpTest, seconds: seconds, into: context)
            try? context.save()
            kept = clip
            // Marking needs the phone's attention, not the camera's.
            filming.stop()
            marking = SlowMoClip(asset: AVURLAsset(url: clip.fileURL), recordedAt: clip.recordedAt)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Opens the camera to film a jump test in the app.
struct FilmJumpButton: View {
    var log: WorkoutLog?
    var boxHeightIn: Double?
    @State private var filming = false

    var body: some View {
        Button { filming = true } label: { Label("Film in Dunk Lab", systemImage: "video") }
            .fullScreenCover(isPresented: $filming) { FilmJumpTestView(log: log, boxHeightIn: boxHeightIn) }
    }
}
