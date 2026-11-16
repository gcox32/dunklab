import CoreMotion
import Foundation

/// The accelerometer's total reading over a test, in g. About 1 standing still,
/// about 0 in the air (the phone is in free fall with you), spiking on landing.
nonisolated struct MotionTrace: Sendable {
    /// Seconds from the first sample.
    var times: [Double]
    var g: [Float]

    var duration: Double { times.last ?? 0 }
    var rateHz: Double { duration > 0 ? Double(times.count - 1) / duration : 0 }

    /// Stored as interleaved Float32 pairs: time, g.
    var data: Data {
        var floats: [Float] = []
        floats.reserveCapacity(times.count * 2)
        for (t, g) in zip(times, g) { floats += [Float(t), g] }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    init(times: [Double], g: [Float]) {
        self.times = times
        self.g = g
    }

    init?(data: Data) {
        guard data.count % 8 == 0 else { return nil }
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        times = stride(from: 0, to: floats.count, by: 2).map { Double(floats[$0]) }
        g = stride(from: 1, to: floats.count, by: 2).map { floats[$0] }
    }
}

/// Records the accelerometer as fast as the phone allows. Samples arrive on a
/// background queue; the screen reads them through the lock.
nonisolated final class MotionRecorder: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var times: [Double] = []
    private var g: [Float] = []

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    var isAvailable: Bool { manager.isAccelerometerAvailable }

    var sampleCount: Int { lock.withLock { g.count } }

    func start() {
        lock.withLock {
            times = []
            g = []
        }
        // Ask for 200 Hz; the phone gives what it can (usually 100), and the trace records what it got.
        manager.accelerometerUpdateInterval = 1.0 / 200
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration
            let magnitude = Float((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
            self.lock.withLock {
                self.times.append(data.timestamp)
                self.g.append(magnitude)
            }
        }
    }

    func stop() -> MotionTrace {
        manager.stopAccelerometerUpdates()
        return lock.withLock {
            let start = times.first ?? 0
            return MotionTrace(times: times.map { $0 - start }, g: g)
        }
    }
}

/// Finds jumps in a trace. Thresholds are first guesses, to be checked against
/// video-timed tests of the same jumps.
nonisolated enum MotionJumps {
    /// Below this, the phone counts as in free fall.
    static let freeFallG: Float = 0.4
    /// Blips above the threshold this short (in samples) don't end a flight: the phone wobbling.
    static let maxBlipSamples = 2
    static let minFlight = 0.08
    /// Longer than this isn't a jump: the phone was dropped or tossed.
    static let maxFlight = 1.2
    /// Most time on the ground between two flights that still makes one rebound.
    static let maxRebound = 0.6
    /// A CMJ starts at the last stillness before take off: this many samples within `stillG` of 1 g.
    static let stillSamples = 10
    static let stillG: Float = 0.06

    struct Flight: Identifiable, Hashable {
        var start: Double
        var end: Double
        var id: Double { start }
        var duration: Double { end - start }
    }

    static func flights(in trace: MotionTrace) -> [Flight] {
        let g = trace.g, t = trace.times
        guard g.count > 2 else { return [] }

        // Runs of samples under the threshold, as inclusive index ranges.
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for i in g.indices {
            if g[i] < freeFallG {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                runs.append(start...(i - 1))
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start...(g.count - 1)) }

        // Join runs split by a short wobble.
        var merged: [ClosedRange<Int>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound - last.upperBound - 1 <= maxBlipSamples {
                merged[merged.count - 1] = last.lowerBound...run.upperBound
            } else {
                merged.append(run)
            }
        }

        return merged.compactMap { run in
            // Interpolate the threshold crossings between samples on each side.
            let start = run.lowerBound > 0 ? crossing(run.lowerBound - 1, run.lowerBound, g, t) : t[run.lowerBound]
            let end = run.upperBound < g.count - 1 ? crossing(run.upperBound, run.upperBound + 1, g, t) : t[run.upperBound]
            let flight = Flight(start: start, end: end)
            return (minFlight...maxFlight).contains(flight.duration) ? flight : nil
        }
    }

    static func reps(in trace: MotionTrace, kind: JumpTestKind) -> [JumpRep] {
        let flights = flights(in: trace)
        switch kind {
        case .cmj:
            return flights.filter { $0.duration >= 0.2 }.compactMap { flight in
                stillnessEnd(before: flight.start, in: trace)
                    .map { JumpRep(contact: $0, takeoff: flight.start, landing: flight.end) }
            }
        case .dropJump, .pogo:
            // Back-to-back flights are a rebound: the first landing is the touch.
            // A drop jump is the step off the box, then the jump, so only the
            // first pair in a chain counts; a pogo counts every pair.
            var reps: [JumpRep] = []
            var chainHasRep = false
            for (previous, next) in zip(flights, flights.dropFirst()) {
                let ground = next.start - previous.end
                guard ground > 0, ground <= maxRebound else {
                    chainHasRep = false
                    continue
                }
                if kind == .dropJump && chainHasRep { continue }
                reps.append(JumpRep(contact: previous.end, takeoff: next.start, landing: next.end))
                chainHasRep = true
            }
            return reps
        }
    }

    /// The last moment the athlete stood still before a take off, up to 2 s back.
    static func stillnessEnd(before takeoff: Double, in trace: MotionTrace) -> Double? {
        guard var i = trace.times.lastIndex(where: { $0 < takeoff }) else { return nil }
        var still = 0
        while i >= 0, trace.times[i] > takeoff - 2 {
            if abs(trace.g[i] - 1) < stillG {
                still += 1
                if still >= stillSamples { return trace.times[i + still - 1] }
            } else {
                still = 0
            }
            i -= 1
        }
        return nil
    }

    private static func crossing(_ a: Int, _ b: Int, _ g: [Float], _ t: [Double]) -> Double {
        let ga = Double(g[a]), gb = Double(g[b])
        guard ga != gb else { return t[b] }
        let fraction = (Double(freeFallG) - ga) / (gb - ga)
        return t[a] + min(max(fraction, 0), 1) * (t[b] - t[a])
    }
}
