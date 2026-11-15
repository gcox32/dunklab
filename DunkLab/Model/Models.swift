import Foundation
import SwiftData

// MARK: - Value types stored inside models

nonisolated enum ExerciseKind: String, Codable, CaseIterable, Identifiable {
    case warmup, strength, plyometric, sprint, isometric, core, mobility

    var id: String { rawValue }

    var label: String {
        switch self {
        case .warmup: "Warm-up"
        case .strength: "Strength"
        case .plyometric: "Plyometric"
        case .sprint: "Sprint"
        case .isometric: "Isometric"
        case .core: "Core"
        case .mobility: "Mobility"
        }
    }
}

nonisolated enum Effort: String, Codable, CaseIterable, Identifiable {
    case light, medium, heavy

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Jump Science's definitions, out of 10.
    var guide: String {
        switch self {
        case .light: "5/10 or easier"
        case .medium: "6–8/10, no struggle to finish"
        case .heavy: "9–10/10, last rep is hard"
        }
    }
}

nonisolated struct LoadSpec: Codable, Hashable {
    /// Percent of the program's basis lift (max deep squat for Jump Science).
    var percent: Double?
    var effort: Effort?
    var pounds: Double?
    var bodyweight: Bool?
}

nonisolated struct SetSpec: Codable, Hashable {
    var reps: Int?
    var seconds: Int?
    var meters: Int?
    var load: LoadSpec?
}

nonisolated struct LoggedSet: Codable, Hashable, Identifiable {
    var id = UUID()
    var target: SetSpec?
    var reps: Int?
    var seconds: Int?
    var meters: Int?
    var weightLb: Double?
    var done = false
}

/// How an exercise reads the athlete's strength.
nonisolated enum Gauge: String, Codable {
    /// A heavy single that can beat the max the program's percentages use.
    case maxTest
    /// Light on strength work, so the way the bar moves is the read on strength.
    case barSpeed
    /// Drop jumps: time a rep from a Slo-Mo clip for reactive strength (RSI).
    case reactive
}

/// How the bar moved on a bar-speed check.
nonisolated enum BarFeel: String, Codable, CaseIterable, Identifiable {
    case fast, solid, slow

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A how-to video that belongs to the program rather than one exercise.
nonisolated struct VideoLink: Codable, Hashable {
    var title: String
    var video: String
}

/// Lifts the program allows in place of one of its exercises.
nonisolated struct ExerciseSwap: Codable, Hashable {
    var replaces: String
    var options: [String]
    var sets: [SetSpec]
    var details: String?
}

nonisolated struct DecisionOption: Codable, Hashable {
    var label: String
    var detail: String
    var goToWeek: Int
}

nonisolated enum JSONField {
    static func decode<T: Decodable>(_ data: Data?, as: T.Type, default value: T) -> T {
        guard let data else { return value }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? value
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

// MARK: - Athlete and body

@Model final class Athlete {
    var heightIn: Double = 0
    var standingReachIn: Double = 0
    var rimHeightIn: Double = 120
    /// Body fat considered lean for nutrition math: 10% for men, 15% for women.
    var leanBodyFatPct: Double = 10
    /// Weekly sport-play budget. Jump Science suggests 2–3 hours while chasing jump gains.
    var weeklyPlayMinutes: Int = 180
    var createdAt: Date = Date.now

    init() {}

    func line(for stage: DunkStage) -> Double { rimHeightIn + stage.clearanceIn }
}

@Model final class BodyEntry {
    var date: Date = Date.now
    var weightLb: Double?
    var bodyFatPct: Double?

    init(date: Date = .now, weightLb: Double?, bodyFatPct: Double?) {
        self.date = date
        self.weightLb = weightLb
        self.bodyFatPct = bodyFatPct
    }
}

@Model final class StrengthTest {
    var date: Date = Date.now
    var lift: String = "max deep squat"
    var weightLb: Double = 0

    init(date: Date = .now, lift: String = "max deep squat", weightLb: Double) {
        self.date = date
        self.lift = lift
        self.weightLb = weightLb
    }
}

@Model final class TouchRecord {
    var date: Date = Date.now
    var heightIn: Double = 0
    var isEstimate: Bool = false
    var session: PracticeSession?

    init(date: Date = .now, heightIn: Double, isEstimate: Bool = false) {
        self.date = date
        self.heightIn = heightIn
        self.isEstimate = isEstimate
    }
}

// MARK: - Reactive strength

nonisolated enum JumpTestKind: String, Codable, CaseIterable, Identifiable {
    case dropJump, pogo, cmj

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dropJump: "Drop jump"
        case .pogo: "Pogo hops"
        case .cmj: "Countermovement jump"
        }
    }

    var shortLabel: String {
        switch self {
        case .dropJump: "Drop jump"
        case .pogo: "Pogo"
        case .cmj: "CMJ"
        }
    }

    /// The first moment to mark: feet touching down, or the dip starting for a CMJ.
    var startLabel: String { self == .cmj ? "Start" : "Touch" }

    /// Drop jumps and pogos measure a quick rebound. A CMJ's slower dip is the point.
    var isRebound: Bool { self != .cmj }
}

/// Three marked moments in one rep, in seconds of real time from the clip.
nonisolated struct JumpRep: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Feet touch down (drop jump, pogo) or the dip starts (CMJ).
    var contact: Double
    var takeoff: Double
    var landing: Double

    var groundTime: Double { takeoff - contact }
    var flightTime: Double { landing - takeoff }
    var heightIn: Double { Reactive.heightIn(flight: flightTime) }
    var rsi: Double { Reactive.rsi(groundTime: groundTime, flight: flightTime) }
}

