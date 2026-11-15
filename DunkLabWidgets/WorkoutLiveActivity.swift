import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The current set on the lock screen, with a button to check it off.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Palette.backboard)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.title)
                        .font(.readout(.headline))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(since: context.attributes.startedAt)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CurrentSetRow(logID: context.attributes.logID, state: state)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(Palette.vaneBlue)
            } compactTrailing: {
                Text("\(state.doneSets)/\(state.totalSets)")
                    .font(.readout(.body))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "dumbbell.fill").foregroundStyle(Palette.vaneBlue)
            }
        }
    }
}

private struct WorkoutLockScreen: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(attributes.title)
                    .font(.readout(.headline))
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(1)
                Spacer()
                Elapsed(since: attributes.startedAt)
            }
            CurrentSetRow(logID: attributes.logID, state: state)
            HStack {
                if let next = state.nextExercise {
                    Text("Next: \(next)").lineLimit(1)
                }
                Spacer()
                Text("\(state.doneSets) of \(state.totalSets) sets")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSoft)
        }
        .padding(16)
    }
}

private struct CurrentSetRow: View {
    let logID: String
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if let set = state.current {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.exercise)
                        .font(.readout(.title2))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text("\(set.label) · \(set.summary)")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(intent: CompleteSetIntent(logID: logID, setID: set.id)) {
                    Label("Done", systemImage: "checkmark")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.vaneBlue)
            }
        } else if state.doneSets < state.totalSets {
            Text("Open Dunk Lab for the rest of the sets.")
                .font(.headline)
                .foregroundStyle(Palette.ink)
        } else {
            Text("Every set is done. Finish the workout in the app.")
                .font(.headline)
                .foregroundStyle(Palette.ink)
        }
    }
}

struct Elapsed: View {
    let since: Date

    var body: some View {
        Text(since, style: .timer)
            .font(.readout(.headline))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 70, alignment: .trailing)
            .foregroundStyle(Palette.inkSoft)
    }
}
