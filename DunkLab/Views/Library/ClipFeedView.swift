import AVFoundation
import SwiftData
import SwiftUI

/// The library one clip at a time, filling the screen: swipe up for the next.
/// Only the clip in view plays, looping. Details are one tap away.
struct ClipFeedView: View {
    let filter: ClipLibraryView.Filter

    @Query(sort: \Clip.recordedAt, order: .reverse) private var clips: [Clip]
    @State private var current: UUID?
    @State private var speed: Float = 1

    init(filter: ClipLibraryView.Filter, startingAt start: UUID?) {
        self.filter = filter
        _current = State(initialValue: start)
    }

    private var shown: [Clip] { clips.filter { !$0.isDeleted && filter.includes($0) } }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { clip in
                        ClipFeedPage(clip: clip, isActive: current == clip.id, speed: $speed,
                                     insets: geo.safeAreaInsets)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(clip.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
        }
        .background(.black)
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "film.stack")
                    .foregroundStyle(.white)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    speed = Self.speeds.first { $0 < speed } ?? Self.speeds[0]
                } label: {
                    Text(Self.speedLabel(speed)).font(.body.monospacedDigit().weight(.semibold))
                }
                .accessibilityLabel("Speed \(Self.speedLabel(speed))")
            }
        }
        .onAppear {
            if current == nil { current = shown.first?.id }
        }
    }

    /// Real time down to an eighth, as on the clip's own screen. Each tap goes one slower.
    static let speeds: [Float] = [1, 0.5, 0.25, 0.125]

    static func speedLabel(_ speed: Float) -> String {
        switch speed {
        case 0.5: "½×"
        case 0.25: "¼×"
        case 0.125: "⅛×"
        default: "1×"
        }
    }
}

/// One clip, full screen, with what it was over a fade at the bottom.
private struct ClipFeedPage: View {
    @Bindable var clip: Clip
    let isActive: Bool
    @Binding var speed: Float
    let insets: EdgeInsets

    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var paused = false
    @State private var ready = false
    private var sync: ClipSync { ClipSync.shared }

    var body: some View {
        ZStack {
            Color.black
            if let poster, !ready {
                Image(uiImage: poster).resizable().scaledToFit()
            }
            if let player {
                PlayerLayerView(player: player, ready: $ready)
            }
            if paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { paused.toggle() }
        .overlay(alignment: .bottom) { info }
        .task(id: "\(clip.id) \(clip.posterVersion)") {
            let url = clip.posterURL
            poster = await Task.detached { UIImage(contentsOfFile: url.path) }.value
        }
        .onAppear(perform: load)
        .onDisappear {
            player?.pause()
            player = nil
            ready = false
        }
        .onChange(of: isActive) { _, active in
            if active {
                paused = false
                if clip.hasLocalFile { clip.lastUsedAt = .now }
            }
            apply()
        }
        .onChange(of: paused) { apply() }
        .onChange(of: speed) { apply() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            player?.seek(to: .zero)
            apply()
        }
    }

    private func load() {
        guard player == nil else { return }
        // The phone copy if there is one, else straight from the bucket.
        guard let url = clip.hasLocalFile ? clip.fileURL : sync.streamURL(for: clip) else { return }
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.actionAtItemEnd = .none
        self.player = player
        if isActive, clip.hasLocalFile { clip.lastUsedAt = .now }
        apply()
    }

    private func apply() {
        guard let player else { return }
        player.defaultRate = speed
        if isActive && !paused {
            player.rate = speed
        } else {
            player.pause()
        }
    }

    private var info: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let color = outcomeColor {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 18)
                    }
                    Text(title).font(.readout(.title))
                }
                if !detail.isEmpty {
                    Text(detail).font(.subheadline.weight(.semibold))
                }
                Text(clip.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                if !clip.caption.isEmpty {
                    Text(clip.caption).font(.subheadline).lineLimit(3).padding(.top, 2)
                }
                if player == nil && !clip.hasLocalFile {
                    Text("In the cloud. Add your key in Clip storage to watch it.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                Button {
                    clip.isFavorite.toggle()
                    Task { await sync.refreshManifest(clip) }
                } label: {
                    Image(systemName: clip.isFavorite ? "heart.fill" : "heart")
                }
                .accessibilityLabel(clip.isFavorite ? "Remove from Favorites" : "Favorite")
                NavigationLink { ClipDetailView(clip: clip) } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Details")
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .padding(.horizontal, 16)
        .padding(.top, 72)
        .padding(.bottom, insets.bottom + 16)
        .background {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black.opacity(0.45), location: 0.4),
                                   .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var title: String {
        switch clip.kind {
        case .attempt: clip.outcome?.label ?? "Attempt"
        case .jumpTest:
            if let best = clip.jumpTest?.best { "RSI \(Reactive.rsiText(best.rsi))" } else { "Jump test" }
        case .other: "Clip"
        }
    }

    /// The dunk for an attempt, the test for a jump test.
    private var detail: String {
        switch clip.kind {
        case .attempt, .other: clip.stage
        case .jumpTest: clip.jumpTest == nil ? "" : "Jump test"
        }
    }

    private var outcomeColor: Color? {
        switch clip.outcome {
        case .make: Palette.vaneBlue
        case .close: Palette.rim
        case .miss, nil: nil
        }
    }
}

/// An AVPlayerLayer showing the whole frame, letterboxed. Reports when the
/// first frame is up so the poster can step aside.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var ready: Bool

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        context.coordinator.observe(view.playerLayer) { ready = $0 }
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observation: NSKeyValueObservation?

        func observe(_ layer: AVPlayerLayer, _ report: @escaping @MainActor (Bool) -> Void) {
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let isReady = layer.isReadyForDisplay
                Task { @MainActor in report(isReady) }
            }
        }
    }

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