/// One reactive strength test, timed from a Slo-Mo clip.
@Model final class JumpTest {
    var date: Date = Date.now
    var kindRaw: String = JumpTestKind.dropJump.rawValue
    var boxHeightIn: Double?
    /// The marked moments, kept so results can be recomputed if the math changes.
    var repsData: Data = Data()
    /// The workout it was measured in, if any.
    var log: WorkoutLog?

    init(date: Date = .now, kind: JumpTestKind, boxHeightIn: Double? = nil, reps: [JumpRep]) {
        self.date = date
        self.kindRaw = kind.rawValue
        self.boxHeightIn = boxHeightIn
        self.repsData = JSONField.encode(reps)
    }

    var kind: JumpTestKind { JumpTestKind(rawValue: kindRaw) ?? .dropJump }

    var reps: [JumpRep] {
        get { JSONField.decode(repsData, as: [JumpRep].self, default: []) }
        set { repsData = JSONField.encode(newValue) }
    }

    /// The rep with the best RSI among those that count.
    var best: JumpRep? { Reactive.best(of: reps, kind: kind) }
}

// MARK: - Programs and workout templates

@Model final class Program {
    var name: String = ""
    var author: String = ""
    var summary: String = ""
    /// What a percentage refers to, e.g. "max deep squat".
    var percentBasis: String = "max deep squat"
    var guidelines: [String] = []
    /// Videos to watch before testing the basis lift.
    var basisVideosData: Data?
    var swapsData: Data?
    var isActive: Bool = false
    var currentWeek: Int = 1
    /// Index into the current week's sorted days.
    var currentDay: Int = 0
    /// Set when the current week ended with a decision to make.
    var awaitingDecision: Bool = false
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \ProgramWeek.program)
    var weeks: [ProgramWeek] = []

    @Relationship(deleteRule: .cascade, inverse: \PlanDay.asNeededFor)
    var asNeeded: [PlanDay] = []

    init(name: String, author: String = "", summary: String = "") {
        self.name = name
        self.author = author
        self.summary = summary
    }

    var basisVideos: [VideoLink] {
        get { JSONField.decode(basisVideosData, as: [VideoLink].self, default: []) }
        set { basisVideosData = JSONField.encode(newValue) }
    }

    var swaps: [ExerciseSwap] {
        get { JSONField.decode(swapsData, as: [ExerciseSwap].self, default: []) }
        set { swapsData = JSONField.encode(newValue) }
    }

    /// The swap that applies to an exercise, whether it's the original or a replacement.
    func swap(for exercise: String) -> ExerciseSwap? {
        swaps.first { $0.replaces == exercise || $0.options.contains(exercise) }
    }

    var sortedWeeks: [ProgramWeek] { weeks.sorted { $0.number < $1.number } }
    var sortedAsNeeded: [PlanDay] { asNeeded.sorted { $0.order < $1.order } }

    func week(_ number: Int) -> ProgramWeek? { weeks.first { $0.number == number } }

    var currentWeekModel: ProgramWeek? { week(currentWeek) }

    var nextDay: PlanDay? {
        guard !awaitingDecision, let days = currentWeekModel?.sortedDays,
              days.indices.contains(currentDay) else { return nil }
        return days[currentDay]
    }

    /// Moves the pointer past `day` if it is the next scheduled workout.
    func advance(past day: PlanDay) {
        guard day.persistentModelID == nextDay?.persistentModelID,
              let week = currentWeekModel else { return }
        currentDay += 1
        if currentDay >= week.days.count {
            if week.decision != nil {
                awaitingDecision = true
            } else if self.week(currentWeek + 1) != nil {
                currentWeek += 1
                currentDay = 0
            } else {
                awaitingDecision = true
            }
        }
    }

    func jump(toWeek number: Int, day: Int = 0) {
        currentWeek = number
        currentDay = day
        awaitingDecision = false
    }
}

