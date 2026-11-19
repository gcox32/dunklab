import SwiftData
import UIKit

/// What's known about a clip, written beside its video in the bucket so the
/// bucket makes sense without the phone: what it shows and what was measured.
nonisolated struct ClipManifest: Codable, Sendable {
    struct Test: Codable, Sendable {
        var kind: String
        var boxHeightIn: Double?
        var reps: [JumpRep]
        var bestRSI: Double?
        var bestHeightIn: Double?
    }

    var id: UUID
    var recordedAt: Date
    var kind: String
    var caption: String
    var stage: String
    var outcome: String?
    var durationSec: Double
    var nominalFPS: Double
    var width: Int
    var height: Int
    var isFavorite: Bool
    var jumpTest: Test?
    var session: Session?
    var attempt: Attempt?

    struct Session: Codable, Sendable {
        var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var focus: String
        var cue: String
        var stage: String
    }

    /// The logged attempt the clip is matched to, as it was logged.
    struct Attempt: Codable, Sendable {
        var id: UUID
        /// 1-based, in the order logged.
        var number: Int
        var at: Date
        var outcome: String
        var stage: String
    }
}

/// Uploads clips to the bucket one at a time, and fetches or frees local copies.
/// Runs whenever the app is opened and after a clip is kept; does nothing until
/// a key has been entered.
@Observable final class ClipSync {
    static let shared = ClipSync()

    /// Days an uploaded clip's phone copy is kept after it was last used.
    static let keepLocalDays = 14

    private(set) var isSyncing = false
    private(set) var lastError: String?
    /// Clips being downloaded, so their screens can show it.
    private(set) var downloading: Set<UUID> = []

