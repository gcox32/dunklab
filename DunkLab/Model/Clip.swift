import AVFoundation
import SwiftData
import UIKit

/// What a clip shows. Attempts carry their outcome separately, so a make is an
/// attempt whose outcome is make.
nonisolated enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case attempt, jumpTest, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .attempt: "Attempt"
        case .jumpTest: "Jump test"
        case .other: "Clip"
        }
    }
}

/// Where a clip's file is, relative to the cloud copy.
nonisolated enum UploadState: String, Codable {
    /// Only on this phone.
    case local
    case uploading
    /// In the bucket. The local file may since have been cleared to save space.
    case uploaded
    case failed
}

/// One video in the library. The file lives in Application Support/Clips,
/// named after the clip's id. Times inside it are real time, not slowed down.
@Model final class Clip {
    var id: UUID = UUID()
    var recordedAt: Date = Date.now
    var kindRaw: String = ClipKind.other.rawValue
    var caption: String = ""
    var durationSec: Double = 0
    /// The rate it was filmed at: 240 or 120 for in-app recordings.
    var nominalFPS: Double = 0
    var width: Int = 0
    var height: Int = 0
    /// The dunk being worked on when it was filmed, kept even if the attempt goes.
    var stage: String = ""
    /// The attempt's outcome when it was filmed, kept even if the attempt goes.
    var outcomeRaw: String?
    var isFavorite: Bool = false
    /// The Photos video it was imported from, so it isn't imported twice.
    var sourceAssetID: String?
    /// When it was last kept, imported, downloaded or opened: the phone copy's
    /// clock for being cleared (see ClipSync.keepLocalDays).
    var lastUsedAt: Date?

    /// Whether the file is on this phone. False once it's been cleared after upload.
    var hasLocalFile: Bool = true
    /// Bumped when the poster is redrawn (after a rotate), so the grid reloads it.
    var posterVersion: Int = 0
    /// The object's key in the bucket, once uploaded.
    var remoteKey: String?
    var uploadStateRaw: String = UploadState.local.rawValue

    /// The logged attempt it shows, if matched to one. Matching never changes the attempt.
    var attempt: DunkAttempt?
    /// The practice session it's from. Set for every attempt clip, and for clips
    /// linked to a session without being matched to an attempt.
    var session: PracticeSession?
    var jumpTest: JumpTest?

    init(kind: ClipKind, recordedAt: Date, durationSec: Double, nominalFPS: Double, width: Int, height: Int) {
        self.kindRaw = kind.rawValue
        self.recordedAt = recordedAt
        self.durationSec = durationSec
        self.nominalFPS = nominalFPS
        self.width = width
        self.height = height
    }

    var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var outcome: AttemptOutcome? { outcomeRaw.flatMap(AttemptOutcome.init) }
    var uploadState: UploadState { UploadState(rawValue: uploadStateRaw) ?? .local }

    var fileURL: URL { ClipFiles.videoURL(for: id) }
    var posterURL: URL { ClipFiles.posterURL(for: id) }
}

