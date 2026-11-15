import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The attempt count on the lock screen, with the same three outcome buttons as the app.
struct PracticeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PracticeActivityAttributes.self) { context in
            PracticeLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Palette.backboard)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.focus)
                        .font(.readout(.headline))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(since: context.attributes.startedAt)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    OutcomeButtons(sessionID: context.attributes.sessionID)
                }
            } compactLeading: {
                Image(systemName: "basketball.fill").foregroundStyle(Palette.rim)
            } compactTrailing: {
                Text("\(state.attempts)/\(state.cap)")
                    .font(.readout(.body))
                    .monospacedDigit()
            } minimal: {
                Text("\(state.attempts)")
                    .font(.readout(.body))
                    .monospacedDigit()
            }
        }
    }
}

private struct PracticeLockScreen: View {
    let attributes: PracticeActivityAttributes
    let state: PracticeActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(attributes.focus) · \(state.stage)")
                    .font(.readout(.headline))
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(1)
                Spacer()
                Elapsed(since: attributes.startedAt)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(state.attempts)")
                    .font(.readout(.largeTitle))
                    .monospacedDigit()
                    .foregroundStyle(state.attempts >= state.cap ? Palette.vaneRed : Palette.ink)
                Text("of \(state.cap), \(state.makes) \(state.makes == 1 ? "make" : "makes")")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSoft)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(Array(state.recent.enumerated()), id: \.offset) { _, outcome in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(outcome))
                            .frame(width: 7, height: 14)
                    }
                }
            }
            OutcomeButtons(sessionID: attributes.sessionID)
        }
        .padding(16)
    }

    private func color(_ outcome: AttemptOutcome) -> Color {
        switch outcome {
        case .make: Palette.vaneBlue
        case .close: Palette.rim
        case .miss: Palette.chalk
        }
    }
}

private struct OutcomeButtons: View {
    let sessionID: String

    var body: some View {
        HStack(spacing: 8) {
            button(.make, "Make", Palette.vaneBlue)
            button(.close, "Rimmed", Palette.rim)
            button(.miss, "Miss", Palette.inkSoft)
        }
    }

    private func button(_ outcome: AttemptOutcome, _ title: String, _ tint: Color) -> some View {
        Button(intent: RecordAttemptIntent(sessionID: sessionID, outcome: outcome)) {
            Text(title)
                .font(.readout(.headline))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
}