@Model final class ProgramWeek {
    var number: Int = 1
    var decision: String?
    var decisionOptionsData: Data?
    var program: Program?

    @Relationship(deleteRule: .cascade, inverse: \PlanDay.week)
    var days: [PlanDay] = []

    init(number: Int) {
        self.number = number
    }

    var sortedDays: [PlanDay] { days.sorted { $0.order < $1.order } }

    var decisionOptions: [DecisionOption] {
        get { JSONField.decode(decisionOptionsData, as: [DecisionOption].self, default: []) }
        set { decisionOptionsData = JSONField.encode(newValue) }
    }
}

/// A workout template: a program day, an as-needed routine, or one of the athlete's own.
@Model final class PlanDay {
    var title: String = ""
    var order: Int = 0
    var notes: String = ""
    /// Full rest days wanted between the program's previous workout and this one.
    var restDaysBefore: Int = 0
    var createdAt: Date = Date.now
    var week: ProgramWeek?
    var asNeededFor: Program?

    @Relationship(deleteRule: .cascade, inverse: \PlanItem.day)
    var items: [PlanItem] = []

    @Relationship(deleteRule: .nullify, inverse: \WorkoutLog.sourceDay)
    var logs: [WorkoutLog] = []

    init(title: String, order: Int = 0) {
        self.title = title
        self.order = order
    }

    var sortedItems: [PlanItem] { items.sorted { $0.order < $1.order } }
    var isOwnWorkout: Bool { week == nil && asNeededFor == nil }

    var program: Program? { week?.program ?? asNeededFor }

    /// "PhD Program, week 3, day 2"
    var contextLabel: String? {
        if let week, let program = week.program {
            return "\(program.name), week \(week.number)"
        }
        if let asNeededFor { return "\(asNeededFor.name), as needed" }
        return nil
    }
}

@Model final class PlanItem {
    var order: Int = 0
    var exercise: String = ""
    var kindRaw: String = ExerciseKind.strength.rawValue
    var setsData: Data = Data()
    /// "leg" or "side" when the sets are done on each.
    var perSide: String?
    var details: String?
    /// A how-to video for the exercise, usually a YouTube link.
    var videoURL: String?
    var gaugeRaw: String?
    var day: PlanDay?

    init(order: Int, exercise: String, kind: ExerciseKind, sets: [SetSpec],
         perSide: String? = nil, details: String? = nil, videoURL: String? = nil,
         gauge: Gauge? = nil) {
        self.order = order
        self.exercise = exercise
        self.kindRaw = kind.rawValue
        self.setsData = JSONField.encode(sets)
        self.perSide = perSide
        self.details = details
        self.videoURL = videoURL
        self.gaugeRaw = gauge?.rawValue
    }

    var kind: ExerciseKind {
        get { ExerciseKind(rawValue: kindRaw) ?? .strength }
        set { kindRaw = newValue.rawValue }
    }

    var gauge: Gauge? {
        get { gaugeRaw.flatMap(Gauge.init) }
        set { gaugeRaw = newValue?.rawValue }
    }

    var sets: [SetSpec] {
        get { JSONField.decode(setsData, as: [SetSpec].self, default: []) }
        set { setsData = JSONField.encode(newValue) }
    }
}

// MARK: - Workout logs

@Model final class WorkoutLog {
    var startedAt: Date = Date.now
    var finishedAt: Date?
    var title: String = ""
    var context: String?
    var notes: String = ""
    var sourceDay: PlanDay?

    @Relationship(deleteRule: .cascade, inverse: \LoggedEntry.log)
    var entries: [LoggedEntry] = []

    /// RSI tests timed during this workout. Discarding the workout discards them too.
    @Relationship(deleteRule: .cascade, inverse: \JumpTest.log)
    var jumpTests: [JumpTest] = []

    init(title: String, context: String?) {
        self.title = title
        self.context = context
    }

    var sortedEntries: [LoggedEntry] { entries.sorted { $0.order < $1.order } }

    /// The heaviest completed rep across this workout's max tests, if any.
    var maxTestBest: Double? {
        entries.filter { $0.gauge == .maxTest }
            .flatMap(\.sets)
            .filter { $0.done && ($0.reps ?? 0) >= 1 }
            .compactMap(\.weightLb)
            .max()
    }

    /// Marks the workout done and, if it was the program's next workout, moves the program on.
    func finish(at date: Date = .now) {
        finishedAt = date
        if let day = sourceDay, let program = day.week?.program, program.isActive {
            program.advance(past: day)
        }
    }
}

