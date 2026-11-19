#if DEBUG
import Foundation
import SwiftData

/// Simulator shortcuts. Launch with `-fixture starting-numbers` to skip onboarding.
enum DebugFixtures {
    static func applyLaunchArguments(to context: ModelContext) {
        guard UserDefaults.standard.string(forKey: "fixture") == "starting-numbers",
              (try? context.fetchCount(FetchDescriptor<Athlete>())) == 0 else { return }

        let athlete = Athlete()
        athlete.heightIn = 73.5
        athlete.standingReachIn = 94.5
        context.insert(athlete)
        context.insert(BodyEntry(weightLb: 180, bodyFatPct: nil))
        context.insert(StrengthTest(weightLb: 275))
        context.insert(TouchRecord(heightIn: 124, isEstimate: true))
        // `-touchHistory YES`: an older best touch, so Today shows the gap moving.
        if UserDefaults.standard.bool(forKey: "touchHistory") {
            let touch = TouchRecord(heightIn: 122.5, isEstimate: true)
            touch.date = Date.now.addingTimeInterval(-40 * 86_400)
            context.insert(touch)
        }

        let stages = (try? context.fetch(FetchDescriptor<DunkStage>(sortBy: [SortDescriptor(\.order)]))) ?? []
        stages.first?.ownedAt = .now
        // `-landedOnce YES`: one practice session with a make on the second dunk, landed but not owned.
        if UserDefaults.standard.bool(forKey: "landedOnce"), stages.count > 1 {
            let session = PracticeSession(focus: "Penultimate step", cue: "", stage: stages[1].name, attemptCap: 20)
            session.startedAt = Date.now.addingTimeInterval(-10 * 86_400)
            session.finishedAt = session.startedAt.addingTimeInterval(1_800)
            context.insert(session)
            for outcome in [AttemptOutcome.miss, .close, .make, .miss] {
                let attempt = DunkAttempt(stage: session.stage, outcome: outcome)
                attempt.at = session.startedAt
                context.insert(attempt)
                attempt.session = session
            }
        }
        if let program = try? context.fetch(FetchDescriptor<Program>()).first {
            program.isActive = true
            // `-week 4 -day 1`: start partway through (day is 0-based).
            let week = UserDefaults.standard.integer(forKey: "week")
            program.jump(toWeek: week > 0 ? week : 1, day: UserDefaults.standard.integer(forKey: "day"))
            // `-trainedToday YES`: day 1 is already done, so day 2 should wait for a rest day.
            if UserDefaults.standard.bool(forKey: "trainedToday"), let day = program.nextDay {
                WorkoutFactory.start(day, basis: 275, in: context).finish()
            }
        }
        // `-signals YES`: eight weeks of squat maxes, weights and drop jump tests for the Body charts.
        if UserDefaults.standard.bool(forKey: "signals") {
            let day = 86_400.0
            for (weeksAgo, squat, weight) in [(8.0, 255.0, 184.0), (6, 265, 183), (4, 270, 181), (2, 280, 180), (0.5, 285, 179)] {
                let date = Date.now.addingTimeInterval(-weeksAgo * 7 * day)
                context.insert(StrengthTest(date: date, weightLb: squat))
                context.insert(BodyEntry(date: date.addingTimeInterval(day), weightLb: weight, bodyFatPct: nil))
            }
            for (weeksAgo, ground, flight) in [(7.0, 0.238, 0.47), (5, 0.226, 0.48), (3, 0.214, 0.49), (1, 0.205, 0.50)] {
                let date = Date.now.addingTimeInterval(-weeksAgo * 7 * day)
                let rep = JumpRep(contact: 1, takeoff: 1 + ground, landing: 1 + ground + flight)
                context.insert(JumpTest(date: date, kind: .dropJump, boxHeightIn: 12, reps: [rep]))
            }
        }
        try? context.save()
    }
}
#endif
