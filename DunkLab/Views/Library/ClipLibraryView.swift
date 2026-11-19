import PhotosUI
import SwiftData
import SwiftUI

/// Every clip, newest first: attempts filmed in practice and jump tests.
struct ClipLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Clip.recordedAt, order: .reverse) private var clips: [Clip]
    @State private var filter: Filter = .all
    @State private var filmingTest = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var importing: (done: Int, total: Int)?
    @State private var importNote: String?
    @State private var opened: Clip?
    @State private var deleting: Clip?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", makes = "Makes", attempts = "Attempts", tests = "Tests", favorites = "Favorites"
        var id: String { rawValue }

        func includes(_ clip: Clip) -> Bool {
            switch self {
            case .all: true
            case .makes: clip.kind == .attempt && clip.outcome == .make
            case .attempts: clip.kind == .attempt
            case .tests: clip.kind == .jumpTest
            case .favorites: clip.isFavorite
            }
        }
    }

    private var shown: [Clip] { clips.filter(filter.includes) }

    var body: some View {
        ScrollView {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { filter in
                    if filter == .favorites {
                        Image(systemName: "heart.fill").accessibilityLabel(filter.rawValue).tag(filter)
                    } else {
                        Text(filter.rawValue).tag(filter)
                    }
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let importing {
                HStack {
                    Text("Importing \(importing.done + 1) of \(importing.total)…")
                    Spacer()
                    ProgressView()
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if shown.isEmpty {
                ContentUnavailableView(
                    clips.isEmpty ? "No clips yet" : "Nothing here",
                    systemImage: "film.stack",
                    description: Text(clips.isEmpty
                        ? "Turn on Film in a practice session and every attempt you log keeps the seconds before it. Or film a jump test from here."
                        : "No clips match this filter."))
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 4)], spacing: 4) {
                    ForEach(shown) { clip in
                        NavigationLink { ClipDetailView(clip: clip) } label: { ClipTile(clip: clip) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(clip.isFavorite ? "Remove from Favorites" : "Favorite",
                                       systemImage: clip.isFavorite ? "heart.slash" : "heart") {
                                    clip.isFavorite.toggle()
                                    Task { await ClipSync.shared.refreshManifest(clip) }
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = clip }
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .background(Palette.backboard)
        .navigationTitle("Library")
        .toolbar {
            // One way in for new clips. Clip storage lives in Settings.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .videos, photoLibrary: .shared()) {
                        Label("Add from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { filmingTest = true } label: { Label("Film a jump test", systemImage: "video") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(importing != nil)
            }
        }
        .fullScreenCover(isPresented: $filmingTest) { FilmJumpTestView() }
        .navigationDestination(item: $opened) { ClipDetailView(clip: $0) }
        .confirmationDialog("Delete this clip?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { clip in
            Button("Delete clip", role: .destructive) { ClipLibrary.delete(clip, from: context) }
        } message: { clip in
            Text(clip.jumpTest != nil
                 ? "It's deleted from this phone and the cloud. The jump test measured on it stays."
                 : "It's deleted from this phone and the cloud.")
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            Task { await importVideos(items) }
        }
        .alert("Import", isPresented: Binding(get: { importNote != nil }, set: { if !$0 { importNote = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importNote ?? "")
        }
        .onAppear {
            ClipLibrary.sweep(context)
            Task { await ClipSync.shared.syncPending(context) }
        }
    }
}

extension ClipLibraryView {
    /// One video opens straight away for tagging; several land in the grid.
    fileprivate func importVideos(_ items: [PhotosPickerItem]) async {
        let result = await PhotoImport.run(items, into: context) { importing = ($0, $1) }
        importing = nil
        importNote = result.note(linkedTo: nil)
        if result.added.count == 1 { opened = result.added[0] }
    }
}

/// A clip's poster with what it was: the outcome, or the test's best RSI.
struct ClipTile: View {
    let clip: Clip
    @State private var poster: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Text(badge)
                    Spacer(minLength: 0)
                    if clip.isFavorite { Image(systemName: "heart.fill") }
                    switch clip.uploadState {
                    case .uploaded where !clip.hasLocalFile: Image(systemName: "icloud")
                    case .failed: Image(systemName: "exclamationmark.icloud")
                    default: EmptyView()
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .topLeading) {
                if let color = outcomeColor {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 16).padding(6)
                }
            }
            .task(id: clip.id) {
                let url = clip.posterURL
                poster = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(badge), \(clip.recordedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var badge: String {
        switch clip.kind {
        case .attempt: clip.outcome?.label ?? "Attempt"
        case .jumpTest:
            if let best = clip.jumpTest?.best { "RSI \(Reactive.rsiText(best.rsi))" } else { "Jump test" }
        case .other: clip.caption.isEmpty ? "Clip" : clip.caption
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
