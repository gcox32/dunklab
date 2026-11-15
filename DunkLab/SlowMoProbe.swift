#if DEBUG
import AVFoundation
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Answers one question before any RSI work: when a Slo-Mo clip comes in from
/// Photos, does the app get every 240 fps frame with real-time timestamps?
/// Tries two routes on the same clip:
///   A. PhotosPicker's file transfer with `.current` encoding (no permission needed).
///   B. PHImageManager's `.original` version (needs photo library access).
struct SlowMoProbeView: View {
    @State private var item: PhotosPickerItem?
    @State private var reports: [ProbeReport] = []
    @State private var working = false

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $item, matching: .videos,
                             preferredItemEncoding: .current, photoLibrary: .shared()) {
                    Label("Pick a Slo-Mo clip", systemImage: "slowmo")
                }
                if working { ProgressView("Reading frames…") }
            } footer: {
                Text("Film a few seconds in the Camera app's Slo-Mo mode at 240 fps, with a drop jump or a few hand claps. To see whether light causes gaps, probe one clip filmed indoors and one outside in daylight.")
            }

            ForEach(reports) { report in
                Section {
                    Text(report.verdict).font(.headline)
                    ForEach(report.rows, id: \.0) { LabeledContent($0.0, value: $0.1) }
                } header: {
                    SectionTitle(report.route)
                }
            }

            if !reports.isEmpty {
                Section {
                    Button("Copy report") {
                        UIPasteboard.general.string = reports.map(\.text).joined(separator: "\n\n")
                    }
                }
            }
        }
        .navigationTitle("Slo-Mo probe")
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task { await run(item) }
        }
    }

    private func run(_ item: PhotosPickerItem) async {
        working = true
        reports = []
        defer { working = false }

        // Route A: the file PhotosPicker hands over.
        do {
            if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                reports.append(await SlowMoProbe.analyze(AVURLAsset(url: movie.url), route: "A. PhotosPicker file (.current)"))
                try? FileManager.default.removeItem(at: movie.url)
            } else {
                reports.append(.failure("A. PhotosPicker file (.current)", "No file came back."))
            }
        } catch {
            reports.append(.failure("A. PhotosPicker file (.current)", error.localizedDescription))
        }

        // Route B: the original from the photo library.
        let routeB = "B. Photo library original"
        guard let id = item.itemIdentifier else {
            reports.append(.failure(routeB, "The picker gave no asset identifier."))
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            reports.append(.failure(routeB, "Photo library access was not granted."))
            return
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            reports.append(.failure(routeB, "Couldn't find the asset. With limited access, add this clip to the allowed photos."))
            return
        }
        let subtypes = asset.mediaSubtypes.contains(.videoHighFrameRate) ? "high frame rate (Slo-Mo)" : "not marked Slo-Mo"
        do {
            let original = try await SlowMoProbe.original(of: asset)
            var report = await SlowMoProbe.analyze(original, route: routeB)
            report.rows.insert(("Photos subtype", subtypes), at: 0)
            reports.append(report)
        } catch {
            reports.append(.failure(routeB, error.localizedDescription))
        }
    }
}

nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = URL.temporaryDirectory.appending(path: "probe-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

nonisolated struct ProbeReport: Identifiable, Sendable {
    let id = UUID()
    var route: String
    var verdict: String
    var rows: [(String, String)]

    static func failure(_ route: String, _ message: String) -> ProbeReport {
        ProbeReport(route: route, verdict: "Failed: \(message)", rows: [])
    }

    var text: String {
        ([route, verdict] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
    }
}

nonisolated enum SlowMoProbe {
    struct ProbeError: LocalizedError {
        var errorDescription: String?
    }

    static func original(of asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        // The handler hands over sole ownership of the asset, so passing it on is safe.
        struct Handoff: @unchecked Sendable { let asset: AVAsset }
        let handoff: Handoff = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: Handoff(asset: avAsset))
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? ProbeError(errorDescription: "No video came back."))
                }
            }
        }
        return handoff.asset
    }

    static func analyze(_ asset: AVAsset, route: String) async -> ProbeReport {
        do {
            return try await measure(asset, route: route)
        } catch {
            return .failure(route, error.localizedDescription)
        }
    }

    private static func measure(_ asset: AVAsset, route: String) async throws -> ProbeReport {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError(errorDescription: "The file has no video track.")
        }
        let (nominal, size, minFrame) = try await track.load(.nominalFrameRate, .naturalSize, .minFrameDuration)
        let duration = try await asset.load(.duration).seconds

        var rows: [(String, String)] = []
        let kind = asset is AVComposition ? "AVComposition (edited timeline)"
            : (asset as? AVURLAsset).map { "File: \($0.url.lastPathComponent)" } ?? String(describing: type(of: asset))
        rows.append(("Asset", kind))

        // A composition's segments show any slow-motion time ramp directly.
        if let compositionTrack = track as? AVCompositionTrack {
            let scaled = compositionTrack.segments.filter {
                abs($0.timeMapping.source.duration.seconds - $0.timeMapping.target.duration.seconds) > 0.001
            }
            rows.append(("Segments", "\(compositionTrack.segments.count), \(scaled.count) time-scaled"))
        }

        // Every frame's presentation time, read without decoding.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ProbeError(errorDescription: "Couldn't read the frames.")
        }
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            }
        }
        times.sort()
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }
        let deltas = steps.sorted()
        let span = (times.last ?? 0) - (times.first ?? 0)
        let measured = times.count > 1 && span > 0 ? Double(times.count - 1) / span : 0
        let median = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
        let typicalFPS = median > 0 ? 1 / median : 0

        // A gap is any step longer than 1.5 typical frames.
        let gapSteps = steps.filter { $0 > median * 1.5 }
        let missingTime = gapSteps.reduce(0) { $0 + ($1 - median) }
        let missingFrames = median > 0 ? Int((missingTime / median).rounded()) : 0
        var gapSizes: [Int: Int] = [:]
        for gap in gapSteps { gapSizes[Int((gap / median).rounded()) - 1, default: 0] += 1 }
        let sizeText = gapSizes.keys.sorted().map { "\(gapSizes[$0]!)× \($0) missing" }.joined(separator: ", ")

        // Frames in each second of the clip, to show where the gaps fall.
        let start = times.first ?? 0
        var perSecond = [Int](repeating: 0, count: max(1, Int(span.rounded(.up))))
        for t in times { perSecond[min(perSecond.count - 1, Int(t - start))] += 1 }
        let timeline = perSecond.enumerated().map { "\($0.offset)s \($0.element)" }.joined(separator: ", ")

        rows += [
            ("Nominal frame rate", String(format: "%.1f fps", nominal)),
            ("Typical frame rate", String(format: "%.1f fps (median spacing)", typicalFPS)),
            ("Average frame rate", String(format: "%.1f fps (frames ÷ span)", measured)),
            ("Frames", "\(times.count)"),
            ("Duration", String(format: "%.3f s", duration)),
            ("Frame spacing", String(format: "min %.2f, median %.2f, max %.2f ms",
                                     (deltas.first ?? 0) * 1000, median * 1000, (deltas.last ?? 0) * 1000)),
            ("Gaps", gapSteps.isEmpty ? "none" : "\(gapSteps.count), \(missingFrames) frames missing (\(sizeText))"),
            ("Time in gaps", String(format: "%.2f s of %.2f s", missingTime, span)),
            ("Frames per second of clip", timeline),
            ("Min frame duration", String(format: "%.2f ms", minFrame.seconds * 1000)),
            ("Size", "\(Int(size.width))×\(Int(size.height))"),
        ]

        let verdict: String
        let gapShare = span > 0 ? missingTime / span : 0
        if typicalFPS >= 200 && gapShare < 0.02 {
            verdict = String(format: "Usable: %.0f fps in real time, %.1f ms per frame, almost no gaps.", typicalFPS, median * 1000)
        } else if typicalFPS >= 200 {
            verdict = String(format: "Usable with gaps: %.0f fps typical, but %.0f%% of the time falls in gaps.", typicalFPS, gapShare * 100)
        } else if typicalFPS >= 100 {
            verdict = String(format: "Usable but coarse: %.0f fps, %.1f ms per frame.", typicalFPS, median * 1000)
        } else {
            verdict = String(format: "Not usable as is: %.0f fps. Frames were dropped or time was stretched.", typicalFPS)
        }
        return ProbeReport(route: route, verdict: verdict, rows: rows)
    }
}
#endif
