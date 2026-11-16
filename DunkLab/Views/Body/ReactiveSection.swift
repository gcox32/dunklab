import SwiftData
import SwiftUI

/// Reactive strength tests on the Body tab: a way to time a new one from a
/// Slo-Mo clip, and the history. The latest result shows in JumpSignalsSection.
struct ReactiveSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \JumpTest.date, order: .reverse) private var tests: [JumpTest]

    var body: some View {
        Section {
            TimeJumpButton()
            MotionJumpButton()

            ForEach(tests) { JumpTestRow(test: $0) }
                .onDelete { offsets in
                    for i in offsets { context.delete(tests[i]) }
                }
        } header: {
            SectionTitle("Reactive strength")
        } footer: {
            Text("Film in the Camera app's Slo-Mo mode with the phone low and your feet in frame, or wear the phone at your waist and let the motion sensor time it. Hands on hips, and land where you took off. A drop jump off a box about a foot high is the standard test.")
        }
    }
}
