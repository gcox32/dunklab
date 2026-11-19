import AVFoundation
import SwiftData
import SwiftUI

/// The replay camera as the screens see it: whether it's running, and
/// keeping the last few seconds as a library clip.
@Observable final class Filming {
    enum State: Equatable {
        case starting
        case running(fps: Double)
        case failed(String)
    }

    /// Seconds kept by an outcome tap. Long enough to walk back to the phone.
    static let keepSecondsKey = "camera.keepSeconds"
    static let keepChoices: [Double] = [6, 10, 15, 20]

    private(set) var state: State = .starting
    /// Clips being written right now, for a small "saving" note.
    private(set) var saving = 0

    let camera = ReplayCamera()
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    var isRunning: Bool { if case .running = state { true } else { false } }

    func start() async {
        state = .starting
        do {
            let setup = try await camera.start()
            state = .running(fps: setup.fps)
            UIApplication.shared.isIdleTimerDisabled = true
            attachCoordinator()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        camera.stop()
        previewObservation = nil
        coordinator = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Writes the last `seconds` filmed into the library as a new clip.
    func keep(_ kind: ClipKind, seconds: Double, into context: ModelContext) async throws -> Clip {
        saving += 1
        defer { saving -= 1 }
        // Portrait if the phone's orientation isn't known yet.
        let degrees = coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let kept = try await camera.keep(lastSeconds: seconds, rotationDegrees: degrees)
        return try await ClipLibrary.add(recordingAt: kept.url, kind: kind, recordedAt: kept.recordedAt, into: context)
    }

    // MARK: Keeping the preview upright

    fileprivate func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        attachCoordinator()
    }

    private func attachCoordinator() {
        guard coordinator == nil, let previewLayer,
              let device = (camera.session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self?.previewLayer?.connection?.videoRotationAngle = angle }
        }
    }
}

/// What the camera sees, filling its frame.
struct CameraPreview: UIViewRepresentable {
    let filming: Filming

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = filming.camera.session
        filming.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

/// The preview with its state laid over it: starting, the frame rate, or why it can't film.
struct CameraPanel: View {
    let filming: Filming

    var body: some View {
        CameraPreview(filming: filming)
            .overlay {
                switch filming.state {
                case .starting:
                    ProgressView().tint(.white)
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                case .running:
                    EmptyView()
                }
            }
            .overlay(alignment: .topLeading) {
                if case .running(let fps) = filming.state {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.vaneRed).frame(width: 8, height: 8)
                        Text("\(Int(fps)) fps").font(.caption.weight(.semibold)).monospacedDigit()
                        if filming.saving > 0 {
                            Text("Saving…").font(.caption)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .capsule)
                    .padding(8)
                }
            }
    }
}
