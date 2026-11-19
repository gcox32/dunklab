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
    /// The object's key in the bucket, once uploaded.
    var remoteKey: String?
    var uploadStateRaw: String = UploadState.local.rawValue

    var attempt: DunkAttempt?
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

    /// Deletes the clip and its files.
    static func delete(_ clip: Clip, from context: ModelContext) {
        let remote = clip.remoteKey
        Task { await ClipSync.shared.deleteRemote(key: remote) }
        try? FileManager.default.removeItem(at: clip.fileURL)
        try? FileManager.default.removeItem(at: clip.posterURL)
        context.delete(clip)
    }

    /// Clears out files whose clip is gone. Cheap: one directory listing.
    static func sweep(_ context: ModelContext) {
        let ids = ((try? context.fetch(FetchDescriptor<Clip>())) ?? []).map(\.id)
        ClipFiles.sweep(keeping: Set(ids))
    }
}