    /// Uploads every clip that's only on the phone. Safe to call often: a call
    /// while one is already running returns at once, and that run picks up new clips.
    func syncPending(_ context: ModelContext) async {
        guard !isSyncing, let client = CloudConfig.client else { return }
        isSyncing = true
        defer { isSyncing = false }
        lastError = nil

        // Only one run at a time, so anything marked uploading was cut off: start it again.
        let uploading = UploadState.uploading.rawValue
        for clip in (try? context.fetch(FetchDescriptor<Clip>(predicate: #Predicate { $0.uploadStateRaw == uploading }))) ?? [] {
            clip.uploadStateRaw = UploadState.local.rawValue
        }

        // Hold the app open long enough to finish the clip in hand if it's backgrounded.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Upload clips")
        defer { UIApplication.shared.endBackgroundTask(task) }

        while let clip = nextPending(context) {
            do {
                try await upload(clip, with: client)
            } catch {
                clip.uploadStateRaw = UploadState.failed.rawValue
                lastError = error.localizedDescription
                try? context.save()
                // One failure usually means all would fail (no network, bad key). Try again next time.
                return
            }
        }
        pruneLocalCopies(context)
    }

    /// Clears phone copies of uploaded clips not used in `keepLocalDays`. Starred
    /// clips stay, and so do jump tests not yet timed, since marking needs the file.
    func pruneLocalCopies(_ context: ModelContext, now: Date = .now) {
        let uploaded = UploadState.uploaded.rawValue
        let clips = (try? context.fetch(FetchDescriptor<Clip>(
            predicate: #Predicate { $0.uploadStateRaw == uploaded && $0.hasLocalFile && !$0.isFavorite }))) ?? []
        let cutoff = now.addingTimeInterval(-Double(Self.keepLocalDays) * 86_400)
        for clip in clips {
            if clip.kind == .jumpTest && clip.jumpTest == nil { continue }
            // Clips from before this clock existed start it now, rather than by filming date.
            guard let used = clip.lastUsedAt else {
                clip.lastUsedAt = now
                continue
            }
            if used < cutoff { removeLocalCopy(clip) }
        }
        try? context.save()
    }

    /// A link to play the clip from the bucket without saving it, good for an hour.
    func streamURL(for clip: Clip) -> URL? {
        guard let key = clip.remoteKey, let client = CloudConfig.client else { return nil }
        return client.presignedGET(key: key)
    }

    private func nextPending(_ context: ModelContext) -> Clip? {
        let local = UploadState.local.rawValue
        var descriptor = FetchDescriptor<Clip>(
            predicate: #Predicate { $0.uploadStateRaw == local && $0.hasLocalFile },
            sortBy: [SortDescriptor(\.recordedAt)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Tries clips that failed before, then everything else pending.
    func retryFailed(_ context: ModelContext) async {
        let failed = UploadState.failed.rawValue
        let clips = (try? context.fetch(FetchDescriptor<Clip>(predicate: #Predicate { $0.uploadStateRaw == failed }))) ?? []
        for clip in clips { clip.uploadStateRaw = UploadState.local.rawValue }
        await syncPending(context)
    }

    private func upload(_ clip: Clip, with client: S3Client) async throws {
        let key = Self.key(for: clip)
        clip.uploadStateRaw = UploadState.uploading.rawValue
        try await client.put(file: clip.fileURL, key: key + ".mov", contentType: "video/quicktime")
        try await client.put(data: Self.manifest(clip), key: key + ".json", contentType: "application/json")
        // Uploaded again (after a rotate) under a new key, if its date was changed: clear the old copy.
        if let old = clip.remoteKey, old != key + ".mov" { await deleteRemote(key: old) }
        clip.remoteKey = key + ".mov"
        clip.uploadStateRaw = UploadState.uploaded.rawValue
        try? clip.modelContext?.save()
    }

    /// Rewrites a clip's manifest after a caption or test changes. Quiet on failure.
    func refreshManifest(_ clip: Clip) async {
        // A deleted clip must not write its manifest back after the delete removed it.
        guard !deleted.contains(clip.id), !clip.isDeleted, clip.modelContext != nil,
              clip.uploadState == .uploaded, let client = CloudConfig.client, let video = clip.remoteKey else { return }
        let key = String(video.dropLast(".mov".count)) + ".json"
        let data = Self.manifest(clip)
        let id = clip.id
        let write = Task { _ = try? await client.put(data: data, key: key, contentType: "application/json") }
        manifestWrites[id] = write
        await write.value
        if manifestWrites[id] == write { manifestWrites[id] = nil }
    }

    /// Clips deleted this run, so nothing writes their manifest again.
    private var deleted: Set<UUID> = []
    /// Called the moment a clip is deleted, before anything else can run.
    func markDeleted(_ id: UUID) { deleted.insert(id) }

    /// Manifest uploads in flight, so a delete can wait them out rather than race them.
    private var manifestWrites: [UUID: Task<Void, Never>] = [:]

    /// Marks a clip deleted, then removes its video and manifest from the bucket
    /// once any manifest upload already under way has finished.
    func deleteRemote(id: UUID, key: String?) async {
        markDeleted(id)
        await manifestWrites[id]?.value
        await deleteRemote(key: key)
    }

    /// clips/2026/11/<id>: grouped by month so the bucket is browsable.
    static func key(for clip: Clip) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: clip.recordedAt)
        return CloudConfig.prefix + String(format: "%04d/%02d/", parts.year ?? 0, parts.month ?? 0) + clip.id.uuidString
    }

    static func manifest(_ clip: Clip) -> Data {
        let test = clip.jumpTest.map { test in
            ClipManifest.Test(kind: test.kindRaw, boxHeightIn: test.boxHeightIn, reps: test.reps,
                              bestRSI: test.best?.rsi, bestHeightIn: test.best?.heightIn)
        }
        let manifest = ClipManifest(
            id: clip.id, recordedAt: clip.recordedAt, kind: clip.kindRaw, caption: clip.caption,
            stage: clip.stage, outcome: clip.outcomeRaw, durationSec: clip.durationSec,
            nominalFPS: clip.nominalFPS, width: clip.width, height: clip.height,
            isFavorite: clip.isFavorite, jumpTest: test,
            session: clip.session.map { session in
                ClipManifest.Session(id: session.ensureSyncID(), startedAt: session.startedAt, finishedAt: session.finishedAt,
                                     focus: session.focus, cue: session.cue, stage: session.stage)
            },
            attempt: clip.attempt.map { attempt in
                let number = (attempt.session?.sortedAttempts.firstIndex { $0 === attempt } ?? 0) + 1
                return ClipManifest.Attempt(id: attempt.ensureSyncID(), number: number, at: attempt.at,
                                            outcome: attempt.outcomeRaw, stage: attempt.stage)
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(manifest)) ?? Data()
    }

    // MARK: Phone copies

    /// Deletes the video from the phone once it's safely in the bucket. The poster stays.
    func removeLocalCopy(_ clip: Clip) {
        guard clip.uploadState == .uploaded, clip.remoteKey != nil else { return }
        try? FileManager.default.removeItem(at: clip.fileURL)
        clip.hasLocalFile = false
    }

    func download(_ clip: Clip) async throws {
        guard let key = clip.remoteKey else { return }
        guard let client = CloudConfig.client else {
            throw S3Client.Failure(errorDescription: "Add your cloud key in Clip storage first.")
        }
        downloading.insert(clip.id)
        defer { downloading.remove(clip.id) }
        try await client.get(key: key, to: clip.fileURL)
        clip.hasLocalFile = true
        clip.lastUsedAt = .now
    }

    /// Deletes the clip's objects from the bucket. Quiet on failure: an orphan costs pennies.
    private func deleteRemote(key: String?) async {
        guard let key, let client = CloudConfig.client else { return }
        let stem = String(key.dropLast(".mov".count))
        try? await client.delete(key: stem + ".mov")
        try? await client.delete(key: stem + ".json")
    }
}
