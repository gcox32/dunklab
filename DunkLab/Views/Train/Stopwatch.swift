import Observation
import SwiftUI
import UIKit

@Observable final class Stopwatch {
    private(set) var startedAt: Date?
    /// Time from earlier runs, before the latest pause.
    private(set) var banked: TimeInterval = 0

    var isRunning: Bool { startedAt != nil }
    var isCleared: Bool { !isRunning && banked == 0 }

    func elapsed(at now: Date) -> TimeInterval {
        banked + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    func toggle() {
        if let startedAt {
            banked += Date.now.timeIntervalSince(startedAt)
            self.startedAt = nil
        } else {
            startedAt = .now
        }
    }

    func reset() {
        startedAt = nil
        banked = 0
    }
}

/// The stopwatch at the bottom of a workout: a small button when closed,
/// a panel when open. It keeps time whether open or closed.
struct StopwatchPanel: View {
    let stopwatch: Stopwatch
    @Binding var isOpen: Bool

    var body: some View {
        Group {
            if isOpen {
                panel
            } else {
                closed
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.snappy, value: isOpen)
        .sensoryFeedback(.impact, trigger: stopwatch.isRunning)
        .onChange(of: stopwatch.isRunning) { _, running in
            // Keep the screen awake through a hold.
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var closed: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stopwatch")
                if stopwatch.isCleared {
                    Text("Stopwatch")
                } else {
                    readout(font: .readout(.headline))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(stopwatch.isCleared ? "Open stopwatch" : "Open stopwatch, running")
    }

    private var panel: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                readout(font: .system(size: 64, weight: .heavy).width(.compressed))
                Spacer()
                Button {
                    isOpen = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close stopwatch")
            }
            HStack(spacing: 10) {
                Button("Reset") { stopwatch.reset() }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Palette.chalk.opacity(0.6), in: .rect(cornerRadius: 14))
                    .disabled(stopwatch.isCleared)
                Button(stopwatch.isRunning ? "Stop" : stopwatch.isCleared ? "Start" : "Resume") {
                    stopwatch.toggle()
                }
                .buttonStyle(BigButtonStyle(tint: stopwatch.isRunning ? Palette.ink : Palette.vaneBlue))
            }
        }
        .padding(16)
        .background(Palette.glass, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private func readout(font: Font) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            Text(Duration.seconds(stopwatch.elapsed(at: timeline.date)),
                 format: .time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1)))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
        }
    }
}