@Model final class LoggedEntry {
    var order: Int = 0
    var exercise: String = ""
    var kindRaw: String = ExerciseKind.strength.rawValue
    var perSide: String?
    var details: String?
    var videoURL: String?
    var gaugeRaw: String?
    /// How the bar moved, for a bar-speed check.
    var feelRaw: String?
    var setsData: Data = Data()
    var log: WorkoutLog?

    init(order: Int, exercise: String, kind: ExerciseKind, perSide: String?, details: String?,
         videoURL: String? = nil, gauge: Gauge? = nil, sets: [LoggedSet]) {
        self.order = order
        self.exercise = exercise
        self.kindRaw = kind.rawValue
        self.perSide = perSide
        self.details = details
        self.videoURL = videoURL
        self.gaugeRaw = gauge?.rawValue
        self.setsData = JSONField.encode(sets)
    }

    var kind: ExerciseKind { ExerciseKind(rawValue: kindRaw) ?? .strength }
    var gauge: Gauge? { gaugeRaw.flatMap(Gauge.init) }

    var feel: BarFeel? {
        get { feelRaw.flatMap(BarFeel.init) }
        set { feelRaw = newValue?.rawValue }
    }

    /// The heaviest weight lifted in a completed set.
    var topWeight: Double? { sets.filter(\.done).compactMap(\.weightLb).max() }

    var sets: [LoggedSet] {
        get { JSONField.decode(setsData, as: [LoggedSet].self, default: []) }
        set { setsData = JSONField.encode(newValue) }
    }
}

// MARK: - Practice

/// A dunk on the athlete's ladder, with the rough hand height above the rim it needs.
@Model final class DunkStage {
    var order: Int = 0
    var name: String = ""
    var detail: String = ""
    var clearanceIn: Double = 6
    var landedAt: Date?

    init(order: Int, name: String, detail: String, clearanceIn: Double) {
        self.order = order
        self.name = name
        self.detail = detail
        self.clearanceIn = clearanceIn
    }

    var isLanded: Bool { landedAt != nil }

    /// The goal is the first dunk on the ladder not landed yet.
    static func goal(in stages: [DunkStage]) -> DunkStage? {
        stages.sorted { $0.order < $1.order }.first { !$0.isLanded }
    }
}

@Model final class PracticeFocus {
    var order: Int = 0
    var name: String = ""
    var cue: String = ""

    init(order: Int, name: String, cue: String) {
        self.order = order
        self.name = name
        self.cue = cue
    }
}

@Model final class PracticeSession {
    var startedAt: Date = Date.now
    var finishedAt: Date?
    var focus: String = ""
    var cue: String = ""
    var stage: String = ""
    var attemptCap: Int = 20
    var reflection: String = ""

    @Relationship(deleteRule: .cascade, inverse: \DunkAttempt.session)
    var attempts: [DunkAttempt] = []

    @Relationship(deleteRule: .cascade, inverse: \TouchRecord.session)
    var touches: [TouchRecord] = []

    init(focus: String, cue: String, stage: String, attemptCap: Int) {
        self.focus = focus
        self.cue = cue
        self.stage = stage
        self.attemptCap = attemptCap
    }

    var sortedAttempts: [DunkAttempt] { attempts.sorted { $0.at < $1.at } }
    var makes: Int { attempts.filter { $0.outcome == .make }.count }
    var bestTouch: Double? { touches.map(\.heightIn).max() }

    /// When the session ended. One that was never ended (the app closed
    /// mid-session) counts only up to the last thing logged in it.
    var effectiveEnd: Date {
        finishedAt ?? (attempts.map(\.at) + touches.map(\.date)).max() ?? startedAt
    }

    var minutes: Double {
        effectiveEnd.timeIntervalSince(startedAt) / 60
    }
}

@Model final class DunkAttempt {
    var at: Date = Date.now
    var stage: String = ""
    var outcomeRaw: String = AttemptOutcome.miss.rawValue
    var session: PracticeSession?

    init(stage: String, outcome: AttemptOutcome) {
        self.stage = stage
        self.outcomeRaw = outcome.rawValue
    }

    var outcome: AttemptOutcome { AttemptOutcome(rawValue: outcomeRaw) ?? .miss }
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Athlete.self, BodyEntry.self, StrengthTest.self, TouchRecord.self, JumpTest.self,
        Program.self, ProgramWeek.self, PlanDay.self, PlanItem.self,
        WorkoutLog.self, LoggedEntry.self,
        DunkStage.self, PracticeFocus.self, PracticeSession.self, DunkAttempt.self,
    ]
}
