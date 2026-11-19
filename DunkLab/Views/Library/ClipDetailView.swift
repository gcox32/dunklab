import AVKit
import SwiftData
import SwiftUI

/// One clip: play it slowed down, caption it, and see or make what was measured on it.
struct ClipDetailView: View {
    @Bindable var clip: Clip

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DunkStage.order) private var stages: [DunkStage]
    @State private var player = AVPlayer()
    @State private var speed: Float = 0.25
    @State private var marking: SlowMoClip?
    @State private var confirmDelete = false
    @State private var syncError: String?
    private var sync: ClipSync { ClipSync.shared }

    /// Real time down to an eighth: at 240 fps an eighth still shows every frame.
    private let speeds: [(Float, String)] = [(1, "1×"), (0.5, "½×"), (0.25, "¼×"), (0.125, "⅛×")]

    var body: some View { screenBody.keyboardDoneButton() }

    @ViewBuilder private var screenBody: some View {
        Form {
            Section {
                if clip.hasLocalFile || streamURL != nil {
                    VideoPlayer(player: player)
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxHeight: 460)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                        .listRowInsets(EdgeInsets())
                    Picker("Speed", selection: $speed) {
                        ForEach(speeds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("This clip is in the cloud. Add your key in Clip storage to watch it.")
                        .foregroundStyle(Palette.inkSoft)
                }
            }

            Section {
                TextField("Caption", text: $clip.caption, axis: .vertical)
                    .lineLimit(1...4)
                Toggle("Favorite", isOn: $clip.isFavorite)
            }

            Section {
                NavigationLink { SessionLinkView(clip: clip) } label: {
                    LabeledContent("Session") {
                        Text(sessionText).multilineTextAlignment(.trailing)
                    }
                }
                if isStandalone {
                    editableFacts
                } else {
                    LabeledContent("Filmed", value: clip.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if clip.kind == .attempt {
                        if !clip.stage.isEmpty { LabeledContent("Dunk", value: clip.stage) }
                        if let outcome = clip.outcome { LabeledContent("Outcome", value: outcome.label) }
                    }
                }
                LabeledContent("Length", value: String(format: "%.1f s", clip.durationSec))
                if clip.nominalFPS > 0 {
                    LabeledContent("Frame rate", value: "\(Int(clip.nominalFPS.rounded())) fps")
                }
            } header: {
                SectionTitle("Details")
            }

            storageSection

            measuredSection

            Section {
                Button("Delete clip", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(clip.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if clip.hasLocalFile { clip.lastUsedAt = .now }
            guard player.currentItem == nil else { return }
            // The phone copy if there is one, else straight from the bucket.
            guard let url = clip.hasLocalFile ? clip.fileURL : streamURL else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.defaultRate = speed
        }
        .onDisappear {
            player.pause()
            // Captions and stars live in the bucket's manifest too.
            if !clip.isDeleted { Task { await sync.refreshManifest(clip) } }
        }
        .alert("Cloud storage", isPresented: Binding(get: { syncError != nil }, set: { if !$0 { syncError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(syncError ?? "")
        }
        .onChange(of: speed) { _, rate in
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
        .fullScreenCover(item: $marking) { JumpMarkerView(clip: $0, libraryClip: clip) }
        .confirmationDialog("Delete this clip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete clip", role: .destructive) {
                player.pause()
                ClipLibrary.delete(clip, from: context)
                dismiss()
            }
        } message: {
            Text(clip.jumpTest != nil ? "The jump test measured on it stays." : "The attempt it shows stays in its session.")
        }
    }

    @ViewBuilder private var measuredSection: some View {
        if let test = clip.jumpTest {
            Section {
                JumpTestRow(test: test)
                ForEach(Array(test.reps.enumerated()), id: \.element.id) { offset, rep in
                    VStack(alignment: .leading, spacing: 2) {
                        RepRow(number: offset + 1, rep: rep, kind: test.kind)
                        if let frames = frameText(rep) {
                            Text(frames).font(.caption.monospacedDigit()).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
            } header: {
                SectionTitle("Measured")
            }
        } else if clip.kind != .attempt && (clip.hasLocalFile || clip.remoteKey != nil) {
            Section {
                if sync.downloading.contains(clip.id) {
                    HStack { Text("Downloading to mark…"); Spacer(); ProgressView() }
                } else {
                    Button("Time this jump") { Task { await timeJump() } }
                }
            } footer: {
                Text(clip.hasLocalFile
                     ? "Step through it frame by frame and mark each rep for RSI and height."
                     : "Step through it frame by frame and mark each rep for RSI and height. It downloads first: marking needs every frame on the phone.")
            }
        }
    }

    @ViewBuilder private var storageSection: some View {
        Section {
            LabeledContent("Stored", value: storedText)
            switch clip.uploadState {
            case .local, .failed:
                if CloudConfig.hasKey && clip.hasLocalFile {
                    Button(clip.uploadState == .failed ? "Retry upload" : "Upload now") {
                        clip.uploadStateRaw = UploadState.local.rawValue
                        Task { await sync.syncPending(context) }
                    }
                    .disabled(sync.isSyncing)
                }
            case .uploading:
                EmptyView()
            case .uploaded:
                if clip.hasLocalFile {
                    Button("Remove from phone") {
                        sync.removeLocalCopy(clip)
                        // Carry on playing, now from the bucket.
                        player.replaceCurrentItem(with: streamURL.map { AVPlayerItem(url: $0) })
                        player.defaultRate = speed
                    }
                } else if sync.downloading.contains(clip.id) {
                    HStack { Text("Saving to phone…"); Spacer(); ProgressView() }
                } else {
                    Button("Save to phone", systemImage: "arrow.down.circle") {
                        Task { await download() }
                    }
                }
            }
        } header: {
            SectionTitle("Storage")
        } footer: {
            if clip.uploadState == .failed, let error = sync.lastError {
                Text(error)
            } else if clip.uploadState == .uploaded && clip.hasLocalFile {
                Text("Safe in the cloud. The phone copy (\(sizeText)) clears itself \(ClipSync.keepLocalDays) days after you last open it, unless it's a favorite.")
            } else if clip.uploadState == .uploaded {
                Text("Plays from the cloud. Save it to the phone to watch without signal.")
            }
        }
    }

    private var sizeText: String {
        let bytes = (try? clip.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var streamURL: URL? { sync.streamURL(for: clip) }

    private func timeJump() async {
        if !clip.hasLocalFile {
            await download()
            guard clip.hasLocalFile else { return }
        }
        marking = SlowMoClip(asset: AVURLAsset(url: clip.fileURL), recordedAt: clip.recordedAt)
    }

    private func download() async {
        do {
            try await sync.download(clip)
            player.replaceCurrentItem(with: AVPlayerItem(url: clip.fileURL))
            player.defaultRate = speed
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Not tied to a logged attempt or a saved test: an import, or a clip kept on its own.
    /// Those carry their own facts, so they can be set here.
    private var isStandalone: Bool { clip.attempt == nil && clip.jumpTest == nil }

    @ViewBuilder private var editableFacts: some View {
        DatePicker("Filmed", selection: $clip.recordedAt)
        Picker("What it is", selection: $clip.kindRaw) {
            ForEach(ClipKind.allCases) { Text($0.label).tag($0.rawValue) }
        }
        if clip.kind == .attempt {
            Picker("Outcome", selection: $clip.outcomeRaw) {
                Text("Not set").tag(String?.none)
                ForEach(AttemptOutcome.allCases, id: \.self) { Text($0.label).tag(Optional($0.rawValue)) }
            }
            Picker("Dunk", selection: $clip.stage) {
                Text("Not set").tag("")
                ForEach(stages) { Text($0.name).tag($0.name) }
                // A dunk since renamed or removed from the ladder still shows.
                if !clip.stage.isEmpty && !stages.contains(where: { $0.name == clip.stage }) {
                    Text(clip.stage).tag(clip.stage)
                }
            }
        }
    }

    /// The linked session and attempt, briefly.
    private var sessionText: String {
        guard let session = clip.session else { return "Not linked" }
        var text = session.startedAt.formatted(date: .abbreviated, time: .omitted)
        if let attempt = clip.attempt, let index = session.sortedAttempts.firstIndex(where: { $0 === attempt }) {
            text += ", attempt \(index + 1)"
        }
        return text
    }

    private func frameText(_ rep: JumpRep) -> String? {
        guard let c = rep.contactFrame, let t = rep.takeoffFrame, let l = rep.landingFrame else { return nil }
        return "Frames \(c + 1) → \(t + 1) → \(l + 1)"
    }

    private var aspect: CGFloat {
        guard clip.width > 0, clip.height > 0 else { return 9 / 16 }
        return CGFloat(clip.width) / CGFloat(clip.height)
    }

    private var storedText: String {
        switch clip.uploadState {
        case .local: "This phone only"
        case .uploading: "Uploading"
        case .uploaded: clip.hasLocalFile ? "Phone and cloud" : "Cloud"
        case .failed: "Upload failed"
        }
    }
}
