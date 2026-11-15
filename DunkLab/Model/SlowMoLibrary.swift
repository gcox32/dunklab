import AVFoundation
import Photos

/// A Slo-Mo clip as recorded, before Photos slows it down for playback.
/// AVAsset is immutable once made, so sharing it across tasks is safe.
nonisolated struct SlowMoClip: Identifiable, @unchecked Sendable {
    let id = UUID()
    let asset: AVAsset
    let recordedAt: Date?
}

/// One frame's presentation time, exact for seeking and in seconds for math.
nonisolated struct FrameTime: Sendable {
    let value: CMTimeValue
    let timescale: CMTimeScale

    var time: CMTime { CMTime(value: value, timescale: timescale) }
    var seconds: Double { time.seconds }
}

/// Gets Slo-Mo originals out of the photo library. The picker's own file is
/// the slowed-down playback version at 30 fps, which has lost the timing, so
/// this goes through PhotoKit for the original (see SlowMoProbe).
nonisolated enum SlowMoLibrary {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static func clip(forPickerItem id: String?) async throws -> SlowMoClip {
        guard let id else { throw Failure(errorDescription: "That clip didn't come from the photo library.") }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw Failure(errorDescription: "Dunk Lab needs photo access to read the original Slo-Mo clip. You can allow it in Settings.")
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw Failure(errorDescription: "Couldn't open that clip. With limited photo access, add it to the photos Dunk Lab can see.")
        }
        guard asset.mediaSubtypes.contains(.videoHighFrameRate) else {
            throw Failure(errorDescription: "That isn't a Slo-Mo clip. Film the jump in the Camera app's Slo-Mo mode.")
        }

        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let recordedAt = asset.creationDate
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: SlowMoClip(asset: avAsset, recordedAt: recordedAt))
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? Failure(errorDescription: "Photos didn't hand over the video."))
                }
            }
        }
    }

    /// Every frame's presentation time, in order, read without decoding.
    /// Slo-Mo files skip some frames, so stepping by these times shows each real frame once.
    static func frameTimes(of clip: SlowMoClip) async throws -> [FrameTime] {
        guard let track = try await clip.asset.loadTracks(withMediaType: .video).first else {
            throw Failure(errorDescription: "That clip has no video.")
        }
        let reader = try AVAssetReader(asset: clip.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? Failure(errorDescription: "Couldn't read the clip's frames.")
        }
        var times: [CMTime] = []
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(buffer))
            }
        }
        return times.sorted { CMTimeCompare($0, $1) < 0 }
            .map { FrameTime(value: $0.value, timescale: $0.timescale) }
    }
}
