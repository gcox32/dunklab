import PhotosUI
import SwiftData
import SwiftUI

/// Links a clip to the practice session it's from and, if you like, the logged
/// attempt it shows. Only links: nothing about the session or its attempts
/// changes, so the counts stay as they were logged.
struct SessionLinkView: View {
    @Bindable var clip: Clip

    @Query(sort: \PracticeSession.startedAt, order: .reverse) private var sessions: [PracticeSession]
    @State private var showingAll = false

    private var suggested: [PracticeSession] { ClipLibrary.suggestedSessions(for: clip, among: sessions) }

    var body: some View {
        Form {
            if let session = clip.session {
                Section {
                    SessionSummaryRow(session: session)
                    Button("Unlink from this session", role: .destructive) {
                        ClipLibrary.link(clip, to: nil, attempt: nil)
                    }
                } header: {
                    SectionTitle("Linked to")
                }
                attemptSection(session)
            }

            Section {
                if suggested.isEmpty {
                    Text("No session was running when this was filmed (\(clip.recordedAt.formatted(date: .abbreviated, time: .shortened))).")
                        .foregroundStyle(Palette.inkSoft)
                }
                ForEach(suggested) { sessionButton($0) }
            } header: {
                SectionTitle(clip.session == nil ? "Around when it was filmed" : "Or another session")
            }

            Section {
                if showingAll {
                    ForEach(sessions.filter { !suggested.contains($0) }) { sessionButton($0) }
                } else {
                    Button("Show all \(sessions.count) sessions") { showingAll = true }
                }
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sessionButton(_ session: PracticeSession) -> some View {
        Button {
            // The session only: the attempt is the athlete's call (the nearest is labelled).
            ClipLibrary.link(clip, to: session, attempt: nil)
        } label: {
            HStack {
                SessionSummaryRow(session: session)
                Spacer()
                if clip.session == session {
                    Image(systemName: "checkmark").foregroundStyle(Palette.vaneBlue)
                }
            }
        }
        .tint(Palette.ink)
    }

    private func attemptSection(_ session: PracticeSession) -> some View {
        let attempts = session.sortedAttempts
        let suggestion = ClipLibrary.suggestedAttempt(for: clip, in: session)
        return Section {
            Button {
                ClipLibrary.link(clip, to: session, attempt: nil)
            } label: {
                HStack {
                    Text("Session only, no attempt")
                    Spacer()
                    if clip.attempt == nil { Image(systemName: "checkmark").foregroundStyle(Palette.vaneBlue) }
                }
            }
            .tint(Palette.ink)
            ForEach(Array(attempts.enumerated()), id: \.element.id) { index, attempt in
                Button {
                    ClipLibrary.link(clip, to: session, attempt: attempt)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.readout(.body)).monospacedDigit().frame(width: 26, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2).fill(color(attempt.outcome)).frame(width: 8, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attempt.outcome.label)
                            Text(attempt.at.formatted(date: .omitted, time: .standard)
                                 + (attempt == suggestion ? " · closest in time" : ""))
                                .font(.caption).foregroundStyle(Palette.inkSoft)
                        }
                        Spacer()
                        if attempt.clips.contains(where: { $0.id != clip.id }) {
                            Image(systemName: "video.fill").font(.caption).foregroundStyle(Palette.inkSoft)
                                .accessibilityLabel("Has another clip")
                        }
                        if clip.attempt == attempt {
                            Image(systemName: "checkmark").foregroundStyle(Palette.vaneBlue)
                        }
                    }
                }
                .tint(Palette.ink)
            }
        } header: {
            SectionTitle("Attempt")
        } footer: {
            Text(attempts.isEmpty
                 ? "No attempts were logged in this session."
                 : "Matching shows this video against the attempt as you logged it. The attempt and the session's counts don't change.")
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

/// A session in a list: focus, when, and how it went.
struct SessionSummaryRow: View {
    let session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.focus.isEmpty ? "Practice" : session.focus).foregroundStyle(Palette.ink)
            Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)), \(session.makes) of \(session.attempts.count) on \(session.stage.lowercased())")
                .font(.caption).foregroundStyle(Palette.inkSoft)
        }
    }
}

/// A session's videos as a strip, and a way to add more from Photos. Added
/// clips are linked to the session; matching each to an attempt is on its page.
struct SessionClipsSection: View {
    let session: PracticeSession

    @Environment(\.modelContext) private var context
    @State private var picks: [PhotosPickerItem] = []
    @State private var importing: (done: Int, total: Int)?
    @State private var note: String?

    private var clips: [Clip] { session.clips.sorted { $0.recordedAt < $1.recordedAt } }

    var body: some View {
        Section {
            if !clips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(clips) { clip in
                            NavigationLink { ClipDetailView(clip: clip) } label: {
                                ClipTile(clip: clip).frame(width: 84)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let importing {
                HStack {
                    Text("Importing \(importing.done + 1) of \(importing.total)…")
                    Spacer()
                    ProgressView()
                }
            } else {
                PhotosPicker(selection: $picks, maxSelectionCount: 30, matching: .videos, photoLibrary: .shared()) {
                    Label("Add from Photos", systemImage: "photo.on.rectangle")
                }
            }
        } header: {
            SectionTitle("Clips")
        } footer: {
            Text("Clips go with the session for reference. Match one to an attempt from its page; the counts above stay as you logged them.")
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            Task {
                let result = await PhotoImport.run(items, linkingTo: session, into: context) { importing = ($0, $1) }
                importing = nil
                note = result.note(linkedTo: session)
            }
        }
        .alert("Import", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(note ?? "")
        }
    }
}
