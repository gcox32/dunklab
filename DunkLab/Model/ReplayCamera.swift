import AVFoundation
import VideoToolbox

/// The back camera filming nonstop at its highest frame rate (240 fps on
/// recent iPhones), keeping the last stretch in memory already compressed.
/// `keep` writes the last few seconds to a file without re-encoding, so
/// nothing has to be started before a jump: jump, walk back, then keep it.
///
/// Frames are encoded on arrival with one HEVC session, so every kept frame
/// shares one format and the file's frame times are the camera's real times.
nonisolated final class ReplayCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    struct Setup: Sendable {
        var fps: Double
        var width: Int32
        var height: Int32
    }

    /// How much is held in memory. About 90 MB at 240 fps.
    static let bufferSeconds: Double = 24

    let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "dunklab.replay.capture", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "dunklab.replay.write", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()

    // Touched only on captureQueue.
    private var compression: VTCompressionSession?
    private var frameDuration = CMTime(value: 1, timescale: 240)
    private var configured = false

    // Guarded by lock: written from the encoder's thread, read by keep.
    private let lock = NSLock()
    private var frames: [Frame] = []

    private struct Frame {
        let buffer: CMSampleBuffer
        let pts: CMTime
        let isSync: Bool
    }

    // MARK: Start and stop

    /// Asks for the camera, sets it to its fastest 1080p format, and starts filming.
    @concurrent func start() async throws -> Setup {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw Failure(errorDescription: "Dunk Lab needs the camera to film. You can allow it in Settings.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    let setup = try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume(returning: setup)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        captureQueue.async {
            self.session.stopRunning()
            if let compression = self.compression {
                VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            }
            self.lock.withLock { self.frames.removeAll() }
        }
    }

    private var setup: Setup?

    private func configureIfNeeded() throws -> Setup {
        if let setup { return setup }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw Failure(errorDescription: "This device has no back camera.")
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw Failure(errorDescription: "Couldn't use the camera.") }
        session.addInput(input)

        let format = Self.fastestFormat(of: device)
        let fps = format.map { Self.maxRate(of: $0) } ?? 30
        try device.lockForConfiguration()
        if let format { device.activeFormat = format }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        frameDuration = duration

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw Failure(errorDescription: "Couldn't film from the camera.") }
        session.addOutput(output)

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        compression = try Self.makeCompression(width: dims.width, height: dims.height, fps: fps)
        let setup = Setup(fps: fps, width: dims.width, height: dims.height)
        self.setup = setup
        return setup
    }

    /// The 1080p format with the highest frame rate, else the fastest format at least 720p tall.
    private static func fastestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let hd = usable.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == 1920 && d.height == 1080
        }
        let pool = hd.isEmpty ? usable.filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).height >= 720 } : hd
        return pool.max { maxRate(of: $0) < maxRate(of: $1) }
    }

    private static func maxRate(of format: AVCaptureDevice.Format) -> Double {
        min(240, format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
    }

    private static func makeCompression(width: Int32, height: Int32, fps: Double) throws -> VTCompressionSession {
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let session = made else {
            throw Failure(errorDescription: "Couldn't start the video encoder (\(status)).")
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: fps >= 200 ? 30_000_000 : 20_000_000,
            // Frequent keyframes so a kept clip can start close to where it's asked to.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0.5,
            // Frames come out in order, so the ring can be cut anywhere after a keyframe.
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    // MARK: Filming

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let compression, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(compression, imageBuffer: image, presentationTimeStamp: pts,
                                        duration: frameDuration, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            self.append(encoded)
        }
    }

    private func append(_ buffer: CMSampleBuffer) {
        let frame = Frame(buffer: buffer, pts: CMSampleBufferGetPresentationTimeStamp(buffer), isSync: Self.isSync(buffer))
        lock.withLock {
            frames.append(frame)
            // Trim in chunks, a second at a time, rather than one frame per frame.
            guard let first = frames.first, (frame.pts - first.pts).seconds > Self.bufferSeconds + 1 else { return }
            let cutoff = frame.pts.seconds - Self.bufferSeconds
            let drop = frames.firstIndex { $0.pts.seconds >= cutoff } ?? 0
            frames.removeFirst(drop)
        }
    }

    private static func isSync(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: Keeping

    struct Kept: Sendable {
        let url: URL
        /// When the clip's first frame was filmed.
        let recordedAt: Date
    }

    /// Writes about the last `seconds` filmed to a new file in the temporary
    /// directory, starting at the keyframe nearest the cut. Filming carries on.
    /// `rotationDegrees` turns the picture upright, as the phone was held.
    @concurrent func keep(lastSeconds seconds: Double, rotationDegrees: Double) async throws -> Kept {
        let snapshot = lock.withLock { frames }
        guard let newest = snapshot.last else {
            throw Failure(errorDescription: "Nothing filmed yet.")
        }
        let wantStart = newest.pts.seconds - seconds
        let startIndex = snapshot.firstIndex { $0.isSync && $0.pts.seconds >= wantStart }
            ?? snapshot.firstIndex(where: \.isSync)
        guard let startIndex, let format = CMSampleBufferGetFormatDescription(snapshot[startIndex].buffer) else {
            throw Failure(errorDescription: "Nothing filmed yet.")
        }
        let slice = Array(snapshot[startIndex...])

        // Capture times are on the host clock, so this dates the first frame.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let recordedAt = Date.now.addingTimeInterval(-(now - slice[0].pts).seconds)

        let url = URL.temporaryDirectory.appending(path: "replay-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Index at the front, so it streams from the bucket without fetching the end first.
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        input.transform = CGAffineTransform(rotationAngle: rotationDegrees * .pi / 180)
        guard writer.canAdd(input) else { throw Failure(errorDescription: "Couldn't write the clip.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? Failure(errorDescription: "Couldn't write the clip.")
        }
        // The file's clock starts at its first frame.
        writer.startSession(atSourceTime: slice[0].pts)

        let box = WriteBox(input: input, frames: slice.map(\.buffer))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: writeQueue) {
                while box.input.isReadyForMoreMediaData {
                    guard let next = box.next() else {
                        box.input.markAsFinished()
                        box.finish { done.resume() }
                        return
                    }
                    if !box.input.append(next) {
                        box.input.markAsFinished()
                        box.finish { done.resume() }
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? Failure(errorDescription: "Couldn't write the clip.")
        }
        return Kept(url: url, recordedAt: recordedAt)
    }

    /// The frames left to write, walked on the write queue only.
    private final class WriteBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        private var frames: [CMSampleBuffer]
        private var index = 0
        private var finished = false

        init(input: AVAssetWriterInput, frames: [CMSampleBuffer]) {
            self.input = input
            self.frames = frames
        }

        func next() -> CMSampleBuffer? {
            guard index < frames.count else { return nil }
            defer { index += 1 }
            return frames[index]
        }

        /// The ready handler can run again after the last frame; finish once.
        func finish(_ body: () -> Void) {
            guard !finished else { return }
            finished = true
            frames = []
            body()
        }
    }
}