/// The clip files on disk, and the work of moving a fresh recording into the library.
nonisolated enum ClipFiles {
    static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Clips", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func videoURL(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).mov") }
    static func posterURL(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).jpg") }

    struct Facts: Sendable {
        var duration: Double
        var fps: Double
        var width: Int
        var height: Int
    }

    /// Duration, frame rate and upright size, read from the file.
    static func facts(of url: URL) async throws -> Facts {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return Facts(duration: duration, fps: 0, width: 0, height: 0)
        }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let upright = size.applying(transform)
        return Facts(duration: duration, fps: Double(fps),
                     width: Int(abs(upright.width)), height: Int(abs(upright.height)))
    }

    /// A still from a moment in the clip, saved beside it for the grid.
    static func makePoster(for url: URL, at seconds: Double, to posterURL: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image,
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) else { return }
        try? data.write(to: posterURL, options: .atomic)
    }

    /// A copy of the video turned a quarter turn clockwise, written to the
    /// temporary directory. Only the orientation flag changes: every frame is
    /// copied as it was, so it's quick and loses nothing.
    @concurrent static func rotatedClockwise(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        let reader = try AVAssetReader(asset: asset)
        let url = URL.temporaryDirectory.appending(path: "rotated-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Index at the front, so it streams from the bucket without fetching the end first.
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = (try? await asset.load(.metadata)) ?? []

        var pumps: [Pump] = []
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            let (formats, transform, size) = try await track.load(.formatDescriptions, .preferredTransform, .naturalSize)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.transform = quarterTurn(after: transform, size: size)
            }
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            pumps.append(Pump(output: output, input: input))
        }
        guard pumps.contains(where: { $0.input.mediaType == .video }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { await pump.run() } }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// The upright transform a quarter turn clockwise from `transform`, with the
    /// picture moved back into view as the camera writes it.
    static func quarterTurn(after transform: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        let current = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        let turned = ((current + 90) % 360 + 360) % 360
        let (w, h) = (size.width, size.height)
        switch (turned + 45) / 90 % 4 {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }

    /// Copies one track's samples from the reader to the writer.
    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        private let queue = DispatchQueue(label: "clip.rotate")
        private var finished = false

        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.output = output
            self.input = input
        }

        func run() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                            input.markAsFinished()
                            // The ready handler can run again after the end; finish once.
                            if !finished {
                                finished = true
                                done.resume()
                            }
                            return
                        }
                    }
                }
            }
        }
    }

    /// Deletes files no clip points at: left by deleted clips or an interrupted save.
    static func sweep(keeping ids: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            if let id = UUID(uuidString: stem), ids.contains(id) { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

@MainActor
enum ClipLibrary {
    /// Moves a finished recording into the library and makes its clip.
    static func add(recordingAt source: URL, kind: ClipKind, recordedAt: Date,
                    into context: ModelContext) async throws -> Clip {
        let id = UUID()
        let destination = ClipFiles.videoURL(for: id)
        try FileManager.default.moveItem(at: source, to: destination)
        let facts = try await ClipFiles.facts(of: destination)
        // Most of a kept window is walking back; the jump is in the first half.
        await ClipFiles.makePoster(for: destination, at: facts.duration * 0.35, to: ClipFiles.posterURL(for: id))
        let clip = Clip(kind: kind, recordedAt: recordedAt, durationSec: facts.duration,
                        nominalFPS: facts.fps, width: facts.width, height: facts.height)
        clip.id = id
        clip.lastUsedAt = .now
        context.insert(clip)
        return clip
    }

    /// Copies a video, untouched, into the library: a Slo-Mo original from Photos.
    static func importOriginal(_ asset: AVAsset, kind: ClipKind, recordedAt: Date,
                               into context: ModelContext) async throws -> Clip {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = URL.temporaryDirectory.appending(path: "import-\(UUID().uuidString).mov")
        // Index at the front, so it streams from the bucket without fetching the end first.
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: url, as: .mov)
        return try await add(recordingAt: url, kind: kind, recordedAt: recordedAt, into: context)
    }

    /// Turns the clip a quarter turn clockwise: the phone copy, its poster, and,
    /// if it's in the bucket, the cloud copy, which is uploaded again over the old one.
    static func rotate(_ clip: Clip, in context: ModelContext) async throws {
        if !clip.hasLocalFile {
            try await ClipSync.shared.download(clip)
        }
        let rotated = try await ClipFiles.rotatedClockwise(clip.fileURL)
        _ = try FileManager.default.replaceItemAt(clip.fileURL, withItemAt: rotated)
        let facts = try await ClipFiles.facts(of: clip.fileURL)
        clip.width = facts.width
        clip.height = facts.height
        await ClipFiles.makePoster(for: clip.fileURL, at: facts.duration * 0.35, to: clip.posterURL)
        clip.posterVersion += 1
        clip.lastUsedAt = .now
        if clip.uploadState != .local {
            clip.uploadStateRaw = UploadState.local.rawValue
        }
        try? context.save()
        Task { await ClipSync.shared.syncPending(context) }
    }

    /// Deletes the clip and its files.
    static func delete(_ clip: Clip, from context: ModelContext) {
        let remote = clip.remoteKey
        let id = clip.id
        ClipSync.shared.markDeleted(id)
        Task { await ClipSync.shared.deleteRemote(id: id, key: remote) }
        try? FileManager.default.removeItem(at: clip.fileURL)
        try? FileManager.default.removeItem(at: clip.posterURL)
        context.delete(clip)
    }

    /// Attaches a clip to a session and, optionally, one of its logged attempts.
    /// Only links: the session's attempts and counts stay as they were logged.
    static func link(_ clip: Clip, to session: PracticeSession?, attempt: DunkAttempt?) {
        clip.session = session
        clip.attempt = attempt
        if let attempt {
            // The logged attempt is the truth about what happened.
            clip.kind = .attempt
            clip.outcomeRaw = attempt.outcomeRaw
            clip.stage = attempt.stage
        } else if let session, clip.stage.isEmpty {
            clip.stage = session.stage
        }
    }

    /// Sessions the clip was probably filmed in: those running at its time, give
    /// or take half an hour, nearest first.
    static func suggestedSessions(for clip: Clip, among sessions: [PracticeSession]) -> [PracticeSession] {
        let slack: TimeInterval = 30 * 60
        let time = clip.recordedAt
        return sessions
            .filter { $0.startedAt.addingTimeInterval(-slack) <= time && time <= $0.effectiveEnd.addingTimeInterval(slack) }
            .sorted { distance(time, $0) < distance(time, $1) }
    }

    private static func distance(_ time: Date, _ session: PracticeSession) -> TimeInterval {
        if time < session.startedAt { return session.startedAt.timeIntervalSince(time) }
        if time > session.effectiveEnd { return time.timeIntervalSince(session.effectiveEnd) }
        return 0
    }

    /// The logged attempt nearest the clip's end, among those with no video yet,
    /// within three minutes. Attempts are logged just after the jump, so the end
    /// of the clip is the best guess at when it was tapped.
    static func suggestedAttempt(for clip: Clip, in session: PracticeSession) -> DunkAttempt? {
        let end = clip.recordedAt.addingTimeInterval(clip.durationSec)
        return session.attempts
            .filter { $0.clips.isEmpty || $0.clips.contains { $0.id == clip.id } }
            .map { ($0, abs($0.at.timeIntervalSince(end))) }
            .filter { $0.1 <= 180 }
            .min { $0.1 < $1.1 }?.0
    }

    /// Clips filmed before the session link existed reach their session through
    /// their attempt. Gives them the direct link too. Cheap; runs at launch.
    static func linkSessionsFromAttempts(_ context: ModelContext) {
        for clip in (try? context.fetch(FetchDescriptor<Clip>())) ?? [] where clip.session == nil {
            if let session = clip.attempt?.session { clip.session = session }
        }
        try? context.save()
    }

    /// Clears out files whose clip is gone. Cheap: one directory listing.
    static func sweep(_ context: ModelContext) {
        let ids = ((try? context.fetch(FetchDescriptor<Clip>())) ?? []).map(\.id)
        ClipFiles.sweep(keeping: Set(ids))
    }
}
